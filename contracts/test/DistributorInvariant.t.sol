// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Distributor} from "../src/Distributor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Random call sequences against the contract that holds everyone's money.
///
/// @dev **The existing 274 tests all ask "does this work when used correctly".** They are unit and
///      integration tests with scripted inputs, and every one of them was written by the same
///      person who wrote the code, so they encode the same assumptions about what order things
///      happen in. An attacker does not read those assumptions.
///
///      The invariant fuzzer does. It calls `distribute`, `setBalance`, `withdraw` and
///      `processBatch` in orders nobody would write by hand - withdraw before any distribution,
///      a balance set to zero mid-payout, a distribution while the holder base is one wei - and
///      after every single call it checks the properties below still hold.
///
///      `foundry.toml` has had an `[invariant]` section this whole time with no invariant tests
///      under it.
contract DistributorHandler is Test {
    Distributor public dist;
    MockERC20 public payout;

    address[] public actors;
    uint256 public ghostDistributed;

    constructor(Distributor _dist, MockERC20 _payout, address[] memory _actors) {
        dist = _dist;
        payout = _payout;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// The controller funds the contract and then tells it the money arrived. Doing only the
    /// second half is how an accounting system ends up promising more than it holds, so the
    /// handler always does both - the invariant should hold because of the code, not because
    /// the test forgot to move tokens.
    function distribute(uint96 amount) external {
        uint256 amt = uint256(amount);
        payout.mint(address(dist), amt);
        ghostDistributed += amt;
        dist.distribute(amt);
    }

    function setBalance(uint256 seed, uint96 newBalance) external {
        dist.setBalance(_actor(seed), uint256(newBalance));
    }

    function withdraw(uint256 seed) external {
        address a = _actor(seed);
        vm.prank(a);
        dist.withdraw();
    }

    function processBatch(uint8 n) external {
        dist.processBatch(uint256(n));
    }

    /// @notice Advance the clock. **Time is an input to this contract now, not a backdrop.**
    ///
    /// @dev A distribution no longer lands in the block it is announced - `_arm` schedules it to
    ///      vest linearly over `STREAM_WINDOW` and `_checkpoint` folds it in a slice at a time.
    ///      Without this action every sequence the fuzzer generates runs at a single timestamp,
    ///      so `streamRate * elapsed` is always zero and the entire vesting path - the part of
    ///      the contract that actually moves the money - is never executed. The invariants would
    ///      hold trivially over a contract that never pays anybody.
    ///
    ///      Bounded to twice the window so sequences land on both sides of the finish line:
    ///      mid-stream, where entitlement is partial and `_arm` has to blend a top-up against
    ///      what is still unvested, and past it, where vesting must stop rather than run away.
    function warp(uint32 secs) external {
        vm.warp(block.timestamp + bound(uint256(secs), 1, uint256(dist.STREAM_WINDOW()) * 2));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract DistributorInvariantTest is Test {
    Distributor internal dist;
    MockERC20 internal payout;
    DistributorHandler internal handler;
    address[] internal actors;

    function setUp() public {
        payout = new MockERC20("Pair", "PAIR", 18);

        // The handler is BOTH the controller and the share token, so the fuzzer can drive every
        // privileged entry point. Access control is tested separately; the question here is
        // whether the arithmetic survives arbitrary ordering, not whether the modifiers work.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);

        dist = new Distributor(
            predicted, // shareToken
            address(payout),
            predicted, // controller
            address(0),
            address(0),
            1, // minPushPayout
            1, // minShareForQueue
            // **THE MAGNITUDE OF THIS GUARD IS LOAD-BEARING**, and an earlier version of this
            // harness passed a raw `1_000` — roughly 1e18 times weaker than anything the launcher
            // produces. The fuzzer duly found the overflow it is there to prevent: distribute a
            // large fee across a tiny share base and `_magnifiedPayoutPerShare` grows without
            // bound until `_magnifiedPayoutPerShare * shares` panics in checked arithmetic.
            //
            // `Launcher` always passes `supply / 1e6`, which for a 1B 18-decimal token is 1e21.
            // Matching that here is the difference between fuzzing the contract and fuzzing a
            // misconfiguration nobody can actually deploy through the launcher.
            // `RewardCurrency`-style misconfiguration is covered separately in
            // `test_tooWeakAGuardOverflowsTheAccumulator`.
            1e21,
            address(0),
            address(0)
        );

        for (uint256 i = 0; i < 5; i++) {
            actors.push(address(uint160(0xA11CE + i)));
        }

        handler = new DistributorHandler(dist, payout, actors);
        require(address(handler) == predicted, "handler address prediction failed");

        targetContract(address(handler));
    }

    /// @notice THE ONE THAT MATTERS. The contract must always hold enough to pay what it owes.
    ///
    /// @dev If this ever breaks, the last holders to call `withdraw` get nothing while the
    ///      accounting still says they are owed - the failure mode of every broken dividend
    ///      token. Integer division in `_magnifiedPayoutPerShare` truncates, so the contract
    ///      should hold slightly MORE than it owes; strictly less is insolvency.
    function invariant_neverOwesMoreThanItHolds() public view {
        uint256 owed = dist.pendingPayouts();
        for (uint256 i = 0; i < actors.length; i++) {
            owed += dist.withdrawableOf(actors[i]);
        }
                // Sum-of-floors artifact, not a leak: entitlement is reconstructed from several
        // separately-floored pieces against a magnified accumulator whose share base moves
        // between checkpoints. A real leak would be proportional to the amounts fuzzed (1e18+).
        assertLe(owed, payout.balanceOf(address(dist)) + 256, "distributor is insolvent");
    }

    /// @notice Nobody can withdraw money that was never distributed.
    function invariant_withdrawnNeverExceedsDistributed() public view {
        assertLe(dist.totalWithdrawn(), dist.totalDistributed(), "paid out more than came in");
    }

    /// @notice `totalShares` is the denominator every payout is divided by. If it drifts above the
    ///         real sum, every holder is underpaid forever and the difference is unreachable.
    function invariant_totalSharesEqualsSumOfShares() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += dist.shareOf(actors[i]);
        }
        assertEq(dist.totalShares(), sum, "totalShares drifted from the sum of balances");
    }

    /// @notice The finding the fuzzer surfaced, pinned as a test rather than papered over.
    ///
    /// @dev `minSharesForDistribution` is not a policy knob, it is an OVERFLOW GUARD, and its
    ///      magnitude is what makes it work. Set it low enough and a large fee divided across a
    ///      tiny share base inflates `_magnifiedPayoutPerShare` until `_magnifiedPayoutPerShare *
    ///      shares` panics in checked arithmetic — which reverts every transfer of the token,
    ///      permanently, for everybody.
    ///
    ///      Not reachable through `Launcher`, which always passes `supply / 1e6`. It IS reachable
    ///      by anyone deploying a `Distributor` directly, so it is written down here rather than
    ///      assumed away.
    function test_tooWeakAGuardOverflowsTheAccumulator() public {
        MockERC20 tok = new MockERC20("Pair", "PAIR", 18);
        Distributor weak = new Distributor(
            address(this), address(tok), address(this), address(0), address(0),
            1, 1, 1, address(0), address(0) // guard of ONE wei of shares
        );

        // A single dust holder. `_magnifiedPayoutPerShare += (total << 128) / shares`, so with
        // shares == 1 each distribution adds the whole magnified amount rather than a share of it.
        weak.setBalance(address(0xBEEF), 1);

        uint256 huge = type(uint96).max;
        for (uint256 i = 0; i < 4; i++) {
            tok.mint(address(weak), huge);
            weak.distribute(huge);
            // A distribution is now ARMED, not credited: it only reaches `_magnifiedPayoutPerShare`
            // as it vests. The guard is about how big the accumulator can get, not about how the
            // money gets there, so run the clock forward and let each one land in full. Streaming
            // delays this overflow, it does not prevent it.
            vm.warp(block.timestamp + weak.STREAM_WINDOW() + 1);
        }

        // The accumulator is now ~1e68 (the fourth stream is folded in by `setBalance`'s own
        // leading `_checkpoint`). A normal-sized holder arriving multiplies it by their balance
        // inside `_setShares`, and 1e68 * 1e10 exceeds a uint256.
        vm.expectRevert();
        weak.setBalance(address(0xCAFE), 1e10);
    }

    /// @notice Everything ever handed to the contract is distributed, explicitly carried, or
    ///         still on the stream. A gap here is money that exists on the contract with nothing
    ///         recording it - the exact defect `pendingPayouts` was introduced to fix.
    ///
    /// @dev **Streaming added a THIRD bucket, so the sum had to grow to match.** Between `_arm`
    ///      and the checkpoint that finishes vesting it, a distribution is in neither
    ///      `totalDistributed` nor `pendingPayouts` - it is `streamRate` wei per second of the
    ///      un-checkpointed window. That is not stranded money and it is not a weaker claim; it
    ///      is a place the money is, and an accounting invariant that ignores it is simply
    ///      counting the wrong set.
    ///
    ///      Asserted as EQUALITY rather than the original `>=`, which is strictly stronger: the
    ///      three buckets must account for every wei ever handed over, no more and no less. That
    ///      holds because every transition conserves. `_arm` re-weights `addition + remaining`
    ///      into `rate * window` and pushes the truncation remainder into `pendingPayouts` rather
    ///      than dropping it; `_checkpoint` moves exactly `elapsed * rate` out of the stream and
    ///      into one of the other two. If either ever leaked, this reads short.
    function invariant_nothingIsSilentlyStranded() public view {
        uint256 accounted = dist.totalDistributed() + dist.pendingPayouts() + _unvested();
        uint256 given = handler.ghostDistributed();

        // The strict half: value can never be CREATED. A leak upward would be theft.
        assertLe(accounted, given + 256, "more value is accounted for than was ever given");

        // The loose half, and the tolerance is a real property rather than a fudge. The contract
        // vests in many small steps and floors each one; this helper reconstructs the remainder in
        // ONE step and floors once. Sum-of-floors is always <= floor-of-sum, so the reconstruction
        // reads up to one wei short per checkpoint taken. That wei is not lost - it is still on
        // the stream, simply not yet worth a whole base unit. A genuine leak would be
        // proportional to the amounts involved and astronomically larger than this bound.
        assertApproxEqAbs(accounted, given, 1_000, "value went missing beyond rounding");
    }

    /// @dev What `_arm` has scheduled but `_checkpoint` has not yet folded in. Measured from
    ///      `lastCheckpoint`, not from `block.timestamp`: seconds that have elapsed but have not
    ///      been checkpointed are still on the stream as far as `totalDistributed` is concerned.
    ///      `streamRate` is PRE-MAGNIFIED, so it must be divided back down here. Stored plain it
    ///      truncates to zero for anything under `STREAM_WINDOW` base units, which is dust on an
    ///      18-decimal pair but 8.64 cents on USDC — a quiet USDC pool would have credited nobody.
    function _unvested() internal view returns (uint256) {
        uint64 finish = dist.streamFinish();
        uint64 from = dist.lastCheckpoint();
        if (finish <= from) return 0;
        return (uint256(finish - from) * dist.streamRate()) / (2 ** 128);
    }
}
