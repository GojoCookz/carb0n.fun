// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {ZapRouter} from "../src/ZapRouter.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {Addresses} from "./Addresses.sol";

/// @title DeployZap
/// @notice Deploy `ZapRouter` on Sepolia and stand up the ETH/tPAXG pool it needs for hop 1.
///
/// @dev **STATE THIS PLAINLY, EVERY TIME THIS SCRIPT IS MENTIONED: the price in this pool is a
///      number I invented.** There is no ETH/tPAXG market on Sepolia, and tPAXG is a mock with no
///      market anywhere. Seeding it myself is the only way to exercise hop 1 at all, and it proves
///      the ROUTING works. It is not evidence about anybody's economics and the UI must not imply
///      that it is. On mainnet hop 1 would route through the real ETH/PAXG market, which
///      `app/measure.ts` measured at $17.2M across v2 and v3.
///
///      The opening tick puts roughly 997 tPAXG to one ether. That ratio was chosen for one
///      unglamorous reason: the deployer wallet holds about 0.08 Sepolia ETH and a million tPAXG,
///      so pricing tPAXG cheaply is what lets the scarce side of the book go further.
///
///      **The liquidity here is NOT locked.** It sits in a `PoolModifyLiquidityTest`, whose
///      `modifyLiquidity` is public, so anyone can pull it back out. That is acceptable for a
///      testnet routing demo and would not be acceptable anywhere else.
///
///      Run:
///        forge script script/DeployZap.s.sol:DeployZap --rpc-url $SEPOLIA_RPC_URL --broadcast --slow
contract DeployZap is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// Approved in `PairRegistry` by `AddPaxg.s.sol`.
    address constant TPAXG = 0x5B36658F7EF7c79c4e7ec46463FeB04012744F0c;

    int24 constant SPACING = 60;
    uint24 constant ETH_POOL_FEE = 3000;

    /// 1.0001^69060 ~= 997 tPAXG per ether. A multiple of the tick spacing so the opening tick is
    /// exactly a usable one.
    int24 constant OPENING_TICK = 69060;

    /// Chosen so the ether side costs about 0.03 of the deployer's ~0.08 ETH.
    int256 constant LIQUIDITY = 9.4e17;
    uint256 constant ETH_SENT = 0.031 ether;
    uint256 constant TPAXG_FOR_SEED = 100e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        IPoolManager mgr = IPoolManager(Addresses.SEPOLIA_POOL_MANAGER);

        vm.startBroadcast(pk);

        // `weth = address(0)` DISABLES the wrap shortcut, deliberately. Sepolia's `tWETH` is a
        // plain `MockERC20` with no `deposit()`, so pointing this at it would make every
        // WETH-paired zap revert inside a function that does not exist. On mainnet this is the
        // real WETH9 and hop 1 for a WETH-paired launch becomes a free 1:1 wrap.
        ZapRouter zap = new ZapRouter(mgr, address(0));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(mgr);

        // Native ether is address(0), so it sorts to currency0 unconditionally. `ZapRouter`
        // requires exactly this shape and rejects anything else with `EthLegIsNotNative`.
        PoolKey memory ethKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(TPAXG),
            fee: ETH_POOL_FEE,
            tickSpacing: SPACING,
            hooks: IHooks(address(0))
        });

        // **Idempotent on purpose.** `ZapRouter`'s constructor and entry points change more often
        // than the pool does, so this script gets re-run to redeploy the router alone. `forge`
        // aborts a broadcast if ANY call in the trace reverts — including a second `initialize` on
        // a pool that already exists — so the pool legs are skipped when hop 1 is already there.
        (uint160 existing,,,) = mgr.getSlot0(ethKey.toId());
        if (existing == 0) {
            mgr.initialize(ethKey, TickMath.getSqrtPriceAtTick(OPENING_TICK));

            MockERC20(TPAXG).mint(me, TPAXG_FOR_SEED);
            MockERC20(TPAXG).approve(address(lp), type(uint256).max);

            lp.modifyLiquidity{value: ETH_SENT}(
                ethKey,
                ModifyLiquidityParams({
                    tickLower: TickMath.minUsableTick(SPACING),
                    tickUpper: TickMath.maxUsableTick(SPACING),
                    liquidityDelta: LIQUIDITY,
                    salt: bytes32(0)
                }),
                ""
            );
        }

        vm.stopBroadcast();

        (uint160 sqrtPriceX96, int24 tick,,) = mgr.getSlot0(ethKey.toId());
        require(sqrtPriceX96 != 0, "the ETH/tPAXG pool did not initialise");

        console.log("ZapRouter                ", address(zap));
        console.log("lp router (NOT LOCKED)   ", address(lp));
        console.log("ETH/tPAXG pool tick      ", vm.toString(tick));
        console.log("ETH/tPAXG sqrtPriceX96   ", sqrtPriceX96);
        console.log("--- hop 1 exists. Its price is invented; see this file's docstring. ---");
    }
}
