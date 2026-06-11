// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {DynamicLPFeesHook} from "../src/LPFees/DynamicLPFeesHook.sol";
import {MockChainlinkAggregator} from "../test/mocks/MockChainlinkAggregator.sol";
import {NetworkConfig} from "./NetworkConfig.sol";

/// @notice Sync Sepolia mock oracle + move pool spot to the live Chainlink ETH/USD price.
contract AlignSepoliaPool is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_UNITS = 3;

    function run() external {
        address hookAddr = vm.envAddress("HOOK_ADDR");
        int256 oraclePrice8 = vm.envInt("ORACLE_PRICE8");
        NetworkConfig.Config memory cfg = NetworkConfig.baseSepolia();

        vm.startBroadcast();
        _syncOracle(vm.envAddress("ETH_USD_FEED"), oraclePrice8);
        PoolSwapTest swapRouter = _ensureLiquidity(cfg, hookAddr, oraclePrice8);
        _alignPoolPrice(cfg.poolManager, swapRouter, hookAddr, oraclePrice8);
        vm.stopBroadcast();

        _logResult(hookAddr, cfg.poolManager, oraclePrice8);
    }

    function _syncOracle(address feedAddr, int256 oraclePrice8) internal {
        uint256 now = block.timestamp;
        MockChainlinkAggregator(feedAddr).setRound(oraclePrice8, now - 120, now - 60);
        console2.log("Oracle synced USD:", uint256(oraclePrice8) / 1e8);
    }

    function _ensureLiquidity(NetworkConfig.Config memory cfg, address hookAddr, int256 oraclePrice8)
        internal
        returns (PoolSwapTest swapRouter)
    {
        IPoolManager manager = IPoolManager(cfg.poolManager);
        PoolKey memory key = _poolKey(cfg, hookAddr);
        if (manager.getLiquidity(key.toId()) > 0) {
            swapRouter = PoolSwapTest(vm.envAddress("SWAP_ROUTER"));
            _approvePair(cfg, address(swapRouter));
            return swapRouter;
        }

        console2.log("No liquidity - seeding pool...");
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(key.toId());
        int24 lower = ((tick / TICK_SPACING) - TICK_UNITS) * TICK_SPACING;
        int24 upper = ((tick / TICK_SPACING) + TICK_UNITS) * TICK_SPACING;
        bool wethToken0 = NetworkConfig.wethIsCurrency0(cfg.weth, cfg.usdc);

        uint256 wethAmt = vm.envOr("SEED_WETH_WEI", uint256(0.00003 ether));
        uint256 usdcAmt = vm.envOr("SEED_USDC", FullMath.mulDiv(wethAmt, uint256(oraclePrice8), 1e20));
        uint128 seedLiq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            wethToken0 ? wethAmt : usdcAmt,
            wethToken0 ? usdcAmt : wethAmt
        );

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        _approvePair(cfg, address(lp));
        _approvePair(cfg, address(swapRouter));

        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(seedLiq)), salt: bytes32(0)
            }),
            ""
        );
        console2.log("Seeded liquidity:", uint256(seedLiq));
        console2.log("PoolSwapTest:", address(swapRouter));
    }

    function _alignPoolPrice(address poolManager, PoolSwapTest swapRouter, address hookAddr, int256 oraclePrice8)
        internal
    {
        NetworkConfig.Config memory cfg = NetworkConfig.baseSepolia();
        PoolKey memory key = _poolKey(cfg, hookAddr);
        PoolId id = key.toId();
        IPoolManager manager = IPoolManager(poolManager);
        bool wethToken0 = NetworkConfig.wethIsCurrency0(cfg.weth, cfg.usdc);
        uint256 target = uint256(oraclePrice8);
        bool zeroForOne = !wethToken0;

        for (uint256 i = 0; i < 12; i++) {
            (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);
            uint256 poolPrice8 = _poolPrice8(sqrtPriceX96, wethToken0);
            if (poolPrice8 <= target) break;
            uint256 diffBps = ((poolPrice8 - target) * 10_000) / target;
            if (diffBps <= 50) break;

            int256 usdcIn = -int256(_swapUsdcAmount(diffBps));
            console2.log("Swap USDC in:", uint256(-usdcIn), "diffBps:", diffBps);
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne, amountSpecified: usdcIn, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
    }

    function _logResult(address hookAddr, address poolManager, int256 oraclePrice8) internal view {
        NetworkConfig.Config memory cfg = NetworkConfig.baseSepolia();
        PoolKey memory key = _poolKey(cfg, hookAddr);
        IPoolManager manager = IPoolManager(poolManager);
        PoolId id = key.toId();
        bool wethToken0 = NetworkConfig.wethIsCurrency0(cfg.weth, cfg.usdc);

        (uint24 fee, uint256 dev) = DynamicLPFeesHook(hookAddr).previewFee(id);
        (uint160 sqrtAfter,,,) = manager.getSlot0(id);
        console2.log("Pool ETH/USD after:", _poolPrice8(sqrtAfter, wethToken0) / 1e8);
        console2.log("Target oracle USD:", uint256(oraclePrice8) / 1e8);
        console2.log("previewFee feePips:", uint256(fee), "devBps:", dev);
    }

    function _poolKey(NetworkConfig.Config memory cfg, address hookAddr) internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(NetworkConfig.currency0(cfg.weth, cfg.usdc)),
            currency1: Currency.wrap(NetworkConfig.currency1(cfg.weth, cfg.usdc)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
    }

    function _approvePair(NetworkConfig.Config memory cfg, address spender) internal {
        IERC20Minimal(cfg.weth).approve(spender, type(uint256).max);
        IERC20Minimal(cfg.usdc).approve(spender, type(uint256).max);
    }

    function _swapUsdcAmount(uint256 diffBps) internal pure returns (uint256) {
        if (diffBps > 5000) return 2500e6;
        if (diffBps > 2000) return 1200e6;
        if (diffBps > 1000) return 600e6;
        if (diffBps > 500) return 250e6;
        return 80e6;
    }

    function _poolPrice8(uint160 sqrtPriceX96, bool wethToken0) internal pure returns (uint256) {
        uint256 intermediate = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        if (wethToken0) return FullMath.mulDiv(intermediate, 1e20, 1 << 96);
        return FullMath.mulDiv(1e20, 1 << 96, intermediate);
    }
}
