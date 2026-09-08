// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IRewardConverter} from "./Distributor.sol";

/// @dev The one question this contract ever asks the registry. Declared minimally here, in the
///      style of `IRewardConverter` in `Distributor.sol`, so this file depends on a two-line
///      interface rather than on `PairRegistry`'s oracle machinery. The registry is the SAME
///      address allowlist that gates launches: an asset that may not be launched against may not
///      be elected as a payout either, which is what inherits the no-impostor policy documented at
///      the top of `PairRegistry.sol` (361 fake GMEs, one real one).
interface IPairRegistry {
    function isApproved(address pair) external view returns (bool);
}

/// @title MultiRewardDistributor
/// @notice Pays holders of one launch in a BASKET of currencies - up to four creator-chosen
///         weighted slots plus exactly one slot each holder points wherever they like - instead of
///         the single `rewardToken` `Distributor` supports.
///
/// @dev **This is `Distributor` with the delivery leg widened, and nothing else changed.** The
///      accounting is byte-for-byte the same design: magnified-per-share accumulator, O(1) on
///      every transfer and every distribution, streaming entitlement over `STREAM_WINDOW`,
///      pull-first payout with a bounded permissionless push. Read `Distributor.sol` for the full
///      history of why each of those pieces is shaped the way it is; the docstrings here cover
///      only what is NEW.
///
///      **Accounting stays in `payoutToken`. Slots only change what the final transfer converts
///      into.** Every number in the ledger - the accumulator, `_withdrawn`, `totalDistributed` -
///      is denominated in the pair currency, because that is what fees arrive in and what this
///      contract actually holds. A slot is a delivery instruction, applied at the last possible
///      moment, and a slot whose conversion fails or returns zero pays its share in `payoutToken`
///      instead - never zero, never a revert of the claim. Converting on the way IN was rejected
///      for `Distributor` (the ledger would be denominated in a token the contract does not hold
///      the moment a route fails) and a basket multiplies that failure by the slot count, so the
///      rule matters MORE here, not less.
///
///      **The holder-elected slot is the idea recorded in `audit/11-external-bsc-contracts.md`
///      §7, built to that file's spec instead of to the implementation it audited.** The BSC
///      lineage's `setPersonalReward` took any address from any caller and then handed that
///      address a callback in the middle of a claim whose guards were written AFTER the tokens
///      left (§3a + §3b = drain). Here the election is validated against the pair registry, so an
///      attacker cannot point it at a contract they control; the claim path writes every state
///      change BEFORE any external call; and both payout entry points carry the reentrancy guard
///      that `audit/09-remediation.md` R2-04 proved is load-bearing for the shared allowance slot.
///
///      **The creator seat follows BaseStonk's basket-controller rules exactly**
///      (`audit/14-basestonk-reference.md` §3a): the controller can re-weight, can swap slot
///      assets (registry-validated), can hand the seat over, can renounce one way - and can NEVER
///      change the total rewards percentage, because that number is not stored here at all. It
///      lives in the hook; this contract just receives whatever `distribute` delivers.
///
///      **Bounded work, everywhere** (`audit/13-marscoin-reference.md`): the only loops in this
///      contract are over the fixed slot array (`MAX_SLOTS`, compile-time capped) and the
///      keeper's caller-bounded `processBatch`. No path iterates holders.
///
///      **Chain-agnostic by construction.** No `block.chainid`, no hardcoded addresses; every
///      dependency arrives through the constructor, so the same bytecode deploys identically on
///      Ethereum L1 and Robinhood Chain 4663.
contract MultiRewardDistributor is ReentrancyGuardTransient {
    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint256 internal constant BPS = 10_000;

    /// @notice Hard cap on the basket, INCLUDING the holder slot.
    ///
    /// @dev Five, not BaseStonk's ten, because every slot is a potential converter call inside a
    ///      claim and `processBatch` multiplies that by its batch size. The cap is what makes
    ///      "bounded payout work" a compile-time property instead of a configuration hope.
    uint256 public constant MAX_SLOTS = 5;
    uint256 public constant MAX_CREATOR_SLOTS = MAX_SLOTS - 1;

    /// @notice One creator-chosen basket entry: what to convert into, and how much of each payout.
    /// @dev Weights are bps of the WHOLE payout. Creator weights plus `holderSlotBps` must sum to
    ///      exactly `BPS` - enforced on every mutation, so the invariant can never drift.
    struct Slot {
        address token;
        uint16 weightBps;
    }

    // -------------------------------------------------------------------------------------------
    // Immutables - everything that must never move after birth
    // -------------------------------------------------------------------------------------------

    /// @notice The launch token whose holders are paid.
    address public immutable shareToken;
    /// @notice The currency this contract HOLDS and accounts in - always the pair currency.
    address public immutable payoutToken;
    /// @notice The hook. Sole caller of `distribute` and `setExcluded`. NOT the basket seat.
    address public immutable controller;
    /// @notice Converts `payoutToken` into a slot's asset at payout time. May be unset, in which
    ///         case every slot degrades to the pair currency and the basket is purely cosmetic.
    address public immutable converter;
    /// @notice The launch-asset allowlist. The ONLY authority on what a slot may point at.
    ///
    /// @dev Immutable on purpose: a swappable registry would be a lever for whoever holds the
    ///      swapping key to route everyone's dividends through an arbitrary contract, which is the
    ///      exact attacker-supplied-token gadget the registry check exists to kill.
    address public immutable pairRegistry;
    /// @notice Who held the basket seat at construction. The CURRENT holder is `basketController`.
    address public immutable basketControllerAtBirth;

    uint256 public immutable minPushPayout;
    uint256 public immutable minShareForQueue;
    uint256 public immutable minSharesForDistribution;

    // -------------------------------------------------------------------------------------------
    // Basket state
    // -------------------------------------------------------------------------------------------

    /// @dev The creator's slots. Length is capped at `MAX_CREATOR_SLOTS` on every write, so
    ///      iterating it in the claim path is bounded by a constant, not by anyone's behaviour.
    Slot[] internal _creatorSlots;

    /// @notice The holder slot's weight, in bps. `BPS` at birth: a fresh basket is 100% holder
    ///         choice, which makes the default behaviour identical to `Distributor` plus election.
    uint16 public holderSlotBps;

    /// @notice The current basket seat. Zero once renounced.
    address public basketController;
    /// @notice Two-step handover, because `audit/03-access-control.md` F-10 already flagged a
    ///         single-step seat transfer as a footgun in this codebase once.
    address public pendingBasketController;
    /// @notice One-way. Once true, the basket is frozen exactly as it stands, forever.
    bool public basketRenounced;

    /// @notice Each holder's elected asset for the holder slot. Zero means `payoutToken`.
    ///
    /// @dev Zero-as-default rather than an explicit initialisation means a holder who never calls
    ///      `setMyReward` costs nothing and gets the pair currency - "a default when unset, and no
    ///      forced third-party token", per the audit/11 §7 spec.
    mapping(address holder => address) public electedRewardOf;

    // -------------------------------------------------------------------------------------------
    // Streaming accumulator - identical to Distributor.sol; see that file for the full rationale
    // -------------------------------------------------------------------------------------------

    /// @notice How long a distribution takes to fully vest. The entire front-running defence.
    uint64 public constant STREAM_WINDOW = 24 hours;

    uint256 public streamRate; // pre-magnified; see Distributor.sol on why
    uint64 public streamFinish;
    uint64 public lastCheckpoint;
    uint256 public streamRemainderMag;

    uint256 internal _magnifiedPayoutPerShare;
    mapping(address account => int256) internal _corrections;
    mapping(address account => uint256) internal _withdrawn;
    mapping(address account => uint256) public shareOf;

    uint256 public totalShares;
    uint256 public totalDistributed;
    uint256 public totalWithdrawn;
    uint256 public pendingPayouts;

    mapping(address account => bool) public excluded;

    address[] internal _queue;
    mapping(address account => uint256) internal _queueIndexPlusOne;
    uint256 public cursor;

    // -------------------------------------------------------------------------------------------
    // Events - every mutation is visible, because a payout in a currency nobody advertised is
    // exactly the kind of thing that must be readable on chain rather than inferred from balances
    // -------------------------------------------------------------------------------------------

    event PayoutsAdded(uint256 amount, uint256 newMagnifiedPerShare);
    /// @notice One slot's share of a payout was swapped into that slot's asset before payment.
    event RewardConverted(address indexed to, uint256 amountIn, uint256 amountOut, address token);
    /// @notice One slot's share could not be swapped, so it was paid in the pair currency instead.
    event RewardConversionFailed(address indexed to, uint256 amount, address wanted);
    event PayoutSent(address indexed account, uint256 amount);
    event PayoutSendFailed(address indexed account, uint256 amount);
    event ExcludedSet(address indexed account, bool isExcluded);

    event BasketSet(address[] tokens, uint16[] weightsBps, uint16 holderSlotBps);
    event RewardElected(address indexed holder, address indexed token);
    event BasketControllerTransferStarted(address indexed from, address indexed to);
    event BasketControllerTransferred(address indexed from, address indexed to);
    event BasketRenounced(address indexed by);

    error OnlyShareToken();
    error OnlyController();
    error OnlyBasketController();
    error NotPendingBasketController();
    error BasketIsRenounced();
    error NothingToWithdraw();
    error ZeroAddress();
    error AlreadyExcluded();
    error TooManySlots(uint256 given);
    error WeightsMustSumToBps(uint256 sum);
    error ZeroWeightSlot(uint256 index);
    error TokenNotApproved(address token);
    error LengthMismatch();

    modifier onlyShareToken() {
        if (msg.sender != shareToken) revert OnlyShareToken();
        _;
    }

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    /// @dev Renounce is checked FIRST so a renounced basket answers every mutation attempt with
    ///      the same unambiguous error, including from the address that used to hold the seat.
    modifier onlyBasketController() {
        if (basketRenounced) revert BasketIsRenounced();
        if (msg.sender != basketController) revert OnlyBasketController();
        _;
    }

    /// @param _poolManager excluded at construction for the same reason as `Distributor`: in v4
    ///        the pool's reserves are an ERC-20 balance on the singleton, which would otherwise be
    ///        the largest "holder" in the book. See `Distributor.sol`'s constructor docs.
    /// @param _launcher excluded at construction; it holds 100% of supply between mint and seed.
    /// @param _basketController the creator seat. Zero is allowed and means the basket is BORN
    ///        renounced: 100% holder slot, frozen forever - the maximally trust-minimised shape,
    ///        available without a second transaction.
    constructor(
        address _shareToken,
        address _payoutToken,
        address _controller,
        address _poolManager,
        address _launcher,
        uint256 _minPushPayout,
        uint256 _minShareForQueue,
        uint256 _minSharesForDistribution,
        address _converter,
        address _pairRegistry,
        address _basketController
    ) {
        if (
            _shareToken == address(0) || _payoutToken == address(0) || _controller == address(0)
                || _pairRegistry == address(0)
        ) revert ZeroAddress();
        shareToken = _shareToken;
        payoutToken = _payoutToken;
        controller = _controller;
        converter = _converter;
        pairRegistry = _pairRegistry;
        basketControllerAtBirth = _basketController;
        basketController = _basketController;
        if (_basketController == address(0)) basketRenounced = true;
        minPushPayout = _minPushPayout;
        minShareForQueue = _minShareForQueue;
        minSharesForDistribution = _minSharesForDistribution;

        // A fresh basket is 100% holder slot. No creator slots exist until the seat sets some,
        // so the zero-configuration behaviour is exactly `Distributor` plus election.
        holderSlotBps = uint16(BPS);

        excluded[address(0)] = true;
        excluded[address(0xdEaD)] = true;
        excluded[address(this)] = true;
        if (_poolManager != address(0)) excluded[_poolManager] = true;
        if (_launcher != address(0)) excluded[_launcher] = true;
    }

    // -------------------------------------------------------------------------------------------
    // The basket seat
    // -------------------------------------------------------------------------------------------

    /// @notice Replace the creator slots and the holder slot's weight, atomically.
    ///
    /// @dev Atomic replacement rather than per-slot edits, so the sum-to-`BPS` invariant is
    ///      checked once against the WHOLE new configuration and there is no intermediate state in
    ///      which the weights do not add up. **This changes only how FUTURE transfers are split.**
    ///      Value already accrued is denominated in `payoutToken` and untouched; a payout already
    ///      made is beyond anyone's reach, including this seat's - the BaseStonk rule ("cannot
    ///      touch dividends already paid") falls out of the accounting model for free.
    ///
    ///      Every slot asset must be registry-approved or be the pair currency itself. The
    ///      registry is checked AGAIN at payout time (see `_convertOrFallBack`), so approving here
    ///      is necessary but not sufficient - a pair revoked after configuration stops being
    ///      converted into without anyone having to touch this contract.
    ///
    ///      Note what is NOT a parameter: the share of trading fees this contract receives. That
    ///      is the hook's number. This seat can redirect the basket; it cannot grow it.
    function setBasket(address[] calldata tokens, uint16[] calldata weightsBps, uint16 _holderSlotBps)
        external
        onlyBasketController
    {
        if (tokens.length != weightsBps.length) revert LengthMismatch();
        if (tokens.length > MAX_CREATOR_SLOTS) revert TooManySlots(tokens.length);

        uint256 sum = _holderSlotBps;
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (weightsBps[i] == 0) revert ZeroWeightSlot(i);
            address t = tokens[i];
            if (t == address(0)) revert ZeroAddress();
            if (t != payoutToken && !IPairRegistry(pairRegistry).isApproved(t)) {
                revert TokenNotApproved(t);
            }
            sum += weightsBps[i];
        }
        if (sum != BPS) revert WeightsMustSumToBps(sum);

        delete _creatorSlots;
        for (uint256 i = 0; i < tokens.length; ++i) {
            _creatorSlots.push(Slot({token: tokens[i], weightBps: weightsBps[i]}));
        }
        holderSlotBps = _holderSlotBps;

        emit BasketSet(tokens, weightsBps, _holderSlotBps);
    }

    /// @notice Begin handing the seat to another address. Two-step, like `Ownable2Step`.
    function transferBasketController(address to) external onlyBasketController {
        if (to == address(0)) revert ZeroAddress();
        pendingBasketController = to;
        emit BasketControllerTransferStarted(msg.sender, to);
    }

    function acceptBasketController() external {
        if (msg.sender != pendingBasketController) revert NotPendingBasketController();
        address old = basketController;
        basketController = msg.sender;
        delete pendingBasketController;
        emit BasketControllerTransferred(old, msg.sender);
    }

    /// @notice Give up the seat forever. The basket freezes exactly as it stands.
    ///
    /// @dev **One way, and not even the platform can reverse it** - there is no address in this
    ///      contract with the authority to re-seat a renounced basket, which is the whole point:
    ///      renouncing is a trust signal, and a signal that can be taken back is not a signal
    ///      (the same argument `Distributor.renounceAccrual` makes for holders). The basket
    ///      freezes AS CONFIGURED rather than resetting to 100% holder slot, because holders
    ///      bought into the advertised basket; a renounce that silently rewrote it would be a
    ///      mutation performed by the act of promising no more mutations.
    function renounceBasket() external onlyBasketController {
        basketRenounced = true;
        basketController = address(0);
        delete pendingBasketController;
        emit BasketRenounced(msg.sender);
    }

    // -------------------------------------------------------------------------------------------
    // The holder slot
    // -------------------------------------------------------------------------------------------

    /// @notice Choose what YOUR slot of every future payout is converted into.
    ///
    /// @dev **The registry check is the security gate, and it is the difference between this
    ///      feature and the drain in `audit/11-external-bsc-contracts.md` §3.** The BSC lineage
    ///      accepted any address here and then called it back mid-claim; the token was the
    ///      attacker's re-entry gadget. Validating against the launch allowlist means an election
    ///      can only ever point at an asset the platform already deemed fit to launch against -
    ///      an attacker cannot elect a contract they control unless the registry owner approves
    ///      it, and if that happens the registry is the breach, not this function.
    ///
    ///      Zero resets to the default (`payoutToken`), and electing `payoutToken` itself is
    ///      always allowed even if the registry never listed it - the base currency cannot be a
    ///      worse choice than the fallback everyone gets anyway.
    ///
    ///      **An election never touches accrued value.** Entitlement is denominated in
    ///      `payoutToken` and the election is only read at the moment of transfer, so switching
    ///      tokens moves no ledger entry, creates no backlog, and cannot be used to re-denominate
    ///      anything already owed.
    function setMyReward(address token) external {
        if (token != address(0) && token != payoutToken) {
            if (!IPairRegistry(pairRegistry).isApproved(token)) revert TokenNotApproved(token);
        }
        electedRewardOf[msg.sender] = token;
        emit RewardElected(msg.sender, token);
    }

    // -------------------------------------------------------------------------------------------
    // Accounting - identical to Distributor.sol; docstrings there, mechanics here
    // -------------------------------------------------------------------------------------------

    /// @dev Fold vested time into the accumulator. MUST run before any read/write of shares or
    ///      entitlement; carries rather than strands when the register is empty. See
    ///      `Distributor._checkpoint` for the Synthetix zero-supply bug this avoids.
    function _checkpoint() internal {
        uint64 finish = streamFinish;
        uint64 upTo = uint64(block.timestamp) < finish ? uint64(block.timestamp) : finish;
        uint64 from = lastCheckpoint;
        if (upTo <= from) return;

        uint256 grossMag = uint256(upTo - from) * streamRate + streamRemainderMag;
        uint256 vested = grossMag / MAGNITUDE;

        lastCheckpoint = upTo;
        streamRemainderMag = grossMag % MAGNITUDE;

        if (vested == 0) return;

        uint256 shares = totalShares;
        if (shares == 0 || shares < minSharesForDistribution) {
            pendingPayouts += vested;
            return;
        }

        _magnifiedPayoutPerShare += (vested * MAGNITUDE) / shares;
        totalDistributed += vested;
    }

    /// @dev The accumulator as of RIGHT NOW, mirroring `_checkpoint` exactly including the carried
    ///      remainder, or views would promise more than a withdraw in the same block pays.
    function _perShareNow() internal view returns (uint256) {
        uint64 finish = streamFinish;
        uint64 upTo = uint64(block.timestamp) < finish ? uint64(block.timestamp) : finish;
        if (upTo <= lastCheckpoint) return _magnifiedPayoutPerShare;

        uint256 shares = totalShares;
        if (shares == 0 || shares < minSharesForDistribution) return _magnifiedPayoutPerShare;

        uint256 grossMag = uint256(upTo - lastCheckpoint) * streamRate + streamRemainderMag;
        uint256 vested = grossMag / MAGNITUDE;
        if (vested == 0) return _magnifiedPayoutPerShare;
        return _magnifiedPayoutPerShare + (vested * MAGNITUDE) / shares;
    }

    /// @dev Start or extend the stream, weighting new money against the unvested remainder -
    ///      Yearn's re-lock rule, so a dust distribution cannot reset the finish line. See
    ///      `Distributor._arm`.
    function _arm(uint256 addition) internal {
        uint256 nowTs = block.timestamp;
        uint256 remainingTime = streamFinish > nowTs ? streamFinish - nowTs : 0;
        uint256 remaining = (remainingTime * streamRate) / MAGNITUDE;
        uint256 total = addition + remaining;
        if (total == 0) return;

        uint256 window = (remaining * remainingTime + addition * STREAM_WINDOW) / total;
        if (window == 0) window = 1;

        uint256 rate = (total * MAGNITUDE) / window;
        uint256 dust = total - (rate * window) / MAGNITUDE;
        if (dust != 0) pendingPayouts += dust;

        streamRate = rate;
        streamFinish = uint64(nowTs + window);
        lastCheckpoint = uint64(nowTs);
    }

    /// @notice Fold carried value back into a stream. Permissionless; see `Distributor.flush`.
    function flush() external {
        _checkpoint();
        uint256 carry = pendingPayouts;
        if (carry == 0) return;

        uint256 shares = totalShares;
        if (shares == 0 || shares < minSharesForDistribution) return;

        pendingPayouts = 0;
        _arm(carry);
        emit PayoutsAdded(carry, _magnifiedPayoutPerShare);
    }

    /// @notice Called by the hook once payout tokens have landed here. Carries at zero shares.
    function distribute(uint256 amount) external onlyController {
        _checkpoint();

        uint256 total = amount + pendingPayouts;
        if (total == 0) return;

        uint256 shares = totalShares;
        if (shares == 0 || shares < minSharesForDistribution) {
            pendingPayouts = total;
            return;
        }

        pendingPayouts = 0;
        _arm(total);
        emit PayoutsAdded(total, _magnifiedPayoutPerShare);
    }

    /// @notice Called by the launch token on every balance change. O(1), always.
    function setBalance(address account, uint256 newBalance) external onlyShareToken {
        _checkpoint();
        if (excluded[account]) {
            if (shareOf[account] != 0) _setShares(account, 0);
            return;
        }
        _setShares(account, newBalance);
    }

    function setExcluded(address account, bool isExcluded) external onlyController {
        _checkpoint();
        excluded[account] = isExcluded;
        if (isExcluded && shareOf[account] != 0) _setShares(account, 0);
        emit ExcludedSet(account, isExcluded);
    }

    /// @notice Give up your own future dividends. One way, only for yourself. See
    ///         `Distributor.renounceAccrual` for the full authority argument.
    function renounceAccrual() external {
        _checkpoint();
        if (excluded[msg.sender]) revert AlreadyExcluded();
        excluded[msg.sender] = true;
        if (shareOf[msg.sender] != 0) _setShares(msg.sender, 0);
        emit ExcludedSet(msg.sender, true);
    }

    function _setShares(address account, uint256 newShares) internal {
        uint256 old = shareOf[account];
        if (newShares == old) return;

        if (newShares > old) {
            uint256 d = newShares - old;
            totalShares += d;
            _corrections[account] -= int256(_magnifiedPayoutPerShare * d);
        } else {
            uint256 d = old - newShares;
            totalShares -= d;
            _corrections[account] += int256(_magnifiedPayoutPerShare * d);
        }
        shareOf[account] = newShares;

        if (newShares >= minShareForQueue) {
            _enqueue(account);
        } else if (newShares == 0) {
            _dequeue(account);
        }
    }

    // -------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------

    function accumulativeOf(address account) public view returns (uint256) {
        int256 acc = int256(_perShareNow() * shareOf[account]) + _corrections[account];
        if (acc <= 0) return 0;
        return uint256(acc) / MAGNITUDE;
    }

    function withdrawableOf(address account) public view returns (uint256) {
        uint256 acc = accumulativeOf(account);
        uint256 w = _withdrawn[account];
        return acc > w ? acc - w : 0;
    }

    function withdrawnOf(address account) external view returns (uint256) {
        return _withdrawn[account];
    }

    function creatorSlotCount() external view returns (uint256) {
        return _creatorSlots.length;
    }

    function creatorSlotAt(uint256 i) external view returns (address token, uint16 weightBps) {
        Slot memory s = _creatorSlots[i];
        return (s.token, s.weightBps);
    }

    /// @notice What `account`'s holder slot currently converts into. Never zero.
    function holderRewardOf(address account) public view returns (address) {
        address t = electedRewardOf[account];
        return t == address(0) ? payoutToken : t;
    }

    function queueLength() external view returns (uint256) {
        return _queue.length;
    }

    function queueAt(uint256 i) external view returns (address) {
        return _queue[i];
    }

    // -------------------------------------------------------------------------------------------
    // Payout
    // -------------------------------------------------------------------------------------------

    /// @notice Pull. Always available, never gated on anyone else paying gas.
    ///
    /// @dev **Every state write happens before the first external call, and the guard makes the
    ///      allowance measurement in `_convertOrFallBack` meaningful** - both halves of the
    ///      audit/11 §3 lesson, applied. The residue decrement after `_paySplit` is not a guard
    ///      written late: it un-books only value that verifiably never left, inside the same
    ///      guarded frame, and re-entry between the externals and the decrement is exactly what
    ///      `nonReentrant` forbids. A holder whose plain send fails when nothing converted gets a
    ///      full rollback and a revert, same as `Distributor`; one whose plain send fails AFTER
    ///      some slots converted keeps a live claim on precisely the unpaid residue.
    function withdraw() external nonReentrant returns (uint256) {
        _checkpoint();
        uint256 amount = withdrawableOf(msg.sender);
        if (amount == 0) revert NothingToWithdraw();

        // EFFECTS - the whole claim is consumed before any token is touched.
        _withdrawn[msg.sender] += amount;
        totalWithdrawn += amount;

        // INTERACTIONS.
        uint256 residue = _paySplit(msg.sender, amount);

        if (residue != 0) {
            // Un-book only what was never paid, so the holder can retry that part. If NOTHING
            // was paid this collapses to Distributor's full rollback-and-revert.
            _withdrawn[msg.sender] -= residue;
            totalWithdrawn -= residue;
            if (residue == amount) revert NothingToWithdraw();
            emit PayoutSendFailed(msg.sender, residue);
        }

        uint256 paid = amount - residue;
        emit PayoutSent(msg.sender, paid);
        return paid;
    }

    /// @notice Push. Walks at most `maxAccounts` holders from the cursor, wrapping around.
    ///
    /// @dev Permissionless, idempotent, unpaid - a courtesy, exactly as documented at length in
    ///      `Distributor`. A failing recipient is SKIPPED, never bubbled: one hostile or
    ///      blocklisted receiver must not brick the queue. Worst-case external calls per batch is
    ///      `maxAccounts * MAX_SLOTS` conversions, which the CALLER bounds - there is still no
    ///      quantity here that grows with the holder set.
    function processBatch(uint256 maxAccounts)
        public
        nonReentrant
        returns (uint256 sentCount, uint256 sentTotal)
    {
        _checkpoint();
        uint256 len = _queue.length;
        if (len == 0 || maxAccounts == 0) return (0, 0);
        if (maxAccounts > len) maxAccounts = len;

        uint256 i = cursor;
        for (uint256 n = 0; n < maxAccounts; ++n) {
            if (i >= len) i = 0;
            address account = _queue[i];
            uint256 amount = withdrawableOf(account);

            if (amount >= minPushPayout) {
                _withdrawn[account] += amount;
                totalWithdrawn += amount;

                uint256 residue = _paySplit(account, amount);
                if (residue != 0) {
                    _withdrawn[account] -= residue;
                    totalWithdrawn -= residue;
                    emit PayoutSendFailed(account, residue);
                }
                uint256 paid = amount - residue;
                if (paid != 0) {
                    unchecked {
                        ++sentCount;
                        sentTotal += paid;
                    }
                    emit PayoutSent(account, paid);
                }
            }
            unchecked {
                ++i;
            }
        }
        cursor = i >= len ? 0 : i;
    }

    /// @dev Split one payout across the basket and deliver it.
    ///
    ///      **Solvency by construction:** each creator slot takes `amount * weight / BPS`,
    ///      floored, and the holder slot takes THE REMAINDER - its own floored share plus every
    ///      wei of rounding dust - so the portions always sum to exactly `amount` and nothing is
    ///      stranded or double-counted.
    ///
    ///      All value that ends up payoutToken-denominated - the unset holder slot, slots that
    ///      point at the pair currency, and every failed conversion - is coalesced into ONE plain
    ///      transfer at the end, so a payout costs at most `MAX_SLOTS` conversion attempts plus
    ///      one transfer.
    ///
    /// @return residue payoutToken value that could not be delivered at all. Zero on full success.
    ///         Only ever the PLAIN portion: a slot that converted has left the building and can
    ///         never be part of a rollback.
    function _paySplit(address to, uint256 amount) internal returns (uint256 residue) {
        uint256 plain = 0;
        uint256 assigned = 0;

        uint256 n = _creatorSlots.length; // <= MAX_CREATOR_SLOTS, enforced on every write
        for (uint256 i = 0; i < n; ++i) {
            Slot memory s = _creatorSlots[i];
            uint256 portion = (amount * s.weightBps) / BPS;
            assigned += portion;
            plain += _convertOrFallBack(to, portion, s.token);
        }

        // The holder slot is the remainder, so the split is exact whatever the rounding did.
        uint256 holderPortion = amount - assigned;
        plain += _convertOrFallBack(to, holderPortion, holderRewardOf(to));

        if (plain != 0) {
            (bool ok, bytes memory ret) =
                payoutToken.call(abi.encodeWithSelector(IERC20.transfer.selector, to, plain));
            if (!(ok && (ret.length == 0 || abi.decode(ret, (bool))))) {
                residue = plain;
            }
        }
    }

    /// @dev Attempt one slot's conversion; on ANY failure, return the portion for plain payment.
    ///
    ///      This is `Distributor._trySend`'s conversion block verbatim, per slot, including the
    ///      allowance-consumed measurement that closed D-01 and R2-07: the converter is judged by
    ///      how much of its exact-amount allowance it spent - the only quantity that describes
    ///      THIS transfer and that nothing else can move while the reentrancy guard holds.
    ///      Exactly `portion` is approved, never more, and the allowance is cleared afterwards in
    ///      every branch: this contract holds every holder's money and the converter is a
    ///      separate deployment.
    ///
    ///      **The registry is re-checked at payout time.** Approval at election/configuration
    ///      time is not enough: a pair the registry owner revokes - because it paused, blacklists,
    ///      or got exploited - stops being converted into on the next claim, with no action
    ///      needed from anyone here. The holder is paid the pair currency and told so by event.
    ///
    /// @return plainPortion the payoutToken value this slot could NOT deliver in its own asset.
    function _convertOrFallBack(address to, uint256 portion, address target)
        internal
        returns (uint256 plainPortion)
    {
        if (portion == 0) return 0;
        if (target == payoutToken) return portion;

        if (
            converter == address(0) || converter.code.length == 0
                || !IPairRegistry(pairRegistry).isApproved(target)
        ) {
            emit RewardConversionFailed(to, portion, target);
            return portion;
        }

        (bool okApprove,) =
            payoutToken.call(abi.encodeWithSelector(IERC20.approve.selector, converter, portion));
        if (okApprove) {
            try IRewardConverter(converter).convert(payoutToken, target, portion, to) returns (
                uint256 out
            ) {
                uint256 taken = portion - IERC20(payoutToken).allowance(address(this), converter);
                _clearAllowance();
                if (taken != 0) {
                    // It spent the allowance. Whether it produced anything is the converter's
                    // problem now; paying this portion again would double-spend the claim.
                    if (out != 0) emit RewardConverted(to, portion, out, target);
                    else emit RewardConversionFailed(to, portion, target);
                    return 0;
                }
            } catch {
                _clearAllowance();
            }
        }
        emit RewardConversionFailed(to, portion, target);
        return portion;
    }

    /// @dev Never leave a standing allowance over every holder's money.
    function _clearAllowance() internal {
        (bool ok,) =
            payoutToken.call(abi.encodeWithSelector(IERC20.approve.selector, converter, 0));
        ok;
    }

    function _enqueue(address account) internal {
        if (_queueIndexPlusOne[account] != 0) return;
        _queue.push(account);
        _queueIndexPlusOne[account] = _queue.length;
    }

    function _dequeue(address account) internal {
        uint256 idxPlusOne = _queueIndexPlusOne[account];
        if (idxPlusOne == 0) return;
        uint256 idx = idxPlusOne - 1;
        uint256 last = _queue.length - 1;
        if (idx != last) {
            address moved = _queue[last];
            _queue[idx] = moved;
            _queueIndexPlusOne[moved] = idx + 1;
        }
        _queue.pop();
        delete _queueIndexPlusOne[account];
    }
}
