// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Addresses} from "./Addresses.sol";

// ===============================================================================================
// Minimal local interfaces.
//
// **This script deliberately imports NOTHING from `src/`.** Two reasons, and the second is the
// important one:
//
//   1. It is read-only. It never deploys, so it never needs the creation code.
//   2. Importing `src/` would make this script's ability to compile depend on `src/` compiling.
//      This is the tool you reach for when you are worried about a deployment, which is exactly
//      when `src/` is most likely to be mid-edit. A verifier that cannot run until the code it is
//      checking builds is a verifier that is unavailable when it matters.
//
// The consequence to be honest about: these signatures are a COPY. If a getter is renamed in
// `src/`, this script keeps compiling and the call reverts at runtime with a decode error rather
// than a clear message. That trade is taken on purpose, and `_expectAddress` names the getter in
// its failure text so a rename is still diagnosable.
// ===============================================================================================

interface IFeeHookView {
    function launcher() external view returns (address);
    function platformRecipient() external view returns (address);
    function poolManager() external view returns (address);
}

interface ILauncherView {
    function feeHook() external view returns (address);
    function pairRegistry() external view returns (address);
    function tokenImplementation() external view returns (address);
    function referralVault() external view returns (address);
    function poolManager() external view returns (address);
    function launchCount() external view returns (uint256);
}

interface IReferralVaultView {
    function launcher() external view returns (address);
    function feeHook() external view returns (address);
    function treasury() external view returns (address);
    function tierCount() external view returns (uint8);
}

interface IPairRegistryView {
    struct PairConfig {
        bool approved;
        address feed;
        uint32 maxStaleness;
        uint8 feedDecimals;
        uint8 tokenDecimals;
    }

