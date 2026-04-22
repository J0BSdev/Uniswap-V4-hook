// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ExecutionGuardHook
/// @author Lovro Posel
/// @notice Starter hook: extend with slippage/MEV checks inside `beforeSwap`.
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol"

