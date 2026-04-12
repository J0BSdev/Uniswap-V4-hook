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
 