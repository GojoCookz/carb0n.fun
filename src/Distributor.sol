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
contract Distributor {
    uint256 internal constant MAGNITUDE = 2 ** 128;

    /// @notice The launch token whose holders are paid.
    address public immutable shareToken;
    /// @notice The currency holders are paid IN. Fixed at launch, never converted.
    address public immutable payoutToken;

    /// @notice Dust guard: below this, a push send costs more gas than it delivers.
    uint256 public immutable minPushPayout;
    /// @notice Balances below this do not enter the push queue (they can still pull).
    uint256 public immutable minShareForQueue;

    /// @notice Floor on `totalShares` before a distribution is applied rather than carried.
    /// @dev Overflow guard, not a policy knob. See the constructor docs.
    uint256 public immutable minSharesForDistribution;

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
        uint256 _minSharesForDistribution
    ) {
        if (_shareToken == address(0) || _payoutToken == address(0) || _controller == address(0)) {
            revert ZeroAddress();
        }
        shareToken = _shareToken;
        payoutToken = _payoutToken;
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
    function distribute(uint256 amount) external onlyController {
        uint256 total = amount + pendingPayouts;
        if (total == 0) return;

        // Carry while there is nobody to pay, AND while the holder base is small enough that
        // dividing by it would inflate `_magnifiedPayoutPerShare` into later overflow territory.
        uint256 shares = totalShares;
        if (shares == 0 || shares < minSharesForDistribution) {
            pendingPayouts = total;
            return;
        }

        pendingPayouts = 0;
        _magnifiedPayoutPerShare += (total * MAGNITUDE) / shares;
        totalDistributed += total;
        emit PayoutsAdded(total, _magnifiedPayoutPerShare);
    }

    /// @notice Called by the launch token on every balance change.
    function setBalance(address account, uint256 newBalance) external onlyShareToken {
        if (excluded[account]) {
            if (shareOf[account] != 0) _setShares(account, 0);
            return;
        }
        _setShares(account, newBalance);
    }

    function setExcluded(address account, bool isExcluded) external onlyController {
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

    function accumulativeOf(address account) public view returns (uint256) {
        int256 acc = int256(_magnifiedPayoutPerShare * shareOf[account]) + _corrections[account];
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

    /// @notice Raw-call transfer that reports failure instead of reverting.
    /// @dev Handles both bool-returning and no-return ERC-20s.
    function _trySend(address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) =
            payoutToken.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
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
