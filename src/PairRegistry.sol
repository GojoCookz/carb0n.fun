// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";

/// @title PairRegistry
/// @notice The allowlist of assets a launch may be priced against, and the oracle wiring for each.
///
/// @dev **Ticker impostors are why this is an address allowlist.** The problem was measured on
///      Robinhood Chain - 361 separate contracts use the symbol `GME`, exactly one is real; 416 use
///      `ROBIN`, 115 claim `SPCX`, 114 claim `COIN`; seven carry the exact string "GameStop -
///      Robinhood Token"; over 13 days in July 2026 the fakes did $213M across 1.34M trades and
///      out-traded the genuine token two to one - but it is not chain-specific. Ethereum L1 has the
///      same disease. Symbol matching is useless, name matching is useless, and the ONLY reliable
///      identity is the contract address. A pair not listed here cannot be launched against.
///
///      Delisting a pair stops NEW launches against it. It does not and cannot touch pools that
///      already exist - nothing reads this registry after launch.
///
///      **Two classes of pair, deliberately.** On Ethereum L1 the assets worth pairing against do
///      not all have a Chainlink feed:
///
///        - PRICEABLE  (`approvePair`)            - has a feed, so a launch can open at a
///                                                  dollar-denominated market cap.
///        - UNPRICEABLE (`approvePairWithoutOracle`) - no feed exists, so openings must be quoted in
///                                                  units of the pair asset itself.
///
///      The motivating case is WXMR (`0x465e07d6...db0f5`), which has a ~$310K Uniswap V2 pool that
///      has been live since 2021-01-06, but **no XMR/USD Chainlink feed exists on Ethereum L1**.
///      Push feeds for XMR/USD exist only on Optimism and Polygon. Rather than fake a price from a
///      spot pool - which is manipulable inside a single transaction and is exactly how launchpads
///      misprice their own openings - an unpriceable pair is marked as such and `priceUsd` reverts
///      loudly instead of returning a number nobody should trust.
contract PairRegistry is Ownable2Step {
    /// @notice Per-pair oracle configuration.
    /// @param approved      whether new launches may use this pair
    /// @param feed          Chainlink AggregatorV3 proxy for pair/USD, or address(0) if this pair
    ///                      is approved but has no USD oracle (see `approvePairWithoutOracle`)
    /// @param maxStaleness  seconds after which `updatedAt` is not trusted; 0 when `feed` is unset
    /// @param feedDecimals  cached `feed.decimals()`; never hardcode 8
    /// @param tokenDecimals cached `IERC20.decimals()`; USDC is 6, WETH and WXMR are 18
    struct PairConfig {
        bool approved;
        address feed;
        uint32 maxStaleness;
        uint8 feedDecimals;
        uint8 tokenDecimals;
    }

    /// @notice Suggested bound for a mainnet crypto feed. A day of silence is already abnormal.
    /// @dev These constants are SUGGESTIONS passed in by the operator, not enforced defaults.
    ///      Always set `maxStaleness` to a comfortable multiple of the feed's real heartbeat -
    ///      mainnet ETH/USD is ~1h, USDC/USD is ~24h. Setting it EQUAL to the heartbeat guarantees
    ///      intermittent reverts, which is why MIN_STALENESS is a floor and not a recommendation.
    uint32 public constant CRYPTO_STALENESS = 1 days;
    /// @notice Equity feeds are 24/5 and hold Friday's close across the weekend BY DESIGN.
    ///         A crypto-tuned bound would brick every stock pair every Saturday. Kept for the
    ///         tokenized-equity pairs that do exist on L1 (Ondo `*on`, Backed `b*`/`*x`).
    uint32 public constant EQUITY_STALENESS = 96 hours;
    /// @notice Absolute floor we will accept. Below this is a configuration mistake, not a policy.
    uint32 public constant MIN_STALENESS = 1 hours;
    /// @notice Nothing legitimate needs a week-old price.
    uint32 public constant MAX_STALENESS = 7 days;

    /// @notice L2 sequencer uptime feed. Zero disables the check.
    /// @dev **Inert on Ethereum L1 and must stay address(0) there** - mainnet has no sequencer, so
    ///      there is no uptime feed to read and enabling this would revert every price read. The
    ///      code is retained deliberately: it is correct and REQUIRED if this is ever redeployed to
    ///      Optimism or another L2 (which is also where the XMR/USD push feed actually lives), and
    ///      deleting it would be a silent correctness bug on that redeploy.
    address public sequencerUptimeFeed;
    /// @notice How long after the sequencer comes back before prices are trusted again.
    uint32 public sequencerGracePeriod = 1 hours;

    mapping(address pair => PairConfig) private _pairs;
    address[] private _pairList;
    mapping(address pair => bool) private _listed;

    event PairApproved(address indexed pair, address indexed feed, uint32 maxStaleness, uint8 tokenDecimals);
    event PairRevoked(address indexed pair);
    event SequencerFeedSet(address indexed feed, uint32 gracePeriod);

    error ZeroAddress();
    error StalenessOutOfBounds(uint32 given);
    error PairNotApproved(address pair);
    error SequencerDown();
    error SequencerGracePeriod();
    error StalePrice(address pair, uint256 updatedAt, uint32 maxStaleness);
    error InvalidPrice(address pair, int256 answer);
    /// @notice The pair is approved for launches but has no USD oracle, so it has no USD price.
    error PairNotPriceable(address pair);

    constructor(address initialOwner) Ownable(initialOwner) {}

    // -------------------------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------------------------

    /// @notice Approve a pair asset by ADDRESS. There is deliberately no symbol-based entry point.
    /// @dev `feedDecimals` and `tokenDecimals` are read from the contracts, never passed in, so a
    ///      typo cannot misprice a pair by 1e12 (the USDG-is-6-decimals footgun).
    function approvePair(address pair, address feed, uint32 maxStaleness, uint8 tokenDecimals)
        external
        onlyOwner
    {
        if (pair == address(0) || feed == address(0)) revert ZeroAddress();
        if (maxStaleness < MIN_STALENESS || maxStaleness > MAX_STALENESS) {
            revert StalenessOutOfBounds(maxStaleness);
        }

        uint8 feedDecimals = IAggregatorV3(feed).decimals();

        _pairs[pair] = PairConfig({
            approved: true,
            feed: feed,
            maxStaleness: maxStaleness,
            feedDecimals: feedDecimals,
            tokenDecimals: tokenDecimals
        });

        _list(pair);

        emit PairApproved(pair, feed, maxStaleness, tokenDecimals);
    }

    /// @notice Approve a pair that has NO Chainlink USD feed on this chain.
    /// @dev Launches against this pair cannot be opened at a dollar-denominated market cap; the
    ///      opening price must be expressed in units of the pair asset. `priceUsd` reverts with
    ///      `PairNotPriceable` rather than returning a fabricated number.
    ///
    ///      This is a SEPARATE entry point on purpose. Allowing `approvePair(pair, address(0), ...)`
    ///      would mean a mistyped or accidentally-zero feed argument silently downgrades a pair to
    ///      unpriced instead of reverting, which is precisely the failure this contract exists to
    ///      prevent. Dropping the oracle must be an explicit, deliberate call.
    ///
    ///      Motivating case: WXMR on Ethereum L1 - real, liquid, five years old, and unfeedable.
    function approvePairWithoutOracle(address pair, uint8 tokenDecimals) external onlyOwner {
        if (pair == address(0)) revert ZeroAddress();

        _pairs[pair] = PairConfig({
            approved: true, feed: address(0), maxStaleness: 0, feedDecimals: 0, tokenDecimals: tokenDecimals
        });

        _list(pair);

        emit PairApproved(pair, address(0), 0, tokenDecimals);
    }

    /// @notice Stop NEW launches against a pair. Existing pools are untouched and untouchable.
    function revokePair(address pair) external onlyOwner {
        _pairs[pair].approved = false;
        emit PairRevoked(pair);
    }

    function _list(address pair) internal {
        if (!_listed[pair]) {
            _listed[pair] = true;
            _pairList.push(pair);
        }
    }

    function setSequencerFeed(address feed, uint32 gracePeriod) external onlyOwner {
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(feed, gracePeriod);
    }

    // -------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------

    function isApproved(address pair) external view returns (bool) {
        return _pairs[pair].approved;
    }

    /// @notice True if this pair is approved AND has a USD oracle, i.e. `priceUsd` will not revert
    ///         for lack of a feed. Callers that need a dollar-denominated opening must check this.
    function isPriceable(address pair) external view returns (bool) {
        PairConfig memory cfg = _pairs[pair];
        return cfg.approved && cfg.feed != address(0);
    }

    function pairConfig(address pair) external view returns (PairConfig memory) {
        return _pairs[pair];
    }

    function pairCount() external view returns (uint256) {
        return _pairList.length;
    }

    function pairAt(uint256 i) external view returns (address) {
        return _pairList[i];
    }

    /// @notice USD price of one whole unit of `pair`, and the feed's decimals.
    /// @dev Reverts rather than returning a suspicious number. A launch that cannot be priced must
    ///      not open a permanent pool at a wrong number.
    ///
    ///      Reverts `PairNotPriceable` for pairs registered via `approvePairWithoutOracle`. That is
    ///      the intended, non-exceptional path for assets like WXMR - callers should branch on
    ///      `isPriceable` and quote the opening in pair units instead of guessing a dollar value.
    ///
    ///      For a tokenized equity whose feed already returns share price x multiplier, the answer
    ///      is the value of ONE TOKEN. Do not apply the multiplier again downstream.
    function priceUsd(address pair) public view returns (uint256 price, uint8 priceDecimals) {
        PairConfig memory cfg = _pairs[pair];
        if (!cfg.approved) revert PairNotApproved(pair);
        if (cfg.feed == address(0)) revert PairNotPriceable(pair);

        _checkSequencer();

        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(cfg.feed).latestRoundData();
        if (answer <= 0) revert InvalidPrice(pair, answer);
        if (block.timestamp - updatedAt > cfg.maxStaleness) {
            revert StalePrice(pair, updatedAt, cfg.maxStaleness);
        }

        return (uint256(answer), cfg.feedDecimals);
    }

    /// @notice Reverts unless the L2 sequencer is up and past its grace period.
    /// @dev Robinhood Chain is an Arbitrum Nitro L2. During a sequencer outage feeds go stale while
    ///      still returning a value, so this must be checked BEFORE any price is trusted.
    function _checkSequencer() internal view {
        address feed = sequencerUptimeFeed;
        if (feed == address(0)) return;

        (, int256 status, uint256 startedAt,,) = IAggregatorV3(feed).latestRoundData();
        // 0 = sequencer up, 1 = down
        if (status != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerGracePeriod();
    }
}
