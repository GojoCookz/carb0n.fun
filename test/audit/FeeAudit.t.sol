// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Pool} from "v4-core/libraries/Pool.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {FeeHook} from "../../src/FeeHook.sol";
import {Distributor} from "../../src/Distributor.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {LaunchTokenDeployer} from "../utils/LaunchTokenDeployer.sol";

/// @title FeeAuditWorld
/// @notice A real v4 world in which the auditor can stand up ARBITRARY fee configurations.
///
/// @dev `FeeHookHarness` hardcodes `FEE_BPS = 300` / `CREATOR_BPS = 2000` as constants and only
///      lets a subclass vary the sell and burn rates. Several of the findings below live in
///      configurations that harness cannot express at all - most importantly `burnBps = 10_000`,
///      which `PlatformDilution.t.sol` explicitly bounds away from
///      (`bound(burnBps, 0, 5000)`, "the harness creator takes 50%"). So this file builds its own
///      world and mints pools on demand.
///
///      The launch token is `currency0` here; a second suite at the bottom re-runs the
///      currency-ordering-sensitive findings with the token as `currency1`.
abstract contract FeeAuditWorld is Test, LaunchTokenDeployer {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolManager internal manager;
    FeeHook internal hook;
    LaunchToken internal token;
    Distributor internal dist;
    MockERC20 internal pair;

    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;

    address internal constant PLATFORM = address(0xFEE0);
    address internal creator = address(0xC0EA702);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant SUPPLY = 1_000_000_000e18;

    function _tokenIsCurrency0() internal pure virtual returns (bool);

    /// @dev Buying the launch token means paying the pair currency in.
    function _buyIsZeroForOne() internal pure returns (bool) {
        return !_tokenIsCurrency0();
    }

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        pair = new MockERC20("Wrapped Ether", "WETH", 18);
        _deployLaunchTokenImpl();

        address hookAddr = address(uint160(uint256(0xAD17) << 144 | 0x20CC));
        deployCodeTo(
            "FeeHook.sol:FeeHook", abi.encode(address(manager), address(this), PLATFORM), hookAddr
        );
        hook = FeeHook(hookAddr);

        token = _deploySorted(address(pair), _tokenIsCurrency0());
        dist = token.distributor();

        pair.mint(address(this), 1_000_000_000e18);
        pair.approve(address(lpRouter), type(uint256).max);
        pair.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);

        _fund(alice);
        _fund(bob);
    }

    function _deploySorted(address pairAddr, bool wantCurrency0) internal returns (LaunchToken) {
        LaunchToken.InitParams memory p = LaunchToken.InitParams({
            name_: "Hoodstonk",
            symbol_: "HOOD",
            supply: SUPPLY,
            recipient: address(this),
            payoutToken: pairAddr,
            rewardToken: address(0),
            converter: address(0),
            controller: address(hook),
            poolManager_: address(manager),
            maxWallet_: 0,
            minPushPayout: 1e6,
            minShareForQueue: 1e18,
            metadata: _defaultMetadata()
        });

        for (uint256 i = 0; i < 4096; ++i) {
            bytes32 salt = bytes32(i);
            if ((_predictClone(salt) < pairAddr) == wantCurrency0) return _cloneAndInit(salt, p);
        }
        revert("no salt");
    }

    function _fund(address who) internal {
        pair.mint(who, 100_000_000e18);
        vm.startPrank(who);
        pair.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Configure, initialise and seed a brand new pool with an arbitrary fee shape.
    ///      `graduationThreshold == 0` means graduation (and therefore auto-sweep) stays UNARMED,
    ///      which keeps a test's sweep path deterministic.
    function _newPool(
        int24 tickSpacing,
        uint16 feeBps,
        uint16 sellFeeBps,
        uint16 burnBps,
        uint16 creatorBps,
        uint256 graduationThreshold
    ) internal returns (PoolKey memory k) {
        (Currency c0, Currency c1) = _tokenIsCurrency0()
            ? (Currency.wrap(address(token)), Currency.wrap(address(pair)))
            : (Currency.wrap(address(pair)), Currency.wrap(address(token)));

        k = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 0,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });

        hook.configurePoolFull(
            k,
            FeeHook.FeeSetup({
                distributor: address(dist),
                pairCurrency: Currency.wrap(address(pair)),
                feeBps: feeBps,
                sellFeeBps: sellFeeBps,
                burnBps: burnBps,
                creator: creator,
                creatorBps: creatorBps,
                rewardCurrency: Currency.wrap(address(0))
            })
        );
        if (graduationThreshold != 0) hook.configureGraduation(k, graduationThreshold, SUPPLY);

        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));

        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(tickSpacing),
                tickUpper: TickMath.maxUsableTick(tickSpacing),
                liquidityDelta: 10_000_000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev A pool seeded the way `Launcher` really seeds one: SINGLE-SIDED, entirely in the launch
    ///      token, from the opening tick outward. There is no pair currency in the pool until
    ///      somebody buys, and none below the opening tick ever.
    ///
    ///      `_newPool`'s symmetric full-range seed is a test-harness convenience that does not
    ///      exist in production, and it hides every "the pool ran out of pair currency" path.
    function _newSingleSidedPool(int24 tickSpacing, uint16 feeBps, uint16 sellFeeBps)
        internal
        returns (PoolKey memory k)
    {
        (Currency c0, Currency c1) = _tokenIsCurrency0()
            ? (Currency.wrap(address(token)), Currency.wrap(address(pair)))
            : (Currency.wrap(address(pair)), Currency.wrap(address(token)));

        k = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 0,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });

        hook.configurePoolFull(
            k,
            FeeHook.FeeSetup({
                distributor: address(dist),
                pairCurrency: Currency.wrap(address(pair)),
                feeBps: feeBps,
                sellFeeBps: sellFeeBps,
                burnBps: 0,
                creator: creator,
                creatorBps: 2000,
                rewardCurrency: Currency.wrap(address(0))
            })
        );

        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));

        // A position holding only currency0 sits ABOVE the current price; one holding only
        // currency1 sits BELOW it. The launch token is the only thing seeded either way.
        (int24 lower, int24 upper) = _tokenIsCurrency0()
            ? (int24(0), TickMath.maxUsableTick(tickSpacing))
            : (TickMath.minUsableTick(tickSpacing), int24(0));

        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: 1_000_000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _swapRaw(PoolKey memory k, address who, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta)
    {
        vm.prank(who);
        return swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _buyExactIn(PoolKey memory k, address who, uint256 amountIn) internal {
        _swapRaw(k, who, _buyIsZeroForOne(), -int256(amountIn));
    }

    function _buyExactOut(PoolKey memory k, address who, uint256 amountOut) internal {
        _swapRaw(k, who, _buyIsZeroForOne(), int256(amountOut));
    }

    function _sellExactIn(PoolKey memory k, address who, uint256 amountIn) internal {
        _swapRaw(k, who, !_buyIsZeroForOne(), -int256(amountIn));
    }
}

