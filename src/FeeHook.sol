// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HookBase} from "./base/HookBase.sol";
import {Distributor} from "./Distributor.sol";

/// @title FeeHook
/// @notice Takes the trading fee INSIDE the swap and routes it to holders in the pair currency.
///
/// @dev This is the contract the whole design rests on. Three properties matter:
///
///      1. **The fee is taken by the hook, not by the token.** `LaunchToken` has no transfer fee,
///         so wallet-to-wallet moves are free and no venue can route around the fee by avoiding
///         our contract. Every swap through this pool pays, whatever the frontend.
///
///      2. **The fee is always taken in the PAIR currency.** Holders are paid in WETH/PEPE/WXMR,
///         not in more of the token they already hold. To guarantee that, the fee is only ever
///         charged on a BUY - the leg where the pair currency is what the pool receives. Charging a
///         sell would mean taking launch tokens and needing to sell them for the pair, which is a
///         swap inside a swap and a reentrancy problem. Buys only, by construction.
///
///      3. **A buy has to be charged in two different places, and this is the subtle part.**
///         A hook's returned delta can only move ONE side of the swap: `beforeSwap` adjusts the
///         SPECIFIED currency, `afterSwap` adjusts the UNSPECIFIED currency. Which of those the pair
///         currency happens to be is decided by the caller's exactness mode, not by us:
///
///         ```
///                            specified   unspecified   charge in
///           buy  exact-in       pair        token      beforeSwap
///           buy  exact-out      token       pair       afterSwap
///           sell exact-in       token       pair       (not charged - sells are free)
///           sell exact-out      pair        token      (not charged - sells are free)
///         ```
///
///         An earlier version implemented only the `afterSwap` half. It was correct for every case
///         it handled and collected **exactly zero** on an exact-input buy - which is the shape every
///         router, aggregator and swap UI sends by default. The pool worked, the fee silently did
///         not. `test_onlyExactOutputBuysAreCharged` is the regression marker for that.
///
///      4. **Hook flags must be 0x20CC.** BEFORE_INITIALIZE (0x2000), BEFORE_SWAP (0x0080),
///         AFTER_SWAP (0x0040), BEFORE_SWAP_RETURNS_DELTA (0x0008), AFTER_SWAP_RETURNS_DELTA
///         (0x0004). The deployed address must encode exactly these in its low 14 bits or the
///         constructor reverts. Every deployment needs a mined CREATE2 salt.
///
///         This is deliberately NOT the 0x2044 that BaseStonk and Pons both use. They can live
///         without `beforeSwap` because they let the fee land on whichever token the swap outputs;
///         paying dividends strictly in the pair currency is what forces the extra two flags.
///
///      SETTLEMENT: `afterSwap` returns a positive int128 on the UNSPECIFIED currency, which tells
///      the PoolManager the hook is owed that much. We must then actually `take()` it, or the
///      unlock cycle ends with a non-zero delta and the whole transaction reverts with
///      `CurrencyNotSettled`. Returning a delta without taking is the single most common way a v4
///      hook bricks every swap in its pool.
contract FeeHook is HookBase {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Per-pool configuration, written once by the launcher at initialize.
    /// @param distributor  where holder dividends are sent
    /// @param pairCurrency the currency fees are taken and paid in
    /// @param feeBps       total fee in basis points, capped at MAX_FEE_BPS
    /// @param creator      receives the creator share
    /// @param creatorBps   creator's cut of `feeBps`; the remainder goes to holders
    /// @param configured   guards against a pool being initialised without config
    struct PoolConfig {
        address distributor;
        Currency pairCurrency;
        uint16 feeBps;
        address creator;
        uint16 creatorBps;
        bool configured;
    }

    /// @notice Hard ceiling on total fee. 10% is the most any launch may charge.
    uint16 public constant MAX_FEE_BPS = 1000;
    /// @notice Basis point denominator.
    uint16 public constant BPS = 10_000;

    /// @notice The only address allowed to register a pool config. Set once at deploy.
    address public immutable launcher;

    mapping(PoolId => PoolConfig) public poolConfig;
    /// @notice Fees collected per pool, in the pair currency. Diagnostics only.
    mapping(PoolId => uint256) public totalFeesTaken;

    event PoolConfigured(
        PoolId indexed poolId, address distributor, Currency pairCurrency, uint16 feeBps, address creator
    );
    event FeeTaken(PoolId indexed poolId, uint256 total, uint256 toHolders, uint256 toCreator);

    error OnlyLauncher();
    error AlreadyConfigured();
    error NotConfigured();
    error FeeTooHigh(uint16 given);
    error CreatorShareTooHigh(uint16 given);
    error ZeroAddress();

    constructor(IPoolManager _poolManager, address _launcher) HookBase(_poolManager) {
        if (_launcher == address(0)) revert ZeroAddress();
        launcher = _launcher;
    }

    /// @inheritdoc HookBase
    /// @dev Encodes to 0x20CC. Any other deployed address fails `validateHookPermissions`.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------------------------

    /// @notice Register a pool's fee split before its pool is initialised.
    /// @dev Callable only by the launcher, and only once per pool. Immutable afterwards: a fee
    ///      split that can be changed after people have bought is a rug with extra steps.
    function configurePool(
        PoolKey calldata key,
        address distributor,
        Currency pairCurrency,
        uint16 feeBps,
        address creator,
        uint16 creatorBps
    ) external {
        if (msg.sender != launcher) revert OnlyLauncher();
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh(feeBps);
        if (creatorBps > BPS) revert CreatorShareTooHigh(creatorBps);
        if (distributor == address(0) || creator == address(0)) revert ZeroAddress();

        PoolId id = key.toId();
        if (poolConfig[id].configured) revert AlreadyConfigured();

        poolConfig[id] = PoolConfig({
            distributor: distributor,
            pairCurrency: pairCurrency,
            feeBps: feeBps,
            creator: creator,
            creatorBps: creatorBps,
            configured: true
        });

        emit PoolConfigured(id, distributor, pairCurrency, feeBps, creator);
    }

    // -------------------------------------------------------------------------------------------
    // Hook callbacks
    // -------------------------------------------------------------------------------------------

    /// @dev Refuses to let a pool open against this hook unless the launcher configured it first.
    ///      Without this, anyone could open a pool pointing at our hook and swaps would revert on
    ///      a missing config - or worse, take fees to a zero address.
    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal
        view
        override
        returns (bytes4)
    {
        if (!poolConfig[key.toId()].configured) revert NotConfigured();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Charges the EXACT-INPUT BUY leg, where the pair currency is the swap's SPECIFIED side
    ///      and is therefore untouchable from `afterSwap`.
    ///
    ///      The returned specified-delta is positive, which credits the hook and shrinks the amount
    ///      the core curve swaps: `amountToSwap += hookDeltaSpecified`, so `-1000` becomes `-970`
    ///      for a 3% fee. The trader still pays 1000; 30 never reaches the pool.
    ///
    ///      TRADEOFF, deliberate and documented: this charges the amount the trader REQUESTED, not
    ///      the amount the pool ultimately consumed. If a `sqrtPriceLimitX96` stops the swap early,
    ///      the unspent input is refunded to the trader but the fee on it is not. Moving the charge
    ///      to `afterSwap` would fix that and reintroduce the zero-fee hole this exists to close;
    ///      the partial-fill case is rare and the overcharge is bounded by `feeBps`.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfig[id];
        if (!cfg.configured || cfg.feeBps == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Exact-output swaps specify the OUTPUT, so the pair currency is never the specified side
        // on a buy. Those are handled in `_afterSwap`.
        if (params.amountSpecified >= 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // A buy pays the pair currency in. The payer's side is currency0 when `zeroForOne`, so this
        // is a buy exactly when the pair sits on the side being paid.
        bool pairIsCurrency0 = Currency.unwrap(cfg.pairCurrency) == Currency.unwrap(key.currency0);
        if (params.zeroForOne != pairIsCurrency0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 pairIn = uint256(-params.amountSpecified);
        uint256 fee = (pairIn * cfg.feeBps) / BPS;
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        poolManager.take(cfg.pairCurrency, address(this), fee);
        _routeFee(id, cfg, fee);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    /// @dev Charges the EXACT-OUTPUT BUY leg, where the pair currency is the UNSPECIFIED side.
    ///
    ///      The returned int128 is a delta on the unspecified currency. Positive means the hook is
    ///      owed. We take exactly that amount in the same call so the unlock cycle balances.
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfig[id];
        if (!cfg.configured || cfg.feeBps == 0) return (IHooks.afterSwap.selector, 0);

        bool pairIsCurrency0 = Currency.unwrap(cfg.pairCurrency) == Currency.unwrap(key.currency0);

        // The pool's delta on the pair currency. Negative = the POOL received pair currency,
        // which is a buy of the launch token. That is the only leg we charge.
        int128 pairDelta = pairIsCurrency0 ? delta.amount0() : delta.amount1();
        if (pairDelta >= 0) return (IHooks.afterSwap.selector, 0);

        // Only chargeable when the pair currency is the UNSPECIFIED side, because this return value
        // can only adjust the unspecified currency. When the pair IS the specified side the swap is
        // an exact-input buy and `_beforeSwap` already charged it - this guard is what stops the
        // two legs double-charging the same trade.
        bool exactInput = params.amountSpecified < 0;
        bool specifiedIsCurrency0 = exactInput == params.zeroForOne;
        if (specifiedIsCurrency0 == pairIsCurrency0) return (IHooks.afterSwap.selector, 0);

        uint256 pairIn = uint256(uint128(-pairDelta));
        uint256 fee = (pairIn * cfg.feeBps) / BPS;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        // Claim the fee from the PoolManager into this contract, then forward it. Skipping the
        // take() here is what produces CurrencyNotSettled and bricks the pool.
        poolManager.take(cfg.pairCurrency, address(this), fee);
        _routeFee(id, cfg, fee);

        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    /// @dev Splits a collected fee between creator and holders and forwards both. Shared by the two
    ///      charging legs so they can never drift apart.
    ///
    ///      Sends are raw calls: a hostile or blocklisted creator must not be able to revert the
    ///      swap. A failed payout strands the tokens on this contract rather than trapping every
    ///      trader in the pool.
    function _routeFee(PoolId id, PoolConfig memory cfg, uint256 fee) internal {
        uint256 toCreator = (fee * cfg.creatorBps) / BPS;
        uint256 toHolders = fee - toCreator;

        address pairToken = Currency.unwrap(cfg.pairCurrency);
        if (toCreator != 0) _trySend(pairToken, cfg.creator, toCreator);
        if (toHolders != 0) {
            if (_trySend(pairToken, cfg.distributor, toHolders)) {
                Distributor(cfg.distributor).distribute(toHolders);
            }
        }

        totalFeesTaken[id] += fee;
        emit FeeTaken(id, fee, toHolders, toCreator);
    }

    /// @dev Raw call so a hostile or non-standard recipient cannot revert the whole swap. A failed
    ///      payout leaves the tokens on this contract rather than trapping every trader in the pool.
    function _trySend(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}
