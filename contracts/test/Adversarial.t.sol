// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Distributor} from "../src/Distributor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Deliberate attacks on the payout path, written to break it rather than to confirm it.
///
/// @dev **The pair currency is chosen per launch from an allowlist, and it is arbitrary code.**
///      Every other test in this repo pays out in a well-behaved MockERC20. That is the one thing
///      an attacker gets to choose that nobody was testing: `_trySend` makes a raw `.call` into
///      the payout token, so on any pool whose pair currency is hostile, the token is running code
///      in the middle of the distributor's payout loop.
///
///      These tests do not prove the system is safe. They prove specific attacks fail. That is a
///      different and much weaker claim, and it is not a substitute for an audit.

/// @dev A payout token that calls back into the distributor from inside `transfer`.
contract ReentrantToken is MockERC20 {
    Distributor public target;
    bool public armed;
    uint256 public reentryCount;
    uint8 public mode; // 0 = withdraw, 1 = processBatch

    constructor() MockERC20("Hostile", "EVIL", 18) {}

    function arm(Distributor _t, uint8 _mode) external {
        target = _t;
        mode = _mode;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed && address(target) != address(0)) {
            reentryCount++;
            armed = false; // one shot, so the test terminates
            if (mode == 0) {
                try target.withdraw() {} catch {}
            } else {
                try target.processBatch(10) {} catch {}
            }
            armed = true;
        }
        return super.transfer(to, amount);
    }
}

/// @dev A holder that cannot receive the payout token at all.
contract RejectingToken is MockERC20 {
    mapping(address => bool) public blocked;

    constructor() MockERC20("Blocky", "BLK", 18) {}

    function block_(address a) external {
        blocked[a] = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blocked[to]) return false; // lies rather than reverts, the harder case
        return super.transfer(to, amount);
    }
}

