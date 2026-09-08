// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {PairRegistry} from "../src/PairRegistry.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Addresses} from "../script/Addresses.sol";

/// @notice Covers the two classes of pair the L1 build has to support: assets with a Chainlink USD
///         feed (WETH), and real, liquid assets that simply have no feed on this chain (WXMR).
contract PairRegistryTest is Test {
    PairRegistry internal registry;

    MockERC20 internal weth;
    MockERC20 internal wxmr;
    MockERC20 internal usdc;
    MockAggregatorV3 internal ethUsdFeed;
    MockAggregatorV3 internal sequencerFeed;

    address internal owner = address(0xA11CE);
    address internal notOwner = address(0xB0B);

    /// @dev A realistic wall-clock start. Foundry defaults `block.timestamp` to 1, which makes every
    ///      staleness subtraction underflow-adjacent and hides real bugs.
    uint256 internal constant T0 = 1_800_000_000;

    /// @dev Mainnet ETH/USD reads 8 decimals; $2,417.09 was the live value on 2026-08-31.
    int256 internal constant ETH_USD = 2417_09000000;

    function setUp() public {
        vm.warp(T0);

        registry = new PairRegistry(owner);

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wxmr = new MockERC20("Wrapped Monero", "WXMR", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        ethUsdFeed = new MockAggregatorV3(8, ETH_USD, "ETH / USD");
        sequencerFeed = new MockAggregatorV3(0, 0, "Sequencer Uptime");
    }

    // ===========================================================================================
    // Priceable pairs
    // ===========================================================================================

    function test_approvePair_storesConfigAndPrices() public {
        vm.prank(owner);
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);

        assertTrue(registry.isApproved(address(weth)), "should be approved");
        assertTrue(registry.isPriceable(address(weth)), "should be priceable");

        (uint256 price, uint8 priceDecimals) = registry.priceUsd(address(weth));
        assertEq(price, uint256(ETH_USD));
        assertEq(priceDecimals, 8);
    }

    /// @dev feedDecimals must be READ from the feed, never passed in. Hardcoding 8 is a silent
    ///      1e10 mispricing when a feed reports 18.
    function test_approvePair_readsFeedDecimalsFromChain() public {
        MockAggregatorV3 oddFeed = new MockAggregatorV3(18, 1e18, "ODD / USD");

        vm.prank(owner);
        registry.approvePair(address(weth), address(oddFeed), 3 hours, 18);

        PairRegistry.PairConfig memory cfg = registry.pairConfig(address(weth));
        assertEq(cfg.feedDecimals, 18, "feedDecimals must come from the feed");
    }

    function test_approvePair_revertsOnZeroPair() public {
        vm.prank(owner);
        vm.expectRevert(PairRegistry.ZeroAddress.selector);
        registry.approvePair(address(0), address(ethUsdFeed), 3 hours, 18);
    }

    /// @dev A zero feed must NOT silently downgrade the pair to unpriced - that is what
    ///      `approvePairWithoutOracle` is for, and it has to be a deliberate call.
    function test_approvePair_revertsOnZeroFeed() public {
        vm.prank(owner);
        vm.expectRevert(PairRegistry.ZeroAddress.selector);
        registry.approvePair(address(wxmr), address(0), 3 hours, 18);
    }

    function test_approvePair_revertsBelowMinStaleness() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PairRegistry.StalenessOutOfBounds.selector, uint32(59 minutes))
        );
        registry.approvePair(address(weth), address(ethUsdFeed), 59 minutes, 18);
    }

    function test_approvePair_revertsAboveMaxStaleness() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PairRegistry.StalenessOutOfBounds.selector, uint32(8 days)));
        registry.approvePair(address(weth), address(ethUsdFeed), 8 days, 18);
    }

    // ===========================================================================================
    // Unpriceable pairs - the WXMR case
    // ===========================================================================================

    /// @dev The whole point of the L1 port: WXMR is real, liquid and five years old, but there is
    ///      no XMR/USD Chainlink feed on Ethereum. It must be launchable without inventing a price.
    function test_approvePairWithoutOracle_approvedButNotPriceable() public {
        vm.prank(owner);
        registry.approvePairWithoutOracle(address(wxmr), 18);

        assertTrue(registry.isApproved(address(wxmr)), "WXMR must be launchable");
        assertFalse(registry.isPriceable(address(wxmr)), "WXMR must not claim a USD price");

        PairRegistry.PairConfig memory cfg = registry.pairConfig(address(wxmr));
        assertEq(cfg.feed, address(0));
        assertEq(cfg.maxStaleness, 0);
        assertEq(cfg.feedDecimals, 0);
        assertEq(cfg.tokenDecimals, 18);
    }

    /// @dev Reverting is the correct behaviour. Returning 0, or a spot-pool-derived number, would be
    ///      how a launchpad opens a permanent pool at a manipulated price.
    function test_priceUsd_revertsForUnpriceablePair() public {
        vm.prank(owner);
        registry.approvePairWithoutOracle(address(wxmr), 18);

        vm.expectRevert(abi.encodeWithSelector(PairRegistry.PairNotPriceable.selector, address(wxmr)));
        registry.priceUsd(address(wxmr));
    }

    function test_approvePairWithoutOracle_revertsOnZeroPair() public {
        vm.prank(owner);
        vm.expectRevert(PairRegistry.ZeroAddress.selector);
        registry.approvePairWithoutOracle(address(0), 18);
    }

    /// @dev Both classes must coexist; approving one must not disturb the other.
    function test_priceableAndUnpriceablePairsCoexist() public {
        vm.startPrank(owner);
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);
        registry.approvePairWithoutOracle(address(wxmr), 18);
        vm.stopPrank();

        assertTrue(registry.isPriceable(address(weth)));
        assertFalse(registry.isPriceable(address(wxmr)));
        assertEq(registry.pairCount(), 2);

        (uint256 price,) = registry.priceUsd(address(weth));
        assertEq(price, uint256(ETH_USD));
    }

    // ===========================================================================================
    // Price validation
    // ===========================================================================================

    function test_priceUsd_revertsForUnapprovedPair() public {
        vm.expectRevert(abi.encodeWithSelector(PairRegistry.PairNotApproved.selector, address(usdc)));
        registry.priceUsd(address(usdc));
    }

    function test_priceUsd_revertsWhenStale() public {
        vm.prank(owner);
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);

        // Feed stopped publishing 4 hours ago; bound is 3h.
        uint256 stamp = T0 - 4 hours;
        ethUsdFeed.setUpdatedAt(stamp);

        vm.expectRevert(
            abi.encodeWithSelector(PairRegistry.StalePrice.selector, address(weth), stamp, uint32(3 hours))
        );
        registry.priceUsd(address(weth));
    }

    /// @dev Just inside the bound must still work - an off-by-one here silently bricks launches.
    function test_priceUsd_acceptsPriceAtStalenessBoundary() public {
        vm.prank(owner);
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);

        ethUsdFeed.setUpdatedAt(T0 - 3 hours);
        (uint256 price,) = registry.priceUsd(address(weth));
        assertEq(price, uint256(ETH_USD));
    }

    function test_priceUsd_revertsOnZeroAnswer() public {
        vm.prank(owner);
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);

        ethUsdFeed.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(PairRegistry.InvalidPrice.selector, address(weth), int256(0)));
        registry.priceUsd(address(weth));
    }

    function test_priceUsd_revertsOnNegativeAnswer() public {
        vm.prank(owner);
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);

        ethUsdFeed.setAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(PairRegistry.InvalidPrice.selector, address(weth), int256(-1)));
        registry.priceUsd(address(weth));
    }

    // ===========================================================================================
    // Sequencer check - inert on L1, correct on L2
    // ===========================================================================================

    /// @dev On Ethereum L1 there is no sequencer. The feed must stay unset and prices must resolve.
    function test_sequencerCheck_disabledByDefaultOnL1() public {
        vm.prank(owner);
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);

        assertEq(registry.sequencerUptimeFeed(), address(0), "L1 must have no sequencer feed");
        (uint256 price,) = registry.priceUsd(address(weth));
        assertEq(price, uint256(ETH_USD));
    }

    function test_sequencerCheck_revertsWhenDown() public {
        vm.startPrank(owner);
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);
        registry.setSequencerFeed(address(sequencerFeed), 1 hours);
        vm.stopPrank();

        sequencerFeed.setSequencerStatus(1, T0 - 10 minutes); // 1 = down
        vm.expectRevert(PairRegistry.SequencerDown.selector);
        registry.priceUsd(address(weth));
    }

    function test_sequencerCheck_revertsInsideGracePeriod() public {
        vm.startPrank(owner);
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);
        registry.setSequencerFeed(address(sequencerFeed), 1 hours);
        vm.stopPrank();

        // Back up, but only 10 minutes ago - inside the 1h grace window.
        sequencerFeed.setSequencerStatus(0, T0 - 10 minutes);
        vm.expectRevert(PairRegistry.SequencerGracePeriod.selector);
        registry.priceUsd(address(weth));
    }

    function test_sequencerCheck_passesAfterGracePeriod() public {
        vm.startPrank(owner);
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);
        registry.setSequencerFeed(address(sequencerFeed), 1 hours);
        vm.stopPrank();

        sequencerFeed.setSequencerStatus(0, T0 - 2 hours);
        (uint256 price,) = registry.priceUsd(address(weth));
        assertEq(price, uint256(ETH_USD));
    }

    // ===========================================================================================
    // Listing and revocation
    // ===========================================================================================

    function test_revokePair_stopsNewLaunches() public {
        vm.startPrank(owner);
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);
        registry.revokePair(address(weth));
        vm.stopPrank();

        assertFalse(registry.isApproved(address(weth)));
        assertFalse(registry.isPriceable(address(weth)));
        vm.expectRevert(abi.encodeWithSelector(PairRegistry.PairNotApproved.selector, address(weth)));
        registry.priceUsd(address(weth));
    }

    /// @dev Revoking must leave the pair in the enumeration - it is a historical record, and the
    ///      list is how an indexer discovers every pair that ever existed.
    function test_revokePair_keepsPairInList() public {
        vm.startPrank(owner);
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);
        registry.revokePair(address(weth));
        vm.stopPrank();

        assertEq(registry.pairCount(), 1);
        assertEq(registry.pairAt(0), address(weth));
    }

    function test_reApprovingDoesNotDuplicateListEntry() public {
        vm.startPrank(owner);
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);
        registry.approvePair(address(weth), address(ethUsdFeed), 4 hours, 18);
        registry.approvePairWithoutOracle(address(weth), 18);
        vm.stopPrank();

        assertEq(registry.pairCount(), 1, "same pair must occupy one slot");
    }

    /// @dev Switching a pair from unpriced to priced (e.g. if an XMR/USD feed ever ships on L1)
    ///      must fully overwrite the config, not merge into it.
    function test_canUpgradeUnpricedPairToPriced() public {
        vm.startPrank(owner);
        registry.approvePairWithoutOracle(address(wxmr), 18);
        assertFalse(registry.isPriceable(address(wxmr)));

        registry.approvePair(address(wxmr), address(ethUsdFeed), 3 hours, 18);
        vm.stopPrank();

        assertTrue(registry.isPriceable(address(wxmr)));
        (uint256 price,) = registry.priceUsd(address(wxmr));
        assertEq(price, uint256(ETH_USD));
    }

    // ===========================================================================================
    // Access control
    // ===========================================================================================

    function test_approvePair_onlyOwner() public {
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);
    }

    function test_approvePairWithoutOracle_onlyOwner() public {
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        registry.approvePairWithoutOracle(address(wxmr), 18);
    }

    function test_revokePair_onlyOwner() public {
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        registry.revokePair(address(weth));
    }

    function test_setSequencerFeed_onlyOwner() public {
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        registry.setSequencerFeed(address(sequencerFeed), 1 hours);
    }

    // ===========================================================================================
    // Fuzz
    // ===========================================================================================

    function testFuzz_stalenessBoundsAreEnforced(uint32 staleness) public {
        // Read the bounds BEFORE pranking: vm.prank only covers the next call, and a view call to
        // the registry would otherwise consume it, leaving approvePair to run as address(this).
        uint32 minStaleness = registry.MIN_STALENESS();
        uint32 maxStaleness = registry.MAX_STALENESS();

        vm.prank(owner);
        if (staleness < minStaleness || staleness > maxStaleness) {
            vm.expectRevert(abi.encodeWithSelector(PairRegistry.StalenessOutOfBounds.selector, staleness));
            registry.approvePair(address(weth), address(ethUsdFeed), staleness, 18);
        } else {
            registry.approvePair(address(weth), address(ethUsdFeed), staleness, 18);
            assertTrue(registry.isApproved(address(weth)));
        }
    }

    /// @dev Any non-positive answer must be rejected, whatever its magnitude.
    function testFuzz_nonPositiveAnswersAlwaysRejected(int256 badAnswer) public {
        badAnswer = int256(bound(badAnswer, type(int192).min, 0));

        vm.prank(owner);
        registry.approvePair(address(weth), address(ethUsdFeed), 3 hours, 18);
        ethUsdFeed.setAnswer(badAnswer);

        vm.expectRevert(abi.encodeWithSelector(PairRegistry.InvalidPrice.selector, address(weth), badAnswer));
        registry.priceUsd(address(weth));
    }

    // ===========================================================================================
    // Address book
    // ===========================================================================================

    /// @dev Guards against a fat-fingered edit to Addresses.sol. These were verified with
    ///      eth_getCode on 2026-08-31.
    function test_addressBook_holdsVerifiedConstants() public pure {
        assertEq(Addresses.MAINNET_POOL_MANAGER, 0x000000000004444c5dc75cB358380D2e3dE08A90);
        assertEq(Addresses.MAINNET_WXMR, 0x465e07d6028830124BE2E4aA551fBe12805dB0f5);
        assertEq(Addresses.MAINNET_WETH9, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        assertEq(Addresses.SEPOLIA_POOL_MANAGER, 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);

        // There is no XMR/USD push feed on L1. If this ever becomes non-zero, the WXMR pair should
        // be upgraded from approvePairWithoutOracle to approvePair.
        assertEq(Addresses.MAINNET_XMR_USD_FEED, address(0));
        assertEq(Addresses.SEPOLIA_WXMR, address(0));
    }

    function test_addressBook_poolManagerResolvesPerChain() public pure {
        assertEq(Addresses.poolManager(1), Addresses.MAINNET_POOL_MANAGER);
        assertEq(Addresses.poolManager(11155111), Addresses.SEPOLIA_POOL_MANAGER);
    }

    /// @dev `Addresses.poolManager` is an internal library function, so it inlines into the caller.
    ///      `vm.expectRevert` needs the revert to happen one call deeper than the cheatcode, hence
    ///      the external hop through `this`.
    function callPoolManager(uint256 chainId) external pure returns (address) {
        return Addresses.poolManager(chainId);
    }

    /// @dev **This used to assert on chain 4663, described as "deliberately no longer supported".**
    ///      Robinhood Chain is supported now - the contracts are deployed there - so the assertion
    ///      was testing a fact that had stopped being true, and it failed the moment the address
    ///      book learned the chain. That is the test working: it is a guard against the address
    ///      book silently answering for a network nobody configured.
    ///
    ///      Re-pointed at a chain id that is genuinely unknown and has no prospect of being added,
    ///      so the guard keeps testing the property rather than a particular chain's status.
    function test_addressBook_revertsOnUnknownChain() public {
        vm.expectRevert("Addresses: unsupported chain");
        this.callPoolManager(999_999_999);
    }

    /// @dev The positive half, added alongside: every chain we DO claim to support must answer with
    ///      a non-zero PoolManager. Without this, deleting a branch from `Addresses.poolManager`
    ///      would still pass the negative test above and break every deploy on that chain.
    function test_addressBook_answersForEverySupportedChain() public view {
        assertTrue(Addresses.poolManager(Addresses.MAINNET_CHAIN_ID) != address(0), "mainnet");
        assertTrue(Addresses.poolManager(Addresses.SEPOLIA_CHAIN_ID) != address(0), "sepolia");
        assertTrue(Addresses.poolManager(Addresses.ROBINHOOD_CHAIN_ID) != address(0), "robinhood");
    }
}
