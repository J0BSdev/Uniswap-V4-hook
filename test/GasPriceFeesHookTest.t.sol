// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Deployers} from "../lib/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "../lib/v4-core/src/PoolManager.sol";
import {Currency, CurrencyLibrary} from "../lib/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "../lib/v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "../lib/v4-core/src/test/PoolSwapTest.sol";
import {GasPriceFeesHook} from "../src/GasPriceFeesHook.sol";
import {TickMath} from "../lib/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "../lib/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "../lib/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "../lib/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "../lib/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "../lib/v4-core/src/interfaces/IHooks.sol";

contract GasPriceFeesHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolId;

    GasPriceFeesHook hook;

    function setUp() public {
        //deploy v4 core contracts
        deployFreshManagerAndRouters();

        //deploy 2 erc-20 tokens ,mint some amount of them to ourselves
        //and approve all router contracts to spend them
        deployMintAndApprove2Currencies();

        //deploy our hook
        address hookAddress =
            address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG));

        //NOTE: by default in the testing environment, gas price is set to 0

        vm.txGasPrice(10 gwei);
        deployCodeTo("GasPriceFeesHook.sol", abi.encode(manager), hookAddress);
        hook = GasPriceFeesHook(hookAddress);

        // initialize a new pool
        (key,) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        //add liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: 100e18, salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_feesUpdatesWithGasPrice() public {
        //we're gonna do 3 swaps
        //1 swap = expect fees being charged = base fees
        //1 swap = expect fees being charged < base fees
        //1 swap = expect fees being charged > base fees

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -0.00001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        //STEP = SANITY CHECK
        // expect movinAveraagePrice = 10 gwei
        // expect movingAverageGasPriceCount = 1

        uint128 movingAverageGasPrice = hook.movingAverageGasPrice();
        uint104 movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        assertEq(movingAverageGasPrice, 10 gwei);
        assertEq(movingAverageGasPriceCount, 1);

        // STEP 2 = FIRST SWAP
        //sell token0 for token1
        //at a gas price of 10 gwei
        // keep track of how muck token1 we get back

        uint256 balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        uint256 balanceOfToken1After = currency1.balanceOfSelf();
        uint256 outputFromBaseFeeSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);
        movingAverageGasPrice = hook.movingAverageGasPrice();
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        assertEq(movingAverageGasPrice, 10 gwei);
        assertEq(movingAverageGasPriceCount, 2);

        // STEP 3 = SECOND SWAP
        // sell token0 for token1
        //at a gas price of 4 gwei

        vm.txGasPrice(4 gwei);
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();

        uint256 outputfromIncreasedFeeSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // our moving average should now be ( 10 + 10 + 4) / 3 = 8 gwei
        movingAverageGasPrice = hook.movingAverageGasPrice();
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        assertEq(movingAverageGasPrice, 8 gwei);
        assertEq(movingAverageGasPriceCount, 3);

        // STEP 4 = THIRD SWAP
        //sell token0 for token1
        //at a gas price of 12 gwei

        vm.txGasPrice(12 gwei);
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();

        uint256 outputFromDecreasedFeeSwap = balanceOfToken1After - balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // our movung average should now be ( 10 + 10 + 4 + 12) / 4 = 9 gwei
        movingAverageGasPrice = hook.movingAverageGasPrice();
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();

        assertEq(movingAverageGasPrice, 9 gwei);
        assertEq(movingAverageGasPriceCount, 4);

        assertGt(outputFromDecreasedFeeSwap, outputFromBaseFeeSwap);
        assertGt(outputFromBaseFeeSwap, outputfromIncreasedFeeSwap);

        console.log("outputFromBaseFeeSwap", outputFromBaseFeeSwap);
        console.log("outputfromIncreasedFeeSwap", outputfromIncreasedFeeSwap);
        console.log("outputFromDecreasedFeeSwap", outputFromDecreasedFeeSwap);
    }
}
