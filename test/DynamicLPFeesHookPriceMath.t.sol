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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {DynamicLPFeesHookHarness} from "./DynamicLPFeesHookHarness.sol";
import {DynamicLPFeesHook} from "../src/LPFees/DynamicLPFeesHook.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";

/// @notice Direct unit tests for _getPoolPriceFromSqrtPriceX96, _priceDeviationBps, and fee economics.
contract DynamicLPFeesHookPriceMath is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant WETH_MAIN = 0x4200000000000000000000000000000000000006;
    address internal constant USDC_MAIN = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH_SEP = 0x4200000000000000000000000000000000000006;
    address internal constant USDC_SEP = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant PRICE_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    uint256 internal constant ORACLE = 3500e8;

    DynamicLPFeesHookHarness hook;
    MockChainlinkAggregator priceFeed;
    MockChainlinkAggregator sequencerFeed;
    PoolId poolId;

    PoolSwapTest.TestSettings internal settings =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public {
        vm.warp(1_000_000);
        deployFreshManagerAndRouters();
        _deployMockFeeds();
        _deployPair(WETH_MAIN, USDC_MAIN);
        _deployHook(WETH_MAIN, USDC_MAIN);
    }

    // --- _getPoolPriceFromSqrtPriceX96 ---

    function test_poolPrice_knownSpots() public view {
        assertApproxEqAbs(hook.exposePoolPriceFromSqrt(_sqrtFor(1682e8)), 1682e8, 2);
        assertApproxEqAbs(hook.exposePoolPriceFromSqrt(_sqrtFor(3500e8)), 3500e8, 2);
        assertApproxEqAbs(hook.exposePoolPriceFromSqrt(_sqrtFor(10_000e8)), 10_000e8, 3);
    }

    function testFuzz_poolPrice_matchesReference(uint256 s) public view {
        s = bound(s, TickMath.MIN_SQRT_PRICE + 1, TickMath.MAX_SQRT_PRICE - 1);
        assertEq(hook.exposePoolPriceFromSqrt(uint160(s)), _refPoolPrice8(s));
    }

    function testFuzz_poolPrice_monotonicInSqrt(uint256 s1, uint256 s2) public view {
        s1 = bound(s1, TickMath.MIN_SQRT_PRICE + 1, TickMath.MAX_SQRT_PRICE - 1);
        s2 = bound(s2, TickMath.MIN_SQRT_PRICE + 1, TickMath.MAX_SQRT_PRICE - 1);
        vm.assume(s1 < s2);
        vm.assume(_refPoolPrice8(s1) > 0 && _refPoolPrice8(s2) > 0);

        uint256 p1 = hook.exposePoolPriceFromSqrt(uint160(s1));
        uint256 p2 = hook.exposePoolPriceFromSqrt(uint160(s2));
        assertGt(p2, p1, "WETH token0: higher sqrt => higher USD price");
    }

    function test_poolPrice_tickRoundTrip() public view {
        int24[7] memory ticks = [int24(-200000), int24(-100000), int24(-1000), int24(0), int24(1000), int24(100000), int24(200000)];
        for (uint256 i = 0; i < ticks.length; i++) {
            uint160 sqrtP = TickMath.getSqrtPriceAtTick(ticks[i]);
            uint256 pool8 = hook.exposePoolPriceFromSqrt(sqrtP);
            assertGt(pool8, 0, "tick price must be positive");
            assertEq(pool8, _refPoolPrice8(sqrtP));
        }
    }

    function test_deviation_revertsWhenPoolNotInitialized() public {
        PoolId emptyId = PoolId.wrap(bytes32(uint256(1)));
        vm.expectRevert(DynamicLPFeesHook.PoolPriceNotSet.selector);
        hook.exposePriceDeviationBps(emptyId);
    }

    function test_poolPrice_zeroAtMinSqrt() public view {
        assertEq(hook.exposePoolPriceFromSqrt(TickMath.MIN_SQRT_PRICE), 0);
    }

    function test_sepoliaOrder_poolPrice_invertsFormula() public {
        _redeploySepolia();
        assertFalse(hook.exposeWethIsCurrency0());

        uint256 target = 3500e8;
        uint160 sqrtP = _sqrtForSepolia(target);
        assertApproxEqAbs(hook.exposePoolPriceFromSqrt(sqrtP), target, 2);
    }

    function testFuzz_sepoliaOrder_poolPriceReference(uint256 s) public {
        _redeploySepolia();
        s = bound(s, TickMath.MIN_SQRT_PRICE + 1, TickMath.MAX_SQRT_PRICE - 1);
        uint256 step = FullMath.mulDiv(s, s, 1 << 96);
        vm.assume(step > 0);
        assertEq(hook.exposePoolPriceFromSqrt(uint160(s)), _refPoolPrice8Sepolia(s));
    }

    // --- _priceDeviationBps ---

    function test_deviation_zeroAtOracleParity() public {
        _initAtOracle();
        assertEq(hook.exposePriceDeviationBps(poolId), 0);
        (uint24 fee,) = hook.previewFee(poolId);
        assertEq(fee, hook.LOW_FEE());
    }

    function test_deviation_exactFormula_atKnownDeltas() public {
        int256[6] memory deltas = [int256(50), int256(100), int256(499), int256(500), int256(1999), int256(2000)];
        for (uint256 i = 0; i < deltas.length; i++) {
            _redeployMainnet();
            _initPoolAtDeltaBps(deltas[i], ORACLE);
            uint256 bps = hook.exposePriceDeviationBps(poolId);
            assertApproxEqAbs(bps, uint256(deltas[i] >= 0 ? deltas[i] : -deltas[i]), 2);
        }
    }

    function testFuzz_deviation_matchesIntegerFormula(uint256 oracle8, int256 deltaBps) public {
        oracle8 = bound(oracle8, 500e8, 50_000e8);
        deltaBps = bound(deltaBps, -9000, 9000);

        _redeployMainnet();
        _initPoolAtDeltaBps(deltaBps, oracle8);

        uint256 pool8 = hook.exposePoolPriceFromSqrt(_slot0Sqrt());
        uint256 expected = _deviationBps(pool8, oracle8);
        assertEq(hook.exposePriceDeviationBps(poolId), expected);
    }

    function test_deviation_previewFeeUsesSameScore() public {
        _initPoolAtDeltaBps(750, ORACLE);
        uint256 dev = hook.exposePriceDeviationBps(poolId);
        (, uint256 previewBps) = hook.previewFee(poolId);
        assertEq(previewBps, dev);
    }

    // --- fee economics (deviation -> tier) ---

    function test_economics_tierBoundaries() public {
        _assertTierAtDelta(0, hook.LOW_FEE());
        _assertTierAtDelta(99, hook.LOW_FEE());
        _assertTierAtDelta(150, hook.MEDIUM_FEE()); // margin for sqrt round-trip
        _assertTierAtDelta(550, hook.HIGH_FEE());
        _assertTierAtDelta(2100, hook.VERY_HIGH_FEE());
    }

    function testFuzz_economics_feeMonotonicInDeviation(int256 deltaA, int256 deltaB) public {
        deltaA = bound(deltaA, -5000, 5000);
        deltaB = bound(deltaB, -5000, 5000);
        vm.assume(_abs(deltaA) < _abs(deltaB));

        _redeployMainnet();
        _initPoolAtDeltaBps(deltaA, ORACLE);
        (uint24 feeA,) = hook.previewFee(poolId);

        _redeployMainnet();
        _initPoolAtDeltaBps(deltaB, ORACLE);
        (uint24 feeB,) = hook.previewFee(poolId);

        assertLe(feeA, feeB, "larger |deviation| must not reduce fee");
    }

    function test_economics_111Usdc_mediumWhenPool1PctOff() public {
        _initPoolAtDeltaBps(150, ORACLE);
        _seed();

        (uint24 fee,) = hook.previewFee(poolId, false, -111e6);
        assertEq(fee, hook.MEDIUM_FEE());
        assertGe(hook.exposePriceDeviationBps(poolId), hook.SCORE_LOW());
    }

    function test_economics_swapEmitsSameDeviationScore() public {
        _initPoolAtDeltaBps(300, ORACLE);
        _seed();

        uint256 dev = hook.exposePriceDeviationBps(poolId);
        (uint24 previewFee, uint256 previewBps) = hook.previewFee(poolId, true, -0.1 ether);
        assertEq(previewBps, dev);

        vm.recordLogs();
        _swap(true, -0.1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("FeeAdjusted(bytes32,uint24,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != topic) continue;
            (uint24 emittedFee, uint256 emittedBps) = abi.decode(logs[i].data, (uint24, uint256));
            assertEq(emittedFee, previewFee);
            assertEq(emittedBps, dev);
            found = true;
        }
        assertTrue(found);
    }

    // --- helpers ---

    function _refPoolPrice8(uint256 s) internal pure returns (uint256) {
        uint256 step = FullMath.mulDiv(s, s, 1 << 96);
        return FullMath.mulDiv(step, 1e20, 1 << 96);
    }

    function _refPoolPrice8Sepolia(uint256 s) internal pure returns (uint256) {
        uint256 step = FullMath.mulDiv(s, s, 1 << 96);
        return FullMath.mulDiv(1e20, 1 << 96, step);
    }

    function _deviationBps(uint256 pool8, uint256 oracle8) internal pure returns (uint256) {
        uint256 diff = pool8 > oracle8 ? pool8 - oracle8 : oracle8 - pool8;
        return diff * 10_000 / oracle8;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function _assertTierAtDelta(int256 deltaBps, uint24 expectedFee) internal {
        _redeployMainnet();
        _initPoolAtDeltaBps(deltaBps, ORACLE);
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, expectedFee);
        assertApproxEqAbs(bps, _abs(deltaBps), 10);
    }

    function _initAtOracle() internal {
        _initPoolAtDeltaBps(0, ORACLE);
    }

    function _initPoolAtDeltaBps(int256 deltaBps, uint256 oracle8) internal {
        _setOracle(oracle8);
        bool weth0 = Currency.unwrap(currency0) == WETH_MAIN;
        uint256 pool8 = _withBps(oracle8, deltaBps);
        uint160 sqrtP = weth0 ? _sqrtFor(pool8) : _sqrtForSepolia(pool8);
        manager.initialize(_key(), sqrtP);
        poolId = _key().toId();
    }

    function _slot0Sqrt() internal view returns (uint160) {
        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        return sqrtP;
    }

    function _sqrtFor(uint256 ethUsd8) internal pure returns (uint160) {
        uint256 target = FullMath.mulDiv(ethUsd8, 1 << 192, 1e20);
        return uint160(_sqrt(target));
    }

    function _sqrtForSepolia(uint256 ethUsd8) internal pure returns (uint160) {
        uint256 target = FullMath.mulDiv(1e26, 1 << 192, ethUsd8 * 1e6);
        return uint160(_sqrt(target));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    function _withBps(uint256 base8, int256 bps) internal pure returns (uint256) {
        if (bps >= 0) return base8 * uint256(10_000 + bps) / 10_000;
        return base8 * (10_000 - uint256(-bps)) / 10_000;
    }

    function _seed() internal {
        (uint160 sqrtP, int24 tick,,) = manager.getSlot0(poolId);
        int24 lower = ((tick / 60) - 3) * 60;
        int24 upper = ((tick / 60) + 3) * 60;
        bool weth0 = Currency.unwrap(currency0) == WETH_MAIN;
        (uint256 a0, uint256 a1) = weth0 ? (uint256(50 ether), uint256(175_000e6)) : (uint256(175_000e6), uint256(50 ether));
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), a0, a1
        );
        modifyLiquidityRouter.modifyLiquidity(
            _key(),
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liq)), salt: bytes32(0)}),
            ""
        );
    }

    function _swap(bool zeroForOne, int256 amount) internal {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(_key(), params, settings, ZERO_BYTES);
    }

    function _key() internal view returns (PoolKey memory k) {
        k = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _redeployMainnet() internal {
        deployFreshManagerAndRouters();
        _deployMockFeeds();
        _deployPair(WETH_MAIN, USDC_MAIN);
        _deployHook(WETH_MAIN, USDC_MAIN);
    }

    function _redeploySepolia() internal {
        deployFreshManagerAndRouters();
        _deployMockFeeds();
        _deployPair(USDC_SEP, WETH_SEP);
        _deployHook(WETH_SEP, USDC_SEP);
    }

    function _deployMockFeeds() internal {
        deployCodeTo("MockChainlinkAggregator.sol", PRICE_FEED);
        deployCodeTo("MockChainlinkAggregator.sol", SEQUENCER_FEED);
        priceFeed = MockChainlinkAggregator(PRICE_FEED);
        sequencerFeed = MockChainlinkAggregator(SEQUENCER_FEED);
        _setOracle(ORACLE);
        sequencerFeed.setRound(0, block.timestamp - 5000, block.timestamp);
    }

    function _setOracle(uint256 oracle8) internal {
        priceFeed.setRound(int256(oracle8), block.timestamp - 1, block.timestamp);
    }

    function _deployPair(address token0Addr, address token1Addr) internal {
        bool token0IsWeth = token0Addr == WETH_MAIN || token0Addr == WETH_SEP;
        uint8 dec0 = token0IsWeth ? 18 : 6;
        uint8 dec1 = token0IsWeth ? 6 : 18;
        deployCodeTo(
            "solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("T0", "T0", dec0), token0Addr
        );
        deployCodeTo(
            "solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("T1", "T1", dec1), token1Addr
        );
        MockERC20(token0Addr).mint(address(this), 10_000 ether);
        MockERC20(token1Addr).mint(address(this), 10_000_000e6);

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
            MockERC20(token0Addr).approve(routers[i], type(uint256).max);
            MockERC20(token1Addr).approve(routers[i], type(uint256).max);
        }
        currency0 = Currency.wrap(token0Addr);
        currency1 = Currency.wrap(token1Addr);
    }

    function _deployHook(address weth, address usdc) internal {
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo(
            "DynamicLPFeesHookHarness.sol",
            abi.encode(manager, weth, usdc, PRICE_FEED, SEQUENCER_FEED),
            hookAddress
        );
        hook = DynamicLPFeesHookHarness(hookAddress);
    }
}
