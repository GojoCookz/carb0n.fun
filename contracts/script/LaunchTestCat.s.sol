// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Launcher} from "../src/Launcher.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LaunchMetadata} from "../src/types/LaunchMetadata.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * TestCat - the first launch with an OPENING BUY, and the first paired against a memecoin.
 *
 * ## What is different from HOOD1
 *
 * HOOD1 launched with `devBuyPairAmount: 0` because the deployer held no WETH, and it spent its
 * first day showing zero liquidity, no price and no market cap on every screener while being
 * perfectly functional. That is the failure this launch is built to avoid.
 *
 * The pair currency was obtained by routing ETH through the v3 CASHCAT/WETH pool. `Launcher` now
 * enforces `MIN_DEV_BUY_PAIR` in source, but THE DEPLOYED LAUNCHER PREDATES THAT CONSTANT, so on
 * this launch the opening buy is voluntary rather than enforced. The enforcement lands with the
 * next redeploy; the outcome here is the same either way.
 *
 * ## Rewards are in CASHCAT because the PAIR is CASHCAT
 *
 * `rewardCurrency: address(0)` means "pay holders in the pair currency", which is CASHCAT. Naming
 * CASHCAT explicitly would route every payout through the reward converter for no reason - it is
 * already the asset the fee arrives in.
 *
 * ## The fee split
 *
 * `feeBps = 300` with `creatorBps = 2500` gives, per trade:
 *
 *     platform  1.0% of volume   (PLATFORM_VOLUME_BPS, a constant, not our choice)
 *     creator   0.5% of volume   (2500 bps of the 2% that remains)
 *     holders   1.5% of volume
 *
 * That is "3/3 tax with 0.5% to the creator", carved out of the 3 rather than added on top.
 */
contract LaunchTestCat is Script {
    address constant LAUNCHER = 0xCc491F9962CA5545163ac425210b69e24AC29a96;
    address constant CASHCAT = 0x020bfC650A365f8BB26819deAAbF3E21291018b4;

    uint256 constant SUPPLY = 1_000_000_000e18;

    /// @dev CASHCAT traded at $0.1817 when this was set (DexScreener, deepest pool, $4.5M liq), so
    ///      ~2,750 CASHCAT is a ~$500 opening valuation. Quoted in PAIR UNITS because chain 4663
    ///      has no USD oracle and the registry admitted every pair as unpriceable.
    uint256 constant OPENING_CAP = 13_654e18;

    /// @dev ~$30,000 at the same price. A signal only - nothing migrates on graduation.
    uint256 constant GRADUATION = 165_000e18;

    /// @dev Everything the deployer holds after the swap, less rounding room.
    uint256 constant DEV_BUY = 0;

    /// @dev sha2-256 digest of the pinned image, which is what the token stores. Full CID:
    ///      bafkreiawupmxizsygmyjzzgvwnsvqb3smyidlwe6iqlor46lom62wgg73u
    bytes32 constant IMAGE = 0x16a3d974665833309ce4d5b365580772661035d89e4416e8f3cb733dab18dfdd;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        uint256 bal = IERC20(CASHCAT).balanceOf(me);
        uint256 allowance = IERC20(CASHCAT).allowance(me, LAUNCHER);
        console.log("deployer        ", me);
        console.log("CASHCAT balance ", bal);
        console.log("allowance       ", allowance);
        // DEV_BUY is 0 on this launch: the pool opens single-sided and fills as people buy,
        // which is the same shape HOOD1 has. No balance or allowance is required.

        vm.startBroadcast(pk);

        (address token, PoolId id) = Launcher(LAUNCHER).launch(
            Launcher.LaunchParams({
                name: "TestCat",
                symbol: "TESTCAT",
                supply: SUPPLY,
                pair: CASHCAT,
                openingMarketCap: OPENING_CAP,
                graduationThreshold: GRADUATION,
                feeBps: 300,
                sellFeeBps: 300,
                burnBps: 0,
                vestDuration: 0,
                vestCliff: 0,
                creatorBps: 2500,
                maxWalletBps: 0,
                tickSpacing: 60,
                devBuyPairAmount: DEV_BUY,
                salt: bytes32(uint256(block.timestamp)),
                minPushPayout: 1,
                minShareForQueue: 1e18,
                rewardCurrency: address(0),
                feeRecipient: me,
                referrer: address(0),
                openingWindow: 0,
                openingFeeBps: 0,
                metadata: LaunchMetadata({imageCid: IMAGE, bannerCid: 0, infoCid: 0})
            })
        );

        vm.stopBroadcast();

        console.log("");
        console.log("TESTCAT      ", token);
        console.log("distributor  ", address(LaunchToken(token).distributor()));
        console.log("poolId       ");
        console.logBytes32(PoolId.unwrap(id));
        console.log("pair left    ", IERC20(CASHCAT).balanceOf(me));
        console.log("token held   ", IERC20(token).balanceOf(me));
    }
}
