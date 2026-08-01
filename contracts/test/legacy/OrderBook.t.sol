// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {OrderBook} from "../../src/legacy/OrderBook.sol";

contract RevertingReceiver {
    OrderBook public immutable ask;
    bool public accept;

    constructor(OrderBook _ask) {
        ask = _ask;
    }

    function setAccept(bool v) external {
        accept = v;
    }

    function doDeposit(uint32 askBps) external payable returns (uint256) {
        return ask.deposit{value: msg.value}(askBps);
    }

    function doClaim() external {
        ask.claimPending();
    }

    receive() external payable {
        require(accept, "no thanks");
    }
}

contract OrderBookTest is Test {
    OrderBook ask;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address whale = makeAddr("whale");

    uint256 constant FEE_BPS = 250; // 150 protocol + 100 jackpot

    function setUp() public {
        ask = new OrderBook();
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
        vm.deal(whale, 10000 ether);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function net(uint256 grossWei) internal pure returns (uint256) {
        return grossWei - (grossWei * 150) / 10_000 - (grossWei * 100) / 10_000;
    }

    function owedOf(uint256 id) internal view returns (uint256) {
        (OrderBook.Position memory p, uint256 owed,) = ask.positionView(id);
        p; // silence
        return owed;
    }

    function pos(uint256 id) internal view returns (OrderBook.Position memory p) {
        (p,,) = ask.positionView(id);
    }

    /// Reference distance-to-fill computed independently from public state.
    function referenceDistance(uint256 id) internal view returns (uint256) {
        OrderBook.Position memory me = pos(id);
        require(!me.filled, "filled");
        uint256 ahead = 0;
        for (uint256 i = 1; i < ask.nextPositionId(); ++i) {
            if (i == id) continue;
            OrderBook.Position memory q = pos(i);
            if (q.filled) continue;
            bool isAhead = q.level < me.level || (q.level == me.level && q.queueIndex < me.queueIndex);
            if (isAhead) ahead += (uint256(q.principal) * q.askBps) / 10_000 - q.paid;
        }
        uint256 c = ask.carry();
        return ahead > c ? ahead - c : 0;
    }

    function assertAccounting() internal view {
        assertEq(
            address(ask).balance,
            ask.carry() + ask.jackpot() + ask.protocolFees() + ask.totalPending(),
            "balance identity broken"
        );
    }

    // ── validation ───────────────────────────────────────────────────────────

    function test_RevertWhen_DepositBelowMin() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.DepositTooSmall.selector, 0.004 ether, 0.005 ether));
        ask.deposit{value: 0.004 ether}(10_100);
    }

    function test_RevertWhen_AskBelowFloor() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.AskOutOfBounds.selector, uint32(10_000)));
        ask.deposit{value: 1 ether}(10_000);
    }

    function test_RevertWhen_AskAboveCeiling() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.AskOutOfBounds.selector, uint32(1_000_100)));
        ask.deposit{value: 1 ether}(1_000_100);
    }

    function test_RevertWhen_AskMisaligned() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.AskNotAligned.selector, uint32(10_150)));
        ask.deposit{value: 1 ether}(10_150);
    }

    function test_BoundaryAsksAccepted() public {
        vm.prank(alice);
        uint256 id1 = ask.deposit{value: 1 ether}(10_100); // 1.01x floor
        vm.prank(bob);
        uint256 id2 = ask.deposit{value: 1 ether}(1_000_000); // 100x ceiling
        assertEq(pos(id1).level, 0);
        assertEq(pos(id2).level, 9899);
        assertEq(ask.NUM_LEVELS(), 9900);
    }

    // ── deposit basics ───────────────────────────────────────────────────────

    function test_FirstDepositGoesToCarry() public {
        vm.prank(alice);
        uint256 id = ask.deposit{value: 1 ether}(10_100);
        assertEq(ask.carry(), net(1 ether), "carry = net deposit on empty book");
        assertEq(ask.protocolFees(), 0.015 ether);
        assertEq(ask.jackpot(), 0.01 ether);
        assertEq(owedOf(id), 1.01 ether);
        assertEq(ask.totalOutstanding(), 1.01 ether);
        assertEq(ask.totalLivePrincipal(), 1 ether);
        assertEq(ask.liveCount(), 1);
        assertAccounting();
    }

    function test_SecondDepositFillsFirst() public {
        vm.prank(alice);
        uint256 a = ask.deposit{value: 1 ether}(10_100); // owed 1.01
        uint256 aliceBefore = alice.balance;

        vm.prank(bob);
        ask.deposit{value: 1 ether}(20_000);
        // budget = net(1) + carry(net(1)) = 1.95 ether -> clears alice's 1.01.
        // Clearing alice empties the book, so she also wins the 0.02 jackpot.
        assertEq(alice.balance, aliceBefore + 1.01 ether + 0.02 ether, "alice paid in full + jackpot");
        assertEq(ask.jackpot(), 0);
        assertTrue(pos(a).filled);
        assertEq(ask.carry(), 1.95 ether - 1.01 ether);
        assertEq(ask.liveCount(), 1); // only bob remains
        assertAccounting();
    }

    function test_PartialFillKeepsHeadPriority() public {
        vm.prank(alice);
        uint256 a = ask.deposit{value: 1 ether}(20_000); // owed 2.0
        vm.prank(bob);
        uint256 b = ask.deposit{value: 1 ether}(20_000);
        // bob's budget 1.95 partially fills alice: paid 1.95, remaining 0.05
        assertEq(pos(a).paid, 1.95 ether);
        assertFalse(pos(a).filled);

        vm.prank(carol);
        ask.deposit{value: 1 ether}(20_000);
        // carol's budget 0.975: clears alice's 0.05, then partial-pays bob 0.925
        assertTrue(pos(a).filled);
        assertEq(pos(b).paid, 0.925 ether);
        assertFalse(pos(b).filled);
        assertAccounting();
    }

    function test_SelfFillImpossible() public {
        // A huge deposit into an empty book cannot touch its own position.
        vm.prank(whale);
        uint256 id = ask.deposit{value: 100 ether}(10_100);
        assertEq(pos(id).paid, 0);
        assertFalse(pos(id).filled);
        assertEq(ask.carry(), net(100 ether));
        assertAccounting();
    }

    function test_FifoWithinLevel() public {
        // Alice then bob at the same level; a filler must clear alice first.
        vm.prank(alice);
        uint256 a = ask.deposit{value: 1 ether}(50_000); // owed 5
        vm.prank(bob);
        uint256 b = ask.deposit{value: 1 ether}(50_000); // partially fills alice 1.95
        vm.prank(carol);
        ask.deposit{value: 1 ether}(50_000); // pays alice further 0.975
        assertEq(pos(a).paid, 2.925 ether);
        assertEq(pos(b).paid, 0);

        (, uint256 owedA, uint256 rankA) = ask.positionView(a);
        (,, uint256 rankB) = ask.positionView(b);
        assertEq(rankA, 0);
        assertEq(rankB, 1);
        owedA;
        assertAccounting();
    }

    // ── fill cap + gas ───────────────────────────────────────────────────────

    /// Builds a book of many small fully-fillable positions, then hits it with
    /// a whale deposit. Exactly MAX_FILLS_PER_TX positions may be touched.
    function _buildCrowdedBook() internal returns (uint256 sponge) {
        // Phase 1: a sponge at the floor absorbs every dust deposit's budget,
        // so the 30 dust positions above it stay completely unfilled.
        address spongeOwner = makeAddr("spongeOwner");
        vm.deal(spongeOwner, 100 ether);
        vm.prank(spongeOwner);
        sponge = ask.deposit{value: 50 ether}(10_100); // owed 50.5 ether
        for (uint256 i = 0; i < 30; ++i) {
            address actor = makeAddr(string(abi.encodePacked("dust", i)));
            vm.deal(actor, 1 ether);
            vm.prank(actor);
            ask.deposit{value: 0.005 ether}(uint32(10_200 + (i % 5) * 100)); // levels 1..5
        }
        // Phase 2: sponge reprices to the ceiling. The dust is now cheapest.
        vm.warp(block.timestamp + 61);
        vm.prank(spongeOwner);
        ask.reprice(sponge, 1_000_000);
    }

    function test_MaxFillsPerTxRespected() public {
        _buildCrowdedBook();
        uint256 liveBefore = ask.liveCount();

        vm.recordLogs();
        vm.prank(whale);
        ask.deposit{value: 10 ether}(1_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 fillEvents = 0;
        bytes32 filledSig = keccak256("Filled(uint256,address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == filledSig) ++fillEvents;
        }
        assertEq(fillEvents, ask.MAX_FILLS_PER_TX(), "fill loop must stop at cap");
        // Cap of 20 fills on a book of 30+ live positions: some remain.
        assertGt(ask.liveCount(), liveBefore - fillEvents);
        assertAccounting();
    }

    function test_GasDepositAtMaxFills() public {
        _buildCrowdedBook();
        vm.prank(whale);
        uint256 g0 = gasleft();
        ask.deposit{value: 10 ether}(1_000_000);
        uint256 used = g0 - gasleft();
        assertLt(used, 1_500_000, "MAX_FILLS deposit must stay under 1.5M gas");
        emit log_named_uint("gas used at MAX_FILLS_PER_TX", used);
    }

    // ── fill ordering (invariants 3 & 5, event-level) ───────────────────────

    function testFuzz_FillOrderStrict(uint256 seed) public {
        // Random small book.
        uint256 n = 5 + (seed % 12);
        for (uint256 i = 0; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address actor = makeAddr(string(abi.encodePacked("f", i)));
            vm.deal(actor, 100 ether);
            uint32 bps = uint32(10_100 + (seed % 200) * 100);
            uint256 val = 0.005 ether + (seed % 1 ether);
            vm.prank(actor);
            ask.deposit{value: val}(bps);
        }

        (uint256 lowestPre, bool anyPre) = ask.lowestNonEmptyLevel();

        vm.recordLogs();
        vm.prank(whale);
        uint256 newId = ask.deposit{value: 20 ether}(1_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 filledSig = keccak256("Filled(uint256,address,uint256,uint256)");
        uint256 prevLevel = 0;
        bool first = true;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != filledSig) continue;
            uint256 id = uint256(logs[i].topics[1]);
            // Invariant 5: a deposit can never fill its own position.
            assertTrue(id != newId, "self-fill");
            uint256 lvl = pos(id).level;
            if (first) {
                // Invariant 3: the first fill hits the lowest pre-existing level.
                assertTrue(anyPre, "fill with empty book");
                assertEq(lvl, lowestPre, "must start at lowest level");
                first = false;
            } else {
                assertGe(lvl, prevLevel, "fills must walk levels upward");
            }
            prevLevel = lvl;
        }
    }

    // ── reprice ──────────────────────────────────────────────────────────────

    function test_RevertWhen_RepriceDuringCooldown() public {
        vm.prank(alice);
        uint256 id = ask.deposit{value: 1 ether}(20_000);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.RepriceCooldown.selector, 60));
        ask.reprice(id, 30_000);
    }

    function test_RevertWhen_RepriceNotOwner() public {
        vm.prank(alice);
        uint256 id = ask.deposit{value: 1 ether}(20_000);
        vm.warp(block.timestamp + 61);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.NotYourPosition.selector, id));
        ask.reprice(id, 30_000);
    }

    function test_RepriceMovesLevelAndLosesPriority() public {
        vm.prank(alice);
        uint256 a = ask.deposit{value: 1 ether}(900_000); // level 8899, out of fill range
        vm.prank(bob);
        uint256 b = ask.deposit{value: 1 ether}(900_000);
        // alice is ahead of bob at 90x.
        (,, uint256 rankA) = ask.positionView(a);
        assertEq(rankA, 0);

        vm.warp(block.timestamp + 61);
        vm.prank(alice);
        ask.reprice(a, 900_000); // same level: still goes to the tail
        (,, uint256 rankA2) = ask.positionView(a);
        (,, uint256 rankB2) = ask.positionView(b);
        assertEq(rankB2, 0, "bob promoted to front");
        assertEq(rankA2, 1, "alice pays with time priority");

        vm.warp(block.timestamp + 61);
        vm.prank(alice);
        ask.reprice(a, 500_000);
        assertEq(pos(a).level, (500_000 - 10_100) / 100);
        assertEq(pos(a).askBps, 500_000);
        // alice already received 1.95 from bob's deposit: her owed is 50 - 1.95.
        assertEq(ask.totalOutstanding(), (50 ether - 1.95 ether) + 90 ether);
        assertAccounting();
    }

    function test_RepriceUpdatesBitmap() public {
        vm.prank(alice);
        uint256 id = ask.deposit{value: 1 ether}(500_000);
        (uint256 lvl, bool found) = ask.lowestNonEmptyLevel();
        assertTrue(found);
        assertEq(lvl, (500_000 - 10_100) / 100);

        vm.warp(block.timestamp + 61);
        vm.prank(alice);
        ask.reprice(id, 700_000);
        (uint256 lvl2,) = ask.lowestNonEmptyLevel();
        assertEq(lvl2, (700_000 - 10_100) / 100, "old bit cleared, new bit set");
    }

    function test_RevertWhen_RepriceBelowRealizedPayout() public {
        vm.prank(alice);
        uint256 a = ask.deposit{value: 1 ether}(20_000); // owed 2
        vm.prank(bob);
        ask.deposit{value: 1 ether}(20_000); // alice paid 1.95

        assertEq(pos(a).paid, 1.95 ether);
        vm.warp(block.timestamp + 61);
        vm.prank(alice);
        // 1.9x target = 1.9 ether < 1.95 already received.
        vm.expectRevert(abi.encodeWithSelector(OrderBook.AskBelowRealizedPayout.selector, uint32(19_000), 1.95 ether));
        ask.reprice(a, 19_000);
    }

    function test_RepriceToExactlyPaidClearsPosition() public {
        vm.prank(alice);
        uint256 a = ask.deposit{value: 1 ether}(20_000); // owed 2
        vm.prank(bob);
        ask.deposit{value: 1 ether}(20_000); // alice paid 1.95

        vm.warp(block.timestamp + 61);
        vm.prank(alice);
        ask.reprice(a, 19_500); // target 1.95 == paid -> done, owed 0
        assertTrue(pos(a).filled);
        assertEq(ask.liveCount(), 1);
        assertEq(ask.totalOutstanding(), 2 ether); // only bob's
        assertAccounting();
    }

    function test_RevertWhen_RepriceFilledPosition() public {
        vm.prank(alice);
        uint256 a = ask.deposit{value: 1 ether}(10_100);
        vm.prank(bob);
        ask.deposit{value: 2 ether}(20_000); // clears alice
        assertTrue(pos(a).filled);
        vm.warp(block.timestamp + 61);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.PositionAlreadyFilled.selector, a));
        ask.reprice(a, 20_000);
    }

    // ── no exits ─────────────────────────────────────────────────────────────

    function test_CancelAlwaysReverts() public {
        vm.expectRevert(OrderBook.CancelDisabled.selector);
        ask.cancel(1);
        assertFalse(ask.CANCEL_ENABLED());
    }

    // ── payments: push failure -> pending ────────────────────────────────────

    function test_GriefingReceiverCannotBrickBook() public {
        // Ceiling anchor keeps the book non-empty (no incidental jackpot).
        vm.prank(carol);
        ask.deposit{value: 0.05 ether}(1_000_000);

        RevertingReceiver griefer = new RevertingReceiver(ask);
        vm.deal(address(griefer), 10 ether);
        griefer.doDeposit{value: 1 ether}(10_100); // cheapest ask, receive() reverts

        vm.prank(bob);
        uint256 b = ask.deposit{value: 1 ether}(10_200);

        vm.prank(carol);
        ask.deposit{value: 2 ether}(20_000);
        // griefer's 1.01 could not be pushed: credited as pending; book moved on to bob.
        assertEq(ask.pendingWithdrawals(address(griefer)), 1.01 ether);
        assertEq(ask.totalPending(), 1.01 ether);
        assertGt(pos(b).paid, 0, "book advanced past the griefer");
        assertAccounting();

        // Claim fails while still reverting, succeeds once it accepts.
        vm.expectRevert(OrderBook.TransferFailed.selector);
        griefer.doClaim();
        griefer.setAccept(true);
        uint256 before = address(griefer).balance;
        griefer.doClaim();
        assertEq(address(griefer).balance, before + 1.01 ether);
        assertEq(ask.totalPending(), 0);
        assertAccounting();
    }

    // ── jackpot ──────────────────────────────────────────────────────────────

    function test_JackpotPaidOnBookClear() public {
        vm.prank(alice);
        uint256 a = ask.deposit{value: 1 ether}(10_100); // sole position, owed 1.01
        uint256 aliceBefore = alice.balance;

        vm.expectEmit(true, true, false, true);
        emit OrderBook.JackpotPaid(a, alice, 0.03 ether);
        vm.prank(bob);
        ask.deposit{value: 2 ether}(50_000);
        // Jackpot = 1% of 1 + 1% of 2 = 0.03. Book emptied via alice's fill.
        assertEq(alice.balance, aliceBefore + 1.01 ether + 0.03 ether);
        assertEq(ask.jackpot(), 0);
        assertAccounting();
    }

    function test_NoJackpotWhenBookNotEmpty() public {
        // Ceiling anchor first so the book is never emptied by later fills.
        vm.prank(carol);
        ask.deposit{value: 0.05 ether}(1_000_000);
        vm.prank(alice);
        ask.deposit{value: 1 ether}(10_100);

        vm.prank(bob);
        ask.deposit{value: 2 ether}(50_000); // clears alice; carol's anchor remains
        assertGt(ask.jackpot(), 0, "jackpot keeps building while the book is non-empty");
        assertAccounting();
    }

    // ── admin ────────────────────────────────────────────────────────────────

    function test_WithdrawProtocolFees() public {
        vm.prank(alice);
        ask.deposit{value: 10 ether}(10_100);
        uint256 fees = ask.protocolFees();
        assertEq(fees, 0.15 ether);
        address to = makeAddr("treasury");
        ask.withdrawProtocolFees(to);
        assertEq(to.balance, fees);
        assertEq(ask.protocolFees(), 0);
        assertAccounting();
    }

    function test_RevertWhen_WithdrawFeesNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        ask.withdrawProtocolFees(alice);
    }

    // ── views ────────────────────────────────────────────────────────────────

    function test_DistanceToFillExact() public {
        vm.prank(alice);
        uint256 a = ask.deposit{value: 0.1 ether}(20_000);
        vm.prank(bob);
        uint256 b = ask.deposit{value: 0.1 ether}(20_000);
        vm.prank(carol);
        uint256 c = ask.deposit{value: 0.1 ether}(30_000);

        if (!pos(a).filled) assertEq(ask.distanceToFill(a), referenceDistance(a));
        if (!pos(b).filled) assertEq(ask.distanceToFill(b), referenceDistance(b));
        if (!pos(c).filled) assertEq(ask.distanceToFill(c), referenceDistance(c));
    }

    function testFuzz_DistanceToFillMatchesReference(uint256 seed) public {
        uint256 n = 4 + (seed % 10);
        for (uint256 i = 0; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address actor = makeAddr(string(abi.encodePacked("d", i)));
            vm.deal(actor, 10 ether);
            vm.prank(actor);
            ask.deposit{value: 0.005 ether + (seed % 0.5 ether)}(uint32(10_100 + (seed % 500) * 100));
        }
        for (uint256 id = 1; id < ask.nextPositionId(); ++id) {
            if (pos(id).filled) continue;
            assertEq(ask.distanceToFill(id), referenceDistance(id), "distanceToFill mismatch");
        }
    }

    function test_BookSliceAndHighestAsk() public {
        vm.prank(alice);
        ask.deposit{value: 1 ether}(500_000);
        vm.prank(bob);
        ask.deposit{value: 2 ether}(500_000);
        vm.prank(carol);
        uint256 c = ask.deposit{value: 0.5 ether}(1_000_000);

        (uint32[] memory bps, uint256[] memory depth, uint256[] memory counts) = ask.bookSlice(0, 50);
        assertEq(bps.length, 2, "two non-empty levels");
        assertEq(bps[0], 500_000);
        assertEq(depth[0], 3 ether);
        assertEq(counts[0], 2);
        assertEq(bps[1], 1_000_000);
        assertEq(counts[1], 1);

        (uint256 hid, uint32 hbps, uint256 howed) = ask.highestAsk();
        assertEq(hid, c);
        assertEq(hbps, 1_000_000);
        assertEq(howed, 50 ether);

        (uint256 tvl, uint256 outstanding, uint256 jp, uint256 live) = ask.stats();
        assertEq(tvl, 3.5 ether);
        assertEq(outstanding, ask.totalOutstanding());
        assertEq(jp, 0.035 ether);
        assertEq(live, 3);
    }

    function test_PositionsOf() public {
        vm.startPrank(alice);
        uint256 a1 = ask.deposit{value: 1 ether}(500_000);
        uint256 a2 = ask.deposit{value: 1 ether}(600_000);
        vm.stopPrank();
        uint256[] memory ids = ask.positionsOf(alice);
        assertEq(ids.length, 2);
        assertEq(ids[0], a1);
        assertEq(ids[1], a2);
    }

    // ── direct ETH rejection ─────────────────────────────────────────────────

    function test_PlainSendReverts() public {
        vm.prank(alice);
        (bool ok,) = address(ask).call{value: 1 ether}("");
        assertFalse(ok, "no receive function: plain sends must revert");
    }
}
