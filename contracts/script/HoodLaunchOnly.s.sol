// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {Launcher} from "../src/Launcher.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Distributor} from "../src/Distributor.sol";
import {LaunchMetadata} from "../src/types/LaunchMetadata.sol";
import {Addresses} from "./Addresses.sol";

/// @title HoodLaunchOnly
///
/// @notice The first real launch on Robinhood Chain. Launch step only.
///
/// @dev **Why this is split off from the full smoke test.** The complete sequence is
///      launch -> buy -> sweep -> sell -> sweep -> claim, and every step after the first needs the
///      caller to hold PAIR CURRENCY to trade with. The deployer holds native ETH and nothing
///      else, and the WETH on this chain is a bridged ERC-20 with no `deposit()` - there is no way
///      to wrap into it, it has to be bought on a DEX first.
///
///      **The launch itself needs none of that, and that is the property under test.** A launch
///      here is single-sided: the pool opens with launch tokens on one side and nothing on the
///      other, so a creator can open a market without owning a single unit of the asset they price
///      against. This script proves exactly that on live infrastructure, and refuses to pretend it
///      proved anything more.
///
///      What a green run establishes: the deployed Launcher, FeeHook and PairRegistry work
///      together against the real v4 PoolManager on 4663; a token is created; its pool is
///      initialised with our hook attached; the launcher ends holding nothing; and the launch
///      consumed zero pair currency.
///
///      What it does NOT establish: that trading charges the right fee, that a sweep converts, or
///      that a holder can withdraw. Those need `HoodSmoke.s.sol` after the deployer is funded with
///      WETH.
///
///      Run:
///        forge script script/HoodLaunchOnly.s.sol:HoodLaunchOnly --rpc-url $ROBINHOOD_RPC_URL
///        (add --broadcast once the simulation prints LAUNCH OK)
contract HoodLaunchOnly is Script {
    /// The Sepolia key whose private key is public. Refused here as everywhere else.
    address internal constant COMPROMISED = 0xc286b1956c7691d678520e370727D8aB57328556;

    address internal constant LAUNCHER = 0xCc491F9962CA5545163ac425210b69e24AC29a96;
    address internal constant FEE_HOOK = 0xdC0244274F0b4E60Ec4433bfA9d3Ff0632CAa0Cc;

    /// WETH on 4663. Deepest quote asset on the chain and already approved in our registry.
    address internal constant PAIR = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    uint256 internal constant SUPPLY = 1_000_000_000e18;

    function run() external {
        require(block.chainid == 4663, "HoodLaunchOnly: Robinhood Chain (4663) only");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        require(me != COMPROMISED, "HoodLaunchOnly: that key's private key is PUBLIC");

        require(LAUNCHER.code.length > 0, "HoodLaunchOnly: no code at the launcher");
        require(FEE_HOOK.code.length > 0, "HoodLaunchOnly: no code at the hook");
        require(PAIR.code.length > 0, "HoodLaunchOnly: no code at the pair token");

        Launcher launcher = Launcher(LAUNCHER);
        FeeHook hook = FeeHook(FEE_HOOK);
        IERC20 pair = IERC20(PAIR);
        IPoolManager mgr = IPoolManager(Addresses.ROBINHOOD_POOL_MANAGER);

        // Measured, not assumed: both of these must be UNCHANGED by a single-sided launch.
        uint256 myPairBefore = pair.balanceOf(me);
        uint256 mgrPairBefore = pair.balanceOf(address(mgr));

        console.log("================================================================");
        console.log("chain id      ", block.chainid);
        console.log("caller        ", me);
        console.log("eth balance   ", me.balance);
        console.log("pair (WETH)   ", PAIR);
        console.log("caller's WETH ", myPairBefore, "  <- expected 0, and it must stay 0");
        console.log("================================================================");

        vm.startBroadcast(pk);

        (address token, PoolId id) = launcher.launch(
            Launcher.LaunchParams({
                name: "Hood Test One",
                symbol: "HOOD1",
                supply: SUPPLY,
                pair: PAIR,
                // Quoted in units of the PAIR asset, not dollars: this chain has no USD oracle, so
                // the registry admitted every pair as UNPRICEABLE. 1e18 = one WETH of opening cap.
                openingMarketCap: 1e18,
                graduationThreshold: type(uint256).max, // never graduate during a test
                feeBps: 300, // 3% buys
                sellFeeBps: 300, // 3% sells
                burnBps: 0, // one less moving part on the first live launch
                vestDuration: 0,
                vestCliff: 0,
                creatorBps: 0,
                maxWalletBps: 0,
                tickSpacing: 60,
                devBuyPairAmount: 0, // we hold no WETH, so no dev buy is possible
                salt: bytes32(uint256(block.timestamp)),
                minPushPayout: 1,
                minShareForQueue: 1e18,
                rewardCurrency: address(0), // pay in the pair; a synth reward comes later
                feeRecipient: address(0),
                referrer: address(0),
                openingWindow: 0,
                openingFeeBps: 0,
                metadata: LaunchMetadata({imageCid: keccak256("hood1"), bannerCid: 0, infoCid: 0})
            })
        );

        vm.stopBroadcast();

        // --- The assertions that make this worth running ------------------------------------
        require(token.code.length > 0, "ABORT: no code at the launched token");
        require(
            pair.balanceOf(me) == myPairBefore, "ABORT: the launch spent pair currency - single-sided broken"
        );
        require(
            pair.balanceOf(address(mgr)) == mgrPairBefore,
            "ABORT: the launch put pair currency into the pool - single-sided broken"
        );
        require(
            LaunchToken(token).balanceOf(address(mgr)) > 0, "ABORT: the pool did not receive the supply"
        );
        // The launcher must end every launch holding nothing. Same property the fork test asserts.
        require(
            LaunchToken(token).balanceOf(LAUNCHER) == 0, "ABORT: the launcher retained launch tokens"
        );
        require(pair.balanceOf(LAUNCHER) == 0, "ABORT: the launcher retained pair currency");

        Distributor dist = LaunchToken(token).distributor();
        require(address(dist).code.length > 0, "ABORT: no distributor was deployed for this launch");

        console.log("");
        console.log("=== LAUNCH OK on Robinhood Chain ===");
        console.log("token            ", token);
        console.log("distributor      ", address(dist));
        console.log("pool supply      ", LaunchToken(token).balanceOf(address(mgr)));
        console.log("pair spent        0  (single-sided, as designed)");
        console.log("launcher retained 0");
        console.log("fees taken so far", hook.totalFeesTaken(id));
        console.log("");
        console.log("NOT yet proven: fee correctness, sweep conversion, holder withdrawal.");
        console.log("Those need WETH in the caller and HoodSmoke.s.sol.");
    }
}
