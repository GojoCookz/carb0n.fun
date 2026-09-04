// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Distributor} from "./Distributor.sol";

/// @title VestingVault
/// @notice Holds a creator's opening buy and releases it on a schedule the chain announced at
///         birth.
///
/// @dev **The point is the disclosure, not the lock.** `Launcher` emits `VaultCreated` inside the
///      launch transaction itself, so the schedule is public from the block the token exists. An
///      indexer reading launches cannot miss it and a buyer reading the token page sees exactly
///      what is held back and until when, before deciding anything.
///
///      **The honest trade, stated plainly: a vested dev buy is UNCAPPED.** The 10% cap applies
///      only to the unvested path - tokens paid straight to the creator's wallet. Choose a lock
///      and the whole buy, whatever its size, routes here. The cap protected buyers from an
///      undisclosed large position; the vault replaces that protection with a disclosed one. A
///      vested launch is not automatically safer than a capped one, it is *differently* safe.
///
///      Three rules make the disclosure worth anything:
///
///        - **Extend, never shorten.** The beneficiary may lengthen a cliff or a duration. Any
///          change that would shorten one reverts. A schedule announced at launch can only ever
///          become more restrictive.
///        - **Add, never subtract.** More tokens can be locked under new schedules. Nothing can
///          be pulled out early, by anyone, including us - there is no admin on this contract.
///        - **A 7-day floor.** Shorter than that is theatre.
///
///      Locked tokens are still held tokens, so a vault on a dividend-paying launch accrues
///      holder rewards like any other holder. The beneficiary can claim that stream, or give it
///      away permanently with `renounceAccrual`.
contract VestingVault {
    using SafeERC20 for IERC20;

    /// @param total    tokens locked under this schedule
    /// @param released how much has already been sent to the beneficiary
    /// @param start    when vesting begins - launch time, for a dev buy
    /// @param cliff    seconds after `start` before anything unlocks at all
    /// @param duration seconds from `start` over which the whole amount vests linearly
    struct Schedule {
        uint128 total;
        uint128 released;
        uint64 start;
        uint64 cliff;
        uint64 duration;
    }

    /// @notice Shortest schedule the contract will accept.
    uint64 public constant MIN_DURATION = 7 days;
    /// @notice Cap on schedules per vault, so `releasable` can never be made to run out of gas.
    uint256 public constant MAX_SCHEDULES = 32;

    /// @notice The token being vested.
    address public immutable token;
    /// @notice The launch's dividend ledger, so the vault can claim what its locked supply earns.
    address public immutable distributor;
    /// @notice Whoever deployed this vault - the `Launcher`, in every real launch.
    ///
    /// @dev Captured from `msg.sender` in the constructor rather than passed in, because the
    ///      launcher creates the vault mid-`launch` and there is no other candidate. It exists
    ///      solely so `addSchedule` can accept the launch's own opening lock without also
    ///      accepting a stranger's.
    address public immutable launcher;

    /// @notice Who receives the tokens as they vest. Transferable - a project outliving the
    ///         wallet that founded it is a normal thing to want.
    address public beneficiary;

    /// @notice Once true the locked supply's dividend claim belongs to the other holders, forever.
    bool public accrualRenounced;

    Schedule[] private _schedules;

    event ScheduleAdded(uint256 indexed index, uint256 total, uint64 start, uint64 cliff, uint64 duration);
    event ScheduleExtended(uint256 indexed index, uint64 cliff, uint64 duration);
    event Released(address indexed to, uint256 amount);
    event BeneficiaryTransferred(address indexed from, address indexed to);
    event AccrualRenounced();

    error OnlyBeneficiary();
    error ZeroAddress();
    error DurationTooShort();
    error CliffExceedsDuration();
    error CannotShorten();
    error TooManySchedules();
    error NothingToRelease();
    error AlreadyRenounced();
    error OnlyLauncherOrBeneficiary();
    error StartInTheFuture(uint64 given, uint64 now_);
    error AmountExceedsUnscheduled(uint256 given, uint256 available);

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary) revert OnlyBeneficiary();
        _;
    }

    constructor(address _token, address _distributor, address _beneficiary) {
        if (_token == address(0) || _beneficiary == address(0)) revert ZeroAddress();
        token = _token;
        distributor = _distributor;
        beneficiary = _beneficiary;
        launcher = msg.sender;
    }

    // -------------------------------------------------------------------------------------------
    // Locking
    // -------------------------------------------------------------------------------------------

    /// @notice Record a schedule over tokens this vault already holds.
    ///
    /// @dev **The launcher or the beneficiary, and `start` may not be in the future.** This used
    ///      to be fully permissionless with an unbounded caller-chosen `start`, justified by "the
    ///      launcher calls it during the launch transaction, before a beneficiary could possibly
    ///      front-run anything". That is true of the launch and of nothing else: the contract also
    ///      advertises top-ups, and every top-up after the launch is transfer-then-schedule with
    ///      an open window in between. Two abuses lived in that window, both measured:
    ///
    ///        - **Permanent lock.** A stranger front-ran a 1,000-token top-up with
    ///          `start = now + 100 years`. Fifty years later it had not begun to vest, and
    ///          nothing could undo it - `extend` takes only `cliff` and `duration` and refuses to
    ///          shorten either, so `start` is unreachable once written.
    ///        - **Slot exhaustion.** 31 schedules over 1 wei each filled `MAX_SCHEDULES`, and the
    ///          beneficiary could never lock anything again. Cost: 31 wei plus gas.
    ///
    ///      `start <= block.timestamp` is what closes the first one for good. A lock that should
    ///      begin later is expressed as a CLIFF, which `extend` can lengthen and which is visible
    ///      in `scheduleAt`, rather than as a start date nothing can ever move.
    ///
    ///      **Over-large amounts revert rather than trim.** Silent trimming is banned across this
    ///      codebase (`Launcher` reverts `DevBuyTooLarge` rather than clamping a dev buy) and this
    ///      was the one place it was not applied: asking to lock more than is present produced a
    ///      schedule for a different number, with no revert and only a well-formed event to notice
    ///      it by.
    function addSchedule(uint128 amount, uint64 start, uint64 cliff, uint64 duration) external {
        if (msg.sender != launcher && msg.sender != beneficiary) {
            revert OnlyLauncherOrBeneficiary();
        }
        if (start > block.timestamp) revert StartInTheFuture(start, uint64(block.timestamp));
        if (duration < MIN_DURATION) revert DurationTooShort();
        if (cliff > duration) revert CliffExceedsDuration();
        if (_schedules.length >= MAX_SCHEDULES) revert TooManySchedules();

        // Never schedule more than is actually here, or `release` would promise tokens the vault
        // cannot pay and the last beneficiary out would eat the shortfall.
        uint256 unscheduled = IERC20(token).balanceOf(address(this)) - _totalUnreleased();
        if (amount > unscheduled) revert AmountExceedsUnscheduled(amount, unscheduled);
        if (amount == 0) revert NothingToRelease();

        _schedules.push(
            Schedule({total: amount, released: 0, start: start, cliff: cliff, duration: duration})
        );

        emit ScheduleAdded(_schedules.length - 1, amount, start, cliff, duration);
    }

    /// @notice Lengthen a schedule. It can never be shortened, by anyone.
    function extend(uint256 index, uint64 newCliff, uint64 newDuration) external onlyBeneficiary {
        Schedule storage s = _schedules[index];
        if (newCliff < s.cliff || newDuration < s.duration) revert CannotShorten();
        if (newCliff > newDuration) revert CliffExceedsDuration();

        s.cliff = newCliff;
        s.duration = newDuration;

        emit ScheduleExtended(index, newCliff, newDuration);
    }

    // -------------------------------------------------------------------------------------------
    // Releasing
    // -------------------------------------------------------------------------------------------

    /// @notice Send everything that has vested to the beneficiary.
    /// @dev Callable by anyone. The beneficiary is the only possible recipient, so a stranger
    ///      paying the gas to move somebody else's vested tokens is a favour, not an attack.
    function release() external returns (uint256 sent) {
        uint256 n = _schedules.length;
        for (uint256 i = 0; i < n; ++i) {
            Schedule storage s = _schedules[i];
            uint256 vested = _vestedAt(s, block.timestamp);
            if (vested > s.released) {
                uint256 amount = vested - s.released;
                s.released = uint128(vested);
                sent += amount;
            }
        }

        if (sent == 0) revert NothingToRelease();
        IERC20(token).safeTransfer(beneficiary, sent);
        emit Released(beneficiary, sent);
    }

    /// @notice What `release()` would send right now.
    function releasable() external view returns (uint256 total) {
        uint256 n = _schedules.length;
        for (uint256 i = 0; i < n; ++i) {
            Schedule storage s = _schedules[i];
            uint256 vested = _vestedAt(s, block.timestamp);
            if (vested > s.released) total += vested - s.released;
        }
    }

    /// @dev Linear from `start + cliff`, nothing before it, everything after `start + duration`.
    function _vestedAt(Schedule storage s, uint256 at) internal view returns (uint256) {
        if (at < uint256(s.start) + s.cliff) return 0;
        if (at >= uint256(s.start) + s.duration) return s.total;
        return (uint256(s.total) * (at - s.start)) / s.duration;
    }

    function _totalUnreleased() internal view returns (uint256 total) {
        uint256 n = _schedules.length;
        for (uint256 i = 0; i < n; ++i) {
            total += _schedules[i].total - _schedules[i].released;
        }
    }

    // -------------------------------------------------------------------------------------------
    // Dividends on locked supply
    // -------------------------------------------------------------------------------------------

    /// @notice Pull whatever the locked supply has earned and forward it to the beneficiary.
    /// @dev The locked principal never moves early. Only the dividend stream is claimed.
    /// @dev **Forwards the whole balance, and pulls only if there is something to pull.**
    ///
    ///      The previous version measured a DELTA around an unconditional `withdraw()`, and both
    ///      halves of that were wrong. `Distributor.processBatch` is permissionless and this vault
    ///      is an ordinary holder in its queue, so anyone could PUSH a payout here; that money
    ///      landed inside `before`, was therefore invisible to the delta, and `withdraw()` then
    ///      reverted `NothingToWithdraw` because the push had already cleared the claim - taking
    ///      the whole call down. Every later claim forwarded only its own delta and stepped over
    ///      the stranded pile forever. The vault has no owner and no other transfer of this token,
    ///      so it was unrecoverable, and an honest keeper doing exactly what the distributor's
    ///      docs recommend was enough to cause it.
    function claimDividends() external onlyBeneficiary returns (uint256 amount) {
        if (accrualRenounced) revert AlreadyRenounced();

        Distributor d = Distributor(distributor);
        address payout = d.payoutToken();

        // Pull only when there is a claim. A push may already have settled it.
        if (d.withdrawableOf(address(this)) != 0) d.withdraw();

        // Forward everything held, however it arrived - pulled now, or pushed at any point since.
        amount = _forward(payout);

        // A creator may have chosen to be paid in something other than the pair currency, in
        // which case the converter sends THAT here instead and the pair balance stays zero.
        address reward = d.rewardToken();
        if (reward != payout) amount += _forward(reward);
    }

    /// @dev **Never forwards the locked principal.** `token` is the vested asset and the guard is
    ///      the only thing standing between "sweep the dividends out" and "empty the vault early",
    ///      which is the entire promise this contract exists to make.
    function _forward(address asset) internal returns (uint256 amount) {
        if (asset == address(0) || asset == token) return 0;
        amount = IERC20(asset).balanceOf(address(this));
        if (amount != 0) IERC20(asset).safeTransfer(beneficiary, amount);
    }

    /// @notice Give the locked supply's dividend claim to the other holders. **One way.**
    /// @dev There is no un-renounce, not for the beneficiary and not for the platform. A founder
    ///      who wants to signal that their locked bag will not keep earning has to be able to make
    ///      that irreversible, or it is not a signal.
    ///
    /// @dev **It now does what it says.** The previous version set this flag and nothing else: the
    ///      vault's shares stayed in `totalShares`, so the other holders' per-share rate did not
    ///      move by one wei and the renounced stream was DESTROYED rather than redistributed -
    ///      the exact opposite of the sentence above it. Worse, `processBatch` kept pushing real
    ///      pair currency into a vault whose only exit (`claimDividends`) now reverted
    ///      `AlreadyRenounced`, so the money was stranded on top of being lost.
    ///
    ///      `Distributor.renounceAccrual` is the reachable, self-only, one-way exclusion that
    ///      makes the promise true: the vault's shares leave the denominator, everybody else's
    ///      rate genuinely rises, and nothing is ever pushed here again.
    ///      **What has ALREADY been earned is paid out first, and that is not generosity - it is
    ///      the only way to leave no residue.** Renouncing removes the vault's shares but not its
    ///      outstanding claim, and after renouncing `claimDividends` reverts `AlreadyRenounced`
    ///      forever, so anything still owed at that instant would be stranded on the distributor
    ///      with no path out. The signal is about the FUTURE; the past is settled on the way
    ///      through.
    function renounceAccrual() external onlyBeneficiary {
        if (accrualRenounced) revert AlreadyRenounced();
        accrualRenounced = true;

        if (distributor != address(0)) {
            Distributor d = Distributor(distributor);
            address payout = d.payoutToken();
            if (d.withdrawableOf(address(this)) != 0) d.withdraw();
            _forward(payout);
            address reward = d.rewardToken();
            if (reward != payout) _forward(reward);
            d.renounceAccrual();
        }

        emit AccrualRenounced();
    }

    // -------------------------------------------------------------------------------------------
    // The seat
    // -------------------------------------------------------------------------------------------

    function transferBeneficiary(address to) external onlyBeneficiary {
        if (to == address(0)) revert ZeroAddress();
        emit BeneficiaryTransferred(beneficiary, to);
        beneficiary = to;
    }

    // -------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------

    function schedules() external view returns (Schedule[] memory) {
        return _schedules;
    }

    function scheduleCount() external view returns (uint256) {
        return _schedules.length;
    }

    function scheduleAt(uint256 i) external view returns (Schedule memory) {
        return _schedules[i];
    }

    /// @notice Total still locked across every schedule.
    function locked() external view returns (uint256) {
        return _totalUnreleased();
    }
}
