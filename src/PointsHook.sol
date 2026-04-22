// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PointsHook
/// @author Lovro Posel
/// @notice Hook to check the points of the transaction

import {BaseHook} from "../lib/v4-hooks-public/src/base/BaseHook.sol";

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

