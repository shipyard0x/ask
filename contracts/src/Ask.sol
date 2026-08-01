// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title ASK — hold it when the clock stops.
/// @notice Rounds. The opening ask costs 0.005 ETH. Every ask after that costs
///         10% more than the last. When you take it:
///
///           · the previous holder is paid back 105% of what they paid —
///             they leave +5%, immediately, guaranteed;
///           · the other 5% is skimmed into the pot;
///           · the clock gains 5 seconds, and never exceeds 60.
///
///         When the clock finally reaches zero, whoever is holding takes 50% of
///         the pot. 10% goes to the devs and 40% seeds the next round.
///
///         Everyone who gets taken out makes 5%. The person still holding when
///         the music stops takes the pile. The trade is a small certain gain
///         against a large uncertain one.
///
/// @dev    No proxy, no pause, no parameter setters. The only privileged action
///         is dev-fee withdrawal. Payouts push with capped gas and fall back to
///         a pull, so no receiving contract can stall the game.
contract Ask is Ownable, ReentrancyGuard {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Price of the opening ask in every round.
    uint256 public constant START_PRICE = 0.005 ether;
    /// @notice Each ask costs 10% more than the one before it.
    uint256 public constant PRICE_STEP_BPS = 1_000;
    /// @notice The previous holder is paid back this much of their own cost.
    ///         10500 = 105%, i.e. they exit +5%.
    uint256 public constant HOLDER_RETURN_BPS = 10_500;
    /// @notice The clock never exceeds this.
    uint64 public constant TIMER_MAX = 60 seconds;
    /// @notice Every take adds this much time, up to TIMER_MAX.
    uint64 public constant TIMER_BONUS = 5 seconds;

    /// @notice The holder at zero takes this share of the pot.
    uint256 public constant WINNER_SHARE_BPS = 5_000;
    /// @notice Dev share of the pot at round end.
    uint256 public constant DEV_SHARE_BPS = 1_000;
    // The remainder — 40% — seeds the next round.

    /// @notice Gas forwarded on push payouts. Failures credit pendingWithdrawals.
    uint256 public constant PAYOUT_GAS = 30_000;
    /// @notice There is no withdraw. This is the visible, auditable switch.
    bool public constant WITHDRAW_ENABLED = false;

    uint256 private constant BPS_DENOM = 10_000;

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Current round, starting at 1.
    uint256 public roundId = 1;
    /// @notice What the next ask costs, exactly.
    uint256 public price = START_PRICE;
    /// @notice Who is holding. address(0) = the round has not opened.
    address public holder;
    /// @notice What the holder paid. Drives their 105% exit if they're taken out.
    uint256 public holderPaid;
    /// @notice When the holder took it.
    uint64 public holderSince;
    /// @notice Clock expiry. The round can be settled after this.
    uint64 public deadline;
    /// @notice Hands so far this round: 1 = opener, 2 = second, and so on.
    uint64 public hop;
    /// @notice The prize. Grows by the 5% skim on every take.
    uint256 public pot;
    /// @notice Owner-withdrawable dev take.
    uint256 public devFees;

    /// @notice Payouts that could not be pushed.
    mapping(address => uint256) public pendingWithdrawals;
    /// @notice Sum of all pendingWithdrawals.
    uint256 public totalPending;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event Taken(
        uint256 indexed roundId,
        address indexed taker,
        uint256 pricePaid,
        address indexed flipped,
        uint256 flippedReturn,
        uint256 potAdded,
        uint256 heldSeconds,
        uint64 hop,
        uint64 deadline
    );
    event RoundWon(
        uint256 indexed roundId,
        address indexed winner,
        uint256 won,
        uint256 potAtEnd,
        uint64 hops,
        uint256 toDevs,
        uint256 toNextPot
    );
    event RoundStarted(uint256 indexed roundId, uint256 seed);
    event PendingCredited(address indexed owner, uint256 amount);
    event PendingClaimed(address indexed owner, uint256 amount);
    event DevFeesWithdrawn(address indexed to, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors — blunt, like the UI.
    // ─────────────────────────────────────────────────────────────────────────

    error WrongPrice(uint256 sent, uint256 required);
    error WrongRound(uint256 given, uint256 current);
    error AlreadyHolding();
    error RoundStillLive(uint256 secondsRemaining);
    error NoRoundToEnd();
    error NothingPending();
    error TransferFailed();

    constructor() Ownable(msg.sender) {
        emit RoundStarted(1, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Take it
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Take it. Pay exactly `price`. The holder you take it from is paid
    ///         105% of what they paid; the remaining 5% goes to the pot; the
    ///         clock gains 5 seconds and you are the one holding.
    /// @param  expectedRound The round you mean to join. If the clock ran out
    ///         between you signing and this landing, the round has moved on and
    ///         this reverts rather than opening a new round at a stale price.
    function take(uint256 expectedRound) external payable nonReentrant {
        // A finished round pays out before anything else can happen.
        if (holder != address(0) && block.timestamp > deadline) {
            _settle();
        }
        if (expectedRound != roundId) revert WrongRound(expectedRound, roundId);
        if (msg.value != price) revert WrongPrice(msg.value, price);
        if (msg.sender == holder) revert AlreadyHolding();

        address flipped = holder;
        uint256 flippedCost = holderPaid;
        uint256 held = flipped == address(0) ? 0 : block.timestamp - holderSince;

        uint256 flippedReturn;
        uint256 potAdded;
        if (flipped == address(0)) {
            // The opening ask: nobody to pay, so all of it becomes the pot.
            potAdded = msg.value;
            // An opening ask gets the full clock; +5s on an empty clock would
            // give the opener five seconds to find a taker.
            deadline = uint64(block.timestamp) + TIMER_MAX;
        } else {
            // 105% of their cost back to them; the rest of the step to the pot.
            flippedReturn = (flippedCost * HOLDER_RETURN_BPS) / BPS_DENOM;
            potAdded = msg.value - flippedReturn;
            // The clock gains 5s, and never exceeds a minute.
            uint64 remaining = deadline > block.timestamp ? deadline - uint64(block.timestamp) : 0;
            uint64 extended = remaining + TIMER_BONUS;
            if (extended > TIMER_MAX) extended = TIMER_MAX;
            deadline = uint64(block.timestamp) + extended;
        }

        holder = msg.sender;
        holderPaid = msg.value;
        holderSince = uint64(block.timestamp);
        hop += 1;
        pot += potAdded;
        price = (price * (BPS_DENOM + PRICE_STEP_BPS)) / BPS_DENOM;

        if (flippedReturn != 0) _send(flipped, flippedReturn);

        emit Taken(roundId, msg.sender, msg.value, flipped, flippedReturn, potAdded, held, hop, deadline);
    }

    /// @notice Settle a finished round and pay the winner. Anyone may call.
    function endRound() external nonReentrant {
        if (holder == address(0)) revert NoRoundToEnd();
        if (block.timestamp <= deadline) revert RoundStillLive(deadline - block.timestamp);
        _settle();
    }

    function _settle() private {
        uint256 potAtEnd = pot;
        uint256 toWinner = (potAtEnd * WINNER_SHARE_BPS) / BPS_DENOM;
        uint256 toDevs = (potAtEnd * DEV_SHARE_BPS) / BPS_DENOM;
        uint256 toNext = potAtEnd - toWinner - toDevs;

        address winner = holder;
        devFees += toDevs;

        emit RoundWon(roundId, winner, toWinner, potAtEnd, hop, toDevs, toNext);

        roundId += 1;
        price = START_PRICE;
        holder = address(0);
        holderPaid = 0;
        holderSince = 0;
        deadline = 0;
        hop = 0;
        pot = toNext;

        emit RoundStarted(roundId, toNext);

        if (toWinner != 0) _send(winner, toWinner);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Payments
    // ─────────────────────────────────────────────────────────────────────────

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount, gas: PAYOUT_GAS}("");
        if (!ok) {
            pendingWithdrawals[to] += amount;
            totalPending += amount;
            emit PendingCredited(to, amount);
        }
    }

    /// @notice Claim a payout that could not be pushed to you.
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
    // Admin — fee withdrawal only.
    // ─────────────────────────────────────────────────────────────────────────

    function withdrawDevFees(address to) external onlyOwner nonReentrant {
        uint256 amount = devFees;
        devFees = 0;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit DevFeesWithdrawn(to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Seconds left. 0 means the round is over and the next take (or
    ///         endRound) pays the holder.
    function timeLeft() public view returns (uint256) {
        if (holder == address(0)) return 0;
        return block.timestamp >= deadline ? 0 : deadline - block.timestamp;
    }

    /// @notice How long the current holder has been holding.
    function heldFor() public view returns (uint256) {
        if (holder == address(0)) return 0;
        return block.timestamp - holderSince;
    }

    /// @notice What the current holder takes if the clock runs out right now.
    function winnerTake() public view returns (uint256) {
        return (pot * WINNER_SHARE_BPS) / BPS_DENOM;
    }

    /// @notice What the current holder is paid if someone takes it from them.
    function holderExitValue() public view returns (uint256) {
        return (holderPaid * HOLDER_RETURN_BPS) / BPS_DENOM;
    }

    /// @notice Everything the page needs, in one call.
    function state()
        external
        view
        returns (
            uint256 round,
            uint256 currentPrice,
            address currentHolder,
            uint256 currentHolderPaid,
            uint256 secondsLeft,
            uint256 heldSeconds,
            uint256 potWei,
            uint256 winnerTakeWei,
            uint64 hops,
            bool expired
        )
    {
        return (
            roundId,
            price,
            holder,
            holderPaid,
            timeLeft(),
            heldFor(),
            pot,
            winnerTake(),
            hop,
            holder != address(0) && block.timestamp > deadline
        );
    }

    /// @notice What the ask will cost `n` takes from now.
    function priceAfter(uint256 n) external view returns (uint256 p) {
        p = price;
        for (uint256 i = 0; i < n; ++i) {
            p = (p * (BPS_DENOM + PRICE_STEP_BPS)) / BPS_DENOM;
        }
    }
}
