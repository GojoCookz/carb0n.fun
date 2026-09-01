// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {FeeHook} from "../src/FeeHook.sol";
import {HookBase} from "../src/base/HookBase.sol";
import {Distributor} from "../src/Distributor.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {LaunchTokenDeployer} from "./utils/LaunchTokenDeployer.sol";

/// @title FeeHookHarness
/// @notice Stands up a complete, real Uniswap v4 world - PoolManager, pool, liquidity, routers -
///         and launches a token against it through the hook.
///
/// @dev **This exists to test one thing that cannot be tested any other way: whether a swap through
///      the pool actually completes.** `FeeHook.afterSwap` returns a positive `int128`, which gives
///      the hook a positive currency delta inside the PoolManager's unlock cycle. If the hook does
///      not `take()` exactly that much, `unlock` ends with a non-zero delta and reverts
///      `CurrencyNotSettled` - which bricks *every swap in the pool*, not just the fee. A unit test
///      with a mocked PoolManager proves nothing about that, because the trap lives in the real
///      manager's settlement accounting.
///
///      Two structural choices worth explaining:
///
///      1. **The hook is placed with `deployCodeTo`, not mined.** `HookBase`'s constructor asserts
///         the deployed address encodes exactly `getHookPermissions()`, so the address must be
///         `0x2044` in its low 14 bits. Mining a real CREATE2 salt takes minutes per run; placing
///         the code at a chosen address takes microseconds and exercises the identical constructor
///         check.
///
///      2. **The LaunchToken's CREATE2 salt IS mined**, because currency ordering is not cosmetic.
///         v4 requires `currency0 < currency1` strictly, so which side the launch token lands on
///         changes the sign of every delta the hook inspects. Real launchpads mine this salt for
///         exactly this reason. Every test below runs in BOTH orientations via two concrete
///         subclasses, because a fee hook that works in one and silently no-ops in the other is the
///         most expensive kind of passing test suite.
abstract contract FeeHookHarness is Test, LaunchTokenDeployer {
    using PoolIdLibrary for PoolKey;

    PoolManager internal manager;
    /// Where the platform's 1% of volume lands. A distinct address from every other actor in
    /// these tests on purpose: routing it to `address(this)` would hide a misrouted fee inside
    /// the test contract's own balance, which is exactly the bug worth catching.
    address internal constant PLATFORM = address(0xFEE0);
    FeeHook internal hook;
    LaunchToken internal token;
    Distributor internal dist;
    MockERC20 internal pair;

    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;

    PoolKey internal key;
    PoolId internal poolId;

    address internal creator = address(0xC0EA702);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant MIN_PUSH = 1e6;
    uint256 internal constant MIN_QUEUE = 1e18;

    /// @dev 3% total fee, of which 20% goes to the creator and 80% to holders.
    uint16 internal constant FEE_BPS = 300;
    uint16 internal constant CREATOR_BPS = 2000;

    int24 internal constant TICK_SPACING = 60;

    /// @notice Set by the concrete subclass. Decides which side of the pool the launch token is on.
    function _tokenIsCurrency0() internal pure virtual returns (bool);

    /// @notice Sells are free by default, which is what every existing test below assumes.
    function _sellFeeBps() internal pure virtual returns (uint16) {
        return 0;
    }

    /// @notice No buyback by default.
    function _burnBps() internal pure virtual returns (uint16) {
        return 0;
    }

    /// @dev Buying the launch token means paying the PAIR currency and receiving the token.
    ///      `zeroForOne` therefore depends entirely on which side the token sorted onto.
    function _buyIsZeroForOne() internal pure returns (bool) {
        return !_tokenIsCurrency0();
    }

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        pair = new MockERC20("Wrapped Ether", "WETH", 18);
        _deployLaunchTokenImpl();

        // 0x20CC = BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP
        //          | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA.
        // The high bits are arbitrary; only the low 14 are read by the PoolManager.
        address hookAddr = address(uint160(uint256(0xF00D) << 144 | 0x20CC));
        deployCodeTo("FeeHook.sol:FeeHook", abi.encode(address(manager), address(this), PLATFORM), hookAddr);
        hook = FeeHook(hookAddr);

        token = _deployLaunchTokenSorted(address(pair), _tokenIsCurrency0());
        dist = token.distributor();

        (Currency c0, Currency c1) = _tokenIsCurrency0()
            ? (Currency.wrap(address(token)), Currency.wrap(address(pair)))
            : (Currency.wrap(address(pair)), Currency.wrap(address(token)));

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            // The pool's own fee is ZERO: the hook charges instead. Any indexer reading
            // `PoolKey.fee` will report the trading cost as 0%. That is a documented consequence
            // of taking the fee in the hook, and it is why `FeeTaken` is emitted.
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        poolId = key.toId();

        hook.configurePoolFull(
            key,
            FeeHook.FeeSetup({
                distributor: address(dist),
                pairCurrency: Currency.wrap(address(pair)),
                feeBps: FEE_BPS,
                sellFeeBps: _sellFeeBps(),
                burnBps: _burnBps(),
                creator: creator,
                creatorBps: CREATOR_BPS,
                rewardCurrency: Currency.wrap(address(0))
            })
        );
        // A real launch always registers graduation alongside the fee, and that is where the
        // auto-sweep threshold is armed. Configuring only the fee here left this harness in a
        // state `Launcher` can never produce, which is how the auto path went untested.
        hook.configureGraduation(key, 1_000_000e18, SUPPLY);

        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        _seedLiquidity();
        _fundTrader(alice);
        _fundTrader(bob);

        // The test contract trades too (it is also the launcher and the LP).
        pair.mint(address(this), 100_000_000e18);
        pair.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
    }

    // ===============================================================================================
    // Harness internals
    // ===============================================================================================

    /// @dev Mines a clone salt so the launch token sorts onto the requested side of the pair.
    function _deployLaunchTokenSorted(address pairAddr, bool wantCurrency0) internal returns (LaunchToken) {
        LaunchToken.InitParams memory p = LaunchToken.InitParams({
            name_: "Hoodstonk",
            symbol_: "HOOD",
            supply: SUPPLY,
            recipient: address(this), // launcher / initial recipient
            payoutToken: pairAddr,
                rewardToken: address(0),
                converter: address(0), // dividends paid in the PAIR asset
            controller: address(hook),
            poolManager_: address(manager),
            maxWallet_: 0, // the cap has its own suite
            minPushPayout: MIN_PUSH,
            minShareForQueue: MIN_QUEUE,
            metadata: _defaultMetadata()
        });

        for (uint256 i = 0; i < 4096; ++i) {
            bytes32 salt = bytes32(i);
            if ((_predictClone(salt) < pairAddr) == wantCurrency0) {
                return _cloneAndInit(salt, p);
            }
        }
        revert("no salt found for requested currency ordering");
    }

    /// @dev Full-range liquidity at a 1:1 price, deep enough that test swaps barely move it.
    function _seedLiquidity() internal {
        pair.mint(address(this), 500_000_000e18);

        token.approve(address(lpRouter), type(uint256).max);
        pair.approve(address(lpRouter), type(uint256).max);

        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 100_000_000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _fundTrader(address who) internal {
        pair.mint(who, 10_000_000e18);
        vm.startPrank(who);
        pair.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Swaps, then sweeps.
    ///
    ///      Since single-sided seeding, a fee is taken inside the swap as an ERC-6909 CLAIM and
    ///      redeemed for real tokens by `sweep()` afterwards - a fresh pool holds no pair currency
    ///      for `take()` to draw on. Sweeping here keeps every test below about the economics
    ///      rather than about the plumbing; `test_feesAccrueAsClaimsUntilSwept` is the one that
    ///      pins the unswept state deliberately.
    function _swap(address who, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        vm.prank(who);
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        hook.sweep(key);
        return delta;
    }

    /// @dev The bounty is what makes sweeping a job somebody takes rather than a favour. It comes
    ///      out of the swept amount, before the creator/holder split, and it goes to whoever
    ///      called - which is deliberately allowed to be a complete stranger.
    function test_sweepPaysItsCallerABounty() public {
        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _buyIsZeroForOne(),
                amountSpecified: -5e18,
                sqrtPriceLimitX96: _buyIsZeroForOne()
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 pending = hook.pendingFees(poolId);
        assertGt(pending, 0, "nothing to sweep");

        // Bob holds no position and did not trade. He should still be paid for doing the work.
        uint256 bobBefore = pair.balanceOf(bob);
        vm.prank(bob);
        hook.sweep(key);

        // The burn wedge is spent first, so the bounty is a share of what survives it.
        uint256 afterBurn = (pending * (10_000 - _burnBps())) / 10_000;
        assertApproxEqAbs(
            pair.balanceOf(bob) - bobBefore,
            (afterBurn * hook.SWEEP_BOUNTY_BPS()) / 10_000,
            2,
            "caller was not paid exactly the bounty"
        );
    }

    /// @dev The automatic path. Once the backlog clears the threshold a trade pays holders on its
    ///      way through, with nobody having to call anything.
    function test_autoSweepFiresOnceTheBacklogIsWorthIt() public {
        assertGt(hook.autoSweepThreshold(poolId), 0, "auto sweep must be armed at launch");

        // Manual first buy, so the backlog exists without the harness sweeping it away.
        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _buyIsZeroForOne(),
                amountSpecified: -int256(hook.autoSweepThreshold(poolId) * 500),
                sqrtPriceLimitX96: _buyIsZeroForOne()
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // An exact-OUTPUT buy runs the afterSwap leg, which is where the auto path is attempted.
        uint256 ledgerBefore = pair.balanceOf(address(dist));
        _giveTokens(bob, 1_000_000e18);
        _buyExactOut(alice, 100_000e18);

        assertGt(
            pair.balanceOf(address(dist)),
            ledgerBefore,
            "holders were not paid without anyone calling sweep"
        );
    }

    /// @dev The behaviour change made explicit: a trade charges the fee immediately, but the value
    ///      sits as a claim on the PoolManager until somebody sweeps. Anyone may.
    function test_feesAccrueAsClaimsUntilSwept() public {
        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: _buyIsZeroForOne(),
                amountSpecified: -1e18,
                sqrtPriceLimitX96: _buyIsZeroForOne()
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(hook.pendingFees(poolId), (uint256(1e18) * FEE_BPS) / 10_000, "charged on the trade");
        assertEq(pair.balanceOf(address(dist)), 0, "but not yet delivered");

        // Permissionless: a stranger with no position can redeem it for everyone.
        vm.prank(bob);
        hook.sweep(key);

        assertEq(hook.pendingFees(poolId), 0, "claim redeemed");
        assertGt(pair.balanceOf(address(dist)), 0, "and the holders' share landed");
    }

    /// @dev Buy the launch token with `amountIn` of the pair currency (exact input).
    function _buyExactIn(address who, uint256 amountIn) internal returns (BalanceDelta) {
        return _swap(who, _buyIsZeroForOne(), -int256(amountIn));
    }

    /// @dev Buy exactly `amountOut` of the launch token, paying whatever the pair costs.
    function _buyExactOut(address who, uint256 amountOut) internal returns (BalanceDelta) {
        return _swap(who, _buyIsZeroForOne(), int256(amountOut));
    }

    /// @dev Sell `amountIn` of the launch token for the pair currency (exact input).
    function _sellExactIn(address who, uint256 amountIn) internal returns (BalanceDelta) {
        return _swap(who, !_buyIsZeroForOne(), -int256(amountIn));
    }

    /// @dev Sell the launch token for exactly `amountOut` of the pair currency.
    function _sellExactOut(address who, uint256 amountOut) internal returns (BalanceDelta) {
        return _swap(who, !_buyIsZeroForOne(), int256(amountOut));
    }

    /// @dev Give `who` a real holder position without routing through the pool.
    function _giveTokens(address who, uint256 amount) internal {
        token.transfer(who, amount);
    }

    // ===============================================================================================
    // Hook address and permissions
    // ===============================================================================================

    /// @dev The whole hook system is address-encoded. If this drifts, the PoolManager silently stops
    ///      calling the callbacks the hook relies on and the fee quietly becomes zero.
    function test_hookAddressEncodesExactly0x20CC() public view {
        assertEq(uint160(address(hook)) & 0x3FFF, 0x20CC, "hook address must encode 0x20CC");
    }

    function test_permissionsMatchTheMinedFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize, "beforeInitialize");
        assertTrue(p.beforeSwap, "beforeSwap - required to charge exact-input buys");
        assertTrue(p.beforeSwapReturnDelta, "beforeSwapReturnDelta");
        assertTrue(p.afterSwap, "afterSwap");
        assertTrue(p.afterSwapReturnDelta, "afterSwapReturnDelta");
        assertFalse(p.beforeAddLiquidity, "beforeAddLiquidity must stay off");
        assertFalse(p.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta must stay off");
    }

    /// @dev A callback reached from anywhere but the PoolManager must revert, or anyone can forge
    ///      a swap result and drain the fee path.
    function test_callbacksRejectNonPoolManagerCallers() public {
        vm.expectRevert(abi.encodeWithSelector(HookBase.NotPoolManager.selector));
        hook.beforeInitialize(address(this), key, TickMath.getSqrtPriceAtTick(0));
    }

    // ===============================================================================================
    // Configuration
    // ===============================================================================================

    function test_configurePool_revertsForNonLauncher() public {
        PoolKey memory other = key;
        other.tickSpacing = 120;

        vm.prank(alice);
        vm.expectRevert(FeeHook.OnlyLauncher.selector);
        hook.configurePool(other, address(dist), Currency.wrap(address(pair)), FEE_BPS, creator, CREATOR_BPS);
    }

    /// @dev Immutability is the anti-rug property: a fee split that can change after people buy is
    ///      a rug with extra steps.
    function test_configurePool_revertsOnReconfigure() public {
        vm.expectRevert(FeeHook.AlreadyConfigured.selector);
        hook.configurePool(key, address(dist), Currency.wrap(address(pair)), 100, creator, 0);
    }

    function test_configurePool_revertsAboveFeeCap() public {
        PoolKey memory other = key;
        other.tickSpacing = 120;

        uint16 tooHigh = hook.MAX_FEE_BPS() + 1;
        vm.expectRevert(abi.encodeWithSelector(FeeHook.FeeTooHigh.selector, tooHigh));
        hook.configurePool(other, address(dist), Currency.wrap(address(pair)), tooHigh, creator, CREATOR_BPS);
    }

    function test_configurePool_revertsOnZeroCreator() public {
        PoolKey memory other = key;
        other.tickSpacing = 120;

        vm.expectRevert(FeeHook.ZeroAddress.selector);
        hook.configurePool(
            other, address(dist), Currency.wrap(address(pair)), FEE_BPS, address(0), CREATOR_BPS
        );
    }

    /// @dev **A hook without this check is a free fee collector for strangers.** Anyone may call
    ///      `PoolManager.initialize` naming our hook; `beforeInitialize` is the only thing that
    ///      stops an unconfigured pool attaching itself to us.
    function test_strangerCannotOpenAPoolAgainstThisHook() public {
        MockERC20 rogue = new MockERC20("Rogue", "ROGUE", 18);

        (Currency c0, Currency c1) = address(rogue) < address(pair)
            ? (Currency.wrap(address(rogue)), Currency.wrap(address(pair)))
            : (Currency.wrap(address(pair)), Currency.wrap(address(rogue)));

        PoolKey memory rogueKey = PoolKey({
            currency0: c0, currency1: c1, fee: 0, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))
        });

        vm.prank(alice);
        vm.expectRevert();
        manager.initialize(rogueKey, TickMath.getSqrtPriceAtTick(0));
    }

    // ===============================================================================================
    // The CurrencyNotSettled trap - all four swap shapes must complete
    // ===============================================================================================

    function test_exactInputBuyCompletes() public {
        _buyExactIn(alice, 10_000e18);
        assertGt(token.balanceOf(alice), 0, "buyer must actually receive the launch token");
    }

    function test_exactOutputBuyCompletes() public {
        uint256 pairBefore = pair.balanceOf(alice);
        _buyExactOut(alice, 10_000e18);
        assertEq(token.balanceOf(alice), 10_000e18, "exact-output buy must deliver exactly");
        assertLt(pair.balanceOf(alice), pairBefore, "buyer must have paid");
    }

    function test_exactInputSellCompletes() public {
        _buyExactIn(alice, 10_000e18);
        uint256 held = token.balanceOf(alice);

        uint256 pairBefore = pair.balanceOf(alice);
        _sellExactIn(alice, held);

        assertEq(token.balanceOf(alice), 0, "seller must be able to exit fully");
        assertGt(pair.balanceOf(alice), pairBefore, "seller must receive the pair currency");
    }

    function test_exactOutputSellCompletes() public {
        _buyExactIn(alice, 50_000e18);
        uint256 pairBefore = pair.balanceOf(alice);

        _sellExactOut(alice, 1_000e18);

        assertEq(pair.balanceOf(alice) - pairBefore, 1_000e18, "exact-output sell must deliver exactly");
    }

    /// @dev Many swaps in sequence, both directions, both exactness modes. If settlement is off by a
    ///      wei anywhere, one of these reverts.
    function test_manySwapsInSequenceAllComplete() public {
        for (uint256 i = 0; i < 6; ++i) {
            _buyExactIn(alice, 5_000e18);
            _buyExactOut(bob, 3_000e18);
            _sellExactIn(alice, 1_000e18);
            _sellExactOut(bob, 500e18);
        }
        assertGt(token.balanceOf(alice), 0);
        assertGt(token.balanceOf(bob), 0);
    }

    // ===============================================================================================
    // Fee routing - the money test
    // ===============================================================================================

    function test_exactOutputBuyChargesAFee() public {
        uint256 before = hook.totalFeesTaken(poolId);
        _buyExactOut(bob, 100_000e18);
        assertGt(hook.totalFeesTaken(poolId) - before, 0, "an exact-output buy must pay the holders");
    }

    /// @dev **The coverage matrix, measured rather than argued.** Every one of the four swap shapes,
    ///      asserted independently:
    ///
    ///      ```
    ///                          specified   unspecified   charged in    charged?
    ///        buy  exact-in       pair         token      beforeSwap      YES
    ///        buy  exact-out      token        pair       afterSwap       YES
    ///        sell exact-in       token        pair       -               no (sells are free)
    ///        sell exact-out      pair         token      -               no (sells are free)
    ///      ```
    ///
    ///      **This is the test that caught the original bug.** Before `beforeSwap` was added, the
    ///      first row read `0` - the hook collected nothing on an exact-input buy, which is the
    ///      shape every router, aggregator and swap UI sends by default. The pool worked and the fee
    ///      silently did not.
    function test_everyBuyShapeIsChargedAndNoSellIs() public {
        uint256 f0 = hook.totalFeesTaken(poolId);
        _buyExactIn(bob, 100_000e18);
        uint256 exactInBuyFee = hook.totalFeesTaken(poolId) - f0;

        uint256 f1 = hook.totalFeesTaken(poolId);
        _sellExactIn(bob, 10_000e18);
        uint256 exactInSellFee = hook.totalFeesTaken(poolId) - f1;

        uint256 f2 = hook.totalFeesTaken(poolId);
        _sellExactOut(bob, 1_000e18);
        uint256 exactOutSellFee = hook.totalFeesTaken(poolId) - f2;

        uint256 f3 = hook.totalFeesTaken(poolId);
        _buyExactOut(bob, 100_000e18);
        uint256 exactOutBuyFee = hook.totalFeesTaken(poolId) - f3;

        assertGt(exactInBuyFee, 0, "REGRESSION MARKER: exact-input buys must be charged");
        assertGt(exactOutBuyFee, 0, "exact-output buys must be charged");
        assertEq(exactInSellFee, 0, "sells are free by design (the fee must be in the pair currency)");
        assertEq(exactOutSellFee, 0, "sells are free by design");
    }

    /// @dev An exact-input buy is charged exactly `feeBps` of the stated input, and the trader's
    ///      wallet is debited exactly what they asked to spend - the fee comes out of the amount
    ///      that reaches the curve, not on top of it.
    function test_exactInputBuyChargesExactlyTheConfiguredRate() public {
        uint256 amountIn = 100_000e18;
        uint256 pairBefore = pair.balanceOf(bob);

        _buyExactIn(bob, amountIn);

        assertEq(pairBefore - pair.balanceOf(bob), amountIn, "trader spends exactly what they specified");
        assertEq(
            hook.totalFeesTaken(poolId), (amountIn * FEE_BPS) / 10_000, "fee is exactly feeBps of the input"
        );
    }

    /// @dev The commercial test. Ordinary router traffic - plain exact-input buys - must pay
    ///      holders. This asserted zero before the fix.
    function test_defaultRouterBehaviourPaysHolders() public {
        _giveTokens(alice, 10_000_000e18);

        // Ten ordinary exact-input buys - the shape a Uniswap frontend sends.
        for (uint256 i = 0; i < 10; ++i) {
            _buyExactIn(bob, 100_000e18);
        }

        assertEq(
            hook.totalFeesTaken(poolId),
            (uint256(1_000_000e18) * FEE_BPS) / 10_000,
            "ten normal buys pay in full"
        );
        assertGt(dist.withdrawableOf(alice), 0, "and a holder who did nothing is owed real money");
    }

    /// @dev A trade must never be charged by both legs. The two charging paths are mutually
    ///      exclusive on exactness, and this pins that: one buy of a given size costs the same
    ///      whether it is expressed as exact-in or exact-out, within curve slippage.
    function test_buyIsNeverDoubleCharged() public {
        uint256 amountIn = 100_000e18;
        _buyExactIn(bob, amountIn);
        uint256 charged = hook.totalFeesTaken(poolId);

        assertEq(charged, (amountIn * FEE_BPS) / 10_000, "charged once, not twice");
        assertLe(charged * 10_000, amountIn * FEE_BPS, "never more than the configured rate");
    }

    /// @dev THE test. A holder who did nothing but hold must be able to withdraw pair currency that
    ///      came from someone else's trade. Until this passes there is no launchpad.
    function test_tradingIncreasesWithdrawableForAHolder() public {
        _giveTokens(alice, 10_000_000e18);
        assertEq(dist.withdrawableOf(alice), 0, "nothing owed before any trade");

        _buyExactOut(bob, 500_000e18);

        assertGt(dist.withdrawableOf(alice), 0, "a holder must accrue from someone else's trade");

        uint256 owed = dist.withdrawableOf(alice);
        uint256 pairBefore = pair.balanceOf(alice);

        vm.prank(alice);
        dist.withdraw();

        assertEq(pair.balanceOf(alice) - pairBefore, owed, "paid in the PAIR currency");
        assertEq(token.balanceOf(alice), 10_000_000e18, "launch token balance untouched");
    }

    function test_creatorReceivesConfiguredShare() public {
        _giveTokens(alice, 10_000_000e18);

        uint256 creatorBefore = pair.balanceOf(creator);
        _buyExactOut(bob, 500_000e18);

        uint256 total = hook.totalFeesTaken(poolId);
        uint256 creatorGot = pair.balanceOf(creator) - creatorBefore;
        uint256 holdersGot = pair.balanceOf(address(dist));

        assertGt(total, 0, "fee must have been taken at all");
        assertGt(creatorGot, 0, "creator was paid nothing");

        // Assert the SPLIT, not a reconstructed absolute. Three things now come off a fee before
        // it is divided - the burn wedge, the sweep bounty, and a burn share reserved by an
        // automatic sweep for a later manual one - and which of them applied depends on how many
        // trades took the auto path versus the manual path. Reconstructing that arithmetic in a
        // test just re-implements the contract and asserts it against itself.
        //
        // What must hold on every path is the RATIO: of everything that reaches the two of them,
        // the creator's cut is exactly `creatorBps`. That is the promise made at launch.
        uint256 distributed = creatorGot + holdersGot;
        assertApproxEqRel(
            (creatorGot * 10_000) / distributed,
            CREATOR_BPS,
            1e15, // 0.1%
            "creator and holders were not split at the configured rate"
        );
    }

    /// @dev The hook is a conduit, not a treasury. Anything it retains is stranded forever - it has
    ///      no sweep function and no owner.
    function test_hookRetainsNothingAfterASwap() public {
        _giveTokens(alice, 10_000_000e18);
        _buyExactOut(bob, 500_000e18);

        assertEq(pair.balanceOf(address(hook)), 0, "hook must forward every wei it takes");
        assertEq(token.balanceOf(address(hook)), 0, "hook must never hold the launch token");
    }

    // ===============================================================================================
    // Dividend leakage into the pool
    // ===============================================================================================

    /// @dev **Regression guard for the largest hole this suite found.**
    ///
    ///      In v4 there is no per-pair contract: the pool's reserves are an ERC-20 balance on the
    ///      singleton PoolManager, and that balance is the entire unsold supply. Before the fix the
    ///      manager was the biggest "holder" in the book and was allocated more of every
    ///      distribution than a real holder - measured at 10x alice's share in this harness.
    ///
    ///      It could not be fixed after deployment either: `setExcluded` is `onlyController`, the
    ///      controller is the fee hook, and the hook has no function that calls through. The
    ///      exclusion therefore has to happen in the Distributor's constructor.
    function test_poolManagerNeverAccruesDividends() public {
        _giveTokens(alice, 10_000_000e18);

        assertTrue(dist.excluded(address(manager)), "the pool must be excluded at construction");
        assertEq(dist.shareOf(address(manager)), 0, "the pool must hold zero dividend shares");
        assertGt(token.balanceOf(address(manager)), 0, "...despite holding most of the supply");

        _buyExactOut(bob, 500_000e18);

        assertEq(dist.withdrawableOf(address(manager)), 0, "the pool must be owed nothing");
        assertGt(dist.withdrawableOf(alice), 0, "a real holder still accrues");
    }

    /// @dev The push path must never raw-transfer the pair currency into the singleton. An unsynced
    ///      ERC-20 arriving at the PoolManager is not a donation - it is an unowned balance that the
    ///      next caller to `sync`/`settle` can claim for free.
    function test_pushQueueNeverPaysThePoolManager() public {
        _giveTokens(alice, 10_000_000e18);
        _buyExactOut(bob, 500_000e18);

        uint256 managerPairBefore = pair.balanceOf(address(manager));

        dist.processBatch(dist.queueLength());

        assertEq(
            pair.balanceOf(address(manager)), managerPairBefore, "no dividend may be pushed into the pool"
        );
        assertGt(pair.balanceOf(alice), 0, "but real holders are paid");
    }

    /// @dev Shares must track only tokens in real hands. Both pieces of infrastructure that hold
    ///      supply - the pool (reserves) and the launcher (conduit) - are excluded, so `totalShares`
    ///      is exactly the sum of genuine holder balances and nothing else.
    function test_totalSharesCountsOnlyRealHolders() public {
        _giveTokens(alice, 10_000_000e18);
        _giveTokens(bob, 4_000_000e18);

        assertEq(dist.shareOf(address(manager)), 0, "pool holds no shares");
        assertEq(dist.shareOf(address(this)), 0, "launcher holds no shares");
        assertGt(token.balanceOf(address(manager)), 0, "...though both hold real balances");
        assertGt(token.balanceOf(address(this)), 0);

        assertEq(
            dist.totalShares(),
            dist.shareOf(alice) + dist.shareOf(bob),
            "totalShares is exactly the real holders"
        );
        assertEq(dist.totalShares(), 14_000_000e18, "and matches what was actually handed out");
    }

    /// @dev Conservation: the distributor can never owe more than the hook actually delivered.
    function testFuzz_distributorNeverOwesMoreThanItReceived(uint256 amountOut) public {
        amountOut = bound(amountOut, 1e18, 1_000_000e18);
        _giveTokens(alice, 10_000_000e18);
        _giveTokens(bob, 5_000_000e18);

        _buyExactOut(address(this), amountOut);

        assertLe(
            dist.withdrawableOf(alice) + dist.withdrawableOf(bob),
            pair.balanceOf(address(dist)),
            "solvency: owed <= held"
        );
    }

    /// @dev The fee taken can never exceed the configured rate on the amount that moved.
    function testFuzz_feeNeverExceedsConfiguredRate(uint256 amountOut) public {
        amountOut = bound(amountOut, 1e18, 1_000_000e18);

        uint256 pairBefore = pair.balanceOf(address(this));

        _buyExactOut(address(this), amountOut);

        uint256 paid = pairBefore - pair.balanceOf(address(this));
        uint256 fee = hook.totalFeesTaken(poolId);

        assertLe(fee * 10_000, paid * FEE_BPS + 10_000, "fee must not exceed the configured bps of the input");
    }
}

