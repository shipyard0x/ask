// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {OrderBook} from "../../src/legacy/OrderBook.sol";

/// Economic simulation: 500 random actors, three phases.
///   Phase 1 GROWTH  — 1200 deposits, 15% reprice noise.
///   Phase 2 DECAY   — 300 shrinking deposits.
///   Phase 3 STOP    — inflow ends; only panic reprices downward.
/// The book must visibly collapse when inflow stops (no new fills are possible,
/// clear rate flatlines) and the collapse must be graceful: no reverts, no
/// stuck funds, the balance identity intact throughout.
contract EconSimTest is Test {
    OrderBook ask;
    uint256 constant NUM_ACTORS = 500;
    uint256 seed = 0xA5C;

    uint256 grossIn; // total wei deposited
    uint256 opCount;

    function setUp() public {
        ask = new OrderBook();
    }

    function _rand() internal returns (uint256) {
        seed = uint256(keccak256(abi.encode(seed)));
        return seed;
    }

    function _actor(uint256 r) internal pure returns (address) {
        return address(uint160(0xEC0_0000 + (r % NUM_ACTORS)));
    }

    /// Skewed ask distribution: 60% 1.01-2x, 30% 2-10x, 10% 10-100x.
    function _randomAsk(uint256 r) internal pure returns (uint32) {
        uint256 bucket = r % 100;
        uint256 level;
        if (bucket < 60) {
            level = (r >> 8) % 100; // 1.01x .. 2.00x
        } else if (bucket < 90) {
            level = 100 + ((r >> 8) % 800); // 2.01x .. 10.00x
        } else {
            level = 900 + ((r >> 8) % 9000); // 10.01x .. 100x
        }
        return uint32(10_100 + level * 100);
    }

    /// Skewed size distribution: 70% retail, 25% mid, 5% whale.
    function _randomValue(uint256 r) internal pure returns (uint256) {
        uint256 bucket = r % 100;
        if (bucket < 70) return 0.005 ether + ((r >> 8) % 0.5 ether);
        if (bucket < 95) return 0.5 ether + ((r >> 8) % 1.5 ether);
        return 2 ether + ((r >> 8) % 18 ether);
    }

    function _deposit(uint256 value, uint32 bps) internal {
        address actor = _actor(_rand());
        vm.deal(actor, value);
        vm.prank(actor);
        ask.deposit{value: value}(bps);
        grossIn += value;
        ++opCount;
        vm.warp(block.timestamp + 1 + (_rand() % 120));
    }

    /// Panic reprice: a random live position undercuts toward the floor.
    function _panicReprice() internal {
        uint256 next = ask.nextPositionId();
        if (next < 2) return;
        uint256 id = 1 + (_rand() % (next - 1));
        (OrderBook.Position memory p,,) = ask.positionView(id);
        if (p.filled) return;
        if (block.timestamp < uint256(p.lastReprice) + 61) {
            vm.warp(uint256(p.lastReprice) + 61);
        }
        uint256 newLevel = uint256(p.level) / 2; // halve the greed
        uint32 bps = uint32(10_100 + newLevel * 100);
        if ((uint256(p.principal) * bps) / 10_000 < p.paid) return;
        vm.prank(p.owner);
        ask.reprice(id, bps);
        ++opCount;
        vm.warp(block.timestamp + 1 + (_rand() % 120));
    }

    function _clearedCount() internal view returns (uint256 cleared) {
        uint256 next = ask.nextPositionId();
        for (uint256 i = 1; i < next; ++i) {
            (OrderBook.Position memory p,,) = ask.positionView(i);
            if (p.filled) ++cleared;
        }
    }

    function _logState(string memory phase) internal view {
        (uint256 tvl, uint256 outstanding, uint256 jp, uint256 live) = ask.stats();
        console2.log(string.concat("[", phase, "] op"), opCount);
        console2.log("  live positions   ", live);
        console2.log("  book outstanding (wei)", outstanding);
        console2.log("  live principal (wei)  ", tvl);
        console2.log("  carry (wei)      ", ask.carry());
        console2.log("  jackpot (wei)    ", jp);
        console2.log("  cleared total    ", _clearedCount());
    }

    function _assertIdentity() internal view {
        assertEq(
            address(ask).balance,
            ask.carry() + ask.jackpot() + ask.protocolFees() + ask.totalPending(),
            "balance identity broken mid-sim"
        );
    }

    function test_EconomicSimulation() public {
        // ── Phase 1: growth ──────────────────────────────────────────────────
        for (uint256 i = 0; i < 1200; ++i) {
            uint256 r = _rand();
            if (r % 100 < 15) {
                _panicReprice();
            } else {
                _deposit(_randomValue(_rand()), _randomAsk(_rand()));
            }
            if (opCount % 200 == 0) _logState("GROWTH");
        }
        _assertIdentity();
        uint256 clearedAfterGrowth = _clearedCount();
        _logState("GROWTH END");

        // ── Phase 2: decay — inflow shrinks 10x ──────────────────────────────
        for (uint256 i = 0; i < 300; ++i) {
            uint256 r = _rand();
            if (r % 100 < 25) {
                _panicReprice();
            } else {
                _deposit(0.005 ether + (_rand() % 0.05 ether), _randomAsk(_rand()));
            }
            if (opCount % 100 == 0) _logState("DECAY");
        }
        _assertIdentity();
        uint256 clearedAfterDecay = _clearedCount();
        _logState("DECAY END");

        // ── Phase 3: inflow stops. Only panic repricing remains. ─────────────
        for (uint256 i = 0; i < 200; ++i) {
            _panicReprice();
        }
        _logState("STOPPED");

        // ── The collapse must be graceful. ───────────────────────────────────

        // 1. No new fills once inflow stopped: fills only happen inside deposit.
        assertEq(_clearedCount(), clearedAfterDecay, "positions cleared without inflow");

        // 2. Growth phase actually cleared positions (the machine worked).
        assertGt(clearedAfterGrowth, 0, "no clears during growth");

        // 3. The book is left holding the bag: outstanding claims exceed reserves.
        assertGt(
            ask.totalOutstanding(),
            address(ask).balance,
            "a ponzi that can pay everyone is not a ponzi"
        );
        assertGt(ask.liveCount(), 0, "someone must be left waiting");

        // 4. No stuck funds: every wei is attributed.
        _assertIdentity();

        // 5. Every filled position was paid exactly its (final) target.
        uint256 next = ask.nextPositionId();
        uint256 sumOwed = 0;
        for (uint256 i = 1; i < next; ++i) {
            (OrderBook.Position memory p, uint256 owed,) = ask.positionView(i);
            if (p.filled) {
                assertEq(p.paid, (uint256(p.principal) * p.askBps) / 10_000, "filled short");
            } else {
                assertLe(p.paid, (uint256(p.principal) * p.askBps) / 10_000, "overpaid");
                sumOwed += owed;
            }
        }
        assertEq(sumOwed, ask.totalOutstanding(), "outstanding drift after full sim");

        // 6. Conservation: everything deposited either left as payouts/fees or
        //    is still inside, and inside == carry + jackpot + fees + pending.
        assertLe(address(ask).balance, grossIn, "balance exceeds inflow");

        console2.log("---- FINAL ----");
        console2.log("gross inflow (wei)     ", grossIn);
        console2.log("contract balance (wei) ", address(ask).balance);
        console2.log("outstanding claims(wei)", ask.totalOutstanding());
        console2.log(
            "unbacked claims (wei)  ", ask.totalOutstanding() - address(ask).balance
        );
    }
}
