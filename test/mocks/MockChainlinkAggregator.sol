// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockChainlinkAggregator {
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;

    function setRound(int256 _answer, uint256 _startedAt, uint256 _updatedAt) external {
        _writeRound(_answer, _startedAt, _updatedAt, 0);
    }

    // answeredInRoundOverride = 0 means "complete round" (answeredInRound == new roundId)
    function setRoundData(int256 _answer, uint256 _startedAt, uint256 _updatedAt, uint80 answeredInRoundOverride)
        external
    {
        _writeRound(_answer, _startedAt, _updatedAt, answeredInRoundOverride);
    }

    function _writeRound(int256 _answer, uint256 _startedAt, uint256 _updatedAt, uint80 answeredInRoundOverride)
        internal
    {
        answer = _answer;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
        roundId++;
        answeredInRound = answeredInRoundOverride == 0 ? roundId : answeredInRoundOverride;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}
