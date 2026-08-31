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
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {Launcher} from "../src/Launcher.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Distributor} from "../src/Distributor.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {LaunchMetadata} from "../src/types/LaunchMetadata.sol";
import {Addresses} from "./Addresses.sol";

/// @title LiveTest
/// @notice Drives a complete launch on a LIVE network and asserts every property we claim.
///
/// @dev The suite proves these against a PoolManager we compiled and a fork we pinned. This proves
///      them against a deployed singleton, a deployed hook at a mined address, real block gas and
///      a real transaction ordering. Every `require` below is a claim from the docs:
///
///        - launching costs the creator NO pair currency
///        - the pool opens holding zero pair currency (single-sided)
///        - a buy is charged in the pair currency, as an ERC-6909 claim
///        - `sweep` converts claims into real payouts a holder can withdraw
///        - a sell is charged in the LAUNCH TOKEN and converted on the next sweep
///        - the burn wedge destroys supply
///        - graduation latches once and never un-latches
///
///      Run:
///        forge script script/LiveTest.s.sol:LiveTest --rpc-url sepolia --broadcast --slow
contract LiveTest is Script {
    using StateLibrary for IPoolManager;

    // Filled from the deploy that precedes this run.
    address constant LAUNCHER = 0x81d5690Aa98651cE9D68F82E5396a2E37e25029E;
    address constant FEE_HOOK = 0xd67E790d3Be6161C50d9D27b84aE78eE8e2eE0cC;
    address constant TWXMR = 0x033cb8D1E8b7F69360358B5595ea335283f675fF;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant OPENING_MCAP = 5e18; // 5 tWXMR
    uint256 constant THRESHOLD = 25e18; // 5x the opening

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        Launcher launcher = Launcher(LAUNCHER);
        FeeHook hook = FeeHook(FEE_HOOK);
        MockERC20 pair = MockERC20(TWXMR);

        vm.startBroadcast(pk);

        // The router that will trade against the pool. Uniswap deployed one on Sepolia, but this
        // script owns its approvals so it deploys its own.
        PoolSwapTest router = new PoolSwapTest(IPoolManager(Addresses.SEPOLIA_POOL_MANAGER));

        // Fund ourselves with the test pair so we can trade. Note we do NOT need any of it to
        // launch - that is the property under test.
        pair.mint(me, 1_000e18);

        uint256 pairBefore = pair.balanceOf(me);

        // --- 1. LAUNCH, supplying no pair currency -------------------------------------------
        (address token, PoolId id) = launcher.launch(
            Launcher.LaunchParams({
                name: "Live Test Token",
                symbol: "LIVE",
                supply: SUPPLY,
                pair: TWXMR,
                openingMarketCap: OPENING_MCAP,
                graduationThreshold: THRESHOLD,
                feeBps: 300, // 3% buys
                sellFeeBps: 500, // 5% sells
                burnBps: 2000, // 20% of each swept fee is burned
                creatorBps: 2000,
                maxWalletBps: 0,
                tickSpacing: 60,
                devBuyPairAmount: 0,
                salt: bytes32(uint256(block.timestamp)),
                minPushPayout: 1e6,
                minShareForQueue: 1e18,
                metadata: LaunchMetadata({imageCid: keccak256("live"), bannerCid: 0, infoCid: 0})
            })
        );

        require(pair.balanceOf(me) == pairBefore, "LAUNCH COST PAIR CURRENCY - single-sided broken");

        PoolKey memory key = _key(token);
        IPoolManager mgr = IPoolManager(Addresses.SEPOLIA_POOL_MANAGER);

        require(pair.balanceOf(address(mgr)) == 0, "pool opened holding pair currency");
        require(LaunchToken(token).balanceOf(address(mgr)) > 0, "pool did not receive the supply");

        // --- 2. BUY --------------------------------------------------------------------------
        pair.approve(address(router), type(uint256).max);
        _swap(router, key, _buyIsZeroForOne(token), 2e18);

        uint256 charged = hook.pendingFees(id);
        require(charged == (2e18 * 300) / 10_000, "buy fee is not exactly 3%");
        require(LaunchToken(token).balanceOf(me) > 0, "buy delivered no tokens");

        // --- 3. SWEEP: claims become real payouts, and the burn fires ------------------------
        Distributor dist = LaunchToken(token).distributor();

        // Measure the DELTA. `Launcher._refundResidual` already burns unseeded dust to the dead
        // address at launch, so its balance is not only the buyback.
        uint256 deadBefore = LaunchToken(token).balanceOf(address(0xdEaD));
        hook.sweep(key);

        require(hook.pendingFees(id) == 0, "sweep did not redeem the claim");
        require(hook.totalBurned(id) > 0, "burn wedge did not fire");
        require(
            LaunchToken(token).balanceOf(address(0xdEaD)) - deadBefore == hook.totalBurned(id),
            "bought-back tokens did not reach the dead address"
        );

        // --- 4. SELL: charged in the LAUNCH TOKEN --------------------------------------------
        LaunchToken(token).approve(address(router), type(uint256).max);
        uint256 held = LaunchToken(token).balanceOf(me);
        _swap(router, key, !_buyIsZeroForOne(token), held / 4);

        require(hook.pendingTokenFees(id) > 0, "sell was not charged in launch tokens");

        // --- 5. SWEEP AGAIN: the sell fee becomes pair currency for holders -------------------
        uint256 ledgerBefore = pair.balanceOf(address(dist));
        hook.sweep(key);
        require(hook.pendingTokenFees(id) == 0, "token fee not converted");
        require(pair.balanceOf(address(dist)) >= ledgerBefore, "conversion did not reach holders");

        // --- 6. GRADUATION -------------------------------------------------------------------
        require(!hook.hasGraduated(id), "graduated far too early");
        _swap(router, key, _buyIsZeroForOne(token), 40e18); // clear 5x
        require(hook.marketCapOf(id) >= THRESHOLD, "the big buy did not clear the bar");
        require(hook.checkGraduation(id), "crossing did not latch");
        require(hook.checkGraduation(id), "second call must stay true");

        vm.stopBroadcast();

        console.log("=== LIVE TEST PASSED on Sepolia ===");
        console.log("token            ", token);
        console.log("pair spent to launch  0  (single-sided)");
        console.log("fees charged     ", hook.totalFeesTaken(id));
        console.log("tokens burned    ", hook.totalBurned(id));
        console.log("market cap       ", hook.marketCapOf(id));
        console.log("graduated        ", hook.hasGraduated(id));
        console.log("holder withdrawable", dist.withdrawableOf(me));
    }

    function _key(address token) internal pure returns (PoolKey memory) {
        bool t0 = token < TWXMR;
        return PoolKey({
            currency0: Currency.wrap(t0 ? token : TWXMR),
            currency1: Currency.wrap(t0 ? TWXMR : token),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(FEE_HOOK)
        });
    }

    function _buyIsZeroForOne(address token) internal pure returns (bool) {
        return !(token < TWXMR); // buying pays the pair in
    }

    function _swap(PoolSwapTest router, PoolKey memory key, bool zeroForOne, uint256 amountIn)
        internal
    {
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
