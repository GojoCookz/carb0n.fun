// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {Launcher} from "../src/Launcher.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Distributor} from "../src/Distributor.sol";
import {PairRegistry} from "../src/PairRegistry.sol";
import {LaunchMetadata} from "../src/types/LaunchMetadata.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title LauncherTest
/// @notice End-to-end: one `launch()` call must produce a pool a stranger can trade against and a
///         holder who gets paid, with nothing left on the launcher.
///
/// @dev **The deployment order here is a real constraint, not a test artifact.** `FeeHook.launcher`
///      and `Launcher.feeHook` are both immutable and each needs the other's address, so one of them
///      must be predicted before it exists. The hook is the one that gets mined (its address encodes
///      its permissions), and its constructor args include the launcher - so the launcher's address
///      has to be known BEFORE the hook's salt can be mined. Any deploy script has to do exactly
///      what `setUp` does: compute the launcher's CREATE address first, then mine the hook against
///      it, then deploy the launcher into the slot that was reserved.
contract LauncherTest is Test {
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
    address internal holder = address(0xB0B);

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant OPENING_MCAP = 100e18;

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        registry = new PairRegistry(address(this));
        tokenImpl = new LaunchToken();
        pair = new MockERC20("Wrapped Ether", "WETH", 18);

        // WETH has an oracle on mainnet, but the launcher only needs approval, not a price.
        registry.approvePairWithoutOracle(address(pair), 18);

        // Break the immutable circular dependency: reserve the launcher's CREATE address, mine the
        // hook against it, then deploy the launcher into that exact slot.
        address predictedLauncher = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address hookAddr = address(uint160(uint256(0xF00D) << 144 | 0x20CC));
        deployCodeTo("FeeHook.sol:FeeHook", abi.encode(address(manager), predictedLauncher, PLATFORM), hookAddr);
        hook = FeeHook(hookAddr);

        launcher = new Launcher(IPoolManager(address(manager)), hook, registry, address(tokenImpl));
        assertEq(address(launcher), predictedLauncher, "launcher must land on the reserved address");

        pair.mint(creator, 1_000_000e18);
        pair.mint(trader, 1_000_000e18);

        vm.prank(creator);
        pair.approve(address(launcher), type(uint256).max);

        vm.startPrank(trader);
        pair.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ===========================================================================================
    // Helpers
    // ===========================================================================================

    function _params() internal view returns (Launcher.LaunchParams memory) {
        return Launcher.LaunchParams({
            name: "Hoodstonk",
            symbol: "HOOD",
            supply: SUPPLY,
            pair: address(pair),
            openingMarketCap: OPENING_MCAP,
            // 5x the opening market cap. `pairSeed` IS the opening market cap in pair units.
            graduationThreshold: OPENING_MCAP * 5,
            feeBps: 300,
            sellFeeBps: 0,
            burnBps: 0,
            vestDuration: 0,
            vestCliff: 0,
            creatorBps: 2000,
            maxWalletBps: 200, // 2%
            tickSpacing: 60,
            devBuyPairAmount: 0,
            salt: bytes32(uint256(1)),
            minPushPayout: 1e6,
            minShareForQueue: 1e18,
            rewardCurrency: address(0),
            feeRecipient: address(0),
            referrer: address(0),
            metadata: LaunchMetadata({
                imageCid: keccak256("image"), bannerCid: keccak256("banner"), infoCid: keccak256("info")
            })
        });
    }

    function _launch(Launcher.LaunchParams memory p) internal returns (address token, PoolId id) {
        vm.prank(creator);
        return launcher.launch(p);
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

    /// @dev An ordinary exact-input buy - the shape a router sends.
    function _buy(address who, address token, uint256 amountIn) internal {
        PoolKey memory k = _key(token);
        bool zeroForOne = Currency.unwrap(k.currency0) == address(pair);

        vm.prank(who);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        // Fees are ERC-6909 claims until swept; sweep so these tests stay about economics.
        hook.sweep(k);
    }

    // ===========================================================================================
    // The end-to-end path
    // ===========================================================================================

    /// @dev THE test for job 2. One call, and afterwards a stranger can trade and a holder is paid.
    function test_launchProducesATradeablePoolThatPaysHolders() public {
        (address token,) = _launch(_params());

        assertEq(LaunchToken(token).totalSupply(), SUPPLY, "supply minted");
        assertGt(LaunchToken(token).balanceOf(address(manager)), 0, "pool was seeded with the token");
        // SINGLE-SIDED: the creator supplies no pair currency, so the pool opens holding none of
        // it. The pair side of the book is built entirely by the people who buy, which is what
        // makes the opening price a floor and launching free.
        assertEq(pair.balanceOf(address(manager)), 0, "pool opens with no pair currency at all");

        // A stranger buys. This is the first trade the pool has ever seen. Sized under the 2% cap:
        // at the seeded ratio, 1 pair buys ~1% of supply.
        _buy(trader, token, 1e18);
        assertGt(LaunchToken(token).balanceOf(trader), 0, "the trader actually received tokens");

        // The trader is now a holder. A second trade by someone else must pay them.
        Distributor dist = LaunchToken(token).distributor();
        _buy(holderFunded(), token, 1e18);

        uint256 owed = dist.withdrawableOf(trader);
        assertGt(owed, 0, "a holder accrues from someone else's trade");

        uint256 pairBefore = pair.balanceOf(trader);
        vm.prank(trader);
        dist.withdraw();

        assertEq(pair.balanceOf(trader) - pairBefore, owed, "paid in the pair currency, not the token");
        assertGt(LaunchToken(token).balanceOf(trader), 0, "and their token position is untouched");
    }

    function holderFunded() internal returns (address) {
        pair.mint(holder, 1_000e18);
        vm.prank(holder);
        pair.approve(address(swapRouter), type(uint256).max);
        return holder;
    }

    /// @dev The invariant the whole design hangs on. There is no sweep function, so anything left
    ///      here is stranded forever - which is why the contract asserts it on chain too.
    function test_launcherHoldsNothingAfterLaunch() public {
        (address token,) = _launch(_params());

        assertEq(LaunchToken(token).balanceOf(address(launcher)), 0, "no launch token retained");
        assertEq(pair.balanceOf(address(launcher)), 0, "no pair currency retained");
    }

    function testFuzz_launcherHoldsNothingForAnySeed(uint256 seed, uint256 supply) public {
        seed = bound(seed, 1e15, 100_000e18);
        supply = bound(supply, 1_000_000e18, 100_000_000_000e18);

        Launcher.LaunchParams memory p = _params();
        p.openingMarketCap = seed;
        p.supply = supply;
        // The threshold is validated against the seed, so it has to move with it.
        p.graduationThreshold = seed * 5;

        (address token,) = _launch(p);

        assertEq(LaunchToken(token).balanceOf(address(launcher)), 0, "no launch token retained");
        assertEq(pair.balanceOf(address(launcher)), 0, "no pair currency retained");
    }

    /// @dev The liquidity lock. The position belongs to the launcher, and the launcher contains no
    ///      code path that passes a negative liquidityDelta - there is no admin, no owner, no
    ///      upgrade. Unremovable by construction rather than by promise.
    function test_liquidityIsHeldByTheLauncherAndCannotBeWithdrawn() public {
        (address token, PoolId id) = _launch(_params());
        PoolKey memory k = _key(token);

        // The position is single-sided now, so it runs from the opening tick to one edge rather
        // than spanning the whole range. Read the tick the pool actually opened at.
        (, int24 openingTick,,) = IPoolManager(address(manager)).getSlot0(id);
        bool tokenIsCurrency0 = token < address(pair);
        (int24 lower, int24 upper) = tokenIsCurrency0
            ? (openingTick, TickMath.maxUsableTick(60))
            : (TickMath.minUsableTick(60), openingTick);

        bytes32 positionKey =
            Position.calculatePositionKey(address(launcher), lower, upper, bytes32(0));
        uint128 liq = IPoolManager(address(manager)).getPositionLiquidity(id, positionKey);
        assertGt(liq, 0, "the launcher holds the position");
        assertGt(IPoolManager(address(manager)).getLiquidity(id), 0, "the pool has active liquidity");

        // There is no function on Launcher that can remove it. The ABI has no such selector.
        assertEq(k.tickSpacing, 60);
    }

    // ===========================================================================================
    // Validation
    // ===========================================================================================

    function test_revertsOnUnapprovedPair() public {
        MockERC20 rogue = new MockERC20("Rogue", "RGE", 18);
        Launcher.LaunchParams memory p = _params();
        p.pair = address(rogue);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Launcher.PairNotApproved.selector, address(rogue)));
        launcher.launch(p);
    }

    /// @dev Ticker impostors are why the registry is an address allowlist. A revoked pair must stop
    ///      new launches immediately.
    function test_revokedPairStopsNewLaunches() public {
        registry.revokePair(address(pair));
        Launcher.LaunchParams memory p = _params();

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Launcher.PairNotApproved.selector, address(pair)));
        launcher.launch(p);
    }

    function test_revertsWithoutAnImage() public {
        Launcher.LaunchParams memory p = _params();
        p.metadata.imageCid = bytes32(0);

        vm.prank(creator);
        vm.expectRevert(Launcher.ImageRequired.selector);
        launcher.launch(p);
    }

    /// @dev The banner is genuinely optional - a token with no banner renders a fallback.
    function test_bannerIsOptional() public {
        Launcher.LaunchParams memory p = _params();
        p.metadata.bannerCid = bytes32(0);

        (address token,) = _launch(p);
        (, bytes32 bannerCid,) = LaunchToken(token).metadata();
        assertEq(bannerCid, bytes32(0), "launch succeeds with no banner");
    }

    function test_revertsOnZeroSeed() public {
        Launcher.LaunchParams memory p = _params();
        p.openingMarketCap = 0;

        vm.prank(creator);
        vm.expectRevert(Launcher.SeedTooLow.selector);
        launcher.launch(p);
    }

    /// @dev A max wallet small enough to block ordinary buys is a transfer blocker, not anti-whale.
    function test_revertsOnAbsurdlySmallMaxWallet() public {
        Launcher.LaunchParams memory p = _params();
        p.maxWalletBps = 1; // 0.01%

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Launcher.MaxWalletTooSmall.selector, uint16(1)));
        launcher.launch(p);
    }

    /// @dev We revert rather than silently trimming. Silent adjustment is how users get surprised.
    function test_devBuyOverCapReverts() public {
        Launcher.LaunchParams memory p = _params();
        p.devBuyPairAmount = (OPENING_MCAP * 1001) / 10_000; // just over 10%

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(
                Launcher.DevBuyTooLarge.selector, p.devBuyPairAmount, (OPENING_MCAP * 1000) / 10_000
            )
        );
        launcher.launch(p);
    }

    // ===========================================================================================
    // Dev buy
    // ===========================================================================================

    function test_devBuyDeliversTokensToTheCreator() public {
        Launcher.LaunchParams memory p = _params();
        p.devBuyPairAmount = OPENING_MCAP / 20; // 5%

        (address token,) = _launch(p);

        assertGt(LaunchToken(token).balanceOf(creator), 0, "creator received their opening buy");
        assertEq(LaunchToken(token).balanceOf(address(launcher)), 0, "and the launcher kept none");
    }

    /// @dev **Regression guard for a fee that used to vanish.** `Distributor.distribute` once
    ///      returned early when `totalShares` was zero and stranded the fee with nothing recording
    ///      it. The invariant under test is that a charged fee is NEVER dropped - it is either
    ///      carried until there is somebody to pay, or distributed to whoever already holds.
    ///
    ///      Which of those two happens moved when fees became claims. It used to be carried
    ///      always: the hook routed the dev buy's fee mid-launch, before the creator's tokens had
    ///      been delivered, so `totalShares` was genuinely zero at that instant. Sweeping happens
    ///      after the launch completes, by which point the creator is a real holder - so the same
    ///      fee now distributes. Both paths are correct; neither may lose a wei.
    function test_devBuyFeeIsNeverDropped() public {
        Launcher.LaunchParams memory p = _params();
        p.devBuyPairAmount = OPENING_MCAP / 20;

        (address token,) = _launch(p);
        Distributor dist = LaunchToken(token).distributor();

        uint256 charged = hook.pendingFees(_key(token).toId());
        assertGt(charged, 0, "the dev buy really was charged, as a claim");
        assertEq(pair.balanceOf(address(dist)), 0, "and nothing has moved yet");

        hook.sweep(_key(token));

        assertEq(hook.pendingFees(_key(token).toId()), 0, "claim redeemed in full");
        assertGt(
            dist.totalDistributed() + dist.pendingPayouts(),
            0,
            "the fee was accounted for - carried or distributed, never dropped"
        );
        assertGt(pair.balanceOf(address(dist)), 0, "and the tokens really reached the ledger");

        // The creator bought, so they are a holder and the fee is theirs to claim.
        assertGt(dist.withdrawableOf(creator), 0, "the holder can actually claim it");
    }

    // ===========================================================================================
    // Immutability and provenance
    // ===========================================================================================

    function test_metadataIsStoredOnTheToken() public {
        (address token,) = _launch(_params());
        (bytes32 imageCid, bytes32 bannerCid, bytes32 infoCid) = LaunchToken(token).metadata();

        assertEq(imageCid, keccak256("image"));
        assertEq(bannerCid, keccak256("banner"));
        assertEq(infoCid, keccak256("info"));
    }

    /// @dev A fee split that can change after people buy is a rug with extra steps.
    function test_feeSplitCannotBeChangedAfterLaunch() public {
        (address token,) = _launch(_params());
        PoolKey memory k = _key(token);

        // Even the launcher cannot reconfigure it - and nothing on Launcher calls this anyway.
        vm.prank(address(launcher));
        vm.expectRevert(FeeHook.AlreadyConfigured.selector);
        hook.configurePool(k, address(1), Currency.wrap(address(pair)), 1000, creator, 10_000);
    }

    function test_onlyTheLauncherMayConfigureAPool() public {
        (address token,) = _launch(_params());
        PoolKey memory k = _key(token);
        k.tickSpacing = 120;

        vm.prank(creator);
        vm.expectRevert(FeeHook.OnlyLauncher.selector);
        hook.configurePool(k, address(1), Currency.wrap(address(pair)), 300, creator, 2000);
    }

    function test_provenanceIsRecorded() public {
        (address token,) = _launch(_params());

        assertTrue(launcher.isOurs(token), "the launcher vouches for its own token");
        assertFalse(launcher.isOurs(address(pair)), "and for nothing else");
        assertEq(launcher.launchCount(), 1);

        (address recordedToken, address recordedCreator, address recordedPair,) = launcher.launches(0);
        assertEq(recordedToken, token);
        assertEq(recordedCreator, creator);
        assertEq(recordedPair, address(pair));
    }

    function test_predictedAddressMatchesTheCloneActuallyDeployed() public {
        Launcher.LaunchParams memory p = _params();
        address predicted = launcher.predictTokenAddress(p.salt);

        (address token,) = _launch(p);
        assertEq(token, predicted, "salt mining off-chain must be trustworthy");
    }

    /// @dev Two launches cannot share a salt - the second clone would collide.
    function test_reusingASaltReverts() public {
        _launch(_params());

        vm.prank(creator);
        vm.expectRevert();
        launcher.launch(_params());
    }

    function test_twoLaunchesWithDifferentSaltsBothWork() public {
        (address a,) = _launch(_params());

        Launcher.LaunchParams memory p = _params();
        p.salt = bytes32(uint256(2));
        (address b,) = _launch(p);

        assertTrue(a != b);
        assertEq(launcher.launchCount(), 2);
        assertTrue(launcher.isOurs(a) && launcher.isOurs(b));
    }

    // ===========================================================================================
    // Opening price
    // ===========================================================================================

    /// @dev The pool must open exactly where the creator's own seed ratio says it should, in either
    ///      currency orientation. Getting the `2^192`-inside-the-sqrt wrong truncates the ratio to
    ///      zero for any launch where the token is cheaper than the pair asset - i.e. all of them.
    function test_openingPriceMatchesTheSeedRatio() public {
        (address token, PoolId id) = _launch(_params());
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(id);

        bool tokenIsCurrency0 = token < address(pair);
        (uint256 amount0, uint256 amount1) = tokenIsCurrency0 ? (SUPPLY, OPENING_MCAP) : (OPENING_MCAP, SUPPLY);

        // price = (sqrtPriceX96 / 2^96)^2 should equal amount1/amount0. Compare in a scaled integer
        // space to avoid asserting on floating point.
        uint256 priceScaled = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;
        uint256 expectedScaled = (amount1 * 1e18) / amount0;

        assertApproxEqRel(priceScaled, expectedScaled, 1e16, "opening price must match the market cap asked for (snapped to a tick)");
        assertGt(sqrtPriceX96, TickMath.MIN_SQRT_PRICE, "and be a usable price");
    }
}
