// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Distributor
/// @notice Pays holders of one launch in that launch's PAIR currency - USDG, WETH, NVDA, whatever
///         the token trades against - not in more of the memecoin.
///
/// @dev Accounting is the magnified-dividend-per-share accumulator: O(1) on every transfer and
///      every distribution, with no iteration in the hot path. Payout is then offered two ways:
///
///        - PUSH  `processBatch(n)`  - a gas-bounded cursor that walks at most `n` holders per
///                                     call and wraps around. Anyone may call it; the hook calls
///                                     it opportunistically after a swap. There is NO unbounded
///                                     loop over holders anywhere in this contract, because that
///                                     is a self-DoS the moment the holder set grows.
///        - PULL  `withdraw()`       - always available, so a holder is never dependent on anyone
///                                     else paying gas.
///
///      A push send that reverts (blocklisted recipient, hostile receiver) is SKIPPED, not
///      bubbled - one bad address must never brick the queue. That is why sends go through a raw
///      call rather than SafeERC20.
///
///      Robinhood stock tokens are safe as a payout asset here: corporate actions move
///      `uiMultiplier()`, not raw balances, so pro-rata accounting on raw balances stays correct.
/// @notice Swaps a dividend into the currency the creator chose, at withdrawal time.
///
/// @dev Deliberately a SEPARATE deployment behind an interface rather than logic in the
///      distributor. The route from a pair currency to an arbitrary reward on L1 is a moving
///      target - v3 pools, v4 pools, multi-hop, whichever is deepest this month - and none of
///      that belongs inside the contract holding everyone''s dividends. It also means a
///      distributor with no converter simply pays the pair currency, which is the default.
///
///      MUST pull exactly `amountIn` of `tokenIn` via the allowance it is given, and MUST send
///      what it produces directly to `recipient`. Returning zero is a valid "could not route".
interface IRewardConverter {
    function convert(address tokenIn, address tokenOut, uint256 amountIn, address recipient)
        external
        returns (uint256 amountOut);
}

