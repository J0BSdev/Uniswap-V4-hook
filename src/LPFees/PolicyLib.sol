// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "./Types.sol";

/// @title PolicyLib
/// @notice Picks a swap fee from the risk score returned by RiskModelLib.
library PolicyLib {
    // pips (1e6 = 100%)
    uint24 internal constant FEE_LOW = 3_000;
    uint24 internal constant FEE_MEDIUM = 7_000;
    uint24 internal constant FEE_HIGH = 12_000;

    uint256 internal constant LOW_THRESHOLD = 100;
    uint256 internal constant MED_THRESHOLD = 500;

    function decideFee(uint256 score) internal pure returns (uint24 feePips, Types.RiskTier tier) {
        if (score < LOW_THRESHOLD) {
            return (FEE_LOW, Types.RiskTier.Low);
        }
        if (score < MED_THRESHOLD) {
            return (FEE_MEDIUM, Types.RiskTier.Medium);
        }
        return (FEE_HIGH, Types.RiskTier.High);
    }
}
