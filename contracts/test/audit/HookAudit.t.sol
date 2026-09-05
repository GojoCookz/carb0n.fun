// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Launcher} from "../../src/Launcher.sol";
import {FeeHook} from "../../src/FeeHook.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {Distributor} from "../../src/Distributor.sol";
import {PairRegistry} from "../../src/PairRegistry.sol";
import {LaunchMetadata} from "../../src/types/LaunchMetadata.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

// ===============================================================================================
// Probes
// ===============================================================================================

/// @notice A router that PAYS ITS INPUT BEFORE SWAPPING - `sync` -> `transfer` -> `swap` ->
///         `settle` - rather than the `swap` -> `sync` -> `transfer` -> `settle` order every
///         Uniswap-supplied router uses.
///
/// @dev Both orders are legal v4. The difference is that `PoolManager._settle` credits
///      `balanceOfSelf() - syncedReserves`, so ANY ERC-20 that leaves the singleton between the
///      `sync` and the `settle` is silently deducted from what the payer is credited. A hook that
///      calls `poolManager.take()` from inside `afterSwap` does exactly that.
///
///      It resolves whatever deltas remain afterwards, so the probe itself can never be the cause
///      of a `CurrencyNotSettled`, and it returns what `settle()` actually credited so a test can
///      compare it against what was handed over.
contract SyncFirstRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    struct D {
        address payer;
        PoolKey key;
        SwapParams params;
        uint256 prepay;
    }

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory key, SwapParams memory params, uint256 prepay)
        external
        returns (uint256 credited)
    {
        credited = abi.decode(
            manager.unlock(abi.encode(D(msg.sender, key, params, prepay))), (uint256)
        );
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        D memory d = abi.decode(raw, (D));

        Currency inC = d.params.zeroForOne ? d.key.currency0 : d.key.currency1;
        Currency outC = d.params.zeroForOne ? d.key.currency1 : d.key.currency0;

        // THE PATTERN UNDER TEST.
        manager.sync(inC);
        IERC20(Currency.unwrap(inC)).transferFrom(d.payer, address(manager), d.prepay);

        manager.swap(d.key, d.params, "");

        uint256 credited = manager.settle();

        // Clean up so the probe is never itself the reason a cycle fails to balance.
        int256 dIn = manager.currencyDelta(address(this), inC);
        if (dIn < 0) {
            manager.sync(inC);
            IERC20(Currency.unwrap(inC)).transferFrom(d.payer, address(manager), uint256(-dIn));
            manager.settle();
        } else if (dIn > 0) {
            manager.take(inC, d.payer, uint256(dIn));
        }

        int256 dOut = manager.currencyDelta(address(this), outC);
        if (dOut > 0) manager.take(outC, d.payer, uint256(dOut));

        return abi.encode(credited);
    }
}

/// @notice Calls `FeeHook.sweep` from INSIDE an already-open unlock cycle.
/// @dev `sweep` calls `poolManager.unlock`, and v4's `Lock` is a single global transient flag, so
///      this is the shape that would reveal a re-entrant `unlock`.
contract UnlockReentrantSweeper is IUnlockCallback {
    IPoolManager public immutable manager;
    FeeHook public immutable hook;

    constructor(IPoolManager m, FeeHook h) {
        manager = m;
        hook = h;
    }

    function attack(PoolKey memory k) external {
        manager.unlock(abi.encode(k));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        PoolKey memory k = abi.decode(raw, (PoolKey));
        hook.sweep(k);
        return "";
    }
}

// ===============================================================================================
// World - the REAL Launcher, so every pool below is seeded exactly the way production seeds one
// ===============================================================================================

