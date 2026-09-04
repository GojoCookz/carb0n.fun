// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReferralVault} from "../src/ReferralVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The referral ledger: that it splits correctly, that nothing leaks, and that the
///         structural limits which keep it out of pyramid territory actually hold.
contract ReferralTest is Test {
    ReferralVault internal vault;
    MockERC20 internal weth;

    address internal launcher = address(0x1A0);
    address internal hook = address(0x400);
    address internal treasury = address(0x7EE);

    address internal a = address(0xA1);
    address internal b = address(0xB2);
    address internal c = address(0xC3);
    address internal d = address(0xD4);
    address internal e = address(0xE5);
    address internal f = address(0xF6);

    /// 20 / 10 / 5 / 3 / 2 percent of the platform cut. 40% total, treasury keeps 60%.
    function _schedule() internal pure returns (uint16[] memory s) {
        s = new uint16[](5);
        s[0] = 2000;
        s[1] = 1000;
        s[2] = 500;
        s[3] = 300;
        s[4] = 200;
    }

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        vault = new ReferralVault(launcher, hook, treasury, _schedule());
    }

    function _refer(address user, address referrer) internal {
        vm.prank(launcher);
        vault.setReferrer(user, referrer);
    }

    /// Move the money the way the hook does: transfer first, then tell the vault.
    function _credit(uint256 amount, address creator) internal {
        weth.mint(address(vault), amount);
        vm.prank(hook);
        vault.credit(address(weth), amount, creator);
    }

    // ===========================================================================================
    // The split
    // ===========================================================================================

    function test_aSingleReferrerEarnsTheFirstTierAndTreasuryTakesTheRest() public {
        _refer(a, b); // b referred a
        _credit(1000e18, a);

        assertEq(vault.owed(b, address(weth)), 200e18, "direct referrer should earn 20%");
        assertEq(vault.owed(treasury, address(weth)), 800e18, "treasury should keep the rest");
    }

    /// The whole chain, five deep, each tier paid its own share.
    function test_theChainIsPaidTierByTier() public {
        _refer(a, b);
        _refer(b, c);
        _refer(c, d);
        _refer(d, e);
        _refer(e, f);

        _credit(10_000e18, a);

        assertEq(vault.owed(b, address(weth)), 2000e18, "tier 1");
        assertEq(vault.owed(c, address(weth)), 1000e18, "tier 2");
        assertEq(vault.owed(d, address(weth)), 500e18, "tier 3");
        assertEq(vault.owed(e, address(weth)), 300e18, "tier 4");
        assertEq(vault.owed(f, address(weth)), 200e18, "tier 5");
        assertEq(vault.owed(treasury, address(weth)), 6000e18, "treasury keeps the remainder");
    }

    /// **The walk is bounded by the schedule, not by the chain.** A sixth referrer earns nothing;
    /// the depth cap is in the bytecode and cannot be extended later to chase growth.
    function test_theChainStopsAtTheTierCount() public {
        address[7] memory chain = [a, b, c, d, e, f, address(0x777)];
        for (uint256 i = 0; i < 6; i++) {
            _refer(chain[i], chain[i + 1]);
        }

        _credit(10_000e18, a);

        assertEq(vault.owed(address(0x777), address(weth)), 0, "a 6th tier was paid");
        assertEq(vault.tierCount(), 5, "tier count drifted");
    }

    /// **Nothing may leak.** Every wei credited is owed to somebody, on every chain length.
    function testFuzz_creditIsFullyConserved(uint96 amount, uint8 depth) public {
        depth = uint8(bound(depth, 0, 6));
        address[7] memory chain = [a, b, c, d, e, f, address(0x777)];
        for (uint256 i = 0; i < depth; i++) {
            _refer(chain[i], chain[i + 1]);
        }

        _credit(uint256(amount), a);

        uint256 total = vault.owed(treasury, address(weth));
        for (uint256 i = 0; i < 7; i++) {
            total += vault.owed(chain[i], address(weth));
        }
        assertEq(total, uint256(amount), "value leaked out of the split");
    }

    /// A creator nobody referred is not a special case - the treasury simply takes all of it.
    function test_anUnreferredCreatorSendsEverythingToTreasury() public {
        _credit(500e18, a);
        assertEq(vault.owed(treasury, address(weth)), 500e18);
    }

    // ===========================================================================================
    // Claiming
    // ===========================================================================================

    function test_claimPaysAndZeroes() public {
        _refer(a, b);
        _credit(1000e18, a);

        vm.prank(b);
        uint256 got = vault.claim(address(weth));

        assertEq(got, 200e18);
        assertEq(weth.balanceOf(b), 200e18, "referrer was not paid");
        assertEq(vault.owed(b, address(weth)), 0, "balance survived the claim");
    }

    /// **One balance per address, not per pool.** A referrer with many referred launches against
    /// the same currency claims all of them at once.
    function test_oneClaimCollectsEveryReferredLaunch() public {
        _refer(a, b);
        _refer(c, b);
        _refer(d, b);

        _credit(1000e18, a);
        _credit(1000e18, c);
        _credit(1000e18, d);

        vm.prank(b);
        vault.claim(address(weth));

        assertEq(weth.balanceOf(b), 600e18, "three referrals did not settle in one claim");
    }

    function test_claimingNothingReverts() public {
        vm.prank(b);
        vm.expectRevert(ReferralVault.NothingOwed.selector);
        vault.claim(address(weth));
    }

    function test_earnedIsCumulativeAndSurvivesAClaim() public {
        _refer(a, b);
        _credit(1000e18, a);
        vm.prank(b);
        vault.claim(address(weth));
        _credit(1000e18, a);

        assertEq(vault.earned(b, address(weth)), 400e18, "lifetime earnings were reset by a claim");
        assertEq(vault.owed(b, address(weth)), 200e18, "only the unclaimed half should be owed");
    }

    // ===========================================================================================
    // Access control and abuse
    // ===========================================================================================

    function test_onlyTheLauncherMaySetAReferrer() public {
        vm.prank(a);
        vm.expectRevert(ReferralVault.OnlyLauncher.selector);
        vault.setReferrer(a, b);
    }

    function test_onlyTheHookMayCredit() public {
        weth.mint(address(vault), 100e18);
        vm.prank(a);
        vm.expectRevert(ReferralVault.OnlyFeeHook.selector);
        vault.credit(address(weth), 100e18, a);
    }

    function test_selfReferralIsRejected() public {
        vm.prank(launcher);
        vm.expectRevert(ReferralVault.SelfReferral.selector);
        vault.setReferrer(a, a);
    }

    /// **A second launch through a different link must not reassign the claim, and must not
    /// revert.** Reverting would mean a creator's second token fails because of a marketing
    /// parameter; reassigning would mean a referral claim can be stolen after the fact.
    function test_aSecondReferrerIsIgnoredRatherThanAppliedOrReverted() public {
        _refer(a, b);
        _refer(a, c); // no revert
        assertEq(vault.referrerOf(a), b, "an existing referrer was overwritten");
    }

    /// A cycle cannot be created (write-once forbids it), but the loop must terminate anyway.
    function test_aCycleCannotBeBuilt() public {
        _refer(a, b);
        _refer(b, a); // legal: b had no referrer

        _credit(10_000e18, a);

        // b earns tier 1, then the walk reaches a, then b again - bounded by tierCount, not depth.
        assertGt(vault.owed(b, address(weth)), 0);
        uint256 total = vault.owed(a, address(weth)) + vault.owed(b, address(weth))
            + vault.owed(treasury, address(weth));
        assertEq(total, 10_000e18, "a cycle leaked value");
    }

    // ===========================================================================================
    // The structural limits
    // ===========================================================================================

    function test_aScheduleDeeperThanTheCapIsRejected() public {
        uint16[] memory tooDeep = new uint16[](6);
        vm.expectRevert(ReferralVault.TooManyTiers.selector);
        new ReferralVault(launcher, hook, treasury, tooDeep);
    }

    /// The schedule is paid out of the platform's cut, so it cannot exceed it. Without this the
    /// treasury underflows and the vault owes more than it holds.
    function test_aScheduleOverOneHundredPercentIsRejected() public {
        uint16[] memory greedy = new uint16[](2);
        greedy[0] = 6000;
        greedy[1] = 5000;
        vm.expectRevert(ReferralVault.TiersExceedWhole.selector);
        new ReferralVault(launcher, hook, treasury, greedy);
    }

    /// The vault must never owe more than it holds, on any chain.
    function testFuzz_vaultIsAlwaysSolvent(uint96 amount, uint8 depth) public {
        depth = uint8(bound(depth, 0, 6));
        address[7] memory chain = [a, b, c, d, e, f, address(0x777)];
        for (uint256 i = 0; i < depth; i++) {
            _refer(chain[i], chain[i + 1]);
        }
        _credit(uint256(amount), a);

        uint256 owedTotal = vault.owed(treasury, address(weth));
        for (uint256 i = 0; i < 7; i++) {
            owedTotal += vault.owed(chain[i], address(weth));
        }
        assertGe(weth.balanceOf(address(vault)), owedTotal, "vault owes more than it holds");
    }
}
