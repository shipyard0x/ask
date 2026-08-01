// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ask} from "../src/Ask.sol";

contract GriefingHolder {
    Ask public immutable ask;
    bool public accept;

    constructor(Ask _a) {
        ask = _a;
    }

    function setAccept(bool v) external {
        accept = v;
    }

    function doTake(uint256 round) external payable {
        ask.take{value: msg.value}(round);
    }

    function doClaim() external {
        ask.claimPending();
    }

    receive() external payable {
        require(accept, "no");
    }
}

contract AskTest is Test {
    Ask ask;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        ask = new Ask();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    function assertIdentity() internal view {
        assertEq(
            address(ask).balance,
            ask.pot() + ask.devFees() + ask.totalPending(),
            "balance identity broken"
        );
    }

    // ── opening ──────────────────────────────────────────────────────────────

    function test_InitialState() public view {
        assertEq(ask.roundId(), 1);
        assertEq(ask.price(), 0.005 ether);
        assertEq(ask.holder(), address(0));
        assertEq(ask.pot(), 0);
        assertEq(ask.TIMER_MAX(), 60);
        assertEq(ask.TIMER_BONUS(), 5);
        assertFalse(ask.WITHDRAW_ENABLED());
    }

    function test_OpenerGetsFullClockAndSeedsPot() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        assertEq(ask.holder(), alice);
        assertEq(ask.pot(), 0.005 ether, "the opening ask is the pot");
        assertEq(ask.timeLeft(), 60, "opener gets the full minute, not +5s");
        assertEq(ask.price(), 0.0055 ether);
        assertEq(ask.hop(), 1);
        assertIdentity();
    }

    // ── the 5% / 5% split ────────────────────────────────────────────────────

    function test_FlippedHolderGetsExactly105Percent() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        uint256 before = alice.balance;
        uint256 potBefore = ask.pot();

        vm.prank(bob);
        ask.take{value: 0.0055 ether}(1);

        // alice paid 0.005, receives 105% = 0.00525, so +5% profit.
        assertEq(alice.balance, before + 0.00525 ether, "105% back to the flipped holder");
        assertEq(alice.balance - before - 0.005 ether, 0.00025 ether, "+5% on 0.005");
        // The pot takes the rest of bob's payment: 0.0055 - 0.00525.
        assertEq(ask.pot(), potBefore + 0.00025 ether, "5% skim to the pot");
        assertIdentity();
    }

    function test_HolderExitValueMatchesWhatTheyGet() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        uint256 quoted = ask.holderExitValue();
        uint256 before = alice.balance;
        vm.prank(bob);
        ask.take{value: 0.0055 ether}(1);
        assertEq(alice.balance, before + quoted, "holderExitValue must be exact");
    }

    function test_PotGrowsFivePercentEachHand() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1); // pot = 0.005
        vm.prank(bob);
        ask.take{value: 0.0055 ether}(1); // + 0.00025
        vm.prank(carol);
        ask.take{value: 0.00605 ether}(1); // + 5% of 0.0055 = 0.000275
        assertEq(ask.pot(), 0.005 ether + 0.00025 ether + 0.000275 ether);
        assertIdentity();
    }

    function test_PriceLadder() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        vm.prank(bob);
        ask.take{value: 0.0055 ether}(1);
        assertEq(ask.price(), 0.00605 ether);
        assertEq(ask.priceAfter(1), 0.006655 ether);
    }

    function test_RevertWhen_WrongPrice() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ask.WrongPrice.selector, 0.004 ether, 0.005 ether));
        ask.take{value: 0.004 ether}(1);
    }

    function test_RevertWhen_WrongRound() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ask.WrongRound.selector, 2, 1));
        ask.take{value: 0.005 ether}(2);
    }

    function test_RevertWhen_TakingFromYourself() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        vm.prank(alice);
        vm.expectRevert(Ask.AlreadyHolding.selector);
        ask.take{value: 0.0055 ether}(1);
    }

    // ── the clock ────────────────────────────────────────────────────────────

    function test_TakeAddsFiveSecondsNotAFullReset() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        vm.warp(block.timestamp + 40); // 20s left
        assertEq(ask.timeLeft(), 20);

        vm.prank(bob);
        ask.take{value: 0.0055 ether}(1);
        assertEq(ask.timeLeft(), 25, "20 + 5, not back to 60");
    }

    function test_ClockCapsAtSixtySeconds() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        assertEq(ask.timeLeft(), 60);

        // Rapid-fire takes cannot push the clock past a minute.
        address[3] memory who = [bob, carol, alice];
        uint256[3] memory pay = [uint256(0.0055 ether), 0.00605 ether, 0.006655 ether];
        for (uint256 i = 0; i < 3; ++i) {
            vm.warp(block.timestamp + 1);
            vm.prank(who[i]);
            ask.take{value: pay[i]}(1);
            assertLe(ask.timeLeft(), 60, "clock must never exceed the cap");
        }
        assertEq(ask.timeLeft(), 60);
    }

    function test_ClockDrainsWhenNobodyTakes() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        vm.warp(block.timestamp + 30);
        vm.prank(bob);
        ask.take{value: 0.0055 ether}(1);
        assertEq(ask.timeLeft(), 35);
        vm.warp(block.timestamp + 34);
        assertEq(ask.timeLeft(), 1, "the clock really does run out");
        vm.warp(block.timestamp + 2);
        assertEq(ask.timeLeft(), 0);
    }

    function test_RevertWhen_EndRoundWhileLive() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        vm.warp(block.timestamp + 30);
        vm.expectRevert(abi.encodeWithSelector(Ask.RoundStillLive.selector, 30));
        ask.endRound();
    }

    function test_RevertWhen_EndRoundWithNoRound() public {
        vm.expectRevert(Ask.NoRoundToEnd.selector);
        ask.endRound();
    }

    // ── winning ──────────────────────────────────────────────────────────────

    function test_HolderAtZeroTakesHalfThePot() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        vm.prank(bob);
        ask.take{value: 0.0055 ether}(1); // bob holds; pot = 0.00525

        uint256 potAtEnd = ask.pot();
        assertEq(potAtEnd, 0.00525 ether);
        uint256 expectWin = (potAtEnd * 5000) / 10_000;
        uint256 expectDev = (potAtEnd * 1000) / 10_000;
        uint256 expectNext = potAtEnd - expectWin - expectDev;
        assertEq(ask.winnerTake(), expectWin, "winnerTake must quote the real payout");

        uint256 bobBefore = bob.balance;
        vm.warp(block.timestamp + 61);

        vm.expectEmit(true, true, false, true);
        emit Ask.RoundWon(1, bob, expectWin, potAtEnd, 2, expectDev, expectNext);
        ask.endRound();

        assertEq(bob.balance, bobBefore + expectWin, "the last holder is paid");
        assertEq(ask.devFees(), expectDev, "10% devs");
        assertEq(ask.pot(), expectNext, "40% seeds the next round");
        assertEq(ask.roundId(), 2);
        assertEq(ask.price(), 0.005 ether);
        assertEq(ask.holder(), address(0));
        assertEq(ask.hop(), 0);
        assertIdentity();
    }

    function test_OpenerCanWinAlone() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        uint256 before = alice.balance;
        vm.warp(block.timestamp + 61);
        ask.endRound();
        // Pot was 0.005: alice takes 50% = 0.0025 back. She paid 0.005, so a
        // solo round is a loss — someone has to take it from you to profit.
        assertEq(alice.balance, before + 0.0025 ether);
        assertEq(ask.devFees(), 0.0005 ether);
        assertEq(ask.pot(), 0.002 ether);
        assertIdentity();
    }

    function test_TakeAfterExpirySettlesAndOpensNextRound() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        uint256 aliceBefore = alice.balance;
        vm.warp(block.timestamp + 61);

        // The finished round's id is gone: a stale signature cannot land.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ask.WrongRound.selector, 1, 2));
        ask.take{value: 0.005 ether}(1);

        vm.prank(bob);
        ask.take{value: 0.005 ether}(2);
        // alice was paid her winnings during the lazy settle.
        assertEq(alice.balance, aliceBefore + 0.0025 ether);
        assertEq(ask.roundId(), 2);
        assertEq(ask.holder(), bob);
        assertEq(ask.pot(), 0.002 ether + 0.005 ether, "rolled seed + new opening ask");
        assertIdentity();
    }

    function test_PotCompoundsAcrossRounds() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        vm.warp(block.timestamp + 61);
        ask.endRound(); // pot 0.005 -> next 0.002, devs 0.0005

        vm.prank(bob);
        ask.take{value: 0.005 ether}(2); // pot = 0.002 + 0.005 = 0.007
        assertEq(ask.pot(), 0.007 ether);
        vm.warp(block.timestamp + 61);
        ask.endRound();
        assertEq(ask.pot(), 0.007 ether - 0.0035 ether - 0.0007 ether);
        assertEq(ask.devFees(), 0.0005 ether + 0.0007 ether);
        assertIdentity();
    }

    // ── payments ─────────────────────────────────────────────────────────────

    function test_GriefingHolderCannotStallTheGame() public {
        GriefingHolder g = new GriefingHolder(ask);
        vm.deal(address(g), 1 ether);
        g.doTake{value: 0.005 ether}(1);

        vm.prank(bob);
        ask.take{value: 0.0055 ether}(1); // push to g fails -> pending

        assertEq(ask.pendingWithdrawals(address(g)), 0.00525 ether);
        assertEq(ask.holder(), bob, "the game moved on");
        assertIdentity();

        vm.expectRevert(Ask.TransferFailed.selector);
        g.doClaim();
        g.setAccept(true);
        uint256 before = address(g).balance;
        g.doClaim();
        assertEq(address(g).balance, before + 0.00525 ether);
        assertEq(ask.totalPending(), 0);
        assertIdentity();
    }

    function test_GriefingWinnerGetsPendingCredit() public {
        GriefingHolder g = new GriefingHolder(ask);
        vm.deal(address(g), 1 ether);
        g.doTake{value: 0.005 ether}(1); // g holds and will win
        vm.warp(block.timestamp + 61);
        ask.endRound();
        assertEq(ask.pendingWithdrawals(address(g)), 0.0025 ether, "winnings held for pull");
        assertIdentity();
    }

    function test_WithdrawDevFeesOwnerOnly() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        vm.warp(block.timestamp + 61);
        ask.endRound();

        vm.prank(alice);
        vm.expectRevert();
        ask.withdrawDevFees(alice);

        address treasury = makeAddr("treasury");
        ask.withdrawDevFees(treasury);
        assertEq(treasury.balance, 0.0005 ether);
        assertEq(ask.devFees(), 0);
        assertIdentity();
    }

    // ── views ────────────────────────────────────────────────────────────────

    function test_StateView() public {
        vm.prank(alice);
        ask.take{value: 0.005 ether}(1);
        vm.warp(block.timestamp + 15);

        (
            uint256 round,
            uint256 p,
            address h,
            uint256 paid,
            uint256 left,
            uint256 held,
            uint256 potWei,
            uint256 take_,
            uint64 hops,
            bool expired
        ) = ask.state();
        assertEq(round, 1);
        assertEq(p, 0.0055 ether);
        assertEq(h, alice);
        assertEq(paid, 0.005 ether);
        assertEq(left, 45);
        assertEq(held, 15);
        assertEq(potWei, 0.005 ether);
        assertEq(take_, 0.0025 ether);
        assertEq(hops, 1);
        assertFalse(expired);

        vm.warp(block.timestamp + 61);
        (,,,, left,,,,, expired) = ask.state();
        assertEq(left, 0);
        assertTrue(expired);
    }

    // ── a full round ─────────────────────────────────────────────────────────

    function test_LongChainThenSomebodyWins() public {
        address[8] memory players = [
            alice, bob, carol, makeAddr("d"), makeAddr("e"), makeAddr("f"), makeAddr("g"), makeAddr("h")
        ];
        for (uint256 i = 0; i < players.length; ++i) vm.deal(players[i], 100 ether);

        for (uint256 i = 0; i < 24; ++i) {
            address who = players[i % players.length];
            uint256 p = ask.price();
            address prev = ask.holder();
            uint256 before = prev == address(0) ? 0 : prev.balance;
            uint256 quoted = ask.holderExitValue();
            vm.warp(block.timestamp + 3);
            vm.prank(who);
            ask.take{value: p}(1);
            if (prev != address(0)) assertEq(prev.balance, before + quoted, "flip must pay 105%");
            assertLe(ask.timeLeft(), 60);
            assertIdentity();
        }

        address winner = ask.holder();
        uint256 winnerBefore = winner.balance;
        uint256 expectWin = ask.winnerTake();
        vm.warp(block.timestamp + 61);
        ask.endRound();
        assertEq(winner.balance, winnerBefore + expectWin, "the survivor takes the pile");
        assertGt(expectWin, 0);
        assertIdentity();
    }

    // ── fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_TakesAndSettlements(uint256 seed) public {
        address[6] memory players = [alice, bob, carol, makeAddr("d"), makeAddr("e"), makeAddr("f")];
        for (uint256 i = 0; i < players.length; ++i) vm.deal(players[i], 1000 ether);

        for (uint256 op = 0; op < 50; ++op) {
            seed = uint256(keccak256(abi.encode(seed, op)));
            if (seed % 10 < 7) {
                address who = players[seed % players.length];
                (uint256 round, uint256 p,,,,,,,, bool expired) = ask.state();
                if (expired) {
                    round += 1;
                    p = 0.005 ether;
                }
                if (!expired && who == ask.holder()) continue;
                address prev = expired ? address(0) : ask.holder();
                uint256 before = prev == address(0) ? 0 : prev.balance;
                uint256 quoted = expired ? 0 : ask.holderExitValue();
                vm.prank(who);
                ask.take{value: p}(round);
                if (prev != address(0) && prev != who) {
                    assertEq(prev.balance, before + quoted, "flipped holder must get 105%");
                }
                assertLe(ask.timeLeft(), 60, "cap holds under fuzz");
                vm.warp(block.timestamp + 1 + (seed % 90));
            } else {
                vm.warp(block.timestamp + 61);
                if (ask.holder() != address(0)) ask.endRound();
            }
            assertIdentity();
        }
    }
}
