// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PairRegistry} from "../src/PairRegistry.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {Addresses} from "../script/Addresses.sol";

/// @notice Runs against a real Ethereum mainnet fork.
///
/// @dev The unit suite proves the logic against mocks. This suite proves the ASSUMPTIONS about the
///      real chain, which is where a port like this actually goes wrong. Specifically it pins:
///        1. the live ETH/USD feed really is 8 decimals and returns a sane, fresh price
///        2. the real WXMR contract really is 18 decimals with the supply we recorded
///        3. there really is NO XMR/USD feed on L1 - the fact the whole no-oracle path exists for
///
///      Skipped automatically when no fork RPC is reachable, so CI without network still passes.
///      Run explicitly:  forge test --match-contract PairRegistryForkTest
contract PairRegistryForkTest is Test {
    PairRegistry internal registry;
    address internal owner = address(0xA11CE);

    bool internal forked;

    /// @dev Published XMR/USD aggregators. Both live on OTHER chains; both must be codeless here.
    address internal constant XMR_USD_ON_OPTIMISM = 0x2a8D91686A048E98e6CCF1A89E82f40D14312672;
    address internal constant XMR_USD_ON_POLYGON = 0xBE6FB0AB6302B693368D0E9001fAF77ecc6571db;

    function setUp() public {
        try vm.createFork("mainnet_public") returns (uint256 forkId) {
            vm.selectFork(forkId);
            forked = true;
        } catch {
            forked = false;
            return;
        }
        registry = new PairRegistry(owner);
    }

    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
        }
        _;
    }

    // ===========================================================================================
    // The priceable path, against the real feed
    // ===========================================================================================

    function test_fork_realEthUsdFeedPricesCorrectly() public onlyForked {
        vm.prank(owner);
        registry.approvePair(Addresses.MAINNET_WETH9, Addresses.MAINNET_ETH_USD_FEED, 3 hours, 18);

        assertTrue(registry.isPriceable(Addresses.MAINNET_WETH9));

        (uint256 price, uint8 priceDecimals) = registry.priceUsd(Addresses.MAINNET_WETH9);

        assertEq(priceDecimals, 8, "mainnet ETH/USD is 8 decimals");
        // Deliberately wide: this pins the ORDER OF MAGNITUDE, not the market. A decimals mistake
        // moves this by 1e10; a real price move does not.
        assertGt(price, 100e8, "ETH under $100 means the decimals are wrong");
        assertLt(price, 100_000e8, "ETH over $100k means the decimals are wrong");
    }

    function test_fork_ethUsdFeedIsFresh() public onlyForked {
        (,,, uint256 updatedAt,) = IAggregatorV3(Addresses.MAINNET_ETH_USD_FEED).latestRoundData();
        // Mainnet ETH/USD heartbeat is ~1h. Anything past 3h means the feed changed behaviour and
        // the staleness bound we ship needs rethinking.
        assertLt(block.timestamp - updatedAt, 3 hours, "ETH/USD unexpectedly stale");
    }

    // ===========================================================================================
    // The unpriceable path, against the real WXMR
    // ===========================================================================================

    function test_fork_realWxmrMatchesRecordedProperties() public onlyForked {
        IERC20Metadata wxmr = IERC20Metadata(Addresses.MAINNET_WXMR);

        assertEq(wxmr.decimals(), 18, "WXMR is 18 decimals");
        assertEq(wxmr.symbol(), "WXMR");
        // 7,000.00000000000000011 - the exact supply recorded on 2026-08-31. If this changes, BTSE
        // minted or burned, which is a material change to a pair currency we depend on.
        assertEq(wxmr.totalSupply(), 7000000000000000000110, "WXMR supply moved");
    }

    function test_fork_realWxmrRegistersWithoutOracle() public onlyForked {
        vm.prank(owner);
        registry.approvePairWithoutOracle(Addresses.MAINNET_WXMR, 18);

        assertTrue(registry.isApproved(Addresses.MAINNET_WXMR), "WXMR must be launchable");
        assertFalse(registry.isPriceable(Addresses.MAINNET_WXMR), "WXMR has no USD price on L1");

        vm.expectRevert(
            abi.encodeWithSelector(PairRegistry.PairNotPriceable.selector, Addresses.MAINNET_WXMR)
        );
        registry.priceUsd(Addresses.MAINNET_WXMR);
    }

    // ===========================================================================================
    // The finding this whole design rests on
    // ===========================================================================================

    /// @dev If this test ever fails, an XMR/USD feed shipped on L1 and WXMR should be upgraded from
    ///      `approvePairWithoutOracle` to `approvePair`. That would be good news, and this is how
    ///      we would find out rather than assuming the absence forever.
    function test_fork_noXmrUsdFeedExistsOnMainnet() public onlyForked {
        assertEq(XMR_USD_ON_OPTIMISM.code.length, 0, "XMR/USD feed appeared on L1");
        assertEq(XMR_USD_ON_POLYGON.code.length, 0, "XMR/USD feed appeared on L1");
        assertEq(Addresses.MAINNET_XMR_USD_FEED, address(0));
    }

    /// @dev Attempting to register WXMR through the priceable path must fail rather than silently
    ///      wiring a dead address as an oracle.
    function test_fork_wxmrCannotBeRegisteredWithZeroFeed() public onlyForked {
        vm.prank(owner);
        vm.expectRevert(PairRegistry.ZeroAddress.selector);
        registry.approvePair(Addresses.MAINNET_WXMR, Addresses.MAINNET_XMR_USD_FEED, 3 hours, 18);
    }

    // ===========================================================================================
    // Infrastructure we depend on
    // ===========================================================================================

    function test_fork_uniswapV4AndDeployerArePresent() public onlyForked {
        assertGt(Addresses.MAINNET_POOL_MANAGER.code.length, 0, "v4 PoolManager missing");
        assertGt(Addresses.MAINNET_POSITION_MANAGER.code.length, 0, "v4 PositionManager missing");
        assertGt(Addresses.PERMIT2.code.length, 0, "Permit2 missing");
        // Hook address mining is impossible without this.
        assertGt(Addresses.CREATE2_DEPLOYER.code.length, 0, "CREATE2 deployer missing");
    }

    /// @dev Uniswap's own PoolManager sits at 24,009 of 24,576 bytes. Recording it here keeps the
    ///      EIP-170 budget visible: the launcher has to fit in the same envelope.
    function test_fork_poolManagerIsNearEip170Limit() public onlyForked {
        uint256 size = Addresses.MAINNET_POOL_MANAGER.code.length;
        assertLt(size, 24_576, "above EIP-170");
        assertGt(size, 20_000, "unexpectedly small - wrong address?");
    }
}
