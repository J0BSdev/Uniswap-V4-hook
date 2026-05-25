// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DynamicLPFeesHook
/// @author Lovro Posel
/// @notice Uniswap v4 hook that charges a dynamic fee based on the liquidity of the pool.

import {BaseHook} from "../lib/v4-hooks-public/src/base/BaseHook.sol";

contract DynamicLPFeesHook is BaseHook {
    constructor(IPoolManager poolManager) BaseHook(poolManager) {}
}