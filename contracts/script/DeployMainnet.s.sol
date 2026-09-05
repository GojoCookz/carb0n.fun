// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {PairRegistry} from "../src/PairRegistry.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {Launcher} from "../src/Launcher.sol";
import {ReferralVault} from "../src/ReferralVault.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Addresses} from "./Addresses.sol";

/// @title DeployMainnet
/// @notice The Ethereum L1 deployment. Read `script/README-DEPLOY.md` before running this.
///
/// @dev ## Why this is not `DeployTestnet` with a different chain id
///
///      `DeployTestnet.s.sol:107` sets `platformRecipient = deployer` and deploys the
///      `ReferralVault` AFTER the hook. `FeeHook.platformRecipient` is **immutable**, so
///      `ReferralVault.credit` is unreachable for that hook's entire life. Referrals are recorded,
///      `launcher.referralVault()` answers, every post-deploy assertion in that script passes, and
///      not one referrer can ever be paid. That is audit finding **A-8 / F-07**
///      (`audit/03-access-control.md:394`), and repeating it on mainnet is unrecoverable without a
///      full redeploy.
///
///      ## The circularity is THREE-way, not two-way
///
///      The brief for this script said "deploy the vault first, then mine the hook against it".
///      **That is not sufficient, and doing only that reproduces the same class of bug in the
///      mirror direction.** `ReferralVault` stores `feeHook` as an immutable too
///      (`src/ReferralVault.sol:42`) and `credit` is `onlyFeeHook` (`:151`). So:
///
///        ReferralVault  needs  launcher + feeHook
///        FeeHook        needs  launcher + platformRecipient (= the vault)
///        Launcher       needs  feeHook
///
///      Three contracts, three immutables, no valid sequential order exists on its own.
///
///      ## How it is actually resolved
///
///      A contract deployed with **CREATE** has an address determined by `(deployer, nonce)` and
///      **nothing else** - notably not by its constructor arguments. A contract deployed with
///      **CREATE2** has an address determined by the salt and the init code, which *does* include
///      the constructor arguments. So the two CREATE addresses can be reserved from arithmetic
///      alone, and the one CREATE2 address is then mined against both of them:
///
///        1. reserve the ReferralVault's CREATE address  (deployer, N)
///        2. reserve the Launcher's CREATE address       (deployer, N + 2)
///        3. mine the hook salt against (poolManager, reservedLauncher, reservedVault)
///        4. deploy ReferralVault(reservedLauncher, minedHook, treasury, tiers)   -> nonce N
///        5. deploy FeeHook{salt}(poolManager, reservedLauncher, reservedVault)   -> nonce N+1
///        6. deploy Launcher(poolManager, hook, registry, tokenImpl)              -> nonce N+2
///        7. launcher.initReferralVault(vault)
///
///      Every one of steps 4/5/6 asserts it landed on the address that was reserved for it.
///
///      **NOTHING MAY CONSUME A NONCE BETWEEN STEPS 4 AND 6.** Not a log, not a balance top-up,
///      not a registry approval, not a second terminal. That is why the pair approvals all happen
///      in a separate phase AFTER the launcher exists, and why the runbook insists on a dedicated
///      deployer key that does nothing else.
///
///      ## Why `HOOK_NONCE_STEP` is 1 and not 0
///
///      `new C{salt: s}(...)` under `vm.startBroadcast` is not an EVM CREATE2 executed by this
///      script - forge rewrites it into a transaction from the deployer EOA to the deterministic
///      CREATE2 factory at `Addresses.CREATE2_DEPLOYER`. That transaction is a normal transaction
///      and it **advances the EOA's nonce like any other**.
///
///      This is stated as a fact rather than a guess because `DeployTestnet.s.sol:92` uses
///      `getNonce(deployer) + 1` with exactly one CREATE2 between the nonce read and the launcher
///      deploy, its `require(address(launcher) == predictedLauncher)` passed, and that deployment
///      is live on Sepolia. One CREATE2 in the gap == one nonce. The comment above that line
///      ("CREATE2 does not touch the EOA's nonce") describes the mechanism incorrectly while
///      arriving at the correct offset.
///
///      **The failure mode is safe.** `forge script` simulates the entire script against forked
///      head state and only broadcasts if the simulation succeeds end to end. If this nonce model
///      is wrong, the `reservedVault` assertion fails in simulation and **zero transactions are
///      sent** - not a half-deploy. Run the dry run and read the assertions; that is the proof.
///
///      ## What is reversible and what is not
///
///      Permanent from the moment it is mined: the hook's address, its `launcher`, its
///      `platformRecipient`, the vault's `launcher`/`feeHook`/`treasury`/tier schedule, the
///      launcher's `feeHook`/`pairRegistry`/`tokenImplementation`, and `initReferralVault` (one
///      shot, deployer only). **Only the pair allowlist is revocable** - `revokePair` exists and
///      `renounceOwnership` is disabled on `PairRegistry` - and even that only stops NEW launches;
///      pools already open against a revoked pair keep trading forever.
///
///      Dry run (NEVER add `--broadcast` casually, and see README-DEPLOY.md):
///        forge script script/DeployMainnet.s.sol:DeployMainnet --rpc-url mainnet
contract DeployMainnet is Script {
    // ===========================================================================================
    // Constants
    // ===========================================================================================

    /// @notice The Sepolia deployer, whose private key was pasted into a chat and is therefore
    ///         permanently public. Hardcoded so it can never be used here by accident.
    /// @dev Verified 2026 on mainnet: nonce 0, balance 0 - it has never transacted on L1 and it
    ///      never will. Anyone reading this repo's history can spend anything sent to it.
    address internal constant COMPROMISED_DEPLOYER = 0xc286b1956c7691d678520e370727D8aB57328556;

    /// @notice `BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA
    ///         | AFTER_SWAP_RETURNS_DELTA` = 0x20CC.
    /// @dev NOT the 0x2044 that every other launchpad hook uses. Paying dividends strictly in the
    ///      pair currency forces the two extra `beforeSwap` flags: `afterSwap` can only move the
    ///      UNSPECIFIED currency, and on an exact-input buy the pair currency is the SPECIFIED
    ///      one. If these bits drift, the PoolManager silently stops calling the callbacks the
    ///      fee depends on and the protocol's revenue quietly becomes zero.
    uint16 internal constant EXPECTED_HOOK_BITS = 0x20CC;

    /// @dev Nonce offsets inside the reserved block. See the contract docstring for why the hook
    ///      costs a nonce despite being a CREATE2.
    uint256 internal constant VAULT_NONCE_STEP = 0;
    uint256 internal constant HOOK_NONCE_STEP = 1;
    uint256 internal constant LAUNCHER_NONCE_STEP = 2;

    /// @dev 3 hours against mainnet ETH/USD's ~1 hour heartbeat. Never set `maxStaleness` EQUAL
    ///      to a heartbeat or the feed reads as stale intermittently. `PairRegistry.MIN_STALENESS`
    ///      is 1 hour and `MAX_STALENESS` is 7 days, so this is comfortably inside both.
    uint32 internal constant ETH_USD_STALENESS = 3 hours;

    /// @dev The referral schedule: 20 / 10 / 5 / 3 / 2 percent of the platform's cut, five deep.
    ///      40% total, so the treasury keeps 60% even on a fully populated referral chain. Fixed
    ///      in the vault's bytecode at construction and unextendable afterwards.
    uint16 internal constant TIER_0 = 2000;
    uint16 internal constant TIER_1 = 1000;
    uint16 internal constant TIER_2 = 500;
    uint16 internal constant TIER_3 = 300;
    uint16 internal constant TIER_4 = 200;

    /// @notice A real, deliberately-EXCLUDED mainnet token, used as a negative control.
    /// @dev PEPE is in `app/src/lib/pairs.ts` and is NOT in the seed list below, because its
    ///      measured hop-1 cost is 190.2 bps. Asserting `isApproved(PEPE) == false` is what makes
    ///      the eleven `isApproved(...) == true` assertions mean anything: without it, a build
    ///      where `isApproved` returned `true` unconditionally would pass every positive check.
    address internal constant NEGATIVE_CONTROL_PEPE = 0x6982508145454Ce325dDbE47a25d4ec3d2311933;

    // ===========================================================================================
    // Pair seeding
    // ===========================================================================================

    /// @dev One approved pair currency, with the evidence for why it is on the list.
    struct SeedPair {
        address token;
        uint8 decimals;
        string symbol;
        string reason;
    }

    /// @notice The mainnet pair allowlist. **Eleven of the thirty-eight** currencies the app knows
    ///         about, and the eleven are not an opinion.
    ///
    /// @dev SELECTION RULE, applied mechanically: a pair ships only if `app/pairDepth.ts` measured
    ///      a **Uniswap v4** ETH -> pair route costing under 100 bps on a 1 ETH buy. That table is
    ///      `app/src/lib/ethRoute.ts`, simulated against the real mainnet V4Quoter
    ///      `0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203` at block 25,898,753 and cross-checked two
    ///      ways (a local SqrtPriceMath recomputation, exact to the wei 3/3, and the same trade
    ///      quoted on v3, 3/3 within 0.24%).
    ///
    ///      Why v4 specifically: `ZapRouter` routes ETH -> PAIR -> TOKEN and hop 1 must be a v4
    ///      pool. **v2 and v3 liquidity is unreachable from the v4 singleton.** "PEPE has $26.8M of
    ///      depth on Ethereum" is true and says nothing about whether a buyer can pay in ETH.
    ///
    ///      DELIBERATELY ABSENT, and absent rather than quietly substituted, because silent
    ///      trimming is banned in this codebase:
    ///        - APE (196.3 bps), PEPE (190.2), SPX (477.7) - a v4 ETH pool EXISTS but the cost is
    ///          real. Routable, not shippable at launch. Revisit with a fresh measurement.
    ///        - the other 24 (tBTC, LBTC, ENA, WLFI, ELON, FLOKI, Mog, NPC, SHIB, BITCOIN, ANDY,
    ///          APU, WOJAK, PORK, WOLF, ANIME, WXMR, WXRP, USD1, USDY, USDf, WHITE, MNT, TRX) -
    ///          no v4 ETH pool was found by a fixed-keyspace scan of the four canonical
    ///          `(fee, tickSpacing)` pairs. That means "not found by that method", NOT "provably
    ///          does not exist": depth behind a hook or at a non-standard spacing is invisible to
    ///          it. Any of these can be added later with one `approvePair` call and a fresh
    ///          measurement. **Adding a pair is cheap; the immutables above are not.**
    ///
    ///      DECIMALS ARE NOT ALL 18 and `approvePair`/`approvePairWithoutOracle` take
    ///      `tokenDecimals` as a PARAMETER despite the docstring at `PairRegistry.sol:103`
    ///      claiming they are read from the contract. USDC, USDT and XAUT are 6; WBTC is 8. Every
    ///      value below was read from the deployed contract with `cast call decimals()` against
    ///      `https://eth.drpc.org`, and `VerifyDeployment` re-reads each one and compares.
    function _seedPairs() internal pure returns (SeedPair[] memory pairs) {
        pairs = new SeedPair[](11);

        // --- Deepest, and the default -----------------------------------------------------------
        pairs[0] = SeedPair({
            token: Addresses.MAINNET_WETH9,
            decimals: 18,
            symbol: "WETH",
            reason: "6.3 bps hop-1 (500 tier). $304M depth. No admin powers at all. THE DEFAULT PAIR."
        });
        pairs[1] = SeedPair({
            token: 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599,
            decimals: 8,
            symbol: "WBTC",
            reason: "6.6 bps hop-1 (500). $186M depth. 8 DECIMALS. BitGo custodial: pause+mint+owner."
        });
        pairs[2] = SeedPair({
            token: Addresses.MAINNET_USDC,
            decimals: 6,
            symbol: "USDC",
            reason: "6.7 bps hop-1 (500). 6 DECIMALS. Circle can pause AND blacklist - accepted, disclosed."
        });
        pairs[3] = SeedPair({
            token: 0xdAC17F958D2ee523a2206206994597C13D831ec7,
            decimals: 6,
            symbol: "USDT",
            reason: "8.1 bps hop-1 (500). 6 DECIMALS. Tether can pause AND blacklist - accepted, disclosed."
        });

        // --- Blue-chip ecosystem ----------------------------------------------------------------
        pairs[4] = SeedPair({
            token: 0x514910771AF9Ca656af840dff83E8264EcF986CA,
            decimals: 18,
            symbol: "LINK",
            reason: "35.0 bps hop-1 (3000). $13.2M depth. Fixed 1B supply, ZERO admin powers in bytecode."
        });
        pairs[5] = SeedPair({
            token: 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9,
            decimals: 18,
            symbol: "AAVE",
            reason: "36.7 bps hop-1 (3000). $4.7M depth. Upgradeable - today's audit does not bind tomorrow."
        });
        pairs[6] = SeedPair({
            token: 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984,
            decimals: 18,
            symbol: "UNI",
            reason: "38.1 bps hop-1 (3000). $18.3M depth. Mintable by governance."
        });
        pairs[7] = SeedPair({
            token: 0xD533a949740bb3306d119CC777fa900bA034cd52,
            decimals: 18,
            symbol: "CRV",
            reason: "89.6 bps hop-1 (3000). $1.2M depth - moderate. Mintable."
        });

        // --- Real-world assets. The Ethereum answer to stock-paired pads, with no Reg S exposure.
        pairs[8] = SeedPair({
            token: 0x68749665FF8D2d112Fa859AA293F07A622782F38,
            decimals: 6,
            symbol: "XAUT",
            reason: "41.3 bps hop-1 (3000). Tether Gold, 6 DECIMALS. Upgradeable+mintable+owner."
        });
        pairs[9] = SeedPair({
            token: 0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3,
            decimals: 18,
            symbol: "ONDO",
            reason: "59.1 bps hop-1 (3000). Hop 1 is fine but TOTAL depth is only $318K - thin for dividends."
        });
        pairs[10] = SeedPair({
            token: 0x45804880De22913dAFE09f4980848ECE6EcbAf78,
            decimals: 18,
            symbol: "PAXG",
            reason: "96.7 bps hop-1 (3000) - NEAR THE 100 bps THRESHOLD, re-measure before trusting it."
        });
    }

    // ===========================================================================================
    // Entry point
    // ===========================================================================================

    function run() external {
        // --- Rail 1: the wrong chain --------------------------------------------------------
        require(block.chainid == Addresses.MAINNET_CHAIN_ID, "DeployMainnet: Ethereum mainnet only");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // --- Rail 2: the permanently public key ---------------------------------------------
        require(
            deployer != COMPROMISED_DEPLOYER,
            "DeployMainnet: that is the Sepolia key whose private key is PUBLIC. Generate a fresh one - see script/README-DEPLOY.md"
        );

        address treasury = vm.envAddress("TREASURY");
        require(treasury != address(0), "DeployMainnet: TREASURY is the zero address");
        require(
            treasury != COMPROMISED_DEPLOYER, "DeployMainnet: TREASURY is the compromised Sepolia address"
        );
        // The treasury is IMMUTABLE on the vault. A hot deploy key is the wrong thing to make
        // permanent, and pointing it at the deployer is exactly the shape of the A-8 mistake.
        require(
            treasury != deployer,
            "DeployMainnet: TREASURY must not be the deploy key - it is immutable on the vault. Use a multisig."
        );
        // A Safe has code; a fresh EOA does not. Allowed, but only on purpose.
        if (treasury.code.length == 0) {
            require(
                _envIsYes("ALLOW_EOA_TREASURY"),
                "DeployMainnet: TREASURY has no code (it is an EOA). Set ALLOW_EOA_TREASURY=yes to accept that."
            );
        }

        // --- Rail 3: the PoolManager is a claim until eth_getCode says otherwise -------------
        // Re-checked here rather than trusted from `Addresses.sol` because a constant in a file
        // is a claim about the chain, and this script is the last place that can catch it being
        // wrong. Confirmed 2026 over https://eth.drpc.org: 24,009 bytes, and `owner()` answers
        // with the Uniswap governance timelock 0x1a9C8182C09F50C8318d769245beA52c32BE35BC.
        require(
            Addresses.MAINNET_POOL_MANAGER.code.length > 0,
            "DeployMainnet: no code at the mainnet PoolManager address"
        );
        require(
            Addresses.CREATE2_DEPLOYER.code.length > 0,
            "DeployMainnet: no code at the deterministic CREATE2 deployer - the hook cannot be mined"
        );
        require(
            Addresses.MAINNET_ETH_USD_FEED.code.length > 0,
            "DeployMainnet: no code at the Chainlink ETH/USD feed"
        );

        // --- Rail 4: enough gas to finish ----------------------------------------------------
        // A run that dies between the vault and the launcher leaves a mined hook pointing at an
        // address that will never hold a launcher. Recovery is a full redeploy. Rough cost of the
        // whole script is ~14.5M gas; the default floor covers ~10 gwei with headroom. Override
        // with MIN_DEPLOYER_BALANCE (wei) when gas is cheap or expensive.
        uint256 minBalance = vm.envOr("MIN_DEPLOYER_BALANCE", uint256(0.15 ether));
        require(
            deployer.balance >= minBalance,
            "DeployMainnet: deployer balance below MIN_DEPLOYER_BALANCE - a half-finished deploy is unrecoverable"
        );

        SeedPair[] memory pairs = _seedPairs();

        _preflight(deployer, treasury, minBalance, pairs);

        // --- Rail 5: explicit confirmation ---------------------------------------------------
        // Deliberately AFTER the summary, so running without it prints the whole plan and then
        // refuses, rather than refusing before you can read anything.
        require(
            _envIsYes("CONFIRM_MAINNET"),
            "DeployMainnet: read the summary above, then re-run with CONFIRM_MAINNET=yes"
        );

        _deploy(pk, deployer, treasury, pairs);
    }

    // ===========================================================================================
    // Pre-flight
    // ===========================================================================================

    function _preflight(
        address deployer,
        address treasury,
        uint256 minBalance,
        SeedPair[] memory pairs
    ) internal view {
        console.log("");
        console.log("================================================================");
        console.log("   hoodstonk :: ETHEREUM MAINNET DEPLOY :: PRE-FLIGHT");
        console.log("================================================================");
        console.log("chain id              ", block.chainid);
        console.log("deployer              ", deployer);
        console.log("deployer balance (wei)", deployer.balance);
        console.log("required minimum (wei)", minBalance);
        console.log("deployer nonce        ", vm.getNonce(deployer));
        console.log("");
        console.log("--- permanent, immutable, unfixable after this run ---");
        console.log("treasury (vault)      ", treasury);
        console.log("  has code            ", treasury.code.length > 0);
        console.log("PoolManager v4        ", Addresses.MAINNET_POOL_MANAGER);
        console.log("  code bytes          ", Addresses.MAINNET_POOL_MANAGER.code.length);
        console.log("CREATE2 deployer      ", Addresses.CREATE2_DEPLOYER);
        console.log("hook permission bits  ", "0x20CC (BEFORE_INIT|BEFORE_SWAP|AFTER_SWAP|both RETURNS_DELTA)");
        console.log("referral tiers (bps)  ", "2000 / 1000 / 500 / 300 / 200  = 40% of the platform cut");
        console.log("");
        console.log("--- pair allowlist (revocable later; everything above is not) ---");
        for (uint256 i = 0; i < pairs.length; i++) {
            console.log(
                string.concat(
                    "  ",
                    pairs[i].symbol,
                    "  ",
                    vm.toString(pairs[i].token),
                    "  dec=",
                    vm.toString(uint256(pairs[i].decimals))
                )
            );
            console.log(string.concat("      ", pairs[i].reason));
        }
        console.log("");
        console.log("  EXCLUDED on purpose: APE / PEPE / SPX (v4 ETH route exists but costs");
        console.log("  190-478 bps) and 24 others with no v4 ETH pool found. Absent, never");
        console.log("  silently substituted. Adding one later is a single approvePair call.");
        console.log("");
        console.log("--- what this run CANNOT undo ---");
        console.log("  FeeHook.platformRecipient, FeeHook.launcher, ReferralVault.feeHook,");
        console.log("  ReferralVault.launcher, ReferralVault.treasury, the tier schedule,");
        console.log("  Launcher.feeHook / .pairRegistry / .tokenImplementation, and");
        console.log("  initReferralVault (one shot, deployer only).");
        console.log("================================================================");
        console.log("");
    }

    // ===========================================================================================
    // Deploy
    // ===========================================================================================

    function _deploy(uint256 pk, address deployer, address treasury, SeedPair[] memory pairs)
        internal
    {
        vm.startBroadcast(pk);

        // -------------------------------------------------------------------------------------
        // PHASE A - nonce-irrelevant. Anything here may consume any number of nonces, because
        // the reserved block below reads the nonce fresh afterwards.
        // -------------------------------------------------------------------------------------
        PairRegistry registry = new PairRegistry(deployer);
        LaunchToken tokenImpl = new LaunchToken();

        // -------------------------------------------------------------------------------------
        // PHASE B - THE RESERVED BLOCK. NOTHING MAY CONSUME A NONCE INSIDE THIS.
        //
        // No approvals, no top-ups, no extra deploys, no second terminal using this key. Each of
        // the three deploys asserts it landed where it was reserved, so a violation fails the
        // simulation and sends nothing rather than producing a silently-orphaned hook.
        // -------------------------------------------------------------------------------------
        uint256 n = vm.getNonce(deployer);

        address reservedVault = vm.computeCreateAddress(deployer, n + VAULT_NONCE_STEP);
        address reservedLauncher = vm.computeCreateAddress(deployer, n + LAUNCHER_NONCE_STEP);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // The salt is mined against the EXACT constructor encoding used by `new FeeHook` below.
        // A missing or reordered argument here mines a salt for a different contract and the
        // address assertion catches it - but only after the gas is spent, so keep them adjacent.
        //
        // `reservedVault` is the third argument, and that is the whole fix: `platformRecipient`
        // becomes the ReferralVault instead of an EOA, at the moment the address is mined.
        (address hookAddr, bytes32 salt) = HookMiner.find(
            Addresses.CREATE2_DEPLOYER,
            flags,
            type(FeeHook).creationCode,
            abi.encode(Addresses.MAINNET_POOL_MANAGER, reservedLauncher, reservedVault)
        );

        // --- B.1  vault, at nonce n. Knows the hook because the hook was MINED, not deployed. ---
        ReferralVault vault =
            new ReferralVault(reservedLauncher, hookAddr, treasury, _tierSchedule());
        require(
            address(vault) == reservedVault,
            "DeployMainnet: vault missed its reserved address - the nonce model is wrong, NOTHING was broadcast"
        );

        // --- B.2  hook, at nonce n+1 (CREATE2 via the factory is still a transaction) ---------
        FeeHook feeHook = new FeeHook{salt: salt}(
            IPoolManager(Addresses.MAINNET_POOL_MANAGER), reservedLauncher, reservedVault
        );
        require(address(feeHook) == hookAddr, "DeployMainnet: hook did not land on the mined address");

        // --- B.3  launcher, at nonce n+2 -----------------------------------------------------
        require(
            vm.getNonce(deployer) == n + LAUNCHER_NONCE_STEP,
            "DeployMainnet: a nonce was consumed inside the reserved block"
        );
        Launcher launcher = new Launcher(
            IPoolManager(Addresses.MAINNET_POOL_MANAGER), feeHook, registry, address(tokenImpl)
        );
        require(
            address(launcher) == reservedLauncher,
            "DeployMainnet: launcher missed its reserved address"
        );

        // -------------------------------------------------------------------------------------
        // PHASE C - wiring and the allowlist. Nonces are free again from here.
        // -------------------------------------------------------------------------------------

        // One shot, deployer only. Guarded so a re-run against a partially-wired launcher does
        // not provoke `ReferralVaultAlreadySet` - forge aborts a broadcast if ANY call in the
        // trace reverts, even one that would be logically harmless.
        if (launcher.referralVault() == address(0)) {
            launcher.initReferralVault(address(vault));
        }

        _approvePairs(registry, pairs);

        vm.stopBroadcast();

        _report(deployer, treasury, registry, tokenImpl, feeHook, launcher, vault, salt, pairs);
        _assertDeployment(registry, feeHook, launcher, vault, treasury, deployer, pairs);
    }

    function _tierSchedule() internal pure returns (uint16[] memory tiers) {
        tiers = new uint16[](5);
        tiers[0] = TIER_0;
        tiers[1] = TIER_1;
        tiers[2] = TIER_2;
        tiers[3] = TIER_3;
        tiers[4] = TIER_4;
    }

    /// @dev Idempotent: skips anything already approved, because deploy scripts get re-run and a
    ///      revert anywhere in the trace aborts the whole broadcast.
    ///
    ///      WETH is the ONLY pair that goes through `approvePair` with a Chainlink feed. Every
    ///      other one uses `approvePairWithoutOracle`. That is not laziness - it is the rule this
    ///      codebase already follows: a dollar figure is shown only where a feed ADDRESS has been
    ///      verified in this repo. USDC, LINK, AAVE, CRV and UNI all have a DIRECT Chainlink
    ///      USD feed on L1, but none of those proxy addresses is verified here, and
    ///      `approvePair` with a wrong or wrongly-decimalled feed misprices a pair silently.
    ///      Registering unpriced is the honest default and is a one-call upgrade later.
    function _approvePairs(PairRegistry registry, SeedPair[] memory pairs) internal {
        for (uint256 i = 0; i < pairs.length; i++) {
            if (registry.isApproved(pairs[i].token)) continue;

            if (pairs[i].token == Addresses.MAINNET_WETH9) {
                registry.approvePair(
                    Addresses.MAINNET_WETH9,
                    Addresses.MAINNET_ETH_USD_FEED,
                    ETH_USD_STALENESS,
                    pairs[i].decimals
                );
            } else {
                registry.approvePairWithoutOracle(pairs[i].token, pairs[i].decimals);
            }
        }
    }

    // ===========================================================================================
    // Report + post-deploy assertions
    // ===========================================================================================

    function _report(
        address deployer,
        address treasury,
        PairRegistry registry,
        LaunchToken tokenImpl,
        FeeHook feeHook,
        Launcher launcher,
        ReferralVault vault,
        bytes32 salt,
        SeedPair[] memory pairs
    ) internal view {
        console.log("");
        console.log("=== hoodstonk :: Ethereum mainnet ===");
        console.log("deployer          ", deployer);
        console.log("treasury          ", treasury);
        console.log("PoolManager (v4)  ", Addresses.MAINNET_POOL_MANAGER);
        console.log("--- stack ---");
        console.log("PairRegistry      ", address(registry));
        console.log("LaunchToken impl  ", address(tokenImpl));
        console.log("ReferralVault     ", address(vault));
        console.log("FeeHook           ", address(feeHook));
        console.log("Launcher          ", address(launcher));
        console.log("--- hook provenance (keep this, Etherscan verification needs it) ---");
        console.log("hook salt         ", vm.toString(salt));
        console.log("hook low 14 bits  ", uint256(uint160(address(feeHook)) & 0x3FFF), "(decimal; must equal 8396 = 0x20CC)");
        console.log("--- approved pairs ---");
        for (uint256 i = 0; i < pairs.length; i++) {
            console.log(string.concat("  ", pairs[i].symbol, "  ", vm.toString(pairs[i].token)));
        }
        console.log("");
        console.log("NEXT: run script/VerifyDeployment.s.sol against these addresses, then diff");
        console.log("      the deployed bytecode against src/. See script/README-DEPLOY.md.");
    }

    /// @dev A script that only logs has verified nothing. These are staticcalls made after
    ///      `stopBroadcast`, so none of them is broadcast.
    function _assertDeployment(
        PairRegistry registry,
        FeeHook feeHook,
        Launcher launcher,
        ReferralVault vault,
        address treasury,
        address deployer,
        SeedPair[] memory pairs
    ) internal view {
        // The hook's address IS its API.
        require(
            uint160(address(feeHook)) & 0x3FFF == EXPECTED_HOOK_BITS,
            "DeployMainnet: hook address must encode 0x20CC"
        );

        // The circularity, checked from every end rather than assumed.
        require(feeHook.launcher() == address(launcher), "DeployMainnet: hook -> launcher wrong");
        require(
            address(launcher.feeHook()) == address(feeHook), "DeployMainnet: launcher -> hook wrong"
        );

        // *** THE A-8 REGRESSION GUARD. This is the check DeployTestnet never had. ***
        require(
            feeHook.platformRecipient() == address(vault),
            "DeployMainnet: A-8 REGRESSION - platformRecipient is not the ReferralVault, referrals can never be paid"
        );
        // And the mirror of it, which the brief did not ask for but which fails identically:
        // ReferralVault.feeHook is immutable and `credit` is onlyFeeHook.
        require(
            vault.feeHook() == address(feeHook),
            "DeployMainnet: A-8 MIRROR - vault does not point at the hook, credit() is unreachable"
        );
        require(vault.launcher() == address(launcher), "DeployMainnet: vault -> launcher wrong");
        require(vault.treasury() == treasury, "DeployMainnet: vault treasury wrong");
        require(vault.tierCount() == 5, "DeployMainnet: referral schedule did not take");
        require(launcher.referralVault() == address(vault), "DeployMainnet: launcher -> vault wrong");

        require(
            address(launcher.pairRegistry()) == address(registry), "DeployMainnet: launcher registry wrong"
        );
        require(launcher.launchCount() == 0, "DeployMainnet: a fresh launcher must have no launches");

        require(registry.owner() == deployer, "DeployMainnet: registry owner is not the deployer");
        require(registry.owner() != address(0), "DeployMainnet: registry owner is the zero address");
        require(
            registry.sequencerUptimeFeed() == address(0),
            "DeployMainnet: L1 has no sequencer uptime feed, this must stay unset"
        );

        for (uint256 i = 0; i < pairs.length; i++) {
            require(registry.isApproved(pairs[i].token), "DeployMainnet: a seeded pair is not approved");
        }
        require(registry.pairCount() == pairs.length, "DeployMainnet: registry holds pairs we did not seed");
        require(registry.isPriceable(Addresses.MAINNET_WETH9), "DeployMainnet: WETH must be priceable");

        // Negative control. Without it, "returns true" proves nothing about whether the call
        // reads what it claims to read.
        require(
            !registry.isApproved(NEGATIVE_CONTROL_PEPE),
            "DeployMainnet: NEGATIVE CONTROL FAILED - PEPE reads as approved and it was never added"
        );

        console.log("--- all post-deploy checks passed, negative control included ---");
    }

    // ===========================================================================================
    // Helpers
    // ===========================================================================================

    /// @dev `vm.envOr` with a string default, compared by hash. An unset variable is not "yes".
    function _envIsYes(string memory key) internal view returns (bool) {
        return keccak256(bytes(vm.envOr(key, string("")))) == keccak256(bytes("yes"));
    }
}
