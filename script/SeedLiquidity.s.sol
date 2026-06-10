// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {NetworkConfig} from "./NetworkConfig.sol";

/// @notice Deploys liquidity + swap test routers and seeds the WETH/USDC pool with
/// liquidity so the frontend can execute real swaps on the fork.
/// Requires: deployer holds WETH and USDC. Pass HOOK_ADDR env var.
///   HOOK_ADDR=0x... forge script script/SeedLiquidity.s.sol \
///     --rpc-url http://127.0.0.1:8545 --broadcast --private-key 0xac09...ff80
contract SeedLiquidity is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    int24 internal constant TICK_SPACING = 60;
    // Narrow range around spot; minimal token amounts for fork demo swaps.
    int24 internal constant TICK_UNITS = 3;

    function run() external returns (address lpRouter, address swapRouter) {
        address hookAddr = vm.envAddress("HOOK_ADDR");
        NetworkConfig.Config memory cfg = _networkConfig();
        IPoolManager manager = IPoolManager(cfg.poolManager);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(NetworkConfig.currency0(cfg.weth, cfg.usdc)),
            currency1: Currency.wrap(NetworkConfig.currency1(cfg.weth, cfg.usdc)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });

        PoolId id = key.toId();
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(id);

        int24 lower = ((tick / TICK_SPACING) - TICK_UNITS) * TICK_SPACING;
        int24 upper = ((tick / TICK_SPACING) + TICK_UNITS) * TICK_SPACING;

        uint128 liquidity = _liquidityForSeed(cfg, sqrtPriceX96, lower, upper);

        vm.startBroadcast();

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        PoolSwapTest sw = new PoolSwapTest(manager);

        IERC20Minimal(cfg.weth).approve(address(lp), type(uint256).max);
        IERC20Minimal(cfg.usdc).approve(address(lp), type(uint256).max);
        IERC20Minimal(cfg.weth).approve(address(sw), type(uint256).max);
        IERC20Minimal(cfg.usdc).approve(address(sw), type(uint256).max);

        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        vm.stopBroadcast();

        lpRouter = address(lp);
        swapRouter = address(sw);

        console2.log("==========================================================");
        console2.log("Liquidity added. liquidity units:", uint256(liquidity));
        console2.log("Tick lower:", lower);
        console2.log("Tick upper:", upper);
        console2.log("PoolModifyLiquidityTest:", lpRouter);
        console2.log("PoolSwapTest (swap router):", swapRouter);
        console2.log("Frontend env:");
        console2.log("  VITE_SWAP_ROUTER =", swapRouter);
        console2.log("  VITE_LP_TICK_LOWER =", lower);
        console2.log("  VITE_LP_TICK_UPPER =", upper);
        console2.log("==========================================================");
    }

    function _networkConfig() internal view returns (NetworkConfig.Config memory cfg) {
        if (vm.envOr("USE_SEPOLIA", false)) {
            return NetworkConfig.baseSepolia();
        }
        return NetworkConfig.baseMainnet();
    }

    function _liquidityForSeed(
        NetworkConfig.Config memory cfg,
        uint160 sqrtPriceX96,
        int24 lower,
        int24 upper
    ) internal view returns (uint128) {
        bool wethToken0 = NetworkConfig.wethIsCurrency0(cfg.weth, cfg.usdc);
        (uint256 amount0, uint256 amount1) = _seedAmounts(wethToken0);
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            amount0,
            amount1
        );
    }

    function _seedAmounts(bool wethToken0) internal view returns (uint256 amount0, uint256 amount1) {
        uint256 wethAmt = vm.envOr("SEED_WETH_WEI", uint256(1 ether));
        uint256 usdcAmt = vm.envOr("SEED_USDC", uint256(0));
        if (usdcAmt == 0) {
            int256 oracle8 = vm.envOr("ORACLE_PRICE8", int256(3500e8));
            usdcAmt = uint256(oracle8 / 1e8) * 1e6;
        }
        amount0 = wethToken0 ? wethAmt : usdcAmt;
        amount1 = wethToken0 ? usdcAmt : wethAmt;
    }
}
