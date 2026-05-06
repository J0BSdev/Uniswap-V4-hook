// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Types
/// @notice Shared structs / enums used by ExecutionGuardHook, RiskModelLib and PolicyLib.
/// @dev Kept deliberately small so that the risk model is easy to reason about.
library Types {
    /// @notice Tier the current swap was placed in by `PolicyLib.decideFee`.
    enum RiskTier {
        Low, // calm pool / small trade  -> low fee
        Medium, // noticeable price impact   -> medium fee
        High // big trade or thin pool    -> high fee
    }

    /// @notice Raw inputs the hook collects before each swap.
    /// @param tradeSize              Absolute notional of the swap (|amountSpecified|).
    /// @param liquidity              Active in-range liquidity reported by the pool.
    /// @param sqrtPriceX96           Current pool price (Q64.96).
    /// @param referenceSqrtPriceX96  Reference price (e.g. price at pool initialization)
    ///                               used to estimate how far the pool has drifted.
    struct RiskInputs {
        uint256 tradeSize;
        uint128 liquidity;
        uint160 sqrtPriceX96;
        uint160 referenceSqrtPriceX96;
    }

    /// @notice Output of the risk model.
    /// @param sizeRatioBps       Trade size as a fraction of pool liquidity, in bps.
    /// @param priceDeviationBps  |currentSqrt - refSqrt| / refSqrt, in bps.
    /// @param totalScore         Weighted aggregate score (bps-like). Bigger == riskier.
    struct RiskScore {
        uint256 sizeRatioBps;
        uint256 priceDeviationBps;
        uint256 totalScore;
    }
}
