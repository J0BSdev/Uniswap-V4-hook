// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DynamicLPFeesHook
/// @author Lovro Posel
/// @notice Uniswap v4 hook that charges a dynamic fee based on the liquidity of the pool.

import{PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {BaseHook} from "../lib/v4-hooks-public/src/base/BaseHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";


PoolKey memory poolKey = PoolKey({
    currency0: currency0,
    currency1: currency1,
    fee: lpFee,
    tickSpacing: tickSpacing,
    hooks: hookContract
});
