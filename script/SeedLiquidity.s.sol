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

/// @notice Deploys liquidity + swap test routers and seeds the WETH/USDC pool with
/// liquidity so the frontend can execute real swaps on the fork.
/// Requires: deployer holds WETH and USDC. Pass HOOK_ADDR env var.
///   HOOK_ADDR=0x... forge script script/SeedLiquidity.s.sol \
///     --rpc-url http://127.0.0.1:8545 --broadcast --private-key 0xac09...ff80
contract SeedLiquidity is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    int24 internal constant TICK_SPACING = 60;
    // Concentrated range: +/- 3 spacing units (180 ticks) around the current tick.
    // Much deeper than a wide range so 1 WETH swaps barely move the pool price.
    int24 internal constant TICK_UNITS = 3;

    function run() external returns (address lpRouter, address swapRouter) {
        address hookAddr = vm.envAddress("HOOK_ADDR");
        IPoolManager manager = IPoolManager(POOL_MANAGER);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });

        PoolId id = key.toId();
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(id);

        int24 lower = ((tick / TICK_SPACING) - TICK_UNITS) * TICK_SPACING;
        int24 upper = ((tick / TICK_SPACING) + TICK_UNITS) * TICK_SPACING;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            120 ether,
            210_000e6
        );

        vm.startBroadcast();

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        PoolSwapTest sw = new PoolSwapTest(manager);

        IERC20Minimal(WETH).approve(address(lp), type(uint256).max);
        IERC20Minimal(USDC).approve(address(lp), type(uint256).max);
        IERC20Minimal(WETH).approve(address(sw), type(uint256).max);
        IERC20Minimal(USDC).approve(address(sw), type(uint256).max);

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
}
