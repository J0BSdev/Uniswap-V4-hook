// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GasPriceFeesHook
/// @author Lovro Posel
/// @notice Hook to check the gas price and fees of the transaction
import {BaseHook} from "../lib/v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract GasPriceFeesHook is BaseHook {
    using LPFeeLibrary for uint24;

    uint128 public movingAverageGasPrice; // current moving average gas price
    uint104 public movingAverageGasPriceCount; //the number of txns we
    //observed to get to that value

    uint24 public constant BASE_FEES = 5000; //pips, 0.5% fee

    error _MustUseDynamicFees();

    constructor(IPoolManager _manager) BaseHook(_manager) {
        updateMovingAverage();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // validate that our dynamic fees are enabled
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,  //apply our dynamic fees to the swap
            afterSwap: true, // track the gas price
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

//verify that our pool has dynamic fees enabled

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert _MustUseDynamicFees();
        return BaseHook.beforeInitialize.selector;
    }


    //before a swap happens we need to:
    //get the current gas price
    //compare the cuurnet gas price with the moving average
    //calculate the amount of fees that should  be charged on the pool
    //update the swap fees in the PoolManager

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        //1. look at gas price for this swap
        //2. compare to moving average gas price
        //3. get a fee value to charge for this swap
        //4. return the new fee value

        uint24 fee = getFee();

        //add our override fee flag onto value
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;


        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        updateMovingAverage();
        return (BaseHook.afterSwap.selector, 0);
    }

    function getFee() internal view returns (uint24) {
        //get the current gas price
        uint128 gasPrice = uint128(tx.gasprice);
        //compare the current gas price with the moving average gas price
        //if the gas price > moving average by 10%, half the fees
        if (gasPrice > movingAverageGasPrice * 11 / 10) {
            return BASE_FEES / 2;
        }
        //if the gas price < moving average by 10%, double the fees
        if (gasPrice < movingAverageGasPrice * 9 / 10) {
            return BASE_FEES * 2;
        }
        //just return the base fees
        return BASE_FEES;
    }

    function updateMovingAverage() internal {
        uint128 gasPrice = uint128(tx.gasprice);
        movingAverageGasPrice =
            ((movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice) / (movingAverageGasPriceCount + 1);
        movingAverageGasPriceCount++;
    }
}

