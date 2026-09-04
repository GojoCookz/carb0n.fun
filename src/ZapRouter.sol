// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice The two functions that make WETH a wrapper rather than just an ERC-20.
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title ZapRouter
/// @notice Buy a launch with ETH. Sell a launch for ETH. The pair currency never touches the
///         user's wallet.
///
/// @dev **The problem this removes.** Holders of a launch are paid dividends in the PAIR currency —
///      that is the product, and it is not changing. But `TradeRouter` makes the BUYER source that
///      currency too, and those are different concerns. A `$GOLDFISH` launch paired against PAXG
///      asks a first-time buyer to go acquire PAXG before they can press Buy. Almost nobody does.
///      This contract routes `ETH -> PAIR -> TOKEN` in a single transaction so the buyer only ever
///      sees ETH, and reverses it on the way out.
///
///      ```
///      BUY   ETH --(hop 1: ETH/PAIR pool)--> PAIR --(hop 2: our hooked pool)--> TOKEN
///      SELL  TOKEN --(hop 2 reversed)--> PAIR --(hop 1 reversed)--> ETH
///      ```
///
///      **SETTLEMENT ORDER IS LOAD-BEARING, AND HERE IT IS LOAD-BEARING TWICE.** `FeeHook` moves
///      real ERC-20 out of the singleton from inside `afterSwap`, and `PoolManager._settle` credits
///      `balanceOfSelf() - syncedReserves`. Anything that leaves between a payer's `sync` and their
///      `settle` is silently deducted from what they are credited — audit 04 measured a
///      `sync -> transfer -> swap -> settle` router being overcharged **8.5x** on an identical
///      trade, and hitting a bare arithmetic panic when the hook's backlog exceeded the prepay.
///      That failure is a SILENT OVERCHARGE, not a revert, so a test that only asks "did it
///      succeed" passes while users are robbed. Both swaps therefore happen FIRST, and every
///      currency is settled afterwards out of the net delta the manager itself reports.
///
///      **The intermediate leg is measured, never assumed.** The tempting shortcut is to treat
///      hop 1's `+PAIR` as cancelling hop 2's `-PAIR` and skip the pair entirely. It does net in
///      the ordinary case — `Hooks.beforeSwap` folds the fee out of the specified amount, so an
///      exact-input hop 2 debits exactly what hop 1 produced — but it stops netting the moment
///      either hop is cut short by its price limit. So this contract reads the pair's own transient
///      delta after both swaps and refuses to continue if it is anything but zero. Delivering a
///      buyer the pair currency they specifically asked never to see is the exact failure this
///      contract exists to remove; a named revert telling them to reduce their size is better than
///      a silent half-fill in an asset they cannot use.
///
///      **Direction is derived, not trusted.** `TradeRouter` takes `zeroForOne` from the caller
///      because it has no honest way to tell which side is the launch token. This one does: the
///      ETH pool's `currency1` IS the pair currency (native ether sorts to `currency0`
///      unconditionally, being `address(0)`), so the launch token is whichever side of the second
///      key is not the pair. A caller cannot point this router the wrong way round.
contract ZapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    /// @notice The canonical wrapped-ether contract, or `address(0)` to disable the wrap path.
    ///
    /// @dev **Why this is a constructor argument and not a constant.** On a network where no real
    ///      WETH9 exists — Sepolia here, whose `tWETH` is a plain `MockERC20` with no `deposit()` —
    ///      passing an address would make every WETH-paired zap revert inside a `deposit` call that
    ///      does not exist. Zero disables the shortcut and the router falls back to routing hop 1
    ///      through a pool like any other pair, which is exactly the behaviour that shipped first.
    address public immutable weth;

    error NotPoolManager();
    error ZeroAmount();
    /// @notice Above this an exact-input swap would wrap into an exact-output one.
    error AmountTooLarge(uint256 amountIn);
    /// @notice The router is a conduit; naming it as the recipient parks value it cannot return.
    error RecipientIsTheRouter();
    /// @notice The transaction sat in the mempool past the deadline the sender set.
    error Expired(uint256 deadline, uint256 nowTimestamp);
    /// @notice Only the wrapped-ether contract may send this router ether.
    error UnexpectedEther();
    /// @notice A swap with no floor is an instruction to be sandwiched.
    error NoSlippageFloor();
    error TooLittleReceived(uint256 got, uint256 minOut);
    /// @notice The first key must be an ETH pool: `currency0` has to be native ether.
    error EthLegIsNotNative();
    /// @notice The second key must contain the pair currency the first key trades against.
    error PairIsNotInTheLaunchPool();
    /// @notice Spot already sits on the price limit for this direction, so `Pool.swap` would
    ///         reject the trade outright. A pool that has never been bought from cannot be sold
    ///         into — that is a v4 property, not a fault in the pool.
    error PoolIsPinnedAtItsPriceLimit(bool zeroForOne);
    /// @notice One of the hops was cut short by its own price limit, so the pair currency did not
    ///         cancel between the legs. Reduce the size.
    error IntermediateLegDidNotNet(int256 residual);
    error EthRefundFailed();
    /// @notice `settle()` credited less than was handed to the singleton. The only way that
    ///         happens is if something moved the manager's balance between our `sync` and our
    ///         `settle` — i.e. if this router was refactored to swap inside that window.
    error SettlementShortfall(uint256 handedOver, uint256 credited);
    /// @notice Not a failure. The quote entry points deliberately revert with the answer so that
    ///         quoting can never be used to execute a floorless swap, and so a quote needs neither
    ///         a balance nor an approval — the revert unwinds before anything is settled.
    error ZapQuote(uint256 amountOut);

    event Zapped(
        address indexed trader,
        address indexed recipient,
        address indexed token,
        bool isBuy,
        uint256 amountIn,
        uint256 amountOut
    );

    struct ZapData {
        /// ETH / pair. `currency0` is native ether. **Ignored entirely when the pair IS weth** —
        /// see `_isWrapPair`.
        PoolKey ethKey;
        /// pair / launch token, in whichever order they sorted. Carries `FeeHook`.
        PoolKey tokenKey;
        bool isBuy;
        bool quoteOnly;
        uint256 amountIn;
        address payer;
        address recipient;
    }

    constructor(IPoolManager _poolManager, address _weth) {
        poolManager = _poolManager;
        weth = _weth;
    }

    /// @dev Refuses ether from everyone except the wrapper.
    ///
    ///      **This is NOT a guarantee that the router's balance is always its current caller's.**
    ///      `selfdestruct` and a coinbase payout both credit an address without executing code, so
    ///      a `receive()` guard cannot keep the balance clean and nothing built on top of it may
    ///      assume otherwise. That assumption was written here and was wrong; the refund path now
    ///      measures what THIS call brought instead of trusting the balance.
    receive() external payable {
        if (msg.sender != weth) revert UnexpectedEther();
    }

    modifier before(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired(deadline, block.timestamp);
        _;
    }

    // ===============================================================================================
    // Entry points
    // ===============================================================================================

    /// @notice Spend ETH, receive the launch token. `msg.value` is the amount in.
    /// @param minAmountOut Floor in launch-token units. Must not be zero.
    /// @param deadline Unix seconds after which this must not execute.
    ///
    /// @dev **`minAmountOut` bounds price; `deadline` bounds TIME, and they are not the same
    ///      guard.** A transaction can sit unmined for hours and then land into a market that has
    ///      moved far enough that the floor derived from a stale quote is no longer protective.
    ///      Every production router takes one; omitting it was an oversight in the first version.
    function zapBuy(
        PoolKey calldata ethKey,
        PoolKey calldata tokenKey,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external payable before(deadline) returns (uint256 amountOut) {
        if (msg.value == 0) revert ZeroAmount();
        if (minAmountOut == 0) revert NoSlippageFloor();

        // **Baselines taken BEFORE anything moves.** Everything refunded below is measured against
        // these, so this call can only ever hand back what it itself brought. Value that was
        // already sitting here — forced in with `selfdestruct`, or an ERC-20 sent to the wrong
        // address — stays exactly where it is instead of being paid to whoever calls next.
        uint256 etherBefore = address(this).balance - msg.value;

        Currency pair = ethKey.currency1;
        bool wrap = _isWrapPair(pair);
        // Hop 1 for a WETH-paired launch is a WRAP, not a swap: 1:1, no fee, no price impact, no
        // pool required. Doing it out here keeps the unlock callback to a single leg.
        uint256 wrappedBefore;
        if (wrap) {
            wrappedBefore = IERC20(weth).balanceOf(address(this));
            IWETH9(weth).deposit{value: msg.value}();
        }

        amountOut = _run(ethKey, tokenKey, true, false, msg.value, recipient);

        // Checked out here rather than inside the callback: reverting mid-unlock unwinds the
        // manager's accounting in flight, while reverting here unwinds the whole transaction
        // cleanly and names both numbers.
        if (amountOut < minAmountOut) revert TooLittleReceived(amountOut, minAmountOut);

        // A hop cut short by its price limit leaves wrapped ether behind. Unwrap only what this
        // call is still holding of its own, so the refund reaches the caller as the asset they sent.
        if (wrap) {
            uint256 held = IERC20(weth).balanceOf(address(this));
            if (held > wrappedBefore) IWETH9(weth).withdraw(held - wrappedBefore);
        }
        _refundEth(etherBefore);
    }

    /// @notice Spend the launch token, receive ETH.
    /// @param minAmountOut Floor in wei. Must not be zero.
    /// @param deadline Unix seconds after which this must not execute.
    function zapSell(
        PoolKey calldata ethKey,
        PoolKey calldata tokenKey,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external before(deadline) returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (minAmountOut == 0) revert NoSlippageFloor();

        address to = recipient == address(0) ? msg.sender : recipient;
        amountOut = _run(ethKey, tokenKey, false, false, amountIn, to);

        if (amountOut < minAmountOut) revert TooLittleReceived(amountOut, minAmountOut);

        // On the wrap path the callback took WETH to this contract rather than native ether to the
        // recipient, because unwrapping cannot happen inside the unlock cycle.
        if (_isWrapPair(ethKey.currency1)) {
            IWETH9(weth).withdraw(amountOut);
            (bool ok,) = to.call{value: amountOut}("");
            if (!ok) revert EthRefundFailed();
        }
    }

    /// @notice Simulation only. **Always reverts** with `ZapQuote(amountOut)`.
    ///
    /// @dev Needs no ETH and no approval: the revert happens after both swaps and before any
    ///      settlement, so the manager's accounting is discarded along with everything else. This
    ///      is how a frontend derives a slippage floor without ever sending a floorless swap.
    function quoteZapBuy(PoolKey calldata ethKey, PoolKey calldata tokenKey, uint256 amountIn) external {
        if (amountIn == 0) revert ZeroAmount();
        _run(ethKey, tokenKey, true, true, amountIn, msg.sender);
    }

    /// @notice Simulation only. **Always reverts** with `ZapQuote(amountOut)`.
    function quoteZapSell(PoolKey calldata ethKey, PoolKey calldata tokenKey, uint256 amountIn) external {
        if (amountIn == 0) revert ZeroAmount();
        _run(ethKey, tokenKey, false, true, amountIn, msg.sender);
    }

    // ===============================================================================================
    // Unlock cycle
    // ===============================================================================================

    function _run(
        PoolKey calldata ethKey,
        PoolKey calldata tokenKey,
        bool isBuy,
        bool quoteOnly,
        uint256 amountIn,
        address recipient
    ) internal returns (uint256) {
        // The router has no rescue function, so anything delivered to it is stranded. `address(0)`
        // already resolves to the caller; naming the router explicitly is the one case that would
        // silently park somebody's output here forever.
        if (recipient == address(this)) revert RecipientIsTheRouter();
        bytes memory result = poolManager.unlock(
            abi.encode(
                ZapData({
                    ethKey: ethKey,
                    tokenKey: tokenKey,
                    isBuy: isBuy,
                    quoteOnly: quoteOnly,
                    amountIn: amountIn,
                    payer: msg.sender,
                    recipient: recipient == address(0) ? msg.sender : recipient
                })
            )
        );
        return abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        ZapData memory d = abi.decode(raw, (ZapData));

        if (!d.ethKey.currency0.isAddressZero()) revert EthLegIsNotNative();
        Currency pair = d.ethKey.currency1;

        // Which side of the launch pool is the token is a FACT derivable from the first key, not
        // something the caller gets to assert.
        bool pairIsCurrency0 = d.tokenKey.currency0 == pair;
        if (!pairIsCurrency0 && !(d.tokenKey.currency1 == pair)) revert PairIsNotInTheLaunchPool();
        Currency launchToken = pairIsCurrency0 ? d.tokenKey.currency1 : d.tokenKey.currency0;

        // When the pair IS wrapped ether there is no hop 1 at all — wrapping is 1:1 and happens
        // outside this cycle, so the router arrives already holding the pair currency.
        bool wrap = _isWrapPair(pair);

        // SWAP EVERY HOP FIRST. Nothing is paid or collected until every swap is done; see the
        // contract docstring for the 8.5x that this ordering is the only defence against.
        if (d.isBuy) {
            // hop 1: ETH -> pair. Native ether is currency0, so spending it is zeroForOne.
            uint256 pairIn = wrap ? d.amountIn : _hop(d.ethKey, true, d.amountIn);
            // hop 2: pair -> launch token.
            _hop(d.tokenKey, pairIsCurrency0, pairIn);
        } else {
            // hop 2 reversed: launch token -> pair.
            uint256 pairOut = _hop(d.tokenKey, !pairIsCurrency0, d.amountIn);
            // hop 1 reversed: pair -> ETH.
            if (!wrap) _hop(d.ethKey, false, pairOut);
        }

        // Read what the manager says we owe and are owed, rather than inferring it from the two
        // returned deltas. These three numbers are the settlement, and `unlock` reverts on any
        // non-zero delta — credit as well as debt, since `NonzeroDeltaCount` is sign-agnostic.
        int256 ethDelta = poolManager.currencyDelta(address(this), CurrencyLibrary.ADDRESS_ZERO);
        int256 pairDelta = poolManager.currencyDelta(address(this), pair);
        int256 tokenDelta = poolManager.currencyDelta(address(this), launchToken);

        // **Off the wrap path the pair must cancel exactly**; on it, the pair IS a settled leg
        // because the router holds wrapped ether directly instead of routing through a pool.
        uint256 amountOut;
        if (wrap) {
            // A buy owes wrapped ether and can only owe LESS than it wrapped (a truncated hop 2
            // spends less), which the caller gets back as ether. A sell is owed it.
            if (d.isBuy ? pairDelta > 0 : pairDelta < 0) revert IntermediateLegDidNotNet(pairDelta);
            amountOut = uint256(d.isBuy ? tokenDelta : pairDelta);
        } else {
            if (pairDelta != 0) revert IntermediateLegDidNotNet(pairDelta);
            amountOut = uint256(d.isBuy ? tokenDelta : ethDelta);
        }
        if (d.quoteOnly) revert ZapQuote(amountOut);

        // Pay the debts. Each `sync -> transfer -> settle` is contiguous on purpose: anything that
        // moves the singleton's balance in between is money we do not get credited for.
        if (wrap && pairDelta < 0) {
            // Paid from the router's OWN balance, not pulled from the payer: the wrap already
            // moved their ether into this contract.
            uint256 owed = uint256(-pairDelta);
            poolManager.sync(pair);
            IERC20(Currency.unwrap(pair)).safeTransfer(address(poolManager), owed);
            uint256 credited = poolManager.settle();
            if (credited != owed) revert SettlementShortfall(owed, credited);
        }
        if (tokenDelta < 0) {
            uint256 owed = uint256(-tokenDelta);
            poolManager.sync(launchToken);
            IERC20(Currency.unwrap(launchToken)).safeTransferFrom(d.payer, address(poolManager), owed);
            // **Turns the 8.5x from silent into loud.** `settle()` reports what it credited; if a
            // future refactor moves a swap inside this window, the shortfall stops being an
            // invisible overcharge and becomes a named revert.
            uint256 credited = poolManager.settle();
            if (credited != owed) revert SettlementShortfall(owed, credited);
        }
        if (ethDelta < 0) {
            uint256 owed = uint256(-ethDelta);
            // For native ether `sync` only resets the synced-currency slot; `_settle` then reads
            // `msg.value` and never touches `balanceOfSelf`, which is why the ETH leg is immune to
            // the hook's mid-swap movements and the pair leg is not.
            poolManager.sync(CurrencyLibrary.ADDRESS_ZERO);
            uint256 credited = poolManager.settle{value: owed}();
            if (credited != owed) revert SettlementShortfall(owed, credited);
        }

        // Collect, straight to the recipient.
        if (tokenDelta > 0) poolManager.take(launchToken, d.recipient, uint256(tokenDelta));
        if (ethDelta > 0) poolManager.take(CurrencyLibrary.ADDRESS_ZERO, d.recipient, uint256(ethDelta));
        // The wrapped-ether leg of a sell comes HERE, not to the recipient: it has to be unwrapped
        // first, and `WETH.withdraw` cannot run inside an open unlock cycle.
        if (wrap && pairDelta > 0) poolManager.take(pair, address(this), uint256(pairDelta));

        emit Zapped(
            d.payer, d.recipient, Currency.unwrap(launchToken), d.isBuy, d.amountIn, amountOut
        );

        return abi.encode(amountOut);
    }

    // ===============================================================================================
    // Internals
    // ===============================================================================================

    /// @dev True when hop 1 is a wrap rather than a swap.
    ///
    ///      **The pool is deliberately ignored even when one exists.** There IS a live ETH/WETH v4
    ///      pool on mainnet with real liquidity, and routing through it would cost the LP fee plus
    ///      the protocol fee plus price impact — measured at 6.3 bps — to perform an operation
    ///      `WETH.deposit()` does for free at exactly 1:1. When `weth` is zero the shortcut is off
    ///      and hop 1 goes through a pool like every other pair.
    function _isWrapPair(Currency pair) internal view returns (bool) {
        return weth != address(0) && Currency.unwrap(pair) == weth;
    }

    /// @dev One exact-input leg. Returns how much of the OUTPUT currency this swap produced.
    function _hop(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (uint256) {
        if (amountIn == 0) revert ZeroAmount();
        // **`-int256(amountIn)` is only an exact-INPUT swap while the value fits.** At or above
        // 2**255 the negation wraps positive and v4 reads it as exact OUTPUT — the pool would then
        // choose the input rather than the caller, silently, on the "sell everything" idiom
        // (`type(uint256).max`). Bounded to int128 because every v4 delta is an int128 anyway.
        if (amountIn > uint256(uint128(type(int128).max))) revert AmountTooLarge(amountIn);
        _requireNotPinned(key, zeroForOne);

        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn), // negative = exact input
                sqrtPriceLimitX96: limit
            }),
            ""
        );

        // `PoolManager.swap` returns the delta already net of the hook's own share
        // (`Hooks.afterSwap` does `swapDelta = swapDelta - hookDelta` before the manager accounts
        // it), so this is what THIS router received, not what the pool moved.
        int128 out = zeroForOne ? delta.amount1() : delta.amount0();
        return out > 0 ? uint256(uint128(out)) : 0;
    }

    /// @dev Spot sitting exactly on the limit makes `Pool.swap` reject the trade with a raw
    ///      `PriceLimitAlreadyExceeded`, which reads to a trader like a honeypot. A launch that has
    ///      never been bought from sits at its opening tick with nothing below it, so EVERY sell is
    ///      refused until a buy lifts it off. Name it.
    function _requireNotPinned(PoolKey memory key, bool zeroForOne) internal view {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) return; // uninitialised: let the manager give its own error
        if (zeroForOne) {
            if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE + 1) revert PoolIsPinnedAtItsPriceLimit(true);
        } else {
            if (sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE - 1) revert PoolIsPinnedAtItsPriceLimit(false);
        }
    }

    /// @dev A hop cut short by its price limit leaves ether unspent, and it goes back in the same
    ///      transaction.
    ///
    ///      **Refunds the delta against a baseline, never the whole balance.** Paying out
    ///      `address(this).balance` hands this caller anything that was already here, and — worse
    ///      — makes `zapBuy` revert `EthRefundFailed` for every contract caller without a payable
    ///      fallback the moment somebody forces one wei in, since the refund call runs even when
    ///      there is nothing to refund. Both are closed by measuring instead of trusting.
    function _refundEth(uint256 baseline) internal {
        uint256 balance = address(this).balance;
        if (balance <= baseline) return;
        (bool ok,) = msg.sender.call{value: balance - baseline}("");
        if (!ok) revert EthRefundFailed();
    }
}