    function owner() external view returns (address);
    function isApproved(address pair) external view returns (bool);
    function isPriceable(address pair) external view returns (bool);
    function pairConfig(address pair) external view returns (PairConfig memory);
    function pairCount() external view returns (uint256);
    function sequencerUptimeFeed() external view returns (address);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @title VerifyDeployment
/// @notice READ-ONLY. Proves a live hoodstonk deployment is wired the way the deploy script
///         claims. Deploys nothing, broadcasts nothing, and must never be run with `--broadcast`.
///
/// @dev ## Why this exists separately from the deploy script's own assertions
///
///      The deploy script asserts against variables it is holding in memory, in the same
///      transaction batch that created them. This one takes nothing but addresses and asks the
///      chain. It can therefore be run days later, by someone else, against a deployment this
///      repo did not produce - which is the only kind of check that catches drift.
///
///      ## The check that would have caught A-8
///
///      `FeeHook.platformRecipient() == referralVault`. The Sepolia deployment passes every other
///      check in this file and fails that one: `platformRecipient` was set to the deployer EOA and
///      is immutable, so `ReferralVault.credit` is unreachable for that hook's whole life
///      (`audit/03-access-control.md:394`). Everything looked wired. Nothing was.
///
///      ## The negative control
///
///      Eleven `isApproved(x) == true` assertions prove nothing on their own: a registry whose
///      `isApproved` returned `true` unconditionally - a wrong address, a proxy pointing at the
///      wrong implementation, a getter reading the wrong mapping - would pass all eleven. The
///      controls below are three addresses that must read FALSE, two of them real mainnet tokens
///      from the same roster that were deliberately left out. Positives plus negatives together
///      are what show the call discriminates.
///
///      Run:
///        forge script script/VerifyDeployment.s.sol:VerifyDeployment --rpc-url mainnet
contract VerifyDeployment is Script {
    uint16 internal constant EXPECTED_HOOK_BITS = 0x20CC;

    // --- Negative controls ------------------------------------------------------------------
    /// @dev Real mainnet PEPE. On the app roster, deliberately NOT approved (190.2 bps hop-1).
    address internal constant NC_PEPE = 0x6982508145454Ce325dDbE47a25d4ec3d2311933;
    /// @dev Real mainnet WXMR. On the app roster, deliberately NOT approved (no v4 ETH pool).
    address internal constant NC_WXMR = 0x465e07d6028830124BE2E4aA551fBe12805dB0f5;
    /// @dev Not a token, not a contract, could not have been approved by anything. Deterministic
    ///      so this file is reproducible. `address(0)` is NOT used as a control: a zero key reads
    ///      false out of an empty mapping slot for reasons that have nothing to do with the
    ///      allowlist, so it would pass on a broken registry too.
    address internal constant NC_NOBODY = address(uint160(uint256(keccak256("hoodstonk.never.approved"))));

    struct Expected {
        address registry;
        address hook;
        address launcher;
        address vault;
        address tokenImpl;
        address registryOwner;
        address treasury;
    }

    uint256 internal failures;

    function run() external view {
        Expected memory e = Expected({
            registry: vm.envAddress("PAIR_REGISTRY"),
            hook: vm.envAddress("FEE_HOOK"),
            launcher: vm.envAddress("LAUNCHER"),
            vault: vm.envAddress("REFERRAL_VAULT"),
            tokenImpl: vm.envAddress("TOKEN_IMPL"),
            registryOwner: vm.envAddress("REGISTRY_OWNER"),
            treasury: vm.envAddress("TREASURY")
        });

        console.log("");
        console.log("=== VerifyDeployment :: chain", block.chainid, "===");
        console.log("PairRegistry  ", e.registry);
        console.log("LaunchToken   ", e.tokenImpl);
        console.log("ReferralVault ", e.vault);
        console.log("FeeHook       ", e.hook);
        console.log("Launcher      ", e.launcher);
        console.log("");

        _checkCode(e);
        _checkHookBits(e.hook);
        _checkCircularity(e);
        _checkA8(e);
        _checkRegistryOwner(e);
        _checkPairs(e.registry);
        _checkNegativeControls(e.registry);

        console.log("");
        console.log("=== EVERY CHECK PASSED, NEGATIVE CONTROLS INCLUDED ===");
    }

    // ===========================================================================================
    // 1. Code is actually there
    // ===========================================================================================

    /// @dev A deploy log says a transaction was sent. It does not say code is at the address.
    function _checkCode(Expected memory e) internal view {
        _requireCode(e.registry, "PairRegistry");
        _requireCode(e.hook, "FeeHook");
        _requireCode(e.launcher, "Launcher");
        _requireCode(e.vault, "ReferralVault");
        _requireCode(e.tokenImpl, "LaunchToken implementation");
        _requireCode(Addresses.MAINNET_POOL_MANAGER, "Uniswap v4 PoolManager");
        console.log("[ok] code present at all 6 addresses");
    }

    function _requireCode(address a, string memory label) internal view {
        require(a != address(0), string.concat("VERIFY FAIL: ", label, " is the zero address"));
        require(a.code.length > 0, string.concat("VERIFY FAIL: no code at ", label, " ", vm.toString(a)));
    }

    // ===========================================================================================
    // 2. The hook address encodes exactly the right permissions
    // ===========================================================================================

    /// @dev In v4 a hook's permission set IS the low 14 bits of its own address. Checking that the
    ///      contract exists proves nothing about whether the PoolManager will ever call it.
    ///
    ///      0x20CC = BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA
    ///               | AFTER_SWAP_RETURNS_DELTA
    ///
    ///      Asserted with `==` on all 14 bits, never with `&`. A subset test would pass a hook
    ///      carrying EXTRA permissions - and an unexpected `beforeAddLiquidity` or
    ///      `afterInitialize` bit means the manager calls a `HookBase` stub that reverts, bricking
    ///      the pool. Equally, a MISSING bit means the fee callbacks are never invoked and the
    ///      protocol's revenue is silently zero while every pool still trades normally.
    function _checkHookBits(address hook) internal pure {
        uint16 bits = uint16(uint160(hook) & 0x3FFF);
        require(
            bits == EXPECTED_HOOK_BITS,
            "VERIFY FAIL: hook address does not encode exactly 0x20CC in its low 14 bits"
        );
    }

    // ===========================================================================================
    // 3. The circular immutables actually resolved
    // ===========================================================================================

    function _checkCircularity(Expected memory e) internal view {
        _expectAddress(IFeeHookView(e.hook).launcher(), e.launcher, "FeeHook.launcher()");
        _expectAddress(ILauncherView(e.launcher).feeHook(), e.hook, "Launcher.feeHook()");

        _expectAddress(
            ILauncherView(e.launcher).pairRegistry(), e.registry, "Launcher.pairRegistry()"
        );
        _expectAddress(
            ILauncherView(e.launcher).tokenImplementation(), e.tokenImpl, "Launcher.tokenImplementation()"
        );
        _expectAddress(
            ILauncherView(e.launcher).poolManager(), Addresses.MAINNET_POOL_MANAGER, "Launcher.poolManager()"
        );
        _expectAddress(
            IFeeHookView(e.hook).poolManager(), Addresses.MAINNET_POOL_MANAGER, "FeeHook.poolManager()"
        );

        console.log("[ok] circular immutables resolved: hook <-> launcher, both -> PoolManager");
    }

    // ===========================================================================================
    // 4. THE A-8 REGRESSION GUARD
    // ===========================================================================================

    /// @dev `audit/03-access-control.md` finding A-8 / F-07. `FeeHook.platformRecipient` is
    ///      immutable and `ReferralVault.credit` is `onlyFeeHook`, so the wiring has to be right
    ///      in BOTH directions at the instant the hook's salt is mined. There is no fix afterwards
    ///      short of redeploying the hook, which means redeploying the launcher, which means every
    ///      pool already open is served by an orphaned stack forever.
    ///
    ///      The Sepolia deployment fails the first of these two and passes everything else in this
    ///      file. That is precisely why it is here.
    function _checkA8(Expected memory e) internal view {
        _expectAddress(
            IFeeHookView(e.hook).platformRecipient(),
            e.vault,
            "A-8 REGRESSION: FeeHook.platformRecipient() is not the ReferralVault - referrals can NEVER be paid"
        );
        _expectAddress(
            IReferralVaultView(e.vault).feeHook(),
            e.hook,
            "A-8 MIRROR: ReferralVault.feeHook() is not the hook - credit() reverts OnlyFeeHook forever"
        );
        _expectAddress(
            IReferralVaultView(e.vault).launcher(), e.launcher, "ReferralVault.launcher()"
        );
        _expectAddress(IReferralVaultView(e.vault).treasury(), e.treasury, "ReferralVault.treasury()");
        _expectAddress(
            ILauncherView(e.launcher).referralVault(), e.vault, "Launcher.referralVault()"
        );

        require(
            IReferralVaultView(e.vault).tierCount() == 5,
            "VERIFY FAIL: ReferralVault.tierCount() is not 5 - the referral schedule did not take"
        );

        console.log("[ok] A-8 guard: platformRecipient IS the vault, and the vault points back at the hook");
    }

    // ===========================================================================================
    // 5. Registry ownership
    // ===========================================================================================

    /// @dev `PairRegistry` is the only gate on which currencies may be launched or paid against,
    ///      and the half that matters is REVOCATION: if ownership is lost, a pair currency that
    ///      later pauses, blacklists or gets exploited stays launchable for the life of the
    ///      deployment. `renounceOwnership` is overridden to revert in `src/`, but that is a claim
    ///      about the source - this checks the deployed object.
    function _checkRegistryOwner(Expected memory e) internal view {
        address owner = IPairRegistryView(e.registry).owner();
        require(owner != address(0), "VERIFY FAIL: PairRegistry.owner() is the zero address - allowlist is frozen");
        _expectAddress(owner, e.registryOwner, "PairRegistry.owner()");
        require(
            IPairRegistryView(e.registry).sequencerUptimeFeed() == address(0),
            "VERIFY FAIL: a sequencer uptime feed is set, but Ethereum L1 has no sequencer"
        );
        console.log("[ok] PairRegistry.owner() is the intended owner and is not address(0)");
    }

    // ===========================================================================================
    // 6. The pair allowlist
    // ===========================================================================================

    /// @dev Also re-reads `decimals()` off each token and compares it to what the registry stored.
    ///      `approvePair` takes `tokenDecimals` as a PARAMETER (despite the docstring at
    ///      `PairRegistry.sol:103` saying decimals are read from the contract), so a typo there is
    ///      a silent 1e12 mispricing on USDC/USDT/XAUT and a 1e10 one on WBTC. This is the check
    ///      that turns that from a hope into a fact.
    function _checkPairs(address registry) internal view {
        address[11] memory tokens = [
            Addresses.MAINNET_WETH9, // WETH  6.3 bps
            0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, // WBTC  6.6 bps,  8 dp
            Addresses.MAINNET_USDC, // USDC  6.7 bps,  6 dp
            0xdAC17F958D2ee523a2206206994597C13D831ec7, // USDT  8.1 bps,  6 dp
            0x514910771AF9Ca656af840dff83E8264EcF986CA, // LINK 35.0 bps
            0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9, // AAVE 36.7 bps
            0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, // UNI  38.1 bps
            0x68749665FF8D2d112Fa859AA293F07A622782F38, // XAUT 41.3 bps,  6 dp
            0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3, // ONDO 59.1 bps
            0xD533a949740bb3306d119CC777fa900bA034cd52, // CRV  89.6 bps
            0x45804880De22913dAFE09f4980848ECE6EcbAf78 // PAXG 96.7 bps
        ];

        for (uint256 i = 0; i < tokens.length; i++) {
            require(
                IPairRegistryView(registry).isApproved(tokens[i]),
                string.concat("VERIFY FAIL: intended pair is NOT approved: ", vm.toString(tokens[i]))
            );

            uint8 stored = IPairRegistryView(registry).pairConfig(tokens[i]).tokenDecimals;
            uint8 onChain = IERC20Decimals(tokens[i]).decimals();
            require(
                stored == onChain,
                string.concat(
                    "VERIFY FAIL: registry decimals disagree with the token: ", vm.toString(tokens[i])
                )
            );
        }

        require(
            IPairRegistryView(registry).pairCount() == tokens.length,
            "VERIFY FAIL: registry holds a different number of pairs than were intended"
        );

        // WETH is the only pair registered WITH a Chainlink feed. Asserted in both directions so
        // an accidental `approvePair(x, feed)` on another pair shows up here.
        require(
            IPairRegistryView(registry).isPriceable(Addresses.MAINNET_WETH9),
            "VERIFY FAIL: WETH should be priceable via the ETH/USD feed"
        );
        for (uint256 i = 1; i < tokens.length; i++) {
            require(
                !IPairRegistryView(registry).isPriceable(tokens[i]),
                string.concat("VERIFY FAIL: pair unexpectedly has an oracle: ", vm.toString(tokens[i]))
            );
        }

        console.log("[ok] all 11 intended pairs approved, decimals match the tokens, only WETH is priceable");
    }

    // ===========================================================================================
    // 7. NEGATIVE CONTROLS
    // ===========================================================================================

    /// @dev The eleven positives above are compatible with an `isApproved` that always returns
    ///      true. These three are not. Two of them are real mainnet tokens on the same roster
    ///      that were deliberately excluded, so they are the same SHAPE of input as the positives
    ///      - which is what makes them a control rather than a formality.
    function _checkNegativeControls(address registry) internal view {
        require(
            !IPairRegistryView(registry).isApproved(NC_PEPE),
            "NEGATIVE CONTROL FAILED: PEPE reads as approved and was never added - isApproved does not discriminate"
        );
        require(
            !IPairRegistryView(registry).isApproved(NC_WXMR),
            "NEGATIVE CONTROL FAILED: WXMR reads as approved and was never added"
        );
        require(
            !IPairRegistryView(registry).isApproved(NC_NOBODY),
            "NEGATIVE CONTROL FAILED: an address that cannot exist reads as approved"
        );
        require(
            !IPairRegistryView(registry).isPriceable(NC_PEPE),
            "NEGATIVE CONTROL FAILED: PEPE reads as priceable"
        );

        console.log("[ok] negative controls: PEPE, WXMR and a synthetic address all read FALSE");
    }

    // ===========================================================================================
    // Helpers
    // ===========================================================================================

    function _expectAddress(address got, address want, string memory what) internal pure {
        require(
            got == want,
            string.concat(
                "VERIFY FAIL: ", what, " expected ", vm.toString(want), " got ", vm.toString(got)
            )
        );
    }
}
