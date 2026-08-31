// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {FeeHook} from "./FeeHook.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {PairRegistry} from "./PairRegistry.sol";
import {LaunchMetadata} from "./types/LaunchMetadata.sol";

/// @title Launcher
/// @notice Creates a launch in one transaction: clone the token, wire its dividend ledger, open the
///         v4 pool, seed it, optionally let the creator buy in, and lock the liquidity forever.
///
/// @dev **Liquidity is locked by having no way out, not by burning something.**
///      In v4 a liquidity position belongs to whoever called `modifyLiquidity`, keyed by
///      `(owner, tickLower, tickUpper, salt)`. This contract opens the position in its own name and
///      contains no code path that passes a negative `liquidityDelta` - no admin function, no
///      owner, no upgrade. The liquidity is therefore unremovable by construction rather than by
///      the honour system. That is strictly stronger than the usual "we burned the LP NFT", which
///      only works if you also trust that the NFT was the only handle.
///
///      **Every launch is an EIP-1167 clone.** `LaunchToken`'s creation code is ~8 KB; embedding it
///      here via `new LaunchToken(...)` would put all 8 KB into THIS contract's runtime and is the
///      single biggest EIP-170 risk in the design. `Clones.cloneDeterministic` writes 45 bytes
///      instead and keeps the token bytecode out of the launcher entirely.
///
///      **Nothing here is configurable after the fact.** Fee split, creator share, max wallet and
///      metadata are all written during `launch` and there is no setter for any of them. A fee
///      split that can change after people have bought is a rug with extra steps.
contract Launcher is IUnlockCallback, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // -----------------------------------------------------------------------------------------
    // Immutable wiring
    // -----------------------------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    FeeHook public immutable feeHook;
    PairRegistry public immutable pairRegistry;
    /// @notice The `LaunchToken` implementation every launch clones.
    address public immutable tokenImplementation;

    /// @notice Hard ceiling on the creator's opening buy, as a share of total supply.
    /// @dev A dev buy is legitimate - a creator with zero position has nothing at stake. A dev buy
    ///      large enough to own the float is a rug in progress. We revert rather than silently
    ///      trimming: silent adjustment is how users get surprised.
    uint16 public constant MAX_DEV_BUY_BPS = 1000; // 10% of supply
    /// @notice Smallest max-wallet cap a launch may set, as a share of supply.
    /// @dev Below this the cap stops being anti-whale and becomes a transfer blocker.
    uint16 public constant MIN_MAX_WALLET_BPS = 10; // 0.1%
    uint16 public constant BPS = 10_000;

    /// @notice Full-range positions use the widest ticks the spacing allows.
    bytes32 internal constant LP_SALT = bytes32(0);

    // -----------------------------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------------------------

    /// @param name             token name
    /// @param symbol           token symbol
    /// @param supply           fixed total supply, all of it seeded into the pool
    /// @param pair             the pair currency; must be approved in `PairRegistry`
    /// @param pairSeed         how much pair currency the creator adds as opening liquidity
    /// @param graduationThreshold market cap, in PAIR-CURRENCY units, at which this launch is
    ///                         signalled as mature. Must exceed `pairSeed` - see `_validate`.
    /// @param feeBps           total trading fee, capped by `FeeHook.MAX_FEE_BPS`
    /// @param creatorBps       creator's cut of the fee; the remainder goes to holders
    /// @param maxWalletBps     buy cap as a share of supply, or 0 to disable
    /// @param tickSpacing      pool tick spacing
    /// @param devBuyPairAmount optional opening buy by the creator, in pair currency
    /// @param salt             clone salt; mine it off-chain to control currency ordering
    /// @param minPushPayout    dust guard for the Distributor's push path
    /// @param minShareForQueue balance below which a holder is not queued for pushes
    /// @param metadata         image / banner / info CIDs
    struct LaunchParams {
        string name;
        string symbol;
        uint256 supply;
        address pair;
        uint256 pairSeed;
        uint256 graduationThreshold;
        uint16 feeBps;
        uint16 creatorBps;
        uint16 maxWalletBps;
        int24 tickSpacing;
        uint256 devBuyPairAmount;
        bytes32 salt;
        uint256 minPushPayout;
        uint256 minShareForQueue;
        LaunchMetadata metadata;
    }

    /// @dev Passed through `unlock` into `unlockCallback`. Kept in memory rather than storage so a
    ///      failed launch leaves nothing behind.
    struct SeedData {
        PoolKey key;
        address token;
        uint256 tokenSeed;
        uint256 pairSeed;
        uint256 devBuyPairAmount;
        address creator;
        bool tokenIsCurrency0;
    }

    struct LaunchRecord {
        address token;
        address creator;
        address pair;
        uint64 launchedAt;
    }

    /// @notice Every launch this contract has created, in order.
    LaunchRecord[] public launches;
    /// @notice token address => 1-based index into `launches`. Zero means "not ours".
    mapping(address token => uint256) public launchIndexPlusOne;

    event Launched(
        address indexed token,
        address indexed creator,
        address indexed pair,
        PoolId poolId,
        uint256 supply,
        uint256 pairSeed,
        uint16 feeBps
    );

    error PairNotApproved(address pair);
    error ImageRequired();
    error SupplyTooLow();
    error SeedTooLow();
    error DevBuyTooLarge(uint256 given, uint256 cap);
    error MaxWalletTooSmall(uint16 given);
    error GraduationThresholdTooLow(uint256 given, uint256 openingMarketCap);
    error OnlyPoolManager();
    error LauncherRetainedFunds();
    error OpeningPriceOutOfRange();

    constructor(
        IPoolManager _poolManager,
        FeeHook _feeHook,
        PairRegistry _pairRegistry,
        address _tokenImplementation
    ) {
        poolManager = _poolManager;
        feeHook = _feeHook;
        pairRegistry = _pairRegistry;
        tokenImplementation = _tokenImplementation;
    }

    // -----------------------------------------------------------------------------------------
    // Launch
    // -----------------------------------------------------------------------------------------

    /// @notice Create a token, open its pool, seed it, and lock the liquidity. One transaction.
    /// @dev The caller must have approved this contract for `pairSeed + devBuyPairAmount` of `pair`.
    function launch(LaunchParams calldata p) external nonReentrant returns (address token, PoolId poolId) {
        _validate(p);

        // 1. Clone and initialise the token. All supply is minted here, to be seeded immediately.
        token = Clones.cloneDeterministic(tokenImplementation, p.salt);
        LaunchToken(token)
            .initialize(
                LaunchToken.InitParams({
                    name_: p.name,
                    symbol_: p.symbol,
                    supply: p.supply,
                    recipient: address(this),
                    payoutToken: p.pair,
                    controller: address(feeHook),
                    poolManager_: address(poolManager),
                    maxWallet_: p.maxWalletBps == 0 ? 0 : (p.supply * p.maxWalletBps) / BPS,
                    minPushPayout: p.minPushPayout,
                    minShareForQueue: p.minShareForQueue,
                    metadata: p.metadata
                })
            );

        // 2. Pull the creator's pair currency. Measure what ARRIVED - a fee-on-transfer pair would
        //    deliver less than requested and seeding the difference would revert deep inside the
        //    unlock cycle with an unreadable error.
        uint256 pull = p.pairSeed + p.devBuyPairAmount;
        uint256 balBefore = IERC20(p.pair).balanceOf(address(this));
        IERC20(p.pair).safeTransferFrom(msg.sender, address(this), pull);
        uint256 received = IERC20(p.pair).balanceOf(address(this)) - balBefore;
        uint256 devBuy = Math.min(p.devBuyPairAmount, received);
        uint256 pairSeed = received - devBuy;

        // 3. Build the pool key. Either currency ordering is valid - the hook handles both, proven
        //    by `FeeHookTokenIsCurrency0Test` / `FeeHookTokenIsCurrency1Test` - so the salt is a
        //    chart-orientation preference, not a correctness requirement.
        bool tokenIsCurrency0 = token < p.pair;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(tokenIsCurrency0 ? token : p.pair),
            currency1: Currency.wrap(tokenIsCurrency0 ? p.pair : token),
            // ZERO. The hook charges the fee, not the pool. Any indexer reading `PoolKey.fee`
            // reports the trading cost as 0% - `FeeHook.FeeTaken` carries the real number.
            fee: 0,
            tickSpacing: p.tickSpacing,
            hooks: IHooks(address(feeHook))
        });
        poolId = key.toId();

        // 4. Configure the hook BEFORE initialising the pool. `FeeHook.beforeInitialize` reverts on
        //    an unconfigured pool, which is what stops strangers attaching pools to our hook.
        feeHook.configurePool(
            key,
            address(LaunchToken(token).distributor()),
            Currency.wrap(p.pair),
            p.feeBps,
            msg.sender,
            p.creatorBps
        );

        // Graduation is a separate call rather than two more arguments on `configurePool`, so the
        // signature of the function that governs every fee this pool will ever charge stays exactly
        // as it was. A maturity notification has no business widening that surface.
        feeHook.configureGraduation(key, p.graduationThreshold, p.supply);

        poolManager.initialize(key, _openingSqrtPrice(p.supply, pairSeed, tokenIsCurrency0));

        // 5. Seed, dev-buy and settle, all inside one unlock.
        poolManager.unlock(
            abi.encode(
                SeedData({
                    key: key,
                    token: token,
                    tokenSeed: p.supply,
                    pairSeed: pairSeed,
                    devBuyPairAmount: devBuy,
                    creator: msg.sender,
                    tokenIsCurrency0: tokenIsCurrency0
                })
            )
        );

        // 6. Nothing may be left here. Asserted on chain, not just in a test - if a rounding change
        //    or a hostile pair currency ever strands value on this contract there is no sweep
        //    function to recover it, so the launch must fail loudly instead.
        _assertHoldsNothing(token, p.pair);

        launches.push(
            LaunchRecord({
                token: token, creator: msg.sender, pair: p.pair, launchedAt: uint64(block.timestamp)
            })
        );
        launchIndexPlusOne[token] = launches.length;

        emit Launched(token, msg.sender, p.pair, poolId, p.supply, pairSeed, p.feeBps);
    }

    function _validate(LaunchParams calldata p) internal view {
        if (!pairRegistry.isApproved(p.pair)) revert PairNotApproved(p.pair);
        // Image is required, banner is not. A token with no image is unlistable; a token with no
        // banner renders a fallback.
        if (p.metadata.imageCid == bytes32(0)) revert ImageRequired();
        if (p.supply < 1e18) revert SupplyTooLow();
        if (p.pairSeed == 0) revert SeedTooLow();
        if (p.maxWalletBps != 0 && p.maxWalletBps < MIN_MAX_WALLET_BPS) {
            revert MaxWalletTooSmall(p.maxWalletBps);
        }

        // The pool opens with the ENTIRE supply seeded against `pairSeed`, and the opening price is
        // exactly that ratio - so the opening market cap, measured in pair units, is exactly
        // `pairSeed`. A graduation threshold at or below it means the token is born graduated,
        // which turns the signal into noise on day one. This is the only bound worth enforcing:
        // how far above the opening a launch sets its bar is the creator's call, not ours.
        if (p.graduationThreshold <= p.pairSeed) {
            revert GraduationThresholdTooLow(p.graduationThreshold, p.pairSeed);
        }

        uint256 devCap = (p.pairSeed * MAX_DEV_BUY_BPS) / BPS;
        if (p.devBuyPairAmount > devCap) revert DevBuyTooLarge(p.devBuyPairAmount, devCap);
        // `feeBps` and `creatorBps` are validated by `FeeHook.configurePool`, which owns those caps.
    }

    /// @dev Opening price is the ratio of the two seeded amounts, so the pool opens exactly where
    ///      the creator's own liquidity says it should.
    ///
    ///      `sqrtPriceX96 = sqrt(amount1 / amount0) * 2^96`, computed as
    ///      `sqrt(mulDiv(amount1, 2^192, amount0))`. The `2^192` goes INSIDE the square root:
    ///      doing it as `sqrt(amount1/amount0) * 2^96` on integers truncates the ratio to zero for
    ///      any pair where the token is cheaper than the pair asset, which is every launch.
    function _openingSqrtPrice(uint256 supply, uint256 pairSeed, bool tokenIsCurrency0)
        internal
        pure
        returns (uint160)
    {
        (uint256 amount0, uint256 amount1) = tokenIsCurrency0 ? (supply, pairSeed) : (pairSeed, supply);

        uint256 ratioX192 = FullMath.mulDiv(amount1, FixedPoint96.Q96 * FixedPoint96.Q96, amount0);
        uint256 sqrtPrice = Math.sqrt(ratioX192);

        if (sqrtPrice < TickMath.MIN_SQRT_PRICE || sqrtPrice >= TickMath.MAX_SQRT_PRICE) {
            revert OpeningPriceOutOfRange();
        }
        return uint160(sqrtPrice);
    }

    // -----------------------------------------------------------------------------------------
    // Unlock cycle
    // -----------------------------------------------------------------------------------------

    /// @dev Every delta opened here must be closed before this returns, or the PoolManager reverts
    ///      the whole launch with `CurrencyNotSettled`.
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        SeedData memory d = abi.decode(raw, (SeedData));

        _seedLiquidity(d);
        if (d.devBuyPairAmount != 0) _devBuy(d);

        // Any pair currency the curve did not consume goes back to the creator rather than sitting
        // on a contract with no sweep function.
        _refundResidual(d);
        return "";
    }

    function _seedLiquidity(SeedData memory d) internal {
        int24 lower = TickMath.minUsableTick(d.key.tickSpacing);
        int24 upper = TickMath.maxUsableTick(d.key.tickSpacing);

        // `PoolManager` exposes no getters - pool state is read through `extsload`, which is what
        // `StateLibrary` wraps. Hand-rolling the slot derivation here would duplicate a constant
        // (`POOLS_SLOT = 6`) that lives in someone else's contract.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(d.key.toId());
        (uint256 amount0, uint256 amount1) =
            d.tokenIsCurrency0 ? (d.tokenSeed, d.pairSeed) : (d.pairSeed, d.tokenSeed);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            amount0,
            amount1
        );

        // The position is opened in THIS contract's name and there is no code path anywhere that
        // passes a negative liquidityDelta. That is the lock.
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            d.key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: LP_SALT
            }),
            ""
        );

        _settleDelta(d.key.currency0, delta.amount0());
        _settleDelta(d.key.currency1, delta.amount1());
    }

    /// @dev The creator's opening buy. This is a normal swap and the hook charges it a normal fee -
    ///      the creator does not get a free entry.
    function _devBuy(SeedData memory d) internal {
        // Buying the launch token means paying the pair currency in.
        bool zeroForOne = !d.tokenIsCurrency0;

        BalanceDelta delta = poolManager.swap(
            d.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(d.devBuyPairAmount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        _settleDelta(d.key.currency0, delta.amount0());
        _settleDelta(d.key.currency1, delta.amount1());

        // Hand the creator their tokens. They are subject to the same max-wallet cap as anyone -
        // the launcher is exempt, the creator is not.
        uint256 bought = IERC20(d.token).balanceOf(address(this));
        if (bought != 0) IERC20(d.token).safeTransfer(d.creator, bought);
    }

    /// @dev Positive delta = the manager owes us, so take it. Negative = we owe, so settle it.
    function _settleDelta(Currency currency, int128 amount) internal {
        if (amount == 0) return;
        if (amount > 0) {
            poolManager.take(currency, address(this), uint128(amount));
        } else {
            uint256 owed = uint256(uint128(-amount));
            // sync() FIRST - settle() credits `balanceNow - balanceBefore`, and without the
            // snapshot it diffs against a stale reserve and credits the wrong amount.
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), owed);
            poolManager.settle();
        }
    }

    function _refundResidual(SeedData memory d) internal {
        address pair =
            d.tokenIsCurrency0 ? Currency.unwrap(d.key.currency1) : Currency.unwrap(d.key.currency0);

        uint256 leftoverPair = IERC20(pair).balanceOf(address(this));
        if (leftoverPair != 0) IERC20(pair).safeTransfer(d.creator, leftoverPair);

        // Unseeded token dust cannot go to the creator - that would be an unadvertised allocation.
        // It is burned to the standard dead address, which the Distributor already excludes.
        uint256 leftoverToken = IERC20(d.token).balanceOf(address(this));
        if (leftoverToken != 0) IERC20(d.token).safeTransfer(address(0xdEaD), leftoverToken);
    }

    function _assertHoldsNothing(address token, address pair) internal view {
        if (IERC20(token).balanceOf(address(this)) != 0 || IERC20(pair).balanceOf(address(this)) != 0) {
            revert LauncherRetainedFunds();
        }
    }

    // -----------------------------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------------------------

    function launchCount() external view returns (uint256) {
        return launches.length;
    }

    /// @notice True if this launcher created `token`. The only trustworthy provenance check.
    function isOurs(address token) external view returns (bool) {
        return launchIndexPlusOne[token] != 0;
    }

    /// @notice Address a given salt will produce, so orientation can be mined off-chain.
    function predictTokenAddress(bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(tokenImplementation, salt, address(this));
    }
}
