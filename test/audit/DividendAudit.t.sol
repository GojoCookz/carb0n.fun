// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Distributor, IRewardConverter} from "../../src/Distributor.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {VestingVault} from "../../src/VestingVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {LaunchTokenDeployer} from "../utils/LaunchTokenDeployer.sol";

// ===============================================================================================
// Converters
// ===============================================================================================

/// @notice Takes the allowance it was given and then reports "could not route" by returning zero.
///
/// @dev This is NOT only a malicious shape. A converter that pulls `amountIn`, routes it, and
///      returns `amountOut` will return zero whenever the route produced nothing - a dust input, a
///      pool that moved, a hop that silently no-opped. `RewardCurrency.t.sol`'s `ZeroConverter` is
///      `pure` and never touches the allowance, so the pull-then-return-zero shape is untested.
contract ThievingConverter is IRewardConverter {
    function convert(address tokenIn, address, uint256 amountIn, address)
        external
        returns (uint256)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        return 0;
    }
}

/// @notice Pulls the allowance, delivers, and reports honestly. The control for the above.
contract HonestConverter is IRewardConverter {
    function convert(address tokenIn, address tokenOut, uint256 amountIn, address recipient)
        external
        returns (uint256)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(recipient, amountIn);
        return amountIn;
    }
}

// ===============================================================================================
// Holders
// ===============================================================================================

/// @notice Tries to take twice what it was approved for.
contract GreedyConverter is IRewardConverter {
    function convert(address tokenIn, address, uint256 amountIn, address)
        external
        returns (uint256)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn * 2);
        return amountIn;
    }
}

/// @notice Pulls only half, reports success. Tests that the allowance is still cleared.
contract PartialConverter is IRewardConverter {
    function convert(address tokenIn, address tokenOut, uint256 amountIn, address recipient)
        external
        returns (uint256)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn / 2);
        MockERC20(tokenOut).mint(recipient, amountIn / 2);
        return amountIn / 2;
    }
}

contract RevertingConverter2 is IRewardConverter {
    function convert(address, address, uint256, address) external pure returns (uint256) {
        revert("no route");
    }
}

/// @notice Reenters the distributor from inside the conversion.
contract ReentrantConverter is IRewardConverter {
    Distributor public target;
    uint256 public hits;
    uint8 public mode; // 0 = withdraw, 1 = processBatch

    function arm(Distributor t, uint8 m) external {
        target = t;
        mode = m;
    }

    function convert(address tokenIn, address tokenOut, uint256 amountIn, address recipient)
        external
        returns (uint256)
    {
        hits++;
        // Spend the allowance BEFORE reentering: a nested `_trySend` clears it on the way out, so
        // reentering first turns every one of these into a `catch` and hides the interleaving.
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        if (hits == 1) {
            if (mode == 0) {
                try target.withdraw() {} catch {}
            } else {
                try target.processBatch(10) {} catch {}
            }
        }
        MockERC20(tokenOut).mint(recipient, amountIn);
        return amountIn;
    }
}

/// @notice A contract that can hold the launch token and has no way to call `withdraw()`.
contract DumbHolder {}

