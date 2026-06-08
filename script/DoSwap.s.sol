// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {DynamicLPFeesHook} from "../src/LPFees/DynamicLPFeesHook.sol";

/// @notice Performs a real swap through the seeded pool and verifies the hook's
/// dynamic fee path on-chain (captures the FeeAdjusted event + before/after state).
///   HOOK_ADDR=0x.. SWAP_ROUTER=0x.. forge script script/DoSwap.s.sol \
///     --rpc-url http://127.0.0.1:8545 --broadcast --private-key 0xac09...ff80
contract DoSwap is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    int24 internal constant TICK_SPACING = 60;

    function run() external {
        address hookAddr = vm.envAddress("HOOK_ADDR");
        PoolSwapTest swapRouter = PoolSwapTest(vm.envAddress("SWAP_ROUTER"));
        IPoolManager manager = IPoolManager(POOL_MANAGER);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        PoolId id = key.toId();

        (uint160 spBefore,,,) = manager.getSlot0(id);
        (uint24 feeBefore, uint256 devBefore) = DynamicLPFeesHook(hookAddr).previewFee(id);
        console2.log("Before - sqrtP:", uint256(spBefore));
        console2.log("Before - feePips:", uint256(feeBefore), "devBps:", devBefore);

        // Sell 1 WETH (exact input, zeroForOne).
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.recordLogs();
        vm.startBroadcast();
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        vm.stopBroadcast();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("FeeAdjusted(bytes32,uint24,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                (uint24 emittedFee, uint256 emittedDev) = abi.decode(logs[i].data, (uint24, uint256));
                console2.log("FeeAdjusted event - feePips:", uint256(emittedFee), "devBps:", emittedDev);
            }
        }

        (uint160 spAfter,,,) = manager.getSlot0(id);
        (uint24 feeAfter, uint256 devAfter) = DynamicLPFeesHook(hookAddr).previewFee(id);
        console2.log("After  - sqrtP:", uint256(spAfter));
        console2.log("After  - feePips:", uint256(feeAfter), "devBps:", devAfter);
    }
}
