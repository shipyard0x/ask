// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OrderBook} from "../../src/legacy/OrderBook.sol";

/// @dev An actor with code but no receive: every push to it fails, exercising
///      the pendingWithdrawals path continuously during invariant runs.
contract NoReceive {}

contract Handler is Test {
    OrderBook public immutable ask;
    address[] public actors;
    uint256[] public allIds;
    uint256[] public touchedLevels;
    mapping(uint256 => bool) internal levelTouched;

    constructor(OrderBook _ask) {
        ask = _ask;
        for (uint256 i = 0; i < 7; ++i) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
        actors.push(address(new NoReceive())); // the griefer
    }

    function idsLength() external view returns (uint256) {
        return allIds.length;
    }

    function touchedLength() external view returns (uint256) {
        return touchedLevels.length;
    }

    function _touch(uint256 level) internal {
        if (!levelTouched[level]) {
            levelTouched[level] = true;
            touchedLevels.push(level);
        }
    }

    function deposit(uint256 actorSeed, uint256 valueSeed, uint256 levelSeed) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 value = bound(valueSeed, 0.005 ether, 5 ether);
        uint256 level = bound(levelSeed, 0, ask.NUM_LEVELS() - 1);
        uint32 bps = uint32(10_100 + level * 100);
        vm.deal(actor, value);
        vm.prank(actor);
        uint256 id = ask.deposit{value: value}(bps);
        allIds.push(id);
        _touch(level);
        // Levels of everything below may have been drained; conservatively mark
        // all levels of known live positions as touched lazily via reprice/deposit only.
    }

    function reprice(uint256 idSeed, uint256 levelSeed, uint256 warpSeed) external {
        if (allIds.length == 0) return;
        uint256 id = allIds[bound(idSeed, 0, allIds.length - 1)];
        (OrderBook.Position memory p,,) = ask.positionView(id);
        if (p.filled) return;
        vm.warp(block.timestamp + bound(warpSeed, 61, 1 days));
        uint256 level = bound(levelSeed, 0, ask.NUM_LEVELS() - 1);
        uint32 bps = uint32(10_100 + level * 100);
        if ((uint256(p.principal) * bps) / 10_000 < p.paid) return; // would revert by design
        _touch(p.level);
        _touch(level);
        vm.prank(p.owner);
        ask.reprice(id, bps);
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 2)]; // skip griefer
        if (ask.pendingWithdrawals(actor) == 0) return;
        vm.prank(actor);
        ask.claimPending();
    }

    function warp(uint256 s) external {
        vm.warp(block.timestamp + bound(s, 1, 1 days));
    }
}

contract OrderBookInvariantTest is Test {
    OrderBook ask;
    Handler handler;

    function setUp() public {
        ask = new OrderBook();
        handler = new Handler(ask);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = Handler.deposit.selector;
        selectors[1] = Handler.reprice.selector;
        selectors[2] = Handler.claim.selector;
        selectors[3] = Handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// Invariant 1: the contract's balance is exactly the sum of its liabilities
    /// that are actually reserved. (Outstanding claims deliberately exceed it.)
    function invariant_BalanceIdentity() public view {
        assertEq(
            address(ask).balance,
            ask.carry() + ask.jackpot() + ask.protocolFees() + ask.totalPending(),
            "balance != carry + jackpot + protocolFees + pending"
        );
    }

    /// Invariant 2 + 7: no position is ever paid more than principal*ask/1e4,
    /// and paid never exceeds the (possibly repriced) target.
    function invariant_NoOverpay() public view {
        uint256 n = handler.idsLength();
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = handler.allIds(i);
            (OrderBook.Position memory p,,) = ask.positionView(id);
            assertLe(p.paid, (uint256(p.principal) * p.askBps) / 10_000, "overpaid");
            if (p.filled) {
                assertEq(p.paid, (uint256(p.principal) * p.askBps) / 10_000, "filled but not fully paid");
            }
        }
    }

    /// Invariant 4: totalOutstanding, totalLivePrincipal, liveCount all equal
    /// their recomputed ground truths.
    function invariant_AggregatesMatch() public view {
        uint256 n = handler.idsLength();
        uint256 sumOwed = 0;
        uint256 sumPrincipal = 0;
        uint256 live = 0;
        for (uint256 i = 0; i < n; ++i) {
            uint256 id = handler.allIds(i);
            (OrderBook.Position memory p, uint256 owed,) = ask.positionView(id);
            if (p.filled) continue;
            sumOwed += owed;
            sumPrincipal += p.principal;
            ++live;
        }
        assertEq(ask.totalOutstanding(), sumOwed, "totalOutstanding drift");
        assertEq(ask.totalLivePrincipal(), sumPrincipal, "totalLivePrincipal drift");
        assertEq(ask.liveCount(), live, "liveCount drift");
    }

    /// Invariant 6: a bitmap bit is set iff that level has >= 1 live position,
    /// and the stored per-level count matches a recount.
    function invariant_BitmapTruth() public view {
        uint256 t = handler.touchedLength();
        uint256 n = handler.idsLength();
        for (uint256 j = 0; j < t; ++j) {
            uint256 level = handler.touchedLevels(j);
            (,, uint64 count,,) = ask.levels(level);
            bool bit = (ask.levelBitmap(level >> 8) >> (level & 0xff)) & 1 == 1;
            assertEq(bit, count > 0, "bitmap bit disagrees with count");

            uint256 recount = 0;
            for (uint256 i = 0; i < n; ++i) {
                (OrderBook.Position memory p,,) = ask.positionView(handler.allIds(i));
                if (!p.filled && p.level == level) ++recount;
            }
            assertEq(uint256(count), recount, "level count drift");
        }
    }

    /// The queue ordering the fill loop relies on: within a level, live
    /// positions have strictly increasing queueIndex >= head, < tail.
    function invariant_QueueBounds() public view {
        uint256 n = handler.idsLength();
        for (uint256 i = 0; i < n; ++i) {
            (OrderBook.Position memory p,,) = ask.positionView(handler.allIds(i));
            if (p.filled) continue;
            (uint64 head, uint64 tail,,,) = ask.levels(p.level);
            assertGe(p.queueIndex, head, "live position behind head");
            assertLt(p.queueIndex, tail, "live position past tail");
            assertEq(ask.levelQueue(p.level, p.queueIndex), handler.allIds(i), "queue slot mismatch");
        }
    }
}