/// @dev `FeeHook.t.sol`'s harness seeds a SYMMETRIC full-range pool at a 1:1 price with liquidity
///      on both sides. Production never has that: `Launcher._seedLiquidity` puts the entire supply
///      in ONE single-sided position starting at the opening tick, and the pool holds zero pair
///      currency until somebody buys. Every finding in this file needs the production shape, so
///      this world drives the real `Launcher` rather than an `lpRouter.modifyLiquidity` shortcut.
abstract contract HookAuditWorld is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolManager internal manager;
    PairRegistry internal registry;
    FeeHook internal hook;
    Launcher internal launcher;
    LaunchToken internal tokenImpl;
    MockERC20 internal pair;
    PoolSwapTest internal swapRouter;
    SyncFirstRouter internal syncRouter;

    address internal constant PLATFORM = address(0xFEE0);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal creator = address(0xC0EA702);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant OPENING_MCAP = 100e18;
    int24 internal constant TICK_SPACING = 60;

    uint256 internal saltNonce = 1;

    /// @notice Set by the concrete subclass: which side of the pool the launch token sorts onto.
    function _tokenIsCurrency0() internal pure virtual returns (bool);

    /// @dev Buying the launch token means paying the pair currency in.
    function _buyIsZeroForOne() internal pure returns (bool) {
        return !_tokenIsCurrency0();
    }

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        registry = new PairRegistry(address(this));
        tokenImpl = new LaunchToken();
        pair = new MockERC20("Wrapped Ether", "WETH", 18);
        registry.approvePairWithoutOracle(address(pair), 18);

        // Same circular-immutable dance the deploy script has to do: reserve the launcher's CREATE
        // address, place the hook against it, then deploy the launcher into the reserved slot.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address hookAddr = address(uint160(uint256(0xBEEF) << 144 | 0x20CC));
        deployCodeTo(
            "FeeHook.sol:FeeHook", abi.encode(address(manager), predicted, PLATFORM), hookAddr
        );
        hook = FeeHook(hookAddr);
        launcher = new Launcher(IPoolManager(address(manager)), hook, registry, address(tokenImpl));
        require(address(launcher) == predicted, "launcher missed its reserved address");

        syncRouter = new SyncFirstRouter(IPoolManager(address(manager)));

        pair.mint(creator, 10_000_000e18);
        vm.prank(creator);
        pair.approve(address(launcher), type(uint256).max);

        _fund(alice);
        _fund(bob);
    }

    function _fund(address who) internal {
        pair.mint(who, 100_000_000e18);
        vm.startPrank(who);
        pair.approve(address(swapRouter), type(uint256).max);
        pair.approve(address(syncRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------
    // Launch helpers
    // ------------------------------------------------------------------------------------------

    function _baseParams() internal returns (Launcher.LaunchParams memory p) {
        p = Launcher.LaunchParams({
            name: "Hoodstonk",
            symbol: "HOOD",
            supply: SUPPLY,
            pair: address(pair),
            openingMarketCap: OPENING_MCAP,
            graduationThreshold: OPENING_MCAP * 5,
            feeBps: 300,
            sellFeeBps: 0,
            burnBps: 0,
            vestDuration: 0,
            vestCliff: 0,
            creatorBps: 2000,
            maxWalletBps: 0,
            tickSpacing: TICK_SPACING,
            devBuyPairAmount: 0,
            salt: bytes32(0),
            minPushPayout: 1e6,
            minShareForQueue: 1e18,
            rewardCurrency: address(0),
            feeRecipient: address(0),
            referrer: address(0),
            openingWindow: 0, openingFeeBps: 0, metadata: LaunchMetadata({
                imageCid: keccak256("image"),
                bannerCid: keccak256("banner"),
                infoCid: keccak256("info")
            })
        });
        p.salt = _mineSalt();
    }

    /// @dev Mines a clone salt so the launch token sorts onto the side this suite is testing.
    function _mineSalt() internal returns (bytes32) {
        for (uint256 i = saltNonce; i < saltNonce + 20_000; ++i) {
            bytes32 s = bytes32(i);
            if ((launcher.predictTokenAddress(s) < address(pair)) == _tokenIsCurrency0()) {
                saltNonce = i + 1;
                return s;
            }
        }
        revert("no salt found for the requested currency ordering");
    }

    function _launch(Launcher.LaunchParams memory p)
        internal
        returns (address token, PoolKey memory k, PoolId id)
    {
        vm.prank(creator);
        (token,) = launcher.launch(p);
        k = _key(token, p.tickSpacing);
        id = k.toId();
        // Both traders must be able to sell it back.
        vm.prank(alice);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        vm.prank(bob);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
    }

    /// @dev The default launch: 3% buy fee, sells free, no burn.
    function _defaultLaunch() internal returns (address token, PoolKey memory k, PoolId id) {
        return _launch(_baseParams());
    }

    function _key(address token, int24 spacing) internal view returns (PoolKey memory) {
        bool t0 = token < address(pair);
        return PoolKey({
            currency0: Currency.wrap(t0 ? token : address(pair)),
            currency1: Currency.wrap(t0 ? address(pair) : token),
            fee: 0,
            tickSpacing: spacing,
            hooks: IHooks(address(hook))
        });
    }

    // ------------------------------------------------------------------------------------------
    // Swap helpers. These do NOT call `hook.sweep` afterwards, unlike `FeeHook.t.sol`'s `_swap`,
    // because most of this file is about what a swap does and does not do on its own.
    // ------------------------------------------------------------------------------------------

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

    function _buyExactIn(PoolKey memory k, address who, uint256 amountIn)
        internal
        returns (BalanceDelta)
    {
        return _swapRaw(k, who, _buyIsZeroForOne(), -int256(amountIn));
    }

    function _buyExactOut(PoolKey memory k, address who, uint256 amountOut)
        internal
        returns (BalanceDelta)
    {
        return _swapRaw(k, who, _buyIsZeroForOne(), int256(amountOut));
    }

    function _sellExactIn(PoolKey memory k, address who, uint256 amountIn)
        internal
        returns (BalanceDelta)
    {
        return _swapRaw(k, who, !_buyIsZeroForOne(), -int256(amountIn));
    }

    function _sellExactOut(PoolKey memory k, address who, uint256 amountOut)
        internal
        returns (BalanceDelta)
    {
        return _swapRaw(k, who, !_buyIsZeroForOne(), int256(amountOut));
    }

    /// @dev Warp past the end of the current dividend stream.
    ///
    ///      `Distributor.distribute` no longer credits the accumulator in the instant a sweep
    ///      lands - it arms a linear vest over `STREAM_WINDOW`. Money and entitlement are on
    ///      different clocks: `pair.balanceOf(address(dist))` moves on the sweep,
    ///      `withdrawableOf` does not move until the clock does.
    ///
    ///      `skip` reads the clock back through the cheatcode. `via_ir` caches `block.timestamp`,
    ///      so a chained `vm.warp(block.timestamp + X)` silently no-ops.
    function _vest(Distributor dist) internal {
        skip(uint256(dist.STREAM_WINDOW()) + 1);
    }

    /// @dev The hook's ERC-6909 claim balance for a currency, straight off the singleton.
    function _claims(Currency c) internal view returns (uint256) {
        return manager.balanceOf(address(hook), c.toId());
    }

    function _tick(PoolId id) internal view returns (int24 t) {
        (, t,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), id);
    }
}

// ===============================================================================================
// Findings + sound checks, run in BOTH currency orderings
// ===============================================================================================

abstract contract HookAuditCases is HookAuditWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // -------------------------------------------------------------------------------------------
    // V-01  REGRESSION GUARD. The automatic sweep used to be unreachable from every exact-input
    //       swap - i.e. from all real router traffic. It has been DELETED, so it is now
    //       unreachable from every swap shape, uniformly and by construction.
    // -------------------------------------------------------------------------------------------

    /// @notice INVERTED from `test_V01_autoSweepIsUnreachableFromExactInputSwaps`.
    ///
    /// @dev THE FINDING. `_afterSwap` returned at its `exactInput` guard BEFORE `_tryAutoSweep`,
    ///      and `rate == 0` killed exact-output sells on a default launch, so the ONLY shape that
    ///      could reach the automatic payout was an exact-output BUY. Exact input is what every
    ///      router, aggregator and swap UI sends by default, so on ordinary traffic the feature
    ///      `Launcher` armed on every single launch never ran, no matter how large the backlog got.
    ///
    ///      MEASURED BEFORE, this exact scenario, both currency orderings:
    ///
    ///        20 exact-input buys of 5 pair -> backlog 3.0000 pair (6x the 0.5 pair bar)
    ///        distributor / creator / platform paid                : 0
    ///        one exact-OUTPUT buy on the same pool                : paid all three immediately
    ///        pair moved to the distributor by that single trade   : 1.606302278315809874
    ///
    ///      WHY IT WAS DELETED RATHER THAN MADE REACHABLE. Moving the call above the `exactInput`
    ///      guard is a one-line change and it would have made V-02 LIVE for everybody: the auto
    ///      path's body called `poolManager.take()`, moving real ERC-20 out of the singleton in
    ///      the middle of somebody else's swap, which silently overcharges any caller that syncs
    ///      before swapping by the whole swept amount (measured at 8.5x, see `test_V02_fixed_...`).
    ///      So the honest options were "a feature that does nothing" or "a feature that robs
    ///      strangers", and the third was to delete it.
    ///
    ///      MEASURED AFTER: the identical sequence, including the exact-output buy that used to be
    ///      the one shape that worked, moves NOTHING to holders. `sweep` does.
    function test_V01_fixed_noSwapShapePaysHoldersMidTrade() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        Distributor dist = LaunchToken(t).distributor();

        uint256 distBefore = pair.balanceOf(address(dist));
        uint256 creatorBefore = pair.balanceOf(creator);
        uint256 platformBefore = pair.balanceOf(PLATFORM);

        // Twenty ordinary exact-input buys - the shape that never reached the auto path.
        for (uint256 i = 0; i < 20; ++i) {
            _buyExactIn(k, alice, 5e18);
        }

        uint256 backlog = hook.pendingFees(id);
        assertGt(backlog, 2e18, "precondition: a large real backlog exists to be paid out");
        assertEq(pair.balanceOf(address(dist)), distBefore, "exact input pays holders nothing");

        // THE INVERTED ASSERTION. This is the exact-OUTPUT buy that used to be the one shape that
        // reached the automatic payout. It no longer pays anybody either.
        _buyExactOut(k, bob, 1_000_000e18);

        assertEq(
            pair.balanceOf(address(dist)),
            distBefore,
            "exact OUTPUT no longer pays holders mid-swap either - the auto path is gone"
        );
        assertEq(pair.balanceOf(creator), creatorBefore, "nor the creator");
        assertEq(pair.balanceOf(PLATFORM), platformBefore, "nor the platform");
        assertGt(hook.pendingFees(id), backlog, "and the trade still accrued its own fee");

        // NON-VACUITY. Without this the assertions above would all pass on a build that had
        // simply stopped charging fees.
        hook.sweep(k);
        assertGt(pair.balanceOf(address(dist)), distBefore, "sweep is what pays holders");
        assertGt(pair.balanceOf(creator), creatorBefore, "and the creator");
        assertEq(hook.pendingFees(id), 0, "and it clears the whole backlog");
    }

    /// @notice **THE RESIDUAL RISK OF THE V-01 FIX, KEPT DELIBERATELY AND NOT INVERTED.**
    ///
    /// @dev This test asserted a consequence of the V-01 finding and it is still true after the
    ///      fix, because deleting the auto path did not make payment automatic - it made it
    ///      uniformly manual. Every wei of fee stays an ERC-6909 claim and a holder's
    ///      `withdrawableOf` stays ZERO until a human or a bot calls `sweep`. The claims are real
    ///      and exact; they are just not paid. Keeping this green is the honest statement that the
    ///      remediation traded a broken mechanism for an unbroken one that still needs a caller.
    ///
    ///      **What makes that caller exist is `SWEEP_BOUNTY_BPS`, and it is only worth their gas
    ///      above a measurable pot size.** Measured at 20 gwei in
    ///      `test/audit/11-sweep/SweepEconomics.t.sol`: the break-even pot is ~0.3407 pair in
    ///      steady state and ~0.8158 pair for a keeper being paid in that currency for the first
    ///      time. Below it, nobody is paid to pay anyone, and the pot simply waits.
    ///
    ///      **Streaming adds a second, independent delay on top.** After the sweep finally
    ///      happens, entitlement still takes a full `STREAM_WINDOW` to appear. The intermediate
    ///      assertions below distinguish the two - un-swept and un-vested are both "owed nothing",
    ///      for entirely different reasons.
    function test_V01b_routerOnlyTrafficLeavesHoldersUnpaidIndefinitely() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        Distributor dist = LaunchToken(t).distributor();

        _buyExactIn(k, alice, 2e18); // alice becomes a holder
        for (uint256 i = 0; i < 30; ++i) {
            _buyExactIn(k, bob, 2e18);
        }

        assertGt(hook.pendingFees(id), 0, "fees were charged");
        assertEq(dist.withdrawableOf(alice), 0, "but a holder is owed nothing until someone sweeps");

        // Not swept: waiting a full window changes nothing at all, because there is no stream to
        // vest. This is the assertion that separates "nobody swept" from "the stream is young".
        _vest(dist);
        assertEq(dist.withdrawableOf(alice), 0, "time alone never pays an un-swept pool");
        assertEq(pair.balanceOf(address(dist)), 0, "and no money has moved either");

        hook.sweep(k);
        assertGt(pair.balanceOf(address(dist)), 0, "the sweep moves the MONEY immediately");
        assertEq(dist.withdrawableOf(alice), 0, "but not the ENTITLEMENT - that streams");

        _vest(dist);
        assertGt(dist.withdrawableOf(alice), 0, "the manual path does pay");
    }

    // -------------------------------------------------------------------------------------------
    // V-02  REGRESSION GUARD. `take()` inside `afterSwap` used to corrupt settlement for any
    //       integrator that pays before it swaps. There is no longer any `take()` inside any swap.
    // -------------------------------------------------------------------------------------------

    /// @notice INVERTED from `test_V02_takeInsideAfterSwapCorruptsASyncFirstPayersSettlement`.
    ///
    /// @dev THE BUG. `_tryAutoSweep` -> `autoRedeem` called `poolManager.take(cfg.pairCurrency,
    ///      ...)`, i.e. real ERC-20 left the singleton in the MIDDLE of somebody else's swap.
    ///      `PoolManager._settle` credits a payer with `balanceOfSelf() - syncedReserves`, so a
    ///      caller who `sync`ed the input currency BEFORE the swap was credited exactly that much
    ///      less than it handed over. `sync -> transfer -> swap -> settle` is perfectly legal v4
    ///      and is what an intent solver, a batch executor or any pay-up-front router writes;
    ///      Uniswap's own routers sync AFTER the swap and were unaffected, which is why this was
    ///      latent rather than visible.
    ///
    ///      MEASURED BEFORE, against a control run of the IDENTICAL trade through `PoolSwapTest`
    ///      from the same state snapshot (token = currency0; currency1 matched):
    ///
    ///        cost via the Uniswap-supplied router : 0.400539139623279432 pair
    ///        cost via the sync-first router       : 3.412205328155996308 pair
    ///        overcharge                           : 3.011666188532716876 pair  (8.5x)
    ///        settle() shortfall                   : 3.011666188532716876 pair  (identical)
    ///
    ///      THE FIX. The auto path was deleted outright rather than repaired. `_accrue` only
    ///      `mint`s an ERC-6909 claim, which moves no ERC-20 at all, so after the deletion **there
    ///      is no code path anywhere in this system that moves a real token out of the singleton
    ///      during a swap.** That makes the whole class structurally unreachable instead of merely
    ///      unlikely, which is worth more than a patch that keeps the `take` and guards it.
    ///
    ///      MEASURED AFTER: `settle()` credits every wei handed over, and the sync-first payer is
    ///      charged exactly what the standard router pays, to the wei, with the same large backlog
    ///      sitting unswept.
    function test_V02_fixed_aSyncFirstPayerIsCreditedEveryWeiTheyHandOver() public {
        (, PoolKey memory k, PoolId id) = _defaultLaunch();

        // The same large backlog that used to be stolen out of the payer's synced reserve.
        for (uint256 i = 0; i < 20; ++i) {
            _buyExactIn(k, alice, 5e18);
        }
        uint256 backlog = hook.pendingFees(id);
        assertGt(backlog, 2e18, "precondition: a large unswept backlog exists to be mis-taken");

        uint256 amountOut = 1_000_000e18;
        uint256 snap = vm.snapshotState();

        // CONTROL: the same exact-output buy through the Uniswap-supplied router.
        uint256 before = pair.balanceOf(bob);
        _buyExactOut(k, bob, amountOut);
        uint256 costStandard = before - pair.balanceOf(bob);
        assertGt(costStandard, 0, "precondition: the control trade really cost something");

        require(vm.revertToState(snap), "snapshot revert failed");

        // PROBE: identical trade, paid for before the swap instead of after.
        uint256 prepay = costStandard * 2;
        before = pair.balanceOf(bob);
        vm.prank(bob);
        uint256 credited = syncRouter.swap(
            k,
            SwapParams({
                zeroForOne: _buyIsZeroForOne(),
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: _buyIsZeroForOne()
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            prepay
        );
        uint256 costProbe = before - pair.balanceOf(bob);

        emit log_named_uint("settle() was handed        ", prepay);
        emit log_named_uint("settle() credited          ", credited);
        emit log_named_uint("cost via the normal router ", costStandard);
        emit log_named_uint("cost via the sync-first one", costProbe);

        assertEq(credited, prepay, "settle() now credits every wei that was transferred in");
        assertEq(costProbe, costStandard, "and the sync-first payer pays the standard cost");
        assertEq(
            hook.pendingFees(id) > backlog,
            true,
            "non-vacuity: the trade was really charged a fee, it just stayed a claim"
        );
    }

    /// @notice INVERTED from `test_V02c_aLargeBacklogMakesTheSyncFirstPayersSwapRevertOutright`.
    ///
    /// @dev THE BUG, harder branch. When the auto-swept amount exceeded what the payer handed over
    ///      between `sync` and `settle`, `PoolManager._settle`'s `reservesNow - reservesBefore`
    ///      UNDERFLOWED and the whole transaction reverted with a bare panic `0x11` carrying
    ///      nothing an integrator could act on. Which branch a trade landed in depended on the
    ///      pool's unswept backlog at that block, so it was nondeterministic from the caller's
    ///      side: the same code would work in one block and revert in the next.
    ///
    ///      MEASURED BEFORE: with a backlog exceeding a 2x prepay, `vm.expectRevert(stdError.
    ///      arithmeticError)` was satisfied - the trade was simply unexecutable.
    ///
    ///      MEASURED AFTER: the identical call succeeds, with the backlog still unswept, and the
    ///      buyer receives the launch tokens they asked for.
    function test_V02c_fixed_aLargeBacklogNoLongerRevertsTheSyncFirstPayer() public {
        (, PoolKey memory k, PoolId id) = _defaultLaunch();

        for (uint256 i = 0; i < 20; ++i) {
            _buyExactIn(k, alice, 5e18);
        }
        assertGt(hook.pendingFees(id), 1e18, "backlog dwarfs the trade below");

        uint256 amountOut = 1_000_000e18;
        uint256 snap = vm.snapshotState();
        uint256 before = pair.balanceOf(bob);
        _buyExactOut(k, bob, amountOut);
        uint256 costStandard = before - pair.balanceOf(bob);
        require(vm.revertToState(snap), "snapshot revert failed");

        // THE PRECONDITION THAT USED TO MAKE IT REVERT, asserted so this cannot pass vacuously on
        // a build where the backlog had quietly stopped accumulating.
        assertLt(costStandard * 2, hook.pendingFees(id), "precondition: backlog > the prepay");

        uint256 tokensBefore = IERC20(_tokenOf(k)).balanceOf(bob);
        vm.prank(bob);
        uint256 credited = syncRouter.swap(
            k,
            SwapParams({
                zeroForOne: _buyIsZeroForOne(),
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: _buyIsZeroForOne()
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            costStandard * 2
        );

        assertEq(credited, costStandard * 2, "settle() credited the full prepay, no underflow");
        assertEq(
            IERC20(_tokenOf(k)).balanceOf(bob) - tokensBefore,
            amountOut,
            "and the trade delivered exactly what was asked for"
        );
    }

    /// @dev The same probe on a pool with no backlog at all. Kept as the control that proves the
    ///      probe itself is faithful: it settled to the wei even on the pre-fix build, so a green
    ///      reading here has never depended on the fix. `test_V02_fixed_...` is the one that
    ///      carries the backlog.
    function test_V02b_theSameProbeIsExactWhenThereIsNoBacklogAtAll() public {
        (, PoolKey memory k,) = _defaultLaunch();

        uint256 amountOut = 1_000_000e18;
        uint256 snap = vm.snapshotState();

        uint256 before = pair.balanceOf(bob);
        _buyExactOut(k, bob, amountOut);
        uint256 costStandard = before - pair.balanceOf(bob);

        require(vm.revertToState(snap), "snapshot revert failed");

        uint256 prepay = costStandard * 2;
        before = pair.balanceOf(bob);
        vm.prank(bob);
        uint256 credited = syncRouter.swap(
            k,
            SwapParams({
                zeroForOne: _buyIsZeroForOne(),
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: _buyIsZeroForOne()
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            prepay
        );

        assertEq(credited, prepay, "with no auto sweep, settle() credits every wei handed over");
        assertEq(before - pair.balanceOf(bob), costStandard, "and the payer is charged the same");
    }

    // -------------------------------------------------------------------------------------------
    // V-03  A price-limited exact-input buy pays the full fee on input it never spent.
    // -------------------------------------------------------------------------------------------

    /// @notice REGRESSION GUARD. The trade that used to settle at a 9,087 bps effective fee is
    ///         now refused by name.
    ///
    /// @dev THE BUG. `_beforeSwap` charges `feeBps` of `-params.amountSpecified` - the amount
    ///      REQUESTED, before the curve has run, because on an exact-input buy the pair currency
    ///      is the SPECIFIED side and `beforeSwap` is the only place a hook can touch it. If
    ///      `sqrtPriceLimitX96` stopped the swap early, the unspent input came back and the fee on
    ///      it did not. The docstring called that "bounded by `feeBps`" - true of the notional,
    ///      false of the RATE, and the rate is what a trader experiences. And it was forceable:
    ///      a sandwicher pushes the price to one tick short of the victim's own limit and the
    ///      victim fills for almost nothing while paying the full notional's fee.
    ///
    ///      MEASURED BEFORE, on this exact scenario, both currency orderings:
    ///
    ///        requested input   : 100.000000000000000000 pair
    ///        actually debited  :   3.301308354505875602 pair
    ///        fee charged       :   3.000000000000000000 pair
    ///        effective rate    : 9,087 bps   (30x the advertised 300)
    ///
    ///      MEASURED AFTER: the same call reverts `PriceLimitedBuyWouldOvercharge(100e18,
    ///      consumed, 3e18)` and nothing settles. `spent == 0`, `pendingFees` does not move.
    ///
    ///      THE FIX, and why it is a refusal rather than a refund. A hook's `afterSwap` return can
    ///      only move the UNSPECIFIED currency, which on an exact-input buy is the launch token.
    ///      Handing back launch tokens is not a refund of a pair-currency fee, so there is no
    ///      refund available at all - the choice is "overcharge silently" or "refuse", and this
    ///      codebase has already settled that question (`ZapRouter.IntermediateLegDidNotNet`).
    ///      A trader who wanted a partial fill asks for a smaller amount; a trader who set the
    ///      limit as slippage protection gets exactly what slippage protection means.
    function test_V03_fixed_aPriceLimitedBuyIsRefusedRatherThanOvercharged() public {
        (, PoolKey memory k, PoolId id) = _defaultLaunch();

        // Leave the swap exactly one tick-spacing of room before its own limit binds.
        int24 t0 = _tick(id);
        int24 limitTick = _buyIsZeroForOne() ? t0 - TICK_SPACING : t0 + TICK_SPACING;
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);

        uint256 requested = 100e18;
        uint256 before = pair.balanceOf(alice);
        uint256 feesBefore = hook.pendingFees(id);

        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: _buyIsZeroForOne(),
                amountSpecified: -int256(requested),
                sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(pair.balanceOf(alice), before, "the trader was debited by a refused trade");
        assertEq(hook.pendingFees(id), feesBefore, "a refused trade still accrued a fee");

        // POSITIVE CONTROL, and it is what stops this being a test that would pass on a hook that
        // rejected every buy: the SAME size with the same limit, once the pool has room for it,
        // fills completely and is charged exactly the advertised 300 bps of what was requested.
        uint160 wideLimit =
            _buyIsZeroForOne() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(alice);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: _buyIsZeroForOne(),
                amountSpecified: -int256(requested),
                sqrtPriceLimitX96: wideLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 spent = before - pair.balanceOf(alice);
        uint256 fee = hook.pendingFees(id) - feesBefore;
        emit log_named_uint("control: debited  ", spent);
        emit log_named_uint("control: fee      ", fee);
        assertEq(spent, requested, "an unconstrained buy spends the whole request");
        assertEq(fee, (requested * 300) / 10_000, "and pays exactly the advertised rate");
        assertEq((fee * 10_000) / spent, 300, "effective rate == advertised rate");
    }

    /// @dev The other half of the property: a SELL cut short by the opening-tick floor must still
    ///      partially fill. The refusal above is scoped to the leg charged in the pair currency,
    ///      because `sweep`'s sell-fee conversion and the F-05 self-healing deferral both depend on
    ///      a sell being allowed to fill only as far as the pool's pair side reaches.
    function test_V03b_sound_aPriceLimitedSellStillPartiallyFills() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.sellFeeBps = 1000;
        (address t, PoolKey memory k, PoolId id) = _launch(p);

        // Build a position and put real pair currency in the pool for it to sell into.
        _buyExactIn(k, alice, 50e18);
        _buyExactIn(k, bob, 50e18);
        uint256 held = IERC20(t).balanceOf(alice);
        assertGt(held, 0, "precondition: alice holds something to sell");

        // The mirror of the buy above: one tick-spacing of room before the sell's own limit binds.
        int24 t0 = _tick(id);
        int24 limitTick = _buyIsZeroForOne() ? t0 + TICK_SPACING : t0 - TICK_SPACING;

        uint256 pairBefore = pair.balanceOf(alice);
        uint256 tokenBefore = IERC20(t).balanceOf(alice);

        vm.prank(alice);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: !_buyIsZeroForOne(),
                amountSpecified: -int256(held),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(limitTick)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 sold = tokenBefore - IERC20(t).balanceOf(alice);
        assertGt(pair.balanceOf(alice) - pairBefore, 0, "the sell did not fill at all");
        assertLt(sold, held, "the sell was NOT cut short, so this proves nothing");
    }

    // -------------------------------------------------------------------------------------------
    // V-04  Seeding dust goes to the CREATOR on any launch with a dev buy.
    // -------------------------------------------------------------------------------------------

    /// @dev `_refundResidual` burns unseeded launch-token dust to the dead address because giving
    ///      it to the creator "would be an unadvertised allocation" (Launcher.sol:692). But
    ///      `_devBuy` runs FIRST and reads an ABSOLUTE balance - `IERC20(d.token).balanceOf(
    ///      address(this))` at Launcher.sol:656 - which at that instant is the tokens the dev buy
    ///      bought PLUS the seeding dust. So on any launch with a dev buy the dust is handed to the
    ///      creator (or their vault) and the burn branch never sees it.
    ///
    ///      Small, but it is the one place in the launch path that reads a balance instead of a
    ///      delta, and it contradicts an explicitly stated rule in the same function.
    function test_V04_seedDustReachesTheCreatorWheneverThereIsADevBuy() public {
        // Launch A: no dev buy. The dust is burned, exactly as documented.
        (address a,,) = _defaultLaunch();
        uint256 dustBurned = IERC20(a).balanceOf(DEAD);
        emit log_named_uint("seeding dust burned on a dev-buy-free launch", dustBurned);
        assertGt(dustBurned, 0, "there IS seeding dust to argue about");

        // Launch B: identical, with a dev buy.
        Launcher.LaunchParams memory p = _baseParams();
        p.devBuyPairAmount = 1e18;
        uint256 deadBefore = IERC20(a).balanceOf(DEAD); // per-token balance; b is a new token
        deadBefore; // silence
        (address b,,) = _launch(p);

        assertEq(IERC20(b).balanceOf(DEAD), 0, "NOTHING was burned on the dev-buy launch");
        // The creator holds the bought tokens plus the dust that should have been destroyed.
        assertGt(IERC20(b).balanceOf(creator), 0, "creator was paid the dev buy");
    }

    // ===========================================================================================
    // Checked and found sound
    // ===========================================================================================

    /// @dev All four swap shapes, on a REAL single-sided pool, with a sell tax and a burn wedge
    ///      both armed so every delta path in `_beforeSwap`, `_afterSwap` and `unlockCallback` runs.
    ///      If any returned delta did not match what the hook actually took, one of these reverts
    ///      `CurrencyNotSettled`.
    function test_sound_allFourSwapShapesSettleOnASingleSidedPool() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.sellFeeBps = 500;
        p.burnBps = 2000;
        (, PoolKey memory k, PoolId id) = _launch(p);

        _buyExactIn(k, alice, 20e18);
        _buyExactOut(k, bob, 1_000_000e18);
        _sellExactIn(k, alice, 100_000e18);
        _sellExactOut(k, bob, 1e15);

        assertGt(hook.pendingFees(id), 0, "buys were charged in the pair currency");
        assertGt(hook.pendingTokenFees(id), 0, "sells were charged in the launch token");

        hook.sweep(k);
        assertEq(hook.pendingFees(id), 0, "every pair claim redeemed");
        assertEq(hook.pendingTokenFees(id), 0, "every token claim converted");
    }

    /// @dev SIGN CHECK, `beforeSwap`. `toBeforeSwapDelta(specified, unspecified)` puts the fee in
    ///      the SPECIFIED slot, positive. Per the installed `Hooks.beforeSwap`
    ///      (v4-core/libraries/Hooks.sol:275) that means `amountToSwap += fee`, i.e. a `-1000`
    ///      exact input becomes `-970`. The trader is debited the full 1000 and 30 never reaches
    ///      the curve: the fee comes OUT of the input.
    function test_sound_beforeSwapDeltaSignTakesTheFeeOutOfTheInput() public {
        (, PoolKey memory k, PoolId id) = _defaultLaunch();

        uint256 amountIn = 10e18;
        uint256 before = pair.balanceOf(alice);
        _buyExactIn(k, alice, amountIn);

        assertEq(before - pair.balanceOf(alice), amountIn, "trader is debited exactly what it named");
        assertEq(hook.pendingFees(id), (amountIn * 300) / 10_000, "fee is feeBps of the input");
    }

    /// @dev SIGN CHECK, `afterSwap`. The returned `int128` lands in the UNSPECIFIED slot; on an
    ///      exact-output buy that is the INPUT currency, so a positive value is added ON TOP of what
    ///      the curve consumed. `feeBps` is therefore charged on the pool's consumption, not on the
    ///      trader's total outlay.
    function test_sound_afterSwapDeltaSignAddsTheFeeOnTopOfTheInput() public {
        (, PoolKey memory k, PoolId id) = _defaultLaunch();

        uint256 before = pair.balanceOf(alice);
        _buyExactOut(k, alice, 1_000_000e18);
        uint256 paid = before - pair.balanceOf(alice);

        uint256 fee = hook.pendingFees(id);
        uint256 consumed = paid - fee;

        assertGt(fee, 0, "an exact-output buy is charged");
        assertApproxEqAbs(fee, (consumed * 300) / 10_000, 2, "fee is feeBps of what the curve ate");
        assertEq(paid, consumed + fee, "and it is charged on top, not out of");
    }

    /// @dev No shape is charged twice. The two legs are mutually exclusive on exactness, so the
    ///      hook's claim balance grows by exactly one fee per trade.
    function test_sound_noSwapShapeIsChargedByBothLegs() public {
        (, PoolKey memory k, PoolId id) = _defaultLaunch();

        _buyExactIn(k, alice, 10e18);
        assertEq(hook.totalFeesTaken(id), (uint256(10e18) * 300) / 10_000, "charged once");

        uint256 f = hook.totalFeesTaken(id);
        uint256 before = pair.balanceOf(bob);
        _buyExactOut(k, bob, 1_000_000e18);
        uint256 paid = before - pair.balanceOf(bob);
        uint256 charged = hook.totalFeesTaken(id) - f;

        assertLe(charged * 10_000, paid * 300 + 10_000, "never more than the configured rate");
    }

    /// @dev `Hooks.noSelfCall`, verified against the INSTALLED v4 rather than from memory.
    ///      `Hooks.beforeSwap` returns early at v4-core/libraries/Hooks.sol:253 and
    ///      `Hooks.afterSwap` at :293 when `msg.sender == address(self)`. `unlockCallback` swaps
    ///      the pool's own pool, so both internal swaps - the sell-fee conversion and the buyback -
    ///      must be untaxed and must not recurse.
    function test_sound_noSelfCallMeansTheInternalSweepSwapsAreUntaxed() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.sellFeeBps = 500;
        p.burnBps = 2000;
        (, PoolKey memory k, PoolId id) = _launch(p);

        // Give the pool a real pair-currency reserve so the conversion can complete.
        _buyExactIn(k, alice, 50e18);
        _sellExactIn(k, alice, 100_000e18);

        assertGt(hook.pendingTokenFees(id), 0, "a sell fee is queued in launch tokens");

        uint256 takenBefore = hook.totalFeesTaken(id);
        hook.sweep(k);

        // If the hook's callbacks had fired on its own swaps, the conversion (a sell) would have
        // re-queued `pendingTokenFees` and the buyback (a buy) would have grown `totalFeesTaken`.
        assertEq(hook.totalFeesTaken(id), takenBefore, "the internal buyback was NOT charged a fee");
        assertEq(hook.pendingTokenFees(id), 0, "the internal conversion was NOT charged a sell fee");
        assertEq(hook.pendingFees(id), 0, "and nothing was re-queued");
        assertGt(hook.totalBurned(id), 0, "the buyback really did run");
    }

    /// @dev The re-entrancy boundary, stated as a test. v4's `Lock` is one global transient flag, so
    ///      `sweep` - which calls `unlock` - is unreachable from inside any open unlock cycle. It
    ///      reverts, it does not silently re-enter.
    function test_sound_sweepCannotBeReenteredFromInsideAnUnlockCycle() public {
        (, PoolKey memory k,) = _defaultLaunch();
        _buyExactIn(k, alice, 10e18);

        UnlockReentrantSweeper attacker =
            new UnlockReentrantSweeper(IPoolManager(address(manager)), hook);

        vm.expectRevert();
        attacker.attack(k);
    }

    /// DELETED, all three tests of the automatic sweep, because the feature is gone:
    ///
    ///   - `test_sound_autoRedeemUsesBurnAndTakeRatherThanANestedUnlock` - asserted that the auto
    ///     path avoided a nested `unlock` by using `burn` + `take`. That `take` IS V-02. There is
    ///     no auto path and therefore no nested-unlock question to answer.
    ///   - `test_sound_autoRedeemRejectsEveryOutsideCaller` - `autoRedeem` no longer exists, so
    ///     neither does the external surface its access-control guard protected.
    ///   - `test_sound_aFailedAutoSweepNeverBreaksTheTrade` - asserted that a failing auto sweep
    ///     never reverts somebody else's trade. Nothing that can fail runs inside a swap any more.
    ///
    /// None of these was weakened to go green: each drove a function that has been removed from
    /// `src/`. The PROPERTY they were collectively buying - "the payout machinery can never touch
    /// a trader's swap" - is now stated directly and much more strongly by the test below, which
    /// measures the singleton's own ERC-20 balance instead of inferring safety from a try/catch.

    /// @notice REPLACES the three deleted auto-sweep tests with the property they were proxies for.
    ///
    /// @dev V-02 exists because `PoolManager._settle` credits `balanceOfSelf() - syncedReserves`,
    ///      so the question that actually matters is not "does the payout path have a try/catch"
    ///      but **"does any ERC-20 leave the singleton during a swap"**. That is directly
    ///      measurable and it is measured here rather than argued: across the exact-output buy
    ///      that used to trigger the auto path, with a large unswept backlog sitting there, the
    ///      singleton's pair balance must rise by EXACTLY what the trader paid in.
    ///
    ///      MEASURED BEFORE: the singleton's balance rose by less than the trader paid, by exactly
    ///      the auto-swept payout - 1.606302278315809874 pair on this scenario - which is the
    ///      quantity `settle()` silently deducted from a sync-first caller.
    ///
    ///      MEASURED AFTER: zero. Every wei paid in stays in until somebody calls `sweep`.
    ///
    ///      Also asserts the first-ever-trade case the deleted `test_sound_aFailedAutoSweep...`
    ///      covered: a pool that opens holding no pair currency still trades.
    function test_V02d_fixed_noErc20LeavesTheSingletonDuringASwap() public {
        (, PoolKey memory k, PoolId id) = _defaultLaunch();

        // The first trade a pool ever sees, against a singleton holding zero pair currency. This
        // is the case the deleted "a failing auto sweep never breaks the trade" test covered.
        assertEq(pair.balanceOf(address(manager)), 0, "the pool opens holding zero pair currency");
        _buyExactOut(k, alice, 1_000_000e18);
        assertGt(IERC20(_tokenOf(k)).balanceOf(alice), 0, "the first trade completed");

        // Now build the large backlog that used to be taken out mid-swap.
        for (uint256 i = 0; i < 20; ++i) {
            _buyExactIn(k, alice, 5e18);
        }
        assertGt(hook.pendingFees(id), 2e18, "precondition: a large unswept backlog exists");

        uint256 managerBefore = pair.balanceOf(address(manager));
        uint256 bobBefore = pair.balanceOf(bob);

        // The exact-output buy: the one shape that reached the auto path.
        _buyExactOut(k, bob, 1_000_000e18);

        uint256 paidIn = bobBefore - pair.balanceOf(bob);
        uint256 managerAfter = pair.balanceOf(address(manager));
        assertGt(paidIn, 0, "non-vacuity: the trade really moved pair currency");

        assertEq(
            managerAfter,
            managerBefore + paidIn,
            "every wei the trader paid in stayed in the singleton - nothing left mid-swap"
        );
    }

    /// @dev The `beforeInitialize` gate, attacked from every angle a stranger has: a different tick
    ///      spacing, a different fee, and a dynamic fee - each of which is a DIFFERENT `PoolId` and
    ///      therefore a different, unconfigured `poolConfig` entry.
    function test_sound_strangerCannotOpenASecondPoolAgainstThisHook() public {
        (address t,,) = _defaultLaunch();

        PoolKey memory rogue = _key(t, 120);
        vm.prank(alice);
        vm.expectRevert();
        manager.initialize(rogue, TickMath.getSqrtPriceAtTick(0));

        rogue = _key(t, TICK_SPACING);
        rogue.fee = 3000;
        vm.prank(alice);
        vm.expectRevert();
        manager.initialize(rogue, TickMath.getSqrtPriceAtTick(0));

        rogue = _key(t, TICK_SPACING);
        rogue.fee = 0x800000; // the dynamic-fee sentinel
        vm.prank(alice);
        vm.expectRevert();
        manager.initialize(rogue, TickMath.getSqrtPriceAtTick(0));
    }

    /// @dev And the configured pool cannot be re-opened at a price of the attacker's choosing.
    function test_sound_theLaunchedPoolCannotBeReinitialised() public {
        (, PoolKey memory k,) = _defaultLaunch();
        vm.prank(alice);
        vm.expectRevert();
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
    }

    /// @dev ERC-6909 accounting. The PoolManager is a singleton, so the hook's claim balance in a
    ///      currency is shared across every pool that uses it. What must hold is that the hook's
    ///      claims are exactly the sum of what its per-pool ledgers say it holds - never more (it
    ///      would be unredeemable) and never less (a sweep would spend another pool's claims).
    function test_sound_claimBalanceMatchesThePerPoolLedgersAcrossTwoLaunches() public {
        (address a, PoolKey memory kA, PoolId idA) = _defaultLaunch();

        Launcher.LaunchParams memory p = _baseParams();
        p.sellFeeBps = 500;
        (address b, PoolKey memory kB, PoolId idB) = _launch(p);

        _buyExactIn(kA, alice, 10e18);
        _buyExactIn(kB, bob, 7e18);
        _sellExactIn(kB, bob, 100_000e18);

        Currency pairC = Currency.wrap(address(pair));
        assertEq(
            _claims(pairC),
            hook.pendingFees(idA) + hook.pendingFees(idB),
            "pair claims equal the two pools' pair ledgers, exactly"
        );
        assertEq(
            _claims(Currency.wrap(b)),
            hook.pendingTokenFees(idB),
            "token claims equal that pool's token ledger, exactly"
        );
        assertEq(_claims(Currency.wrap(a)), 0, "and a pool with free sells holds no token claims");

        // Sweeping one pool must leave the other's claims untouched.
        uint256 bPending = hook.pendingFees(idB);
        hook.sweep(kA);
        assertEq(hook.pendingFees(idA), 0, "A swept");
        assertEq(hook.pendingFees(idB), bPending, "B untouched");
        assertEq(_claims(pairC), bPending, "and the shared claim balance is exactly B's");
    }

    /// @dev The single-sided seed requires ZERO pair currency, which is the property the whole
    ///      "launching costs nothing but gas" claim rests on. Asserted against the real
    ///      `_openingTick` / `_seedLiquidity`, in both currency orderings.
    function test_sound_singleSidedSeedRequiresNoPairCurrency() public {
        uint256 managerPairBefore = pair.balanceOf(address(manager));
        uint256 creatorPairBefore = pair.balanceOf(creator);

        (address t,, PoolId id) = _defaultLaunch();

        assertEq(pair.balanceOf(address(manager)), managerPairBefore, "pool took no pair currency");
        assertEq(pair.balanceOf(creator), creatorPairBefore, "creator supplied no pair currency");
        assertGt(IERC20(t).balanceOf(address(manager)), 0, "but the whole supply went in");
        assertEq(pair.balanceOf(address(launcher)), 0, "launcher retains nothing");

        int24 tick = _tick(id);
        assertEq(tick % TICK_SPACING, 0, "the opening tick is aligned to the spacing");
    }

    /// @dev The pool opens at a FLOOR: there is no liquidity below the opening tick, so the first
    ///      seller cannot be filled at all before anyone has bought.
    function test_sound_thereIsNoLiquidityBelowTheOpeningTick() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        int24 opening = _tick(id);

        // Get some tokens into a wallet, then sell them back with nothing on the other side.
        _buyExactIn(k, alice, 1e18);
        int24 afterBuy = _tick(id);
        assertTrue(
            _tokenIsCurrency0() ? afterBuy > opening : afterBuy < opening,
            "a buy moves the price away from the floor"
        );

        uint256 held = IERC20(t).balanceOf(alice);
        _sellExactIn(k, alice, held);

        // Selling everything back cannot push the price through the floor.
        int24 afterSell = _tick(id);
        if (_tokenIsCurrency0()) {
            assertGe(afterSell, opening, "price cannot go below the opening tick");
        } else {
            assertLe(afterSell, opening, "price cannot go past the opening tick");
        }
    }

    /// @dev The hook is a conduit. After a full cycle it must hold no ERC-20 and no unaccounted
    ///      claims.
    function test_sound_hookRetainsNothingAfterAFullCycle() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.sellFeeBps = 500;
        p.burnBps = 1000;
        (address t, PoolKey memory k, PoolId id) = _launch(p);

        _buyExactIn(k, alice, 30e18);
        _sellExactIn(k, alice, 100_000e18);
        _buyExactOut(k, bob, 500_000e18);
        hook.sweep(k);

        assertEq(pair.balanceOf(address(hook)), 0, "no pair currency retained");
        assertEq(IERC20(t).balanceOf(address(hook)), 0, "no launch token retained");
        assertEq(_claims(Currency.wrap(address(pair))), hook.pendingFees(id), "no stray pair claims");
        assertEq(_claims(Currency.wrap(t)), hook.pendingTokenFees(id), "no stray token claims");
    }

    function _tokenOf(PoolKey memory k) internal view returns (address) {
        return Currency.unwrap(k.currency0) == address(pair)
            ? Currency.unwrap(k.currency1)
            : Currency.unwrap(k.currency0);
    }
}

