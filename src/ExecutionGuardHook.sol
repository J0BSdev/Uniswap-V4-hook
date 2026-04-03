//SPDX-License-Identifier: MIT

//@title ExecutionGuardHook
//@author Lovro Posel
//@notice this hook will prevent the execution of the swap if the slippage is too high.

pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta,BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import{Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import{BaseTestHooks} from "@uniswap/v4-core/src/libraries/BaseTestHooks.sol";
import {OnlyPoolManager} from "@uniswap/v4-core/src/libraries/OnlyPoolManager.sol";



   
