// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Types
/// @notice Data shapes shared between DynamicLPFeesHook, RiskModelLib and PolicyLib.
library Types {
    enum RiskTier {
        Low,
        Medium,
        High
    }

    /// @param tradeSize Absolute swap size (|amountSpecified|).
    /// @param liquidity In-range pool liquidity at swap time.
    /// @param sqrtPriceX96 Current sqrt price.
    /// @param referenceSqrtPriceX96 Sqrt price stored when the pool was initialized.
    struct RiskInputs {
        uint256 tradeSize;
        uint128 liquidity;
        uint160 sqrtPriceX96;
        uint160 referenceSqrtPriceX96;
    }

    /// @param sizeRatioBps Swap size relative to liquidity, in bps.
    /// @param priceDeviationBps Distance from the reference sqrt price, in bps.
    /// @param totalScore Combined risk score passed into PolicyLib.
    struct RiskScore {
        uint256 sizeRatioBps;
        uint256 priceDeviationBps;
        uint256 totalScore;
    }
}
