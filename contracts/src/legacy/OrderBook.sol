// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title ASK — an order book where the asset is patience.
/// @notice Players deposit ETH and declare their own exit multiplier (the "ask").
///         New deposits fill the book from the lowest ask upward, FIFO within a
///         price level. There is no withdraw and no cancel. The only lever is
///         repricing your ask — which always costs you time priority.
///
///         Deposits are permanent. Payouts come from later deposits, lowest ask
///         first. Most positions will not fill.
///
/// @dev    No proxy. No pause. No parameter setters. The only privileged action
///         is protocol-fee withdrawal. Every loop is bounded by a named constant,
///         except view-only functions executed via eth_call.
contract OrderBook is Ownable, ReentrancyGuard {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice 1.01x — the floor ask.
    uint32 public constant MIN_BPS = 10_100;
    /// @notice 100x — the ceiling ask.
    uint32 public constant MAX_BPS = 1_000_000;
    /// @notice 0.01x price granularity.
    uint32 public constant STEP_BPS = 100;
    /// @notice Number of price levels: 9,900.
    uint256 public constant NUM_LEVELS = (MAX_BPS - MIN_BPS) / STEP_BPS + 1;
    /// @notice Number of 256-bit words backing the level bitmap: 39.
    uint256 public constant NUM_BITMAP_WORDS = (NUM_LEVELS + 255) / 256;
    /// @notice Anti-dust / book-bloat floor.
    uint256 public constant MIN_DEPOSIT = 0.005 ether;
    /// @notice Keeps all bps math comfortably inside uint128. ~79B ETH.
    uint256 public constant MAX_DEPOSIT = 2 ** 96;
    /// @notice Gas ceiling on the fill loop.
    uint256 public constant MAX_FILLS_PER_TX = 20;
    /// @notice Anti-grief reprice cooldown, seconds.
    uint256 public constant REPRICE_COOLDOWN = 60;
    /// @notice 1.5% protocol fee, skimmed on deposit.
    uint256 public constant PROTOCOL_FEE_BPS = 150;
    /// @notice 1.0% jackpot fee, skimmed on deposit.
    uint256 public constant JACKPOT_FEE_BPS = 100;
    /// @notice Gas forwarded on push payouts. Failures credit pendingWithdrawals.
    uint256 public constant PAYOUT_GAS = 30_000;
    /// @notice There is no cancel. This is the visible, auditable switch.
    bool public constant CANCEL_ENABLED = false;

    uint256 private constant BPS_DENOM = 10_000;

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    struct Position {
        address owner;
        uint128 principal; // deposited, immutable
        uint128 paid; // filled so far
        uint32 askBps;
        uint32 level;
        uint64 lastReprice; // set at deposit, updated on reprice
        uint64 queueIndex; // slot in levelQueue[level]
        bool filled;
    }

    struct Level {
        uint64 head; // next read index (may point at tombstones)
        uint64 tail; // next write index
        uint64 count; // live positions at this level
        uint128 principalDepth; // sum of principal of live positions
        uint128 owedDepth; // sum of outstanding owed of live positions
    }

    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) private _positionsOf;

    mapping(uint256 => Level) public levels;
    /// @dev level => index => positionId. 0 = empty slot / tombstone.
    mapping(uint256 => mapping(uint256 => uint256)) public levelQueue;
    /// @dev wordIndex => bits. Bit set iff that level has >= 1 live position.
    mapping(uint256 => uint256) public levelBitmap;

    /// @dev Position ids start at 1; 0 is the tombstone sentinel in levelQueue.
    uint256 public nextPositionId = 1;

    /// @notice Unspent fill budget, consumed by the next deposit first.
    uint256 public carry;
    /// @notice Paid to the closer of the book (last position cleared when the book empties via fills).
    uint256 public jackpot;
    /// @notice Owner-withdrawable fees.
    uint256 public protocolFees;
    /// @notice Sum of outstanding owed across all live positions.
    uint256 public totalOutstanding;
    /// @notice Sum of principal across all live positions.
    uint256 public totalLivePrincipal;
    /// @notice Count of live (unfilled) positions.
    uint256 public liveCount;

    /// @notice Payouts that could not be pushed (receiver reverted or ran out of gas).
    mapping(address => uint256) public pendingWithdrawals;
    /// @notice Sum of all pendingWithdrawals.
    uint256 public totalPending;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event Deposited(uint256 indexed id, address indexed owner, uint256 principal, uint32 askBps, uint256 level);
    event Filled(uint256 indexed id, address indexed owner, uint256 amount, uint256 remaining);
    event PositionCleared(uint256 indexed id, address indexed owner, uint256 principal, uint256 totalPayout);
    event Repriced(uint256 indexed id, uint32 oldAskBps, uint32 newAskBps, uint256 oldLevel, uint256 newLevel);
    event JackpotPaid(uint256 indexed id, address indexed owner, uint256 amount);
    event PendingCredited(address indexed owner, uint256 amount);
    event PendingClaimed(address indexed owner, uint256 amount);
    event ProtocolFeesWithdrawn(address indexed to, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors — blunt, like the UI.
    // ─────────────────────────────────────────────────────────────────────────

    error DepositTooSmall(uint256 sent, uint256 min);
    error DepositTooLarge(uint256 sent, uint256 max);
    error AskOutOfBounds(uint32 askBps);
    error AskNotAligned(uint32 askBps);
    error NotYourPosition(uint256 id);
    error PositionAlreadyFilled(uint256 id);
    error RepriceCooldown(uint256 secondsRemaining);
    error AskBelowRealizedPayout(uint32 newAskBps, uint256 alreadyPaid);
    error CancelDisabled();
    error NothingPending();
    error NoSuchPosition(uint256 id);
    error TransferFailed();

    constructor() Ownable(msg.sender) {}

    // ─────────────────────────────────────────────────────────────────────────
    // Deposit + fill
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deposit ETH and place an ask. Your money first fills the book
    ///         from the lowest ask upward; then your position joins the tail
    ///         of its level. Your own position cannot receive any of your own
    ///         deposit — it does not exist while the book is being filled.
    /// @param askBps Your exit multiplier in basis points. 10_100 = 1.01x.
    function deposit(uint32 askBps) external payable nonReentrant returns (uint256 id) {
        // 1. Validate.
        if (msg.value < MIN_DEPOSIT) revert DepositTooSmall(msg.value, MIN_DEPOSIT);
        if (msg.value > MAX_DEPOSIT) revert DepositTooLarge(msg.value, MAX_DEPOSIT);
        uint256 level = _validateAsk(askBps);

        // 2. Skim fees.
        uint256 protocolCut = (msg.value * PROTOCOL_FEE_BPS) / BPS_DENOM;
        uint256 jackpotCut = (msg.value * JACKPOT_FEE_BPS) / BPS_DENOM;
        protocolFees += protocolCut;
        jackpot += jackpotCut;

        // 3. Budget = net deposit + carried-over budget.
        uint256 budget = msg.value - protocolCut - jackpotCut + carry;
        carry = 0;

        // 4. Fill the book. The depositor's position does not exist yet:
        //    self-filling is structurally impossible.
        budget = _fill(budget);

        // 5. Leftover budget carries to the next deposit.
        carry = budget;

        // 6. Insert the new position at the tail of its level.
        id = nextPositionId++;
        uint128 principal = uint128(msg.value);
        uint256 owed = (uint256(principal) * askBps) / BPS_DENOM;

        Position storage p = positions[id];
        p.owner = msg.sender;
        p.principal = principal;
        p.askBps = askBps;
        p.level = uint32(level);
        p.lastReprice = uint64(block.timestamp);
        _enqueue(level, id, p, principal, owed);

        _positionsOf[msg.sender].push(id);
        totalOutstanding += owed;
        totalLivePrincipal += principal;
        liveCount += 1;

        emit Deposited(id, msg.sender, principal, askBps, level);
    }

    /// @dev The fill loop. Strict (level asc, FIFO) order. Partial fills keep
    ///      absolute priority at the head of their level. Returns leftover budget.
    function _fill(uint256 budget) private returns (uint256) {
        uint256 fills = 0;
        uint256 lastClearedId = 0;
        address lastClearedOwner = address(0);

        while (budget != 0 && fills < MAX_FILLS_PER_TX) {
            (uint256 level, bool found) = _lowestNonEmptyLevel();
            if (!found) break;

            Level storage L = levels[level];
            // Advance head past tombstones. Bounded amortized: every slot is
            // skipped at most once over the contract's lifetime, and each
            // tombstone was paid for by a prior reprice.
            uint256 h = L.head;
            uint256 id = levelQueue[level][h];
            while (id == 0) {
                unchecked {
                    ++h;
                }
                id = levelQueue[level][h];
            }

            Position storage p = positions[id];
            uint256 owed = (uint256(p.principal) * p.askBps) / BPS_DENOM - p.paid;
            uint256 pay = owed <= budget ? owed : budget;

            p.paid += uint128(pay);
            budget -= pay;
            totalOutstanding -= pay;
            L.owedDepth -= uint128(pay);

            emit Filled(id, p.owner, pay, owed - pay);

            if (pay == owed) {
                // Fully cleared: dequeue.
                p.filled = true;
                delete levelQueue[level][h];
                unchecked {
                    L.count -= 1;
                    L.principalDepth -= p.principal;
                    liveCount -= 1;
                }
                totalLivePrincipal -= p.principal;
                if (L.count == 0) {
                    L.head = L.tail; // compact
                    _clearBit(level);
                } else {
                    L.head = uint64(h + 1);
                }
                lastClearedId = id;
                lastClearedOwner = p.owner;
                emit PositionCleared(id, p.owner, p.principal, (uint256(p.principal) * p.askBps) / BPS_DENOM);
            } else {
                // Partial: stays at head with absolute priority.
                L.head = uint64(h);
            }

            _send(p.owner, pay);

            unchecked {
                ++fills;
            }
        }

        // Book-clear jackpot: the book emptied via fills in this transaction.
        if (lastClearedId != 0 && jackpot != 0 && _bookIsEmpty()) {
            uint256 j = jackpot;
            jackpot = 0;
            emit JackpotPaid(lastClearedId, lastClearedOwner, j);
            _send(lastClearedOwner, j);
        }

        return budget;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reprice
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Move your ask to a new level. Any reprice — up or down — sends
    ///         you to the tail of the destination level. Undercutting is a real
    ///         decision, not a free option.
    function reprice(uint256 positionId, uint32 newAskBps) external nonReentrant {
        Position storage p = positions[positionId];
        if (p.owner != msg.sender) revert NotYourPosition(positionId);
        if (p.filled) revert PositionAlreadyFilled(positionId);
        uint256 readyAt = uint256(p.lastReprice) + REPRICE_COOLDOWN;
        if (block.timestamp < readyAt) revert RepriceCooldown(readyAt - block.timestamp);
        uint256 newLevel = _validateAsk(newAskBps);

        uint256 newTarget = (uint256(p.principal) * newAskBps) / BPS_DENOM;
        if (newTarget < p.paid) revert AskBelowRealizedPayout(newAskBps, p.paid);

        uint32 oldAskBps = p.askBps;
        uint256 oldLevel = p.level;
        uint256 oldOwed = (uint256(p.principal) * oldAskBps) / BPS_DENOM - p.paid;
        uint256 newOwed = newTarget - p.paid;

        // Remove from the old level (tombstone if mid-queue).
        _removeFromLevel(oldLevel, p, oldOwed);

        p.askBps = newAskBps;
        p.level = uint32(newLevel);
        p.lastReprice = uint64(block.timestamp);
        totalOutstanding = totalOutstanding - oldOwed + newOwed;

        if (newOwed == 0) {
            // Repriced exactly down to what was already paid: position is done.
            p.filled = true;
            totalLivePrincipal -= p.principal;
            liveCount -= 1;
            emit Repriced(positionId, oldAskBps, newAskBps, oldLevel, newLevel);
            emit PositionCleared(positionId, p.owner, p.principal, p.paid);
            return;
        }

        // Append to the tail of the new level: time priority is forfeited.
        _enqueue(newLevel, positionId, p, p.principal, newOwed);

        emit Repriced(positionId, oldAskBps, newAskBps, oldLevel, newLevel);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // No exits
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice There is no cancel. This function exists so the absence is
    ///         auditable rather than implicit. It always reverts.
    function cancel(uint256) external pure {
        if (!CANCEL_ENABLED) revert CancelDisabled();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Payments
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Push with capped gas; on failure credit pendingWithdrawals and move
    ///      on. One griefing receiver must never brick the book.
    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount, gas: PAYOUT_GAS}("");
        if (!ok) {
            pendingWithdrawals[to] += amount;
            totalPending += amount;
            emit PendingCredited(to, amount);
        }
    }

    /// @notice Claim payouts that could not be pushed to you.
    function claimPending() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingPending();
        pendingWithdrawals[msg.sender] = 0;
        totalPending -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit PendingClaimed(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin — fee withdrawal only. Nothing else is privileged.
    // ─────────────────────────────────────────────────────────────────────────

    function withdrawProtocolFees(address to) external onlyOwner nonReentrant {
        uint256 amount = protocolFees;
        protocolFees = 0;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit ProtocolFeesWithdrawn(to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A slice of the book: up to `maxLevels` non-empty levels starting
    ///         at `fromLevel`, ascending.
    function bookSlice(uint256 fromLevel, uint256 maxLevels)
        external
        view
        returns (uint32[] memory askBps, uint256[] memory depthWei, uint256[] memory positionCounts)
    {
        askBps = new uint32[](maxLevels);
        depthWei = new uint256[](maxLevels);
        positionCounts = new uint256[](maxLevels);
        uint256 n = 0;
        if (fromLevel < NUM_LEVELS && maxLevels != 0) {
            uint256 startWord = fromLevel >> 8;
            for (uint256 w = startWord; w < NUM_BITMAP_WORDS && n < maxLevels; ++w) {
                uint256 word = levelBitmap[w];
                if (w == startWord) {
                    word &= ~((1 << (fromLevel & 0xff)) - 1);
                }
                while (word != 0 && n < maxLevels) {
                    uint256 b = _lsb(word);
                    uint256 lvl = (w << 8) | b;
                    Level storage L = levels[lvl];
                    askBps[n] = uint32(MIN_BPS + lvl * STEP_BPS);
                    depthWei[n] = L.principalDepth;
                    positionCounts[n] = L.count;
                    ++n;
                    word &= word - 1;
                }
            }
        }
        assembly {
            mstore(askBps, n)
            mstore(depthWei, n)
            mstore(positionCounts, n)
        }
    }

    /// @notice Exact wei of fills required before this position starts paying:
    ///         everything owed strictly ahead of it, minus the current carry.
    function distanceToFill(uint256 positionId) external view returns (uint256 weiRequired) {
        Position storage p = positions[positionId];
        if (p.owner == address(0)) revert NoSuchPosition(positionId);
        if (p.filled) return 0;

        uint256 ahead = 0;
        uint256 myLevel = p.level;

        // All owed at levels strictly below mine.
        uint256 targetWord = myLevel >> 8;
        for (uint256 w = 0; w <= targetWord; ++w) {
            uint256 word = levelBitmap[w];
            if (w == targetWord) {
                word &= (1 << (myLevel & 0xff)) - 1;
            }
            while (word != 0) {
                uint256 b = _lsb(word);
                ahead += levels[(w << 8) | b].owedDepth;
                word &= word - 1;
            }
        }

        // Everything ahead of me in my own level's queue.
        Level storage L = levels[myLevel];
        uint256 myIndex = p.queueIndex;
        for (uint256 i = L.head; i < myIndex; ++i) {
            uint256 qid = levelQueue[myLevel][i];
            if (qid == 0) continue;
            Position storage q = positions[qid];
            ahead += (uint256(q.principal) * q.askBps) / BPS_DENOM - q.paid;
        }

        uint256 c = carry;
        return ahead > c ? ahead - c : 0;
    }

    /// @notice Position plus derived numbers. queueRank is the number of live
    ///         positions ahead of it within its own level (0 = front).
    function positionView(uint256 id)
        external
        view
        returns (Position memory p, uint256 owed, uint256 queueRank)
    {
        p = positions[id];
        if (p.owner == address(0)) revert NoSuchPosition(id);
        if (!p.filled) {
            owed = (uint256(p.principal) * p.askBps) / BPS_DENOM - p.paid;
            Level storage L = levels[p.level];
            for (uint256 i = L.head; i < p.queueIndex; ++i) {
                if (levelQueue[p.level][i] != 0) ++queueRank;
            }
        }
    }

    /// @notice tvl = live principal. outstanding = sum owed. Plus jackpot and live count.
    function stats()
        external
        view
        returns (uint256 tvl, uint256 outstanding, uint256 jackpotWei, uint256 liveCount_)
    {
        return (totalLivePrincipal, totalOutstanding, jackpot, liveCount);
    }

    /// @notice The main character: the front position at the highest non-empty
    ///         level (the oldest ask at the greediest price).
    function highestAsk() external view returns (uint256 positionId, uint32 askBps, uint256 owed) {
        for (uint256 w = NUM_BITMAP_WORDS; w > 0;) {
            unchecked {
                --w;
            }
            uint256 word = levelBitmap[w];
            if (word == 0) continue;
            uint256 lvl = (w << 8) | _msb(word);
            Level storage L = levels[lvl];
            uint256 h = L.head;
            uint256 id = levelQueue[lvl][h];
            while (id == 0) {
                unchecked {
                    ++h;
                }
                id = levelQueue[lvl][h];
            }
            Position storage p = positions[id];
            return (id, p.askBps, (uint256(p.principal) * p.askBps) / BPS_DENOM - p.paid);
        }
        return (0, 0, 0);
    }

    /// @notice All position ids ever created by `who`.
    function positionsOf(address who) external view returns (uint256[] memory) {
        return _positionsOf[who];
    }

    /// @notice Lowest non-empty level, for off-chain reads. found=false when empty.
    function lowestNonEmptyLevel() external view returns (uint256 level, bool found) {
        return _lowestNonEmptyLevel();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────

    function _validateAsk(uint32 askBps) private pure returns (uint256 level) {
        if (askBps < MIN_BPS || askBps > MAX_BPS) revert AskOutOfBounds(askBps);
        uint32 offset = askBps - MIN_BPS;
        if (offset % STEP_BPS != 0) revert AskNotAligned(askBps);
        return offset / STEP_BPS;
    }

    function _enqueue(uint256 level, uint256 id, Position storage p, uint128 principal, uint256 owed) private {
        Level storage L = levels[level];
        if (L.count == 0) {
            L.head = L.tail; // skip any tombstone garbage in O(1)
            _setBit(level);
        }
        uint64 t = L.tail;
        levelQueue[level][t] = id;
        p.queueIndex = t;
        unchecked {
            L.tail = t + 1;
            L.count += 1;
        }
        L.principalDepth += principal;
        L.owedDepth += uint128(owed);
    }

    /// @dev Remove a (live) position from its level for repricing. Mid-queue
    ///      removals leave a tombstone; head removals advance the head.
    function _removeFromLevel(uint256 level, Position storage p, uint256 owed) private {
        Level storage L = levels[level];
        uint256 idx = p.queueIndex;
        delete levelQueue[level][idx];
        unchecked {
            L.count -= 1;
        }
        L.principalDepth -= p.principal;
        L.owedDepth -= uint128(owed);
        if (L.count == 0) {
            L.head = L.tail;
            _clearBit(level);
        } else if (idx == L.head) {
            // Advance past tombstones now, on the repricer's gas.
            uint256 h = idx + 1;
            while (levelQueue[level][h] == 0) {
                unchecked {
                    ++h;
                }
            }
            L.head = uint64(h);
        }
    }

    function _bookIsEmpty() private view returns (bool) {
        for (uint256 w = 0; w < NUM_BITMAP_WORDS; ++w) {
            if (levelBitmap[w] != 0) return false;
        }
        return true;
    }

    function _lowestNonEmptyLevel() private view returns (uint256 level, bool found) {
        for (uint256 w = 0; w < NUM_BITMAP_WORDS; ++w) {
            uint256 word = levelBitmap[w];
            if (word != 0) {
                return ((w << 8) | _lsb(word), true);
            }
        }
        return (0, false);
    }

    function _setBit(uint256 level) private {
        levelBitmap[level >> 8] |= (1 << (level & 0xff));
    }

    function _clearBit(uint256 level) private {
        levelBitmap[level >> 8] &= ~(1 << (level & 0xff));
    }

    /// @dev Index of least significant set bit. w must be nonzero.
    function _lsb(uint256 w) private pure returns (uint256 r) {
        unchecked {
            if (w & type(uint128).max == 0) {
                r += 128;
                w >>= 128;
            }
            if (w & type(uint64).max == 0) {
                r += 64;
                w >>= 64;
            }
            if (w & type(uint32).max == 0) {
                r += 32;
                w >>= 32;
            }
            if (w & type(uint16).max == 0) {
                r += 16;
                w >>= 16;
            }
            if (w & type(uint8).max == 0) {
                r += 8;
                w >>= 8;
            }
            if (w & 0xf == 0) {
                r += 4;
                w >>= 4;
            }
            if (w & 0x3 == 0) {
                r += 2;
                w >>= 2;
            }
            if (w & 0x1 == 0) {
                r += 1;
            }
        }
    }

    /// @dev Index of most significant set bit. w must be nonzero.
    function _msb(uint256 w) private pure returns (uint256 r) {
        unchecked {
            if (w >> 128 != 0) {
                r += 128;
                w >>= 128;
            }
            if (w >> 64 != 0) {
                r += 64;
                w >>= 64;
            }
            if (w >> 32 != 0) {
                r += 32;
                w >>= 32;
            }
            if (w >> 16 != 0) {
                r += 16;
                w >>= 16;
            }
            if (w >> 8 != 0) {
                r += 8;
                w >>= 8;
            }
            if (w >> 4 != 0) {
                r += 4;
                w >>= 4;
            }
            if (w >> 2 != 0) {
                r += 2;
                w >>= 2;
            }
            if (w >> 1 != 0) {
                r += 1;
            }
        }
    }
}
