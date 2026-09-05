// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {FeeHook} from "../src/FeeHook.sol";
import {Launcher} from "../src/Launcher.sol";
import {ReferralVault} from "../src/ReferralVault.sol";
import {PairRegistry} from "../src/PairRegistry.sol";
import {Addresses} from "./Addresses.sol";

/// @title RedeploySepolia
/// @notice Redeploy the launch stack after `FeeHook` and `Launcher` changed, and fix the deploy
///         ORDER that orphaned the referral vault last time.
///
/// @dev **Why a redeploy is mandatory, not tidy.** `LaunchParams` gained `openingWindow` and
///      `openingFeeBps`. Solidity folds a struct argument into the function selector, so the live
///      launcher's `launch` selector is not the one this build encodes — verified with
///      `app/launchProbe.ts`: the new selector `0x528fd43e` does not appear anywhere in the
///      deployed bytecode, and a simulated call reverts. Every launch from the UI would fail.
///      This exact thing has happened once before in this repo, when `feeRecipient` and `referrer`
///      were added.
///
///      **The A-8 fix.** `DeployTestnet` set `platformRecipient = deployer` and deployed
///      `ReferralVault` AFTER the hook. `platformRecipient` is immutable, so `credit` was
///      unreachable for that hook's entire life and referrals could never be paid by it. Since the
///      hook's address is MINED anyway, the vault can simply be predicted and mined against.
///
///      **The three-way circularity and the only order that resolves it.** The hook needs the
///      launcher and the vault; the launcher needs the hook; the vault needs the launcher and the
///      hook. All three are immutable. Nothing can be deployed first, so two are predicted:
///
///        nonce n     FeeHook, CREATE2 — address comes from the mined salt, not the nonce, but the
///                    transaction still consumes n
///        nonce n+1   Launcher, CREATE  — must land exactly on `predictedLauncher`
///        nonce n+2   ReferralVault, CREATE — must land exactly on `predictedVault`
///
///      **Anything that consumes a nonce between the prediction and the deploys breaks it**, which
///      is why nothing else is deployed here. The registry, the pair tokens and the LaunchToken
///      implementation are all REUSED from the existing deployment — that is also most of the gas
///      saved, and the deployer wallet has about 0.03 ETH.
///
///      Run:
///        forge script script/RedeploySepolia.s.sol:RedeploySepolia --rpc-url $SEPOLIA_RPC_URL
///        (add --broadcast --slow only once the dry run's gas estimate fits the balance)
contract RedeploySepolia is Script {
    /// Existing, unchanged, and reused so this deploy stays inside the gas budget.
    PairRegistry constant REGISTRY = PairRegistry(0xd2Ed630c334355e8A38f06FddF9F2C72bf776340);
    Launcher constant OLD_LAUNCHER = Launcher(0x01Bb4b4f8f70DF56A3F3C754BFFd618D9f9f2Dc6);

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Reuse the clone target rather than paying to redeploy it. `LaunchToken` did not change.
        address tokenImpl = OLD_LAUNCHER.tokenImplementation();
        require(tokenImpl.code.length != 0, "no code at the existing LaunchToken implementation");
        require(address(REGISTRY).code.length != 0, "no code at the existing PairRegistry");

        console.log("deployer        ", deployer);
        console.log("balance (wei)   ", deployer.balance);
        console.log("reusing registry", address(REGISTRY));
        console.log("reusing impl    ", tokenImpl);

        vm.startBroadcast(pk);

        // Both predictions are taken BEFORE anything is deployed, and both are asserted after.
        uint64 n = uint64(vm.getNonce(deployer));
        address predictedLauncher = vm.computeCreateAddress(deployer, n + 1);
        address predictedVault = vm.computeCreateAddress(deployer, n + 2);

        // 0x20CC. Paying dividends strictly in the pair currency forces the two beforeSwap flags on
        // top of the 0x2044 every other launchpad hook uses, because `afterSwap` can only move the
        // UNSPECIFIED currency and on an exact-input buy the pair currency is the SPECIFIED one.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // **The vault is the platform recipient, not the deployer.** That single argument is the
        // A-8 fix, and it is why the vault has to be predicted rather than deployed afterwards.
        // The encoding here must match the `new FeeHook` call below EXACTLY — a mismatched
        // argument silently mines a salt for a different contract and the assertion below fails.
        (address hookAddr, bytes32 salt) = HookMiner.find(
            Addresses.CREATE2_DEPLOYER,
            flags,
            type(FeeHook).creationCode,
            abi.encode(Addresses.SEPOLIA_POOL_MANAGER, predictedLauncher, predictedVault)
        );

        FeeHook feeHook = new FeeHook{salt: salt}(
            IPoolManager(Addresses.SEPOLIA_POOL_MANAGER), predictedLauncher, predictedVault
        );
        require(address(feeHook) == hookAddr, "hook did not land on the mined address");

        Launcher launcher = new Launcher(
            IPoolManager(Addresses.SEPOLIA_POOL_MANAGER), feeHook, REGISTRY, tokenImpl
        );
        require(address(launcher) == predictedLauncher, "launcher missed its reserved address");

        // 20 / 10 / 5 / 3 / 2 percent of the platform's cut, five deep. 40% total, so the treasury
        // keeps 60% even on a fully populated chain.
        uint16[] memory tiers = new uint16[](5);
        tiers[0] = 2000;
        tiers[1] = 1000;
        tiers[2] = 500;
        tiers[3] = 300;
        tiers[4] = 200;

        ReferralVault vault =
            new ReferralVault(address(launcher), address(feeHook), deployer, tiers);
        require(address(vault) == predictedVault, "vault missed its reserved address");

        launcher.initReferralVault(address(vault));

        vm.stopBroadcast();

        // ===========================================================================================
        // Post-conditions. A deploy log says a transaction was sent, not that the system is wired.
        // ===========================================================================================
        require(address(feeHook).code.length != 0, "no code at the hook");
        require(address(launcher).code.length != 0, "no code at the launcher");
        require(address(vault).code.length != 0, "no code at the vault");

        require(uint160(address(feeHook)) & 0x3FFF == flags, "hook address does not encode the flags");
        require(feeHook.launcher() == address(launcher), "hook does not point at the launcher");
        require(address(launcher.feeHook()) == address(feeHook), "launcher does not point at the hook");

        // **The A-8 regression guard.** This is the assertion whose absence let a vault sit
        // orphaned for a whole deployment.
        require(
            feeHook.platformRecipient() == address(vault),
            "A-8: the hook's platform recipient is not the referral vault"
        );

        console.log("");
        console.log("=== hoodstonk :: Sepolia, redeployed ===");
        console.log("FeeHook       ", address(feeHook));
        console.log("Launcher      ", address(launcher));
        console.log("ReferralVault ", address(vault));
        console.log("");
        console.log("--- next: update app/src/lib/chain.ts, then re-run app/launchProbe.ts ---");
    }
}
