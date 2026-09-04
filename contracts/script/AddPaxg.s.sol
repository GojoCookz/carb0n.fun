// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PairRegistry} from "../src/PairRegistry.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Stand up a test PAXG on Sepolia so a gold-paired launch can actually be exercised.
///
/// @dev Real PAXG only exists on mainnet. Launching "against gold" on a testnet without an asset
///      to launch against would be a screenshot, not a test - the pool would never open and the
///      pair registry would reject it. This deploys the stand-in and allowlists it, which is the
///      same thing `DeployTestnet` does for tWETH and tWXMR.
contract AddPaxg is Script {
    PairRegistry constant REGISTRY = PairRegistry(0xd2Ed630c334355e8A38f06FddF9F2C72bf776340);

    function run() external {
        vm.startBroadcast();

        // 18 decimals, matching mainnet PAXG. One token, one ounce.
        MockERC20 paxg = new MockERC20("Test Paxos Gold", "tPAXG", 18);
        paxg.mint(msg.sender, 1_000_000e18);

        // No Chainlink feed on Sepolia, so it is approved but not priceable - exactly the state
        // most of the real allowlist is in on L1.
        REGISTRY.approvePairWithoutOracle(address(paxg), 18);

        vm.stopBroadcast();

        console.log("tPAXG        ", address(paxg));
        require(REGISTRY.isApproved(address(paxg)), "tPAXG not approved");
        require(!REGISTRY.isPriceable(address(paxg)), "tPAXG must not be priceable");
        console.log("--- approved and unpriceable, as intended ---");
    }
}
