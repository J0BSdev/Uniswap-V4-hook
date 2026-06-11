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
import {NetworkConfig} from "./NetworkConfig.sol";

/// @notice Performs a real swap through the seeded pool and verifies the hook's
/// dynamic fee path on-chain (captures the FeeAdjusted event + before/after state).
///   HOOK_ADDR=0x.. SWAP_ROUTER=0x.. forge script script/DoSwap.s.sol \
///     --rpc-url http://127.0.0.1:8545 --broadcast --private-key 0xac09...ff80
contract DoSwap is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    int24 internal constant TICK_SPACING = 60;

    function run() external {
        address hookAddr = vm.envAddress("HOOK_ADDR");
        PoolSwapTest swapRouter = PoolSwapTest(vm.envAddress("SWAP_ROUTER"));
        NetworkConfig.Config memory cfg =
            vm.envOr("USE_SEPOLIA", false) ? NetworkConfig.baseSepolia() : NetworkConfig.baseMainnet();
        IPoolManager manager = IPoolManager(cfg.poolManager);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(NetworkConfig.currency0(cfg.weth, cfg.usdc)),
            currency1: Currency.wrap(NetworkConfig.currency1(cfg.weth, cfg.usdc)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        PoolId id = key.toId();

        (uint160 spBefore,,,) = manager.getSlot0(id);
        (uint24 feeBefore, uint256 devBefore) = DynamicLPFeesHook(hookAddr).previewFee(id);
        console2.log("Before - sqrtP:", uint256(spBefore));
        console2.log("Before - feePips:", uint256(feeBefore), "devBps:", devBefore);

        // Sell 1 WETH (exact input).
        bool zeroForOne = NetworkConfig.wethIsCurrency0(cfg.weth, cfg.usdc);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
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
