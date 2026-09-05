// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {FeeHook} from "../../../src/FeeHook.sol";
import {FeeHookHarness} from "../../FeeHook.t.sol";

/// @notice The decaying opening fee — the E-01 mitigation.
///
/// @dev **What E-01 is.** A single-sided pool opens at a creator-chosen tick with a hard floor
///      beneath it, so the first transaction in the launch block holds a risk-free call option on
///      the entire supply. Audit 05 measured the downside capped at `feeBps` (-3.00 pair) against
///      +157.21 upside — a 50:1 free option — with organic buyers losing 154.82 of 200. A dev buy
///      does not defend it: the sniper pays 196.71% of the creator's average price.
///
///      **What this does and does not do.** It does not remove the option. Nothing can, short of
///      changing how the market opens — the floor is a property of single-sided seeding. What it
///      does is charge a PREMIUM for exercising it early, decaying to nothing by the end of the
///      window, so the option stops being free. `audit/09-remediation.md` costed four approaches
///      and this was the only one that touches the premium rather than the size.
///
///      **Every unit above the normal rate goes to the PLATFORM.** Not the creator, not holders.
///      Paying any of it to the creator would hand them a reason to snipe their own launch and
///      collect the penalty they triggered, which is the one incentive this must not create.
///      `test_creatorCannotFarmTheirOwnPenalty` is the guard.
///
///      Defaults to OFF. A launch that sets no window behaves exactly as it did before this
///      existed — `OpeningFeeDisabledTest` is the negative control that proves it.
abstract contract OpeningFeeHarness is FeeHookHarness {
    uint32 internal constant WINDOW = 20;
    uint16 internal constant OPENING_BPS = 9_900; // 99%, decaying to FEE_BPS (300)

    PoolKey internal wkey;
    PoolId internal wid;

    /// @dev **The window lives on a SECOND pool, not on the harness's default one.**
    ///      `FeeHookHarness` carries its own test suite, and every one of those tests asserts the
    ///      NORMAL rate. Turning the window on for the inherited pool made fourteen of them fail
    ///      against a decayed rate that was working exactly as designed — the tests were right and
    ///      the harness was wrong. Same structural mistake as letting a thin-pool suite inherit a
    ///      deep-pool suite: build the special case beside the default, never on top of it.
    function setUp() public virtual override {
        super.setUp();
        wkey = _windowPool(WINDOW, OPENING_BPS);
        wid = wkey.toId();
    }

    function _windowPool(uint32 window, uint16 openingBps) internal returns (PoolKey memory k) {
        (Currency c0, Currency c1) = _tokenIsCurrency0()
            ? (Currency.wrap(address(token)), Currency.wrap(address(pair)))
            : (Currency.wrap(address(pair)), Currency.wrap(address(token)));

        k = PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 10, hooks: key.hooks});

        hook.configurePoolFull(
            k,
            FeeHook.FeeSetup({
                distributor: address(dist),
                pairCurrency: Currency.wrap(address(pair)),
                feeBps: FEE_BPS,
                sellFeeBps: 0,
                burnBps: 0,
                creator: creator,
                creatorBps: CREATOR_BPS,
                rewardCurrency: Currency.wrap(address(0)),
                openingWindow: window,
                openingFeeBps: openingBps
            })
        );
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(10),
                tickUpper: TickMath.maxUsableTick(10),
                liquidityDelta: 10_000_000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _wBuy(address who, uint256 amountIn) internal {
        vm.prank(who);
        swapRouter.swap(
            wkey,
            SwapParams({
                zeroForOne: _buyIsZeroForOne(),
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: _buyIsZeroForOne()
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _wSell(address who, uint256 amountIn) internal {
        vm.prank(who);
        swapRouter.swap(
            wkey,
            SwapParams({
                zeroForOne: !_buyIsZeroForOne(),
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: !_buyIsZeroForOne()
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ===============================================================================================
    // The curve
    // ===============================================================================================

    /// The rate has to actually decay, and it has to land exactly on the normal rate at the end.
    /// A window that never reaches `feeBps` is a permanent tax wearing a temporary name.
    function test_theRateDecaysLinearlyAndLandsExactlyOnTheNormalRate() public {
        uint256 t0 = vm.getBlockTimestamp();

        assertEq(hook.currentBuyFeeBps(wid), OPENING_BPS, "the market did not open at the opening rate");

        // Quarter, half, three-quarters of the way through.
        skip(5);
        uint16 atQuarter = hook.currentBuyFeeBps(wid);
        skip(5);
        uint16 atHalf = hook.currentBuyFeeBps(wid);
        skip(5);
        uint16 atThreeQuarters = hook.currentBuyFeeBps(wid);

        // Linear: three quarters of the spread remains at t=5, half at t=10, a quarter at t=15.
        uint256 spread = OPENING_BPS - FEE_BPS;
        assertEq(atQuarter, FEE_BPS + (spread * 3) / 4, "not linear at a quarter of the window");
        assertEq(atHalf, FEE_BPS + spread / 2, "not linear at half the window");
        assertEq(atThreeQuarters, FEE_BPS + spread / 4, "not linear at three quarters");

        // And it is monotonically decreasing, not just correct at the sample points.
        assertGt(atQuarter, atHalf, "the rate did not fall between the first two samples");
        assertGt(atHalf, atThreeQuarters, "the rate did not fall between the last two samples");

        vm.warp(t0 + WINDOW);
        assertEq(hook.currentBuyFeeBps(wid), FEE_BPS, "the window did not land on the normal rate");

        skip(1 days);
        assertEq(hook.currentBuyFeeBps(wid), FEE_BPS, "the rate moved after the window closed");
    }

    /// A SELL is never subject to the window. The option being priced is a buy-side option, and
    /// taxing an exit would be a honeypot, not a defence.
    function test_theWindowNeverTouchesSells() public {
        // Buy first so there is something to sell — at the opening rate, which is the point.
        _wBuy(alice, 50e18);
        uint256 held = token.balanceOf(alice);
        assertGt(held, 0, "precondition: alice holds tokens");

        uint256 pairBefore = pair.balanceOf(alice);
        _wSell(alice, held / 2);
        assertGt(pair.balanceOf(alice), pairBefore, "a sell inside the window returned nothing");
    }

    // ===============================================================================================
    // THE MEASUREMENT — does it actually change the economics of a snipe?
    // ===============================================================================================

    /// **The E-01 number.** The same block-0 buy, held and sold back, measured inside the window
    /// and again after it. The sniper's cost of exercising early must be materially higher.
    function test_E01_snipingAtTheOpenCostsMaterallyMoreThanWaiting() public {
        uint256 size = 40e18;
        uint256 t0 = vm.getBlockTimestamp();

        // ARM: buy at the very first instant, then round-trip out.
        uint256 snap = vm.snapshotState();
        uint256 beforeSnipe = pair.balanceOf(alice);
        _wBuy(alice, size);
        uint256 sniped = token.balanceOf(alice);
        _wSell(alice, sniped);
        uint256 snipeLoss = beforeSnipe - pair.balanceOf(alice);
        vm.revertToState(snap);

        // CONTROL: identical trade from identical state, after the window has closed.
        vm.warp(t0 + WINDOW + 1);
        uint256 beforeWait = pair.balanceOf(alice);
        _wBuy(alice, size);
        uint256 waited = token.balanceOf(alice);
        _wSell(alice, waited);
        uint256 waitLoss = beforeWait - pair.balanceOf(alice);

        emit log_named_uint("tokens received sniping at t=0 ", sniped);
        emit log_named_uint("tokens received after the window", waited);
        emit log_named_uint("round-trip cost, sniping        ", snipeLoss);
        emit log_named_uint("round-trip cost, waiting        ", waitLoss);
        emit log_named_uint("multiple                        ", waitLoss == 0 ? 0 : snipeLoss / waitLoss);

        assertGt(snipeLoss, waitLoss, "sniping at the open cost no more than waiting");
        // The whole point is that it is not marginal. At 99% opening against a 3% normal rate the
        // premium should be an order of magnitude, not a rounding error.
        assertGt(snipeLoss, waitLoss * 5, "the opening premium is not material");
        assertLt(sniped, waited, "the sniper received at least as many tokens as a patient buyer");
    }

    /// The penalty must reach the PLATFORM and nobody else. This is what stops a creator sniping
    /// their own launch: the money they would be farming is not theirs.
    function test_creatorCannotFarmTheirOwnPenalty() public {
        uint256 creatorBefore = pair.balanceOf(creator);
        uint256 distBefore = pair.balanceOf(address(dist));
        uint256 platformBefore = pair.balanceOf(PLATFORM);

        // A buy at the opening instant, then a sweep to turn claims into money.
        _wBuy(alice, 40e18);
        assertGt(hook.pendingOpeningFees(wid), 0, "the opening penalty was not accrued separately");

        hook.sweep(wkey);

        uint256 creatorGot = pair.balanceOf(creator) - creatorBefore;
        uint256 holdersGot = pair.balanceOf(address(dist)) - distBefore;
        uint256 platformGot = pair.balanceOf(PLATFORM) - platformBefore;

        emit log_named_uint("platform got", platformGot);
        emit log_named_uint("creator got ", creatorGot);
        emit log_named_uint("holders got ", holdersGot);

        // The platform takes the penalty, so on a 99% opening rate it must dwarf both other slices.
        assertGt(platformGot, creatorGot * 10, "the creator got a share of the opening penalty");
        assertGt(platformGot, holdersGot * 5, "the penalty leaked into the holder pot");
        assertEq(hook.pendingOpeningFees(wid), 0, "the penalty was not cleared by the sweep");
    }

    /// The penalty is separate money, not a re-slice of the normal fee. Holders and the creator
    /// must still receive their ordinary cut of the ordinary rate on the same trade.
    function test_theOrdinaryFeeIsStillPaidOnTopOfThePenalty() public {
        uint256 creatorBefore = pair.balanceOf(creator);
        uint256 distBefore = pair.balanceOf(address(dist));

        _wBuy(alice, 40e18);
        hook.sweep(wkey);

        assertGt(pair.balanceOf(creator) - creatorBefore, 0, "the creator was paid nothing at all");
        assertGt(pair.balanceOf(address(dist)) - distBefore, 0, "holders were paid nothing at all");
    }

    /// After the window the pool is an ordinary pool: no penalty accrues, ever again.
    function test_nothingAccruesAfterTheWindowCloses() public {
        skip(WINDOW + 1);
        _wBuy(alice, 40e18);
        assertEq(hook.pendingOpeningFees(wid), 0, "a penalty accrued after the window closed");
    }
}

contract OpeningFeeToken0Test is OpeningFeeHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract OpeningFeeToken1Test is OpeningFeeHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

// ===================================================================================================
// NEGATIVE CONTROL — a launch that sets no window behaves exactly as it did before
// ===================================================================================================

/// @notice The whole mechanism is opt-in, and this proves the opt-out path is untouched.
///
/// @dev Without this, every assertion in the suite above could be satisfied by a build that
///      applied the penalty to everyone.
abstract contract OpeningFeeDisabledHarness is FeeHookHarness {
    function test_control_noWindowMeansTheRateNeverMoves() public {
        assertEq(hook.currentBuyFeeBps(poolId), FEE_BPS, "an unconfigured pool opened at a penalty rate");
        skip(10);
        assertEq(hook.currentBuyFeeBps(poolId), FEE_BPS, "the rate moved on a pool with no window");
        skip(1 days);
        assertEq(hook.currentBuyFeeBps(poolId), FEE_BPS, "the rate moved later on a pool with no window");
    }

    function test_control_noPenaltyEverAccrues() public {
        _buyExactIn(alice, 40e18);
        assertEq(hook.pendingOpeningFees(poolId), 0, "a penalty accrued on a pool with no window");
        assertGt(hook.totalFeesTaken(poolId), 0, "precondition: the buy was charged at all");
    }
}

contract OpeningFeeDisabledToken0Test is OpeningFeeDisabledHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract OpeningFeeDisabledToken1Test is OpeningFeeDisabledHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

// ===================================================================================================
// Configuration is validated, never clamped
// ===================================================================================================

contract OpeningFeeValidationTest is FeeHookHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function _setup(uint32 window, uint16 openingBps)
        internal
        view
        returns (FeeHook.FeeSetup memory)
    {
        return FeeHook.FeeSetup({
            distributor: address(dist),
            pairCurrency: Currency.wrap(address(pair)),
            feeBps: FEE_BPS,
            sellFeeBps: 0,
            burnBps: 0,
            creator: creator,
            creatorBps: CREATOR_BPS,
            rewardCurrency: Currency.wrap(address(0)),
            openingWindow: window,
            openingFeeBps: openingBps
        });
    }

    /// A second pool on the same currencies, so each case gets a fresh PoolId.
    function _freshKey(int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: 0,
            tickSpacing: spacing,
            hooks: key.hooks
        });
    }

    function test_aWindowLongerThanTheCapIsRefused() public {
        uint32 tooLong = hook.MAX_OPENING_WINDOW() + 1;
        vm.expectRevert(abi.encodeWithSelector(FeeHook.OpeningWindowTooLong.selector, tooLong));
        hook.configurePoolFull(_freshKey(10), _setup(tooLong, 5_000));
    }

    function test_anOpeningRateAtOrBelowTheNormalRateIsRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(FeeHook.OpeningFeeBelowNormalRate.selector, uint16(FEE_BPS))
        );
        hook.configurePoolFull(_freshKey(20), _setup(20, FEE_BPS));
    }

    function test_anOpeningRateAboveTheCapIsRefused() public {
        uint16 tooHigh = hook.MAX_OPENING_FEE_BPS() + 1;
        vm.expectRevert(abi.encodeWithSelector(FeeHook.FeeTooHigh.selector, tooHigh));
        hook.configurePoolFull(_freshKey(30), _setup(20, tooHigh));
    }

    /// **Silent trimming is banned in this codebase.** An opening rate with no window to apply it
    /// over is half a configuration, and half a configuration is refused rather than ignored.
    function test_anOpeningRateWithNoWindowIsRefusedRatherThanIgnored() public {
        vm.expectRevert(abi.encodeWithSelector(FeeHook.OpeningWindowTooLong.selector, uint32(0)));
        hook.configurePoolFull(_freshKey(40), _setup(0, 5_000));
    }

    function test_theCapsThemselvesAreAccepted() public {
        hook.configurePoolFull(
            _freshKey(50), _setup(hook.MAX_OPENING_WINDOW(), hook.MAX_OPENING_FEE_BPS())
        );
    }
}
