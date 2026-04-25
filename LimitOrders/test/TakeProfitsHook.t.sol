// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TakeProfitsHookTest
/// @author Lovro Posel
/// @notice Tests for the TakeProfitsHook

import {Test} from "forge-std/Test.sol"

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {TakeProfitsHook} from "../src/TakeProfitsHook.sol";

contract TakeProfitsHookTest is Test, Deployers, ERC1155Holder {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    Currency token0;
    Currency token1;
    TakeProfitsHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        (token0, token1) = deployMintAndApprove2Currencies();

        // Deploy the hook to a deterministic address that encodes the desired permission flags.
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("TakeProfitsHook.sol", abi.encode(manager, ""), hookAddress);
        hook = TakeProfitsHook(hookAddress);

        // Approve the hook to pull our tokens when we place orders.
        MockERC20(Currency.unwrap(token0)).approve(hookAddress, type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(hookAddress, type(uint256).max);

        // Initialize a pool with the hook.
        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);

        // Seed liquidity at a few ranges so swaps actually work.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_placeOrder() public {
        int24 tickToSellAt = 100;
        uint256 amount = 10e18;
        bool zeroForOne = true;

        uint256 originalToken0Balance = token0.balanceOfSelf();

        int24 tickForOrder = hook.placeOrder(key, tickToSellAt, zeroForOne, amount);

        uint256 newToken0Balance = token0.balanceOfSelf();

        assertEq(tickForOrder, 60);
        assertEq(originalToken0Balance - newToken0Balance, amount);

        uint256 positionId = hook.getPositionId(key, tickForOrder, zeroForOne);
        uint256 claimTokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(claimTokenBalance, amount);
    }

    function test_cancelOrder() public {
        int24 tickToSellAt = 100;
        uint256 amount = 10e18;
        bool zeroForOne = true;

        uint256 originalToken0Balance = token0.balanceOfSelf();

        int24 tickForOrder = hook.placeOrder(key, tickToSellAt, zeroForOne, amount);

        uint256 newToken0Balance = token0.balanceOfSelf();

        assertEq(tickForOrder, 60);
        assertEq(originalToken0Balance - newToken0Balance, amount);

        uint256 positionId = hook.getPositionId(key, tickForOrder, zeroForOne);
        uint256 claimTokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(claimTokenBalance, amount);

        hook.cancelOrder(key, tickForOrder, zeroForOne, amount);

        uint256 finalToken0Balance = token0.balanceOfSelf();

        assertEq(finalToken0Balance, originalToken0Balance);
        claimTokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(claimTokenBalance, 0);
    }
}
