// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "./Types.sol";

/// @title RiskModelLib
/// @notice Scores a swap from pool state. Uses trade size vs liquidity and price drift.
library RiskModelLib {
    uint256 internal constant MAX_BPS = 10_000;

    function computeRiskScore(Types.RiskInputs memory i) internal pure returns (Types.RiskScore memory score) {
        score.sizeRatioBps = _sizeRatioBps(i.tradeSize, i.liquidity);
        score.priceDeviationBps = _priceDeviationBps(i.sqrtPriceX96, i.referenceSqrtPriceX96);
    }

    function _sizeRatioBps(uint256 tradeSize, uint128 liquidity) private pure returns (uint256) {
        if (liquidity == 0) return MAX_BPS;
    }

    function _priceDeviationBps(uint160 sqrtPriceX96, uint160 refSqrtPriceX96) private pure returns (uint256) {
        if (refSqrtPriceX96 == 0) return 0;
    }
}
