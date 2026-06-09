// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {DynamicLPFeesHook} from "../src/LPFees/DynamicLPFeesHook.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";

contract DynamicLPFeesHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant PRICE_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    uint256 internal constant ORACLE_ETH_USD = 3500e8;

    DynamicLPFeesHook hook;
    MockChainlinkAggregator priceFeed;
    MockChainlinkAggregator sequencerFeed;
    PoolId poolId;

    PoolSwapTest.TestSettings internal defaultSettings =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    // --- setup ---

    function setUp() public {
        vm.warp(10_000);
        deployFreshManagerAndRouters();
        _deployMockFeeds();
        _deployWethUsdc();
        _deployHook();
    }

    // --- fee tiers (center) ---

    function test_previewFee_lowTier_whenPoolMatchesOracle() public {
        _initPoolAtOraclePrice();
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.LOW_FEE());
        assertEq(bps, 0);
    }

    function test_previewFee_mediumTier_whenDeviationIs3Percent() public {
        _initPoolAtDeviationBps(300);
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.MEDIUM_FEE());
        assertApproxEqAbs(bps, 300, 2);
    }

    function test_previewFee_highTier_whenDeviationIs10Percent() public {
        _initPoolAtDeviationBps(1000);
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.HIGH_FEE());
        assertApproxEqAbs(bps, 1000, 2);
    }

    function test_previewFee_veryHighTier_whenDeviationIs25Percent() public {
        _initPoolAtDeviationBps(2500);
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.VERY_HIGH_FEE());
        assertApproxEqAbs(bps, 2500, 5);
    }

    // --- fee tier boundaries ---

    function test_previewFee_lowTier_at99Bps() public {
        _initPoolAtDeviationBps(99);
        (uint24 fee,) = hook.previewFee(poolId);
        assertEq(fee, hook.LOW_FEE());
    }

    function test_previewFee_mediumTier_whenDeviationCrosses100Bps() public {
        _initPoolAtDeviationBps(110);
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertGe(bps, hook.SCORE_LOW());
        assertEq(fee, hook.MEDIUM_FEE());
    }

    function test_previewFee_mediumTier_at499Bps() public {
        _initPoolAtDeviationBps(499);
        (uint24 fee,) = hook.previewFee(poolId);
        assertEq(fee, hook.MEDIUM_FEE());
    }

    function test_previewFee_highTier_whenDeviationCrosses500Bps() public {
        _initPoolAtDeviationBps(520);
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertGe(bps, hook.SCORE_MEDIUM());
        assertEq(fee, hook.HIGH_FEE());
    }

    function test_previewFee_highTier_at1999Bps() public {
        _initPoolAtDeviationBps(1999);
        (uint24 fee,) = hook.previewFee(poolId);
        assertEq(fee, hook.HIGH_FEE());
    }

    function test_previewFee_veryHighTier_whenDeviationCrosses2000Bps() public {
        _initPoolAtDeviationBps(2100);
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertGe(bps, hook.SCORE_HIGH());
        assertEq(fee, hook.VERY_HIGH_FEE());
    }

    function test_previewFee_veryHighTier_at5000Bps() public {
        _initPoolAtDeviationBps(5000);
        (uint24 fee,) = hook.previewFee(poolId);
        assertEq(fee, hook.VERY_HIGH_FEE());
    }

    // --- symmetric deviation (pool below oracle) ---

    function test_previewFee_lowTier_whenPoolBelowOracle() public {
        _initPoolAtDeviationBps(-50);
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.LOW_FEE());
        assertApproxEqAbs(bps, 50, 2);
    }

    function test_previewFee_mediumTier_whenPoolBelowOracle() public {
        _initPoolAtDeviationBps(-300);
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.MEDIUM_FEE());
        assertApproxEqAbs(bps, 300, 2);
    }

    function test_previewFee_highTier_whenPoolBelowOracle() public {
        _initPoolAtDeviationBps(-1000);
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.HIGH_FEE());
        assertApproxEqAbs(bps, 1000, 2);
    }

    function test_previewFee_veryHighTier_whenPoolBelowOracle() public {
        _initPoolAtDeviationBps(-2500);
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.VERY_HIGH_FEE());
        assertApproxEqAbs(bps, 2500, 5);
    }

    // --- oracle price encoding round-trip ---

    function test_encodeSqrtPrice_roundTrips_atVariousPrices() public pure {
        uint256[5] memory prices = [uint256(1000e8), 3500e8, 5000e8, 10_000e8, 25_000e8];
        for (uint256 i = 0; i < prices.length; i++) {
            uint160 sqrtPrice = _encodeSqrtPriceX96Static(prices[i]);
            uint256 ratioX192 = FullMath.mulDiv(uint256(sqrtPrice), uint256(sqrtPrice), 1);
            uint256 poolPrice8 = FullMath.mulDiv(ratioX192, 1e20, 1 << 192);
            assertApproxEqAbs(poolPrice8, prices[i], 2);
        }
    }

    // --- pool init validation ---

    function test_initialize_succeeds_withValidWethUsdcPool() public {
        _initPoolAtOraclePrice();
        (uint160 sqrtPrice,,,) = manager.getSlot0(poolId);
        assertGt(sqrtPrice, 0);
    }

    function test_reverts_ifPoolIsNotDynamicFee() public {
        _setOraclePrice(ORACLE_ETH_USD);
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        _expectInitializeRevert(DynamicLPFeesHook.MustUseDynamicFees.selector);
        manager.initialize(badKey, encodeSqrtPriceX96(ORACLE_ETH_USD));
    }

    function test_reverts_ifPoolPairIsInvalid() public {
        _setOraclePrice(ORACLE_ETH_USD);
        deployMintAndApprove2Currencies();
        _expectInitializeRevert(DynamicLPFeesHook.InvalidPoolPair.selector);
        initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, encodeSqrtPriceX96(ORACLE_ETH_USD));
    }

    function test_reverts_ifCurrenciesAreReversed() public {
        _setOraclePrice(ORACLE_ETH_USD);
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // PoolManager rejects out-of-order currencies before the hook runs
        vm.expectRevert(
            abi.encodeWithSelector(
                IPoolManager.CurrenciesOutOfOrderOrEqual.selector, USDC, WETH
            )
        );
        manager.initialize(badKey, encodeSqrtPriceX96(ORACLE_ETH_USD));
    }

    function test_reverts_ifOnlyWethIsWrong() public {
        _setOraclePrice(ORACLE_ETH_USD);
        deployMintAndApprove2Currencies();

        PoolKey memory badKey = PoolKey({
            currency0: currency0,
            currency1: Currency.wrap(USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        _expectInitializeRevert(DynamicLPFeesHook.InvalidPoolPair.selector);
        manager.initialize(badKey, encodeSqrtPriceX96(ORACLE_ETH_USD));
    }

    // --- pool price errors ---

    function test_reverts_ifPoolNotInitialized() public {
        PoolId emptyId = PoolId.wrap(bytes32(uint256(999)));
        vm.expectRevert(DynamicLPFeesHook.PoolPriceNotSet.selector);
        hook.previewFee(emptyId);
    }

    // --- sequencer checks ---

    function test_reverts_ifSequencerIsDown() public {
        _initPoolAtOraclePrice();
        sequencerFeed.setRound(1, block.timestamp - 5000, block.timestamp);
        vm.expectRevert(DynamicLPFeesHook.SequencerDown.selector);
        hook.previewFee(poolId);
    }

    function test_reverts_ifGracePeriodNotOver() public {
        _initPoolAtOraclePrice();
        sequencerFeed.setRound(0, block.timestamp - 1000, block.timestamp);
        vm.expectRevert(DynamicLPFeesHook.GracePeriodNotOver.selector);
        hook.previewFee(poolId);
    }

    function test_previewFee_succeeds_whenGracePeriodJustElapsed() public {
        _initPoolAtOraclePrice();
        sequencerFeed.setRound(0, block.timestamp - hook.SEQUENCER_GRACE_PERIOD() - 1, block.timestamp);
        (uint24 fee,) = hook.previewFee(poolId);
        assertEq(fee, hook.LOW_FEE());
    }

    function test_reverts_ifGracePeriodExactlyAtBoundary() public {
        _initPoolAtOraclePrice();
        sequencerFeed.setRound(0, block.timestamp - hook.SEQUENCER_GRACE_PERIOD(), block.timestamp);
        vm.expectRevert(DynamicLPFeesHook.GracePeriodNotOver.selector);
        hook.previewFee(poolId);
    }

    // --- oracle checks ---

    function test_reverts_ifOracleIsStale() public {
        _initPoolAtOraclePrice();
        priceFeed.setRound(int256(ORACLE_ETH_USD), block.timestamp - 5000, block.timestamp - 5000);
        vm.expectRevert(DynamicLPFeesHook.StaleOraclePrice.selector);
        hook.previewFee(poolId);
    }

    function test_previewFee_succeeds_whenOracleAtStalenessBoundary() public {
        _initPoolAtOraclePrice();
        priceFeed.setRound(
            int256(ORACLE_ETH_USD),
            block.timestamp - 5000,
            block.timestamp - hook.MAX_ORACLE_STALENESS()
        );
        (uint24 fee,) = hook.previewFee(poolId);
        assertEq(fee, hook.LOW_FEE());
    }

    function test_reverts_ifOracleJustPastStalenessBoundary() public {
        _initPoolAtOraclePrice();
        priceFeed.setRound(
            int256(ORACLE_ETH_USD),
            block.timestamp - 5000,
            block.timestamp - hook.MAX_ORACLE_STALENESS() - 1
        );
        vm.expectRevert(DynamicLPFeesHook.StaleOraclePrice.selector);
        hook.previewFee(poolId);
    }

    function test_reverts_ifOracleAnswerIsZero() public {
        _initPoolAtOraclePrice();
        priceFeed.setRound(0, block.timestamp - 5000, block.timestamp);
        vm.expectRevert(DynamicLPFeesHook.CurrentOraclePriceNotSet.selector);
        hook.previewFee(poolId);
    }

    function test_reverts_ifOracleAnswerIsNegative() public {
        _initPoolAtOraclePrice();
        priceFeed.setRound(-1, block.timestamp - 5000, block.timestamp);
        vm.expectRevert(DynamicLPFeesHook.CurrentOraclePriceNotSet.selector);
        hook.previewFee(poolId);
    }

    function test_reverts_ifOracleRoundIsIncomplete() public {
        _initPoolAtOraclePrice();
        priceFeed.setRoundData(int256(ORACLE_ETH_USD), block.timestamp - 5000, block.timestamp, 1);
        vm.expectRevert(DynamicLPFeesHook.IncompleteOracleRound.selector);
        hook.previewFee(poolId);
    }

    // --- swap integration ---

    function test_swap_emitsFeeAdjusted_lowTier() public {
        _initPoolAtOraclePrice();
        _addLiquidity();
        int256 amount = -0.001 ether;
        (uint24 expectedFee, uint256 expectedBps) = hook.previewFee(poolId, amount);
        vm.expectEmit(true, false, false, true, address(hook));
        emit DynamicLPFeesHook.FeeAdjusted(poolId, expectedFee, expectedBps);
        _swap(true, amount);
    }

    function test_swap_emitsFeeAdjusted_mediumTier() public {
        _initPoolAtDeviationBps(300);
        _addLiquidity();
        int256 amount = -0.001 ether;
        (uint24 expectedFee, uint256 expectedBps) = hook.previewFee(poolId, amount);
        vm.expectEmit(true, false, false, true, address(hook));
        emit DynamicLPFeesHook.FeeAdjusted(poolId, expectedFee, expectedBps);
        _swap(true, amount);
    }

    function test_swap_emitsFeeAdjusted_highTier() public {
        _initPoolAtDeviationBps(1000);
        _addLiquidity();
        int256 amount = -0.001 ether;
        (uint24 expectedFee, uint256 expectedBps) = hook.previewFee(poolId, amount);
        vm.expectEmit(true, false, false, true, address(hook));
        emit DynamicLPFeesHook.FeeAdjusted(poolId, expectedFee, expectedBps);
        _swap(true, amount);
    }

    function test_swap_emitsFeeAdjusted_oneForZero() public {
        _initPoolAtOraclePrice();
        _addLiquidity();
        int256 amount = -1000e6;
        (uint24 expectedFee, uint256 expectedBps) = hook.previewFee(poolId, amount);
        vm.expectEmit(true, false, false, true, address(hook));
        emit DynamicLPFeesHook.FeeAdjusted(poolId, expectedFee, expectedBps);
        _swap(false, amount);
    }

    function test_previewFee_swapAware_sizeRatioRaisesFee() public {
        _initPoolAtOraclePrice();
        _addLiquidity();

        uint128 liquidity = manager.getLiquidity(poolId);
        int256 largeSwap = -int256(uint256(liquidity) / 50);

        (uint24 gaugeFee,) = hook.previewFee(poolId);
        (uint24 swapFee, uint256 swapBps) = hook.previewFee(poolId, largeSwap);

        assertEq(gaugeFee, hook.LOW_FEE());
        assertGe(swapBps, hook.SCORE_LOW());
        assertEq(swapFee, hook.MEDIUM_FEE());
    }

    function test_swap_previewFeeMatchesEmittedFee() public {
        _initPoolAtDeviationBps(750);
        _addLiquidity();
        int256 amount = -0.001 ether;
        (uint24 previewFee, uint256 previewBps) = hook.previewFee(poolId, amount);
        vm.recordLogs();
        _swap(true, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeAdjustedTopic = keccak256("FeeAdjusted(bytes32,uint24,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != feeAdjustedTopic) continue;
            (uint24 emittedFee, uint256 emittedBps) = abi.decode(logs[i].data, (uint24, uint256));
            assertEq(emittedFee, previewFee);
            assertEq(emittedBps, previewBps);
            found = true;
        }
        assertTrue(found, "FeeAdjusted not emitted");
    }

    function test_swap_reverts_whenSequencerDown() public {
        _initPoolAtOraclePrice();
        _addLiquidity();
        sequencerFeed.setRound(1, block.timestamp - 5000, block.timestamp);
        _expectSwapRevert(DynamicLPFeesHook.SequencerDown.selector);
        _swap(true, -0.001 ether);
    }

    function test_swap_reverts_whenGracePeriodNotOver() public {
        _initPoolAtOraclePrice();
        _addLiquidity();
        sequencerFeed.setRound(0, block.timestamp - 1000, block.timestamp);
        _expectSwapRevert(DynamicLPFeesHook.GracePeriodNotOver.selector);
        _swap(true, -0.001 ether);
    }

    function test_swap_reverts_whenOracleStale() public {
        _initPoolAtOraclePrice();
        _addLiquidity();
        priceFeed.setRound(int256(ORACLE_ETH_USD), block.timestamp - 5000, block.timestamp - 5000);
        _expectSwapRevert(DynamicLPFeesHook.StaleOraclePrice.selector);
        _swap(true, -0.001 ether);
    }

    function test_swap_reverts_whenOracleIncomplete() public {
        _initPoolAtOraclePrice();
        _addLiquidity();
        priceFeed.setRoundData(int256(ORACLE_ETH_USD), block.timestamp - 5000, block.timestamp, 1);
        _expectSwapRevert(DynamicLPFeesHook.IncompleteOracleRound.selector);
        _swap(true, -0.001 ether);
    }

    function test_swap_reverts_whenOracleAnswerIsZero() public {
        _initPoolAtOraclePrice();
        _addLiquidity();
        priceFeed.setRound(0, block.timestamp - 5000, block.timestamp);
        _expectSwapRevert(DynamicLPFeesHook.CurrentOraclePriceNotSet.selector);
        _swap(true, -0.001 ether);
    }

    function test_swap_reverts_whenOracleAnswerIsNegative() public {
        _initPoolAtOraclePrice();
        _addLiquidity();
        priceFeed.setRound(-100, block.timestamp - 5000, block.timestamp);
        _expectSwapRevert(DynamicLPFeesHook.CurrentOraclePriceNotSet.selector);
        _swap(true, -0.001 ether);
    }

    function test_previewFee_reflectsOracleUpdate_whilePoolPriceIsFixed() public {
        _initPoolAtOraclePrice();
        (uint24 feeBefore,) = hook.previewFee(poolId);
        assertEq(feeBefore, hook.LOW_FEE());

        _setOraclePrice(_priceWithDeltaBps(ORACLE_ETH_USD, 800));
        (uint24 feeAfter, uint256 bps) = hook.previewFee(poolId);
        assertGt(bps, hook.SCORE_MEDIUM());
        assertEq(feeAfter, hook.HIGH_FEE());
        assertEq(feeAfter, _expectedFeeForBps(bps));
    }

    function test_initialize_reverts_ifCalledTwice() public {
        _initPoolAtOraclePrice();
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        manager.initialize(key, encodeSqrtPriceX96(ORACLE_ETH_USD));
    }

    function test_reverts_ifUsdcAddressIsWrong() public {
        _setOraclePrice(ORACLE_ETH_USD);
        address wrongUsdc = 0x833589fcD6EdB6e08f4C7C32d4F71b54BdA02914;
        deployCodeTo(
            "solmate/src/test/utils/mocks/MockERC20.sol:MockERC20",
            abi.encode("FAKE", "FAKE", uint8(6)),
            wrongUsdc
        );

        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(wrongUsdc),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        _expectInitializeRevert(DynamicLPFeesHook.InvalidPoolPair.selector);
        manager.initialize(badKey, encodeSqrtPriceX96(ORACLE_ETH_USD));
    }

    function test_tierTable_allRepresentativeDeviations() public {
        uint256[8] memory deltas = [uint256(0), 50, 99, 150, 600, 1500, 2500, 8000];

        for (uint256 i = 0; i < deltas.length; i++) {
            _redeployEnvironment();
            _initPoolAtDeviationBps(int256(deltas[i]));
            (uint24 fee, uint256 bps) = hook.previewFee(poolId);
            assertEq(fee, _expectedFeeForBps(bps), "fee/bps mismatch");
        }
    }

    function test_tierLogic_expectedFees() public view {
        assertEq(_expectedFeeForBps(0), hook.LOW_FEE());
        assertEq(_expectedFeeForBps(99), hook.LOW_FEE());
        assertEq(_expectedFeeForBps(100), hook.MEDIUM_FEE());
        assertEq(_expectedFeeForBps(499), hook.MEDIUM_FEE());
        assertEq(_expectedFeeForBps(500), hook.HIGH_FEE());
        assertEq(_expectedFeeForBps(1999), hook.HIGH_FEE());
        assertEq(_expectedFeeForBps(2000), hook.VERY_HIGH_FEE());
        assertEq(_expectedFeeForBps(50_000), hook.VERY_HIGH_FEE());
    }

    function test_multipleSwaps_emitFeeEachTime() public {
        _initPoolAtOraclePrice();
        _addLiquidity();
        _swap(true, -0.0001 ether);
        _swap(true, -0.0001 ether);
        _swap(false, -50e6);
    }

    function test_swap_reverts_whenPriceHitsMinLimit_andPoolPriceRoundsToZero() public {
        _initPoolAtOraclePrice();
        _addLiquidity();
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -100 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap(key, params, defaultSettings, ZERO_BYTES);
        _expectSwapRevert(DynamicLPFeesHook.PoolPriceNotSet.selector);
        _swap(true, -0.001 ether);
    }

    // --- hook config / constants ---

    function test_immutableFeedAddresses() public view {
        assertEq(address(hook.priceFeed()), PRICE_FEED);
        assertEq(address(hook.sequencerUptimeFeed()), SEQUENCER_FEED);
    }

    function test_feeConstants() public view {
        assertEq(hook.MIN_FEE(), 3000);
        assertEq(hook.LOW_FEE(), 5000);
        assertEq(hook.MEDIUM_FEE(), 10000);
        assertEq(hook.HIGH_FEE(), 30000);
        assertEq(hook.VERY_HIGH_FEE(), 50000);
        assertEq(hook.MAX_FEE(), 100000);
    }

    function test_scoreThresholds() public view {
        assertEq(hook.SCORE_LOW(), 100);
        assertEq(hook.SCORE_MEDIUM(), 500);
        assertEq(hook.SCORE_HIGH(), 2000);
    }

    function test_safetyThresholds() public view {
        assertEq(hook.SEQUENCER_GRACE_PERIOD(), 3600);
        assertEq(hook.MAX_ORACLE_STALENESS(), 3600);
    }

    function test_hookPermissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertFalse(p.afterInitialize);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    // --- fuzz ---

    function testFuzz_feeTierMatchesDeviation(uint256 deltaBps) public {
        deltaBps = bound(deltaBps, 0, 10_000);
        _initPoolAtDeviationBps(int256(deltaBps));
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, _expectedFeeForBps(bps));
    }

    function testFuzz_feeTierMatchesNegativeDeviation(uint256 deltaBps) public {
        deltaBps = bound(deltaBps, 0, 9000);
        _initPoolAtDeviationBps(-int256(deltaBps));
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, _expectedFeeForBps(bps));
    }

    function testFuzz_gracePeriodBoundary(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 10_000);
        _initPoolAtOraclePrice();
        sequencerFeed.setRound(0, block.timestamp - elapsed, block.timestamp);

        if (elapsed <= hook.SEQUENCER_GRACE_PERIOD()) {
            vm.expectRevert(DynamicLPFeesHook.GracePeriodNotOver.selector);
            hook.previewFee(poolId);
        } else {
            (uint24 fee,) = hook.previewFee(poolId);
            assertEq(fee, hook.LOW_FEE());
        }
    }

    function testFuzz_stalenessBoundary(uint256 age) public {
        age = bound(age, 0, 10_000);
        _initPoolAtOraclePrice();
        priceFeed.setRound(int256(ORACLE_ETH_USD), block.timestamp - 5000, block.timestamp - age);

        if (age > hook.MAX_ORACLE_STALENESS()) {
            vm.expectRevert(DynamicLPFeesHook.StaleOraclePrice.selector);
            hook.previewFee(poolId);
        } else {
            (uint24 fee,) = hook.previewFee(poolId);
            assertEq(fee, hook.LOW_FEE());
        }
    }

    function testFuzz_previewFee_neverRevertsWithHealthyFeeds(uint256 deltaBps, uint256 oraclePrice8) public {
        deltaBps = bound(deltaBps, 0, 5000);
        oraclePrice8 = bound(oraclePrice8, 100e8, 100_000e8);
        _setOraclePrice(oraclePrice8);
        _initPool(encodeSqrtPriceX96(_priceWithDeltaBps(oraclePrice8, int256(deltaBps))));
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertGe(fee, hook.MIN_FEE());
        assertLe(fee, hook.MAX_FEE());
        assertApproxEqAbs(bps, deltaBps, 10);
        assertEq(fee, _expectedFeeForBps(bps));
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
        deployCodeTo(
            "DynamicLPFeesHook.sol",
            abi.encode(manager, WETH, USDC, PRICE_FEED, SEQUENCER_FEED),
            hookAddress
        );
        hook = DynamicLPFeesHook(hookAddress);
    }

    function _redeployEnvironment() internal {
        deployFreshManagerAndRouters();
        _deployMockFeeds();
        _deployWethUsdc();
        _deployHook();
    }

    function _initPoolAtOraclePrice() internal {
        _setOraclePrice(ORACLE_ETH_USD);
        _initPool(encodeSqrtPriceX96(ORACLE_ETH_USD));
    }

    function _initPoolAtDeviationBps(int256 deltaBps) internal {
        _setOraclePrice(ORACLE_ETH_USD);
        uint256 poolPrice8 = _priceWithDeltaBps(ORACLE_ETH_USD, deltaBps);
        _initPool(encodeSqrtPriceX96(poolPrice8));
    }

    function _initPool(uint160 sqrtPriceX96) internal {
        (key, poolId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, sqrtPriceX96);
    }

    function _addLiquidity() internal {
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(poolId);
        int24 spacing = key.tickSpacing;
        int24 lower = ((tick - 120) / spacing) * spacing;
        int24 upper = ((tick + 120) / spacing) * spacing;

        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            1 ether,
            3500e6
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int128(liquidityDelta),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(key, params, defaultSettings, ZERO_BYTES);
    }

    function _priceWithDeltaBps(uint256 basePrice8, int256 deltaBps) internal pure returns (uint256) {
        if (deltaBps >= 0) {
            return basePrice8 * uint256(10_000 + deltaBps) / 10_000;
        }
        return basePrice8 * uint256(10_000 - uint256(-deltaBps)) / 10_000;
    }

    function _expectedFeeForBps(uint256 bps) internal view returns (uint24) {
        uint24 fee;
        if (bps < hook.SCORE_LOW()) fee = hook.LOW_FEE();
        else if (bps < hook.SCORE_MEDIUM()) fee = hook.MEDIUM_FEE();
        else if (bps < hook.SCORE_HIGH()) fee = hook.HIGH_FEE();
        else fee = hook.VERY_HIGH_FEE();
        if (fee < hook.MIN_FEE()) fee = hook.MIN_FEE();
        if (fee > hook.MAX_FEE()) fee = hook.MAX_FEE();
        return fee;
    }

    function _expectInitializeRevert(bytes4 hookError) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(hookError),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _expectSwapRevert(bytes4 hookError) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(hookError),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function encodeSqrtPriceX96(uint256 ethUsd8) internal pure returns (uint160) {
        return _encodeSqrtPriceX96Static(ethUsd8);
    }

    function _encodeSqrtPriceX96Static(uint256 ethUsd8) internal pure returns (uint160) {
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
