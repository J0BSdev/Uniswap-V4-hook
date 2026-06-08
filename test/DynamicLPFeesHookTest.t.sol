// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {DynamicLPFeesHook} from "../src/LPFees/DynamicLPFeesHook.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";

contract DynamicLPFeesHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant PRICE_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    uint256 internal constant ORACLE_ETH_USD = 3500e8;

    DynamicLPFeesHook hook;
    MockChainlinkAggregator priceFeed;
    MockChainlinkAggregator sequencerFeed;
    PoolId poolId;

    function setUp() public {
        vm.warp(10_000);
        deployFreshManagerAndRouters();
        _deployMockFeeds();
        _deployWethUsdc();
        _deployHook();
    }

    function test_previewFee_lowTier_whenPoolMatchesOracle() public {
        _initPoolAtOraclePrice();
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.LOW_FEE());
        assertEq(bps, 0);
    }

    function test_previewFee_mediumTier_whenDeviationIs3Percent() public {
        _setOraclePrice(ORACLE_ETH_USD);
        uint160 sqrtPrice = encodeSqrtPriceX96(_oraclePriceWithDeltaBps(300));
        _initPool(sqrtPrice);

        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.MEDIUM_FEE());
        assertApproxEqAbs(bps, 300, 2);
    }

    function test_previewFee_highTier_whenDeviationIs10Percent() public {
        _setOraclePrice(ORACLE_ETH_USD);
        uint160 sqrtPrice = encodeSqrtPriceX96(_oraclePriceWithDeltaBps(1000));
        _initPool(sqrtPrice);

        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.HIGH_FEE());
        assertApproxEqAbs(bps, 1000, 2);
    }

    function test_previewFee_veryHighTier_whenDeviationIs25Percent() public {
        _setOraclePrice(ORACLE_ETH_USD);
        uint160 sqrtPrice = encodeSqrtPriceX96(_oraclePriceWithDeltaBps(2500));
        _initPool(sqrtPrice);

        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.VERY_HIGH_FEE());
        assertApproxEqAbs(bps, 2500, 5);
    }

    function test_reverts_ifPoolIsNotDynamicFee() public {
        _setOraclePrice(ORACLE_ETH_USD);
        currency0 = Currency.wrap(WETH);
        currency1 = Currency.wrap(USDC);

        PoolKey memory badKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(DynamicLPFeesHook.MustUseDynamicFees.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(badKey, encodeSqrtPriceX96(ORACLE_ETH_USD));
    }

    function test_reverts_ifPoolPairIsInvalid() public {
        _setOraclePrice(ORACLE_ETH_USD);
        deployMintAndApprove2Currencies();

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(DynamicLPFeesHook.InvalidPoolPair.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, encodeSqrtPriceX96(ORACLE_ETH_USD));
    }

    function test_reverts_ifSequencerIsDown() public {
        _initPoolAtOraclePrice();
        sequencerFeed.setRound(1, block.timestamp - 5000, block.timestamp);

        vm.expectRevert(DynamicLPFeesHook.SequencerDown.selector);
        hook.previewFee(poolId);
    }

    function test_reverts_ifOracleIsStale() public {
        _initPoolAtOraclePrice();
        priceFeed.setRound(int256(ORACLE_ETH_USD), block.timestamp - 5000, block.timestamp - 5000);

        vm.expectRevert(DynamicLPFeesHook.StaleOraclePrice.selector);
        hook.previewFee(poolId);
    }

    function test_swap_emitsFeeAdjusted() public {
        _initPoolAtOraclePrice();
        _addLiquidity();

        vm.expectEmit(true, false, false, true, address(hook));
        emit DynamicLPFeesHook.FeeAdjusted(poolId, hook.LOW_FEE(), 0);

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, params, settings, ZERO_BYTES);
    }

    // --- helpers ---

    function _deployMockFeeds() internal {
        deployCodeTo("MockChainlinkAggregator.sol", PRICE_FEED);
        deployCodeTo("MockChainlinkAggregator.sol", SEQUENCER_FEED);
        priceFeed = MockChainlinkAggregator(PRICE_FEED);
        sequencerFeed = MockChainlinkAggregator(SEQUENCER_FEED);
        _setOraclePrice(ORACLE_ETH_USD);
        _setSequencerUp();
    }

    function _setOraclePrice(uint256 oraclePrice8) internal {
        priceFeed.setRound(int256(oraclePrice8), block.timestamp - 5000, block.timestamp);
    }

    function _setSequencerUp() internal {
        sequencerFeed.setRound(0, block.timestamp - 5000, block.timestamp);
    }

    function _deployWethUsdc() internal {
        deployCodeTo(
            "solmate/src/test/utils/mocks/MockERC20.sol:MockERC20",
            abi.encode("WETH", "WETH", uint8(18)),
            WETH
        );
        deployCodeTo(
            "solmate/src/test/utils/mocks/MockERC20.sol:MockERC20",
            abi.encode("USDC", "USDC", uint8(6)),
            USDC
        );

        MockERC20(WETH).mint(address(this), 10_000 ether);
        MockERC20(USDC).mint(address(this), 10_000_000e6);

        address[9] memory routers = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];

        for (uint256 i = 0; i < routers.length; i++) {
            MockERC20(WETH).approve(routers[i], type(uint256).max);
            MockERC20(USDC).approve(routers[i], type(uint256).max);
        }

        currency0 = Currency.wrap(WETH);
        currency1 = Currency.wrap(USDC);
    }

    function _deployHook() internal {
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("DynamicLPFeesHook.sol", abi.encode(manager), hookAddress);
        hook = DynamicLPFeesHook(hookAddress);
    }

    function _initPoolAtOraclePrice() internal {
        _initPool(encodeSqrtPriceX96(ORACLE_ETH_USD));
    }

    function _initPool(uint160 sqrtPriceX96) internal {
        (key, poolId) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, sqrtPriceX96);
    }

    function _addLiquidity() internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1000e18, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function _oraclePriceWithDeltaBps(uint256 deltaBps) internal pure returns (uint256) {
        return ORACLE_ETH_USD * (10_000 + deltaBps) / 10_000;
    }

    function encodeSqrtPriceX96(uint256 ethUsd8) internal pure returns (uint160) {
        uint256 ratioX192 = FullMath.mulDiv(ethUsd8, uint256(1) << 192, 1e20);
        return uint160(_sqrt(ratioX192));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        uint256 y = x;
        z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}
