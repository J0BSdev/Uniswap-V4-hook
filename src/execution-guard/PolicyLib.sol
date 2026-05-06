// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "./Types.sol";

/// @title PolicyLib
/// @notice Maps a numeric risk score into a discrete fee tier.
/// @dev Three tiers, three fees. Tweak the thresholds without touching the hook.
library PolicyLib {
    // ─── Fee tiers (in pips, 1e6 == 100%) ───────────────────────────────────
    uint24 internal constant FEE_LOW = 3_000; // 0.3%
    uint24 internal constant FEE_MEDIUM = 7_000; // 0.7%
    uint24 internal constant FEE_HIGH = 12_000; // 1.2%

    // ─── Score thresholds (in the same bps-like units RiskModelLib produces) ─
    /// @dev score < LOW_THRESHOLD                 -> Low tier    (calm pool)
    /// @dev LOW_THRESHOLD <= score < MED_THRESHOLD -> Medium tier (busy pool)
    /// @dev score >= MED_THRESHOLD                -> High tier   (risky pool)
    uint256 internal constant LOW_THRESHOLD = 100; // ~1% of liquidity
    uint256 internal constant MED_THRESHOLD = 500; // ~5% of liquidity

    /// @notice Decide which fee should be charged for a given risk score.
    /// @param score Aggregated score from RiskModelLib.computeRiskScore.
    /// @return feePips Fee to apply (without the override flag).
    /// @return tier    The selected RiskTier (useful for events / introspection).
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
