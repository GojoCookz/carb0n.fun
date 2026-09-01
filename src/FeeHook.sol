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
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
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
    using StateLibrary for IPoolManager;

    /// @notice Per-pool configuration, written once by the launcher at initialize.
    /// @param distributor  where holder dividends are sent
    /// @param pairCurrency the currency fees are taken and paid in
    /// @param feeBps       total fee in basis points, capped at MAX_FEE_BPS
    /// @param creator      receives the creator share
    /// @param creatorBps   creator's cut of `feeBps`; the remainder goes to holders
    /// @param configured   guards against a pool being initialised without config
    /// @param feeBps     the BUY rate, charged in the pair currency
    /// @param sellFeeBps the SELL rate, charged in the launch token and converted on sweep. Set
    ///                   independently of the buy rate; zero means sells are free.
    /// @param burnBps    share of each swept fee that buys the launch token back from its own pool
    ///                   and sends it to the burn address
    struct PoolConfig {
        address distributor;
        Currency pairCurrency;
        uint16 feeBps;
        address creator;
        uint16 creatorBps;
        bool configured;
        uint16 sellFeeBps;
        uint16 burnBps;
    }

    /// @notice Per-pool graduation state. Written once by the launcher, latched once by anyone.
    ///
    /// @param threshold        market cap, **in pair-currency units**, at or above which the launch
    ///                         is considered mature. Immutable after `configureGraduation`.
    /// @param supply           the launch token's total supply, cached at configuration time.
    ///                         `LaunchToken` mints once in `initialize` and exposes no mint and no
    ///                         burn, so this can never go stale. `test_cachedSupplyStaysTrue` is the
    ///                         regression marker if that ever changes.
    /// @param token            the launch token, derived from the pool key - never passed in, so it
    ///                         cannot be set to something the pool does not actually contain.
    /// @param graduatedAt      block timestamp of the crossing; 0 while ungraduated.
    /// @param tokenIsCurrency0 which side of the pool the launch token sorted onto. Needed because
    ///                         `checkGraduation` takes a `PoolId`, which cannot be un-hashed.
    /// @param graduated        the one-way latch. Nothing in this contract ever clears it.
    struct GraduationConfig {
        uint256 threshold;
        uint256 supply;
        address token;
        uint64 graduatedAt;
        bool tokenIsCurrency0;
        bool graduated;
    }

    /// @notice Hard ceiling on total fee. 10% is the most any launch may charge.
    uint16 public constant MAX_FEE_BPS = 1000;
    /// @notice Basis point denominator.
    uint16 public constant BPS = 10_000;
    /// @notice Where bought-back supply goes. Already excluded in `Distributor`'s constructor,
    ///         so burned tokens never accrue dividends to nobody.
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Paid to whoever calls `sweep`, out of the amount swept. 0.5%.
    /// @dev Sweeping costs gas and benefits holders rather than the caller, so without a bounty
    ///      the job depends on altruism and simply does not get done. This makes it a job a bot
    ///      takes the moment it clears their gas, which is what turns accrual into payment.
    uint16 public constant SWEEP_BOUNTY_BPS = 50;

    /// @notice The only address allowed to register a pool config. Set once at deploy.
    address public immutable launcher;

    mapping(PoolId => PoolConfig) public poolConfig;
    /// @notice Fees charged per pool over all time, in the pair currency. Diagnostics only.
    mapping(PoolId => uint256) public totalFeesTaken;
    /// @notice Pair-currency fees charged but not yet swept, held as ERC-6909 claims.
    mapping(PoolId => uint256) public pendingFees;
    /// @notice LAUNCH-TOKEN fees from sells, held as claims until `sweep` converts them.
    mapping(PoolId => uint256) public pendingTokenFees;
    /// @notice Launch tokens bought back and burned per pool. Diagnostics only.
    mapping(PoolId => uint256) public totalBurned;
    /// @notice Pair-currency backlog at which a swap will opportunistically pay holders.
    ///         Zero disables the automatic path entirely, leaving only `sweep`.
    mapping(PoolId => uint256) public autoSweepThreshold;
    /// @notice Graduation threshold and latch, per pool.
    /// @dev A SEPARATE mapping from `poolConfig` on purpose. `_beforeSwap` and `_afterSwap` load
    ///      `poolConfig` into memory on every single trade; folding three more words into that
    ///      struct would add cold SLOADs to the hottest path in the system to serve a value the swap
    ///      path never reads. Nothing below `configureGraduation` / `checkGraduation` touches this.
    mapping(PoolId => GraduationConfig) public graduation;

    event PoolConfigured(
        PoolId indexed poolId,
        address distributor,
        Currency pairCurrency,
        uint16 feeBps,
        uint16 sellFeeBps,
        uint16 burnBps,
        address creator
    );
    /// @notice Charged inside a swap and held as a claim. The real trading rate lives here.
    event FeeAccrued(PoolId indexed poolId, Currency currency, uint256 amount, bool isBuy);
    /// @notice Launch tokens bought back from the pool and destroyed, during a sweep.
    event Burned(PoolId indexed poolId, uint256 pairSpent, uint256 tokensBurned);
    /// @notice An automatic sweep was attempted and failed. The claim stays queued for `sweep`.
    event AutoSweepSkipped(PoolId indexed poolId, uint256 pending);
    /// @notice Paid to whoever called `sweep`, out of what they swept.
    event SweepBounty(PoolId indexed poolId, address indexed caller, uint256 amount);
    /// @notice Redeemed and paid out. Emitted on `sweep`, not on the trade that earned it.
    event FeeTaken(PoolId indexed poolId, uint256 total, uint256 toHolders, uint256 toCreator);
    event GraduationConfigured(
        PoolId indexed poolId, address indexed token, uint256 threshold, uint256 supply
    );
    /// @notice Emitted exactly once per pool, the first time its market cap reaches the threshold.
    /// @dev **This is the entire product surface of graduation.** Indexers key off it.
    event Graduated(
        PoolId indexed poolId, address indexed token, uint256 marketCap, uint256 threshold, uint256 at
    );

    error OnlyLauncher();
    error AlreadyConfigured();
    error NotConfigured();
    error FeeTooHigh(uint16 given);
    error CreatorShareTooHigh(uint16 given);
    error ZeroAddress();
    error GraduationAlreadyConfigured();
    error GraduationNotConfigured();
    error ThresholdRequired();
    error SupplyRequired();

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
    /// @notice Everything a pool's fee needs, in one struct.
    /// @dev A struct rather than eight loose arguments because `Launcher.launch` sits on the stack
    ///      ceiling: encoding a `PoolKey` plus seven scalars at that call site is what tips it into
    ///      a Yul stack-too-deep that via-ir cannot resolve. One struct is two words to pass.
    struct FeeSetup {
        address distributor;
        Currency pairCurrency;
        uint16 feeBps;
        uint16 sellFeeBps;
        uint16 burnBps;
        address creator;
        uint16 creatorBps;
    }

    function configurePool(
        PoolKey calldata key,
        address distributor,
        Currency pairCurrency,
        uint16 feeBps,
        address creator,
        uint16 creatorBps
    ) external {
        configurePoolFull(
            key,
            FeeSetup({
                distributor: distributor,
                pairCurrency: pairCurrency,
                feeBps: feeBps,
                sellFeeBps: 0,
                burnBps: 0,
                creator: creator,
                creatorBps: creatorBps
            })
        );
    }

    /// @notice The full form: separate buy and sell rates, plus a buyback-and-burn share.
    /// @dev `configurePool` is the same thing with sells free and no burn, kept so the simple path
    ///      stays readable at the call site.
    function configurePoolFull(PoolKey calldata key, FeeSetup memory s) public {
        if (msg.sender != launcher) revert OnlyLauncher();
        if (s.feeBps > MAX_FEE_BPS) revert FeeTooHigh(s.feeBps);
        if (s.sellFeeBps > MAX_FEE_BPS) revert FeeTooHigh(s.sellFeeBps);
        if (s.creatorBps > BPS) revert CreatorShareTooHigh(s.creatorBps);
        // Creator share and burn share both come OUT of the fee, so together they cannot exceed it.
        if (uint256(s.creatorBps) + s.burnBps > BPS) revert CreatorShareTooHigh(s.creatorBps);
        if (s.distributor == address(0) || s.creator == address(0)) revert ZeroAddress();

        PoolId id = key.toId();
        if (poolConfig[id].configured) revert AlreadyConfigured();

        poolConfig[id] = PoolConfig({
            distributor: s.distributor,
            pairCurrency: s.pairCurrency,
            feeBps: s.feeBps,
            creator: s.creator,
            creatorBps: s.creatorBps,
            configured: true,
            sellFeeBps: s.sellFeeBps,
            burnBps: s.burnBps
        });

        emit PoolConfigured(
            id, s.distributor, s.pairCurrency, s.feeBps, s.sellFeeBps, s.burnBps, s.creator
        );
    }

    // -------------------------------------------------------------------------------------------
    // Graduation
    //
    // A launch here goes live on the DEX immediately and its liquidity is locked from block 0.
    // There is no bonding curve and no migration step, so there is no privileged moment to
    // graduate INTO. Graduation is therefore a **signal, not a mechanism**: a threshold, a one-way
    // latch, and an event for the app and trading apps to index.
    //
    // ## Why the threshold is denominated in the PAIR ASSET and not in dollars
    //
    // Because on Ethereum L1 the dollar price of a memecoin pair usually does not exist on chain.
    // Chainlink's mainnet reference-data-directory was enumerated (292 feeds, 192 of them Crypto)
    // and cross-checked against the FeedRegistry. Of every pair currency considered here:
    //
    //     DIRECT   ETH · USDC · UNI · WLFI · APE · LINK · AAVE · CRV
    //     DERIVED  SHIB   (only SHIB/ETH exists; multiply by ETH/USD)
    //     NONE     PEPE · SPX · ELON · FLOKI · Mog · NPC · ANDY · APU · WOJAK ·
    //              PORK · WOLF · ENA · ANIME · XMR · XRP
    //
    // PEPE has no feed of ANY kind on L1 - not PEPE/USD, not PEPE/ETH - and neither does XMR, the
    // pair this build actually targets. A USD threshold is therefore uncomputable on chain for
    // exactly the pairs a memecoin launchpad exists to serve. A pair-unit threshold needs no
    // oracle, works identically for all of them, and keeps a second manipulable price source out
    // of the latch. **The UI renders dollars off chain**, where a CEX price is available and where
    // being wrong costs nothing.
    // -------------------------------------------------------------------------------------------

    /// @notice Set a pool's graduation threshold, in pair-currency units. Once, at launch.
    /// @dev Callable only by the launcher, and only after `configurePool` - the pair currency it
    ///      wrote is what decides which side of the pool the launch token is on, and therefore
    ///      which direction the price math runs. The token address is DERIVED from the key rather
    ///      than passed in, so it cannot name a token the pool does not contain.
    ///
    ///      Immutable afterwards, for the same reason the fee split is: a maturity bar that can be
    ///      moved after people have bought is a claim the creator can retroactively rewrite.
    function configureGraduation(PoolKey calldata key, uint256 threshold, uint256 supply) external {
        if (msg.sender != launcher) revert OnlyLauncher();
        // Zero would mean "graduated on the first call", which is noise, not a signal.
        if (threshold == 0) revert ThresholdRequired();
        // Zero supply makes market cap permanently zero, i.e. a launch that can never graduate.
        if (supply == 0) revert SupplyRequired();

        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfig[id];
        if (!cfg.configured) revert NotConfigured();
        if (graduation[id].threshold != 0) revert GraduationAlreadyConfigured();

        bool tokenIsCurrency0 = Currency.unwrap(cfg.pairCurrency) != Currency.unwrap(key.currency0);
        address token =
            tokenIsCurrency0 ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

        graduation[id] = GraduationConfig({
            threshold: threshold,
            supply: supply,
            token: token,
            graduatedAt: 0,
            tokenIsCurrency0: tokenIsCurrency0,
            graduated: false
        });

        emit GraduationConfigured(id, token, threshold, supply);

        // Auto-sweep once the backlog reaches 0.1% of the graduation bar. Tied to the threshold
        // rather than to a constant because the right number is entirely relative to the pool: a
        // fixed figure is dust on a large launch and unreachable on a small one. A launch that
        // never crosses it still gets paid - `sweep` is always available and pays a bounty.
        autoSweepThreshold[id] = threshold / 1000;
    }

    /// @notice Latch a pool as graduated if its market cap has reached the threshold.
    /// @dev Permissionless and idempotent. Returns the latch state; emits `Graduated` at most once
    ///      in the life of the pool.
    ///
    ///      **GATE NOTHING OF VALUE ON THIS.** The market cap is derived from `slot0.sqrtPriceX96`,
    ///      which is a SPOT price. Anyone can move it arbitrarily far inside a single transaction
    ///      by buying, calling this, and selling back - the round trip costs them the trading fee
    ///      and some price impact, and nothing else. That is an acceptable price to pay for a
    ///      notification, which is all this is. It is NOT acceptable for a payout, an unlock, a
    ///      vesting release, a fee-tier change, or anything else that moves value. If a future
    ///      change wants to gate value on maturity, it needs a TWAP or a cumulative-volume measure,
    ///      not this function.
    ///
    ///      The latch is deliberately one-way: a token that reached the bar and then fell back has
    ///      still reached the bar, and an event stream that could retract a past event would be
    ///      unindexable.
    function checkGraduation(PoolId id) external returns (bool) {
        GraduationConfig storage g = graduation[id];
        uint256 threshold = g.threshold;
        if (threshold == 0) revert GraduationNotConfigured();
        if (g.graduated) return true;

        uint256 mcap = _marketCap(g.supply, id, g.tokenIsCurrency0);
        if (mcap < threshold) return false;

        g.graduated = true;
        g.graduatedAt = uint64(block.timestamp);

        emit Graduated(id, g.token, mcap, threshold, block.timestamp);
        return true;
    }

    /// @notice Current market cap of a launch, in units of its pair currency.
    /// @dev Spot, manipulable, display-only. See `checkGraduation`.
    function marketCapOf(PoolId id) public view returns (uint256) {
        GraduationConfig memory g = graduation[id];
        if (g.threshold == 0) revert GraduationNotConfigured();
        return _marketCap(g.supply, id, g.tokenIsCurrency0);
    }

    /// @notice Progress toward graduation in basis points, capped at `BPS`. For the UI's bar.
    function graduationProgressBps(PoolId id) external view returns (uint256) {
        GraduationConfig memory g = graduation[id];
        if (g.threshold == 0) revert GraduationNotConfigured();
        if (g.graduated) return BPS;

        uint256 mcap = _marketCap(g.supply, id, g.tokenIsCurrency0);
        if (mcap >= g.threshold) return BPS;
        return FullMath.mulDiv(mcap, BPS, g.threshold);
    }

    function hasGraduated(PoolId id) external view returns (bool) {
        return graduation[id].graduated;
    }

    /// @dev Market cap = totalSupply x price, with price read off `sqrtPriceX96`.
    ///
    ///      `sqrtPriceX96 = sqrt(amount1 / amount0) * 2^96`, so the price of ONE launch token in
    ///      pair units is `(sqrtPriceX96 / 2^96)^2` when the token is currency0 and the reciprocal
    ///      when it is currency1.
    ///
    ///      Both branches are two chained `FullMath.mulDiv` calls rather than one squaring, because
    ///      `sqrtPriceX96` reaches 2^160 at the top of the tick range and squaring it overflows a
    ///      `uint256` outright. `mulDiv` carries a 512-bit intermediate, so splitting the `2^96`
    ///      across two steps keeps every intermediate in range across the whole legal price band.
    ///
    ///      Truncation is toward zero at each step, so this errs LOW. For a threshold that is the
    ///      safe direction: it can delay a graduation by a wei of market cap, never trigger one
    ///      early.
    function _marketCap(uint256 supply, PoolId id, bool tokenIsCurrency0)
        internal
        view
        returns (uint256)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        // An uninitialised pool has no price and therefore no market cap.
        if (sqrtPriceX96 == 0) return 0;

        if (tokenIsCurrency0) {
            uint256 step = FullMath.mulDiv(supply, sqrtPriceX96, FixedPoint96.Q96);
            return FullMath.mulDiv(step, sqrtPriceX96, FixedPoint96.Q96);
        }
        uint256 step = FullMath.mulDiv(supply, FixedPoint96.Q96, sqrtPriceX96);
        return FullMath.mulDiv(step, FixedPoint96.Q96, sqrtPriceX96);
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
    ///      **Both directions are charged here on an exact-input swap**, because for exact input
    ///      the specified currency IS the input currency whichever way the trade runs:
    ///
    ///      ```
    ///        buy  exact-in   input = pair   -> charge feeBps     in the PAIR currency
    ///        sell exact-in   input = token  -> charge sellFeeBps in the LAUNCH TOKEN
    ///      ```
    ///
    ///      A sell cannot be charged in the pair currency - the trader is not paying any in - so
    ///      the sell fee accrues in launch tokens and `sweep` converts it. That conversion is only
    ///      possible because `sweep` runs outside the swap.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfig[id];
        if (!cfg.configured) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Exact-output swaps specify the OUTPUT, so the input currency is never the specified
        // side. Those are handled in `_afterSwap`.
        if (params.amountSpecified >= 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // A buy pays the pair currency in. The payer's side is currency0 when `zeroForOne`, so
        // this is a buy exactly when the pair sits on the side being paid.
        bool pairIsCurrency0 = Currency.unwrap(cfg.pairCurrency) == Currency.unwrap(key.currency0);
        bool isBuy = params.zeroForOne == pairIsCurrency0;

        uint16 rate = isBuy ? cfg.feeBps : cfg.sellFeeBps;
        if (rate == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 fee = (amountIn * rate) / BPS;
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        Currency feeCurrency = isBuy
            ? cfg.pairCurrency
            : (pairIsCurrency0 ? key.currency1 : key.currency0);

        _accrue(id, feeCurrency, isBuy, fee);

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    /// @dev Charges the EXACT-OUTPUT leg, where the INPUT currency is the unspecified side.
    ///
    ///      The returned int128 is a delta on the unspecified currency. Positive means the hook is
    ///      owed. We claim exactly that much in the same call so the unlock cycle balances.
    ///
    ///      ```
    ///        buy  exact-out   unspecified = pair   -> charge feeBps     in the PAIR currency
    ///        sell exact-out   unspecified = token  -> charge sellFeeBps in the LAUNCH TOKEN
    ///      ```
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfig[id];
        if (!cfg.configured) return (IHooks.afterSwap.selector, 0);

        bool pairIsCurrency0 = Currency.unwrap(cfg.pairCurrency) == Currency.unwrap(key.currency0);

        // Only chargeable when the INPUT currency is the UNSPECIFIED side, because this return
        // value can only adjust the unspecified currency. When the input is the specified side the
        // swap is exact-input and `_beforeSwap` already charged it - this guard is what stops the
        // two legs double-charging the same trade.
        bool exactInput = params.amountSpecified < 0;
        if (exactInput) return (IHooks.afterSwap.selector, 0);

        // A buy pays the pair currency in.
        bool isBuy = params.zeroForOne == pairIsCurrency0;
        uint16 rate = isBuy ? cfg.feeBps : cfg.sellFeeBps;
        if (rate == 0) return (IHooks.afterSwap.selector, 0);

        // The pool's delta on the INPUT currency. Negative = the pool received it.
        bool inputIsCurrency0 = params.zeroForOne;
        int128 inDelta = inputIsCurrency0 ? delta.amount0() : delta.amount1();
        if (inDelta >= 0) return (IHooks.afterSwap.selector, 0);

        uint256 amountIn = uint256(uint128(-inDelta));
        uint256 fee = (amountIn * rate) / BPS;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        Currency feeCurrency = inputIsCurrency0 ? key.currency0 : key.currency1;
        _accrue(id, feeCurrency, isBuy, fee);

        _tryAutoSweep(id, key, cfg);

        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    /// @dev Opportunistic payout, attempted once the pair-currency backlog is worth the gas.
    ///
    ///      **It can never revert the trade.** The whole attempt is a self-call inside
    ///      `try/catch`, so a paused pair currency, a blocklisted distributor or a hostile creator
    ///      makes the sweep a no-op and the swap continues. That isolation is the entire reason
    ///      this is an external self-call rather than an internal one - Trail of Bits' rule is to
    ///      keep non-essential code out of the user's flow, and a dividend is non-essential to
    ///      somebody else's swap.
    ///
    ///      It deliberately handles ONLY the pair-currency claims. Converting sell fees and
    ///      running the buyback both need a swap, and swapping the same pool from inside its own
    ///      `afterSwap` re-enters a pool whose state is mid-update. Those stay on the manual path.
    function _tryAutoSweep(PoolId id, PoolKey calldata key, PoolConfig memory cfg) internal {
        uint256 threshold = autoSweepThreshold[id];
        if (threshold == 0 || pendingFees[id] < threshold) return;

        try this.autoRedeem(id, key, cfg) {}
        catch {
            // Left pending on purpose. `sweep` will collect it later and the trade is unaffected.
            emit AutoSweepSkipped(id, pendingFees[id]);
        }
    }

    /// @dev The auto path's body. External so the `try/catch` above gets a real revert boundary,
    ///      and gated to this contract so nobody else can drive it.
    function autoRedeem(PoolId id, PoolKey calldata key, PoolConfig memory cfg) external {
        if (msg.sender != address(this)) revert NotPoolManager();

        uint256 amount = pendingFees[id];
        if (amount == 0) return;

        // RESERVE THE BURN SHARE. The buyback needs a swap and the auto path cannot swap, so if
        // this paid out the whole balance the burn wedge would silently never fire on any pool
        // busy enough for auto-sweep to handle its volume - the wedge would look armed and do
        // nothing. The burn share stays queued as a claim for the next manual `sweep` to spend.
        uint256 reservedForBurn = (amount * cfg.burnBps) / BPS;
        uint256 payout = amount - reservedForBurn;
        pendingFees[id] = reservedForBurn;
        if (payout == 0) return;

        // We are already inside the manager's unlock cycle here, so this must NOT call `unlock`
        // again - `burn` and `take` go direct. `take` draws on reserves earlier trades already
        // settled; if the singleton is short, the catch above puts the claim back in the queue.
        poolManager.burn(address(this), cfg.pairCurrency.toId(), payout);
        poolManager.take(cfg.pairCurrency, address(this), payout);
        _routeFee(id, cfg, payout);

        // `key` is unused beyond identifying the pool, but taking it keeps this signature aligned
        // with `sweep` so the two paths are obviously the same operation.
        key;
    }

    /// @notice Take the fee as an ERC-6909 claim and record it. Shared by both charging legs so
    ///         they can never drift apart.
    ///
    /// @dev **This must be `mint`, not `take`, and that is forced by single-sided seeding.**
    ///
    ///      `poolManager.take()` moves real ERC-20 out of the singleton, so it requires the
    ///      singleton to actually hold that currency at that instant. It did, back when a launch
    ///      seeded both sides of the pool. A single-sided launch puts in only the launch token, so
    ///      a fresh pool holds ZERO pair currency — and `beforeSwap` runs before the trader has
    ///      settled their input. `take()` there reverts on an ERC-20 transfer the manager cannot
    ///      make, which bricks every buy on a new pool.
    ///
    ///      `mint()` takes the same value as an ERC-6909 claim instead. It needs no balance, it is
    ///      cheaper than `take()` per Uniswap's own docs, and the claim is redeemed later by
    ///      `sweep()` once the pool genuinely holds the currency.
    ///
    ///      The cost of this, stated plainly: fees are no longer delivered inside the swap. They
    ///      accrue exactly and are paid out on a sweep. Holders earn on every trade either way —
    ///      only the moment the tokens move changes.
    function _accrue(PoolId id, Currency feeCurrency, bool isBuy, uint256 fee) internal {
        poolManager.mint(address(this), feeCurrency.toId(), fee);

        if (isBuy) {
            pendingFees[id] += fee;
            totalFeesTaken[id] += fee;
        } else {
            // A sell is charged in LAUNCH TOKENS. It is tracked separately because it has to be
            // converted to the pair currency before holders can be paid in it, and that conversion
            // is a swap - which cannot happen inside the swap that produced it.
            pendingTokenFees[id] += fee;
        }
        emit FeeAccrued(id, feeCurrency, fee, isBuy);
    }

    /// @notice Redeem accrued claims for real tokens and pay the creator and the holders.
    /// @dev Permissionless and idempotent: anyone may call it, and it is a no-op with nothing
    ///      pending. It is deliberately OUTSIDE the swap path, so a hostile creator, a blocklisted
    ///      distributor or a paused pair currency can never revert somebody else's trade.
    function sweep(PoolKey calldata key) external returns (uint256 swept) {
        PoolId id = key.toId();
        if (!poolConfig[id].configured) revert NotConfigured();

        uint256 pairAmount = pendingFees[id];
        uint256 tokenAmount = pendingTokenFees[id];
        if (pairAmount == 0 && tokenAmount == 0) return 0;

        pendingFees[id] = 0;
        pendingTokenFees[id] = 0;

        poolManager.unlock(abi.encode(key, pairAmount, tokenAmount, msg.sender));
        return pairAmount;
    }

    /// @dev The redemption, inside the manager's unlock cycle. Three steps, in this order:
    ///
    ///        1. **Convert sell fees.** Launch tokens taken from sellers are swapped for the pair
    ///           currency through the token's own pool. `Hooks.noSelfCall` means the PoolManager
    ///           skips this hook's callbacks when the hook itself is the caller, so this internal
    ///           swap is not charged a fee and cannot recurse.
    ///        2. **Buy back and burn.** `burnBps` of the total buys the launch token from its own
    ///           pool and sends it to the dead address.
    ///        3. **Route the rest** to the creator and the holders.
    ///
    ///      `burn` turns a claim back into a credit and `take` converts that credit into ERC-20,
    ///      so every delta opened here is closed before the cycle ends.
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint256 pairAmount, uint256 tokenAmount, address sweepCaller) =
            abi.decode(raw, (PoolKey, uint256, uint256, address));

        PoolId id = key.toId();
        PoolConfig memory cfg = poolConfig[id];
        bool pairIsCurrency0 = Currency.unwrap(cfg.pairCurrency) == Currency.unwrap(key.currency0);
        Currency tokenCurrency = pairIsCurrency0 ? key.currency1 : key.currency0;

        // ORDER MATTERS. A claim is not a credit: `burn` is what converts one into the other, and
        // a swap can only spend a credit. Burning every claim FIRST, then swapping, then taking
        // what is left is the only sequence where each delta is opened after it can be covered.
        // Doing the buyback before burning its claim opens a pair debt nothing pays, which is
        // exactly the `CurrencyNotSettled` this ordering exists to avoid.

        // 1. Redeem the pair-currency claims into a credit.
        if (pairAmount != 0) {
            poolManager.burn(address(this), cfg.pairCurrency.toId(), pairAmount);
        }

        // 2. Sell fees arrived in launch tokens. Redeem them and swap them for the pair currency,
        //    which lands as more pair credit. `Hooks.noSelfCall` means the manager skips this
        //    hook's own callbacks here, so this internal swap is untaxed and cannot recurse.
        uint256 totalPair = pairAmount;
        if (tokenAmount != 0) {
            poolManager.burn(address(this), tokenCurrency.toId(), tokenAmount);
            BalanceDelta d = poolManager.swap(
                key,
                SwapParams({
                    // Selling the launch token: pay token in, receive pair out.
                    zeroForOne: !pairIsCurrency0,
                    amountSpecified: -int256(tokenAmount),
                    sqrtPriceLimitX96: !pairIsCurrency0
                        ? TickMath.MIN_SQRT_PRICE + 1
                        : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            int128 gained = pairIsCurrency0 ? d.amount0() : d.amount1();
            if (gained > 0) totalPair += uint256(uint128(gained));
        }

        if (totalPair == 0) return "";

        // 3. Buy the launch token back with a share of that credit and destroy it.
        uint256 toBurn = (totalPair * cfg.burnBps) / BPS;
        if (toBurn != 0) {
            totalPair -= toBurn;
            BalanceDelta d = poolManager.swap(
                key,
                SwapParams({
                    // Buying the launch token: pay pair in, receive token out.
                    zeroForOne: pairIsCurrency0,
                    amountSpecified: -int256(toBurn),
                    sqrtPriceLimitX96: pairIsCurrency0
                        ? TickMath.MIN_SQRT_PRICE + 1
                        : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            int128 bought = pairIsCurrency0 ? d.amount1() : d.amount0();
            if (bought > 0) {
                uint256 burned = uint256(uint128(bought));
                poolManager.take(tokenCurrency, DEAD, burned);
                totalBurned[id] += burned;
                emit Burned(id, toBurn, burned);
            }
        }

        // 4. Whatever credit remains becomes real ERC-20, pays the caller their bounty, and the
        //    rest goes to the creator and the holders.
        if (totalPair != 0) {
            poolManager.take(cfg.pairCurrency, address(this), totalPair);

            uint256 bounty = (totalPair * SWEEP_BOUNTY_BPS) / BPS;
            if (bounty != 0 && sweepCaller != address(0)) {
                totalPair -= bounty;
                // Raw send: a caller that cannot receive must not strand everyone else's payout.
                if (_trySend(Currency.unwrap(cfg.pairCurrency), sweepCaller, bounty)) {
                    emit SweepBounty(id, sweepCaller, bounty);
                } else {
                    totalPair += bounty;
                }
            }

            if (totalPair != 0) _routeFee(id, cfg, totalPair);
        }

        return "";
    }

    /// @dev Splits a swept fee between creator and holders and forwards both.
    ///
    ///      Sends are raw calls: a hostile or blocklisted creator must not be able to revert the
    ///      sweep for everyone else. A failed payout strands the tokens on this contract rather
    ///      than trapping the rest of the distribution.
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

        emit FeeTaken(id, fee, toHolders, toCreator);
    }

    /// @dev Raw call so a hostile or non-standard recipient cannot revert the whole swap. A failed
    ///      payout leaves the tokens on this contract rather than trapping every trader in the pool.
    function _trySend(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}
