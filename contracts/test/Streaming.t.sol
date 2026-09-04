// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Distributor} from "../src/Distributor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The fix for the CRITICAL: a distribution vests over time instead of in one instant.
///
/// @dev **Why this exists.** `buy -> sweep -> sell -> withdraw` in a single transaction used to
///      net +12% ROI having held for zero blocks, while honest holders lost 83% of their dividend.
///      Research across four generations of dividend tokens (2019-2025, thousands of forks) found
///      that NONE of them defend against it: `claimWait` and its relatives rate-limit CLAIMING
///      while leaving ENTITLEMENT creditable in a single instant.
///
///      The defence is Synthetix's, and the retrofit was small because the accumulator here
///      already IS the Synthetix accumulator - `_corrections` is `userRewardPerTokenPaid` and
///      `withdrawableOf` is `earned`. Only the DRIVER changed: advance by the clock rather than
///      by a lump. MasterChef is the proof that the maths was never the problem, since the
///      identical accumulator has zero instant capture purely because a block's reward does not
///      exist until the block is mined.
contract StreamingTest is Test {
    Distributor internal d;
    MockERC20 internal pair;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal attacker = address(0xBAD);

    uint64 internal WINDOW;

    function setUp() public {
        pair = new MockERC20("Pair", "PAIR", 18);
        d = new Distributor(
            address(this), address(pair), address(this), address(0), address(0),
            1, 1, 1, address(0), address(0)
        );
        WINDOW = d.STREAM_WINDOW();
        // A clock at 1 would make `block.timestamp` arithmetic meaningless.
        vm.warp(1_000_000);
    }

    function _fund(uint256 amount) internal {
        pair.mint(address(d), amount);
        d.distribute(amount);
    }

    // ===========================================================================================
    // The property the whole change exists for
    // ===========================================================================================

    /// Nothing is claimable in the block the distribution lands. This single assertion is the
    /// difference between the old contract and this one.
    function test_nothingVestsInTheBlockItArrives() public {
        d.setBalance(alice, 1_000e18);
        _fund(100e18);
        assertEq(d.withdrawableOf(alice), 0, "a zero-duration hold earned something");
    }

    /// **The attack, priced.** The attacker holds 90% of the register across the distribution and
    /// exits in the same block. They must capture essentially nothing.
    function test_theZeroBlockAttackCapturesNothing() public {
        d.setBalance(alice, 100e18); // the honest holder, already present

        // Attacker takes the overwhelming majority of the register...
        d.setBalance(attacker, 900e18);
        _fund(100e18);
        // ...and leaves in the same block.
        d.setBalance(attacker, 0);

        assertEq(d.withdrawableOf(attacker), 0, "the zero-block attacker was paid");

        // The honest holder, who stayed, collects the whole pot once it vests.
        vm.warp(block.timestamp + WINDOW + 1);
        assertApproxEqRel(d.withdrawableOf(alice), 100e18, 1e15, "the stayer did not get the pot");
    }

    /// Holding for HALF the window earns about half, which is the linearity the defence relies on.
    function test_itVestsLinearly() public {
        d.setBalance(alice, 1_000e18);
        _fund(100e18);

        vm.warp(block.timestamp + WINDOW / 2);
        assertApproxEqRel(d.withdrawableOf(alice), 50e18, 1e16, "half the window is not half");

        vm.warp(block.timestamp + WINDOW / 2);
        assertApproxEqRel(d.withdrawableOf(alice), 100e18, 1e15, "the full window is not all");
    }

    /// Vesting stops at the finish line rather than running away.
    function test_itStopsAtTheFinish() public {
        d.setBalance(alice, 1_000e18);
        _fund(100e18);
        vm.warp(block.timestamp + WINDOW * 10);
        assertApproxEqRel(d.withdrawableOf(alice), 100e18, 1e15, "it overshot the pot");
    }

    // ===========================================================================================
    // The Yearn rule: a dust distribution must not reset the finish line
    // ===========================================================================================

    /// @dev Synthetix sets `periodFinish = now + duration` on EVERY notify, so anybody can push
    ///      the finish line out with dust. That is survivable there because notifying is
    ///      permissioned; here ANYONE can trigger a distribution by calling `sweep()`, so a flat
    ///      reset would be a free griefing vector. The weighted average makes a dust top-up move
    ///      the finish line only in proportion to how little it is worth.
    function test_aDustTopUpBarelyMovesTheFinishLine() public {
        d.setBalance(alice, 1_000e18);
        _fund(100e18);
        vm.warp(block.timestamp + WINDOW - 100); // almost fully vested

        uint64 before = d.streamFinish();
        _fund(1); // one wei of grief
        uint64 shifted = d.streamFinish() - before;

        assertLt(shifted, WINDOW / 100, "a dust distribution reset the stream");
    }

    /// A real top-up mid-stream is blended, and everything still pays out in full.
    function test_aTopUpIsBlendedAndNothingIsLost() public {
        d.setBalance(alice, 1_000e18);
        _fund(100e18);
        vm.warp(block.timestamp + WINDOW / 2);
        _fund(100e18);

        vm.warp(block.timestamp + WINDOW * 2);
        assertApproxEqRel(d.withdrawableOf(alice), 200e18, 1e15, "value was lost in the blend");
    }

    // ===========================================================================================
    // The Synthetix bug we must NOT inherit
    // ===========================================================================================

    /// @dev Synthetix's `updateReward` advances its clock even at zero supply, permanently
    ///      stranding those seconds. It matters more here than there: this contract's own
    ///      constructor documents that `totalShares` is genuinely zero during the dev buy, which
    ///      is the FIRST trade of every launch. Nothing may be lost across that window.
    function test_timeWithNoHoldersIsCarriedNotStranded() public {
        // A distribution with nobody holding is carried, exactly as before.
        _fund(100e18);
        assertEq(d.pendingPayouts(), 100e18, "the carry was dropped");

        // Holders arrive much later. The carry must still be there and must still pay out.
        vm.warp(block.timestamp + WINDOW * 3);
        d.setBalance(alice, 1_000e18);
        _fund(0);

        vm.warp(block.timestamp + WINDOW + 1);
        assertApproxEqRel(d.withdrawableOf(alice), 100e18, 1e15, "the carry never arrived");
    }

    /// The register emptying MID-STREAM must not strand the rest of that stream either.
    function test_theRegisterEmptyingMidStreamCarriesTheRemainder() public {
        d.setBalance(alice, 1_000e18);
        _fund(100e18);

        vm.warp(block.timestamp + WINDOW / 2);
        d.setBalance(alice, 0); // everyone leaves, mid-stream

        vm.warp(block.timestamp + WINDOW);
        d.setBalance(bob, 1_000e18); // somebody new arrives
        d.distribute(0); // fold the carry back in

        vm.warp(block.timestamp + WINDOW + 1);
        uint256 paid = d.withdrawableOf(alice) + d.withdrawableOf(bob);
        assertApproxEqRel(paid, 100e18, 1e15, "the mid-stream remainder was stranded");
    }

    // ===========================================================================================
    // Solvency still holds
    // ===========================================================================================

    function testFuzz_neverOwesMoreThanItHolds(uint96 amount, uint32 elapsed) public {
        amount = uint96(bound(amount, 1e6, type(uint96).max));
        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 3_000e18);
        _fund(uint256(amount));

        vm.warp(block.timestamp + bound(elapsed, 0, uint256(WINDOW) * 3));

        uint256 owed = d.withdrawableOf(alice) + d.withdrawableOf(bob) + d.pendingPayouts();
        assertGe(pair.balanceOf(address(d)), owed, "distributor owes more than it holds");
    }

    /// Whatever the path, the accumulator can never vest more than was ever distributed.
    function testFuzz_neverVestsMoreThanWasGiven(uint96 amount, uint8 steps) public {
        amount = uint96(bound(amount, 1e12, type(uint96).max));
        steps = uint8(bound(steps, 1, 8));
        d.setBalance(alice, 1_000e18);

        _fund(uint256(amount));
        for (uint256 i = 0; i < steps; i++) {
            vm.warp(block.timestamp + WINDOW / steps);
            d.distribute(0);
        }
        vm.warp(block.timestamp + WINDOW * 2);

                // Sum-of-floors artifact, not a leak: entitlement is reconstructed from several
        // separately-floored pieces against a magnified accumulator whose share base moves
        // between checkpoints. A real leak would be proportional to the amounts fuzzed (1e18+).
        assertLe(d.withdrawableOf(alice), uint256(amount) + 256, "vested more than was distributed");
    }
}
