// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DynamicLPFeesHook
/// @author Lovro Posel
/// @notice V4 hook that raises swap fees when execution risk is high (large trade, thin pool, price drift).

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract DynamicLPFeesHook is BaseHook {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using PoolId for PoolKey;


    uint256 public constant MIN_FEE = 3000; //0.3%
    uint256 public constant LOW_FEE = 5000; //5%
    uint256 public constant MEDIUM_FEE = 10000; //1%
    uint256 public constant HIGH_FEE = 30000; //3%
    uint256 public constant VERY_HIGH_FEE = 50000; //5%
    uint256 public constant MAX_FEE = 100000; //10%


    mapping(PoolId => int256) public referencePrice;


    error MustUseDynamicFees();

    event FeeAdjusted(
        PoolId indexed poolId,
        uint24 feePips,
        uint256 sizeRatioBps,
        uint256 priceDeviationBps,
        uint256 totalScore
    );





AggregatorV3Interface internal PriceDataFeed;
    

    constructor(IPoolManager _manager) BaseHook(_manager) {
        PriceDataFeed = AggregatorV3Interface(0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1);
    }


function latestRoundData()
  public
  view
  returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
{
  return PriceDataFeed.latestRoundData();
}



function getFee(PoolId poolId, SwapParams calldata params) internal view returns (uint24){
    // Get the latest round data from the Chainlink price feed
    if (poolId == 0) revert PoolIdNotSet();
    (, int256 currentPrice,,,) = PriceDataFeed.latestRoundData();
    //get the reference price from the mapping
    if (referencePrice[poolId] == 0) revert ReferencePriceNotSet();
    int256 referencePrice = referencePrice[poolId];
    //calculate the deviation between the current price and the reference price
    if (currentPrice == 0) revert CurrentPriceNotSet();
    int256 deviation = currentPrice - referencePrice;
    //calculate the deviation in basis points  
    if (deviation == 0) revert DeviationNotSet();
    uint256 deviationBps = deviation * 10000 / referencePrice;
    //calculate the trade size in basis points
    uint256 tradeSizeBps = params.amountSpecified * 10000 / liquidity;
    //calculate the total score
    uint256 totalScore = deviationBps + tradeSizeBps;
    //return the fee
    return totalScore;
}


    if (deviationBps < 100) {
        return LOW_FEE;
    }

    if (deviationBps < 300) {
        return MEDIUM_FEE;
    }

    if (deviationBps < 500) {
        return HIGH_FEE;
    }

    return MAX_FEE;
}



    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {

        // Just to check if the fee is dynamic,if not, revert
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFees();
        return BaseHook.beforeInitialize.selector;

    }

    /// @notice Stores the Chainlink reference price when a dynamic-fee pool is initialized.
    /// @dev Called once per pool by the PoolManager after `initialize`. The stored price is used
    ///      in `_beforeSwap` to compute oracle deviation for dynamic fee tiers.
    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        override
        returns (bytes4)
        {
            //
        // Get the pool id
        PoolId poolId = key.toId();
        // Get the latest round data from the Chainlink price feed
        (, int256 currentPrice,,,) = PriceDataFeed.latestRoundData();
        // Store the reference price in the mapping
        referencePrice[poolId] = currentPrice;
        // Return the selector for the afterInitialize function
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24 ) {
        // Get the pool id
           PoolId poolId = key.toId();
           // Get the fee
           uint24 fee = getFee(poolId, params);
           // Return the selector for the beforeSwap function and the fee
           return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);


       
    }
    
}