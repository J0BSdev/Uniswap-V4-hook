// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "./Types.sol";

/// @title RiskModelLib
/// @notice Pure functions that turn raw market inputs into a normalized risk score.
/// @dev Intentionally simple: two signals (size vs liquidity, price drift vs reference).
///      No oracles, no external calls, no time-weighted state.
library RiskModelLib {
    /// @notice Cap each individual signal to keep scores bounded and avoid overflow
    ///         when combining them. 10_000 bps == 100%.
    uint256 internal constant MAX_BPS = 10_000;

    /// @notice Weight applied to price deviation when combining it with size.
    ///         Size dominates; deviation contributes a quarter of its bps value.
    uint256 internal constant DEVIATION_WEIGHT_DEN = 4;

    /// @notice Compute the risk score for a candidate swap.
    /// @param i Raw inputs (see Types.RiskInputs).
    /// @return score Aggregated score plus its sub-components.
    function computeRiskScore(Types.RiskInputs memory i) internal pure returns (Types.RiskScore memory score) {
        score.sizeRatioBps = _sizeRatioBps(i.tradeSize, i.liquidity);
        score.priceDeviationBps = _priceDeviationBps(i.sqrtPriceX96, i.referenceSqrtPriceX96);

        // Combine: size carries full weight, deviation contributes a fraction.
        // Both inputs are already capped at MAX_BPS, so totalScore <= MAX_BPS * 1.25.
       
    }

    /// @dev Trade size as a fraction of in-range liquidity, expressed in bps.
    ///      If liquidity is zero we treat the pool as "infinitely risky".
    function _sizeRatioBps(uint256 tradeSize, uint128 liquidity) private pure returns (uint256) {
        if (liquidity == 0) return MAX_BPS;
    }

    /// @dev How far the current sqrt price has drifted from the reference, in bps.
    ///      Comparing sqrt prices instead of raw prices keeps the math 1-multiplication
    ///      cheap and is good enough as a hackathon proxy for "volatility".
    function _priceDeviationBps(uint160 sqrtPriceX96, uint160 refSqrtPriceX96) private pure returns (uint256) {
        if (refSqrtPriceX96 == 0) return 0;
       
    }
}