/// @notice The launch token sorted BELOW the pair, so the token is `currency0` and the seeded
///         position runs UPWARD from the opening tick.
contract HookAuditTokenIsCurrency0Test is HookAuditCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function test_orientation() public {
        (address t,,) = _defaultLaunch();
        assertTrue(t < address(pair), "token must be currency0 in this suite");
    }
}

/// @notice The launch token sorted ABOVE the pair, so the token is `currency1` and the seeded
///         position runs DOWNWARD. Every delta sign in the hook flips with this.
contract HookAuditTokenIsCurrency1Test is HookAuditCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }

    function test_orientation() public {
        (address t,,) = _defaultLaunch();
        assertTrue(address(pair) < t, "token must be currency1 in this suite");
    }
}

// ===============================================================================================
// `_openingTick` / `_seedLiquidity` - the single-sided invariant across the whole legal band
// ===============================================================================================

/// @dev The claim under test is narrow and total: for EVERY legal (supply, openingMarketCap,
///      tickSpacing, ordering), the seeded position must require exactly ZERO pair currency. If it
///      ever required any, the launcher would have to find it somewhere - and on a launch with a
///      dev buy it is holding the creator's money at that exact moment, so the failure would be
///      silent rather than a revert.
contract HookAuditSeedingTest is HookAuditWorld {
    using PoolIdLibrary for PoolKey;

    bool internal wantCurrency0 = true;

    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true; // overridden per-case by `wantCurrency0` below
    }

    function _mineFor(bool c0) internal returns (bytes32) {
        for (uint256 i = saltNonce; i < saltNonce + 20_000; ++i) {
            bytes32 s = bytes32(i);
            if ((launcher.predictTokenAddress(s) < address(pair)) == c0) {
                saltNonce = i + 1;
                return s;
            }
        }
        revert("no salt");
    }

    function _seedOnce(uint256 supply, uint256 mcap, int24 spacing, bool c0)
        internal
        returns (address token, int24 openingTick)
    {
        Launcher.LaunchParams memory p = _baseParams();
        p.salt = _mineFor(c0);
        p.supply = supply;
        p.openingMarketCap = mcap;
        p.graduationThreshold = mcap * 2;
        p.tickSpacing = spacing;

        uint256 managerPairBefore = pair.balanceOf(address(manager));

        vm.prank(creator);
        (token,) = launcher.launch(p);

        // THE INVARIANT.
        assertEq(
            pair.balanceOf(address(manager)),
            managerPairBefore,
            "the seed required PAIR CURRENCY - single-sided seeding is broken"
        );
        assertEq(pair.balanceOf(address(launcher)), 0, "launcher retains no pair currency");
        assertEq(IERC20(token).balanceOf(address(launcher)), 0, "launcher retains no launch token");

        PoolKey memory k = _key(token, spacing);
        openingTick = _tick(k.toId());
        assertEq(openingTick % spacing, 0, "the opening tick is not aligned to the spacing");
    }

    /// @dev A wide sweep of realistic shapes, both orderings, six tick spacings. Bounded to the
    ///      band where the launch is guaranteed to be ACCEPTED (price ratio within 1e6 either way,
    ///      liquidity under `maxLiquidityPerTick` even at a spacing of 1) so the assertion is
    ///      unconditional - a swallowed revert would make this test prove nothing.
    function testFuzz_singleSidedSeedNeverNeedsPairCurrency(
        uint256 supply,
        uint256 mcap,
        uint8 spacingSeed,
        bool c0
    ) public {
        supply = bound(supply, 1e18, 1e27);
        mcap = bound(mcap, supply / 1e6, supply * 1e6);
        int24[6] memory spacings =
            [int24(1), int24(10), int24(60), int24(100), int24(200), int24(2000)];
        int24 spacing = spacings[spacingSeed % 6];

        _seedOnce(supply, mcap, spacing, c0);
    }

    /// @dev The explicit grid, where a failure cannot be swallowed by a `catch`. These are the
    ///      corners: a negative opening tick that is not a multiple of the spacing (the branch at
    ///      Launcher.sol:554), a positive one, and a tick spacing of 1 where rounding has nowhere
    ///      to go.
    function test_singleSidedSeedHoldsAtEveryCorner() public {
        // Token far cheaper than the pair -> deeply NEGATIVE tick when the token is currency0.
        _seedOnce(1_000_000_000e18, 1e18, 60, true);
        _seedOnce(1_000_000_000e18, 1e18, 60, false);

        // Token far more expensive than the pair -> POSITIVE tick when the token is currency0.
        _seedOnce(1e18, 1_000_000e18, 60, true);
        _seedOnce(1e18, 1_000_000e18, 60, false);

        // Spacing of 1: every tick is aligned, so the rounding branches are no-ops.
        _seedOnce(1_000_000_000e18, 137e18, 1, true);
        _seedOnce(1_000_000_000e18, 137e18, 1, false);

        // A coarse spacing, where the snap moves the price by a visible amount.
        _seedOnce(1_000_000_000e18, 137e18, 2000, true);
        _seedOnce(1_000_000_000e18, 137e18, 2000, false);

        // A prime-ish market cap so the raw tick is never a multiple of the spacing.
        _seedOnce(999_983_000e18, 7919e18, 200, true);
        _seedOnce(999_983_000e18, 7919e18, 200, false);
    }

    /// @dev The snap direction is stated in the code as "round toward the side the liquidity will
    ///      sit on". The consequence a creator can see is that the pool never opens CHEAPER than
    ///      they asked for - the snapped market cap is always >= the requested one, in both
    ///      orderings.
    function test_theSnapNeverOpensTheTokenCheaperThanRequested() public {
        uint256 supply = 999_983_000e18;
        uint256 mcap = 7919e18;

        (address a,) = _seedOnce(supply, mcap, 200, true);
        PoolKey memory kA = _key(a, 200);
        assertGe(hook.marketCapOf(kA.toId()), mcap, "currency0: opened below the requested cap");

        (address b,) = _seedOnce(supply, mcap, 200, false);
        PoolKey memory kB = _key(b, 200);
        assertGe(hook.marketCapOf(kB.toId()), mcap, "currency1: opened below the requested cap");
    }

    /// @dev An opening price BELOW the legal tick band is refused by name, not silently clamped.
    function test_openingPriceBelowTheBandRevertsByName() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.salt = _mineFor(true); // token is currency0, so price = mcap / supply
        p.supply = 1e60; // 1 wei of pair against 10^60 wei of token
        p.openingMarketCap = 1;
        p.graduationThreshold = 2;

        vm.prank(creator);
        vm.expectRevert(Launcher.OpeningPriceOutOfRange.selector);
        launcher.launch(p);
    }

    /// @dev INFO. The mirror case does NOT reach `OpeningPriceOutOfRange`: the ratio is computed as
    ///      `FullMath.mulDiv(amount1, 2^192, amount0)` (Launcher.sol:540) and that call overflows
    ///      first, so the launch reverts with a bare `FullMath` revert carrying no data. Same
    ///      outcome for the creator (their launch is refused, nothing is clamped) but the error is
    ///      not one the UI can name. The overflow boundary is `amount1 / amount0 >= 2^64`.
    function test_INFO_theReciprocalCaseRevertsInsideFullMathWithNoNamedError() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.salt = _mineFor(false); // token is currency1, so the ratio is supply / mcap
        p.supply = 1e60;
        p.openingMarketCap = 1;
        p.graduationThreshold = 2;

        vm.prank(creator);
        vm.expectRevert(bytes(""));
        launcher.launch(p);
    }
}
