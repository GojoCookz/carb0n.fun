// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeHookHarness} from "../../FeeHook.t.sol";

/// @title SweepBountyGas
///
/// @notice The gas-indexed sweep bounty, finding C-2.
///
/// @dev **The failure this closes.** `SWEEP_BOUNTY_BPS` is a flat 0.5% of the pot, denominated in
///      the pair currency. The caller's cost is denominated in ETH and moves with `block.basefee`.
///      They are unrelated numbers, so during a gas spike the reward stops covering the cost,
///      nobody sweeps, and holders quietly stop being paid. Claims stay exact and `sweep` stays
///      open - nothing is lost - but the product stops working silently, which is the worst shape a
///      failure can take.
///
///      **The cap is the security property, not the scaling.** `block.basefee` is a protocol value
///      rather than a caller input, but it is influenceable: `sweep` is permissionless, so a caller
///      who can push gas up in the block they sweep in would otherwise scale their own payout
///      toward the entire pot. `SWEEP_BOUNTY_MAX_BPS` bounds that, and the tests below assert the
///      bound holds at an absurd basefee rather than merely at a plausible one.
abstract contract SweepBountyGasCases is FeeHookHarness {
    /// @dev Reference basefee in the contract. Below this the top-up must not engage at all.
    uint256 internal constant REFERENCE = 1 gwei;

    /// @dev NEGATIVE CONTROL, and it does real work here.
    ///
    ///      Every assertion below is about the bounty CHANGING with gas. If the bounty were
    ///      constant for some unrelated reason - a zero pot, a misread constant - the "does not
    ///      change below the reference" test would pass for the wrong reason and prove nothing.
    ///      This establishes the bounty is a live, non-zero number on the same path first.
    function test_control_theBountyIsANonZeroShareOfThePot() public view {
        uint256 pot = 100e18;
        uint256 expected = (pot * hook.SWEEP_BOUNTY_BPS()) / hook.BPS();
        assertGt(expected, 0, "control is vacuous: the flat bounty is zero, so nothing below means anything");
        assertEq(expected, 0.5e18, "0.5% of 100 is not 0.5 - the constant moved");
    }

    /// @dev On a normal day the behaviour must be EXACTLY what it always was. A change that alters
    ///      the common case would be a repricing of every existing pool, not a bug fix.
    function test_belowTheReferenceBasefeeTheBountyIsUnchanged() public {
        uint256 pot = 100e18;
        uint256 flat = (pot * hook.SWEEP_BOUNTY_BPS()) / hook.BPS();

        // Robinhood Chain sits near 0.3 gwei and Ethereum near 0.04 at the time of writing; both
        // are below the 1 gwei reference, so the top-up must never engage there.
        vm.fee(0.3 gwei);
        assertEq(hook.previewSweepBounty(pot), flat, "the top-up engaged below the reference basefee");

        vm.fee(0.04 gwei);
        assertEq(hook.previewSweepBounty(pot), flat, "the top-up engaged at Ethereum's current basefee");

        vm.fee(REFERENCE);
        assertEq(hook.previewSweepBounty(pot), flat, "the top-up engaged exactly AT the reference");
    }

    /// @dev The whole point: when gas runs away, the bounty follows it.
    function test_aboveTheReferenceTheBountyScalesWithGas() public {
        uint256 pot = 100e18;
        uint256 flat = (pot * hook.SWEEP_BOUNTY_BPS()) / hook.BPS();

        vm.fee(5 gwei);
        uint256 at5 = hook.previewSweepBounty(pot);
        assertGt(at5, flat, "the bounty did not respond to a 5x basefee - C-2 is still live");
        assertEq(at5, flat * 5, "the top-up is not linear in the basefee");

        vm.fee(20 gwei);
        uint256 at20 = hook.previewSweepBounty(pot);
        assertGt(at20, at5, "the bounty did not keep rising with gas");
    }

    /// @dev THE SECURITY BOUND. An absurd basefee must not hand over the pot.
    function test_theBountyIsCappedNoMatterHowHighGasGoes() public {
        uint256 pot = 100e18;
        uint256 ceiling = (pot * hook.SWEEP_BOUNTY_MAX_BPS()) / hook.BPS();

        vm.fee(10_000 gwei);
        assertEq(hook.previewSweepBounty(pot), ceiling, "the cap did not bind at an extreme basefee");

        // Deliberately absurd: a caller who can set the basefee arbitrarily still gets the cap and
        // not a wei more. Testing the plausible case only would leave the attack untested.
        vm.fee(type(uint64).max);
        assertEq(hook.previewSweepBounty(pot), ceiling, "the cap did not bind at an adversarial basefee");
        assertLt(ceiling, pot, "the ceiling is not strictly less than the pot - holders can be drained");
    }

    /// @dev The cap must be a share of the POT, so it scales with what is actually being swept
    ///      rather than being a fixed number that is trivial on a large pool and confiscatory on a
    ///      small one.
    /// @dev **The first version of this test overflowed in its OWN arithmetic, not the contract's.**
    ///      `hook.SWEEP_BOUNTY_MAX_BPS()` returns a `uint16`, so `1_000e18 * MAX_BPS` was evaluated
    ///      in uint16 space and panicked before the assertion ran. Both `previewSweepBounty` calls
    ///      had already returned correctly. Widening to uint256 first is the fix - worth recording
    ///      because a test that panics in its own expected-value calculation looks exactly like a
    ///      contract bug, and chasing it in the contract would have been chasing nothing.
    function test_theCapScalesWithThePotRatherThanBeingFixed() public {
        vm.fee(10_000 gwei);

        uint256 maxBps = uint256(hook.SWEEP_BOUNTY_MAX_BPS());
        uint256 bps = uint256(hook.BPS());

        uint256 small = hook.previewSweepBounty(1e18);
        uint256 large = hook.previewSweepBounty(1_000e18);

        assertEq(small, (uint256(1e18) * maxBps) / bps, "small pot cap is wrong");
        assertEq(large, (uint256(1_000e18) * maxBps) / bps, "large pot cap is wrong");
        assertGt(large, small, "the cap did not scale with the pot");
    }

    /// @dev A zero pot must yield a zero bounty at any gas price - no division surprises, and no
    ///      paying a caller out of a pot that does not exist.
    function test_anEmptyPotPaysNothingAtAnyGasPrice() public {
        vm.fee(10_000 gwei);
        assertEq(hook.previewSweepBounty(0), 0, "an empty pot paid a bounty");
    }
}

/// @dev Both orderings, per repo convention: which side the launch token sorts onto flips the sign
///      of every delta, and a bounty bug that only appears in one ordering would otherwise ship.
contract SweepBountyGasTokenIsCurrency0Test is SweepBountyGasCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract SweepBountyGasTokenIsCurrency1Test is SweepBountyGasCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}