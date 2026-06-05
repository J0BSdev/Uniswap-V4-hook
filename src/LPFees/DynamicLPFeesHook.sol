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

import {Types} from "./Types.sol";
import {RiskModelLib} from "./RiskModelLib.sol";
import {PolicyLib} from "./PolicyLib.sol";

contract DynamicLPFeesHook is BaseHook {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    error MustUseDynamicFees();

    event FeeAdjusted(
        PoolId indexed poolId,
        Types.RiskTier tier,
        uint24 feePips,
        uint256 sizeRatioBps,
        uint256 priceDeviationBps,
        uint256 totalScore
    );

    mapping(PoolId => uint160) public referenceSqrtPriceX96;
    mapping(PoolId => uint24) public lastAppliedFee;
    mapping(PoolId => Types.RiskTier) public lastTier;
    mapping(PoolId => Types.RiskScore) public lastScore;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

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
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFees();
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        override
        returns (bytes4)
    
