// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HookAuditWorld} from "../HookAudit.t.sol";
import {Distributor} from "../../../src/Distributor.sol";
import {LaunchToken} from "../../../src/LaunchToken.sol";
import {Launcher} from "../../../src/Launcher.sol";

/// @title Sweep economics and swap-path gas
///
/// @notice The measurement suite behind `audit/11-sweep-remediation.md`.
///
/// @dev It exists to answer three questions with numbers rather than reasoning, and it is written
///      so the SAME file compiles and runs both before and against the build that deletes the
///      automatic sweep. Nothing here names `autoSweepThreshold`, `autoRedeem` or
///      `AutoSweepSkipped`, so the before/after readings are produced by identical test code and
///      the delta is a property of `src/`, not of the harness.
///
///      1. **What does a swap cost, by shape?** The auto path was reachable only from an
///         exact-OUTPUT buy, so that is where any gas saving has to show up. An exact-INPUT buy —
///         the shape every router, aggregator and swap UI sends — never reached it, so its number
///         is the control: it must not move.
///
///      2. **At what pot size is `sweep()` profitable at 20 gwei?** If nobody is paid to sweep,
///         dividends never move and deleting the auto path replaces one bug with a worse one.
///         The bounty is `SWEEP_BOUNTY_BPS` of what survives the burn wedge, so the break-even pot
///         is `sweepGas * gasPrice * BPS / SWEEP_BOUNTY_BPS`, and it is asserted from BOTH sides:
///         profitable at 2x it, under water at 0.5x it.
///
///      3. **Is the push path worth a keeper's gas?** `processBatch` pays NO bounty at all. That
///         number is here so the answer is on the record rather than assumed.
///
///      **UNIT WARNING, and it governs how every number below should be read.** The bounty is paid
///      in the POOL'S PAIR CURRENCY and the gas is paid in ETH. The break-even figures are
///      therefore denominated in pair units, and they are directly comparable to a gas bill only
///      on a WETH-paired launch. On a PEPE- or WXMR-paired launch a keeper has to price the pair
///      currency in ETH itself, and a pair currency that is illiquid or unpriceable is one no bot
///      will sweep. That is a real operational risk of the pull-only model and it is not
///      measurable from inside this repo.
abstract contract SweepEconomicsCases is HookAuditWorld {
    using PoolIdLibrary for PoolKey;

    /// @dev The gas price every break-even figure in this file is quoted at.
    uint256 internal constant GAS_PRICE = 20 gwei;

    /// @dev A keeper that holds nothing and has never been paid. Deliberately fresh: the first
    ///      payout to it is a zero-to-nonzero `SSTORE` on the pair currency, which is the
    ///      pessimistic and realistic case for a bot's first job on a new pool.
    address internal keeper = address(0xC0FFEE);

    /// @dev A second keeper used for the steady-state reading, warmed by a prior payout.
    address internal keeperWarm = address(0xBEEF01);

    // ------------------------------------------------------------------------------------------
    // Instruments
    // ------------------------------------------------------------------------------------------

    /// @dev Gas for one swap through the Uniswap-supplied router, measured around the external
    ///      call only. `vm.prank` is outside the window and is identical in every build.
    function _gasSwap(PoolKey memory k, address who, bool zeroForOne, int256 amountSpecified)
        internal
        returns (uint256 used)
    {
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory s =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.prank(who);
        uint256 g0 = gasleft();
        swapRouter.swap(k, p, s, "");
        used = g0 - gasleft();
    }

    /// @dev Gas for one `sweep`, plus what the caller was actually paid for it.
    function _gasSweep(PoolKey memory k, address who)
        internal
        returns (uint256 used, uint256 bounty)
    {
        uint256 before = pair.balanceOf(who);
        vm.prank(who);
        uint256 g0 = gasleft();
        hook.sweep(k);
        used = g0 - gasleft();
        bounty = pair.balanceOf(who) - before;
    }

    /// @dev The pot size at which a bounty exactly covers `gasUsed` at 20 gwei, in pair units.
    ///      `bounty = pot * SWEEP_BOUNTY_BPS / BPS`, so break-even is the inverse of that.
    function _breakEvenPot(uint256 gasUsed) internal view returns (uint256) {
        return (gasUsed * GAS_PRICE * hook.BPS()) / hook.SWEEP_BOUNTY_BPS();
    }

    /// @dev Buy hard enough to leave `wantPot` pair of fee behind, at the default 300 bps.
    ///      The fee is taken out of the input, so `pot == in * feeBps / BPS`.
    function _buyForPot(PoolKey memory k, address who, uint256 wantPot) internal {
        uint256 amountIn = (wantPot * hook.BPS()) / 300;
        _buyExactIn(k, who, amountIn);
    }

    // ------------------------------------------------------------------------------------------
    // 1. Swap-path gas, by shape
    // ------------------------------------------------------------------------------------------

    /// @notice THE CONTROL. An exact-input buy is the shape every router sends by default, and it
    ///         is the shape the automatic sweep could never reach (`_afterSwap` returned at the
    ///         `exactInput` guard before it). Its gas therefore must not move when the auto path
    ///         is deleted. If this number changes, something other than the auto path changed.
    function test_gas_exactInputBuy_theShapeEveryRouterSends() public {
        (, PoolKey memory k,) = _defaultLaunch();

        // Warm the pool first, so this is a steady-state trade and not a pool's first ever swap.
        _buyExactIn(k, alice, 1e18);

        uint256 used = _gasSwap(k, alice, _buyIsZeroForOne(), -int256(uint256(5e18)));
        emit log_named_uint("GAS exact-input buy, warm pool     ", used);
        assertGt(used, 0, "the trade really executed");
    }

    /// @notice The pool's very first trade, exact input. Cold every slot.
    function test_gas_exactInputBuy_firstTradeEver() public {
        (, PoolKey memory k,) = _defaultLaunch();
        uint256 used = _gasSwap(k, alice, _buyIsZeroForOne(), -int256(uint256(5e18)));
        emit log_named_uint("GAS exact-input buy, first trade   ", used);
        assertGt(used, 0, "the trade really executed");
    }

    /// @notice THE SHAPE THAT CARRIES THE WHOLE DELTA. An exact-output buy is the only swap that
    ///         ever reached the automatic sweep, and only once the backlog cleared its bar.
    ///
    /// @dev The backlog is built with twenty 5e18 exact-input buys, which is a fixed, deterministic
    ///         sequence in both builds. On the pre-deletion build that leaves the backlog many
    ///         multiples over `autoSweepThreshold` (0.5 pair on this launch), so this trade also
    ///         pays the distributor, the creator and the platform inside somebody else's swap. On
    ///         the post-deletion build it is an ordinary exact-output buy.
    function test_gas_exactOutputBuy_withALargeBacklog() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        Distributor dist = LaunchToken(t).distributor();

        for (uint256 i = 0; i < 20; ++i) {
            _buyExactIn(k, alice, 5e18);
        }
        uint256 backlog = hook.pendingFees(id);
        assertGt(backlog, 2e18, "precondition: a large unswept backlog exists");

        uint256 distBefore = pair.balanceOf(address(dist));

        uint256 used = _gasSwap(k, bob, _buyIsZeroForOne(), int256(uint256(1_000_000e18)));

        emit log_named_uint("GAS exact-output buy, big backlog  ", used);
        emit log_named_uint("  backlog before the trade         ", backlog);
        emit log_named_uint("  backlog after the trade          ", hook.pendingFees(id));
        emit log_named_uint("  pair moved to the distributor    ", pair.balanceOf(address(dist)) - distBefore);
        assertGt(used, 0, "the trade really executed");
    }

    /// @notice The same shape with a backlog too small to have cleared the old bar. On the
    ///         pre-deletion build this pays one cold `SLOAD` for the threshold and returns; after
    ///         the deletion it pays nothing at all. The gap between this and the test above is the
    ///         cost of the machinery versus the cost of the payout.
    function test_gas_exactOutputBuy_withATinyBacklog() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        Distributor dist = LaunchToken(t).distributor();

        _buyExactIn(k, alice, 1e18); // 0.03 pair of fee
        uint256 backlog = hook.pendingFees(id);
        assertLt(backlog, 5e16, "precondition: the backlog is tiny");

        uint256 distBefore = pair.balanceOf(address(dist));
        uint256 used = _gasSwap(k, bob, _buyIsZeroForOne(), int256(uint256(1_000_000e18)));

        emit log_named_uint("GAS exact-output buy, tiny backlog ", used);
        assertEq(
            pair.balanceOf(address(dist)),
            distBefore,
            "no payout happened, so this is the machinery cost alone"
        );
    }

    /// @notice The two sell shapes, on a launch that actually charges a sell tax.
    function test_gas_sellShapes() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.sellFeeBps = 300;
        (, PoolKey memory k,) = _launch(p);

        _buyExactIn(k, alice, 50e18);
        _buyExactIn(k, bob, 50e18);

        uint256 gIn = _gasSwap(k, alice, !_buyIsZeroForOne(), -int256(uint256(1_000_000e18)));
        uint256 gOut = _gasSwap(k, bob, !_buyIsZeroForOne(), int256(uint256(1e18)));

        emit log_named_uint("GAS exact-input sell               ", gIn);
        emit log_named_uint("GAS exact-output sell              ", gOut);
        assertGt(gIn, 0, "the sell executed");
        assertGt(gOut, 0, "the sell executed");
    }

    // ------------------------------------------------------------------------------------------
    // 2. What a sweep costs, and the pot size at which it pays for itself at 20 gwei
    // ------------------------------------------------------------------------------------------

    /// @notice **THE NUMBER THE WHOLE PULL-ONLY MODEL RESTS ON.**
    ///
    /// @dev `sweep()` is permissionless and pays `SWEEP_BOUNTY_BPS` (0.5%) of the swept amount to
    ///      whoever called it. That is the ONLY thing that turns accrual into payment once the
    ///      automatic path is gone, so the break-even pot is not a curiosity — it is the size a
    ///      launch has to reach before anybody has a reason to press the button, and below it
    ///      dividends sit as ERC-6909 claims indefinitely.
    ///
    ///      Reported for a FRESH keeper (never paid in this currency, so the payout is a
    ///      zero-to-nonzero `SSTORE`) and for a WARM one, because the difference is thousands of
    ///      gas and a real bot is fresh exactly once per pair.
    function test_sweepGasAndTheBreakEvenPotAt20Gwei() public {
        (, PoolKey memory k, PoolId id) = _defaultLaunch();

        _buyForPot(k, alice, 1e18);
        assertGt(hook.pendingFees(id), 0, "precondition: there is something to sweep");

        (uint256 gasFresh, uint256 bountyFresh) = _gasSweep(k, keeper);
        assertGt(bountyFresh, 0, "precondition: the fresh keeper really was paid");

        // A second pot, swept by a keeper that already holds the pair currency.
        _buyForPot(k, alice, 1e18);
        vm.prank(alice);
        pair.transfer(keeperWarm, 1); // warm the recipient slot
        (uint256 gasWarm, uint256 bountyWarm) = _gasSweep(k, keeperWarm);
        assertGt(bountyWarm, 0, "precondition: the warm keeper really was paid");

        uint256 beFresh = _breakEvenPot(gasFresh);
        uint256 beWarm = _breakEvenPot(gasWarm);

        emit log_named_uint("SWEEP gas, fresh keeper            ", gasFresh);
        emit log_named_uint("SWEEP gas, warm keeper             ", gasWarm);
        emit log_named_uint("SWEEP cost in wei @ 20 gwei, fresh ", gasFresh * GAS_PRICE);
        emit log_named_uint("SWEEP cost in wei @ 20 gwei, warm  ", gasWarm * GAS_PRICE);
        emit log_named_uint("BREAK-EVEN POT (pair wei), fresh   ", beFresh);
        emit log_named_uint("BREAK-EVEN POT (pair wei), warm    ", beWarm);
        emit log_named_uint("BREAK-EVEN POT (milli-pair), fresh ", beFresh / 1e15);
        emit log_named_uint("BREAK-EVEN POT (milli-pair), warm  ", beWarm / 1e15);

        assertGt(beFresh, 0, "a break-even pot exists");
    }

    /// @notice The break-even asserted from BOTH sides, so the figure above cannot be a number
    ///         that happens to be printed.
    ///
    /// @dev At twice the computed pot the bounty must strictly exceed the gas bill; at half of it
    ///      the bounty must strictly fall short. Both legs re-measure their own gas rather than
    ///      reusing the probe's, so neither can pass on a stale reading.
    function test_sweepIsProfitableAboveTheBreakEvenAndNotBelowIt() public {
        (, PoolKey memory k, PoolId id) = _defaultLaunch();

        // Probe run: what does a sweep cost here?
        uint256 snap = vm.snapshotState();
        _buyForPot(k, alice, 1e18);
        (uint256 probeGas,) = _gasSweep(k, keeper);
        uint256 breakEven = _breakEvenPot(probeGas);
        require(vm.revertToState(snap), "snapshot revert failed");

        // ABOVE: twice the break-even pot.
        snap = vm.snapshotState();
        _buyForPot(k, alice, breakEven * 2);
        assertGt(hook.pendingFees(id), breakEven, "precondition: the pot really is over the bar");
        (uint256 gAbove, uint256 bAbove) = _gasSweep(k, keeper);
        emit log_named_uint("pot = 2x break-even, bounty (wei)  ", bAbove);
        emit log_named_uint("pot = 2x break-even, gas cost (wei)", gAbove * GAS_PRICE);
        assertGt(bAbove, gAbove * GAS_PRICE, "a 2x pot must pay a keeper more than it costs");
        require(vm.revertToState(snap), "snapshot revert failed");

        // BELOW: half the break-even pot.
        _buyForPot(k, alice, breakEven / 2);
        assertGt(hook.pendingFees(id), 0, "precondition: there is still a real pot");
        (uint256 gBelow, uint256 bBelow) = _gasSweep(k, keeper);
        emit log_named_uint("pot = 0.5x break-even, bounty (wei)", bBelow);
        emit log_named_uint("pot = 0.5x break-even, cost (wei)  ", gBelow * GAS_PRICE);
        assertLt(bBelow, gBelow * GAS_PRICE, "a 0.5x pot must NOT pay for itself");
    }

    /// @notice The bounty on a launch that also burns, which is the case a keeper actually has to
    ///         price: the burn wedge is spent BEFORE the bounty is computed, so the same pot pays
    ///         less and the break-even pot is correspondingly higher.
    function test_aBurnWedgeRaisesTheBreakEvenPot() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.burnBps = 3000;
        (, PoolKey memory k, PoolId id) = _launch(p);

        _buyForPot(k, alice, 1e18);
        uint256 pot = hook.pendingFees(id);
        (uint256 g, uint256 bounty) = _gasSweep(k, keeper);

        emit log_named_uint("pot swept on a 30% burn launch     ", pot);
        emit log_named_uint("bounty paid                        ", bounty);
        emit log_named_uint("bounty as bps of the pot           ", (bounty * 10_000) / pot);
        emit log_named_uint("BREAK-EVEN POT with a 30% burn     ", (g * GAS_PRICE * 10_000 * 10_000) / (uint256(hook.SWEEP_BOUNTY_BPS()) * 7000));

        // 0.5% of what survives a 30% burn is 0.35% of the pot.
        assertApproxEqAbs(
            (bounty * 10_000) / pot,
            (uint256(hook.SWEEP_BOUNTY_BPS()) * 7000) / 10_000,
            1,
            "the burn wedge is spent before the bounty is computed"
        );
    }

    // ------------------------------------------------------------------------------------------
    // 3. The push path pays nobody to run it
    // ------------------------------------------------------------------------------------------

    /// @notice `processBatch` is permissionless, bounded and correct — and pays ZERO. Measured so
    ///         the D-03c decision ("leave it keeper-optional, do not wire it into the swap") rests
    ///         on a number instead of an opinion: there is no bounty, so the push path is a
    ///         courtesy a creator or the platform can fund, never a job a bot takes for profit.
    function test_processBatchCostsGasAndPaysItsCallerNothing() public {
        (address t, PoolKey memory k,) = _defaultLaunch();
        Distributor dist = LaunchToken(t).distributor();

        _buyExactIn(k, alice, 50e18);
        _buyExactIn(k, bob, 50e18);
        hook.sweep(k);
        _vest(dist);

        uint256 queued = dist.queueLength();
        assertGt(queued, 0, "precondition: somebody is queued");
        assertGt(dist.withdrawableOf(alice), 0, "precondition: somebody is actually owed money");

        uint256 keeperBefore = pair.balanceOf(keeper);
        uint256 aliceBefore = pair.balanceOf(alice);

        vm.prank(keeper);
        uint256 g0 = gasleft();
        (uint256 sentCount, uint256 sentTotal) = dist.processBatch(queued);
        uint256 used = g0 - gasleft();

        emit log_named_uint("GAS processBatch, queue length     ", queued);
        emit log_named_uint("GAS processBatch                   ", used);
        emit log_named_uint("  cost in wei @ 20 gwei            ", used * GAS_PRICE);
        emit log_named_uint("  holders paid                     ", sentCount);
        emit log_named_uint("  total pushed                     ", sentTotal);

        assertGt(sentCount, 0, "the batch really paid somebody");
        assertGt(pair.balanceOf(alice) - aliceBefore, 0, "and a real holder's balance moved");
        assertEq(
            pair.balanceOf(keeper),
            keeperBefore,
            "THE PUSH PATH PAYS ITS CALLER NOTHING - unlike sweep, there is no bounty"
        );
    }

    // ------------------------------------------------------------------------------------------
    // 4. What actually leaves the singleton during a swap
    // ------------------------------------------------------------------------------------------

    /// @notice The property V-02 is about, stated directly as a balance: does any ERC-20 leave the
    ///         PoolManager in the middle of somebody else's swap?
    ///
    /// @dev The singleton's pair balance across an exact-output buy should move by exactly what the
    ///      trader paid in. Anything less means something was taken out mid-swap — which is
    ///      precisely what `PoolManager._settle` silently deducts from a caller that synced first.
    ///
    ///      This is a MEASUREMENT, not an assertion of either behaviour, so the same code reads
    ///      honestly on both builds. The pre-deletion build reports a shortfall equal to the
    ///      auto-swept payout; the post-deletion build must report zero.
    function test_howMuchPairLeavesTheSingletonDuringAnExactOutputBuy() public {
        (, PoolKey memory k, PoolId id) = _defaultLaunch();

        for (uint256 i = 0; i < 20; ++i) {
            _buyExactIn(k, alice, 5e18);
        }
        assertGt(hook.pendingFees(id), 2e18, "precondition: a large unswept backlog exists");

        uint256 managerBefore = pair.balanceOf(address(manager));
        uint256 bobBefore = pair.balanceOf(bob);

        _buyExactOut(k, bob, 1_000_000e18);

        uint256 paidIn = bobBefore - pair.balanceOf(bob);
        uint256 managerAfter = pair.balanceOf(address(manager));

        // The singleton's balance can go DOWN across this trade on a build with an automatic
        // sweep, because the payout can exceed what the trader paid in. A plain subtraction
        // underflows there, which is itself the finding - so measure it signed.
        uint256 gained = managerAfter > managerBefore ? managerAfter - managerBefore : 0;
        uint256 lost = managerBefore > managerAfter ? managerBefore - managerAfter : 0;

        emit log_named_uint("trader paid in                     ", paidIn);
        emit log_named_uint("singleton pair balance gained      ", gained);
        emit log_named_uint("singleton pair balance LOST        ", lost);
        emit log_named_uint("LEFT THE SINGLETON MID-SWAP        ", paidIn + lost - gained);

        assertGt(paidIn, 0, "non-vacuity: the trade really moved pair currency");
    }
}

// ===============================================================================================
// Both currency orderings. Every delta sign in the hook flips with the ordering, and a gas number
// measured in only one of them would miss a branch.
// ===============================================================================================

contract SweepEconomicsTokenIsCurrency0Test is SweepEconomicsCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract SweepEconomicsTokenIsCurrency1Test is SweepEconomicsCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
