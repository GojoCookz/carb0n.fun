// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The subset of Chainlink's AggregatorV3Interface we actually use.
/// @dev Robinhood Chain publishes crypto AND tokenized-equity feeds behind this exact interface,
///      so a stock price is read the same way as an ETH price. Always call `decimals()` - most USD
///      feeds are 8, not 18, and hardcoding it is a silent 1e10 mispricing.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
