// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TakeProfitsHookTest
/// @author Lovro Posel
/// @notice Test for the TakeProfitsHook

import {Test} from "forge-std/Test.sol";
import {Deployers} from "../../lib/v4-core/test/Deployers.sol";
import {PoolSwapTest} from "../../lib/v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "../../lib/v4-core/test/mocks/MockERC20.sol";
import {PoolManager} from "../../lib/v4-core/src/PoolManager.sol";
import {IPoolManager} from "../../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId,PoolIdLibrary} from "../../lib/v4-core/src/types/PoolId.sol";
import {Currency,CurrencyLibrary} from "../../lib/v4-core/src/types/Currency.sol";
import {StateLibrary} from "../../lib/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "../../lib/v4-core/src/types/PoolKey.sol";
 import {Hooks} from "../../lib/v4-hooks-public/src/Hooks.sol";
 import {TickMath} from "../../lib/v4-core/src/libraries/TickMath.sol";

 import {TakeProfitsHook} from "../src/TakeProfitsHook.sol";


 contract TakeProfitsHookTest is Test, Deployers{

    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency token0;
    Currency token1;
    TakeProfitsHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();

        (token0, token1) = deployMintAndApprove2Currencies();
         
         uint160 flags =  uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
         );
         address hookAddress = address(flags);
         deployCodeTo("TakeProfitsHook.sol",abi.encode(manager, ""),
         hookAddress);
         hook = TakeProfitsHook(hookAddress);

         }

         MockERC20(Currency.unwrap(token0)).approve(hookAddress,type(uint256).max);
         MockERC20(Currency.unwrap(token1)).approve(hookAddress,type(uint256).max);

         (key,) = initPool(token0,token1 , hook, 3000, SQRT_PRICE_1_1);

         modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower:-60
                tickUpper:60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
         );

         }


         modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower:-120
                tickUpper:120,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
         );
         modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower : TickMath.minUsableTick(60),
                tickUpper : TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
         );
}



function test_placeOrder() public {

    int24 tickTosellAt = 100;
    uint256 amount = 10e18;
    bool zeroForOne = true;

    uint256 originalToken0Balance = token0.balanceOfSelf();

    int24 tickForOrder = hook.placeOrder(key,tickTosellAt,zeroForOne,amount);

    uint256 newToken0Balance = token0.balanceOfSelf();

    assertEq(tickForOrder, 60);
    assertEq(originalToken0Balance - newToken0Balance, amount);


    uint256 positionId = hook.getPositionId(key,tickForOrder,zeroForOne);
    uint256 claimTokenBalance = hook.balanceOf(address(this),positionId);
    assertEq(claimTokenBalance, amount);

}



function test_cancelOrder() public {

     int24 tickTosellAt = 100;
    uint256 amount = 10e18;
    bool zeroForOne = true;

    uint256 originalToken0Balance = token0.balanceOfSelf();

    int24 tickForOrder = hook.placeOrder(key,tickTosellAt,zeroForOne,amount);

    uint256 newToken0Balance = token0.balanceOfSelf();

    assertEq(tickForOrder, 60);
    assertEq(originalToken0Balance - newToken0Balance, amount);


    uint256 positionId = hook.getPositionId(key,tickForOrder,zeroForOne);
    uint256 claimTokenBalance = hook.balanceOf(address(this),positionId);
    assertEq(claimTokenBalance, amount);

    hook.cancelOrder(key, tickForOrder, zeroForOne, amount);

    uint256 finalToken0Balance = token0.balanceOfSelf();

    assertEq(finalToken0Balance, originalToken0Balance);
claimTokenBalance = hook.balanceOf(address(this),positionId);
assertEq(claimTokenBalance, 0);

}
         

         