contract DividendAuditTest is Test, LaunchTokenDeployer {
    MockERC20 internal pair;
    MockERC20 internal reward;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    /// Launcher-shaped numbers: 1B token supply, so `minSharesForDistribution == supply / 1e6`.
    uint256 internal constant SUPPLY = 1_000_000_000e18; // 1e27
    uint256 internal constant FLOOR = SUPPLY / 1e6; // 1e21

    function setUp() public {
        pair = new MockERC20("Wrapped Ether", "WETH", 18);
        reward = new MockERC20("Wrapped Bitcoin", "WBTC", 18);
    }

    /// The test contract is BOTH `shareToken` and `controller`, the same shape `Adversarial.t.sol`
    /// uses, so every privileged entry point is drivable. Access control is tested elsewhere.
    function _mk(uint256 minPush, uint256 minQueue, uint256 minDist, address rewardTok, address conv)
        internal
        returns (Distributor d)
    {
        d = new Distributor(
            address(this),
            address(pair),
            address(this),
            address(0),
            address(0),
            minPush,
            minQueue,
            minDist,
            rewardTok,
            conv
        );
    }

    function _mkDefault() internal returns (Distributor) {
        return _mk(1, 1, 1, address(0), address(0));
    }

    function _fund(Distributor d, uint256 amount) internal {
        pair.mint(address(d), amount);
        d.distribute(amount);
    }

    // ===========================================================================================
    // D-01  A converter that spends its allowance and returns zero is paid, and then the holder
    //       is paid again out of everyone else's money.
    // ===========================================================================================

    function test_D01_converterThatSpendsTheAllowanceAndReturnsZeroIsPaidTwice() public {
        ThievingConverter thief = new ThievingConverter();
        Distributor d = _mk(1, 1, 1, address(reward), address(thief));

        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 1_000e18);
        _fund(d, 200e18);

        uint256 owedAlice = d.withdrawableOf(alice);
        uint256 owedBob = d.withdrawableOf(bob);
        assertApproxEqAbs(owedAlice, 100e18, 2, "precondition: alice owed half");
        assertApproxEqAbs(owedBob, 100e18, 2, "precondition: bob owed half");
        assertEq(pair.balanceOf(address(d)), 200e18, "precondition: the contract holds both claims");

        vm.prank(alice);
        d.withdraw();

        // The converter kept the whole approved amount...
        assertEq(pair.balanceOf(address(thief)), owedAlice, "the converter did not spend the allowance");
        // ...and `_trySend` fell through and paid the pair currency on top of it.
        assertEq(pair.balanceOf(alice), owedAlice, "alice was not paid the fallback as well");

        // Two payments for one claim. The ledger recorded ONE.
        assertEq(d.withdrawnOf(alice), owedAlice, "the ledger only ever saw one payment");
        assertLe(d.totalWithdrawn(), d.totalDistributed(), "the existing invariant still passes");

        // The contract now holds less than it owes. That is insolvency, not a rounding gap.
        assertLt(
            pair.balanceOf(address(d)),
            d.withdrawableOf(bob),
            "the distributor should be short by exactly one holder's claim"
        );
        // Only truncation dust survives: 200e18 arrived, ~2 x 100e18 left on one withdrawal.
        assertLe(pair.balanceOf(address(d)), 2, "both claims left the building on one withdrawal");
    }

    function test_D01b_theSecondPaymentLeavesEveryOtherHolderUnableToClaim() public {
        ThievingConverter thief = new ThievingConverter();
        Distributor d = _mk(1, 1, 1, address(reward), address(thief));

        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 1_000e18);
        _fund(d, 200e18);

        vm.prank(alice);
        d.withdraw();

        uint256 owedBob = d.withdrawableOf(bob);
        assertGt(owedBob, 0, "bob is still owed on the books");

        // Pull fails: nothing left to pay him with.
        vm.prank(bob);
        vm.expectRevert(Distributor.NothingToWithdraw.selector);
        d.withdraw();

        // Push fails too, silently, and restores his claim - so he is stuck forever, not paid late.
        (uint256 sent, uint256 total) = d.processBatch(10);
        assertEq(sent, 0, "somebody was paid out of an empty contract");
        assertEq(total, 0);
        assertEq(d.withdrawableOf(bob), owedBob, "bob's claim is intact and unpayable");
    }

    /// The same shape via the push path: one batch empties the contract, paying one claim to the
    /// converter and one to a holder, and leaves the second holder owed money that is gone.
    function test_D01c_onePushBatchEmptiesTheContractAndStrandsTheSecondHolder() public {
        ThievingConverter thief = new ThievingConverter();
        Distributor d = _mk(1, 1, 1, address(reward), address(thief));

        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 1_000e18);
        _fund(d, 200e18);

        (uint256 sent, uint256 total) = d.processBatch(10);

        assertEq(sent, 1, "expected exactly one holder to be paid before the money ran out");
        assertApproxEqAbs(total, 100e18, 2);
        assertApproxEqAbs(pair.balanceOf(address(thief)), 100e18, 2, "the converter kept a claim");
        assertLe(pair.balanceOf(address(d)), 2, "200e18 arrived and 200e18 left in one batch");

        // The unpaid holder still has their claim, correctly restored - and nothing to pay it with.
        address stranded = pair.balanceOf(alice) == 0 ? alice : bob;
        assertGt(d.withdrawableOf(stranded), 0, "the skipped holder lost their claim");
        vm.prank(stranded);
        vm.expectRevert(Distributor.NothingToWithdraw.selector);
        d.withdraw();
    }

    /// Control: an honest converter that pulls and reports truthfully pays exactly once.
    function test_D01d_control_anHonestConverterPaysExactlyOnce() public {
        HonestConverter good = new HonestConverter();
        Distributor d = _mk(1, 1, 1, address(reward), address(good));

        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 1_000e18);
        _fund(d, 200e18);

        uint256 owed = d.withdrawableOf(alice);
        vm.prank(alice);
        d.withdraw();

        assertEq(pair.balanceOf(alice), 0, "paid the pair currency as well as the reward");
        assertEq(reward.balanceOf(alice), owed, "not paid the reward");
        assertEq(pair.balanceOf(address(d)), 200e18 - owed, "the contract lost more than one claim");
        assertGe(pair.balanceOf(address(d)), d.withdrawableOf(bob), "solvent");
    }

    /// @dev The allowance bound itself holds: the approval is exactly `amount`, so a converter
    ///      reaching for more reverts inside `transferFrom` and lands in the `catch`.
    function test_sound_aConverterCannotTakeMoreThanItWasApprovedFor() public {
        GreedyConverter greedy = new GreedyConverter();
        Distributor d = _mk(1, 1, 1, address(reward), address(greedy));

        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 1_000e18);
        _fund(d, 200e18);

        uint256 owed = d.withdrawableOf(alice);
        vm.prank(alice);
        d.withdraw();

        assertEq(pair.balanceOf(address(greedy)), 0, "the converter took more than its allowance");
        assertEq(pair.balanceOf(alice), owed, "the holder was not paid the fallback");
        assertEq(pair.allowance(address(d), address(greedy)), 0, "an allowance survived");
        assertGe(pair.balanceOf(address(d)), d.withdrawableOf(bob), "insolvent");
    }

    /// @dev The allowance must be zero after every converter outcome, not just the happy one.
    function test_sound_noAllowanceSurvivesAnyConverterOutcome() public {
        address[5] memory convs = [
            address(new HonestConverter()),
            address(new ThievingConverter()),
            address(new PartialConverter()),
            address(new RevertingConverter2()),
            address(new GreedyConverter())
        ];

        for (uint256 i = 0; i < 5; i++) {
            Distributor d = _mk(1, 1, 1, address(reward), convs[i]);
            d.setBalance(alice, 1_000e18);
            _fund(d, 100e18);
            vm.prank(alice);
            try d.withdraw() {} catch {}
            assertEq(
                pair.allowance(address(d), convs[i]), 0, "a converter kept a standing allowance"
            );
        }
    }

    /// @dev A converter is arbitrary code called mid-payout, exactly like a hostile payout token.
    ///      `Adversarial.t.sol` covers the token; this covers the converter.
    function test_sound_aReentrantConverterCannotDoublePay() public {
        for (uint8 mode = 0; mode < 2; mode++) {
            ReentrantConverter rc = new ReentrantConverter();
            Distributor d = _mk(1, 1, 1, address(reward), address(rc));
            rc.arm(d, mode);

            d.setBalance(alice, 1_000e18);
            d.setBalance(bob, 1_000e18);
            _fund(d, 200e18);

            uint256 owedA = d.withdrawableOf(alice);
            uint256 owedB = d.withdrawableOf(bob);
            // Balances accumulate across the two modes, so measure deltas.
            uint256 rA = reward.balanceOf(alice);
            uint256 rB = reward.balanceOf(bob);
            uint256 pA = pair.balanceOf(alice);
            uint256 pB = pair.balanceOf(bob);

            vm.prank(alice);
            d.withdraw();

            assertGt(rc.hits(), 0, "the reentrancy never fired");
            assertLe(
                reward.balanceOf(alice) - rA + pair.balanceOf(alice) - pA,
                owedA,
                "alice was paid more than she was owed"
            );
            assertLe(
                reward.balanceOf(bob) - rB + pair.balanceOf(bob) - pB,
                owedB,
                "bob was paid more than he was owed"
            );
            assertLe(d.totalWithdrawn(), d.totalDistributed(), "paid out more than arrived");
            assertGe(
                pair.balanceOf(address(d)),
                d.withdrawableOf(alice) + d.withdrawableOf(bob),
                "insolvent after a reentrant conversion"
            );
        }
    }

    // ===========================================================================================
    // D-02  Exclusion cannot be changed after construction, so a claim held by a contract that
    //       cannot call `withdraw()` is destroyed rather than redistributed.
    // ===========================================================================================

    /// @dev `setExcluded` is `onlyController`, the controller is `FeeHook`, and `FeeHook` contains
    ///      no call to it (`grep -rn setExcluded src/` finds only the definition). So the excluded
    ///      set is frozen at construction: pool, launcher, distributor, 0x0, 0xdEaD.
    function test_D02_aContractHolderThatCannotPullLocksItsDividendsForever() public {
        Distributor d = _mkDefault();
        DumbHolder dumb = new DumbHolder();

        d.setBalance(address(dumb), 1_000e18);
        d.setBalance(alice, 1_000e18);
        _fund(d, 200e18);

        uint256 stranded = d.withdrawableOf(address(dumb));
        assertApproxEqAbs(stranded, 100e18, 2, "the dumb holder accrued half of the distribution");

        // Push cannot rescue it either: the transfer succeeds and the pair currency lands on a
        // contract with no function that can ever move it again.
        d.processBatch(10);
        assertEq(pair.balanceOf(address(dumb)), stranded, "push did not deliver");
        assertEq(d.withdrawableOf(address(dumb)), 0, "and the claim is settled, on paper");

        // And there is no reachable way to have excluded it in the first place.
        vm.prank(alice);
        vm.expectRevert(Distributor.OnlyController.selector);
        d.setExcluded(address(dumb), true);
    }

    /// @dev The in-repo instance of the same gap. `VestingVault.renounceAccrual` is documented as
    ///      "the locked supply's dividend claim belongs to the other holders, forever". It sets a
    ///      flag on the vault and nothing else - the vault's shares stay in `totalShares`, so the
    ///      other holders' per-share rate does not move by one wei. The stream is destroyed.
    function test_D02b_vestingVaultRenounceDestroysTheStreamInsteadOfRedistributingIt() public {
        Distributor d = _mkDefault();
        address creator = address(0xC12EA702);
        VestingVault vault = new VestingVault(address(this), address(d), creator);

        d.setBalance(address(vault), 1_000e18);
        d.setBalance(alice, 1_000e18);

        _fund(d, 200e18);
        uint256 aliceBefore = d.withdrawableOf(alice);

        vm.prank(creator);
        vault.renounceAccrual();

        // Nothing moved on the ledger.
        assertEq(d.shareOf(address(vault)), 1_000e18, "renouncing removed no shares");
        assertEq(d.totalShares(), 2_000e18, "renouncing did not change the denominator");

        // So the next distribution still cuts the vault in, and alice's rate is unchanged.
        _fund(d, 200e18);
        assertApproxEqAbs(
            d.withdrawableOf(alice) - aliceBefore,
            100e18,
            2,
            "alice received a renounced holder's share - she did not"
        );
        assertGt(d.withdrawableOf(address(vault)), 0, "the vault kept accruing after renouncing");

        // And the vault's only exit is now closed.
        vm.prank(creator);
        vm.expectRevert(VestingVault.AlreadyRenounced.selector);
        vault.claimDividends();

        // Push still delivers real pair currency into the vault, where it is unrecoverable: the
        // vault's ONLY payout-token transfer sits inside `claimDividends`, which now reverts.
        d.processBatch(10);
        assertGt(pair.balanceOf(address(vault)), 0, "pair currency was pushed into a sealed vault");

        vm.prank(creator);
        vm.expectRevert(VestingVault.AlreadyRenounced.selector);
        vault.claimDividends();
    }

    // ===========================================================================================
    // D-03  The queue only ever grows.
    // ===========================================================================================

    /// @dev `Launcher._validate` bounds `supply`, `maxWalletBps`, `openingMarketCap`,
    ///      `graduationThreshold`, the dev buy and the vest. It does NOT look at `minShareForQueue`
    ///      or `minPushPayout` at all, so `minShareForQueue == 0` ships straight through `launch()`.
    ///      At zero, `newShares >= minShareForQueue` is `0 >= 0` and the `else if (newShares == 0)`
    ///      dequeue branch at Distributor.sol:239 becomes unreachable.
    function test_D03_zeroMinShareForQueueMakesDequeueUnreachable() public {
        Distributor d = _mk(1, 0, 1, address(0), address(0));

        d.setBalance(alice, 1_000e18);
        assertEq(d.queueLength(), 1, "precondition: alice queued");

        d.setBalance(alice, 0); // sells everything
        assertEq(d.shareOf(alice), 0, "shares cleared");
        assertEq(d.queueLength(), 1, "a zero-balance holder was dequeued");
        assertEq(d.queueAt(0), alice, "and it is still alice");

        // It is monotonic: 40 accounts in and out leaves 40 permanent entries.
        for (uint256 i = 0; i < 40; i++) {
            address a = address(uint160(0x5A1E0000 + i));
            d.setBalance(a, 1e18);
            d.setBalance(a, 0);
        }
        assertEq(d.queueLength(), 41, "the queue did not grow monotonically");
        assertEq(d.totalShares(), 0, "and nobody actually holds anything");
    }

    /// @dev Even with a positive threshold the dequeue is only wired to EXACTLY zero, so a holder
    ///      who leaves one wei behind is a permanent queue entry. That makes bloat cheap: one
    ///      transfer per address, no minimum position held afterwards.
    function test_D03b_dustHoldersAreNeverDequeuedEvenWithAPositiveThreshold() public {
        Distributor d = _mk(1, 1e18, 1, address(0), address(0));

        for (uint256 i = 0; i < 40; i++) {
            address a = address(uint160(0xD0570000 + i));
            d.setBalance(a, 1e18); // enters the queue
            d.setBalance(a, 1); // one wei left behind
            assertEq(d.shareOf(a), 1);
        }
        assertEq(d.queueLength(), 40, "dust holders left the queue");
        assertEq(d.totalShares(), 40, "40 wei of shares hold 40 queue slots");

        // A real holder arrives and is stuck behind all of them for push purposes.
        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);

        (uint256 sent,) = d.processBatch(40);
        assertEq(sent, 0, "the first full batch paid a real holder");
        assertEq(d.withdrawableOf(alice), d.withdrawableOf(alice), "");
        assertGt(d.withdrawableOf(alice), 0, "alice is owed and was not pushed");

        // The pull path is unaffected - which is why this is griefing, not theft.
        vm.prank(alice);
        d.withdraw();
        assertGt(pair.balanceOf(alice), 0, "pull must always work");
    }

    /// @dev `processBatch` is documented at Distributor.sol:15-16 as something "the hook calls
    ///      opportunistically after a swap". Nothing in `src/` calls it - `FeeHook` only ever calls
    ///      `distribute` (FeeHook.sol:909). The push path is entirely volunteer-funded.
    function test_D03c_nothingInTheSystemEverCallsProcessBatch() public {
        // Documented here rather than asserted: the claim is about the absence of a call site.
        // `grep -rn "processBatch" src/` returns only Distributor.sol's own definition and
        // docstring. This test pins the consequence: a queued holder owed money stays owed until
        // somebody volunteers gas.
        Distributor d = _mkDefault();
        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        assertGt(d.withdrawableOf(alice), 0, "owed, and nothing on-chain will push it");
    }

    // ===========================================================================================
    // D-04  `minPushPayout == 0` turns every batch into a run of zero-value payouts.
    // ===========================================================================================

    function test_D04_zeroMinPushPayoutPaysHoldersWhoAreOwedNothing() public {
        Distributor d = _mk(0, 1, 1, address(0), address(0));

        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 1_000e18);
        // No distribution at all: both are owed exactly zero.
        assertEq(d.withdrawableOf(alice), 0);

        (uint256 sent, uint256 total) = d.processBatch(10);
        assertEq(sent, 2, "the dust guard should have skipped both");
        assertEq(total, 0, "and it moved nothing, at full cost");
    }

    /// With a converter wired, the same no-op batch also makes an external call per holder.
    function test_D04b_zeroMinPushPayoutCallsTheConverterWithZero() public {
        ThievingConverter thief = new ThievingConverter();
        Distributor d = _mk(0, 1, 1, address(reward), address(thief));

        d.setBalance(alice, 1_000e18);
        (uint256 sent,) = d.processBatch(10);
        assertEq(sent, 1, "a zero payout was routed through the converter and counted as sent");
        assertEq(pair.balanceOf(alice), 0);
    }

    // ===========================================================================================
    // D-05  The carry is credited to whoever holds shares at FLUSH time.
    // ===========================================================================================

    /// @dev `pendingPayouts` accumulates fees earned over a period, then `distribute` divides the
    ///      whole pile by `totalShares` as it stands at the moment the floor is finally cleared.
    ///      Nothing records who held during the accrual. A holder who arrives after the fact takes
    ///      it pro-rata, and can leave immediately afterwards because the correction freezes the
    ///      claim on the way out.
    function test_D05_theCarryIsTakenByWhoeverHoldsSharesWhenItIsFlushed() public {
        Distributor d = _mk(1, 1, FLOOR, address(0), address(0));

        // Alice is the only holder for the whole accrual window, but sits below the floor.
        d.setBalance(alice, FLOOR - 1);
        for (uint256 i = 0; i < 5; i++) {
            _fund(d, 100e18);
        }
        assertEq(d.pendingPayouts(), 500e18, "the whole window was carried");
        assertEq(d.withdrawableOf(alice), 0, "and alice, the only holder, is owed nothing");

        // Bob buys in after every one of those fees was already earned.
        d.setBalance(bob, 1_000_000e18);

        // Any subsequent fee - his own next trade will do - flushes the pile.
        _fund(d, 1e18);

        uint256 bobTook = d.withdrawableOf(bob);
        uint256 aliceGot = d.withdrawableOf(alice);
        assertGt(bobTook, 500e18, "bob did not capture the carried window");
        // Alice was the ONLY holder while all 500e18 was earned. She keeps ~0.1% of it, because
        // the split is taken on the share base as it stands at flush time, not at accrual time.
        assertLt(aliceGot, 1e18, "alice kept a meaningful share of the fees earned while she held");
        assertGt(bobTook / (aliceGot + 1), 900, "the capture ratio is not what it looks like");

        // And he can leave with it: selling out freezes, it does not forfeit.
        d.setBalance(bob, 0);
        assertEq(d.withdrawableOf(bob), bobTook, "the claim did not survive the exit");

        vm.prank(bob);
        d.withdraw();
        assertEq(pair.balanceOf(bob), bobTook, "bob walked with the carry");
    }

    /// The floor is re-entered every time the holder base shrinks below it, so this is not a
    /// launch-only window.
    function test_D05b_theCarryWindowReopensWheneverTheHolderBaseShrinks() public {
        Distributor d = _mk(1, 1, FLOOR, address(0), address(0));

        d.setBalance(alice, FLOOR * 10);
        _fund(d, 100e18);
        assertEq(d.pendingPayouts(), 0, "precondition: a real base takes its distribution");

        // Everyone exits.
        d.setBalance(alice, 0);
        assertEq(d.totalShares(), 0);

        _fund(d, 100e18);
        _fund(d, 100e18);
        assertEq(d.pendingPayouts(), 200e18, "carry reopened");

        // A fresh arrival takes all of it.
        d.setBalance(carol, FLOOR);
        _fund(d, 1e18);
        assertGt(d.withdrawableOf(carol), 200e18, "the reopened carry went to the newcomer");
    }

    // ===========================================================================================
    // D-06  Where `minSharesForDistribution` stops working, exactly.
    // ===========================================================================================

    /// @dev The worst legal squeeze the guard permits: a holder base sitting at EXACTLY the floor
    ///      (`supply / 1e6`) takes a distribution, and then a holder arrives with the rest of the
    ///      supply. `_setShares` evaluates `_magnifiedPayoutPerShare * delta` in checked
    ///      arithmetic, and that product is
    ///
    ///          (total * 2**128 / (supply/1e6)) * (supply - supply/1e6)
    ///        = total * 2**128 * (1e6 - 1)
    ///
    ///      which does not contain `supply` at all. The guard is a RATIO, so the boundary is a
    ///      constant in units of the PAIR CURRENCY: `total >= 2**128 / (1e6 - 1)` = 3.4028e32 wei.
    ///      This test locates it rather than asserting it.
    function test_D06_theGuardHoldsAndItsBoundaryIsSupplyIndependent() public {
        uint256 safeTotal = 3.0e32;
        uint256 breakTotal = 3.6e32;

        uint256[3] memory supplies = [uint256(1e18), SUPPLY, uint256(1e33)];
        for (uint256 i = 0; i < 3; i++) {
            (bool ok, uint256 aliceOwed, uint256 bobOwed) = _probe(supplies[i], safeTotal);
            assertTrue(ok, "the guard failed below its own boundary");
            assertApproxEqRel(aliceOwed, safeTotal, 1e13, "the squeezed holder lost her claim");
            assertEq(bobOwed, 0, "the late arrival was credited retroactively");

            (bool ok2,,) = _probe(supplies[i], breakTotal);
            assertFalse(ok2, "no failure at 3.6e32 - the boundary moved");
        }
    }

    /// Pin the boundary to two significant figures, from both sides.
    function test_D06b_theBoundaryIsJustAbove3point40e32PairWei() public {
        (bool below,,) = _probe(SUPPLY, 3.40e32);
        (bool above,,) = _probe(SUPPLY, 3.41e32);
        assertTrue(below, "3.40e32 should still be safe");
        assertFalse(above, "3.41e32 should already be past 2**256");
    }

    /// @dev External so the panic can be caught. The distributor's `shareToken` and `controller`
    ///      are both `address(this)`, and `this.probe...` keeps `msg.sender == address(this)`.
    function probeGuard(uint256 supply, uint256 total)
        external
        returns (uint256 aliceOwed, uint256 bobOwed)
    {
        uint256 floor_ = supply / 1e6;
        Distributor d = _mk(1, 1, floor_, address(0), address(0));

        d.setBalance(alice, floor_); // exactly the floor: the strongest legal denominator squeeze
        pair.mint(address(d), total);
        d.distribute(total);

        d.setBalance(bob, supply - floor_); // the whole rest of the supply arrives at once
        aliceOwed = d.withdrawableOf(alice);
        bobOwed = d.withdrawableOf(bob);
    }

    function _probe(uint256 supply, uint256 total)
        internal
        returns (bool ok, uint256 aliceOwed, uint256 bobOwed)
    {
        try this.probeGuard(supply, total) returns (uint256 a, uint256 b) {
            return (true, a, b);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev `_setShares` bounds `_magnifiedPayoutPerShare * DELTA`; `accumulativeOf` computes
    ///      `_magnifiedPayoutPerShare * BALANCE`. A balance assembled from several deltas that each
    ///      passed the checked multiply can therefore exceed what any single delta could, and the
    ///      panic then lands in `accumulativeOf` - which `processBatch` calls at Distributor.sol:305
    ///      BEFORE `_trySend`, outside the skip-a-bad-recipient protection.
    ///
    ///      That falsifies the stated invariant at Distributor.sol:21-23 ("one bad address must
    ///      never brick the queue") and the "always available" promise at :276. Reachable only with
    ///      a mis-set `minSharesForDistribution`, which `Launcher` never produces - but `Launcher`
    ///      is not the only way a `Distributor` gets deployed.
    function test_D06c_aHolderWhoseAccumulatorPanicsBricksTheQueueForEveryoneElse() public {
        Distributor weak = _mk(1, 1, 1, address(0), address(0));

        // Carol is an ordinary holder who did nothing wrong and shares the queue.
        weak.setBalance(carol, 1);
        weak.setBalance(alice, 1);

        uint256 huge = type(uint96).max;
        for (uint256 i = 0; i < 40; i++) {
            pair.mint(address(weak), huge);
            weak.distribute(huge);
        }

        // `_magnifiedPayoutPerShare`, reproduced from the same arithmetic the contract used.
        uint256 mps = 40 * ((huge * (2 ** 128)) / 2);
        // A delta whose product sits at ~0.9 * 2**256: legal for the checked multiply in
        // `_setShares`, and two of them put the BALANCE product past 2**256.
        uint256 step = ((type(uint256).max / 10) * 9) / mps;

        weak.setBalance(alice, 1 + step); // passes
        weak.setBalance(alice, 1 + 2 * step); // also passes

        assertGt(weak.shareOf(carol), 0, "precondition: a healthy holder exists");

        // Alice can no longer be read at all.
        vm.expectRevert(stdError.arithmeticError);
        weak.withdrawableOf(alice);

        // Her own pull is dead...
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        weak.withdraw();

        // ...and so is everyone else's push, because the batch reads her before it can skip her.
        vm.expectRevert(stdError.arithmeticError);
        weak.processBatch(10);
    }

    // ===========================================================================================
    // Sound: exclusion, `_update`, entitlement timing, double claims
    // ===========================================================================================

    function test_sound_excludedAccountsNeverAccrueAndCannotBeReAdded() public {
        Distributor d = _mkDefault();
        address pool = address(0x9004);
        d.setExcluded(pool, true);

        // Every shape of `setBalance` an excluded account can receive.
        d.setBalance(pool, 0);
        d.setBalance(pool, SUPPLY);
        d.setBalance(pool, 1);
        d.setBalance(pool, type(uint128).max);

        assertEq(d.shareOf(pool), 0, "an excluded account acquired shares");
        assertEq(d.totalShares(), 0, "an excluded account entered the denominator");
        assertEq(d.queueLength(), 0, "an excluded account entered the push queue");

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        assertEq(d.withdrawableOf(pool), 0, "an excluded account accrued");
        assertApproxEqAbs(d.withdrawableOf(alice), 100e18, 2, "the whole fee went to the real holder");
    }

    function test_sound_excludingAHolderFreezesTheirClaimAndRemovesTheirShares() public {
        Distributor d = _mkDefault();
        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 1_000e18);
        _fund(d, 200e18);

        uint256 frozen = d.withdrawableOf(alice);
        d.setExcluded(alice, true);

        assertEq(d.shareOf(alice), 0, "shares not removed");
        assertEq(d.totalShares(), 1_000e18, "denominator not corrected");
        assertEq(d.withdrawableOf(alice), frozen, "an already-earned claim was confiscated");

        _fund(d, 100e18);
        assertEq(d.withdrawableOf(alice), frozen, "an excluded account kept accruing");
        assertApproxEqAbs(d.withdrawableOf(bob), 200e18, 3, "the remaining holder takes the rest");
    }

    function test_sound_unExcludingGrantsNoRetroactiveEntitlement() public {
        Distributor d = _mkDefault();
        d.setBalance(alice, 1_000e18);
        d.setExcluded(alice, true);

        _fund(d, 100e18); // carried: nobody holds shares
        d.setBalance(bob, 1_000e18);
        _fund(d, 100e18);

        d.setExcluded(alice, false);
        assertEq(d.shareOf(alice), 0, "un-excluding must not resurrect shares by itself");
        assertEq(d.withdrawableOf(alice), 0, "nothing retroactive yet");

        // Her next balance update re-enters her at the CURRENT accumulator, not the old one.
        d.setBalance(alice, 1_000e18);
        assertEq(d.withdrawableOf(alice), 0, "re-entry back-dated her to before the distributions");

        _fund(d, 200e18);
        assertApproxEqAbs(d.withdrawableOf(alice), 100e18, 2, "and forward accrual is correct");
    }

    function test_sound_aMidDistributionTransferNeitherCreatesNorDestroysEntitlement() public {
        Distributor d = _mkDefault();
        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 1_000e18);
        _fund(d, 200e18);

        uint256 aliceOwed = d.withdrawableOf(alice);
        uint256 bobOwed = d.withdrawableOf(bob);

        // Alice hands her whole position to bob AFTER the distribution.
        d.setBalance(alice, 0);
        d.setBalance(bob, 2_000e18);

        assertEq(d.withdrawableOf(alice), aliceOwed, "selling forfeited an earned claim");
        assertEq(d.withdrawableOf(bob), bobOwed, "buying bought an already-earned claim");
        assertLe(aliceOwed + bobOwed, 200e18, "the pair conjured entitlement between them");
    }

    function test_sound_aClaimCannotBeTakenTwice() public {
        Distributor d = _mkDefault();
        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);

        vm.prank(alice);
        uint256 first = d.withdraw();

        vm.prank(alice);
        vm.expectRevert(Distributor.NothingToWithdraw.selector);
        d.withdraw();

        // And the push path cannot top it up either.
        (uint256 sent,) = d.processBatch(10);
        assertEq(sent, 0, "push paid an already-settled claim");
        assertEq(pair.balanceOf(alice), first, "paid twice");
    }

    /// @dev Neither path may pay a claim the other has already settled, in either order.
    function test_sound_pushAndPullCannotBothPayTheSameClaim() public {
        Distributor d = _mkDefault();
        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 1_000e18);
        _fund(d, 200e18);

        d.processBatch(1); // pays whoever the cursor is on
        vm.prank(alice);
        try d.withdraw() {} catch {}
        vm.prank(bob);
        try d.withdraw() {} catch {}
        d.processBatch(10);

        assertLe(d.totalWithdrawn(), d.totalDistributed(), "paid more than arrived");
        assertLe(pair.balanceOf(alice) + pair.balanceOf(bob), 200e18, "paid more than arrived");
        assertGe(pair.balanceOf(address(d)), 0);
    }

    /// @dev The carry must be folded in exactly once, however many times it is re-carried.
    function test_sound_theCarryIsNeverDoubleCounted() public {
        Distributor d = _mk(1, 1, FLOOR, address(0), address(0));

        for (uint256 i = 0; i < 6; i++) {
            _fund(d, 100e18); // no holders: carried
        }
        assertEq(d.pendingPayouts(), 600e18);
        assertEq(d.totalDistributed(), 0);

        d.setBalance(alice, FLOOR);
        _fund(d, 100e18);

        assertEq(d.pendingPayouts(), 0, "carry not released");
        assertEq(d.totalDistributed(), 700e18, "the carry was counted twice or lost");
        assertLe(d.withdrawableOf(alice), 700e18, "owed more than ever arrived");
        assertGe(pair.balanceOf(address(d)), d.withdrawableOf(alice), "insolvent");
    }

    function test_sound_cursorWrapsWithoutSkippingOrDoublePaying() public {
        Distributor d = _mkDefault();
        address[5] memory hs = [alice, bob, carol, address(0xD1), address(0xD2)];
        for (uint256 i = 0; i < 5; i++) {
            d.setBalance(hs[i], 1_000e18);
        }
        _fund(d, 500e18);

        // Walk two at a time, more than a full lap.
        uint256 paid;
        for (uint256 i = 0; i < 4; i++) {
            (uint256 sent,) = d.processBatch(2);
            paid += sent;
        }
        assertEq(paid, 5, "the cursor skipped or repaid somebody");

        for (uint256 i = 0; i < 5; i++) {
            assertEq(d.withdrawableOf(hs[i]), 0, "somebody was skipped");
            assertApproxEqAbs(pair.balanceOf(hs[i]), 100e18, 2, "somebody was paid twice");
        }
        assertLe(d.totalWithdrawn(), d.totalDistributed());
    }

    /// @dev `_dequeue` is swap-and-pop, so an exit moves the LAST queue entry into the hole. If the
    ///      cursor has already passed that slot, the moved account waits a full lap. It is a
    ///      fairness artefact, not a loss: nothing is skipped permanently and the pull path is
    ///      untouched. Pinned so the behaviour is deliberate rather than assumed.
    function test_sound_swapAndPopDelaysButNeverStrandsAMovedHolder() public {
        Distributor d = _mkDefault();
        address[4] memory hs = [alice, bob, carol, address(0xD1)];
        for (uint256 i = 0; i < 4; i++) {
            d.setBalance(hs[i], 1_000e18);
        }
        _fund(d, 400e18);

        d.processBatch(2); // pays queue[0], queue[1]; cursor lands on 2
        assertEq(d.cursor(), 2);

        // queue[0] exits, so queue[3] is swapped into slot 0 - behind the cursor.
        d.setBalance(hs[0], 0);
        assertEq(d.queueLength(), 3);
        assertEq(d.queueAt(0), hs[3], "swap-and-pop did not move the last entry into slot 0");

        // The moved holder is still owed, is still in the queue, and is paid on the next lap.
        assertGt(d.withdrawableOf(hs[3]), 0);
        d.processBatch(3);
        assertEq(d.withdrawableOf(hs[3]), 0, "the moved holder was stranded, not merely delayed");

        for (uint256 i = 0; i < 4; i++) {
            assertApproxEqAbs(pair.balanceOf(hs[i]), 100e18, 2, "somebody was skipped or repaid");
        }
    }

    // ===========================================================================================
    // Sound: `LaunchToken._update` edge shapes
    // ===========================================================================================

    struct World {
        LaunchToken token;
        Distributor dist;
    }

    address internal launcher = address(0x1AACE);
    address internal controller = address(0xC0FFEE);
    address internal poolManager = address(0x9004);

    function _world(bytes32 salt) internal returns (World memory w) {
        _deployLaunchTokenImpl();
        w.token = _cloneAndInit(
            salt,
            LaunchToken.InitParams({
                name_: "Audit",
                symbol_: "AUD",
                supply: SUPPLY,
                recipient: launcher,
                payoutToken: address(pair),
                rewardToken: address(0),
                converter: address(0),
                controller: controller,
                poolManager_: poolManager,
                maxWallet_: 0,
                minPushPayout: 1,
                minShareForQueue: 1e18,
                metadata: _defaultMetadata()
            })
        );
        w.dist = w.token.distributor();
        vm.prank(launcher);
        w.token.transfer(poolManager, SUPPLY);
    }

    function test_sound_selfTransferChangesNothing() public {
        World memory w = _world(bytes32(uint256(101)));
        vm.prank(poolManager);
        w.token.transfer(alice, 1_000e18);

        pair.mint(address(w.dist), 100e18);
        vm.prank(controller);
        w.dist.distribute(100e18);
        uint256 owed = w.dist.withdrawableOf(alice);
        uint256 qlen = w.dist.queueLength();

        vm.prank(alice);
        w.token.transfer(alice, 400e18); // self transfer

        assertEq(w.token.balanceOf(alice), 1_000e18, "balance moved");
        assertEq(w.dist.shareOf(alice), 1_000e18, "shares moved");
        assertEq(w.dist.totalShares(), 1_000e18, "denominator moved");
        assertEq(w.dist.withdrawableOf(alice), owed, "entitlement moved");
        assertEq(w.dist.queueLength(), qlen, "queue moved");
    }

    function test_sound_zeroValueTransferChangesNothingAndQueuesNobody() public {
        World memory w = _world(bytes32(uint256(102)));
        vm.prank(poolManager);
        w.token.transfer(alice, 1_000e18);
        uint256 qlen = w.dist.queueLength();

        vm.prank(alice);
        w.token.transfer(bob, 0);

        assertEq(w.dist.shareOf(bob), 0);
        assertEq(w.dist.queueLength(), qlen, "a zero-value transfer queued an empty account");
        assertEq(w.dist.totalShares(), 1_000e18);

        // Even from a stranger with nothing.
        vm.prank(carol);
        w.token.transfer(carol, 0);
        assertEq(w.dist.queueLength(), qlen, "a zero self-transfer queued an empty account");
    }

    function test_sound_transfersToAndFromExcludedAccountsKeepTheDenominatorHonest() public {
        World memory w = _world(bytes32(uint256(103)));

        vm.prank(poolManager);
        w.token.transfer(alice, 10_000e18); // buy, from an excluded account
        assertEq(w.dist.totalShares(), 10_000e18);

        vm.prank(alice);
        w.token.transfer(poolManager, 4_000e18); // sell, to an excluded account
        assertEq(w.dist.shareOf(poolManager), 0, "the pool accrued");
        assertEq(w.dist.totalShares(), 6_000e18, "denominator wrong after a sell");

        vm.prank(alice);
        w.token.transfer(address(0xdEaD), 1_000e18); // burn-ish, to an excluded account
        assertEq(w.dist.shareOf(address(0xdEaD)), 0, "the dead address accrued");
        assertEq(w.dist.totalShares(), 5_000e18, "denominator wrong after a burn");

        // And the launcher, which still holds nothing but is excluded, stays out.
        assertEq(w.dist.shareOf(launcher), 0);
        assertEq(
            w.dist.totalShares(), w.token.balanceOf(alice), "totalShares != sum of real holders"
        );
    }

    /// @dev The distributor excludes `address(this)` in its own constructor - which is the
    ///      DISTRIBUTOR, not the token. The `LaunchToken` address itself is not excluded.
    function test_sound_whichAddressesAreActuallyExcluded() public {
        World memory w = _world(bytes32(uint256(104)));
        assertTrue(w.dist.excluded(address(0)));
        assertTrue(w.dist.excluded(address(0xdEaD)));
        assertTrue(w.dist.excluded(address(w.dist)));
        assertTrue(w.dist.excluded(poolManager));
        assertTrue(w.dist.excluded(launcher));

        // Not excluded, and not excludable after the fact:
        assertFalse(w.dist.excluded(address(w.token)), "the token address is not excluded");
        assertFalse(w.dist.excluded(controller), "the hook is not excluded");
    }

    // ===========================================================================================
    // Sound: solvency fuzz with exclusion and queue churn in the mix
    // ===========================================================================================

    function testFuzz_sound_neverOwesMoreThanItHolds(
        uint96[6] memory balances,
        uint96[3] memory fees,
        uint8 excludePick
    ) public {
        Distributor d = _mk(1, 1e18, FLOOR, address(0), address(0));
        address[6] memory hs =
            [alice, bob, carol, address(0xD1), address(0xD2), address(0xD3)];

        address ex = hs[excludePick % 6];
        d.setExcluded(ex, true);

        for (uint256 i = 0; i < 6; i++) {
            d.setBalance(hs[i], uint256(balances[i]) * 1e9);
        }
        for (uint256 f = 0; f < 3; f++) {
            _fund(d, uint256(fees[f]));
            // Churn: everyone halves, then restores.
            for (uint256 i = 0; i < 6; i++) {
                d.setBalance(hs[i], (uint256(balances[i]) * 1e9) / 2);
            }
            d.processBatch(6);
            for (uint256 i = 0; i < 6; i++) {
                d.setBalance(hs[i], uint256(balances[i]) * 1e9);
            }
        }

        uint256 owed = d.pendingPayouts();
        uint256 sum;
        for (uint256 i = 0; i < 6; i++) {
            owed += d.withdrawableOf(hs[i]);
            sum += d.shareOf(hs[i]);
        }
        assertGe(pair.balanceOf(address(d)), owed, "the distributor owes more than it holds");
        assertEq(d.totalShares(), sum, "totalShares drifted");
        assertEq(d.shareOf(ex), 0, "an excluded account holds shares");
        assertLe(d.totalWithdrawn(), d.totalDistributed(), "paid out more than arrived");
    }
}
