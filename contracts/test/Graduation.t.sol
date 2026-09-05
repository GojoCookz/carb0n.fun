// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {Launcher} from "../src/Launcher.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Distributor} from "../src/Distributor.sol";
import {PairRegistry} from "../src/PairRegistry.sol";
import {LaunchMetadata} from "../src/types/LaunchMetadata.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title GraduationHarness
/// @notice Graduation is a **signal, not a mechanism**: tokens go live to the DEX immediately, the
///         LP is locked from block 0, and nothing migrates. All that exists is a threshold, a
///         one-way latch, and an event for indexers.
///
/// @dev **Every test here runs in BOTH currency orientations.** Market cap is read off
///      `slot0.sqrtPriceX96`, and `sqrtPriceX96` encodes `sqrt(amount1/amount0)` - so which side
///      the launch token sorted onto INVERTS the entire price calculation. A market-cap reader that
///      is correct when the token is currency0 and silently returns the reciprocal when it is
///      currency1 would still be monotonic in price, still fire a plausible-looking event, and be
///      wrong by many orders of magnitude. The salt is mined per orientation for exactly that
///      reason, the same way `FeeHook.t.sol` does it.
///
///      The launches go through the real `Launcher` against a real `PoolManager`. Market cap is a
///      property of the pool's price, and a mocked price proves nothing about the conversion.
abstract contract GraduationHarness is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolManager internal manager;
    PairRegistry internal registry;
    /// Where the platform's 1% of volume lands. A distinct address from every other actor in
    /// these tests on purpose: routing it to `address(this)` would hide a misrouted fee inside
    /// the test contract's own balance, which is exactly the bug worth catching.
    address internal constant PLATFORM = address(0xFEE0);
    FeeHook internal hook;
    Launcher internal launcher;
    LaunchToken internal tokenImpl;
    MockERC20 internal pair;
    PoolSwapTest internal swapRouter;

    address internal creator = address(0xC0EA702);
    address internal trader = address(0x7EAD);
    address internal stranger = address(0x57A);

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    /// @dev The pool opens with the ENTIRE supply against this, and the opening price is exactly
    ///      that ratio - so the opening market cap, in pair units, is exactly `OPENING_MCAP`.
    uint256 internal constant OPENING_MCAP = 100e18;
    /// @dev 5x the opening market cap.
    uint256 internal constant THRESHOLD = 500e18;

    /// @dev A buy big enough to take the price past 5x. The curve behaves as constant product with
    ///      reserves (SUPPLY, OPENING_MCAP), so paying `x` moves the price by `(1 + 0.97x/seed)^2` -
    ///      the 0.97 being the 3% the hook skims before the input reaches the curve. 200 gives
    ///      ~8.6x, which is comfortably clear of the threshold without relying on exact curve math.
    uint256 internal constant BUY_PAST_THRESHOLD = 200e18;
    /// @dev Well under the threshold: ~1.2x the opening.
    uint256 internal constant BUY_UNDER_THRESHOLD = 10e18;

    /// @notice Clone salt that puts the launch token on the side this subclass wants. Mined once.
    bytes32 internal launchSalt;

    /// @notice Set by the concrete subclass. Decides which side of the pool the launch token is on.
    function _tokenIsCurrency0() internal pure virtual returns (bool);

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        registry = new PairRegistry(address(this));
        tokenImpl = new LaunchToken();
        pair = new MockERC20("Wrapped Ether", "WETH", 18);

        registry.approvePairWithoutOracle(address(pair), 18);

        // Same immutable circular dependency the real deploy script has to solve: reserve the
        // launcher's CREATE address, place the hook against it, then deploy into the reserved slot.
        address predictedLauncher = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address hookAddr = address(uint160(uint256(0xF00D) << 144 | 0x20CC));
        deployCodeTo("FeeHook.sol:FeeHook", abi.encode(address(manager), predictedLauncher, PLATFORM), hookAddr);
        hook = FeeHook(hookAddr);

        launcher = new Launcher(IPoolManager(address(manager)), hook, registry, address(tokenImpl));
        assertEq(address(launcher), predictedLauncher, "launcher must land on the reserved address");

        pair.mint(creator, 1_000_000e18);
        pair.mint(trader, 1_000_000e18);
        pair.mint(stranger, 1_000_000e18);

        vm.prank(creator);
        pair.approve(address(launcher), type(uint256).max);
        vm.prank(trader);
        pair.approve(address(swapRouter), type(uint256).max);
        vm.prank(stranger);
        pair.approve(address(swapRouter), type(uint256).max);

        // Mined ONCE, here. `_sortedSalt` makes external calls to the launcher, and calling it from
        // inside `_params()` while a `vm.prank` is pending would spend the prank on the prediction
        // instead of on `launch` - a silent, very confusing loss of the creator's identity.
        launchSalt = _sortedSalt();
    }

    // ===========================================================================================
    // Harness internals
    // ===========================================================================================

    function _params() internal view returns (Launcher.LaunchParams memory) {
        return Launcher.LaunchParams({
            name: "Hoodstonk",
            symbol: "HOOD",
            supply: SUPPLY,
            pair: address(pair),
            openingMarketCap: OPENING_MCAP,
            graduationThreshold: THRESHOLD,
            feeBps: 300,
            sellFeeBps: 0,
            burnBps: 0,
            vestDuration: 0,
            vestCliff: 0,
            creatorBps: 2000,
            // Disabled. Reaching a graduation threshold means buying a large slice of the float,
            // and a max-wallet cap would make every test here a max-wallet test instead.
            maxWalletBps: 0,
            tickSpacing: 60,
            devBuyPairAmount: 0,
            salt: launchSalt,
            minPushPayout: 1e6,
            minShareForQueue: 1e18,
            rewardCurrency: address(0),
            feeRecipient: address(0),
            referrer: address(0),
            openingWindow: 0, openingFeeBps: 0, metadata: LaunchMetadata({
                imageCid: keccak256("image"), bannerCid: keccak256("banner"), infoCid: keccak256("info")
            })
        });
    }

    /// @dev Mines a clone salt so the launch token sorts onto the side this subclass wants.
    ///      `Launcher.predictTokenAddress` is the contract's own prediction, so if it were wrong the
    ///      launch would land on the other side and the orientation assertions would catch it.
    function _sortedSalt() internal view returns (bytes32) {
        for (uint256 i = 1; i < 4096; ++i) {
            bytes32 salt = bytes32(i);
            if ((launcher.predictTokenAddress(salt) < address(pair)) == _tokenIsCurrency0()) {
                return salt;
            }
        }
        revert("no salt found for requested currency ordering");
    }

    function _launch() internal returns (address token, PoolId id) {
        Launcher.LaunchParams memory p = _params();
        vm.prank(creator);
        (token, id) = launcher.launch(p);

        assertEq(token < address(pair), _tokenIsCurrency0(), "launch landed on the wrong side");

        // Sells need the token approved to the router; buys only needed the pair.
        vm.prank(trader);
        LaunchToken(token).approve(address(swapRouter), type(uint256).max);
        vm.prank(stranger);
        LaunchToken(token).approve(address(swapRouter), type(uint256).max);
    }

    function _key(address token) internal view returns (PoolKey memory) {
        bool tokenIsCurrency0 = token < address(pair);
        return PoolKey({
            currency0: Currency.wrap(tokenIsCurrency0 ? token : address(pair)),
            currency1: Currency.wrap(tokenIsCurrency0 ? address(pair) : token),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _swap(address who, address token, bool zeroForOne, int256 amountSpecified) internal {
        vm.prank(who);
        swapRouter.swap(
            _key(token),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        // Fees are ERC-6909 claims until swept.
        hook.sweep(_key(token));
    }

    /// @dev An ordinary exact-input buy - the shape a router sends.
    function _buy(address who, address token, uint256 pairIn) internal {
        _swap(who, token, !_tokenIsCurrency0(), -int256(pairIn));
    }

    function _sell(address who, address token, uint256 tokenIn) internal {
        _swap(who, token, _tokenIsCurrency0(), -int256(tokenIn));
    }

    function _graduatedTopic() internal pure returns (bytes32) {
        return keccak256("Graduated(bytes32,address,uint256,uint256,uint256)");
    }

    function _countGraduatedLogs(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        bytes32 topic = _graduatedTopic();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) ++n;
        }
    }

    // ===========================================================================================
    // Market cap: the conversion from sqrtPriceX96 to a number in pair units
    // ===========================================================================================

    /// @dev **The anchor test.** The pool is seeded with the whole supply against `OPENING_MCAP` and
    ///      opens at exactly that ratio, so market cap = supply x (seed/supply) = `OPENING_MCAP`
    ///      EXACTLY - a known value, not a value copied out of the implementation.
    ///
    ///      Running it in both orientations is what makes it worth writing: an inverted branch would
    ///      report `supply^2 / seed` here, which is 1e34 pair units instead of 100.
    function test_openingMarketCapEqualsThePairSeed() public {
        (, PoolId id) = _launch();

        assertApproxEqRel(
            hook.marketCapOf(id), OPENING_MCAP, 1e16, "opening market cap must be the market cap asked for (snapped to a tick)"
        );
    }

    function test_marketCapRisesWithPriceAndFallsBackWithIt() public {
        (address token, PoolId id) = _launch();
        uint256 opening = hook.marketCapOf(id);

        _buy(trader, token, BUY_PAST_THRESHOLD);
        uint256 peak = hook.marketCapOf(id);
        assertGt(peak, opening, "buying raises market cap");

        _sell(trader, token, LaunchToken(token).balanceOf(trader));
        uint256 after_ = hook.marketCapOf(id);
        assertLt(after_, peak, "selling lowers it again");
    }

    /// @dev A pool that was configured but never initialised has no price at all. `getSlot0`
    ///      returns a zero `sqrtPriceX96` there, and the reciprocal branch would divide by it.
    function test_marketCapOfAnUninitialisedPoolIsZero() public {
        (address token,) = _launch();
        PoolKey memory unopened = _key(token);
        unopened.tickSpacing = 120; // a different pool, never initialised
        PoolId id = unopened.toId();

        vm.startPrank(address(launcher));
        hook.configurePool(unopened, address(1), Currency.wrap(address(pair)), 300, creator, 2000);
        hook.configureGraduation(unopened, THRESHOLD, SUPPLY);
        vm.stopPrank();

        assertEq(hook.marketCapOf(id), 0, "no price means no market cap");
        assertFalse(hook.checkGraduation(id), "and certainly no graduation");
    }

    /// @dev The supply is cached at configuration instead of read live, so `checkGraduation` makes
    ///      no external call to the token at all. That is only sound because `LaunchToken` mints
    ///      once and has no burn. **If a burn is ever added, this test fails and the cache must go.**
    function test_cachedSupplyStaysTrue() public {
        (address token, PoolId id) = _launch();

        _buy(trader, token, BUY_UNDER_THRESHOLD);
        _sell(trader, token, LaunchToken(token).balanceOf(trader) / 2);

        // The launcher burns unseeded dust to 0xdEaD, which must not move totalSupply either.
        // The amount is read BEFORE the prank: `balanceOf` is an external call and would otherwise
        // consume it, sending the transfer from the test contract instead.
        uint256 toBurn = LaunchToken(token).balanceOf(trader) / 2;
        vm.prank(trader);
        LaunchToken(token).transfer(address(0xdEaD), toBurn);

        (, uint256 cachedSupply,,,,) = hook.graduation(id);
        assertEq(cachedSupply, SUPPLY, "cached at launch");
        assertEq(LaunchToken(token).totalSupply(), cachedSupply, "and still true after trading");
    }

    // ===========================================================================================
    // Configuration
    // ===========================================================================================

    function test_launchRecordsTheThresholdAndTheRightToken() public {
        (address token, PoolId id) = _launch();

        (
            uint256 threshold,
            uint256 supply,
            address recordedToken,
            uint64 graduatedAt,
            bool tokenIsCurrency0,
            bool graduated
        ) = hook.graduation(id);

        assertEq(threshold, THRESHOLD, "threshold recorded");
        assertEq(supply, SUPPLY, "supply cached");
        // Derived from the pool key rather than passed in, so this is the check that the derivation
        // picked the launch token and not the pair currency.
        assertEq(recordedToken, token, "the recorded token is the launch token");
        assertEq(tokenIsCurrency0, _tokenIsCurrency0(), "orientation recorded");
        assertEq(graduatedAt, 0, "not graduated at launch");
        assertFalse(graduated, "not graduated at launch");
    }

    function test_onlyTheLauncherMayConfigureGraduation() public {
        (address token,) = _launch();
        PoolKey memory k = _key(token);
        k.tickSpacing = 120;

        vm.prank(creator);
        vm.expectRevert(FeeHook.OnlyLauncher.selector);
        hook.configureGraduation(k, THRESHOLD, SUPPLY);
    }

    /// @dev A maturity bar that can be moved after people have bought is a claim the creator can
    ///      retroactively rewrite. Same rule as the fee split.
    function test_graduationCannotBeReconfigured() public {
        (address token,) = _launch();

        vm.prank(address(launcher));
        vm.expectRevert(FeeHook.GraduationAlreadyConfigured.selector);
        hook.configureGraduation(_key(token), THRESHOLD * 2, SUPPLY);
    }

    /// @dev Zero would graduate on the first call, which is noise rather than a signal.
    function test_zeroThresholdIsRejected() public {
        (address token,) = _launch();
        PoolKey memory k = _key(token);
        k.tickSpacing = 120;

        vm.prank(address(launcher));
        vm.expectRevert(FeeHook.ThresholdRequired.selector);
        hook.configureGraduation(k, 0, SUPPLY);
    }

    function test_zeroSupplyIsRejected() public {
        (address token,) = _launch();
        PoolKey memory k = _key(token);
        k.tickSpacing = 120;

        vm.prank(address(launcher));
        vm.expectRevert(FeeHook.SupplyRequired.selector);
        hook.configureGraduation(k, THRESHOLD, 0);
    }

    /// @dev The fee config is what records the pair currency, and the pair currency is what decides
    ///      which side the launch token is on. Graduation cannot be configured before it.
    function test_graduationRequiresTheFeeConfigFirst() public {
        (address token,) = _launch();
        PoolKey memory k = _key(token);
        k.tickSpacing = 120;

        vm.prank(address(launcher));
        vm.expectRevert(FeeHook.NotConfigured.selector);
        hook.configureGraduation(k, THRESHOLD, SUPPLY);
    }

    /// @dev A threshold at or below the opening market cap means the token is born graduated.
    function test_launchRevertsWhenTheThresholdIsAtTheOpeningMarketCap() public {
        Launcher.LaunchParams memory p = _params();
        p.graduationThreshold = OPENING_MCAP;

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(Launcher.GraduationThresholdTooLow.selector, OPENING_MCAP, OPENING_MCAP)
        );
        launcher.launch(p);
    }

    function test_launchRevertsOnAZeroThreshold() public {
        Launcher.LaunchParams memory p = _params();
        p.graduationThreshold = 0;

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(Launcher.GraduationThresholdTooLow.selector, uint256(0), OPENING_MCAP)
        );
        launcher.launch(p);
    }

    /// @notice REGRESSION GUARD for audit-05 E-07. The bar is now measured against the price the
    ///         pool ACTUALLY opens at, not against the number the creator typed.
    ///
    /// @dev BEFORE: `_validate` compared `graduationThreshold` to `openingMarketCap` and nothing
    ///      else, so `OPENING_MCAP + 1` was accepted - even though `_openingTick` SNAPS the
    ///      opening price up to a usable tick and the pool therefore really opens at
    ///      **100.290561036899339019 pair** against a 100.000000000000000001 bar. The launch was
    ///      born graduated: `checkGraduation` succeeded in the launch block and
    ///      `graduationProgressBps` returned a full 10,000 before the first buyer existed.
    ///
    ///      AFTER: `Launcher._assertNotBornGraduated` reads `marketCapOf` once the pool is open
    ///      and seeded and reverts `BornGraduated(threshold, marketCapAtLaunch)`. It uses the same
    ///      function the latch itself uses, so there is no second model to keep in sync.
    ///
    ///      **How far above the open the bar sits is still entirely the creator's call** - the
    ///      companion assertion below launches one percent up and it is accepted.
    function test_aThresholdBelowTheRealOpeningPriceIsRefused() public {
        Launcher.LaunchParams memory p = _params();
        p.graduationThreshold = OPENING_MCAP + 1;

        vm.prank(creator);
        vm.expectPartialRevert(Launcher.BornGraduated.selector);
        launcher.launch(p);
    }

    /// The other half: a bar above the price the pool really opens at is accepted, and the launch
    /// is genuinely NOT graduated in its own block.
    function test_aThresholdJustAboveTheRealOpeningPriceIsAccepted() public {
        Launcher.LaunchParams memory p = _params();
        p.graduationThreshold = OPENING_MCAP + OPENING_MCAP / 100;

        vm.prank(creator);
        (, PoolId id) = launcher.launch(p);

        (uint256 threshold,,,,,) = hook.graduation(id);
        assertEq(threshold, OPENING_MCAP + OPENING_MCAP / 100);
        assertLt(hook.marketCapOf(id), threshold, "the pool opened below its own bar");
        assertFalse(hook.checkGraduation(id), "and it is not graduated in the launch block");
    }

    // ===========================================================================================
    // The latch
    // ===========================================================================================

    function test_belowThresholdDoesNotFire() public {
        (address token, PoolId id) = _launch();

        assertFalse(hook.checkGraduation(id), "nothing has happened yet");

        _buy(trader, token, BUY_UNDER_THRESHOLD);
        assertLt(hook.marketCapOf(id), THRESHOLD, "still short of the bar");

        vm.recordLogs();
        assertFalse(hook.checkGraduation(id), "and still not graduated");
        assertEq(_countGraduatedLogs(vm.getRecordedLogs()), 0, "no event on a non-crossing");

        assertFalse(hook.hasGraduated(id));
        (,,, uint64 graduatedAt,, bool graduated) = hook.graduation(id);
        assertEq(graduatedAt, 0);
        assertFalse(graduated);
    }

    /// @dev The event indexers key off. It must fire on the crossing and never again.
    function test_crossingFiresExactlyOnce() public {
        (address token, PoolId id) = _launch();
        _buy(trader, token, BUY_PAST_THRESHOLD);
        assertGe(hook.marketCapOf(id), THRESHOLD, "the buy really did clear the bar");

        // Topics only: the market cap in the payload is a live pool price, not a fixture.
        vm.expectEmit(true, true, false, false, address(hook));
        emit FeeHook.Graduated(id, token, 0, 0, 0);

        vm.recordLogs();
        assertTrue(hook.checkGraduation(id), "crossing latches");
        assertEq(_countGraduatedLogs(vm.getRecordedLogs()), 1, "exactly one event");

        assertTrue(hook.hasGraduated(id));
        (,,, uint64 graduatedAt,, bool graduated) = hook.graduation(id);
        assertEq(graduatedAt, uint64(block.timestamp), "the crossing is timestamped");
        assertTrue(graduated);
    }

    /// @dev Idempotent. A second call is a no-op that reports the same answer and emits nothing -
    ///      an event stream that repeated itself would double-count in every indexer.
    function test_aSecondCallIsANoOp() public {
        (address token, PoolId id) = _launch();
        _buy(trader, token, BUY_PAST_THRESHOLD);

        hook.checkGraduation(id);
        (,,, uint64 firstAt,,) = hook.graduation(id);

        vm.warp(block.timestamp + 1 days);
        vm.recordLogs();
        assertTrue(hook.checkGraduation(id), "still graduated");
        assertEq(_countGraduatedLogs(vm.getRecordedLogs()), 0, "and silent about it");

        (,,, uint64 secondAt,,) = hook.graduation(id);
        assertEq(secondAt, firstAt, "the timestamp is not rewritten");
    }

    /// @dev **One way.** A token that reached the bar and then fell back has still reached the bar,
    ///      and an event stream that could retract a past event would be unindexable.
    function test_fallingBackBelowDoesNotUnLatch() public {
        (address token, PoolId id) = _launch();

        _buy(trader, token, BUY_PAST_THRESHOLD);
        assertTrue(hook.checkGraduation(id), "graduated");

        _sell(trader, token, LaunchToken(token).balanceOf(trader));
        assertLt(hook.marketCapOf(id), THRESHOLD, "price collapsed back under the bar");

        vm.recordLogs();
        assertTrue(hook.checkGraduation(id), "still graduated");
        assertEq(_countGraduatedLogs(vm.getRecordedLogs()), 0, "and no second event");
        assertTrue(hook.hasGraduated(id));
        assertEq(hook.graduationProgressBps(id), 10_000, "the bar stays full");
    }

    /// @dev Permissionless: an indexer, a bot or a random wallet must all be able to latch it.
    function test_anyoneMayCallCheckGraduation() public {
        (address token, PoolId id) = _launch();
        _buy(trader, token, BUY_PAST_THRESHOLD);

        vm.prank(stranger);
        assertTrue(hook.checkGraduation(id), "a stranger can latch it");
    }

    function test_checkGraduationRevertsForAnUnknownPool() public {
        PoolId unknown = PoolId.wrap(keccak256("not a pool of ours"));

        vm.expectRevert(FeeHook.GraduationNotConfigured.selector);
        hook.checkGraduation(unknown);

        vm.expectRevert(FeeHook.GraduationNotConfigured.selector);
        hook.marketCapOf(unknown);

        vm.expectRevert(FeeHook.GraduationNotConfigured.selector);
        hook.graduationProgressBps(unknown);

        // The plain flag reader does not revert - an indexer scanning many pools should get
        // "false" for a pool it does not know rather than a failed call.
        assertFalse(hook.hasGraduated(unknown));
    }

    // ===========================================================================================
    // The progress bar the UI renders
    // ===========================================================================================

    function test_progressStartsAtTheOpeningRatioAndCapsAtFull() public {
        (address token, PoolId id) = _launch();

        // Opening market cap is OPENING_MCAP against a 5x threshold: 2,000 bps.
        assertApproxEqAbs(hook.graduationProgressBps(id), 2_000, 5, "opens at a fifth of the bar");

        _buy(trader, token, BUY_UNDER_THRESHOLD);
        uint256 mid = hook.graduationProgressBps(id);
        assertGt(mid, 2_000, "a buy moves the bar");
        assertLt(mid, 10_000, "but not to the end");

        _buy(trader, token, BUY_PAST_THRESHOLD);
        assertEq(hook.graduationProgressBps(id), 10_000, "capped, never over-full");
    }

    // ===========================================================================================
    // Graduation gates NOTHING
    // ===========================================================================================

    /// @dev The whole safety argument rests on this. Market cap comes from a spot price that anyone
    ///      can move inside one transaction, so the latch is only defensible while it controls
    ///      nothing. A buy after graduation must be charged the identical fee, pay holders the
    ///      identical way, and be subject to the identical rules as a buy before it.
    function test_graduationChangesNothingAboutTrading() public {
        (address token, PoolId id) = _launch();
        Distributor dist = LaunchToken(token).distributor();
        uint256 window = dist.STREAM_WINDOW();
        uint256 t0 = block.timestamp;

        // Establish a holder so distributions actually land, then measure a control buy.
        _buy(trader, token, BUY_PAST_THRESHOLD);
        uint256 feesBefore = hook.totalFeesTaken(id);
        _buy(stranger, token, 1e18);
        uint256 chargedUngraduated = hook.totalFeesTaken(id) - feesBefore;

        assertFalse(hook.hasGraduated(id), "control buy happened before the latch");
        assertTrue(hook.checkGraduation(id), "now latch it");

        // **Drain the pre-graduation streams before taking the baseline.** A dividend vests over
        // `STREAM_WINDOW` instead of landing in the block its fee is swept, so without this the
        // delta measured below would be dominated by the CONTROL buys vesting late and would stay
        // positive even if the post-graduation buy paid holders nothing at all - the exact thing
        // this test exists to rule out. Everything armed so far is fully vested at this point, so
        // the second window measures only the trade that happens inside it.
        //
        // Absolute warps, not `block.timestamp + X` twice: under `via_ir` the timestamp is cached
        // and the second chained warp silently no-ops.
        vm.warp(t0 + window + 1);

        uint256 owedBefore = dist.withdrawableOf(trader);
        uint256 feesAtLatch = hook.totalFeesTaken(id);
        _buy(stranger, token, 1e18);
        uint256 chargedGraduated = hook.totalFeesTaken(id) - feesAtLatch;

        assertEq(chargedGraduated, chargedUngraduated, "the fee is 3% either side of graduation");

        vm.warp(t0 + 2 * window + 2);
        assertGt(dist.withdrawableOf(trader) - owedBefore, 0, "holders still get paid");
        assertEq(LaunchToken(token).maxWallet(), 0, "and no cap silently appeared");
    }

    // ===========================================================================================
    // Fuzz
    // ===========================================================================================

    /// @dev Whatever the price does afterwards, the latch never clears and the bar never un-fills.
    function testFuzz_theLatchNeverClears(uint256 sellBps, uint256 extraBuy) public {
        sellBps = bound(sellBps, 1, 10_000);
        extraBuy = bound(extraBuy, 1e15, 1_000e18);

        (address token, PoolId id) = _launch();
        _buy(trader, token, BUY_PAST_THRESHOLD);
        assertTrue(hook.checkGraduation(id));

        _sell(trader, token, (LaunchToken(token).balanceOf(trader) * sellBps) / 10_000);
        assertTrue(hook.checkGraduation(id), "still graduated after a sell of any size");

        _buy(stranger, token, extraBuy);
        assertTrue(hook.checkGraduation(id), "and after any further buy");
        assertEq(hook.graduationProgressBps(id), 10_000);
    }

    /// @dev The threshold is the only thing that decides whether the opening state graduates, and
    ///      `Launcher` guarantees it is above the opening market cap - so a fresh launch is never
    ///      already graduated, at any seed.
    function testFuzz_aFreshLaunchIsNeverAlreadyGraduated(uint256 seed, uint256 thresholdMul) public {
        seed = bound(seed, 1e15, 100_000e18);
        thresholdMul = bound(thresholdMul, 2, 1_000);

        Launcher.LaunchParams memory p = _params();
        p.openingMarketCap = seed;
        p.graduationThreshold = seed * thresholdMul;

        vm.prank(creator);
        (, PoolId id) = launcher.launch(p);

        assertFalse(hook.checkGraduation(id), "a launch is never born graduated");
        assertLt(hook.graduationProgressBps(id), 10_000, "and its bar is never full");
    }
}

/// @notice The launch token sorted BELOW the pair currency: market cap reads `(sqrtP/2^96)^2`.
contract GraduationTokenIsCurrency0Test is GraduationHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

/// @notice The launch token sorted ABOVE the pair currency: market cap reads the RECIPROCAL. Every
///         assertion above must hold identically, which is the point of running it twice.
contract GraduationTokenIsCurrency1Test is GraduationHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
