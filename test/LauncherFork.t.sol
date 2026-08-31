// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {Addresses} from "../script/Addresses.sol";

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

/// @title LauncherForkTest
/// @notice A complete launch against the **real Uniswap v4 PoolManager** and the **real WXMR**
///         contract on an Ethereum mainnet fork.
///
/// @dev The local suites deploy their own PoolManager and their own mock pair. Both are honest
///      tests of our logic and neither proves the thing that actually breaks a port: that the
///      deployed singleton at `0x0000...4444c5dc75cB358380D2e3dE08A90` accepts our hook, that a
///      5.6-year-old custodial token behaves like an ERC-20 when our Distributor calls it, and that
///      the whole settlement cycle balances against a PoolManager we did not compile ourselves.
///
///      **The fork block is pinned.** An unpinned fork test passes today and fails next week for
///      reasons unrelated to the diff, which trains everyone to ignore it.
///
///      Skipped automatically when no RPC is reachable, so an offline run still passes.
///      Run explicitly:  forge test --match-contract LauncherForkTest -vv
contract LauncherForkTest is Test {
    using StateLibrary for IPoolManager;

    /// @dev Pinned 2026-09. Chosen a little behind head so the public RPC reliably has the state.
    uint256 internal constant FORK_BLOCK = 25_875_500;
    /// @dev The same block as a JSON-RPC quantity, for the archive probe below. `setUp` asserts the
    ///      two agree so they cannot drift.
    string internal constant FORK_BLOCK_HEX = "0x18ad42c";

    /// @notice The real Uniswap V2 WXMR/WETH pair, created 2021-01-06.
    /// @dev Resolved from the V2 factory's `getPair(WXMR, WETH)` rather than pasted from a UI.
    address internal constant WXMR_WETH_V2_PAIR = 0x14C10b4BDcCD9d3F8940Fb79E0eE00121391D6dE;

    IPoolManager internal manager;
    IERC20 internal wxmr;
    PairRegistry internal registry;
    FeeHook internal hook;
    Launcher internal launcher;
    LaunchToken internal tokenImpl;
    PoolSwapTest internal swapRouter;

    address internal creator = address(0xC0EA702);
    address internal trader = address(0x7EAD);
    address internal holder = address(0xB0B);

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    /// @dev 20 XMR. Against a token whose ENTIRE supply is 7,000, a seed has to be small to be
    ///      realistic - this is deliberately a plausible launch, not a round number.
    uint256 internal constant OPENING_MCAP = 20e18;
    /// @dev 2x the opening market cap. The pool opens with all supply against `OPENING_MCAP`, so the
    ///      opening market cap in pair units is exactly `OPENING_MCAP` = 20 WXMR.
    uint256 internal constant GRADUATION_THRESHOLD = 40e18;

    bool internal forked;

    /// @dev **A pinned fork makes every state read an ARCHIVE request**, and most free endpoints
    ///      serve head happily while refusing history - `ethereum-rpc.publicnode.com`, which this
    ///      suite used to point at, now answers archive reads with a 403 asking for an account.
    ///
    ///      The failure mode is nasty because Foundry CACHES fork state on disk: the tests keep
    ///      passing on the machine that first ran them and fail for everyone else, and adding one
    ///      new assertion that touches one uncached slot is enough to break them locally too.
    ///
    ///      So each candidate is PROBED with a real archive read before the fork is created.
    ///      `vm.createFork` succeeding proves only that the endpoint exists.
    function _selectArchiveFork() internal returns (bool) {
        string[3] memory candidates = ["mainnet_public", "mainnet_archive_alt", "mainnet_archive_alt2"];
        string memory probe = string.concat(
            '["0x000000000004444c5dc75cB358380D2e3dE08A90","0x0","', FORK_BLOCK_HEX, '"]'
        );

        for (uint256 i = 0; i < candidates.length; ++i) {
            try vm.rpc(candidates[i], "eth_getStorageAt", probe) returns (bytes memory) {
                try vm.createFork(candidates[i], FORK_BLOCK) returns (uint256 forkId) {
                    vm.selectFork(forkId);
                    return true;
                } catch {}
            } catch {}
        }
        return false;
    }

    function setUp() public {
        require(FORK_BLOCK == 0x18ad42c, "FORK_BLOCK and FORK_BLOCK_HEX disagree");

        forked = _selectArchiveFork();
        if (!forked) return;

        manager = IPoolManager(Addresses.MAINNET_POOL_MANAGER);
        wxmr = IERC20(Addresses.MAINNET_WXMR);

        swapRouter = new PoolSwapTest(manager);
        registry = new PairRegistry(address(this));
        tokenImpl = new LaunchToken();

        // WXMR has no USD feed on L1, so it can only enter through the no-oracle path.
        registry.approvePairWithoutOracle(Addresses.MAINNET_WXMR, 18);

        // Same deployment dance a real script must perform: FeeHook.launcher and Launcher.feeHook
        // are both immutable and each needs the other, so the launcher's address is reserved first.
        address predictedLauncher = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address hookAddr = address(uint160(uint256(0xF00D) << 144 | 0x20CC));
        deployCodeTo("FeeHook.sol:FeeHook", abi.encode(address(manager), predictedLauncher), hookAddr);
        hook = FeeHook(hookAddr);

        launcher = new Launcher(manager, hook, registry, address(tokenImpl));
        require(address(launcher) == predictedLauncher, "launcher address reservation failed");

        deal(Addresses.MAINNET_WXMR, creator, 1_000e18);
        deal(Addresses.MAINNET_WXMR, trader, 100e18);
        deal(Addresses.MAINNET_WXMR, holder, 100e18);

        vm.prank(creator);
        wxmr.approve(address(launcher), type(uint256).max);
        vm.prank(trader);
        wxmr.approve(address(swapRouter), type(uint256).max);
        vm.prank(holder);
        wxmr.approve(address(swapRouter), type(uint256).max);
    }

    modifier onlyForked() {
        if (!forked) vm.skip(true);
        _;
    }

    // ===========================================================================================
    // Helpers
    // ===========================================================================================

    function _params() internal pure returns (Launcher.LaunchParams memory) {
        return Launcher.LaunchParams({
            name: "Monero Stonk",
            symbol: "MSTONK",
            supply: SUPPLY,
            pair: Addresses.MAINNET_WXMR,
            openingMarketCap: OPENING_MCAP,
            graduationThreshold: GRADUATION_THRESHOLD,
            feeBps: 300,
            creatorBps: 2000,
            maxWalletBps: 200,
            tickSpacing: 60,
            devBuyPairAmount: 0,
            salt: bytes32(uint256(1)),
            minPushPayout: 1e6,
            minShareForQueue: 1e18,
            metadata: LaunchMetadata({imageCid: keccak256("img"), bannerCid: 0, infoCid: keccak256("info")})
        });
    }

    function _key(address token) internal view returns (PoolKey memory) {
        bool tokenIsCurrency0 = token < Addresses.MAINNET_WXMR;
        return PoolKey({
            currency0: Currency.wrap(tokenIsCurrency0 ? token : Addresses.MAINNET_WXMR),
            currency1: Currency.wrap(tokenIsCurrency0 ? Addresses.MAINNET_WXMR : token),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _buy(address who, address token, uint256 amountIn) internal {
        PoolKey memory k = _key(token);
        bool zeroForOne = Currency.unwrap(k.currency0) == Addresses.MAINNET_WXMR;

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
        // Fees are ERC-6909 claims until swept.
        hook.sweep(k);
    }

    // ===========================================================================================
    // The launch, against real infrastructure
    // ===========================================================================================

    /// @dev THE fork test. If the real PoolManager rejected our hook, or the real WXMR misbehaved
    ///      inside settlement, this is where it would surface - and nowhere else.
    function test_fork_launchAgainstRealWxmrAndRealPoolManager() public onlyForked {
        (address token, PoolId id) = _launch();

        assertGt(LaunchToken(token).totalSupply(), 0, "token exists");
        assertGt(wxmr.balanceOf(address(manager)), 0, "real WXMR was seeded into the real singleton");
        assertGt(LaunchToken(token).balanceOf(address(manager)), 0, "and so was the launch token");

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);
        assertGt(sqrtPriceX96, 0, "pool is initialised on the deployed PoolManager");

        // NOT `getLiquidity`, which reports liquidity ACTIVE at the current tick. A single-sided
        // position sits entirely to one side of the opening price by construction, so at the
        // opening tick itself the active figure is legitimately zero and the first trade crosses
        // into the range. What matters is that the position exists and holds the supply.
        assertGt(manager.getPositionLiquidity(id, _positionKey(token)), 0, "the position is real");
    }

    function test_fork_launcherRetainsNothing() public onlyForked {
        (address token,) = _launch();

        assertEq(wxmr.balanceOf(address(launcher)), 0, "no real WXMR stranded on the launcher");
        assertEq(LaunchToken(token).balanceOf(address(launcher)), 0, "no launch token stranded");
    }

    /// @dev The lock, verified against the real singleton's own position accounting.
    function test_fork_liquidityIsLockedInTheLauncher() public onlyForked {
        (address token, PoolId id) = _launch();

        assertGt(manager.getPositionLiquidity(id, _positionKey(token)), 0, "launcher owns the position");
    }

    /// @dev A real swap through the real PoolManager, paying a fee in real WXMR to a real holder.
    ///      This is the `CurrencyNotSettled` trap tested against a manager we did not compile.
    function test_fork_realSwapPaysHoldersInRealWxmr() public onlyForked {
        (address token,) = _launch();
        Distributor dist = LaunchToken(token).distributor();

        // Sized under the 2% max wallet: 0.2 of a 20 WXMR seed is ~1% of supply.
        _buy(trader, token, 0.2e18);
        assertGt(LaunchToken(token).balanceOf(trader), 0, "trader received the launch token");

        _buy(holder, token, 0.2e18);

        uint256 owed = dist.withdrawableOf(trader);
        assertGt(owed, 0, "holder accrued from someone else's trade");

        uint256 before = wxmr.balanceOf(trader);
        vm.prank(trader);
        dist.withdraw();

        assertEq(wxmr.balanceOf(trader) - before, owed, "paid in REAL WXMR, not in the launch token");
    }

    /// @dev Exact-input buys are the default router shape and must be charged. This is the defect
    ///      the local suite caught, re-verified against real infrastructure.
    function test_fork_exactInputBuysAreCharged() public onlyForked {
        (address token, PoolId id) = _launch();

        _buy(trader, token, 0.2e18);

        assertEq(
            hook.totalFeesTaken(id), (0.2e18 * 300) / 10_000, "fee is exactly 3% of the stated input, in WXMR"
        );
    }

    function _launch() internal returns (address token, PoolId id) {
        vm.prank(creator);
        return launcher.launch(_params());
    }

    /// @dev The single-sided position runs from the opening tick to whichever edge holds only the
    ///      launch token, so the key depends on which side the token sorted onto.
    function _positionKey(address token) internal view returns (bytes32) {
        PoolKey memory k = _key(token);
        (, int24 openingTick,,) = manager.getSlot0(k.toId());
        bool tokenIsCurrency0 = token < Addresses.MAINNET_WXMR;

        (int24 lower, int24 upper) = tokenIsCurrency0
            ? (openingTick, TickMath.maxUsableTick(60))
            : (TickMath.minUsableTick(60), openingTick);

        return Position.calculatePositionKey(address(launcher), lower, upper, bytes32(0));
    }

    // ===========================================================================================
    // Graduation, against real infrastructure
    // ===========================================================================================
    //
    // Graduation is a SIGNAL, not a mechanism: nothing migrates, the LP was locked at block 0, and
    // the latch gates nothing of value. What the fork adds over the local suite is that the market
    // cap is read out of the REAL PoolManager's `slot0` - `getSlot0` goes through `extsload`, which
    // derives a storage slot from a `POOLS_SLOT` constant that lives in Uniswap's contract, not
    // ours. A local PoolManager we compiled ourselves cannot catch a drift in that.

    /// @dev Launches with the max-wallet cap off, because clearing a graduation threshold means
    ///      buying a large slice of the float in one trade and a 2% cap would block it.
    function _launchGraduating() internal returns (address token, PoolId id) {
        Launcher.LaunchParams memory p = _params();
        p.maxWalletBps = 0;
        p.salt = bytes32(uint256(2));

        vm.prank(creator);
        return launcher.launch(p);
    }

    /// @dev The pool opens with the whole supply against 20 real WXMR, so its opening market cap is
    ///      exactly 20 WXMR - a number known from the launch parameters, not from the implementation.
    function test_fork_openingMarketCapIsThePairSeedInRealWxmr() public onlyForked {
        (, PoolId id) = _launch();

        assertApproxEqRel(
            hook.marketCapOf(id), OPENING_MCAP, 1e16, "opening market cap is what was asked for, snapped to a tick"
        );
        assertLt(hook.marketCapOf(id), GRADUATION_THRESHOLD, "and it opens below the bar");
    }

    /// @dev Below the threshold nothing fires, however many times it is checked.
    function test_fork_belowThresholdDoesNotFire() public onlyForked {
        (address token, PoolId id) = _launchGraduating();

        assertFalse(hook.checkGraduation(id), "fresh launch is not graduated");

        _buy(trader, token, 1e18); // ~1.1x: nowhere near 2x
        assertLt(hook.marketCapOf(id), GRADUATION_THRESHOLD, "still under the bar");
        assertFalse(hook.checkGraduation(id), "so it must not latch");
        assertFalse(hook.hasGraduated(id));
    }

    /// @dev Crossing fires exactly once, a second call is a no-op, and falling back does not
    ///      un-latch. All four cases in one narrative, because they are one story.
    function test_fork_crossingLatchesOnceAndNeverUnlatches() public onlyForked {
        (address token, PoolId id) = _launchGraduating();

        // 12 WXMR against a 20 WXMR seed clears 2x with room to spare, after the hook's 3%.
        _buy(trader, token, 12e18);
        assertGe(hook.marketCapOf(id), GRADUATION_THRESHOLD, "the buy cleared the bar");

        vm.recordLogs();
        assertTrue(hook.checkGraduation(id), "crossing latches");
        assertEq(_countGraduatedLogs(vm.getRecordedLogs()), 1, "exactly one Graduated event");
        assertTrue(hook.hasGraduated(id));

        // Second call: same answer, no second event.
        vm.recordLogs();
        assertTrue(hook.checkGraduation(id), "idempotent");
        assertEq(_countGraduatedLogs(vm.getRecordedLogs()), 0, "and silent");

        // Now dump the whole position back into the pool. Sells are uncharged, so this is the
        // cheapest possible way to push the price back under the bar.
        uint256 held = LaunchToken(token).balanceOf(trader);
        vm.prank(trader);
        LaunchToken(token).approve(address(swapRouter), type(uint256).max);

        PoolKey memory k = _key(token);
        bool sellIsZeroForOne = Currency.unwrap(k.currency0) == token;
        vm.prank(trader);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: sellIsZeroForOne,
                amountSpecified: -int256(held),
                sqrtPriceLimitX96: sellIsZeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertLt(hook.marketCapOf(id), GRADUATION_THRESHOLD, "price collapsed back under the bar");

        vm.recordLogs();
        assertTrue(hook.checkGraduation(id), "one way: it stays graduated");
        assertEq(_countGraduatedLogs(vm.getRecordedLogs()), 0, "and emits nothing on the way down");
        assertEq(hook.graduationProgressBps(id), 10_000, "the bar stays full");
    }

    function _countGraduatedLogs(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        bytes32 topic = keccak256("Graduated(bytes32,address,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) ++n;
        }
    }

    // ===========================================================================================
    // What the WXMR pair actually is
    // ===========================================================================================

    /// @dev Measures the real depth behind WXMR rather than asserting a claim about it.
    ///
    ///      This is a **per-pair** property, not a platform one - the registry is an allowlist and a
    ///      creator picks a pair per launch, so a shallow pair constrains only the tokens launched
    ///      against it. Recorded here so the launch UI can warn a creator who picks WXMR, and so we
    ///      find out if BTSE's pool materially changes.
    function test_fork_recordRealWxmrDepth() public onlyForked {
        IUniswapV2Pair pool = IUniswapV2Pair(WXMR_WETH_V2_PAIR);
        (uint112 r0, uint112 r1,) = pool.getReserves();

        assertEq(pool.token0(), Addresses.MAINNET_WXMR, "WXMR is token0 of the V2 pair");

        emit log_named_decimal_uint("WXMR in the main V2 pool", r0, 18);
        emit log_named_decimal_uint("WETH in the main V2 pool", r1, 18);
        emit log_named_decimal_uint("total WXMR supply       ", wxmr.totalSupply(), 18);
        emit log_named_decimal_uint("this launch's seed      ", OPENING_MCAP, 18);

        // Order-of-magnitude guards. These pin that the pair is still small and still alive; they
        // are not a price assertion and must not become one.
        assertGt(r0, 50e18, "WXMR side collapsed - re-evaluate the pair");
        assertLt(r0, 10_000e18, "WXMR side grew 30x - the depth warning may be stale");
        assertGt(r1, 5e18, "WETH side collapsed");
    }

    /// @dev The properties recorded in `Addresses.sol`, re-checked at the pinned block.
    function test_fork_wxmrStillMatchesWhatWeRecorded() public onlyForked {
        assertEq(wxmr.totalSupply(), 7000000000000000000110, "BTSE minted or burned WXMR");
        assertGt(Addresses.MAINNET_WXMR.code.length, 0, "WXMR has code");
        assertFalse(registry.isPriceable(Addresses.MAINNET_WXMR), "still no USD price on L1");
    }
}