// ===============================================================================================
// The findings
// ===============================================================================================

abstract contract FeeAuditFindings is FeeAuditWorld {
    using PoolIdLibrary for PoolKey;

    // -------------------------------------------------------------------------------------------
    // F-01  burnBps = 10_000 pays the platform, the creator and the holders exactly nothing.
    // -------------------------------------------------------------------------------------------

    /// @dev FeeHook.sol:869-870 claims "no combination of `creatorBps` and `burnBps` can leave the
    ///      platform unpaid". `configurePoolFull` only enforces `creatorBps + burnBps <= BPS`, so
    ///      `creatorBps = 0, burnBps = 10_000` is legal - and `unlockCallback` spends the ENTIRE
    ///      swept total on the buyback before `_routeFee` is ever reached.
    ///
    ///      `PlatformDilution.t.sol:78` bounds its fuzz to `burnBps <= 5000` because "the harness
    ///      creator takes 50%", which is why this was never reached.
    function test_F01_burnBps10000_paysPlatformAndHoldersNothing() public {
        PoolKey memory k = _newPool(60, 1000, 0, 10_000, 0, 0);
        PoolId id = k.toId();

        uint256 platformBefore = pair.balanceOf(PLATFORM);
        uint256 creatorBefore = pair.balanceOf(creator);
        uint256 distBefore = pair.balanceOf(address(dist));
        uint256 bobBefore = pair.balanceOf(bob);

        _buyExactIn(k, alice, 100_000e18);
        assertGt(hook.pendingFees(id), 0, "precondition: a fee was charged");

        vm.prank(bob);
        hook.sweep(k);

        assertEq(hook.pendingFees(id), 0, "the fee was swept");
        assertGt(hook.totalBurned(id), 0, "and spent entirely on the buyback");

        assertEq(pair.balanceOf(PLATFORM), platformBefore, "PLATFORM WAS PAID NOTHING");
        assertEq(pair.balanceOf(creator), creatorBefore, "creator was paid nothing");
        assertEq(pair.balanceOf(address(dist)), distBefore, "holders were paid nothing");
        assertEq(pair.balanceOf(bob), bobBefore, "the sweep caller got no bounty either");
    }

    /// @dev The same configuration also makes the automatic path a permanent, unconditional no-op
    ///      that still costs every exact-output trader the gas of reaching it: `autoRedeem`
    ///      reserves 100% for a burn, computes `payout == 0`, and returns having changed nothing.
    function test_F01b_burnBps10000_makesAutoRedeemAPermanentNoOp() public {
        PoolKey memory k = _newPool(60, 1000, 0, 10_000, 0, 1_000_000e18);
        PoolId id = k.toId();

        // Push the backlog well past the auto-sweep threshold.
        _buyExactIn(k, alice, 500_000e18);
        assertGt(hook.pendingFees(id), hook.autoSweepThreshold(id), "backlog is over the bar");

        uint256 pendingBefore = hook.pendingFees(id);
        uint256 distBefore = pair.balanceOf(address(dist));

        // An exact-OUTPUT buy is the shape that reaches `_tryAutoSweep`.
        _buyExactOut(k, bob, 1_000e18);

        assertGt(hook.pendingFees(id), pendingBefore, "the trade still accrued");
        assertEq(pair.balanceOf(address(dist)), distBefore, "auto sweep paid holders nothing");
    }

    // -------------------------------------------------------------------------------------------
    // F-02  `platformShareBps` is derived from the BUY rate but applied to SELL fees too.
    // -------------------------------------------------------------------------------------------

    /// @dev `platformShareBps = PLATFORM_VOLUME_BPS * BPS / feeBps` (FeeHook.sol:345) turns "1% of
    ///      volume" into "this fraction of the fee". That identity only holds for money that
    ///      arrived at the rate `feeBps`. Sell fees arrive at `sellFeeBps`, are converted to the
    ///      pair currency in `unlockCallback`, merged into the same `totalPair`, and then handed to
    ///      `_routeFee`, which applies the buy-derived share to all of it.
    ///
    ///      With `feeBps = 100` (the floor, share = 10_000 = the entire fee) and
    ///      `sellFeeBps = 1000`, the platform takes 100% of a 10% sell tax: ~10% of sell volume,
    ///      ten times the constant it is documented to be capped at, and the creator and the
    ///      holders receive nothing at all from sells.
    ///
    ///      `PlatformFee.t.sol:79` asserts `assertLe(volumeBpsEarned, PLATFORM_VOLUME_BPS,
    ///      "platform was overpaid")`. It passes only because that fuzz hardcodes `sellFeeBps: 0`.
    function test_F02_sellFeesArePaidToThePlatformAtTheBuyRateShare() public {
        PoolKey memory k = _newPool(60, /*buy*/ 100, /*sell*/ 1000, 0, /*creatorBps*/ 5000, 0);
        PoolId id = k.toId();

        (,,,,,,,, uint16 platformShareBps,) = hook.poolConfig(id);
        assertEq(platformShareBps, 10_000, "at the fee floor the platform takes the whole fee");

        // Give alice a position to sell, without routing through the pool.
        token.transfer(alice, 1_000_000e18);

        uint256 platformBefore = pair.balanceOf(PLATFORM);
        uint256 creatorBefore = pair.balanceOf(creator);
        uint256 distBefore = pair.balanceOf(address(dist));
        uint256 alicePairBefore = pair.balanceOf(alice);
        uint256 bobBefore = pair.balanceOf(bob);

        _sellExactIn(k, alice, 1_000_000e18);
        assertGt(hook.pendingTokenFees(id), 0, "the sell was charged in launch tokens");

        vm.prank(bob);
        hook.sweep(k);

        uint256 platformGot = pair.balanceOf(PLATFORM) - platformBefore;
        uint256 sellerGot = pair.balanceOf(alice) - alicePairBefore;

        // Every wei the sweep produced, plus what the seller kept, is the gross sell volume.
        uint256 swept = platformGot + (pair.balanceOf(creator) - creatorBefore)
            + (pair.balanceOf(address(dist)) - distBefore) + (pair.balanceOf(bob) - bobBefore);
        uint256 grossVolume = sellerGot + swept;
        uint256 platformBpsOfVolume = (platformGot * 10_000) / grossVolume;

        emit log_named_uint("platform bps of sell volume", platformBpsOfVolume);

        assertGt(
            platformBpsOfVolume,
            hook.PLATFORM_VOLUME_BPS(),
            "PLATFORM OVERPAID: took more than 1% of sell volume"
        );
        // ~10% of volume, i.e. an order of magnitude over the documented flat rate.
        assertGt(platformBpsOfVolume, 500, "platform took over 5% of sell volume");

        assertEq(pair.balanceOf(creator), creatorBefore, "creator got nothing from the sell tax");
        assertEq(pair.balanceOf(address(dist)), distBefore, "holders got nothing from the sell tax");
    }

    /// @dev The mirror image: a high buy rate with a low sell rate UNDERPAYS the platform on sell
    ///      volume by the same ratio. 10% buy / 1% sell => the platform earns 0.1% of sell volume.
    function test_F02b_theInverseConfigurationUnderpaysThePlatformOnSells() public {
        PoolKey memory k = _newPool(60, /*buy*/ 1000, /*sell*/ 100, 0, /*creatorBps*/ 0, 0);
        PoolId id = k.toId();

        (,,,,,,,, uint16 platformShareBps,) = hook.poolConfig(id);
        assertEq(platformShareBps, 1000, "a 10% fee gives the platform a tenth of it");

        token.transfer(alice, 1_000_000e18);

        uint256 platformBefore = pair.balanceOf(PLATFORM);
        uint256 creatorBefore = pair.balanceOf(creator);
        uint256 distBefore = pair.balanceOf(address(dist));
        uint256 alicePairBefore = pair.balanceOf(alice);
        uint256 bobBefore = pair.balanceOf(bob);

        _sellExactIn(k, alice, 1_000_000e18);
        vm.prank(bob);
        hook.sweep(k);

        uint256 platformGot = pair.balanceOf(PLATFORM) - platformBefore;
        uint256 swept = platformGot + (pair.balanceOf(creator) - creatorBefore)
            + (pair.balanceOf(address(dist)) - distBefore) + (pair.balanceOf(bob) - bobBefore);
        uint256 grossVolume = (pair.balanceOf(alice) - alicePairBefore) + swept;
        uint256 platformBpsOfVolume = (platformGot * 10_000) / grossVolume;

        emit log_named_uint("platform bps of sell volume", platformBpsOfVolume);
        assertLt(
            platformBpsOfVolume,
            hook.PLATFORM_VOLUME_BPS(),
            "PLATFORM UNDERPAID: took less than 1% of sell volume"
        );
    }

    // -------------------------------------------------------------------------------------------
    // F-03  An exact-OUTPUT buy pays a strictly smaller fee than the identical exact-INPUT buy.
    // -------------------------------------------------------------------------------------------

    /// @dev `_beforeSwap` charges `feeBps` of the amount the trader HANDS OVER (the fee comes out
    ///      of the input: FeeHook.sol:591-592). `_afterSwap` charges `feeBps` of the amount the
    ///      POOL CONSUMED and adds it on top (FeeHook.sol:643-644). For the same trade those are
    ///      different bases: the exact-out leg collects `r/(1+r)` of gross instead of `r`.
    ///
    ///      Same pool, same state, same output delivered - measured with a state snapshot so the
    ///      curve is bit-identical on both runs.
    function test_F03_exactOutputBuysAreSystematicallyUndercharged() public {
        PoolKey memory k = _newPool(60, /*buy*/ 1000, 0, 0, 5000, 0);
        PoolId id = k.toId();

        uint256 spend = 100_000e18;

        uint256 snap = vm.snapshotState();

        uint256 tokensBefore = token.balanceOf(alice);
        _buyExactIn(k, alice, spend);
        uint256 outFromExactIn = token.balanceOf(alice) - tokensBefore;
        uint256 feeExactIn = hook.pendingFees(id);

        require(vm.revertToState(snap), "revert failed");

        // Ask for exactly the same number of launch tokens, expressed as exact-output.
        uint256 pairBefore = pair.balanceOf(alice);
        _buyExactOut(k, alice, outFromExactIn);
        uint256 paidExactOut = pairBefore - pair.balanceOf(alice);
        uint256 feeExactOut = hook.pendingFees(id);

        emit log_named_uint("exact-in  fee", feeExactIn);
        emit log_named_uint("exact-out fee", feeExactOut);
        emit log_named_uint("exact-in  paid", spend);
        emit log_named_uint("exact-out paid", paidExactOut);

        assertEq(token.balanceOf(alice) - tokensBefore, outFromExactIn, "same output delivered");

        assertLt(feeExactOut, feeExactIn, "exact-output buy paid LESS fee for the same output");

        // The discount is deterministic. Exact-in charges `r * G`; the pool then only eats
        // `(1-r) * G`, and the exact-out leg charges `r` of THAT. So `feeOut / feeIn == 1 - r`
        // and the discount is exactly `feeBps`.
        uint256 discountBps = ((feeExactIn - feeExactOut) * 10_000) / feeExactIn;
        emit log_named_uint("fee discount bps for routing exact-output", discountBps);
        assertApproxEqAbs(discountBps, 1000, 20, "at a 10% fee the exact-out router saves 10% of it");

        // And the trader really is better off, not just the accounting.
        assertLt(paidExactOut, spend, "the exact-output trader spent less for the same tokens");
    }

    /// @dev Same asymmetry at a realistic 3% rate, to show it is not an artifact of the cap.
    function test_F03b_theDiscountScalesWithTheRate() public {
        PoolKey memory k = _newPool(60, /*buy*/ 300, 0, 0, 2000, 0);
        PoolId id = k.toId();

        uint256 snap = vm.snapshotState();

        uint256 tokensBefore = token.balanceOf(bob);
        _buyExactIn(k, bob, 100_000e18);
        uint256 outFromExactIn = token.balanceOf(bob) - tokensBefore;
        uint256 feeExactIn = hook.pendingFees(id);

        require(vm.revertToState(snap), "revert failed");

        _buyExactOut(k, bob, outFromExactIn);
        uint256 feeExactOut = hook.pendingFees(id);

        uint256 discountBps = ((feeExactIn - feeExactOut) * 10_000) / feeExactIn;
        emit log_named_uint("fee discount bps at a 3% fee", discountBps);
        assertApproxEqAbs(discountBps, 300, 20, "the discount tracks the rate exactly");
    }

    // -------------------------------------------------------------------------------------------
    // F-04  An auto-sweep's "reserved for burn" is itself burn-fractioned by the next sweep.
    // -------------------------------------------------------------------------------------------

    /// @dev `autoRedeem` parks `amount * burnBps / BPS` back into `pendingFees` so a later manual
    ///      sweep can spend it on the buyback the auto path cannot run (FeeHook.sol:686-692). But
    ///      `unlockCallback` does not know that balance is already earmarked: it applies
    ///      `burnBps` to it AGAIN (FeeHook.sol:818), so only `burnBps^2` of the original fee is
    ///      ever burned and the other `burnBps * (1 - burnBps)` is quietly re-routed to the
    ///      platform, creator and holders.
    ///
    ///      Nothing is stolen and nothing is lost. What is false is the documented behaviour: a
    ///      pool busy enough to auto-sweep burns a small fraction of the wedge its creator chose.
    function test_F04_autoSweepReserveIsBurnFractionedTwice() public {
        uint16 burnBps = 2000;
        PoolKey memory k = _newPool(60, 1000, 0, burnBps, 0, 1_000_000e18);
        PoolId id = k.toId();

        // Build a backlog over the auto-sweep bar without triggering it (exact-input never does).
        _buyExactIn(k, alice, 500_000e18);
        uint256 backlog = hook.pendingFees(id);
        assertGt(backlog, hook.autoSweepThreshold(id), "over the auto-sweep bar");

        // An exact-output buy runs `_afterSwap` and therefore `_tryAutoSweep`.
        uint256 burnedBeforeAuto = hook.totalBurned(id);
        _buyExactOut(k, bob, 1_000e18);

        assertEq(hook.totalBurned(id), burnedBeforeAuto, "the auto path cannot burn, by design");

        // Everything still pending is, by the contract's own comment, "reserved for burn".
        uint256 reserved = hook.pendingFees(id);
        assertGt(reserved, 0, "a burn reserve was parked");

        // Now sweep manually. The whole reserve should be spent on the buyback.
        vm.recordLogs();
        hook.sweep(k);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 pairSpentOnBurn;
        bytes32 topic = keccak256("Burned(bytes32,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) {
                (pairSpentOnBurn,) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }

        emit log_named_uint("reserved for burn by the auto sweep", reserved);
        emit log_named_uint("pair actually spent on the buyback ", pairSpentOnBurn);

        // The documented intent is `pairSpentOnBurn == reserved`.
        assertLt(pairSpentOnBurn, reserved, "the reserve was NOT spent on the burn");
        // What actually happens is burnBps of the reserve, i.e. burnBps^2 of the original fee.
        assertApproxEqAbs(
            pairSpentOnBurn,
            (reserved * burnBps) / 10_000,
            2,
            "only burnBps of the reserve is burned, not the reserve"
        );
    }

    // -------------------------------------------------------------------------------------------
    // F-05  REGRESSION GUARD. `sweep()` used to brick PERMANENTLY once the sell-fee pile outgrew
    //       the pool's pair reserve. It now defers what the pool cannot absorb.
    // -------------------------------------------------------------------------------------------

    /// @dev **THE BUG (audit 01, HIGH).** `unlockCallback` burned the WHOLE `pendingTokenFees`
    ///      claim into a token credit and sold all of it in one exact-input swap, without ever
    ///      checking that the swap consumed what it burned. A production pool is seeded
    ///      SINGLE-SIDED, so there is no liquidity below the opening tick and the pool's pair
    ///      balance is only ever what buyers put in. Once the accumulated sell tax was worth more
    ///      pair than the pool still held, the conversion either
    ///
    ///        MODE 1 - reverted `PriceLimitAlreadyExceeded(p, p)` because the dump had already
    ///                 pinned spot at the exact `sqrtPriceLimitX96` the conversion passes, or
    ///        MODE 2 - partially filled and left an unsettled token CREDIT, which
    ///                 `PoolManager.unlock`'s sign-agnostic `NonzeroDeltaCount != 0` check turned
    ///                 into `CurrencyNotSettled`.
    ///
    ///      `sweep` is the ONLY thing that clears `pendingTokenFees` and it reverted before
    ///      reaching the line that clears it, so the state was self-perpetuating: every later
    ///      sweep by every caller reverted too, and the pool's pair-currency fees were trapped
    ///      alongside the token ones. Dividends, creator revenue and platform revenue stopped
    ///      forever, triggered by one ordinary dump.
    ///
    ///      **THE FIX.** `unlockCallback` now (1) reads `slot0` and skips the swap entirely when
    ///      spot is already at the limit, and (2) re-mints whatever the pool could not absorb,
    ///      adding it back to `pendingTokenFees` and emitting `SellFeeConversionDeferred`. The
    ///      claim is deferred, never destroyed, and the pair-currency fees queued behind it are
    ///      released on the same call.
    ///
    ///      **MEASURED, this scenario, identical to the wei in both currency orderings.** A
    ///      2,000,000e18 dump at a 10% sell tax leaves a 200,000e18 pile against a pool whose
    ///      entire pair reserve is one 1e18 buy (0.03e18 of which is fee):
    ///
    ///      | sweep | before the fix | after the fix |
    ///      |---|---|---|
    ///      | #1, spot pinned AT the limit | revert `PriceLimitAlreadyExceeded(p,p)` | ok - 200,000e18 deferred, pair fees released, holders paid |
    ///      | #2, after a 1e18 buy | revert `CurrencyNotSettled` | ok - partial fill, 199,999.030000940899087327e18 deferred |
    ///      | #3, after a 500,000e18 buy | revert `CurrencyNotSettled` | ok - `pendingTokenFees` -> 0, nothing deferred |
    ///
    ///      Note what sweep #2 shows about the SIZE of a partial fill on a single-sided pool: a
    ///      1e18 buy bought back only 0.97e18 of launch token, so that is all the conversion can
    ///      sell before it runs out of range. The backlog drains at the rate real pair currency
    ///      enters the pool, which is the honest behaviour - and is why it must be carried rather
    ///      than reverted on.
    ///
    ///      Sweep #3 is the part that proves DEFERRED rather than LOST: the same claim, untouched
    ///      through two sweeps the pool could not fill, converts in full once there is pair
    ///      liquidity to convert it against.
    function test_F05_sweepSurvivesASellPileLargerThanThePoolsPairReserve() public {
        PoolKey memory k = _newSingleSidedPool(60, /*buy*/ 300, /*sell*/ 1000);
        PoolId id = k.toId();

        // One small buy, so the pool holds a little pair currency and the fee path is live.
        _buyExactIn(k, bob, 1e18);
        uint256 pairFees = hook.pendingFees(id);
        assertGt(pairFees, 0, "precondition: a pair-currency fee is queued behind the pile");

        // A large holder - a creator allocation, an airdrop, a vested unlock - dumps. The pool's
        // whole pair reserve at this instant is one 1e18 buy, so the 10% tax on this is worth
        // orders of magnitude more pair than the pool can pay.
        token.transfer(alice, 2_000_000e18);
        _sellExactIn(k, alice, 2_000_000e18);

        uint256 pile = hook.pendingTokenFees(id);
        assertGt(pile, 0, "precondition: the sell tax accrued in launch tokens");
        emit log_named_uint("launch tokens owed to holders   ", pile);
        emit log_named_uint("pair currency left in the pool  ", pair.balanceOf(address(manager)));

        // -----------------------------------------------------------------------------------
        // SWEEP #1. Spot is pinned at exactly the limit the conversion swap passes. This is the
        // input that used to revert `PriceLimitAlreadyExceeded(p, p)` before any work was done.
        // -----------------------------------------------------------------------------------
        uint160 pinnedAt = _tokenIsCurrency0()
            ? TickMath.MIN_SQRT_PRICE + 1
            : TickMath.MAX_SQRT_PRICE - 1;
        (uint160 spot,,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), id);
        assertEq(spot, pinnedAt, "precondition: the dump pinned spot AT the conversion's own limit");

        uint256 distBefore = pair.balanceOf(address(dist));
        vm.recordLogs();
        hook.sweep(k);

        assertEq(_deferredInLogs(id), pile, "the whole pile must be reported as deferred");
        assertEq(hook.pendingTokenFees(id), pile, "and returned to the queue, wei for wei");
        assertEq(hook.pendingFees(id), 0, "the pair fees behind it are no longer trapped");
        assertGt(
            pair.balanceOf(address(dist)) - distBefore,
            0,
            "and holders were actually paid out of them"
        );

        // -----------------------------------------------------------------------------------
        // SWEEP #2. A buy lifts spot off the floor, so the swap is legal - and partially fills,
        // because the pool holds far less pair currency than the pile is worth. This is the
        // input that used to revert `CurrencyNotSettled` on the leftover credit.
        // -----------------------------------------------------------------------------------
        _buyExactIn(k, bob, 1e18);
        vm.recordLogs();
        hook.sweep(k);

        uint256 remainder = hook.pendingTokenFees(id);
        assertEq(_deferredInLogs(id), remainder, "the event must report exactly what came back");
        assertLt(remainder, pile, "a partial fill must convert SOME of the pile");
        assertGt(remainder, 0, "this pool cannot absorb all of it yet - that is the whole scenario");
        emit log_named_uint("deferred after the partial fill ", remainder);

        // -----------------------------------------------------------------------------------
        // SWEEP #3. THE PROOF THAT IT WAS DEFERRED AND NOT LOST. Real buying puts real pair
        // currency in the pool, and the SAME claim - carried across two sweeps that could not
        // fill it - now converts completely and reaches the holders.
        // -----------------------------------------------------------------------------------
        _buyExactIn(k, bob, 500_000e18);

        uint256 distBefore3 = pair.balanceOf(address(dist));
        vm.recordLogs();
        hook.sweep(k);

        assertEq(hook.pendingTokenFees(id), 0, "the carried claim finally converted in full");
        assertEq(_deferredInLogs(id), 0, "and nothing was deferred on the way");
        assertGt(
            pair.balanceOf(address(dist)) - distBefore3,
            0,
            "the converted sell tax reached the holders"
        );
        assertEq(hook.pendingFees(id), 0, "and the pool is fully swept");
    }

    /// @dev Sum the `returned` field of every `SellFeeConversionDeferred(bytes32,uint256)` in the
    ///      last recorded trace, for one pool. Zero when the event was never emitted, which is
    ///      exactly the "nothing was deferred" assertion sweep #3 needs.
    function _deferredInLogs(PoolId id) internal view returns (uint256 total) {
        bytes32 sig = keccak256("SellFeeConversionDeferred(bytes32,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] != sig) continue;
            if (logs[i].topics[1] != PoolId.unwrap(id)) continue;
            total += abi.decode(logs[i].data, (uint256));
        }
    }

    // -------------------------------------------------------------------------------------------
    // Negative results - things that were suspected and are NOT exploitable.
    // -------------------------------------------------------------------------------------------

    /// @dev The sweep bounty cannot be farmed. `sweep` has no amount parameter, so a caller cannot
    ///      split one backlog into many; and it zeroes both counters, so a second call in the same
    ///      block returns early and pays nothing.
    function test_sound_sweepBountyCannotBeFarmedByRepetition() public {
        PoolKey memory k = _newPool(60, 300, 0, 0, 2000, 0);

        _buyExactIn(k, alice, 100_000e18);

        uint256 bobBefore = pair.balanceOf(bob);
        vm.prank(bob);
        hook.sweep(k);
        uint256 firstBounty = pair.balanceOf(bob) - bobBefore;
        assertGt(firstBounty, 0, "the first sweep pays");

        for (uint256 i = 0; i < 20; ++i) {
            vm.prank(bob);
            hook.sweep(k);
        }
        assertEq(
            pair.balanceOf(bob) - bobBefore, firstBounty, "repeated sweeps pay nothing extra"
        );
    }

    /// @dev Splitting one backlog across many sweeps strictly LOSES bounty to floor division, so
    ///      there is no incentive to fragment even where a caller controls the trade cadence.
    function test_sound_fragmentingSweepsNeverEarnsMoreBounty() public {
        PoolKey memory kA = _newPool(60, 300, 0, 0, 2000, 0);
        PoolKey memory kB = _newPool(120, 300, 0, 0, 2000, 0);

        // One big backlog, swept once.
        uint256 bobBefore = pair.balanceOf(bob);
        for (uint256 i = 0; i < 5; ++i) _buyExactIn(kA, alice, 20_000e18);
        vm.prank(bob);
        hook.sweep(kA);
        uint256 oneShot = pair.balanceOf(bob) - bobBefore;

        // The same five trades, swept after each one.
        bobBefore = pair.balanceOf(bob);
        for (uint256 i = 0; i < 5; ++i) {
            _buyExactIn(kB, alice, 20_000e18);
            vm.prank(bob);
            hook.sweep(kB);
        }
        uint256 fragmented = pair.balanceOf(bob) - bobBefore;

        emit log_named_uint("bounty, swept once     ", oneShot);
        emit log_named_uint("bounty, swept five ways", fragmented);
        assertLe(fragmented, oneShot + 5, "fragmenting must never pay materially more");
    }

    /// @dev `_routeFee`'s three slices are `p`, `(fee-p)*c/BPS` and the remainder, so they sum to
    ///      exactly `fee` by construction. Asserted end-to-end against a real sweep, at the
    ///      configuration where truncation is worst (a prime fee rate).
    function test_sound_theThreeSlicesSumToExactlyTheSweptAmount() public {
        PoolKey memory k = _newPool(60, 333, 0, 0, 3333, 0);
        PoolId id = k.toId();

        token.transfer(alice, 10_000_000e18);

        uint256 platformBefore = pair.balanceOf(PLATFORM);
        uint256 creatorBefore = pair.balanceOf(creator);
        uint256 distBefore = pair.balanceOf(address(dist));
        uint256 bobBefore = pair.balanceOf(bob);

        _buyExactIn(k, alice, 123_457e18);
        uint256 swept = hook.pendingFees(id);

        vm.prank(bob);
        hook.sweep(k);

        uint256 total = (pair.balanceOf(PLATFORM) - platformBefore)
            + (pair.balanceOf(creator) - creatorBefore)
            + (pair.balanceOf(address(dist)) - distBefore) + (pair.balanceOf(bob) - bobBefore);

        assertEq(total, swept, "every wei swept is accounted for, and not one more");
        assertEq(pair.balanceOf(address(hook)), 0, "the hook retains nothing");
    }

    /// @dev A fee cannot be attributed to the wrong pool: two pools sharing the same token, pair
    ///      currency and hook keep independent `pendingFees`, and sweeping one does not touch the
    ///      other's claims.
    function test_sound_feesAreNotCrossAttributedBetweenPools() public {
        PoolKey memory kA = _newPool(60, 300, 0, 0, 2000, 0);
        PoolKey memory kB = _newPool(120, 900, 0, 0, 2000, 0);

        _buyExactIn(kA, alice, 100_000e18);
        _buyExactIn(kB, bob, 50_000e18);

        assertEq(hook.pendingFees(kA.toId()), (100_000e18 * 300) / 10_000, "pool A charged its own rate");
        assertEq(hook.pendingFees(kB.toId()), (50_000e18 * 900) / 10_000, "pool B charged its own rate");

        hook.sweep(kA);
        assertEq(hook.pendingFees(kA.toId()), 0, "A swept");
        assertEq(hook.pendingFees(kB.toId()), (50_000e18 * 900) / 10_000, "B untouched");

        hook.sweep(kB);
        assertEq(hook.pendingFees(kB.toId()), 0, "B swept independently");
    }

    /// @dev Sweeping a pool whose claims were minted while a DIFFERENT pool shares the same pair
    ///      currency must not let one pool redeem the other's claims. `pendingFees` is the only
    ///      thing burned, and it is per-pool.
    function test_sound_onePoolCannotRedeemAnothersClaims() public {
        PoolKey memory kA = _newPool(60, 300, 0, 0, 2000, 0);
        PoolKey memory kB = _newPool(120, 300, 0, 0, 2000, 0);

        _buyExactIn(kA, alice, 100_000e18);
        uint256 aPending = hook.pendingFees(kA.toId());

        // B has charged nothing, so sweeping B is a no-op even though the hook holds A's claims.
        uint256 distBefore = pair.balanceOf(address(dist));
        assertEq(hook.sweep(kB), 0, "sweeping an empty pool returns zero");
        assertEq(pair.balanceOf(address(dist)), distBefore, "and pays nobody");
        assertEq(hook.pendingFees(kA.toId()), aPending, "A's claims are untouched");
    }
}

