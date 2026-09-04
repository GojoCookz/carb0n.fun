// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @title MockAggregatorV3
/// @notice Stands in for a Chainlink AggregatorV3 proxy in tests and on Sepolia.
/// @dev Deliberately allows states a healthy feed never reaches - negative answers, zero answers,
///      and arbitrarily old `updatedAt` - because those are exactly the paths `PairRegistry` is
///      supposed to reject. A mock that can only be healthy tests nothing.
///
///      Doubles as an L2 sequencer uptime feed: set `answer` to 0 for "sequencer up" or 1 for
///      "down", and `startedAt` to the moment that status began.
contract MockAggregatorV3 is IAggregatorV3 {
    uint8 private _decimals;
    string public description;

    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(uint8 decimals_, int256 initialAnswer, string memory description_) {
        _decimals = decimals_;
        answer = initialAnswer;
        description = description_;
        roundId = 1;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId_,
            int256 answer_,
            uint256 startedAt_,
            uint256 updatedAt_,
            uint80 answeredInRound_
        )
    {
        return (roundId, answer, startedAt, updatedAt, roundId);
    }

    // -------------------------------------------------------------------------------------------
    // Test controls
    // -------------------------------------------------------------------------------------------

    /// @notice Publish a new answer as of now.
    function setAnswer(int256 newAnswer) external {
        answer = newAnswer;
        updatedAt = block.timestamp;
        roundId++;
    }

    /// @notice Publish an answer stamped at an arbitrary time, to simulate a stale feed.
    function setAnswerAt(int256 newAnswer, uint256 timestamp) external {
        answer = newAnswer;
        updatedAt = timestamp;
        roundId++;
    }

    /// @notice Freeze `updatedAt` without changing the answer - a feed that stopped publishing.
    function setUpdatedAt(uint256 timestamp) external {
        updatedAt = timestamp;
    }

    /// @notice Drive the sequencer-uptime shape: status 0 = up, 1 = down.
    function setSequencerStatus(int256 status, uint256 since) external {
        answer = status;
        startedAt = since;
        updatedAt = since;
    }
}