contract AdversarialTest is Test {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    function _mkDistributor(address payoutToken) internal returns (Distributor d) {
        d = new Distributor(
            address(this), // shareToken
            payoutToken,
            address(this), // controller
            address(0),
            address(0),
            1, // minPushPayout
            1, // minShareForQueue
            1, // minSharesForDistribution
            address(0), // rewardToken - pays the pair currency
            address(0) // no converter
        );
    }

    // ===========================================================================================
    // Reentrancy through a hostile pair currency
    // ===========================================================================================

    /// A malicious payout token reenters `withdraw` from inside its own `transfer`. If the
    /// accumulator were read before the state update, this would pay the same claim twice.
    function test_attack_reentrantWithdrawCannotDoublePay() public {
        ReentrantToken evil = new ReentrantToken();
        Distributor d = _mkDistributor(address(evil));

        d.setBalance(alice, 1_000e18);
        evil.mint(address(d), 100e18);
        d.distribute(100e18);
        // A distribution vests over `STREAM_WINDOW` rather than crediting instantly, so there is
        // nothing to reenter for until it has. Advance past the finish so the pot is fully
        // claimable and the double-pay attempt below has real money to try to take twice.
        vm.warp(block.timestamp + d.STREAM_WINDOW() + 1);

        uint256 owed = d.withdrawableOf(alice);
        assertGt(owed, 0, "precondition: alice is owed something");

        evil.arm(d, 0);
        vm.prank(alice);
        d.withdraw();

        assertGt(evil.reentryCount(), 0, "the attack never actually fired");
        assertEq(evil.balanceOf(alice), owed, "alice was paid more than once");
        assertEq(d.withdrawableOf(alice), 0, "claim survived being paid");
        assertLe(d.totalWithdrawn(), d.totalDistributed(), "paid out more than came in");
    }

    /// Same idea against the push path, which walks a queue and updates its cursor AFTER the loop.
    function test_attack_reentrantProcessBatchCannotDoublePay() public {
        ReentrantToken evil = new ReentrantToken();
        Distributor d = _mkDistributor(address(evil));

        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 1_000e18);
        evil.mint(address(d), 100e18);
        d.distribute(100e18);
        // Fully vest first: `processBatch` skips anybody owed less than `minPushPayout`, so with
        // an un-vested stream it would walk the queue paying nobody and never reach `transfer`.
        vm.warp(block.timestamp + d.STREAM_WINDOW() + 1);

        uint256 owedA = d.withdrawableOf(alice);
        uint256 owedB = d.withdrawableOf(bob);

        evil.arm(d, 1);
        d.processBatch(10);

        assertGt(evil.reentryCount(), 0, "the attack never actually fired");
        assertEq(evil.balanceOf(alice), owedA, "alice overpaid");
        assertEq(evil.balanceOf(bob), owedB, "bob overpaid");
        assertLe(d.totalWithdrawn(), d.totalDistributed(), "paid out more than came in");
        assertGe(evil.balanceOf(address(d)) + d.totalWithdrawn(), d.totalDistributed(), "insolvent");
    }

    // ===========================================================================================
    // Griefing: one holder who cannot be paid
    // ===========================================================================================

    /// The pair currencies on the allowlist include several that can blacklist an address. A
    /// blacklisted holder must not be able to stop everyone else being paid.
    function test_attack_oneUnpayableHolderCannotBrickTheQueue() public {
        RejectingToken tok = new RejectingToken();
        Distributor d = _mkDistributor(address(tok));

        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 1_000e18);
        d.setBalance(carol, 1_000e18);
        tok.mint(address(d), 300e18);
        d.distribute(300e18);
        // Vest the stream so all three holders are genuinely owed something - otherwise the batch
        // pays nobody and "the blocked holder did not brick the queue" would pass vacuously.
        vm.warp(block.timestamp + d.STREAM_WINDOW() + 1);

        tok.block_(bob);

        uint256 owedB = d.withdrawableOf(bob);
        (uint256 sent,) = d.processBatch(10);

        assertEq(sent, 2, "the blocked holder stopped the others being paid");
        assertGt(tok.balanceOf(alice), 0, "alice unpaid");
        assertGt(tok.balanceOf(carol), 0, "carol unpaid");
        assertEq(tok.balanceOf(bob), 0, "blocked holder somehow received");
        assertEq(d.withdrawableOf(bob), owedB, "blocked holder LOST their claim");
    }

    /// The same holder must not have their balance silently zeroed by a failed pull either.
    function test_attack_failedPullKeepsTheClaim() public {
        RejectingToken tok = new RejectingToken();
        Distributor d = _mkDistributor(address(tok));

        d.setBalance(alice, 1_000e18);
        tok.mint(address(d), 100e18);
        d.distribute(100e18);
        // Without this warp nothing has vested, `withdraw` reverts with `NothingToWithdraw`
        // whatever the token does, and the test passes while proving nothing at all - `before`
        // would be 0 and the assertion would be 0 == 0. The claim has to exist to be eaten.
        vm.warp(block.timestamp + d.STREAM_WINDOW() + 1);
        tok.block_(alice);

        uint256 before = d.withdrawableOf(alice);
        assertGt(before, 0, "precondition: there is a real claim to lose");
        vm.prank(alice);
        vm.expectRevert();
        d.withdraw();

        assertEq(d.withdrawableOf(alice), before, "a failed pull ate the claim");
        assertEq(d.totalWithdrawn(), 0, "a failed pull was counted as paid");
    }

    // ===========================================================================================
    // Donation
    // ===========================================================================================

    /// Anyone can send the pair currency straight to the distributor. That must not become
    /// claimable out of thin air - only `distribute` may create entitlement.
    function test_attack_rawDonationCreatesNoEntitlement() public {
        MockERC20 tok = new MockERC20("Pair", "PAIR", 18);
        Distributor d = _mkDistributor(address(tok));

        d.setBalance(alice, 1_000e18);
        assertEq(d.withdrawableOf(alice), 0);

        tok.mint(address(this), 500e18);
        tok.transfer(address(d), 500e18); // straight in, no distribute()

        assertEq(d.withdrawableOf(alice), 0, "a donation became someone's dividend");
        assertEq(d.totalDistributed(), 0, "a donation was counted as distributed");

        vm.prank(alice);
        vm.expectRevert();
        d.withdraw();
    }

    // ===========================================================================================
    // Access control on the money
    // ===========================================================================================

    function test_attack_outsiderCannotDistribute() public {
        MockERC20 tok = new MockERC20("Pair", "PAIR", 18);
        Distributor d = _mkDistributor(address(tok));
        tok.mint(address(d), 100e18);

        vm.prank(alice);
        vm.expectRevert();
        d.distribute(100e18);
    }

    function test_attack_outsiderCannotSetTheirOwnBalance() public {
        MockERC20 tok = new MockERC20("Pair", "PAIR", 18);
        Distributor d = _mkDistributor(address(tok));

        vm.prank(alice);
        vm.expectRevert();
        d.setBalance(alice, 1_000_000e18);
    }

    function test_attack_outsiderCannotUnexcludeThePool() public {
        MockERC20 tok = new MockERC20("Pair", "PAIR", 18);
        Distributor d = _mkDistributor(address(tok));

        vm.prank(alice);
        vm.expectRevert();
        d.setExcluded(alice, false);
    }

    /// The precise shape of the bug that once bricked a token permanently: a single dust holder
    /// makes `_magnifiedPayoutPerShare` explode until a later `_update` overflows.
    function test_attack_dustHolderCannotBrickTheAccumulator() public {
        MockERC20 tok = new MockERC20("Pair", "PAIR", 18);
        Distributor d = new Distributor(
            address(this),
            address(tok),
            address(this),
            address(0),
            address(0),
            1,
            1,
            1_000e18,
            address(0),
            address(0)
        );

        d.setBalance(alice, 1); // one wei of shares
        tok.mint(address(d), 1_000e18);
        d.distribute(1_000e18);

        // Carried, not divided by dust.
        assertEq(d.totalDistributed(), 0, "divided a distribution by one wei of shares");
        assertEq(d.pendingPayouts(), 1_000e18, "the carried fee vanished");

        // A real holder arrives; the carried amount is folded in and everything still works.
        d.setBalance(bob, 10_000e18);
        tok.mint(address(d), 1e18);
        d.distribute(1e18);

        // Folding the carry back in ARMS it, it does not credit it: the whole 1_001e18 now vests
        // over `STREAM_WINDOW`. Advance past the finish and checkpoint so the ledger below reads
        // the settled state rather than a stream in flight.
        vm.warp(block.timestamp + d.STREAM_WINDOW() + 1);
        d.processBatch(0); // permissionless checkpoint - walks nobody, pays nobody

        // `_arm` splits the total into a per-second rate and carries the `total % STREAM_WINDOW`
        // remainder in `pendingPayouts` rather than dropping it, so the two buckets together are
        // still exactly what came in. That equality is the real claim: not one wei was lost
        // between being carried and being paid.
        assertEq(
            d.totalDistributed() + d.pendingPayouts(), 1_001e18, "the carry was not folded in"
        );
        assertLt(d.pendingPayouts(), d.STREAM_WINDOW(), "more than truncation dust was withheld");

        vm.prank(bob);
        d.withdraw();
        assertGt(tok.balanceOf(bob), 0, "bob could not be paid");
    }
}
