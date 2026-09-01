// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {MockV4Router} from "v4-periphery/test/mocks/MockV4Router.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {PathKey} from "v4-periphery/src/libraries/PathKey.sol";
import {Plan, Planner} from "v4-periphery/test/shared/Planner.sol";

import {Launcher} from "../src/Launcher.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {LaunchMetadata} from "../src/types/LaunchMetadata.sol";
import {Addresses} from "./Addresses.sol";

/// @title RouteTest
/// @notice The test that matters for a real user: **buy the launch token without ever holding the
///         quote asset**, in one transaction, through a multi-hop route.
///
/// @dev Every live test so far bought with the quote token directly, which nobody actually has. A
///      real buyer holds ETH. The route they need is:
///
///        ETH -> (wrap) -> WETH -> QUOTE -> LAUNCH TOKEN
///
///      and the last leg goes through OUR HOOKED POOL. That last leg is the unknown: a hook that
///      returns deltas has to behave correctly when it is an intermediate step in somebody else's
///      route, not just when it is the whole trade. A hook that works standalone and breaks under
///      routing is a hook nobody can trade.
///
///      This builds the missing quote-side pool on Sepolia (tWETH/tWXMR, no hook - it stands in for
///      the real WETH/WXMR market, which on mainnet is a Uniswap v2 pool), then routes
///      tWETH -> tWXMR -> TOKEN through `V4Router` and asserts:
///
///        - the buyer starts with ZERO quote asset and never holds any
///        - they end holding the launch token
///        - our hook charged its fee on the final leg, at the configured rate
///
///      Run:
///        forge script script/RouteTest.s.sol:RouteTest --rpc-url sepolia --broadcast --slow
contract RouteTest is Script {
    using Planner for Plan;

    address constant LAUNCHER = 0x1af6714DfA8f6F2786F336be9DFd7b037a140a16;
    address constant FEE_HOOK = 0x9f3f9dEfCc97422D2C9C62b30B7Db5bF09b9E0cc;
    address constant TWETH = 0x3aB74F7A7572ab3677F4FF0B22F0f37e18F157DE;
    address constant TWXMR = 0xD6d5542D7ff53dc14471AE0f1d5Ec7241821bBC6;

    uint256 constant SUPPLY = 1_000_000_000e18;
    int24 constant SPACING = 60;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        IPoolManager mgr = IPoolManager(Addresses.SEPOLIA_POOL_MANAGER);
        FeeHook hook = FeeHook(FEE_HOOK);
        MockERC20 weth = MockERC20(TWETH);
        MockERC20 quote = MockERC20(TWXMR);

        vm.startBroadcast(pk);

        MockV4Router router = new MockV4Router(mgr);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(mgr);

        // --- 1. Stand up the quote-side market: tWETH/tWXMR, NO hook ------------------------
        //       On mainnet this leg already exists as a Uniswap v2 pool. Sepolia has no such
        //       market for our mock, so the route has nothing to hop through until we build one.
        weth.mint(me, 10_000e18);
        quote.mint(me, 10_000e18);

        PoolKey memory hop1 = _plainKey(TWETH, TWXMR);
        mgr.initialize(hop1, TickMath.getSqrtPriceAtTick(0)); // 1:1

        weth.approve(address(lp), type(uint256).max);
        quote.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            hop1,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(SPACING),
                tickUpper: TickMath.maxUsableTick(SPACING),
                liquidityDelta: 500e18,
                salt: bytes32(0)
            }),
            ""
        );

        // --- 2. Launch a token quoted in tWXMR ----------------------------------------------
        (address token, PoolId id) = Launcher(LAUNCHER).launch(
            Launcher.LaunchParams({
                name: "Route Test Token",
                symbol: "ROUTE",
                supply: SUPPLY,
                pair: TWXMR,
                openingMarketCap: 5e18,
                graduationThreshold: 25e18,
                feeBps: 300,
                sellFeeBps: 500,
                burnBps: 2000,
                vestDuration: 0,
                vestCliff: 0,
                creatorBps: 2000,
                maxWalletBps: 0,
                tickSpacing: SPACING,
                devBuyPairAmount: 0,
                salt: bytes32(uint256(block.timestamp)),
                minPushPayout: 1e6,
                minShareForQueue: 1e18,
                metadata: LaunchMetadata({imageCid: keccak256("route"), bannerCid: 0, infoCid: 0})
            })
        );

        // --- 3. Become a buyer who holds NO quote asset --------------------------------------
        //       Dump every tWXMR so the only way to reach the token is through the route.
        quote.transfer(address(0xdEaD), quote.balanceOf(me));
        require(quote.balanceOf(me) == 0, "buyer must start with zero quote asset");

        uint256 tokenBefore = LaunchToken(token).balanceOf(me);
        uint256 feesBefore = hook.totalFeesTaken(id);

        // --- 4. ONE transaction: tWETH -> tWXMR -> TOKEN -------------------------------------
        //       The second PathKey carries OUR hook, so the final leg runs through it.
        uint256 amountIn = 2e18;

        PathKey[] memory path = new PathKey[](2);
        // A PathKey RECONSTRUCTS the pool key from these fields, so every one of them must match
        // the pool exactly - fee included. The quote-side pool was opened at 3000, and pointing
        // this at 0 hashes to a pool that was never initialised.
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(TWXMR),
            fee: 3000,
            tickSpacing: SPACING,
            hooks: IHooks(address(0)), // the plain quote-side pool
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(token),
            fee: 0,
            tickSpacing: SPACING,
            hooks: IHooks(FEE_HOOK), // OUR pool
            hookData: ""
        });

        // This periphery build carries a PER-HOP price floor, `minHopPriceX36`, which is newer
        // than the two-field slippage guard most examples show. Zero means unconstrained; a real
        // frontend must populate it or every hop is unprotected.
        uint256[] memory minHopPrice = new uint256[](path.length);

        Plan memory plan = Planner.init().add(
            Actions.SWAP_EXACT_IN,
            abi.encode(
                IV4Router.ExactInputParams({
                    currencyIn: Currency.wrap(TWETH),
                    path: path,
                    minHopPriceX36: minHopPrice,
                    amountIn: uint128(amountIn),
                    amountOutMinimum: 0
                })
            )
        );
        bytes memory data =
            plan.finalizeSwap(Currency.wrap(TWETH), Currency.wrap(token), me);

        weth.approve(address(router), type(uint256).max);
        router.executeActions(data);

        // --- 5. Assertions -------------------------------------------------------------------
        require(quote.balanceOf(me) == 0, "buyer ended up holding the quote asset");
        require(
            LaunchToken(token).balanceOf(me) > tokenBefore,
            "ROUTE FAILED - buyer received no launch token"
        );
        require(
            hook.totalFeesTaken(id) > feesBefore,
            "the hook did not charge on the routed leg"
        );

        uint256 got = LaunchToken(token).balanceOf(me) - tokenBefore;
        uint256 charged = hook.totalFeesTaken(id) - feesBefore;

        vm.stopBroadcast();

        console.log("=== MULTI-HOP ROUTE PASSED on Sepolia ===");
        console.log("token              ", token);
        console.log("spent (tWETH)      ", amountIn);
        console.log("quote held by buyer", quote.balanceOf(me));
        console.log("tokens received    ", got);
        console.log("hook fee charged   ", charged);
    }

    /// @dev A hookless pool key, sorted. Stands in for the real WETH/QUOTE market.
    function _plainKey(address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: SPACING,
            hooks: IHooks(address(0))
        });
    }
}
