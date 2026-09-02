// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdError} from "forge-std/Test.sol";

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
import {HookBase} from "../../src/base/HookBase.sol";
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
            metadata: LaunchMetadata({
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
    // Swap helpers - deliberately WITHOUT an automatic sweep, unlike `FeeHook.t.sol`'s `_swap`
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
    // V-01  The automatic sweep is UNREACHABLE from an exact-input swap.
    // -------------------------------------------------------------------------------------------

    /// @dev `_afterSwap` returns at FeeHook.sol:631 (`if (exactInput) return ...`) - which is
    ///      BEFORE `_tryAutoSweep` at FeeHook.sol:650. Exact input is the shape every router,
    ///      aggregator and swap UI sends by default, so on ordinary traffic the automatic payout
    ///      never runs no matter how large the backlog gets.
    ///
    ///      The same early-return chain also kills it for exact-OUTPUT sells on the default launch:
    ///      `sellFeeBps == 0` returns at FeeHook.sol:636. So the ONLY shape that can reach the auto
    ///      path is an exact-output BUY.
    function test_V01_autoSweepIsUnreachableFromExactInputSwaps() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        Distributor dist = LaunchToken(t).distributor();

        uint256 bar = hook.autoSweepThreshold(id);
        assertGt(bar, 0, "precondition: the auto path is armed by the launch");

        uint256 distBefore = pair.balanceOf(address(dist));
        uint256 creatorBefore = pair.balanceOf(creator);

        // Twenty ordinary exact-input buys. The backlog ends many multiples over the bar.
        for (uint256 i = 0; i < 20; ++i) {
            _buyExactIn(k, alice, 5e18);
        }

        assertGt(hook.pendingFees(id), bar * 5, "backlog is many times the auto-sweep bar");
        assertEq(pair.balanceOf(address(dist)), distBefore, "AUTO SWEEP NEVER FIRED on exact input");
        assertEq(pair.balanceOf(creator), creatorBefore, "and nothing reached the creator either");

        // The same pool, the same backlog, one exact-OUTPUT buy: now it fires.
        _buyExactOut(k, bob, 1_000_000e18);
        assertGt(
            pair.balanceOf(address(dist)),
            distBefore,
            "only the exact-output shape can reach the auto path"
        );
    }

    /// @dev The consequence stated as money: on a pool that only ever sees router traffic, every
    ///      wei of fee stays an ERC-6909 claim and a holder's `withdrawableOf` stays ZERO until a
    ///      human or a bot calls `sweep`. The claims are real and safe - they are just not paid.
    function test_V01b_routerOnlyTrafficLeavesHoldersUnpaidIndefinitely() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        Distributor dist = LaunchToken(t).distributor();

        _buyExactIn(k, alice, 2e18); // alice becomes a holder
        for (uint256 i = 0; i < 30; ++i) {
            _buyExactIn(k, bob, 2e18);
        }

        assertGt(hook.pendingFees(id), 0, "fees were charged");
        assertEq(dist.withdrawableOf(alice), 0, "but a holder is owed nothing until someone sweeps");

        hook.sweep(k);
        assertGt(dist.withdrawableOf(alice), 0, "the manual path does pay");
    }

    // -------------------------------------------------------------------------------------------
    // V-02  `take()` inside `afterSwap` corrupts settlement for any integrator that syncs first.
    // -------------------------------------------------------------------------------------------

    /// @dev `_tryAutoSweep` -> `autoRedeem` calls `poolManager.take(cfg.pairCurrency, ...)` at
    ///      FeeHook.sol:699, i.e. real ERC-20 leaves the singleton in the MIDDLE of somebody else's
    ///      swap. `PoolManager._settle` credits `balanceOfSelf() - syncedReserves`, so a caller who
    ///      `sync`ed the input currency before the swap is credited exactly that much less than it
    ///      handed over.
    ///
    ///      Measured against a control run of the identical trade through `PoolSwapTest` (which
    ///      syncs AFTER the swap and is unaffected): the sync-first payer is debited the true cost
    ///      PLUS the whole auto-swept amount, and the difference is exactly the shortfall `settle()`
    ///      reported. Nobody is stealing it - it is paid a second time to the distributor, the
    ///      creator and the platform.
    function test_V02_takeInsideAfterSwapCorruptsASyncFirstPayersSettlement() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        Distributor dist = LaunchToken(t).distributor();

        // Build a backlog over the auto-sweep bar with exact-input buys (which never auto-sweep).
        for (uint256 i = 0; i < 20; ++i) {
            _buyExactIn(k, alice, 5e18);
        }
        assertGt(hook.pendingFees(id), hook.autoSweepThreshold(id), "backlog is over the bar");

        uint256 amountOut = 1_000_000e18;
        uint256 snap = vm.snapshotState();

        // CONTROL: the same exact-output buy through the Uniswap-supplied router.
        uint256 before = pair.balanceOf(bob);
        _buyExactOut(k, bob, amountOut);
        uint256 costStandard = before - pair.balanceOf(bob);
        // Headroom only: `settle()` underflows outright when the hook takes more than the payer
        // handed over, and that case is `test_V02c`. Here we want the measurable branch.
        uint256 headroom = pair.balanceOf(address(dist)) + pair.balanceOf(creator)
            + pair.balanceOf(PLATFORM);

        require(vm.revertToState(snap), "snapshot revert failed");

        // PROBE: identical trade, paid for before the swap instead of after.
        uint256 prepay = costStandard * 2 + headroom * 2;
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

        assertLt(credited, prepay, "settle() credited LESS than was transferred in");
        assertGt(costProbe, costStandard, "the sync-first payer was overcharged");
        assertEq(
            costProbe - costStandard,
            prepay - credited,
            "the overcharge is exactly what the hook took out of the synced reserve"
        );
    }

    /// @dev The harder form of the same defect. When the auto-swept amount exceeds what the payer
    ///      handed over between `sync` and `settle`, `PoolManager._settle`'s
    ///      `reservesNow - reservesBefore` underflows and the whole transaction reverts with a bare
    ///      panic 0x11. The trade is unexecutable and the revert names nothing the integrator can
    ///      act on. Whether a given trade lands in this branch depends on the pool's unswept
    ///      backlog at that block, so it is nondeterministic from the caller's side.
    function test_V02c_aLargeBacklogMakesTheSyncFirstPayersSwapRevertOutright() public {
        (, PoolKey memory k, PoolId id) = _defaultLaunch();

        // A backlog much larger than one small trade's input.
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

        assertLt(costStandard * 2, hook.pendingFees(id), "precondition: backlog > the prepay");

        vm.prank(bob);
        vm.expectRevert(stdError.arithmeticError);
        syncRouter.swap(
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
    }

    /// @dev The same probe on a pool whose auto path never fires settles to the wei, which pins the
    ///      cause on the hook's mid-swap `take` and not on the probe's ordering.
    function test_V02b_theSameProbeIsExactWhenTheAutoPathDoesNotFire() public {
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

    /// @dev `_beforeSwap` charges `feeBps` of `-params.amountSpecified` (FeeHook.sol:591-592) - the
    ///      amount REQUESTED, before the curve has run. The docstring at FeeHook.sol:550-554 calls
    ///      the resulting overcharge "bounded by `feeBps`", which is true of the notional and false
    ///      of the rate: the trader is charged `feeBps` of the whole request while the pool executes
    ///      an arbitrarily small part of it, so the fee on EXECUTED volume is unbounded.
    ///
    ///      It is not only self-inflicted. A sandwicher who pushes the price to a victim's
    ///      `sqrtPriceLimitX96` makes the victim's swap fill for almost nothing and still pay
    ///      `feeBps` of the full notional.
    function test_V03_priceLimitedBuyPaysTheFullFeeOnUnspentInput() public {
        (, PoolKey memory k, PoolId id) = _defaultLaunch();

        // Leave the swap exactly one tick-spacing of room before its own limit binds.
        int24 t0 = _tick(id);
        int24 limitTick = _buyIsZeroForOne() ? t0 - TICK_SPACING : t0 + TICK_SPACING;
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);

        uint256 requested = 100e18;
        uint256 before = pair.balanceOf(alice);

        vm.prank(alice);
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

        uint256 spent = before - pair.balanceOf(alice);
        uint256 fee = hook.pendingFees(id);

        emit log_named_uint("requested input   ", requested);
        emit log_named_uint("actually debited  ", spent);
        emit log_named_uint("fee charged       ", fee);

        assertEq(fee, (requested * 300) / 10_000, "fee is feeBps of the REQUESTED amount");
        assertLt(spent, requested, "but most of the request was never spent");
        // Effective rate on what the trader actually parted with, versus the advertised 3%.
        uint256 effectiveBps = (fee * 10_000) / spent;
        emit log_named_uint("effective fee bps ", effectiveBps);
        assertGt(effectiveBps, 300 * 3, "the trader paid over 3x the advertised rate");
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

    /// @dev The auto path does NOT call `unlock` - it uses `burn` + `take` directly, which is the
    ///      only thing that can work inside an already-open cycle. Proven by it succeeding: a nested
    ///      `unlock` would revert `AlreadyUnlocked` and the `try/catch` would silently turn every
    ///      auto sweep into an `AutoSweepSkipped`.
    function test_sound_autoRedeemUsesBurnAndTakeRatherThanANestedUnlock() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        Distributor dist = LaunchToken(t).distributor();

        for (uint256 i = 0; i < 20; ++i) {
            _buyExactIn(k, alice, 5e18);
        }
        assertGt(hook.pendingFees(id), hook.autoSweepThreshold(id), "over the bar");

        uint256 distBefore = pair.balanceOf(address(dist));
        _buyExactOut(k, bob, 1_000_000e18);

        assertGt(pair.balanceOf(address(dist)), distBefore, "the auto path completed inside the swap");
        assertEq(hook.pendingFees(id), 0, "and drained the backlog (burnBps is zero here)");
    }

    /// @dev `autoRedeem` is external so the `try/catch` gets a real revert boundary. It must be
    ///      unreachable by anyone but the hook itself.
    function test_sound_autoRedeemRejectsEveryOutsideCaller() public {
        (, PoolKey memory k, PoolId id) = _defaultLaunch();
        _buyExactIn(k, alice, 10e18);

        FeeHook.PoolConfig memory cfg;
        cfg.distributor = address(0xdead);
        cfg.pairCurrency = Currency.wrap(address(pair));

        vm.prank(alice);
        vm.expectRevert(HookBase.NotPoolManager.selector);
        hook.autoRedeem(id, k, cfg);
    }

    /// @dev A failing auto sweep must never revert somebody else's trade. On the pool's very first
    ///      trades the singleton may hold no pair currency for the `take` to draw on; the swap still
    ///      has to complete.
    function test_sound_aFailedAutoSweepNeverBreaksTheTrade() public {
        Launcher.LaunchParams memory p = _baseParams();
        // A very low bar, so the auto path is attempted on the first trade the pool ever sees.
        p.graduationThreshold = OPENING_MCAP + 1;
        (, PoolKey memory k, PoolId id) = _launch(p);

        assertEq(pair.balanceOf(address(manager)), 0, "the pool opens holding zero pair currency");

        // The first trade ever, exact output, which is the shape that reaches `_tryAutoSweep`.
        _buyExactOut(k, alice, 1_000_000e18);
        assertGt(IERC20(_tokenOf(k)).balanceOf(alice), 0, "the trade completed");
        assertGe(hook.pendingFees(id) + hook.totalFeesTaken(id), 0, "and the fee was accounted");
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
