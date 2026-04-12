// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GasPriceFeesHook
/// @author Lovro Posel
/// @notice Hook to check the gas price and fees of the transaction
 import {BaseHooks} from "../lib/v4-core/src/hooks/BaseHooks.sol";
 import {IHooks} from "../lib/v4-core/src/interfaces/IHooks.sol";
 import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
 import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
 import {BalanceDelta} from "../lib/v4-core/src/types/BalanceDelta.sol";
 import {LPFeeLibrary} from "../lib/v4-core/src/libraries/LPFeeLibrary.sol";
 import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "../lib/v4-core/src/types/BeforeSwapDelta.sol";


 contract GasPriceFeesHook is BaseHooks {

uint128 public movingAverageGasPrice; // current moving average gas price
uint104 public movingAverageGasPriceCount; //the number of txns we ve observed to get to that value

    uint24 public contsant BASE_FEES = 5000; //pips, 0.5% fee






constructor(IPoolManager _manager) BaseHook(_manager) {}



function getHookPermissions() public
 pure 
 override 
 returns (Hooks.Permissions memory) 
 {
    return Hooks.Permissions({
        beforeInitialize: true,
        afterInitialize: false,
        beforeAddLiquidity: false,
        beforeRemoveLiquidity: false,
        afterAddLiquidity: false,
        afterRemoveLiquidity: false,
        beforeSwap: true,
        afterSwap: true,
        beforeDonate: false,
        afterDonate: false,
        beforeSwapReturnDelta: false,
        afterSwapReturnDelta: false,
        afterAddLiquidityReturnDelta: false,
        afterRemoveLiquidityReturnDelta: false,
    });
 }

 function updateMovingAverage() internal{
    uint128 gasPrice = uint128(tx.gasprice);
    movingAverageGasPrice = (movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice / (movingAverageGasPriceCount + 1);
    movingAverageGasPriceCount++;
 }

 }


