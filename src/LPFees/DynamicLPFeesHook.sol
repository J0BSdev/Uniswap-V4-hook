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


    uint24 public constant MIN_FEE = 3000; //0.3%
    uint24 public constant LOW_FEE = 5000; //0.5%
    uint24 public constant MEDIUM_FEE = 10000; //1%
    uint24 public constant HIGH_FEE = 30000; //3%
    uint24 public constant VERY_HIGH_FEE = 50000; //5%
    uint24 public constant MAX_FEE = 100000; //10%


    mapping(PoolId poolId => int256 referencePrice) public referencePrice;


    error MustUseDynamicFees();
    error CurrentOraclePriceNotSet();
    error ReferencePriceNotSet();
    error PoolPriceNotSet();

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
    (, int256 currentOraclePrice,,,) = PriceDataFeed.latestRoundData();
    if (currentOraclePrice <= 0) revert CurrentOraclePriceNotSet();

    // get the pool price from the sqrtPriceX96
    (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
    uint256 poolPrice = _getPoolPriceFromSqrtPriceX96(sqrtPriceX96);
    if (poolPrice == 0) revert PoolPriceNotSet();

//get the oracle price
  uint256 oraclePrice = uint256(currentOraclePrice);

    uint256 diff = poolPrice > oraclePrice ? poolPrice - oraclePrice : oraclePrice - poolPrice;
    uint256 priceDeviationBps = diff * 10000 / oraclePrice;

    // --- size / liquidity ---
    uint256 tradeSize = params.amountSpecified >= 0
        ? uint256(params.amountSpecified)
        : uint256(-params.amountSpecified);
    // --- score → fee ---
    uint256 totalScore = priceDeviationBps + sizeRatioBps;
    if (totalScore < 100)       feePips = LOW_FEE;
    else if (totalScore < 500)  feePips = MEDIUM_FEE;
    else if (totalScore < 2000) feePips = HIGH_FEE;
    else                        feePips = VERY_HIGH_FEE;
    if (feePips < MIN_FEE) feePips = MIN_FEE;
    if (feePips > MAX_FEE) feePips = MAX_FEE;
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
        // Get the pool id
        PoolId poolId = key.toId();
        // Get the latest round data from the Chainlink price feed
        (, int256 currentOraclePrice,,,) = PriceDataFeed.latestRoundData();
        // Store the reference price in the mapping
        referencePrice[poolId] = currentOraclePrice;
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
        // Get the fee based on the pool id and the swap params
        uint24 fee = getFee(poolId,params);
        // Return the selector for the beforeSwap function and the fee
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
    
}