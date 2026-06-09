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
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {DynamicLPFeesHook} from "../src/LPFees/DynamicLPFeesHook.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";

// Dedicated fuzz suite for DynamicLPFeesHook.
// Run heavy:  FOUNDRY_PROFILE=fuzz forge test --match-contract DynamicLPFeesHookFuzz
contract DynamicLPFeesHookFuzz is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant PRICE_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // Oracle price bounds (Chainlink 1e8 scale). Low bound kept high enough that
    // pool-price reconstruction from sqrtPriceX96 never rounds to zero.
    uint256 internal constant MIN_ORACLE = 100e8; // $100
    uint256 internal constant MAX_ORACLE = 200_000e8; // $200k

    // Reference timestamp set in setUp via vm.warp; gives headroom for subtractions.
    uint256 internal constant NOW = 1_000_000;

    DynamicLPFeesHook hook;
    MockChainlinkAggregator priceFeed;
    MockChainlinkAggregator sequencerFeed;
    PoolId poolId;

    PoolSwapTest.TestSettings internal defaultSettings =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public {
        vm.warp(NOW);
        deployFreshManagerAndRouters();
        _deployMockFeeds();
        _deployWethUsdc();
        _deployHook();
    }

    // ============================================================
    // 1. Fee tier logic — full deviation space, both directions
    // ============================================================

    function testFuzz_feeMatchesDeviation_poolAboveOracle(uint256 oraclePrice8, uint256 deltaBps) public {
        oraclePrice8 = bound(oraclePrice8, MIN_ORACLE, MAX_ORACLE);
        deltaBps = bound(deltaBps, 0, 50_000);
        _setOraclePrice(oraclePrice8);
        _initPool(encodeSqrtPriceX96(_priceWithDeltaBps(oraclePrice8, int256(deltaBps))));

        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        _assertFeeConsistent(fee, bps);
        _assertApproxDeviation(bps, deltaBps);
    }

    function testFuzz_feeMatchesDeviation_poolBelowOracle(uint256 oraclePrice8, uint256 deltaBps) public {
        oraclePrice8 = bound(oraclePrice8, MIN_ORACLE, MAX_ORACLE);
        // cap below 100% so pool price stays positive and non-zero
        deltaBps = bound(deltaBps, 0, 9000);
        _setOraclePrice(oraclePrice8);
        _initPool(encodeSqrtPriceX96(_priceWithDeltaBps(oraclePrice8, -int256(deltaBps))));

        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        _assertFeeConsistent(fee, bps);
        _assertApproxDeviation(bps, deltaBps);
    }

    // Oracle moves while pool price stays fixed (live re-quoting path).
    function testFuzz_feeReactsToOracleMove(uint256 newOraclePrice8) public {
        _setOraclePrice(ORACLE());
        _initPool(encodeSqrtPriceX96(ORACLE()));

        newOraclePrice8 = bound(newOraclePrice8, MIN_ORACLE, MAX_ORACLE);
        _setOraclePrice(newOraclePrice8);

        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        _assertFeeConsistent(fee, bps);
    }

    // ============================================================
    // 2. Fee output invariants — always clamped, always valid
    // ============================================================

    function testFuzz_feeAlwaysWithinClamp(uint256 oraclePrice8, int256 deltaBps) public {
        oraclePrice8 = bound(oraclePrice8, MIN_ORACLE, MAX_ORACLE);
        deltaBps = int256(bound(uint256(deltaBps), 0, 9000));
        // randomly flip sign using the low bit
        if (uint256(oraclePrice8) % 2 == 0) deltaBps = -deltaBps;

        _setOraclePrice(oraclePrice8);
        _initPool(encodeSqrtPriceX96(_priceWithDeltaBps(oraclePrice8, deltaBps)));

        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertGe(fee, hook.MIN_FEE());
        assertLe(fee, hook.MAX_FEE());
        assertTrue(
            fee == hook.LOW_FEE() || fee == hook.MEDIUM_FEE() || fee == hook.HIGH_FEE() || fee == hook.VERY_HIGH_FEE(),
            "fee not one of the tiers"
        );
        assertEq(fee, _expectedFeeForBps(bps));
    }

    // Monotonicity: larger deviation never yields a smaller fee.
    function testFuzz_feeMonotonicInDeviation(uint256 bpsA, uint256 bpsB) public {
        bpsA = bound(bpsA, 0, 50_000);
        bpsB = bound(bpsB, 0, 50_000);
        if (bpsA > bpsB) (bpsA, bpsB) = (bpsB, bpsA);

        _setOraclePrice(ORACLE());
        _initPool(encodeSqrtPriceX96(_priceWithDeltaBps(ORACLE(), int256(bpsA))));
        (uint24 feeA,) = hook.previewFee(poolId);

        _redeployEnvironment();
        _setOraclePrice(ORACLE());
        _initPool(encodeSqrtPriceX96(_priceWithDeltaBps(ORACLE(), int256(bpsB))));
        (uint24 feeB,) = hook.previewFee(poolId);

        assertGe(feeB, feeA, "fee must be monotonic in deviation");
    }

    // ============================================================
    // 3. Sequencer state machine
    // ============================================================

    function testFuzz_sequencer(uint256 answer, uint256 elapsed) public {
        _setOraclePrice(ORACLE());
        _initPool(encodeSqrtPriceX96(ORACLE()));

        elapsed = bound(elapsed, 0, NOW - 1);
        sequencerFeed.setRound(int256(answer), block.timestamp - elapsed, block.timestamp);

        if (answer != 0) {
            vm.expectRevert(DynamicLPFeesHook.SequencerDown.selector);
            hook.previewFee(poolId);
        } else if (elapsed <= hook.SEQUENCER_GRACE_PERIOD()) {
            vm.expectRevert(DynamicLPFeesHook.GracePeriodNotOver.selector);
            hook.previewFee(poolId);
        } else {
            (uint24 fee,) = hook.previewFee(poolId);
            assertEq(fee, hook.LOW_FEE());
        }
    }

    // ============================================================
    // 4. Oracle validation state machine
    // ============================================================

    function testFuzz_oracleValidation(int256 answer, uint256 age, bool incomplete) public {
        _setOraclePrice(ORACLE());
        _initPool(encodeSqrtPriceX96(ORACLE()));

        age = bound(age, 0, NOW - 1);
        // keep answer in a sane int range
        answer = bound(answer, -1e18, int256(MAX_ORACLE));

        uint80 override_ = incomplete ? uint80(1) : uint80(0);
        priceFeed.setRoundData(answer, block.timestamp - 5000, block.timestamp - age, override_);

        if (answer <= 0) {
            vm.expectRevert(DynamicLPFeesHook.CurrentOraclePriceNotSet.selector);
            hook.previewFee(poolId);
        } else if (incomplete) {
            vm.expectRevert(DynamicLPFeesHook.IncompleteOracleRound.selector);
            hook.previewFee(poolId);
        } else if (age > hook.MAX_ORACLE_STALENESS()) {
            vm.expectRevert(DynamicLPFeesHook.StaleOraclePrice.selector);
            hook.previewFee(poolId);
        } else {
            (uint24 fee,) = hook.previewFee(poolId);
            assertGe(fee, hook.MIN_FEE());
        }
    }

    // ============================================================
    // 5. Full combined state machine (the "everything" fuzz)
    // ============================================================

    function testFuzz_fullStateMachine(
        uint256 oraclePrice8,
        int256 deltaBps,
        uint256 seqAnswer,
        uint256 seqElapsed,
        int256 oracleAnswer,
        uint256 oracleAge,
        bool oracleIncomplete
    ) public {
        oraclePrice8 = bound(oraclePrice8, MIN_ORACLE, MAX_ORACLE);
        deltaBps = int256(bound(uint256(deltaBps), 0, 9000));
        if (seqAnswer % 2 == 0) deltaBps = -deltaBps;

        // init pool first with a healthy oracle so initialize doesn't depend on fuzz state
        _setOraclePrice(oraclePrice8);
        _initPool(encodeSqrtPriceX96(_priceWithDeltaBps(oraclePrice8, deltaBps)));

        // now configure both feeds to arbitrary states
        seqElapsed = bound(seqElapsed, 0, NOW - 1);
        oracleAge = bound(oracleAge, 0, NOW - 1);
        oracleAnswer = bound(oracleAnswer, -1e18, int256(MAX_ORACLE));

        sequencerFeed.setRound(int256(seqAnswer), block.timestamp - seqElapsed, block.timestamp);
        uint80 override_ = oracleIncomplete ? uint80(1) : uint80(0);
        priceFeed.setRoundData(oracleAnswer, block.timestamp - 5000, block.timestamp - oracleAge, override_);

        bytes4 expectedError = _expectedError(seqAnswer, seqElapsed, oracleAnswer, oracleAge, oracleIncomplete);

        if (expectedError != bytes4(0)) {
            vm.expectRevert(expectedError);
            hook.previewFee(poolId);
        } else {
            (uint24 fee, uint256 bps) = hook.previewFee(poolId);
            _assertFeeConsistent(fee, bps);
        }
    }

    // ============================================================
    // 6. Swap-path fuzzing
    // ============================================================

    function testFuzz_swapEmitsPreviewFee(uint256 deltaBps, uint256 swapAmount) public {
        deltaBps = bound(deltaBps, 0, 1500);
        swapAmount = bound(swapAmount, 1e12, 0.05 ether);

        _setOraclePrice(ORACLE());
        _initPool(encodeSqrtPriceX96(_priceWithDeltaBps(ORACLE(), int256(deltaBps))));
        _addLiquidity();

        int256 amount = -int256(swapAmount);
        (uint24 previewFee, uint256 previewBps) = hook.previewFee(poolId, amount);

        vm.recordLogs();
        _swap(true, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256("FeeAdjusted(bytes32,uint24,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != topic) continue;
            (uint24 emittedFee, uint256 emittedBps) = abi.decode(logs[i].data, (uint24, uint256));
            assertEq(emittedFee, previewFee, "emitted fee != preview");
            assertEq(emittedBps, previewBps, "emitted bps != preview");
            found = true;
        }
        assertTrue(found, "FeeAdjusted not emitted");
    }

    function testFuzz_swapRevertsWhenSequencerDown(uint256 swapAmount, uint256 seqAnswer) public {
        seqAnswer = bound(seqAnswer, 1, type(uint8).max);
        swapAmount = bound(swapAmount, 1e12, 0.05 ether);

        _setOraclePrice(ORACLE());
        _initPool(encodeSqrtPriceX96(ORACLE()));
        _addLiquidity();

        sequencerFeed.setRound(int256(seqAnswer), block.timestamp - 5000, block.timestamp);
        _expectSwapRevert(DynamicLPFeesHook.SequencerDown.selector);
        _swap(true, -int256(swapAmount));
    }

    function testFuzz_swapRevertsWhenOracleStale(uint256 swapAmount, uint256 age) public {
        age = bound(age, hook.MAX_ORACLE_STALENESS() + 1, NOW - 1);
        swapAmount = bound(swapAmount, 1e12, 0.05 ether);

        _setOraclePrice(ORACLE());
        _initPool(encodeSqrtPriceX96(ORACLE()));
        _addLiquidity();

        priceFeed.setRound(int256(ORACLE()), block.timestamp - 5000, block.timestamp - age);
        _expectSwapRevert(DynamicLPFeesHook.StaleOraclePrice.selector);
        _swap(true, -int256(swapAmount));
    }

    // ============================================================
    // 7. Pool price encode/decode round-trip
    // ============================================================

    function testFuzz_encodeDecodeRoundTrip(uint256 price8) public pure {
        price8 = bound(price8, MIN_ORACLE, MAX_ORACLE);
        uint160 sqrtPrice = _encodeSqrtPriceX96Static(price8);
        uint256 ratioX192 = FullMath.mulDiv(uint256(sqrtPrice), uint256(sqrtPrice), 1);
        uint256 decoded = FullMath.mulDiv(ratioX192, 1e20, 1 << 192);
        // relative drift must be tiny (<= 1 bps)
        uint256 diff = decoded > price8 ? decoded - price8 : price8 - decoded;
        assertLe(diff * 10_000 / price8, 1, "round-trip drift > 1 bps");
    }

    // ============================================================
    // 8. Initialization validation fuzz
    // ============================================================

    function testFuzz_initializeRevertsForNonDynamicFee(uint24 staticFee) public {
        staticFee = uint24(bound(staticFee, 0, 999_999));
        vm.assume(!LPFeeLibrary.isDynamicFee(staticFee));

        _setOraclePrice(ORACLE());
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: staticFee,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        _expectInitializeRevert(DynamicLPFeesHook.MustUseDynamicFees.selector);
        manager.initialize(badKey, encodeSqrtPriceX96(ORACLE()));
    }

    function testFuzz_initializeRevertsForWrongCurrency1(address wrong) public {
        vm.assume(wrong != USDC);
        vm.assume(wrong > WETH); // keep currency order valid
        vm.assume(wrong.code.length == 0);
        vm.assume(uint160(wrong) > 0x10000); // avoid precompiles

        _setOraclePrice(ORACLE());
        deployCodeTo("solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("X", "X", uint8(18)), wrong);

        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(wrong),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        _expectInitializeRevert(DynamicLPFeesHook.InvalidPoolPair.selector);
        manager.initialize(badKey, encodeSqrtPriceX96(ORACLE()));
    }

    // ============================================================
    // Expected-outcome helpers
    // ============================================================

    function _expectedError(
        uint256 seqAnswer,
        uint256 seqElapsed,
        int256 oracleAnswer,
        uint256 oracleAge,
        bool oracleIncomplete
    ) internal view returns (bytes4) {
        // mirrors getFee ordering: sequencer first, then oracle
        if (seqAnswer != 0) return DynamicLPFeesHook.SequencerDown.selector;
        if (seqElapsed <= hook.SEQUENCER_GRACE_PERIOD()) return DynamicLPFeesHook.GracePeriodNotOver.selector;
        if (oracleAnswer <= 0) return DynamicLPFeesHook.CurrentOraclePriceNotSet.selector;
        if (oracleIncomplete) return DynamicLPFeesHook.IncompleteOracleRound.selector;
        if (oracleAge > hook.MAX_ORACLE_STALENESS()) return DynamicLPFeesHook.StaleOraclePrice.selector;
        return bytes4(0);
    }

    function _assertFeeConsistent(uint24 fee, uint256 bps) internal view {
        assertGe(fee, hook.MIN_FEE());
        assertLe(fee, hook.MAX_FEE());
        assertEq(fee, _expectedFeeForBps(bps));
    }

    function _assertApproxDeviation(uint256 bps, uint256 deltaBps) internal pure {
        // allow drift from integer sqrt + decimal rounding; scales slightly with size
        uint256 tolerance = 5 + deltaBps / 1000;
        assertApproxEqAbs(bps, deltaBps, tolerance);
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

    // ============================================================
    // Environment helpers
    // ============================================================

    function ORACLE() internal pure returns (uint256) {
        return 3500e8;
    }

    function _deployMockFeeds() internal {
        deployCodeTo("MockChainlinkAggregator.sol", PRICE_FEED);
        deployCodeTo("MockChainlinkAggregator.sol", SEQUENCER_FEED);
        priceFeed = MockChainlinkAggregator(PRICE_FEED);
        sequencerFeed = MockChainlinkAggregator(SEQUENCER_FEED);
        _setOraclePrice(ORACLE());
        _setSequencerUp();
    }

    function _setOraclePrice(uint256 oraclePrice8) internal {
        priceFeed.setRound(int256(oraclePrice8), block.timestamp - 5000, block.timestamp);
    }

    function _setSequencerUp() internal {
        sequencerFeed.setRound(0, block.timestamp - 5000, block.timestamp);
    }

    function _deployWethUsdc() internal {
        deployCodeTo("solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("WETH", "WETH", uint8(18)), WETH);
        deployCodeTo("solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("USDC", "USDC", uint8(6)), USDC);

        MockERC20(WETH).mint(address(this), 1_000_000 ether);
        MockERC20(USDC).mint(address(this), 1_000_000_000e6);

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

    function _redeployEnvironment() internal {
        deployFreshManagerAndRouters();
        _deployMockFeeds();
        _deployWethUsdc();
        _deployHook();
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
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), 1 ether, 3500e6
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
        if (deltaBps >= 0) return basePrice8 * uint256(10_000 + deltaBps) / 10_000;
        return basePrice8 * (10_000 - uint256(-deltaBps)) / 10_000;
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
