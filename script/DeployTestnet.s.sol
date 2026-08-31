// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {PairRegistry} from "../src/PairRegistry.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockBlacklistERC20} from "../test/mocks/MockERC20.sol";
import {MockAggregatorV3} from "../test/mocks/MockAggregatorV3.sol";
import {Addresses} from "./Addresses.sol";

/// @title DeployTestnet
/// @notice Stands the registry up on Sepolia with stand-ins for the mainnet pair currencies.
///
/// @dev Sepolia has neither WXMR nor an XMR/USD feed, so testnet has to fake both. The point of
///      this script is to exercise BOTH registry paths end to end before anything touches mainnet:
///
///        - a PRICEABLE pair   (mock WETH + mock ETH/USD feed)      -> `approvePair`
///        - an UNPRICEABLE pair (mock WXMR, no feed)                -> `approvePairWithoutOracle`
///
///      It also deploys a `MockBlacklistERC20` mirroring the pause + blacklist powers that are
///      really present in BTSE's WXMR bytecode, so the accepted-risk paths can be driven on a live
///      network rather than only in unit tests.
///
///      Run:
///        forge script script/DeployTestnet.s.sol:DeployTestnet \
///          --rpc-url sepolia --broadcast --verify
contract DeployTestnet is Script {
    /// @dev $2,417.09 at 8 decimals - the real mainnet ETH/USD reading on 2026-08-31, so testnet
    ///      starts from a plausible number instead of a round one.
    int256 internal constant ETH_USD_SEED = 2417_09000000;

    function run() external {
        require(block.chainid == Addresses.SEPOLIA_CHAIN_ID, "DeployTestnet: Sepolia only");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        PairRegistry registry = new PairRegistry(deployer);

        // --- Priceable pair: mock WETH with a mock feed -----------------------------------------
        MockERC20 weth = new MockERC20("Wrapped Ether (test)", "tWETH", 18);
        MockAggregatorV3 ethUsd = new MockAggregatorV3(8, ETH_USD_SEED, "ETH / USD (test)");
        // 3h, comfortably above mainnet ETH/USD's ~1h heartbeat. Never set this EQUAL to a
        // heartbeat or the feed will intermittently read as stale.
        registry.approvePair(address(weth), address(ethUsd), 3 hours, 18);

        // --- Unpriceable pair: the WXMR stand-in ------------------------------------------------
        // Mirrors mainnet WXMR: 18 decimals, and deliberately NO oracle, because no XMR/USD feed
        // exists on Ethereum L1.
        MockERC20 wxmr = new MockERC20("Wrapped Monero (test)", "tWXMR", 18);
        registry.approvePairWithoutOracle(address(wxmr), 18);

        // --- Hostile stand-in: pausable + blacklisting ------------------------------------------
        // Not registered. Deployed so the risks we knowingly accepted on mainnet WXMR can be
        // exercised against a live network before they matter.
        MockBlacklistERC20 hostile = new MockBlacklistERC20("Hostile Pair (test)", "tHOSTILE", 18);

        // Sequencer check stays OFF: Sepolia, like mainnet, has no sequencer uptime feed.
        require(registry.sequencerUptimeFeed() == address(0), "sequencer feed must stay unset");

        vm.stopBroadcast();

        console.log("=== hoodstonk :: Sepolia ===");
        console.log("deployer          ", deployer);
        console.log("PairRegistry      ", address(registry));
        console.log("PoolManager (v4)  ", Addresses.SEPOLIA_POOL_MANAGER);
        console.log("--- pairs ---");
        console.log("tWETH  (priceable)", address(weth));
        console.log("  feed            ", address(ethUsd));
        console.log("tWXMR  (no oracle)", address(wxmr));
        console.log("tHOSTILE (unlisted)", address(hostile));

        // Post-deploy assertions. A script that only logs has not verified anything.
        require(registry.isApproved(address(weth)), "weth not approved");
        require(registry.isPriceable(address(weth)), "weth not priceable");
        require(registry.isApproved(address(wxmr)), "wxmr not approved");
        require(!registry.isPriceable(address(wxmr)), "wxmr must not be priceable");
        require(registry.pairCount() == 2, "expected exactly 2 pairs");

        (uint256 price, uint8 dec) = registry.priceUsd(address(weth));
        require(price == uint256(ETH_USD_SEED) && dec == 8, "weth price readback failed");

        console.log("--- all post-deploy checks passed ---");
    }
}
