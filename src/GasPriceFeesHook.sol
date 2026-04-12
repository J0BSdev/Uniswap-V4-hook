// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GasPriceFeesHook
/// @author Lovro Posel
/// @notice Hook to check the gas price and fees of the transaction
import {Hooks} from "../lib/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "../lib/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "../lib/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "../lib/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "../lib/v4-core/src/types/BeforeSwapDelta.sol";

contract GasPriceFeesHook is BaseHooks {
    using LpFeeLibrary for uint24;

    uint128 public movingAverageGasPrice; // current moving average gas price
    uint104 public movingAverageGasPriceCount; //the number of txns we ve observed to get to that value

    uint24 public constant BASE_FEES = 5000; //pips, 0.5% fee

    error _MustUseDynamicFees();

    constructor(IPoolManager _manager) BaseHook(_manager) {
        updateMovingAverage();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
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
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(adress, PoolKey calldata key, uint160) external pure override returns (bytes4) {
        if (!key.fee.isDynamicFees()) revert _MustUseDynamicFees();
        return this.beforeInitialize.selector;
    }

    function beforeSwap(adress, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        //1. look at gas price for this swap
        //2. compare to moving average gas price
        //3. get a fee value to charge for this swap
        //4. return the new fee value

        uint24 fee = getFee();
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    function afterSwap(adress, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        updateMovingAverage();
        return (this.afterSwap.selector, 0);
    }

    function getFee() internal view returns (uint24) {
        uint128 gasPrice = uint128(tx.gasprice);
        if (gasPrice > movingAverageGasPrice * 11 / 10) {
            return BASE_FEES / 2;
        }
        if (gasPrice < movingAverageGasPrice * 9 / 10) {
            return BASE_FEES * 2;
        }
        return BASE_FEES;
    }

    function updateMovingAverage() internal {
        uint128 gasPrice = uint128(tx.gasprice);
        movingAverageGasPrice =
            (movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice / (movingAverageGasPriceCount + 1);
        movingAverageGasPriceCount++;
    }
}

