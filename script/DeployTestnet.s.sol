// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {PairRegistry} from "../src/PairRegistry.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {Launcher} from "../src/Launcher.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
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

        // ===========================================================================================
        // The launch stack. THIS is the part that had never been run outside a test harness.
        //
        // `FeeHook.launcher` and `Launcher.feeHook` are both immutable and each needs the other's
        // address, so one of them has to exist before it exists. The hook is the one that gets
        // mined - v4 encodes a hook's permissions in the low 14 bits of its address - and the
        // launcher is one of its constructor arguments, so the launcher's address has to be known
        // BEFORE the salt can be mined.
        //
        // Order, and it is the only order that works:
        //   1. predict the launcher's CREATE address from the deployer's next nonce
        //   2. mine a CREATE2 salt for a hook built against that predicted address
        //   3. deploy the hook (CREATE2 - does not consume the deployer's nonce)
        //   4. deploy the launcher, which lands on the reserved address
        // ===========================================================================================

        LaunchToken tokenImpl = new LaunchToken();

        // CREATE2 does not touch the EOA's nonce, so the launcher is the deployer's very next
        // CREATE - one past the nonce as it stands right now.
        address predictedLauncher = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);

        // 0x20CC. BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP
        //         | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA.
        // Deliberately NOT the 0x2044 every other launchpad hook uses: paying dividends strictly
        // in the pair currency forces the two extra beforeSwap flags, because afterSwap can only
        // move the UNSPECIFIED currency and on an exact-input buy the pair currency is SPECIFIED.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // On testnet the platform's cut goes back to the deployer. On mainnet this MUST be a
        // multisig: it is immutable on the hook, so a mistake here is permanent for every pool
        // that hook ever serves.
        address platformRecipient = deployer;

        // The mined salt depends on the constructor args, so this encoding has to match the
        // `new FeeHook` call below EXACTLY - a missing argument here silently mines a salt for a
        // different contract and the deploy fails the address assertion below.
        (address hookAddr, bytes32 salt) = HookMiner.find(
            Addresses.CREATE2_DEPLOYER,
            flags,
            type(FeeHook).creationCode,
            abi.encode(Addresses.SEPOLIA_POOL_MANAGER, predictedLauncher, platformRecipient)
        );

        FeeHook feeHook = new FeeHook{salt: salt}(
            IPoolManager(Addresses.SEPOLIA_POOL_MANAGER), predictedLauncher, platformRecipient
        );
        require(address(feeHook) == hookAddr, "hook did not land on the mined address");

        Launcher launcher = new Launcher(
            IPoolManager(Addresses.SEPOLIA_POOL_MANAGER), feeHook, registry, address(tokenImpl)
        );
        require(address(launcher) == predictedLauncher, "launcher missed its reserved address");

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
        console.log("--- launch stack ---");
        console.log("LaunchToken impl  ", address(tokenImpl));
        console.log("FeeHook           ", address(feeHook));
        console.log("Launcher          ", address(launcher));

        // Post-deploy assertions. A script that only logs has not verified anything.
        require(registry.isApproved(address(weth)), "weth not approved");
        require(registry.isPriceable(address(weth)), "weth not priceable");
        require(registry.isApproved(address(wxmr)), "wxmr not approved");
        require(!registry.isPriceable(address(wxmr)), "wxmr must not be priceable");
        require(registry.pairCount() == 2, "expected exactly 2 pairs");

        (uint256 price, uint8 dec) = registry.priceUsd(address(weth));
        require(price == uint256(ETH_USD_SEED) && dec == 8, "weth price readback failed");

        // The hook's address IS its API. If these bits drift, the PoolManager silently stops
        // calling the callbacks the fee depends on and the fee quietly becomes zero.
        require(uint160(address(feeHook)) & 0x3FFF == 0x20CC, "hook address must encode 0x20CC");

        // The circular wiring, checked from both ends rather than assumed.
        require(feeHook.launcher() == address(launcher), "hook does not point at the launcher");
        require(address(launcher.feeHook()) == address(feeHook), "launcher does not point at the hook");
        require(address(launcher.pairRegistry()) == address(registry), "launcher registry mismatch");
        require(launcher.tokenImplementation() == address(tokenImpl), "launcher impl mismatch");
        require(launcher.launchCount() == 0, "a fresh launcher must have no launches");

        console.log("--- all post-deploy checks passed ---");
    }
}
