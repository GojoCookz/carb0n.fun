// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {PoolId} from "v4-core/types/PoolId.sol";

import {Launcher} from "../src/Launcher.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {LaunchMetadata} from "../src/types/LaunchMetadata.sol";

/// @title VestTest
/// @notice Proves the dev-buy vault on a live network, including the trade it makes.
///
/// @dev The claim being tested is uncomfortable and therefore worth proving rather than asserting:
///      **a vested dev buy is UNCAPPED**. A creator can take a position five times what the cap
///      would allow, and the protection buyers get in exchange is that the size and the schedule
///      are published on chain in the launch transaction and can never be shortened.
///
///        forge script script/VestTest.s.sol:VestTest --rpc-url sepolia --broadcast --slow
contract VestTest is Script {
    address constant LAUNCHER = 0xe570Fe532F5A04EC800c60897ac36eE990533856;
    address constant TWXMR = 0x7B688B7aA4D802B4555Df0eb5E5b1eb64cbe2d05;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant OPENING_MCAP = 5e18;
    // 50% of the opening market cap - five times what the unvested cap permits.
    uint256 constant DEV_BUY = 2.5e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        Launcher launcher = Launcher(LAUNCHER);
        MockERC20 pair = MockERC20(TWXMR);

        vm.startBroadcast(pk);

        pair.mint(me, 100e18);
        pair.approve(LAUNCHER, type(uint256).max);

        (address token,) = launcher.launch(
            Launcher.LaunchParams({
                name: "Vested Launch",
                symbol: "VEST",
                supply: SUPPLY,
                pair: TWXMR,
                openingMarketCap: OPENING_MCAP,
                graduationThreshold: 25e18,
                feeBps: 300,
                sellFeeBps: 0,
                burnBps: 0,
                vestDuration: 365 days,
                vestCliff: 30 days,
                creatorBps: 2000,
                maxWalletBps: 0,
                tickSpacing: 60,
                devBuyPairAmount: DEV_BUY,
                salt: bytes32(uint256(block.timestamp)),
                minPushPayout: 1e6,
                minShareForQueue: 1e18,
                metadata: LaunchMetadata({imageCid: keccak256("vest"), bannerCid: 0, infoCid: 0})
            })
        );

        address vaultAddr = launcher.vaultOf(token);
        require(vaultAddr != address(0), "no vault was created");
        VestingVault vault = VestingVault(vaultAddr);

        // The whole buy is locked. Not a single token reached the creator's wallet.
        require(LaunchToken(token).balanceOf(me) == 0, "tokens leaked to the wallet");
        require(vault.locked() > 0, "nothing is actually locked");
        require(
            LaunchToken(token).balanceOf(vaultAddr) == vault.locked(),
            "the vault does not hold what it claims"
        );

        // And it is uncapped: this buy is 50% of the opening cap, five times the unvested limit.
        require(DEV_BUY * 10_000 / OPENING_MCAP > 1000, "test is not actually exceeding the cap");

        // The schedule is readable by anyone, right now, before the token has ever traded.
        VestingVault.Schedule memory s = vault.scheduleAt(0);
        require(s.duration == 365 days, "duration not published");
        require(s.cliff == 30 days, "cliff not published");
        require(s.released == 0, "something released already");
        require(vault.releasable() == 0, "nothing may be releasable before the cliff");

        // `releasable() == 0` above is the on-chain proof that nothing can be taken out yet.
        // The revert itself is asserted in `VestingTest.test_nothingUnlocksBeforeTheCliff` rather
        // than here: forge aborts a broadcast when any call in the trace reverts, even one caught
        // in a try/catch, so probing it in a script silently turns the run into a dry run.

        vm.stopBroadcast();

        console.log("=== VESTING PASSED on Sepolia ===");
        console.log("token          ", token);
        console.log("vault          ", vaultAddr);
        console.log("locked tokens  ", vault.locked());
        console.log("in creator wallet", LaunchToken(token).balanceOf(me));
        console.log("cliff (days)   ", uint256(s.cliff) / 1 days);
        console.log("duration (days)", uint256(s.duration) / 1 days);
        console.log("releasable now ", vault.releasable());
    }
}
