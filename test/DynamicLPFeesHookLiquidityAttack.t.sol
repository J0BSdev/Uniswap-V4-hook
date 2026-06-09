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

/// @notice Attacker-focused suite: thin liquidity, extreme amounts, math edges.
contract DynamicLPFeesHookLiquidityAttack is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant PRICE_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    uint256 internal constant NOW = 1_000_000;
    uint256 internal constant ORACLE_ETH_USD = 3500e8;

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
    // 1. Minimal liquidity (fork seed: 1 WETH + 3500 USDC)
    // ============================================================

    function test_minimalLiquidity_whaleSwap_getsVeryHighFee() public {
        _initAndSeedMinimal();
        uint128 liq = manager.getLiquidity(poolId);
        assertGt(liq, 0);

        // Swap almost entire WETH side of the book.
        int256 amount = -int256(uint256(liq));
        (uint24 fee, uint256 score) = hook.previewFee(poolId, amount);
        assertGe(score, hook.SCORE_HIGH());
        assertEq(fee, hook.VERY_HIGH_FEE());

        vm.recordLogs();
        _swap(true, amount);
        assertEq(_readAppliedFee(), fee);
    }

    function test_minimalLiquidity_manySmallSwaps_feeStable() public {
        _initAndSeedMinimal();
        int256 amount = -0.001 ether;
        (uint24 first,) = hook.previewFee(poolId, amount);

        for (uint256 i = 0; i < 10; i++) {
            (uint24 preview,) = hook.previewFee(poolId, amount);
            vm.recordLogs();
            _swap(true, amount);
            assertEq(_readAppliedFee(), preview);
            assertEq(preview, first, "fee drifted across repeated small swaps");
        }
    }

    // ============================================================
    // 2. Size-ratio math — must never panic, fee always bounded
    // ============================================================

    function test_previewFee_int256Min_doesNotBrickView() public {
        _initAndSeedMinimal();
        // Attacker calls preview with worst-case int256 — must not panic.
        (uint24 fee, uint256 score) = hook.previewFee(poolId, type(int256).min);
        assertGe(fee, hook.MIN_FEE());
        assertLe(fee, hook.MAX_FEE());
        assertLe(fee, LPFeeLibrary.MAX_LP_FEE);
        assertGt(score, 0);
    }

    function test_previewFee_int256Max_doesNotBrickView() public {
        _initAndSeedMinimal();
        (uint24 fee, uint256 score) = hook.previewFee(poolId, type(int256).max);
        assertGe(fee, hook.MIN_FEE());
        assertLe(fee, hook.MAX_FEE());
        assertEq(fee, hook.VERY_HIGH_FEE());
        assertGt(score, hook.SCORE_HIGH());
    }

    function test_previewFee_zeroAmount_ignoresSizeRatio() public {
        _initAndSeedMinimal();
        (uint24 gaugeFee, uint256 gaugeBps) = hook.previewFee(poolId);
        (uint24 swapFee, uint256 swapBps) = hook.previewFee(poolId, 0);
        assertEq(swapFee, gaugeFee);
        assertEq(swapBps, gaugeBps);
    }

    function testFuzz_previewFee_neverPanics_randomAmount(int256 amount) public {
        _initAndSeedMinimal();
        (uint24 fee, uint256 score) = hook.previewFee(poolId, amount);
        assertGe(fee, hook.MIN_FEE());
        assertLe(fee, hook.MAX_FEE());
        assertLe(fee, LPFeeLibrary.MAX_LP_FEE);
        assertGe(score, _expectedPriceScore());
        _assertFeeMatchesScore(fee, score);
    }

    function testFuzz_sizeRatio_formula(uint256 tradeSize) public {
        tradeSize = bound(tradeSize, 1, type(uint256).max / 10_000);
        _initAndSeedMinimal();

        uint128 liquidity = manager.getLiquidity(poolId);
        int256 amount = -int256(tradeSize);

        (uint24 fee, uint256 score) = hook.previewFee(poolId, amount);
        uint256 expectedSize = tradeSize * 10_000 / uint256(liquidity);
        uint256 priceScore = _expectedPriceScore();
        uint256 expectedScore = priceScore > expectedSize ? priceScore : expectedSize;

        assertEq(score, expectedScore);
        _assertFeeMatchesScore(fee, score);
    }

    // ============================================================
    // 3. Combined attack: oracle parity + huge trade on thin book
    // ============================================================

    function testFuzz_thinBookHugeTrade_feeFromSizeNotOracle(uint256 tradeSize) public {
        tradeSize = bound(tradeSize, 1, 100 ether);
        _initAndSeedMinimal();

        (uint24 gaugeFee, uint256 gaugeBps) = hook.previewFee(poolId);
        assertEq(gaugeBps, 0);
        assertEq(gaugeFee, hook.LOW_FEE());

        int256 amount = -int256(tradeSize);
        (uint24 swapFee, uint256 swapBps) = hook.previewFee(poolId, amount);

        uint128 liq = manager.getLiquidity(poolId);
        uint256 sizeBps = tradeSize * 10_000 / uint256(liq);

        assertEq(swapBps, sizeBps > gaugeBps ? sizeBps : gaugeBps);
        if (sizeBps >= hook.SCORE_LOW()) {
            assertGe(swapFee, hook.MEDIUM_FEE(), "large vs liquidity should hit elevated tier");
        }
        _assertFeeMatchesScore(swapFee, swapBps);
    }

    // ============================================================
    // 4. Real swaps always match swap-aware preview
    // ============================================================

    function testFuzz_appliedFeeMatchesSwapPreview(uint256 deltaBps, uint256 tradeSize, bool zeroForOne) public {
        deltaBps = bound(deltaBps, 0, 2500);
        tradeSize = bound(tradeSize, 1e10, 0.9 ether);

        _setOraclePrice(ORACLE_ETH_USD);
        _initPool(_encode(_withBps(ORACLE_ETH_USD, int256(deltaBps))));
        _seedMinimal();

        int256 amount = zeroForOne ? -int256(tradeSize) : -int256(bound(tradeSize, 1e4, 500_000e6));

        (uint24 previewFee, uint256 previewBps) = hook.previewFee(poolId, amount);

        vm.recordLogs();
        bool ok = _trySwap(zeroForOne, amount);
        if (ok) {
            assertEq(_readAppliedFee(), previewFee);
            assertLe(previewFee, hook.MAX_FEE());
            assertLe(previewFee, LPFeeLibrary.MAX_LP_FEE);
        }
        _assertFeeMatchesScore(previewFee, previewBps);
    }

    // ============================================================
    // 5. Liquidity removal attack — fee path still safe
    // ============================================================

    function test_afterFullLiquidityRemoval_previewUsesMaxSizeScore() public {
        _initAndSeedMinimal();
        (uint160 sqrtP, int24 tick,,) = manager.getSlot0(poolId);
        int24 spacing = key.tickSpacing;
        int24 lower = ((tick - 120) / spacing) * spacing;
        int24 upper = ((tick + 120) / spacing) * spacing;
        uint128 liq = manager.getLiquidity(poolId);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: -int128(liq), salt: bytes32(0)}),
            ZERO_BYTES
        );
        assertEq(manager.getLiquidity(poolId), 0);

        (uint24 fee, uint256 score) = hook.previewFee(poolId, -1 ether);
        assertEq(fee, hook.VERY_HIGH_FEE());
        assertEq(score, type(uint256).max);
        sqrtP; // silence warning
    }

    // ============================================================
    // 6. Exact-output swaps (positive amountSpecified)
    // ============================================================

    function testFuzz_exactOutput_positiveAmount_previewConsistent(uint256 outAmount) public {
        outAmount = bound(outAmount, 1e6, 1000e6);
        _initAndSeedMinimal();
        int256 amount = int256(outAmount);

        (uint24 fee, uint256 score) = hook.previewFee(poolId, amount);
        assertGe(fee, hook.MIN_FEE());
        assertLe(fee, hook.MAX_FEE());
        _assertFeeMatchesScore(fee, score);
    }

    // ============================================================
    // helpers
    // ============================================================

    function _expectedPriceScore() internal view returns (uint256) {
        (, uint256 bps) = hook.previewFee(poolId);
        return bps;
    }

    function _assertFeeMatchesScore(uint24 fee, uint256 score) internal view {
        uint24 expected;
        if (score < hook.SCORE_LOW()) expected = hook.LOW_FEE();
        else if (score < hook.SCORE_MEDIUM()) expected = hook.MEDIUM_FEE();
        else if (score < hook.SCORE_HIGH()) expected = hook.HIGH_FEE();
        else expected = hook.VERY_HIGH_FEE();
        if (expected < hook.MIN_FEE()) expected = hook.MIN_FEE();
        if (expected > hook.MAX_FEE()) expected = hook.MAX_FEE();
        assertEq(fee, expected);
    }

    function _readAppliedFee() internal view returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != SWAP_TOPIC) continue;
            (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            return fee;
        }
        revert("no Swap event");
    }

    function _initAndSeedMinimal() internal {
        _setOraclePrice(ORACLE_ETH_USD);
        _initPool(_encode(ORACLE_ETH_USD));
        _seedMinimal();
    }

    function _seedMinimal() internal {
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
        _setOraclePrice(ORACLE_ETH_USD);
        sequencerFeed.setRound(0, block.timestamp - 5000, block.timestamp);
    }

    function _setOraclePrice(uint256 oraclePrice8) internal {
        priceFeed.setRound(int256(oraclePrice8), block.timestamp - 1, block.timestamp);
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

    function _initPool(uint160 sqrtPriceX96) internal {
        (key, poolId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, sqrtPriceX96);
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        require(_trySwap(zeroForOne, amountSpecified), "swap failed");
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
