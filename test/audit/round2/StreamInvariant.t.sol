// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Distributor} from "../../../src/Distributor.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @notice Round-2 invariants aimed at the STREAMING state machine specifically.
///
/// @dev `test/DistributorInvariant.t.sol` already fuzzes the contract, but it was written before
///      `flush()` existed and it has two blind spots this file closes:
///
///        1. **`flush()` is not in its handler at all.** The one brand-new permissionless entry
///           point in the contract is never called by the existing fuzzer.
///        2. **Its solvency invariant ignores unvested stream value.** It sums
///           `withdrawableOf + pendingPayouts`, which is what is claimable NOW. Money that `_arm`
///           has scheduled but not yet vested appears in neither term, so a bug that scheduled
///           more than the contract holds would pass it green until the stream matured.
///
///      `setExcluded` is also absent from the existing handler and is included here.
contract StreamHandler is Test {
    Distributor public dist;
    MockERC20 public payout;
    address[] public actors;

    /// Ghost: every base unit ever actually handed to the contract.
    uint256 public given;
    uint256 public flushCalls;
    uint256 public armCalls;
    /// Ghosts proving the campaign actually drove the machinery, not just the guards.
    uint256 public maxVested;
    uint256 public maxUnvested;
    uint256 public paidOut;

    modifier record() {
        _;
        uint256 v = dist.totalDistributed();
        if (v > maxVested) maxVested = v;
        uint64 fin = dist.streamFinish();
        uint256 u = fin > block.timestamp ? ((fin - block.timestamp) * dist.streamRate()) / 2 ** 128 : 0;
        if (u > maxUnvested) maxUnvested = u;
        if (dist.totalWithdrawn() > paidOut) paidOut = dist.totalWithdrawn();
    }

    constructor(Distributor _dist, MockERC20 _payout, address[] memory _actors) {
        dist = _dist;
        payout = _payout;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function distribute(uint96 amount) external record {
        uint256 amt = bound(uint256(amount), 0, 1e30);
        payout.mint(address(dist), amt);
        given += amt;
        armCalls++;
        dist.distribute(amt);
    }

    /// The whole point of this file: the permissionless re-arm, called by nobody privileged.
    function flush() external record {
        flushCalls++;
        armCalls++;
        dist.flush();
    }

    function setBalance(uint256 seed, uint96 newBalance) external record {
        dist.setBalance(_actor(seed), bound(uint256(newBalance), 0, 1e27));
    }

    function setExcluded(uint256 seed, bool isExcluded) external record {
        dist.setExcluded(_actor(seed), isExcluded);
    }

    function withdraw(uint256 seed) external record {
        address a = _actor(seed);
        vm.prank(a);
        dist.withdraw();
    }

    function processBatch(uint8 n) external record {
        dist.processBatch(uint256(n));
    }

    /// @dev Each handler action is its own call frame, so `block.timestamp` here is genuinely
    ///      re-read. Inside a single test function body it would be hoisted and the warp would
    ///      silently do nothing - see the note in `DividendAudit2.t.sol::_tick`.
    function warp(uint32 secs) external record {
        vm.warp(block.timestamp + bound(uint256(secs), 1, uint256(dist.STREAM_WINDOW()) * 2));
    }

    /// A short warp, so sequences also land inside a single block-time step where the sub-unit
    /// vesting branch is live.
    function tick(uint8 secs) external record {
        vm.warp(block.timestamp + bound(uint256(secs), 1, 24));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract StreamInvariantTest is Test {
    uint256 internal constant MAGNITUDE = 2 ** 128;

    Distributor internal dist;
    MockERC20 internal payout;
    StreamHandler internal handler;
    address[] internal actors;

    function setUp() public {
        payout = new MockERC20("Pair", "PAIR", 18);
        vm.warp(1_000_000);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        dist = new Distributor(
            predicted, // shareToken
            address(payout),
            predicted, // controller
            address(0),
            address(0),
            1, // minPushPayout
            1, // minShareForQueue
            1e21, // matches Launcher's `supply / 1e6` for a 1B 18-decimal launch
            address(0),
            address(0)
        );

        for (uint256 i = 0; i < 5; i++) {
            actors.push(address(uint160(0xA11CE + i)));
        }
        handler = new StreamHandler(dist, payout, actors);
        require(address(handler) == predicted, "handler address prediction failed");
        targetContract(address(handler));
    }

    function _unvestedAhead() internal view returns (uint256) {
        uint64 fin = dist.streamFinish();
        if (fin <= block.timestamp) return 0;
        return ((fin - block.timestamp) * dist.streamRate()) / MAGNITUDE;
    }

    /// Everything owed on ANY timescale - claimable now, carried, or still scheduled - must be
    /// covered by what the contract actually holds.
    function invariant_stream_solventIncludingUnvested() public view {
        uint256 owed = dist.pendingPayouts() + _unvestedAhead();
        for (uint256 i = 0; i < actors.length; i++) {
            owed += dist.withdrawableOf(actors[i]);
        }
        assertGe(payout.balanceOf(address(dist)), owed, "owes more than it holds, counting the stream");
    }

    /// Value can never be created: the contract may never owe more than was ever given to it,
    /// net of what it has already paid out.
    function invariant_stream_neverOwesMoreThanWasGiven() public view {
        uint256 owed = dist.pendingPayouts() + _unvestedAhead();
        for (uint256 i = 0; i < actors.length; i++) {
            owed += dist.withdrawableOf(actors[i]);
        }
        assertLe(owed + dist.totalWithdrawn(), handler.given(), "conjured value out of the stream");
    }

    /// @notice The anti-grief bound. `_arm`'s window is a convex combination of the time already
    ///         remaining and `STREAM_WINDOW`, so the finish line can never be pushed further than
    ///         one window ahead however many times `flush()` or `distribute()` is called.
    ///
    /// @dev Synthetix's `periodFinish = now + duration` fails this the moment the notifier is
    ///      permissionless, which ours is. This is the invariant that proves Yearn's weighted
    ///      average actually closed it.
    function invariant_stream_finishNeverMoreThanOneWindowAhead() public view {
        assertLe(
            uint256(dist.streamFinish()),
            block.timestamp + uint256(dist.STREAM_WINDOW()),
            "the finish line was pushed past one window"
        );
    }

    /// `lastCheckpoint` may never run ahead of the clock, or `_perShareNow` silently freezes.
    function invariant_stream_checkpointNeverInTheFuture() public view {
        assertLe(uint256(dist.lastCheckpoint()), block.timestamp, "the checkpoint is in the future");
    }

    function invariant_stream_withdrawnNeverExceedsDistributed() public view {
        assertLe(dist.totalWithdrawn(), dist.totalDistributed(), "paid out more than vested");
    }

    function invariant_stream_totalSharesEqualsSumOfShares() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += dist.shareOf(actors[i]);
        }
        assertEq(dist.totalShares(), sum, "totalShares drifted from the sum of balances");
    }

    /// @notice Negative control on the harness itself. If the fuzzer never reaches `flush()` or
    ///         never arms a stream, every invariant above holds vacuously over a dead contract.
    /// @dev Must be `afterInvariant`, not an `invariant_`: Foundry evaluates `invariant_` once
    ///      during setup as well, before any handler call has run, where these are trivially false.
    /// @notice Negative control on the harness. Invariants over a contract that never armed a
    ///         stream, never vested and never paid anybody hold trivially and prove nothing.
    ///
    /// @dev Not an `afterInvariant` hook: Foundry resets state between invariant RUNS and calls
    ///      the hook at the end of each one, so a short run legitimately ends with nothing armed
    ///      and the hook fails on a healthy contract. This drives the same handler through a
    ///      scripted sequence instead, which is what actually proves the actions are wired up.
    function test_control_theHandlerCanDriveTheWholeStream() public {
        handler.setBalance(0, uint96(5e26));
        handler.setBalance(1, uint96(5e26));
        handler.distribute(uint96(1e18));
        assertGt(handler.maxUnvested(), 0, "handler.distribute never armed a stream");

        handler.warp(uint32(40_000));
        // The view accrues on the clock alone; the STORED accumulator needs a state-touching call.
        assertGt(dist.withdrawableOf(actors[0]), 0, "handler.warp never let anything vest");

        handler.flush();
        assertEq(handler.flushCalls(), 1, "handler.flush is not wired up");
        assertGt(handler.maxVested(), 0, "no call ever folded vested time into the accumulator");

        handler.processBatch(5);
        assertGt(handler.paidOut(), 0, "handler.processBatch never paid anybody");

        handler.tick(24); // let a little more vest, so the pull path has something to pay
        handler.withdraw(0);
        handler.setExcluded(1, true);
        assertEq(dist.shareOf(actors[1]), 0, "handler.setExcluded is not wired up");

        // And the invariant helpers themselves are non-trivial at this point.
        assertGt(_unvestedAhead(), 0, "the unvested term is dead, so the solvency check is weak");
        invariant_stream_solventIncludingUnvested();
        invariant_stream_neverOwesMoreThanWasGiven();
        invariant_stream_finishNeverMoreThanOneWindowAhead();
    }
}