/// @notice The launch token is `currency0`.
contract FeeAuditTokenIsCurrency0Test is FeeAuditFindings {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function test_orientation() public view {
        assertTrue(address(token) < address(pair));
    }
}

/// @notice The launch token is `currency1`. Every finding above is re-run in this ordering,
///         because a fee bug that only exists on one side of the sort is the expensive kind.
contract FeeAuditTokenIsCurrency1Test is FeeAuditFindings {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }

    function test_orientation() public view {
        assertTrue(address(pair) < address(token));
    }
}

// ===============================================================================================
// `_marketCap` - overflow and precision across the whole legal price band
// ===============================================================================================

/// @dev `_marketCap` is two chained `FullMath.mulDiv` calls (FeeHook.sol:518-523). This suite
///      writes `slot0` directly so the entire tick range can be swept, rather than trying to push
///      a real pool to `MIN_SQRT_PRICE` / `MAX_SQRT_PRICE` with trades.
contract FeeAuditMarketCapTest is FeeAuditWorld {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));

    PoolKey internal k;
    PoolId internal id;

    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        k = _newPool(60, 300, 0, 0, 2000, 1_000_000e18);
        id = k.toId();
    }

    function _forcePrice(uint160 sqrtPriceX96) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(id), POOLS_SLOT));
        bytes32 cur = vm.load(address(manager), stateSlot);
        // Keep the upper 96 bits (tick / protocolFee / lpFee); replace the low 160.
        bytes32 next = bytes32(
            (uint256(cur) & ~uint256(type(uint160).max)) | uint256(sqrtPriceX96)
        );
        vm.store(address(manager), stateSlot, next);
    }

    /// @dev Sanity: the direct slot write really does move what the hook reads.
    function test_priceForcingWorks() public {
        _forcePrice(TickMath.getSqrtPriceAtTick(0));
        assertEq(hook.marketCapOf(id), SUPPLY, "at 1:1 the market cap is the supply");
    }

    /// @dev Both extremes of the legal band, at the real launch supply. Neither reverts.
    function test_marketCapSurvivesBothTickExtremes() public {
        _forcePrice(TickMath.MIN_SQRT_PRICE);
        assertEq(hook.marketCapOf(id), 0, "at the floor the cap truncates to zero, not a revert");

        _forcePrice(TickMath.MAX_SQRT_PRICE);
        uint256 top = hook.marketCapOf(id);
        assertGt(top, 0, "at the ceiling it is finite and non-zero");
        emit log_named_uint("market cap at MAX_SQRT_PRICE with a 1e27 supply", top);
    }

    /// @dev The full legal price band, at the full legal supply range. Never reverts, never
    ///      overflows, and never reads HIGH - truncation is toward zero at both steps, so a
    ///      graduation can be late by a wei of market cap but never early.
    function testFuzz_marketCapNeverOverflowsAndNeverReadsHigh(uint160 sqrtP, uint256 supply)
        public
    {
        sqrtP = uint160(bound(sqrtP, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        // 1 token .. 10^15 tokens at 18 decimals (a SHIB-sized supply is 10^15).
        supply = bound(supply, 1e18, 1e33);

        PoolKey memory k2 = _newPool(120, 300, 0, 0, 2000, 0);
        hook.configureGraduation(k2, 1, supply);
        PoolId id2 = k2.toId();

        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(id2), POOLS_SLOT));
        bytes32 cur = vm.load(address(manager), stateSlot);
        vm.store(
            address(manager),
            stateSlot,
            bytes32((uint256(cur) & ~uint256(type(uint160).max)) | uint256(sqrtP))
        );

        uint256 got = hook.marketCapOf(id2);

        // A strict UPPER bound on the true market cap: square the price first and round both
        // steps up. `sqrtP <= 2^160` means `sqrtP^2 / 2^96 <= 2^224`, so this cannot overflow
        // either. `got` must never exceed it - the whole safety argument for using this number as
        // a graduation threshold is that it errs LOW.
        uint256 upper = FullMath.mulDivRoundingUp(
            FullMath.mulDivRoundingUp(sqrtP, sqrtP, FixedPoint96.Q96), supply, FixedPoint96.Q96
        );

        assertLe(got, upper, "market cap must never read HIGH");
    }

    /// @dev The overflow boundary, located rather than hand-waved. `_marketCap` reverts once
    ///      `supply * price` would exceed `2^256`. At `MAX_SQRT_PRICE` the price is ~`2^128`, so
    ///      the boundary sits just above a supply of `2^128` wei (~3.4e20 whole tokens) - and it
    ///      ALSO needs a price of ~2^128 pair-wei per token-wei to get there. `Launcher` puts no
    ///      upper bound on `supply`, so this is reachable only by a launch that is absurd on both
    ///      axes at once. A SHIB-sized 1e33 supply is fine at the very top of the tick range.
    function test_marketCapOverflowBoundaryIsUnreachableInPractice() public {
        // Just over the boundary: 2^130 wei of supply at the maximum legal price.
        PoolKey memory over = _newPool(120, 300, 0, 0, 2000, 0);
        hook.configureGraduation(over, 1, uint256(type(uint128).max) * 4);
        _forceMax(over.toId());
        vm.expectRevert();
        hook.marketCapOf(over.toId());

        // A realistic maximum supply at the same maximum price is finite and does not revert.
        PoolKey memory ok = _newPool(200, 300, 0, 0, 2000, 0);
        hook.configureGraduation(ok, 1, 1e33);
        _forceMax(ok.toId());
        assertGt(hook.marketCapOf(ok.toId()), 0, "a 1e33 supply survives the top of the band");
    }

    function _forceMax(PoolId target) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(target), POOLS_SLOT));
        bytes32 cur = vm.load(address(manager), stateSlot);
        vm.store(
            address(manager),
            stateSlot,
            bytes32(
                (uint256(cur) & ~uint256(type(uint160).max)) | uint256(TickMath.MAX_SQRT_PRICE)
            )
        );
    }
}
