SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {BeforeSwapDelta,BeforeSwapDeltaLibrary} from "@uniswap/v4-core/contracts/types/BeforeSwapDelta.sol";
import{Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import{BaseTestHooks} from "@uniswap/v4-core/contracts/libraries/BaseTestHooks.sol";
