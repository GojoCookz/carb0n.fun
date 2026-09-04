// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TradeRouter
/// @notice The one contract a buyer or seller actually calls. Two functions, no Permit2.
///
/// @dev **Why this exists when Uniswap ships a UniversalRouter.**
///
///      Uniswap's router is live on Sepolia and works, but reaching it from a browser means
///      encoding a command stream and routing approvals through Permit2 — two extra concepts and
///      an extra signature for somebody who wants to press Buy. This is a swap and a slippage
///      check. A launchpad whose trade button is harder to use than its launch button has the
///      product backwards.
///
///      **SETTLEMENT ORDER IS LOAD-BEARING AND THAT IS THE SECOND REASON.** `FeeHook` can move
///      real ERC-20 out of the singleton from inside `afterSwap` (its opportunistic sweep), and
///      `PoolManager._settle` credits `balanceOfSelf() - syncedReserves`. Anything that leaves
///      between a payer's `sync` and their `settle` is silently deducted from what they are
///      credited. A `sync -> transfer -> swap -> settle` router — perfectly legal v4, and what you
///      write if you want to pay once up front — was MEASURED being overcharged 8.5x on an
///      identical trade, or reverting on a bare arithmetic panic when the backlog exceeded the
///      prepay. This router swaps FIRST and settles from the resulting delta, which is what
///      Uniswap's own routers do and the only ordering that is safe against a hook like ours.
contract TradeRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error TooLittleReceived(uint256 got, uint256 minOut);
    error ZeroAmount();

    event Traded(
        PoolKey key,
        address indexed trader,
        address indexed recipient,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    );

    struct CallbackData {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        address payer;
        address recipient;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Swap an exact amount in, reverting unless at least `minAmountOut` comes back.
    ///
    /// @dev `zeroForOne` is the caller's, not derived here. Which direction is a BUY depends on
    ///      how the launch token and the pair currency sort by address, which the frontend
    ///      already knows from the pool key it is holding. Deriving it here would mean this
    ///      contract needing to know which side is the launch token, which it has no honest way
    ///      to determine.
    ///
    ///      **Exact-input only.** Every router and aggregator sends this shape by default, and
    ///      it is the shape `FeeHook` charges correctly; supporting exact-output would double the
    ///      surface for a button nobody presses.
    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();

        bytes memory result = poolManager.unlock(
            abi.encode(
                CallbackData({
                    key: key,
                    zeroForOne: zeroForOne,
                    amountIn: amountIn,
                    payer: msg.sender,
                    recipient: recipient == address(0) ? msg.sender : recipient
                })
            )
        );
        amountOut = abi.decode(result, (uint256));

        // **Checked here, outside the unlock cycle, on purpose.** Reverting inside the callback
        // would unwind the manager's accounting mid-flight; reverting here unwinds the whole
        // transaction cleanly and gives the caller an error naming both numbers.
        if (amountOut < minAmountOut) revert TooLittleReceived(amountOut, minAmountOut);

        emit Traded(key, msg.sender, recipient, zeroForOne, amountIn, amountOut);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        CallbackData memory d = abi.decode(raw, (CallbackData));

        // SWAP FIRST. See the contract docstring — settling before this is what gets a router
        // overcharged by a hook that moves ERC-20 during `afterSwap`.
        BalanceDelta delta = poolManager.swap(
            d.key,
            SwapParams({
                zeroForOne: d.zeroForOne,
                amountSpecified: -int256(d.amountIn), // negative = exact input
                sqrtPriceLimitX96: d.zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        Currency inCurrency = d.zeroForOne ? d.key.currency0 : d.key.currency1;
        Currency outCurrency = d.zeroForOne ? d.key.currency1 : d.key.currency0;
        int128 inDelta = d.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = d.zeroForOne ? delta.amount1() : delta.amount0();

        // Pay what we owe. `inDelta` is negative for the side we spent.
        if (inDelta < 0) {
            uint256 owed = uint256(uint128(-inDelta));
            poolManager.sync(inCurrency);
            IERC20(Currency.unwrap(inCurrency)).safeTransferFrom(
                d.payer, address(poolManager), owed
            );
            poolManager.settle();
        }

        // Collect what we are owed, straight to the recipient.
        uint256 amountOut;
        if (outDelta > 0) {
            amountOut = uint256(uint128(outDelta));
            poolManager.take(outCurrency, d.recipient, amountOut);
        }

        // **Both sides are handled even though a swap normally moves one each way.** A hook that
        // returns a delta can leave this router owing or owed on a side it did not expect, and
        // `unlock` reverts on ANY non-zero delta — credit as well as debt.
        if (inDelta > 0) {
            poolManager.take(inCurrency, d.recipient, uint256(uint128(inDelta)));
        }
        if (outDelta < 0) {
            uint256 owed = uint256(uint128(-outDelta));
            poolManager.sync(outCurrency);
            IERC20(Currency.unwrap(outCurrency)).safeTransferFrom(
                d.payer, address(poolManager), owed
            );
            poolManager.settle();
        }

        return abi.encode(amountOut);
    }
}
