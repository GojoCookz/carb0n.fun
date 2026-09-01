// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LaunchToken} from "../src/LaunchToken.sol";
import {Distributor} from "../src/Distributor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {LaunchTokenDeployer} from "./utils/LaunchTokenDeployer.sol";

contract LaunchTokenTest is Test, LaunchTokenDeployer {
    LaunchToken internal token;
    Distributor internal dist;
    MockERC20 internal payout;

    address internal launcher = address(0x1AACE);
    address internal controller = address(0xC0FFEE); // stands in for the fee hook
    address internal poolManager = address(0x9004);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant MAX_WALLET = 20_000_000e18; // 2%
    uint256 internal constant MIN_PUSH = 1e6;
    uint256 internal constant MIN_QUEUE = 1e18;

    function _params(uint256 cap) internal view returns (LaunchToken.InitParams memory) {
        return LaunchToken.InitParams({
            name_: "Test Launch",
            symbol_: "TEST",
            supply: SUPPLY,
            recipient: launcher,
            payoutToken: address(payout),
                rewardToken: address(0),
                converter: address(0),
            controller: controller,
            poolManager_: poolManager,
            maxWallet_: cap,
            minPushPayout: MIN_PUSH,
            minShareForQueue: MIN_QUEUE,
            metadata: _defaultMetadata()
        });
    }

    function setUp() public {
        payout = new MockERC20("Wrapped Monero", "WXMR", 18);

        _deployLaunchTokenImpl();
        token = _cloneAndInit(bytes32(uint256(1)), _params(MAX_WALLET));
        dist = token.distributor();

        // Simulate the launcher seeding the pool.
        vm.prank(launcher);
        token.transfer(poolManager, SUPPLY);
    }

    // ===========================================================================================
    // Construction
    // ===========================================================================================

    function test_deploysAndPairsItsOwnDistributor() public view {
        assertEq(dist.shareToken(), address(token), "distributor must be bound to this token");
        assertEq(dist.payoutToken(), address(payout), "dividends paid in the PAIR asset");
        assertEq(dist.controller(), controller);
    }

    function test_fixedSupplyMintedToLauncher() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev No mint function must exist. If one is ever added this test won't catch it, but the
    ///      supply invariant will.
    function test_supplyIsFixedAfterLaunch() public {
        vm.prank(poolManager);
        token.transfer(alice, 1e18);
        assertEq(token.totalSupply(), SUPPLY, "supply must never change");
    }

    // ===========================================================================================
    // Max wallet - buys only
    // ===========================================================================================

    function test_buyUnderCapSucceeds() public {
        vm.prank(poolManager);
        token.transfer(alice, MAX_WALLET - 1);
        assertEq(token.balanceOf(alice), MAX_WALLET - 1);
    }

    function test_buyAtExactCapSucceeds() public {
        vm.prank(poolManager);
        token.transfer(alice, MAX_WALLET);
        assertEq(token.balanceOf(alice), MAX_WALLET);
    }

    function test_buyOverCapReverts() public {
        vm.prank(poolManager);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchToken.MaxWalletExceeded.selector, alice, MAX_WALLET + 1, MAX_WALLET)
        );
        token.transfer(alice, MAX_WALLET + 1);
    }

    /// @dev The cap is cumulative, not per-transaction - otherwise it is trivially bypassed by
    ///      splitting one buy into two.
    function test_capIsCumulativeAcrossBuys() public {
        vm.startPrank(poolManager);
        token.transfer(alice, MAX_WALLET - 10);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchToken.MaxWalletExceeded.selector, alice, MAX_WALLET + 90, MAX_WALLET)
        );
        token.transfer(alice, 100);
        vm.stopPrank();
    }

    /// @dev THE important one. A cap that can block a sell is a honeypot.
    function test_sellIsNeverBlocked() public {
        vm.prank(poolManager);
        token.transfer(alice, MAX_WALLET);

        vm.prank(alice);
        token.transfer(poolManager, MAX_WALLET);

        assertEq(token.balanceOf(alice), 0, "sell must always be allowed");
    }

    /// @dev Wallet-to-wallet is not a buy and must not be capped, even past the cap.
    function test_walletToWalletIsNotCapped() public {
        vm.prank(poolManager);
        token.transfer(alice, MAX_WALLET);
        vm.prank(poolManager);
        token.transfer(bob, MAX_WALLET);

        vm.prank(bob);
        token.transfer(alice, MAX_WALLET);

        assertEq(token.balanceOf(alice), MAX_WALLET * 2, "p2p transfers are not buys");
    }

    function test_exemptAddressesBypassCap() public view {
        assertTrue(token.exemptFromMaxWallet(poolManager));
        assertTrue(token.exemptFromMaxWallet(launcher));
        assertTrue(token.exemptFromMaxWallet(controller));
        assertTrue(token.exemptFromMaxWallet(address(dist)));
    }

    function test_zeroMaxWalletDisablesCap() public {
        LaunchToken uncapped = _cloneAndInit(bytes32(uint256(2)), _params(0));
        vm.prank(launcher);
        uncapped.transfer(poolManager, SUPPLY);

        vm.prank(poolManager);
        uncapped.transfer(alice, SUPPLY); // the entire supply, in one buy
        assertEq(uncapped.balanceOf(alice), SUPPLY);
    }

    // ===========================================================================================
    // Distributor wiring
    // ===========================================================================================

    function test_transferUpdatesDistributorShares() public {
        vm.prank(poolManager);
        token.transfer(alice, 5_000e18);

        assertEq(dist.shareOf(alice), 5_000e18, "shares must track balance");
        assertEq(token.balanceOf(alice), dist.shareOf(alice));
    }

    /// @dev The pool must never accrue dividends - it is infrastructure, not a holder. If it did,
    ///      a large fraction of every distribution would be paid to the pool and stranded.
    function test_poolManagerAccruesNoShares() public {
        vm.prank(controller);
        dist.setExcluded(poolManager, true);

        vm.prank(poolManager);
        token.transfer(alice, 1_000e18);

        assertEq(dist.shareOf(poolManager), 0, "pool must hold zero shares");
        assertEq(dist.shareOf(alice), 1_000e18);
    }

    function test_sharesFollowBalanceBothWays() public {
        vm.prank(poolManager);
        token.transfer(alice, 10_000e18);
        assertEq(dist.shareOf(alice), 10_000e18);

        vm.prank(alice);
        token.transfer(bob, 4_000e18);

        assertEq(dist.shareOf(alice), 6_000e18);
        assertEq(dist.shareOf(bob), 4_000e18);
        assertEq(dist.totalShares(), dist.shareOf(alice) + dist.shareOf(bob) + dist.shareOf(poolManager));
    }

    /// @dev End to end: holders are paid in the PAIR currency, not in more of this token.
    function test_dividendsArePaidInPairCurrency() public {
        vm.prank(controller);
        dist.setExcluded(poolManager, true);

        vm.prank(poolManager);
        token.transfer(alice, 1_000e18);
        vm.prank(poolManager);
        token.transfer(bob, 3_000e18);

        // The hook has taken 400 WXMR of fees and delivered them to the distributor.
        payout.mint(address(dist), 400e18);
        vm.prank(controller);
        dist.distribute(400e18);

        // alice holds 25% of shares, bob 75%. The magnified-per-share accumulator truncates, so
        // payouts round DOWN by up to a wei each. That is the correct direction: dust is stranded
        // in the contract and folded into the next distribution, and the pool can never be drained
        // by rounding. Assert the bound and the direction, never exact equality.
        uint256 aliceOwed = dist.withdrawableOf(alice);
        uint256 bobOwed = dist.withdrawableOf(bob);

        assertApproxEqAbs(aliceOwed, 100e18, 1, "alice ~25%");
        assertApproxEqAbs(bobOwed, 300e18, 1, "bob ~75%");
        assertLe(aliceOwed, 100e18, "must round down, never up");
        assertLe(bobOwed, 300e18, "must round down, never up");

        // The invariant that actually matters: the contract can never owe more than it received.
        assertLe(aliceOwed + bobOwed, 400e18, "payouts must never exceed distributions");

        vm.prank(alice);
        dist.withdraw();

        assertEq(payout.balanceOf(alice), aliceOwed, "paid in WXMR, not in the launch token");
        assertGt(payout.balanceOf(alice), 0, "alice actually got paid");
        assertEq(token.balanceOf(alice), 1_000e18, "launch token balance untouched");
    }

    /// @dev Generalises the rounding guarantee: however the shares split, the sum of what everyone
    ///      can withdraw must never exceed what was distributed.
    function testFuzz_payoutsNeverExceedDistributions(uint256 aliceShare, uint256 fee) public {
        aliceShare = bound(aliceShare, 1e18, MAX_WALLET);
        fee = bound(fee, 1e6, 1_000_000e18);

        vm.prank(controller);
        dist.setExcluded(poolManager, true);

        vm.startPrank(poolManager);
        token.transfer(alice, aliceShare);
        token.transfer(bob, MAX_WALLET);
        vm.stopPrank();

        payout.mint(address(dist), fee);
        vm.prank(controller);
        dist.distribute(fee);

        assertLe(dist.withdrawableOf(alice) + dist.withdrawableOf(bob), fee, "solvency: owed <= received");
    }

    // ===========================================================================================
    // Infrastructure exclusion and the brick-the-token guard
    // ===========================================================================================

    /// @dev Both addresses that hold supply as infrastructure must be excluded at construction.
    ///      Neither can be excluded later: `setExcluded` is `onlyController`, the controller is the
    ///      fee hook, and the hook has no function that calls through to it.
    function test_poolAndLauncherAreExcludedAtConstruction() public view {
        assertTrue(dist.excluded(poolManager), "the pool holds reserves, not a position");
        assertTrue(dist.excluded(launcher), "the launcher is a conduit, not a holder");
        assertTrue(dist.excluded(address(0)), "mint/burn counterparty");
        assertTrue(dist.excluded(address(0xdEaD)), "burn address");
    }

    /// @dev **Regression guard for a token-bricking griefing vector.**
    ///
    ///      `_magnifiedPayoutPerShare += amount * 2**128 / totalShares` grows without bound as
    ///      `totalShares` approaches zero, and `_setShares` then evaluates
    ///      `_magnifiedPayoutPerShare * delta` in checked arithmetic. If the first holder owns one
    ///      wei when a real fee arrives, the accumulator lands around `fee * 2**128`, and the next
    ///      ordinary-sized balance change overflows - which reverts inside `_update` and makes the
    ///      token **permanently untransferable for everyone**.
    ///
    ///      That is reachable on purpose: be the first buyer, buy one wei. The floor makes the
    ///      distribution carry instead.
    function test_aOneWeiHolderCannotBrickTheToken() public {
        vm.prank(poolManager);
        token.transfer(alice, 1);
        assertEq(dist.totalShares(), 1, "a single wei is the entire holder base");

        payout.mint(address(dist), 1_000e18);
        vm.prank(controller);
        dist.distribute(1_000e18);

        assertEq(dist.pendingPayouts(), 1_000e18, "carried rather than divided by one wei");
        assertEq(dist.totalDistributed(), 0, "and not applied");

        // The token must still move. Before the floor existed, this reverted with panic 0x11.
        vm.prank(poolManager);
        token.transfer(bob, 10_000_000e18);
        assertEq(token.balanceOf(bob), 10_000_000e18, "transfers still work");

        vm.prank(bob);
        token.transfer(alice, 1_000e18);
        assertEq(dist.totalShares(), token.balanceOf(alice) + token.balanceOf(bob));
    }

    /// @dev The carry is not a black hole: once a real holder base exists, it is paid out.
    function test_carriedPayoutsAreReleasedToTheFirstRealHolders() public {
        vm.prank(poolManager);
        token.transfer(alice, 1);

        payout.mint(address(dist), 1_000e18);
        vm.prank(controller);
        dist.distribute(1_000e18);
        assertEq(dist.pendingPayouts(), 1_000e18);

        // A real holder arrives, then any further distribution flushes the carry with it.
        vm.prank(poolManager);
        token.transfer(bob, 10_000_000e18);

        payout.mint(address(dist), 1e18);
        vm.prank(controller);
        dist.distribute(1e18);

        assertEq(dist.pendingPayouts(), 0, "carry released");
        assertEq(dist.totalDistributed(), 1_001e18, "the carried amount was included");
        assertGt(dist.withdrawableOf(bob), 999e18, "and the real holder receives it");
    }

    // ===========================================================================================
    // Fuzz
    // ===========================================================================================

    function testFuzz_sharesAlwaysEqualBalanceForHolders(uint256 amount) public {
        amount = bound(amount, 1, MAX_WALLET);

        vm.prank(controller);
        dist.setExcluded(poolManager, true);

        vm.prank(poolManager);
        token.transfer(alice, amount);

        assertEq(dist.shareOf(alice), token.balanceOf(alice));
    }

    function testFuzz_sellNeverReverts(uint256 buyAmount, uint256 sellAmount) public {
        buyAmount = bound(buyAmount, 1, MAX_WALLET);
        sellAmount = bound(sellAmount, 1, buyAmount);

        vm.prank(poolManager);
        token.transfer(alice, buyAmount);

        vm.prank(alice);
        token.transfer(poolManager, sellAmount);

        assertEq(token.balanceOf(alice), buyAmount - sellAmount);
    }
}
