// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PairRegistry} from "../src/PairRegistry.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {Launcher} from "../src/Launcher.sol";
import {ReferralVault} from "../src/ReferralVault.sol";
import {Addresses} from "./Addresses.sol";

/// @title DeployRobinhood
///
/// @notice The same four contracts as `DeployMainnet`, on Robinhood Chain (4663).
///
/// @dev **Nothing in `src/` changes to run here, and that was verified rather than assumed.**
///      There is not one `block.chainid`, hard-coded PoolManager, or network constant anywhere in
///      `src/`; every dependency arrives through a constructor argument. This file is the whole
///      port.
///
///      **Four differences from `DeployMainnet`, each with a reason.**
///
///      1. **A different PoolManager, and it cannot be assumed.** The canonical L1 address
///         `0x000000000004444c5dc75cB358380D2e3dE08A90` returns ZERO BYTES on this chain. A script
///         that reached for it would deploy a hook wired to nothing and only find out on the first
///         swap. The real one is 24,009 bytes - the exact size Uniswap ships.
///
///      2. **No USD oracle, so every pair is UNPRICEABLE.** No Chainlink aggregator has been
///         located on 4663. This is a supported mode rather than a degraded one: the UNPRICEABLE
///         tier exists because WXMR on L1 is liquid and unfeedable, and it quotes openings in
///         units of the pair asset instead of dollars. `Addresses.hasUsdFeed(4663)` returns false
///         and this script asserts on it, so if a feed is ever added the two cannot drift apart.
///
///      3. **No ZapRouter.** `ZapRouter` wraps and unwraps native ether through a WETH9. The
///         contract with 533,961 holders that answers `symbol() == "WETH"` on this chain exposes
///         neither `deposit()` nor `withdraw(uint256)`, and neither do the four other WETH-named
///         contracts. Deploying a router against a bridged ERC-20 produces one that reverts on
///         every zap, which is worse than not shipping it. Buyers source the pair currency
///         directly until a real wrapper exists.
///
///      4. **Pairs are passed in, never hard-coded here.** See `_seedPairs`.
///
///      Run:
///        forge script script/DeployRobinhood.s.sol:DeployRobinhood --rpc-url $ROBINHOOD_RPC_URL
///        (add --broadcast once the summary prints and you have set CONFIRM_ROBINHOOD=yes)
contract DeployRobinhood is Script {
    /// @dev The Sepolia deployer whose private key is PUBLIC. Blocked by address here for the same
    ///      reason `DeployMainnet` blocks it: anything it signs on a live chain is a donation.
    address internal constant COMPROMISED_DEPLOYER = 0xc286b1956c7691d678520e370727D8aB57328556;

    /// @dev Referral tier schedule, in bps of the platform's cut. Mirrors mainnet.
    function _tierSchedule() internal pure returns (uint16[] memory tiers) {
        tiers = new uint16[](5);
        tiers[0] = 3000;
        tiers[1] = 2000;
        tiers[2] = 1500;
        tiers[3] = 1000;
        tiers[4] = 500;
    }

    struct SeedPair {
        address token;
        uint8 decimals;
        string symbol;
        string reason;
    }

    /// @notice The pair allowlist for this chain. **Deliberately empty until addresses are
    ///         supplied and verified.**
    ///
    /// @dev **A symbol identifies nothing on this chain, so none are hard-coded from a name.**
    ///      Measured on 4663: three separate contracts answer `symbol() == "USDG"` with 279k, 173k
    ///      and 169k holders. Five answer `WETH` or `wETH`. Four answer `XMR` or `Monero`, with
    ///      supplies of 92, 100M, 1B and 100B against real Monero's 18.4M - and real Monero has no
    ///      contract at all, being a separate chain with no EVM. `PairRegistry`'s own docstring
    ///      records 361 contracts using `GME` and 416 using another ticker, exactly one of each
    ///      being real.
    ///
    ///      That is why `PairRegistry` is an address allowlist with no symbol-based entry point,
    ///      and why this function returns nothing by default. Fill it from
    ///      `VerifyRobinhoodPairs.s.sol`, which reads `name`, `symbol`, `decimals`, `totalSupply`
    ///      and code size for a candidate and prints a line ready to paste here.
    ///
    ///      **DECIMALS ARE NOT ALL 18.** USDG is 6. `approvePairWithoutOracle` takes the token's
    ///      decimals and a wrong value misprices every launch against that pair by a power of ten.
    function _seedPairs() internal pure returns (SeedPair[] memory pairs) {
        pairs = new SeedPair[](11);

        // Every address below was resolved on-chain (name, symbol, decimals, code size) and its
        // market read from DexScreener before being written down. Symbols identify nothing on this
        // chain; the addresses are the facts. `_approvePairs` re-reads decimals from the token at
        // deploy time and reverts on a mismatch, so a typo here cannot misprice a launch.

        // --- Core --------------------------------------------------------------------------------
        pairs[0] = SeedPair({
            token: Addresses.ROBINHOOD_WETH,
            decimals: 18,
            symbol: "WETH",
            reason: "Bridged ERC-20, 533,961 holders. Deepest quote asset. NOT a WETH9: no zap."
        });
        pairs[1] = SeedPair({
            token: Addresses.ROBINHOOD_USDG,
            decimals: 6, // SIX. Not 18. Verified on-chain; two impostors share the symbol.
            symbol: "USDG",
            reason: "Global Dollar, 279,018 holders. RhPairRegistry.usdg() confirms this address."
        });

        // --- Commodities / wrapped assets --------------------------------------------------------
        pairs[2] = SeedPair({
            token: 0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4,
            decimals: 8, // canonical cbBTC decimals, verified on-chain
            symbol: "cbBTC",
            reason: "Coinbase Wrapped BTC, 29.5 BTC supply. $1.45M USDG + $581k WETH pools. Owner exists (bridge)."
        });
        pairs[3] = SeedPair({
            token: 0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f,
            decimals: 18,
            symbol: "SLV",
            reason: "iShares Silver Trust - Robinhood official rail (283 b proxy). $500k+ USDG depth. Metal-in-trust: commodity claim per the pairs.ts gold exception, not an issuer claim."
        });
        pairs[4] = SeedPair({
            token: 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e,
            decimals: 18,
            symbol: "GLD",
            reason: "SPDR Gold Trust - Robinhood official rail. $280k depth across GG/SLV pools. Same commodity-claim reasoning as SLV."
        });
        pairs[5] = SeedPair({
            token: 0xc700C81925D1d1C10F996fA7c0Dee83a54C4Bb8D,
            decimals: 18,
            symbol: "PAXG",
            reason: "Paxos Gold, real name/decimals BUT supply 0.488 and $452 liquidity at admission time. Admitted on the operator's explicit instruction; a launch against it has NO market until depth arrives."
        });

        // --- RobinVista synths: USDG-collateralised, 1x perp-hedged via Hyperliquid --------------
        // Peg = operator hedge + venue solvency; source unverified; operator EOA can pause. The
        // reward-conversion path degrades to paying the PAIR on failure (tested in
        // RewardCurrency.t.sol), which is what makes these acceptable as REWARD assets.
        pairs[6] = SeedPair({
            token: 0x38F728351fd9565087a4fF0ad5049739e0Ce235c,
            decimals: 18,
            symbol: "XMR",
            reason: "Synthetic Monero, Hyperliquid perp mark. $30k XMR/ETH pool. THE narrative asset."
        });
        pairs[7] = SeedPair({
            token: 0xEc127e99Da1a2eD3d6C0433227154a99B7B29221,
            decimals: 18,
            symbol: "ZEC",
            reason: "Synthetic Zcash, same RobinVista vault family (18,374 b)."
        });
        pairs[8] = SeedPair({
            token: 0x49F98A382Ccbc05f13b3E3aB323D04aBA975642D,
            decimals: 18,
            symbol: "SOL",
            reason: "Synthetic Solana, same vault family, Lighter perp mark."
        });

        // --- Community, admitted on operator instruction -----------------------------------------
        pairs[9] = SeedPair({
            token: 0x12D5ee7917cA430073C3A638ee1e6f0648A98a01,
            decimals: 18,
            symbol: "FATCOIN",
            reason: "Memecoin, $306k combined liq, real volume. Community pair, not a store of value."
        });
        pairs[10] = SeedPair({
            token: 0xe2324FF2a59F8eCBa8c321c6466e59121C00e795,
            decimals: 18,
            symbol: "CME",
            reason: "'Commodity Market Exchange' memecoin, $309k liq, $11M vol. Community pair."
        });
    }

    function run() external {
        // --- Rail 1: the wrong chain --------------------------------------------------------
        require(
            block.chainid == Addresses.ROBINHOOD_CHAIN_ID, "DeployRobinhood: Robinhood Chain (4663) only"
        );

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // --- Rail 2: the permanently public key ---------------------------------------------
        require(
            deployer != COMPROMISED_DEPLOYER,
            "DeployRobinhood: that is the Sepolia key whose private key is PUBLIC. Generate a fresh one."
        );

        address treasury = vm.envAddress("TREASURY");
        require(treasury != address(0), "DeployRobinhood: TREASURY is the zero address");
        // Immutable on the vault. A hot deploy key is the wrong thing to make permanent, and
        // pointing it at the deployer is the shape of the A-8 mistake.
        require(
            treasury != deployer,
            "DeployRobinhood: TREASURY must not be the deploy key - it is immutable on the vault"
        );
        require(treasury != COMPROMISED_DEPLOYER, "DeployRobinhood: TREASURY is the compromised address");

        // --- Rail 3: the chain is a claim until eth_getCode says otherwise -------------------
        // A constant in a file is a claim about a chain. This is the last place that can catch it
        // being wrong, and on THIS chain it matters more than most: the canonical L1 PoolManager
        // address is empty here, so a copy-paste from the mainnet script fails silently.
        require(
            Addresses.ROBINHOOD_POOL_MANAGER.code.length > 0,
            "DeployRobinhood: no code at the Robinhood PoolManager - check the address, it is NOT the L1 one"
        );
        require(
            Addresses.CREATE2_DEPLOYER.code.length > 0,
            "DeployRobinhood: no code at the deterministic CREATE2 deployer - the hook cannot be mined"
        );

        // --- Rail 4: pricing mode must match what the chain actually offers ------------------
        // Asserted rather than assumed so `Addresses.hasUsdFeed` and this script cannot drift.
        require(
            !Addresses.hasUsdFeed(Addresses.ROBINHOOD_CHAIN_ID),
            "DeployRobinhood: hasUsdFeed(4663) is now true - set the feed and use approvePair for it"
        );

        uint256 minBalance = vm.envOr("MIN_DEPLOYER_BALANCE", uint256(0.02 ether));
        require(
            deployer.balance >= minBalance,
            "DeployRobinhood: deployer balance below MIN_DEPLOYER_BALANCE - a half-finished deploy is unrecoverable"
        );

        SeedPair[] memory pairs = _seedPairs();
        _preflight(deployer, treasury, pairs);

        // --- Rail 5: explicit confirmation, AFTER the summary --------------------------------
        require(
            keccak256(bytes(vm.envOr("CONFIRM_ROBINHOOD", string("")))) == keccak256(bytes("yes")),
            "DeployRobinhood: read the summary above, then re-run with CONFIRM_ROBINHOOD=yes"
        );

        _deploy(pk, deployer, treasury, pairs);
    }

    function _preflight(address deployer, address treasury, SeedPair[] memory pairs) internal view {
        console.log("================================================================");
        console.log("hoodstonk :: Robinhood Chain");
        console.log("chain id              ", block.chainid);
        console.log("deployer              ", deployer);
        console.log("deployer balance (wei)", deployer.balance);
        console.log("deployer nonce        ", vm.getNonce(deployer));
        console.log("treasury (vault)      ", treasury);
        console.log("PoolManager           ", Addresses.ROBINHOOD_POOL_MANAGER);
        console.log("  code bytes          ", Addresses.ROBINHOOD_POOL_MANAGER.code.length);
        console.log("CREATE2 deployer      ", Addresses.CREATE2_DEPLOYER);
        console.log("basefee (wei)         ", block.basefee);
        console.log("");
        console.log("PRICING: no USD oracle on this chain. Every pair is admitted UNPRICEABLE and");
        console.log("         openings are quoted in units of the pair asset, not dollars.");
        console.log("ZAP:     NOT deployed. The WETH here is a bridged ERC-20 with no deposit()/");
        console.log("         withdraw(), so a router built on it would revert on every zap.");
        console.log("");
        console.log("pairs to admit        ", pairs.length);
        for (uint256 i = 0; i < pairs.length; i++) {
            console.log("  ", pairs[i].symbol, pairs[i].token);
            console.log("     decimals", pairs[i].decimals);
            console.log("     ", pairs[i].reason);
        }
        if (pairs.length == 0) {
            console.log("  NONE. The launcher will deploy with an EMPTY allowlist and no launch can");
            console.log("  succeed until a pair is approved. Verify addresses with");
            console.log("  VerifyRobinhoodPairs.s.sol, then fill _seedPairs. This is deliberate: a");
            console.log("  symbol identifies nothing on this chain.");
        }
        console.log("================================================================");
    }

    function _deploy(uint256 pk, address deployer, address treasury, SeedPair[] memory pairs) internal {
        IPoolManager manager = IPoolManager(Addresses.ROBINHOOD_POOL_MANAGER);

        // The three-way circularity, reserved by nonce exactly as A-8 requires: the hook is mined
        // against an address the launcher does not occupy yet, and the vault against one the
        // launcher will take. Getting this wrong is a full redeploy, so both are asserted below.
        //
        // **The CREATE2 hook deploy still burns a deployer nonce.** The hook's ADDRESS comes from
        // CREATE2 and ignores the nonce, but the transaction that asks the Create2Deployer to do
        // it is an ordinary tx from this account. First draft reserved the launcher at n+3 and the
        // live-chain simulation reverted `launcher missed its reserved address` - the create2 tx
        // had consumed n+3 and pushed the launcher to n+4. Sequence: registry n, tokenImpl n+1,
        // vault n+2, create2 tx n+3, launcher n+4.
        uint64 n = uint64(vm.getNonce(deployer));
        address reservedLauncher = vm.computeCreateAddress(deployer, n + 4);

        vm.startBroadcast(pk);

        PairRegistry registry = new PairRegistry(deployer);
        LaunchToken tokenImpl = new LaunchToken();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        address predictedVault = vm.computeCreateAddress(deployer, n + 2);

        (address hookAddr, bytes32 salt) = HookMiner.find(
            Addresses.CREATE2_DEPLOYER,
            flags,
            type(FeeHook).creationCode,
            abi.encode(manager, reservedLauncher, predictedVault)
        );

        ReferralVault vault = new ReferralVault(reservedLauncher, hookAddr, treasury, _tierSchedule());
        require(address(vault) == predictedVault, "DeployRobinhood: vault missed its reserved address");

        FeeHook feeHook = new FeeHook{salt: salt}(manager, reservedLauncher, address(vault));
        require(address(feeHook) == hookAddr, "DeployRobinhood: hook did not land on the mined address");

        Launcher launcher = new Launcher(manager, feeHook, registry, address(tokenImpl));
        require(
            address(launcher) == reservedLauncher, "DeployRobinhood: launcher missed its reserved address"
        );

        _approvePairs(registry, pairs);

        vm.stopBroadcast();

        // --- Post-deploy assertions ---------------------------------------------------------
        require(address(feeHook).code.length != 0, "DeployRobinhood: no code at the hook");
        require(address(launcher).code.length != 0, "DeployRobinhood: no code at the launcher");
        require(address(vault).code.length != 0, "DeployRobinhood: no code at the vault");
        require(
            uint160(address(feeHook)) & 0x3FFF == flags,
            "DeployRobinhood: hook address does not encode the flags"
        );
        require(feeHook.launcher() == address(launcher), "DeployRobinhood: hook -> launcher wrong");
        require(
            address(launcher.feeHook()) == address(feeHook), "DeployRobinhood: launcher -> hook wrong"
        );
        require(
            feeHook.platformRecipient() == address(vault), "DeployRobinhood: hook -> vault wrong"
        );

        console.log("");
        console.log("=== hoodstonk :: Robinhood Chain, deployed ===");
        console.log("PairRegistry  ", address(registry));
        console.log("LaunchToken   ", address(tokenImpl));
        console.log("FeeHook       ", address(feeHook));
        console.log("Launcher      ", address(launcher));
        console.log("ReferralVault ", address(vault));
        console.log("ZapRouter      NOT DEPLOYED - see the note in this file");
        console.log("");
        console.log("--- next: add these to app/src/lib/networks.ts under `robinhood`, then");
        console.log("--- flip ACTIVE_NETWORK once a pair is approved and a launch has been proven.");
    }

    /// @dev Every pair on this chain goes in UNPRICEABLE, because no USD feed has been located.
    ///      `approvePair` is deliberately not reachable from here: reaching for it would require a
    ///      feed address, and a wrong one prices launches off a number nobody checked.
    function _approvePairs(PairRegistry registry, SeedPair[] memory pairs) internal {
        for (uint256 i = 0; i < pairs.length; i++) {
            if (registry.isApproved(pairs[i].token)) continue;

            // Decimals are READ FROM THE TOKEN and checked against the declared value rather than
            // trusted. USDG is 6 where almost everything else is 18, and a mismatch here misprices
            // every launch against the pair by a power of ten.
            uint8 onChain = IERC20Metadata(pairs[i].token).decimals();
            require(onChain == pairs[i].decimals, "DeployRobinhood: declared decimals != on-chain decimals");

            registry.approvePairWithoutOracle(pairs[i].token, pairs[i].decimals);
        }
    }
}
