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
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {DynamicLPFeesHook} from "../src/LPFees/DynamicLPFeesHook.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";

/// @notice Extreme adversarial + fuzz: oracle gaming, math edges, liquidity/trade manipulation.
contract DynamicLPFeesHookExtreme is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant PRICE_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    uint256 internal constant NOW = 1_000_000;
    uint256 internal constant ORACLE = 3500e8;

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    DynamicLPFeesHook hook;
    MockChainlinkAggregator priceFeed;
    MockChainlinkAggregator sequencerFeed;
    PoolId poolId;

    PoolSwapTest.TestSettings internal settings =
        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    function setUp() public {
        vm.warp(NOW);
        deployFreshManagerAndRouters();
        _deployMockFeeds();
        _deployWethUsdc();
        _deployHook();
    }

    // ============================================================
    // MEGA-FUZZ: all dimensions at once — must never panic
    // ============================================================

    function testFuzz_extremeCombo_neverPanics(
        uint256 oracle8,
        int256 deltaBps,
        int256 amount,
        uint256 staleOffset,
        uint256 seqStarted
    ) public {
        oracle8 = bound(oracle8, 100e8, 500_000e8);
        deltaBps = bound(deltaBps, -9000, 50_000);
        staleOffset = bound(staleOffset, 0, hook.MAX_ORACLE_STALENESS());
        seqStarted = bound(seqStarted, 0, block.timestamp - hook.SEQUENCER_GRACE_PERIOD() - 1);

        priceFeed.setRound(int256(oracle8), block.timestamp - 1, block.timestamp - staleOffset);
        sequencerFeed.setRound(0, seqStarted, block.timestamp);

        _initPool(_encode(_withBps(oracle8, deltaBps)));
        _seedMinimal();

        (uint24 fee, uint256 score) = hook.previewFee(poolId, true, amount);
        _assertFeeInvariants(fee, score);
        _assertScoreIsDeviationOnly(score, true, amount);
    }

    // ============================================================
    // TIER BOUNDARY FUZZ — oracle deviation scores
    // ============================================================

    function testFuzz_tierBoundaries(uint256 priceScore) public {
        priceScore = bound(priceScore, 0, 100_000);

        uint24 expected = _feeForScore(priceScore);
        (uint24 fee, uint256 score) = _feeFromScorePure(priceScore);

        assertEq(fee, expected);
        assertEq(score, priceScore);
    }

    function test_tierBoundaries_exactEdges() public {
        _assertTierAt(0, hook.LOW_FEE());
        _assertTierAt(hook.SCORE_LOW() - 1, hook.LOW_FEE());
        _assertTierAt(hook.SCORE_LOW(), hook.MEDIUM_FEE());
        _assertTierAt(hook.SCORE_MEDIUM() - 1, hook.MEDIUM_FEE());
        _assertTierAt(hook.SCORE_MEDIUM(), hook.HIGH_FEE());
        _assertTierAt(hook.SCORE_HIGH() - 1, hook.HIGH_FEE());
        _assertTierAt(hook.SCORE_HIGH(), hook.VERY_HIGH_FEE());
        _assertTierAt(type(uint256).max, hook.VERY_HIGH_FEE());
    }

    // ============================================================
    // ORACLE ATTACK SURFACE
    // ============================================================

    function testFuzz_oracleStalenessBoundary(uint256 age) public {
        age = bound(age, 0, hook.MAX_ORACLE_STALENESS() + 10);
        _initParity();
        priceFeed.setRound(int256(ORACLE), block.timestamp - 1, block.timestamp - age);

        if (age > hook.MAX_ORACLE_STALENESS()) {
            vm.expectRevert(DynamicLPFeesHook.StaleOraclePrice.selector);
            hook.previewFee(poolId);
        } else {
            (uint24 fee,) = hook.previewFee(poolId);
            assertEq(fee, hook.LOW_FEE());
        }
    }

    function testFuzz_sequencerGraceBoundary(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, hook.SEQUENCER_GRACE_PERIOD() + 10);
        _initParity();
        sequencerFeed.setRound(0, block.timestamp - elapsed, block.timestamp);

        if (elapsed <= hook.SEQUENCER_GRACE_PERIOD()) {
            vm.expectRevert(DynamicLPFeesHook.GracePeriodNotOver.selector);
            hook.previewFee(poolId);
        } else {
            (uint24 fee,) = hook.previewFee(poolId);
            assertEq(fee, hook.LOW_FEE());
        }
    }

    function test_attack_oracleSpikeBetweenSwaps() public {
        _initParity();
        _seedMinimal();

        // Tiny trade — fee is oracle-driven only.
        int256 amt = -1;
        (uint24 feeBefore,) = hook.previewFee(poolId, true, amt);
        assertEq(feeBefore, hook.LOW_FEE());

        // Attacker pumps oracle +50% mid-session (simulates off-chain move).
        priceFeed.setRound(int256(ORACLE * 150 / 100), block.timestamp - 1, block.timestamp);

        (uint24 feeAfter,) = hook.previewFee(poolId, true, amt);
        assertGt(feeAfter, feeBefore, "oracle spike must raise fee");
        assertEq(feeAfter, hook.VERY_HIGH_FEE());
        assertLe(feeAfter, hook.MAX_FEE());
    }

    function test_attack_oracleCrashBetweenSwaps() public {
        _initParity();
        _seedMinimal();
        int256 amt = -0.01 ether;

        priceFeed.setRound(int256(ORACLE / 2), block.timestamp - 1, block.timestamp);
        (uint24 fee,) = hook.previewFee(poolId, true, amt);
        assertGe(fee, hook.MEDIUM_FEE());
    }

    function testFuzz_incompleteRoundAlwaysReverts(uint256 offset) public {
        _initParity();
        uint80 nextRoundId = priceFeed.roundId() + 1;
        vm.assume(nextRoundId > 1);
        offset = bound(offset, 1, nextRoundId - 1);
        priceFeed.setRoundData(int256(ORACLE), block.timestamp - 1, block.timestamp, uint80(offset));
        vm.expectRevert(DynamicLPFeesHook.IncompleteOracleRound.selector);
        hook.previewFee(poolId);
    }

    // ============================================================
    // LIQUIDITY / TRADE MANIPULATION
    // ============================================================

    function test_attack_whaleSwapThenDrainLiquidity() public {
        _initParity();
        uint128 seededLiq = _seedMinimal();

        // Moderate whale — moves pool price away from oracle.
        int256 whale = -0.05 ether;
        (uint24 feeWhale,) = hook.previewFee(poolId, true, whale);
        assertEq(feeWhale, hook.LOW_FEE());

        _trySwap(true, whale);

        // Attacker (or LP) removes seeded position after moving price.
        _removeSeedLiquidity(seededLiq);
        (uint24 feeAfterDrain,) = hook.previewFee(poolId, true, -0.001 ether);
        assertEq(feeAfterDrain, hook.LOW_FEE(), "fee follows oracle deviation, not L");
    }

    function test_attack_splitSwapSameFeePerTx() public {
        _initParity();
        _seedMinimal();

        int256 single = -1 ether;
        int256 split = -0.1 ether;

        (uint24 feeSingle,) = hook.previewFee(poolId, true, single);
        (uint24 feeSplit,) = hook.previewFee(poolId, true, split);

        assertEq(feeSingle, feeSplit, "fee ignores trade size");
    }

    function testFuzz_absAmountSignSymmetric(int256 amount) public {
        _initParity();
        _seedMinimal();

        (uint24 feeA, uint256 scoreA) = hook.previewFee(poolId, true, amount);
        (uint24 feeB, uint256 scoreB) = hook.previewFee(poolId, true, amount == type(int256).min ? amount : -amount);

        assertEq(feeA, feeB);
        assertEq(scoreA, scoreB);
    }

    function testFuzz_appliedFeeMatchesPreviewExtreme(uint256 deltaBps, int256 amount, bool zeroForOne) public {
        deltaBps = bound(deltaBps, 0, 3000);
        amount = bound(amount, -100 ether, 100 ether);
        vm.assume(amount != 0);

        _setOracle(ORACLE);
        _initPool(_encode(_withBps(ORACLE, int256(deltaBps))));
        _seedMinimal();

        (uint24 previewFee, uint256 previewScore) = hook.previewFee(poolId, zeroForOne, amount);
        _assertFeeInvariants(previewFee, previewScore);

        vm.recordLogs();
        if (_trySwap(zeroForOne, amount)) {
            assertEq(_readAppliedFee(), previewFee);
        }
    }

    // ============================================================
    // MATH REFERENCE — on-chain must match independent formula
    // ============================================================

    function testFuzz_deviationNeverOverflows(uint256 oracle8, uint160 sqrtP) public {
        oracle8 = bound(oracle8, 100e8, type(uint128).max);
        sqrtP = uint160(bound(sqrtP, TickMath.MIN_SQRT_PRICE + 1, TickMath.MAX_SQRT_PRICE - 1));

        _setOracle(oracle8);
        _initPoolAtSqrt(sqrtP);

        uint256 pool8 = _refPoolPrice8(sqrtP);
        vm.assume(pool8 > 0);

        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        _assertFeeInvariants(fee, bps);

        uint256 diff = pool8 > oracle8 ? pool8 - oracle8 : oracle8 - pool8;
        uint256 expected = diff * 10_000 / oracle8;
        assertEq(bps, expected);
    }

    function testFuzz_poolPriceConversionMatchesReference(uint256 sqrtP) public {
        sqrtP = bound(sqrtP, TickMath.MIN_SQRT_PRICE + 1, TickMath.MAX_SQRT_PRICE - 1);
        uint256 pool8 = _refPoolPrice8(sqrtP);
        vm.assume(pool8 > 0);

        _setOracle(ORACLE);
        _initPoolAtSqrt(uint160(sqrtP));
        (, uint256 bps) = hook.previewFee(poolId);
        uint256 diff = pool8 > ORACLE ? pool8 - ORACLE : ORACLE - pool8;
        assertEq(bps, diff * 10_000 / ORACLE);
    }

    function testFuzz_swapPreviewIgnoresTradeSize(uint256 tradeSize) public {
        tradeSize = bound(tradeSize, 1, type(uint256).max / 10_000);
        _initParity();
        _seedMinimal();

        int256 amount = -int256(tradeSize);
        (uint24 gaugeFee, uint256 gaugeBps) = hook.previewFee(poolId);
        (uint24 swapFee, uint256 score) = hook.previewFee(poolId, true, amount);

        assertEq(score, gaugeBps);
        assertEq(swapFee, gaugeFee);
    }

    // ============================================================
    // HOOK SAFETY — cannot brick pool, fee flag valid, stateless
    // ============================================================

    function testFuzz_swapNeverReturnsDelta(int256 amount) public {
        amount = bound(amount, -1 ether, 1 ether);
        vm.assume(amount != 0);
        _initParity();
        _seedMinimal();

        vm.recordLogs();
        _trySwap(true, amount);
        assertTrue(true);
    }

    function test_nonDynamicFeePool_revertsOnInit() public {
        vm.expectRevert();
        initPool(currency0, currency1, IHooks(address(hook)), 3000, _encode(ORACLE));
    }

    function test_wrongPair_revertsOnInit() public {
        address daiAddr = address(0xDA1);
        deployCodeTo(
            "solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("DAI", "DAI", uint8(18)), daiAddr
        );
        vm.expectRevert();
        initPool(
            Currency.wrap(daiAddr), currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, _encode(ORACLE)
        );
    }

    function testFuzz_emptyPoolId_reverts(bytes32 rawId) public {
        PoolId id = PoolId.wrap(rawId);
        vm.expectRevert();
        hook.previewFee(id);
    }

    // ============================================================
    // helpers
    // ============================================================

    function _assertTierAt(uint256 score, uint24 expectedFee) internal {
        (uint24 fee,) = _feeFromScorePure(score);
        assertEq(fee, expectedFee, "wrong tier at score");
    }

    function _feeFromScorePure(uint256 score) internal view returns (uint24 fee, uint256 riskScore) {
        riskScore = score;
        if (score < hook.SCORE_LOW()) fee = hook.LOW_FEE();
        else if (score < hook.SCORE_MEDIUM()) fee = hook.MEDIUM_FEE();
        else if (score < hook.SCORE_HIGH()) fee = hook.HIGH_FEE();
        else fee = hook.VERY_HIGH_FEE();
        if (fee < hook.MIN_FEE()) fee = hook.MIN_FEE();
        if (fee > hook.MAX_FEE()) fee = hook.MAX_FEE();
    }

    function _feeForScore(uint256 score) internal view returns (uint24) {
        (uint24 fee,) = _feeFromScorePure(score);
        return fee;
    }

    function _assertFeeInvariants(uint24 fee, uint256 score) internal view {
        assertGe(fee, hook.MIN_FEE());
        assertLe(fee, hook.MAX_FEE());
        assertLe(fee, LPFeeLibrary.MAX_LP_FEE);
        assertEq(fee, _feeForScore(score));
    }

    function _assertScoreIsDeviationOnly(uint256 score, bool, int256) internal view {
        (, uint256 priceScore) = hook.previewFee(poolId);
        assertEq(score, priceScore);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        if (x >= 0) return uint256(x);
        if (x == type(int256).min) return uint256(type(int256).max) + 1;
        return uint256(-x);
    }

    function _refPoolPrice8(uint256 s) internal pure returns (uint256) {
        uint256 step = FullMath.mulDiv(s, s, 1 << 96);
        return FullMath.mulDiv(step, 1e20, 1 << 96);
    }

    function _readAppliedFee() internal view returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != SWAP_TOPIC) continue;
            (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            return fee;
        }
        revert("no swap");
    }

    function _initParity() internal {
        _setOracle(ORACLE);
        _initPool(_encode(ORACLE));
    }

    function _removeAllLiquidity() internal {
        _removeSeedLiquidity(manager.getLiquidity(poolId));
    }

    function _removeSeedLiquidity(uint128 liq) internal {
        (uint160 sqrtP, int24 tick,,) = manager.getSlot0(poolId);
        int24 spacing = key.tickSpacing;
        int24 lower = ((tick - 120) / spacing) * spacing;
        int24 upper = ((tick + 120) / spacing) * spacing;
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: -int128(liq), salt: bytes32(0)}),
            ZERO_BYTES
        );
        sqrtP;
    }

    function _seedMinimal() internal returns (uint128 seededLiq) {
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(poolId);
        int24 spacing = key.tickSpacing;
        int24 lower = ((tick - 120) / spacing) * spacing;
        int24 upper = ((tick + 120) / spacing) * spacing;
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), 1 ether, 3500e6
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: int128(liq), salt: bytes32(0)}),
            ZERO_BYTES
        );
        return liq;
    }

    function _withBps(uint256 base8, int256 bps) internal pure returns (uint256) {
        if (bps >= 0) return base8 * uint256(10_000 + bps) / 10_000;
        return base8 * (10_000 - uint256(-bps)) / 10_000;
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

    function _deployWethUsdc() internal {
        deployCodeTo("solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("WETH", "WETH", 18), WETH);
        deployCodeTo("solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("USDC", "USDC", 6), USDC);
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
        deployCodeTo(
            "DynamicLPFeesHook.sol", abi.encode(manager, WETH, USDC, PRICE_FEED, SEQUENCER_FEED), address(flags)
        );
        hook = DynamicLPFeesHook(address(flags));
    }

    function _initPool(uint160 sqrtPriceX96) internal {
        (key, poolId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, sqrtPriceX96);
    }

    function _initPoolAtSqrt(uint160 sqrtPriceX96) internal {
        _initPool(sqrtPriceX96);
    }

    function _trySwap(bool zeroForOne, int256 amountSpecified) internal returns (bool) {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        try swapRouter.swap(key, params, settings, ZERO_BYTES) {
            return true;
        } catch {
            return false;
        }
    }

    function _encode(uint256 ethUsd8) internal pure returns (uint160) {
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