/// @notice The launch token sorted BELOW the pair, so the token is `currency0`.
contract FeeHookTokenIsCurrency0Test is FeeHookHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function test_orientationIsWhatThisSuiteClaims() public view {
        assertEq(Currency.unwrap(key.currency0), address(token));
        assertEq(Currency.unwrap(key.currency1), address(pair));
    }
}

/// @notice The launch token sorted ABOVE the pair, so the token is `currency1`.
contract FeeHookTokenIsCurrency1Test is FeeHookHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }

    function test_orientationIsWhatThisSuiteClaims() public view {
        assertEq(Currency.unwrap(key.currency0), address(pair));
        assertEq(Currency.unwrap(key.currency1), address(token));
    }
}

/// @notice The same world, but with a SELL TAX and a BUYBACK-AND-BURN wedge armed.
///
/// @dev These are the two features single-sided seeding unlocked. A sell pays launch tokens in, so
///      its fee cannot be taken in the pair currency - there is none coming in. It is taken in the
///      token instead and converted during `sweep`, which is only possible because `sweep` runs
///      outside the swap. The burn wedge then spends a share of the swept pair currency buying the
///      token back from its own pool and destroying it.
abstract contract FeeHookWedgeHarness is FeeHookHarness {
    function _sellFeeBps() internal pure override returns (uint16) {
        return 500; // 5% on the way out
    }

    function _burnBps() internal pure override returns (uint16) {
        return 2000; // 20% of every swept fee buys back and burns
    }

    function test_sellIsChargedInTheLaunchToken() public {
        _buyExactIn(alice, 10e18);
        uint256 held = token.balanceOf(alice);

        vm.prank(alice);
        token.approve(address(swapRouter), type(uint256).max);

        uint256 pendingBefore = hook.pendingTokenFees(poolId);
        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !_buyIsZeroForOne(),
                amountSpecified: -int256(held / 2),
                sqrtPriceLimitX96: !_buyIsZeroForOne()
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(
            hook.pendingTokenFees(poolId) - pendingBefore,
            ((held / 2) * 500) / 10_000,
            "the sell fee is exactly 5% of the tokens sold, in tokens"
        );
    }

    /// @dev The conversion. Tokens taken from sellers come out the other side as pair currency in
    ///      the holders' ledger - which is the whole promise of paying dividends in the pair.
    function test_sellTaxBecomesPairCurrencyForHolders() public {
        _buyExactIn(alice, 20e18);
        _giveTokens(bob, 1_000_000e18); // a holder who is owed the proceeds

        uint256 held = token.balanceOf(alice);
        vm.prank(alice);
        token.approve(address(swapRouter), type(uint256).max);
        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !_buyIsZeroForOne(),
                amountSpecified: -int256(held / 2),
                sqrtPriceLimitX96: !_buyIsZeroForOne()
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertGt(hook.pendingTokenFees(poolId), 0, "charged in tokens");
        uint256 ledgerBefore = pair.balanceOf(address(dist));

        hook.sweep(key);

        assertEq(hook.pendingTokenFees(poolId), 0, "token claim converted");
        assertGt(
            pair.balanceOf(address(dist)),
            ledgerBefore,
            "and it arrived as PAIR currency, not as more of the token"
        );
    }

    /// @dev The burn wedge. Supply only ever goes down, and the tokens land at the dead address
    ///      rather than being held by anyone.
    function test_burnWedgeBuysBackAndDestroys() public {
        uint256 deadBefore = token.balanceOf(address(0xdEaD));

        _buyExactIn(alice, 20e18); // _swap sweeps, so the burn runs inside this call

        assertGt(hook.totalBurned(poolId), 0, "a buyback happened");
        assertEq(
            token.balanceOf(address(0xdEaD)) - deadBefore,
            hook.totalBurned(poolId),
            "every burned token is at the dead address"
        );
    }
}

contract FeeHookWedgeTokenIsCurrency0Test is FeeHookWedgeHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract FeeHookWedgeTokenIsCurrency1Test is FeeHookWedgeHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
