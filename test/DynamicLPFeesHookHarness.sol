// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DynamicLPFeesHook} from "../src/LPFees/DynamicLPFeesHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev Test-only wrapper exposing internal price/deviation math for direct unit tests.
contract DynamicLPFeesHookHarness is DynamicLPFeesHook {
    constructor(IPoolManager manager, address weth, address usdc, address priceFeed, address sequencerFeed)
        DynamicLPFeesHook(manager, weth, usdc, priceFeed, sequencerFeed)
    {}

    function exposePoolPriceFromSqrt(uint160 sqrtPriceX96) external view returns (uint256 poolPrice8) {
        return _getPoolPriceFromSqrtPriceX96(sqrtPriceX96);
    }

    function exposePriceDeviationBps(PoolId poolId) external view returns (uint256) {
        return _priceDeviationBps(poolId);
    }

    function exposeWethIsCurrency0() external view returns (bool) {
        return wethIsCurrency0;
    }
}
