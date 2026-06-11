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
        uint256 ts = block.timestamp;
        MockChainlinkAggregator(feedAddr).setRound(oraclePrice8, ts - 120, ts - 60);
        console2.log("Oracle synced USD:", uint256(oraclePrice8) / 1e8);
    }

    function _ensureLiquidity(NetworkConfig.Config memory cfg, address hookAddr, int256 oraclePrice8)
        internal
        returns (PoolSwapTest swapRouter)
    {
        PoolKey memory key = _poolKey(cfg, hookAddr);

        address swapRouterAddr = vm.envOr("SWAP_ROUTER", address(0));
        if (swapRouterAddr == address(0) || swapRouterAddr.code.length == 0) {
            swapRouter = new PoolSwapTest(IPoolManager(cfg.poolManager));
            console2.log("PoolSwapTest:", address(swapRouter));
        } else {
            swapRouter = PoolSwapTest(swapRouterAddr);
        }

        _approvePair(cfg, address(swapRouter));
        _seedBridgingLiquidity(cfg, key, oraclePrice8);
    }

    function _seedBridgingLiquidity(NetworkConfig.Config memory cfg, PoolKey memory key, int256 oraclePrice8)
        internal
    {
        IPoolManager manager = IPoolManager(cfg.poolManager);
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(key.toId());
        bool wethToken0 = NetworkConfig.wethIsCurrency0(cfg.weth, cfg.usdc);
        int24 targetTick = TickMath.getTickAtSqrtPrice(NetworkConfig.sqrtPriceFromOracle(oraclePrice8, wethToken0));

        int24 lower = ((tick < targetTick ? tick : targetTick) / TICK_SPACING - 1) * TICK_SPACING;
        int24 upper = ((tick > targetTick ? tick : targetTick) / TICK_SPACING + 1) * TICK_SPACING;
        if (lower >= upper) return;

        _addLiquidityInRange(cfg, key, sqrtPriceX96, lower, upper, wethToken0);
    }

    function _addLiquidityInRange(
        NetworkConfig.Config memory cfg,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        int24 lower,
        int24 upper,
        bool wethToken0
    ) internal {
        uint256 wethAmt = (IERC20Minimal(cfg.weth).balanceOf(msg.sender) * 90) / 100;
        uint256 usdcAmt = (IERC20Minimal(cfg.usdc).balanceOf(msg.sender) * 90) / 100;
        if (wethAmt < 1e12 && usdcAmt < 1e4) return;

        uint128 seedLiq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            wethToken0 ? wethAmt : usdcAmt,
            wethToken0 ? usdcAmt : wethAmt
        );
        if (seedLiq == 0) return;

        IPoolManager manager = IPoolManager(cfg.poolManager);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        _approvePair(cfg, address(lp));
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(seedLiq)), salt: bytes32(0)
            }),
            ""
        );
        console2.log("Bridging liquidity:", uint256(seedLiq));
    }

    function _alignPoolPrice(address poolManager, PoolSwapTest swapRouter, address hookAddr, int256 oraclePrice8)
        internal
    {
        NetworkConfig.Config memory cfg = NetworkConfig.baseSepolia();
        uint256 wethBal = IERC20Minimal(cfg.weth).balanceOf(msg.sender);
        if (wethBal < 1e12) return;

        _runAlignSwaps(
            IPoolManager(poolManager),
            swapRouter,
            _poolKey(cfg, hookAddr),
            NetworkConfig.wethIsCurrency0(cfg.weth, cfg.usdc),
            uint256(oraclePrice8),
            wethBal
        );
    }

    function _runAlignSwaps(
        IPoolManager manager,
        PoolSwapTest swapRouter,
        PoolKey memory key,
        bool wethToken0,
        uint256 target,
        uint256 wethBal
    ) internal {
        PoolId id = key.toId();
        bool zeroForOne = wethToken0;
        uint160 priceLimit = NetworkConfig.sqrtPriceFromOracle(int256(target), wethToken0);

        for (uint256 i = 0; i < 24; i++) {
            if (wethBal < 1e12) break;
            (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);
            uint256 poolPrice8 = _poolPrice8(sqrtPriceX96, wethToken0);
            if (poolPrice8 <= target) break;
            uint256 diffBps = ((poolPrice8 - target) * 10_000) / target;
            if (diffBps <= 50) break;

            uint256 swapAmt = _swapWethAmount(diffBps, wethBal);
            console2.log("Swap WETH in:", swapAmt, "diffBps:", diffBps);
            _swapIn(swapRouter, key, zeroForOne, swapAmt, priceLimit);
            wethBal -= swapAmt;
        }
    }

    function _swapIn(
        PoolSwapTest swapRouter,
        PoolKey memory key,
        bool zeroForOne,
        uint256 swapAmt,
        uint160 targetSqrt
    ) internal {
        uint160 limit = zeroForOne
            ? (targetSqrt > TickMath.MIN_SQRT_PRICE + 1 ? targetSqrt : TickMath.MIN_SQRT_PRICE + 1)
            : (targetSqrt < TickMath.MAX_SQRT_PRICE - 1 ? targetSqrt : TickMath.MAX_SQRT_PRICE - 1);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(swapAmt), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
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

    function _swapWethAmount(uint256 diffBps, uint256 maxWei) internal pure returns (uint256) {
        uint256 want;
        if (diffBps > 5000) want = 0.01 ether;
        else if (diffBps > 2000) want = 0.005 ether;
        else if (diffBps > 1000) want = 0.002 ether;
        else if (diffBps > 500) want = 0.001 ether;
        else want = 0.0003 ether;
        if (want > maxWei) want = maxWei;
        uint256 hopCap = maxWei <= 0.0001 ether ? maxWei / 8 : 0.0005 ether;
        if (want > hopCap) want = hopCap;
        return want;
    }

    function _poolPrice8(uint160 sqrtPriceX96, bool wethToken0) internal pure returns (uint256) {
        uint256 intermediate = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        if (wethToken0) return FullMath.mulDiv(intermediate, 1e20, 1 << 96);
        return FullMath.mulDiv(1e20, 1 << 96, intermediate);
    }
}