contract Distributor {
    uint256 internal constant MAGNITUDE = 2 ** 128;

    /// @notice The launch token whose holders are paid.
    address public immutable shareToken;
    /// @notice The currency this contract HOLDS and accounts in — always the pair currency.
    ///
    /// @dev Not necessarily what a holder receives. See `rewardToken`.
    address public immutable payoutToken;

    /// @notice What holders are actually paid, if the creator chose something else.
    ///
    /// @dev **Accounting stays in `payoutToken`; only the final transfer changes.** Fees arrive in
    ///      the pair currency because that is what a buyer hands over, so any other reward means a
    ///      swap. Doing that swap on the way IN would credit the accumulator in one token while
    ///      the contract held another the moment a swap failed — the "fallback" would not degrade,
    ///      it would make this contract insolvent. Doing it on the way OUT means a failed swap
    ///      simply pays the pair currency, and not one number in the ledger moves.
    ///
    ///      Equal to `payoutToken` on most launches, in which case no conversion is attempted.
    address public immutable rewardToken;

    /// @notice Converts `payoutToken` into `rewardToken` at withdrawal time. May be unset.
    address public immutable converter;

    /// @notice Dust guard: below this, a push send costs more gas than it delivers.
    uint256 public immutable minPushPayout;
    /// @notice Balances below this do not enter the push queue (they can still pull).
    uint256 public immutable minShareForQueue;

    /// @notice Floor on `totalShares` before a distribution is applied rather than carried.
    /// @dev Overflow guard, not a policy knob. See the constructor docs.
    uint256 public immutable minSharesForDistribution;

    /// @notice How long a distribution takes to fully vest into the accumulator.
    ///
    /// @dev **This window is the entire defence against dividend front-running**, and it exists
    ///      because the classic dividend-token lineage does NOT defend against it. Traced across
    ///      four implementations from 2019 to 2025: `claimWait` and friends rate-limit CLAIMING
    ///      while leaving ENTITLEMENT creditable in a single instant, so `buy -> trigger -> sell`
    ///      in one transaction captures a share of the whole pot having held for zero blocks.
    ///
    ///      Streaming makes that worthless. An attacker who buys, sweeps and sells in one
    ///      transaction earns only what vested in that block — dust, against the trading fee they
    ///      just paid on both legs. Earning a real share requires holding across the window, which
    ///      is price risk, which is indistinguishable from simply investing. That is the point.
    ///
    ///      24 hours is a deliberate midpoint. Shorter makes the attack cheaper; longer makes
    ///      dividends feel unresponsive on a token whose holders check hourly.
    uint64 public constant STREAM_WINDOW = 24 hours;

    /// @notice Payout released per second while a stream is live, PRE-MAGNIFIED by `MAGNITUDE`.
    ///
    /// @dev **Magnified, and that is not cosmetic.** Stored as a plain per-second amount it is
    ///      `total / window`, which truncates to ZERO for anything under `STREAM_WINDOW` base
    ///      units. On an 18-decimal pair 86,400 wei is dust, but on a 6-decimal pair like USDC it
    ///      is 8.64 cents — so a quiet USDC-paired pool would credit nobody on every sweep and
    ///      quietly route the whole fee into the carry. Carrying the magnitude here keeps the rate
    ///      meaningful down to a single base unit.
    uint256 public streamRate;
    /// @notice When the current stream finishes. Zero before the first distribution.
    uint64 public streamFinish;
    /// @notice Last second already folded into `_magnifiedPayoutPerShare`.
    uint64 public lastCheckpoint;

    /// @notice Sub-unit vesting carried between checkpoints, in MAGNIFIED units.
    ///
    /// @dev **The rate was magnified but the accrual was not, and that lost real money.**
    ///      `_checkpoint` divided `MAGNITUDE` straight back out and threw the remainder away on
    ///      every call. On an 18-decimal pair that is invisible; on a 6-decimal pair with ordinary
    ///      traffic a 0.01 USDG stream lost 28% of itself — exactly the population magnifying the
    ///      rate was introduced to protect.
    ///
    ///      Carrying it also removes the old "do not advance the clock on a sub-unit vest" branch,
    ///      which was itself griefable: `flush()` is permissionless, `_arm` always leaves a wei of
    ///      dust, so an attacker could re-arm every block and reset `lastCheckpoint` past time the
    ///      guard had deliberately left un-advanced. Advancing is now lossless, so there is
    ///      nothing left to grind.
    uint256 public streamRemainderMag;

    uint256 internal _magnifiedPayoutPerShare;
    mapping(address account => int256) internal _corrections;
    mapping(address account => uint256) internal _withdrawn;
    mapping(address account => uint256) public shareOf;

    uint256 public totalShares;
    uint256 public totalDistributed;
    uint256 public totalWithdrawn;

    /// @notice Payout tokens received while `totalShares` was zero, awaiting the first real holder.
    uint256 public pendingPayouts;

    /// @notice Addresses that never accrue: the pool, the launcher, this contract, burn addresses.
    mapping(address account => bool) public excluded;

    address[] internal _queue;
    mapping(address account => uint256) internal _queueIndexPlusOne;
    uint256 public cursor;

    event PayoutsAdded(uint256 amount, uint256 newMagnifiedPerShare);
    /// @notice A dividend was swapped into the creator's chosen reward currency before payment.
    event RewardConverted(address indexed to, uint256 amountIn, uint256 amountOut, address token);
    /// @notice The swap could not be made, so the holder was paid the pair currency instead.
    event RewardConversionFailed(address indexed to, uint256 amount, address wanted);
    event PayoutSent(address indexed account, uint256 amount);
    event PayoutSendFailed(address indexed account, uint256 amount);
    event ExcludedSet(address indexed account, bool isExcluded);

    error OnlyShareToken();
    error OnlyController();
    error NothingToWithdraw();
    error ZeroAddress();

    address public immutable controller;

    modifier onlyShareToken() {
        if (msg.sender != shareToken) revert OnlyShareToken();
        _;
    }

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    /// @param _launcher the contract that mints and seeds the launch. **Excluded at construction.**
    ///        It holds 100% of supply between the mint and the pool seeding, and keeps unseeded dust
    ///        afterwards. Left unexcluded it is not merely a phantom holder - it is the mechanism by
    ///        which `_magnifiedPayoutPerShare` explodes, because the dev buy's fee gets divided by
    ///        whatever dust the launcher still holds. See `minSharesForDistribution`.
    /// @param _minSharesForDistribution floor below which a distribution is CARRIED instead of
    ///        applied. `_magnifiedPayoutPerShare += amount * 2**128 / shares` grows without bound as
    ///        `shares` approaches zero, and `_setShares` then computes
    ///        `_magnifiedPayoutPerShare * delta` in checked arithmetic. Once that product can
    ///        overflow, EVERY transfer of the token reverts and the token is bricked - a far worse
    ///        outcome than a delayed dividend. Anyone able to be the first holder with 1 wei could
    ///        otherwise trigger it deliberately. The floor makes the dust case carry instead.
    /// @param _poolManager the Uniswap v4 singleton. **Excluded at construction, not later.**
    ///        In v4 there is no per-pair contract: the pool's reserves are an ERC-20 balance held by
    ///        the PoolManager itself, and that balance is the entire unsold supply. Left unexcluded
    ///        it is the largest "holder" in the book and silently absorbs most of every
    ///        distribution - which is then not merely stranded but raw-transferred INTO the
    ///        singleton by `processBatch`, where an unsynced balance is free money for the next
    ///        caller to `sync`/`settle`. Exclusion has to happen here because `setExcluded` is
    ///        `onlyController`, the controller is the fee hook, and the hook exposes no function
    ///        that calls through to it.
    constructor(
        address _shareToken,
        address _payoutToken,
        address _controller,
        address _poolManager,
        address _launcher,
        uint256 _minPushPayout,
        uint256 _minShareForQueue,
        uint256 _minSharesForDistribution,
        address _rewardToken,
        address _converter
    ) {
        if (_shareToken == address(0) || _payoutToken == address(0) || _controller == address(0)) {
            revert ZeroAddress();
        }
        shareToken = _shareToken;
        payoutToken = _payoutToken;
        // Zero collapses to the pair currency, so the common path needs no branch and no
        // converter has to exist for a launch that does not use one.
        rewardToken = _rewardToken == address(0) ? _payoutToken : _rewardToken;
        converter = _converter;
        controller = _controller;
        minPushPayout = _minPushPayout;
        minShareForQueue = _minShareForQueue;
        minSharesForDistribution = _minSharesForDistribution;

        excluded[address(0)] = true;
        excluded[address(0xdEaD)] = true;
        excluded[address(this)] = true;
        if (_poolManager != address(0)) excluded[_poolManager] = true;
        if (_launcher != address(0)) excluded[_launcher] = true;
    }

    // -------------------------------------------------------------------------------------------
    // Accounting
    // -------------------------------------------------------------------------------------------

    /// @notice Called by the controller (hook) once payout tokens have landed on this contract.
    ///
    /// @dev **A distribution arriving while nobody holds shares is CARRIED, not dropped.** This is
    ///      not a hypothetical: the dev buy in `Launcher.launch` is the very first trade, and the
    ///      hook distributes its fee *before* the buyer's tokens are delivered - so `totalShares` is
    ///      genuinely zero at that moment, because the pool is excluded and no holder exists yet.
    ///      An earlier version returned early here and the fee stayed on this contract with nothing
    ///      recording it, unreachable forever. `pendingPayouts` is what makes the "folded into the
    ///      next distribution" promise true.
    /// @dev Fold everything that has vested since the last touch into the accumulator.
    ///
    ///      **Must run BEFORE any read or write of shares or entitlement**, which is what makes
    ///      the stream sound: a balance change is always applied to an accumulator that is already
    ///      current, so incoming shares can never be credited with time they were not present for.
    ///
    ///      When there is nobody to pay, the elapsed value is CARRIED rather than stranded.
    ///      Synthetix's `updateReward` advances its clock even at zero supply and loses those
    ///      seconds permanently — 0xmacro published that exact bug against a Synthetix sibling.
    ///      It matters more here than there, because this contract's own constructor documents
    ///      that `totalShares` is genuinely zero during the dev buy, which is the FIRST trade.
    function _checkpoint() internal {
        uint64 finish = streamFinish;
        uint64 upTo = uint64(block.timestamp) < finish ? uint64(block.timestamp) : finish;
        uint64 from = lastCheckpoint;
        if (upTo <= from) return;

        // Magnified, because `streamRate` is, PLUS whatever fraction the last call could not pay
        // out. Advancing the clock is now lossless, so it always advances.
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

        // Credited from the ROUNDED amount, not from the magnified one. Deriving the accumulator
        // and `totalDistributed` from two different precisions lets entitlement exceed what was
        // actually distributed - measured at one wei over, which is one wei of insolvency on the
        // final withdrawal and exactly the kind of dust that bricks a last claim.
        _magnifiedPayoutPerShare += (vested * MAGNITUDE) / shares;
        totalDistributed += vested;
    }

    /// @dev The accumulator as it stands RIGHT NOW, including time not yet checkpointed. Views
    ///      must use this or a holder's balance would appear to jump only when somebody else
    ///      happens to transact.
    function _perShareNow() internal view returns (uint256) {
        uint64 finish = streamFinish;
        uint64 upTo = uint64(block.timestamp) < finish ? uint64(block.timestamp) : finish;
        if (upTo <= lastCheckpoint) return _magnifiedPayoutPerShare;

        uint256 shares = totalShares;
        if (shares == 0 || shares < minSharesForDistribution) return _magnifiedPayoutPerShare;

        // Mirrors `_checkpoint` exactly, including the carried remainder and the rounding, or the
        // view would promise a holder more than a withdraw in the same block would actually pay.
        uint256 grossMag = uint256(upTo - lastCheckpoint) * streamRate + streamRemainderMag;
        uint256 vested = grossMag / MAGNITUDE;
        if (vested == 0) return _magnifiedPayoutPerShare;
        return _magnifiedPayoutPerShare + (vested * MAGNITUDE) / shares;
    }

    /// @dev Start or extend the stream, weighting the new money against whatever is still
    ///      unvested.
    ///
    ///      **Weighted average, not a flat reset.** Synthetix sets `periodFinish = now + duration`
    ///      on every notify, so anyone may push the finish line out with dust — and unlike
    ///      Synthetix, whose notifier is permissioned, ANYONE can trigger a distribution here by
    ///      calling `sweep()`. A dust distribution therefore barely moves the finish line: it is
    ///      averaged in proportion to how little it is worth. This is Yearn v3's profit-unlocking
    ///      rule, and the analogy is exact — a harvest is our sweep.
    function _arm(uint256 addition) internal {
        uint256 nowTs = block.timestamp;
        uint256 remainingTime = streamFinish > nowTs ? streamFinish - nowTs : 0;
        // `streamRate` is magnified, so the unvested remainder must be divided back down before
        // it can be weighed against `addition`, which is in plain units.
        uint256 remaining = (remainingTime * streamRate) / MAGNITUDE;
        uint256 total = addition + remaining;
        if (total == 0) return;

        uint256 window = (remaining * remainingTime + addition * STREAM_WINDOW) / total;
        if (window == 0) window = 1;

        uint256 rate = (total * MAGNITUDE) / window;
        // Truncation dust is carried, not dropped. Over many small sweeps this would otherwise
        // silently accumulate as unreachable balance on the contract.
        uint256 dust = total - (rate * window) / MAGNITUDE;
        if (dust != 0) pendingPayouts += dust;

        streamRate = rate;
        streamFinish = uint64(nowTs + window);
        lastCheckpoint = uint64(nowTs);
    }

    /// @notice Fold carried value back into a stream. Permissionless, and takes no arguments.
    ///
    /// @dev **Without this the carry can be unreachable.** `distribute` is `onlyController` and
    ///      the hook only calls it when the holder slice is non-zero, so `distribute(0)` — the
    ///      thing that flushes `pendingPayouts` — cannot be reached on a deployed system at all.
    ///      Streaming also added two new ways INTO the carry that instant crediting did not have:
    ///      `_arm` truncation dust on every distribution, and `_checkpoint` carrying whenever the
    ///      register empties MID-stream, which previously could not happen because there was no
    ///      stream to be mid-way through.
    ///
    ///      A live token self-heals on its next fee-bearing sweep. One that empties and then stops
    ///      trading would have stranded it permanently, against a docstring promising it is
    ///      "folded into the next distribution". Permissionless because there is nothing to abuse:
    ///      it moves nobody's money anywhere except into the stream everybody is paid from, and it
    ///      cannot be used to time anything, since what it arms vests over the full window.
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

    function distribute(uint256 amount) external onlyController {
        // Vest what is owed under the OLD rate before the new money changes it.
        _checkpoint();

        uint256 total = amount + pendingPayouts;
        if (total == 0) return;

        // Carry while there is nobody to pay, AND while the holder base is small enough that
        // dividing by it would inflate `_magnifiedPayoutPerShare` into later overflow territory.
        // Nothing is armed in that case: a stream with no holders would vest into the carry
        // anyway, one `_checkpoint` at a time, for no benefit.
        uint256 shares = totalShares;
        if (shares == 0 || shares < minSharesForDistribution) {
            pendingPayouts = total;
            return;
        }

        pendingPayouts = 0;
        // NOT credited to the accumulator here. `_arm` schedules it to vest over `STREAM_WINDOW`,
        // which is what makes a zero-block position worthless.
        _arm(total);
        emit PayoutsAdded(total, _magnifiedPayoutPerShare);
    }

    /// @notice Called by the launch token on every balance change.
    ///
    /// @dev **Checkpoints BEFORE touching shares, and that ordering is the whole fix.** Vesting
    ///      first means the accumulator already reflects every second the OLD holder base was
    ///      present for, so the arriving balance is credited from this instant forward and cannot
    ///      claim time it was not there for. The classic dividend lineage gets this backwards:
    ///      it moves the accumulator, then transfers, then updates the register, which credits a
    ///      seller while they still hold the position they are selling.
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

    /// @dev Uses `_perShareNow`, not the stored value, so a holder's balance rises continuously
    ///      instead of jumping only when somebody else happens to transact.
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
    function withdraw() external returns (uint256) {
        // Vest first, so a holder is paid everything owed up to this second rather than up to
        // whenever somebody else last transacted.
        _checkpoint();
        uint256 amount = withdrawableOf(msg.sender);
        if (amount == 0) revert NothingToWithdraw();
        _withdrawn[msg.sender] += amount;
        totalWithdrawn += amount;
        if (!_trySend(msg.sender, amount)) {
            // Roll back so the holder can retry; a pull that cannot pay must not silently zero out.
            _withdrawn[msg.sender] -= amount;
            totalWithdrawn -= amount;
            revert NothingToWithdraw();
        }
        emit PayoutSent(msg.sender, amount);
        return amount;
    }

    /// @notice Push. Walks at most `maxAccounts` holders from the cursor, wrapping around.
    /// @dev Permissionless and idempotent. A failing recipient is skipped and the cursor moves on.
    /// @return sentCount how many accounts were actually paid
    /// @return sentTotal total payout tokens moved
    function processBatch(uint256 maxAccounts) public returns (uint256 sentCount, uint256 sentTotal) {
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
                if (_trySend(account, amount)) {
                    unchecked {
                        ++sentCount;
                        sentTotal += amount;
                    }
                    emit PayoutSent(account, amount);
                } else {
                    // Skip, do not bubble. One hostile or blocklisted receiver must never brick
                    // the queue for everyone else. They keep their claim and can pull later.
                    _withdrawn[account] -= amount;
                    totalWithdrawn -= amount;
                    emit PayoutSendFailed(account, amount);
                }
            }
            unchecked {
                ++i;
            }
        }
        cursor = i >= len ? 0 : i;
    }

    /// @notice Pay a holder, converting into the reward currency first if the creator chose one.
    ///
    /// @dev **A failed conversion pays the pair currency and moves no accounting.** That is the
    ///      whole reason conversion lives here rather than on the way in: the amount is already
    ///      owed and already held, so the worst case is that somebody is paid in the base asset
    ///      instead of their preferred one. It is emitted either way, because being paid in a
    ///      currency the creator did not advertise is exactly the kind of thing that must be
    ///      visible on chain rather than inferred from a balance.
    function _trySend(address to, uint256 amount) internal returns (bool) {
        if (rewardToken != payoutToken && converter != address(0) && converter.code.length != 0) {
            // Approve exactly what is being converted, never an unbounded allowance: this
            // contract holds every holder's money and the converter is a separate deployment.
            (bool okApprove,) = payoutToken.call(
                abi.encodeWithSelector(IERC20.approve.selector, converter, amount)
            );
            if (okApprove) {
                try IRewardConverter(converter).convert(payoutToken, rewardToken, amount, to)
                returns (uint256 out) {
                    // **Judged by the ALLOWANCE IT CONSUMED, not by what it said and not by our
                    // balance.** Two wrong answers were tried before this one. Trusting `out`
                    // alone let a converter pull its input and return zero - the documented
                    // "could not route" signal - and get paid AND fall through to the transfer
                    // below, paying the same claim twice. Measuring our own BALANCE delta instead
                    // was no better: `processBatch` is permissionless and reentrant from inside
                    // `convert`, so a converter that pulls nothing and re-enters can make somebody
                    // else's payout leave and have that read as success, debiting this holder for
                    // a payment they never received.
                    //
                    // The allowance is the only quantity that describes THIS transfer and that
                    // nothing else in the system can move.
                    uint256 taken = amount
                        - IERC20(payoutToken).allowance(address(this), converter);
                    _clearAllowance();
                    if (taken != 0) {
                        // It spent the allowance. Whether it produced anything is the converter's
                        // problem now; paying again from here would double-spend the claim.
                        if (out != 0) emit RewardConverted(to, amount, out, rewardToken);
                        else emit RewardConversionFailed(to, amount, rewardToken);
                        return true;
                    }
                } catch {
                    _clearAllowance();
                }
            }
            emit RewardConversionFailed(to, amount, rewardToken);
        }

        (bool ok, bytes memory ret) =
            payoutToken.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
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
