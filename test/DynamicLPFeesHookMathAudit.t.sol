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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {DynamicLPFeesHook} from "../src/LPFees/DynamicLPFeesHook.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";

// Adversarial audit of the price math and oracle handling.
// Goal: actively try to break the deviation/price conversion and the oracle reads.
contract DynamicLPFeesHookMathAudit is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant PRICE_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    uint256 internal constant NOW = 1_000_000;
    uint256 internal constant ORACLE_ETH_USD = 3500e8;

    DynamicLPFeesHook hook;
    MockChainlinkAggregator priceFeed;
    MockChainlinkAggregator sequencerFeed;
    PoolId poolId;

    function setUp() public {
        vm.warp(NOW);
        deployFreshManagerAndRouters();
        _deployMockFeeds();
        _deployWethUsdc();
        _deployHook();
    }

    // ============================================================
    // PRICE MATH — reference implementation cross-check
    // ============================================================

    // An independent, high-precision reference for poolPrice8 using rational math.
    // poolPrice8 = (sqrtPriceX96^2 / 2^192) * 1e20, floored.
    function _refPoolPrice8(uint256 s) internal pure returns (uint256) {
        // compute s^2 * 1e20 / 2^192 without losing precision via FullMath two-step
        uint256 step = FullMath.mulDiv(s, s, 1 << 96); // s^2 / 2^96
        return FullMath.mulDiv(step, 1e20, 1 << 96); // * 1e20 / 2^96
    }

    // The hook's conversion must equal the reference across the ENTIRE valid range.
    function testFuzz_poolPriceConversionMatchesReference(uint256 s) public {
        s = bound(s, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1);

        // drive the pool to sqrtPrice s and read deviation against a matching oracle,
        // back out the implied poolPrice8 the hook used and compare to reference.
        uint256 ref = _refPoolPrice8(s);
        vm.assume(ref > 0); // below this, hook cleanly reverts (covered separately)

        _setOraclePrice(ref == 0 ? 1 : ref); // oracle == pool => deviation 0 if exact
        _initPoolAtSqrtPrice(uint160(s));

        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        // when oracle == reference poolPrice8, deviation must be ~0
        assertLe(bps, 1, "deviation should be ~0 when oracle matches reference price");
        assertEq(fee, hook.LOW_FEE());
    }

    // Try to break the conversion at the EXTREME HIGH end (near MAX_SQRT_PRICE).
    // Pool creation is permissionless, so an absurd-but-valid price must not panic.
    function test_highPrice_doesNotPanic_nearMaxSqrtPrice() public {
        uint160 s = TickMath.MAX_SQRT_PRICE - 1;
        _setOraclePrice(ORACLE_ETH_USD);
        _initPoolAtSqrtPrice(s);

        // must return a clean result or a clean custom error, never a generic overflow panic
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertGe(fee, hook.MIN_FEE());
        assertLe(fee, hook.MAX_FEE());
        assertGt(bps, 0);
    }

    // Sweep across the high band [2^128, MAX] that used to overflow the old math.
    function testFuzz_highPriceBand_noPanic(uint256 s) public {
        s = bound(s, uint256(1) << 128, TickMath.MAX_SQRT_PRICE - 1);
        _setOraclePrice(ORACLE_ETH_USD);
        _initPoolAtSqrtPrice(uint160(s));

        (uint24 fee,) = hook.previewFee(poolId);
        assertGe(fee, hook.MIN_FEE());
        assertLe(fee, hook.MAX_FEE());
    }

    // EXTREME LOW end (near MIN_SQRT_PRICE) must round to zero and revert cleanly.
    function test_lowPrice_revertsCleanly_nearMinSqrtPrice() public {
        uint160 s = TickMath.MIN_SQRT_PRICE;
        _setOraclePrice(ORACLE_ETH_USD);
        _initPoolAtSqrtPrice(s);

        vm.expectRevert(DynamicLPFeesHook.PoolPriceNotSet.selector);
        hook.previewFee(poolId);
    }

    // ============================================================
    // DEVIATION MATH — exactness against an independent computation
    // ============================================================

    // For a given realistic price and oracle, the bps must equal the integer formula exactly.
    function testFuzz_deviationBpsExact(uint256 oracle8, uint256 pool8) public {
        oracle8 = bound(oracle8, 100e8, 100_000e8);
        pool8 = bound(pool8, 100e8, 100_000e8);

        // build a pool sqrtPrice whose reconstructed price == pool8 (within rounding),
        // then compare hook bps to the formula using the hook's OWN reconstructed price.
        uint160 s = _encodeSqrtPriceX96Static(pool8);
        uint256 reconstructed = _refPoolPrice8(s);
        vm.assume(reconstructed > 0);

        _setOraclePrice(oracle8);
        _initPoolAtSqrtPrice(s);

        (, uint256 bps) = hook.previewFee(poolId);

        uint256 diff = reconstructed > oracle8 ? reconstructed - oracle8 : oracle8 - reconstructed;
        uint256 expectedBps = diff * 10000 / oracle8;
        assertEq(bps, expectedBps, "bps must equal exact integer formula");
    }

    // Deviation must never overflow even when pool price is astronomically large.
    function test_deviationNoOverflow_atMaxPrice() public {
        _setOraclePrice(100e8); // tiny oracle, huge pool => max diff
        _initPoolAtSqrtPrice(TickMath.MAX_SQRT_PRICE - 1);
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.VERY_HIGH_FEE());
        assertGt(bps, hook.SCORE_HIGH());
    }

    // Symmetry: pool above oracle by X bps and below by X bps yield ~equal |deviation|.
    // (Tiers can differ by one step only exactly on a boundary due to integer rounding,
    // so we compare the measured bps magnitude, allowing a tiny rounding tolerance.)
    function testFuzz_symmetricDeviationMagnitude(uint256 deltaBps) public {
        deltaBps = bound(deltaBps, 0, 9000);

        _setOraclePrice(ORACLE_ETH_USD);
        _initPoolAtSqrtPrice(_encodeSqrtPriceX96Static(_withBps(ORACLE_ETH_USD, int256(deltaBps))));
        (, uint256 bpsUp) = hook.previewFee(poolId);

        _redeploy();
        _setOraclePrice(ORACLE_ETH_USD);
        _initPoolAtSqrtPrice(_encodeSqrtPriceX96Static(_withBps(ORACLE_ETH_USD, -int256(deltaBps))));
        (, uint256 bpsDown) = hook.previewFee(poolId);

        assertApproxEqAbs(bpsUp, bpsDown, 2, "up/down deviation magnitude must match");
    }

    // ============================================================
    // ORACLE — try every nasty value real Chainlink could emit
    // ============================================================

    function test_oracle_exactlyAtStalenessBoundary_ok() public {
        _initAtParity();
        priceFeed.setRound(int256(ORACLE_ETH_USD), block.timestamp - 1, block.timestamp - hook.MAX_ORACLE_STALENESS());
        (uint24 fee,) = hook.previewFee(poolId);
        assertEq(fee, hook.LOW_FEE());
    }

    function test_oracle_oneSecondPastStaleness_reverts() public {
        _initAtParity();
        priceFeed.setRound(
            int256(ORACLE_ETH_USD), block.timestamp - 1, block.timestamp - hook.MAX_ORACLE_STALENESS() - 1
        );
        vm.expectRevert(DynamicLPFeesHook.StaleOraclePrice.selector);
        hook.previewFee(poolId);
    }

    function test_oracle_zeroAnswer_reverts() public {
        _initAtParity();
        priceFeed.setRound(0, block.timestamp - 1, block.timestamp);
        vm.expectRevert(DynamicLPFeesHook.CurrentOraclePriceNotSet.selector);
        hook.previewFee(poolId);
    }

    function testFuzz_oracle_negativeAnswer_reverts(int256 answer) public {
        answer = bound(answer, type(int256).min, -1);
        _initAtParity();
        priceFeed.setRound(answer, block.timestamp - 1, block.timestamp);
        vm.expectRevert(DynamicLPFeesHook.CurrentOraclePriceNotSet.selector);
        hook.previewFee(poolId);
    }

    function test_oracle_incompleteRound_reverts() public {
        _initAtParity();
        priceFeed.setRoundData(int256(ORACLE_ETH_USD), block.timestamp - 1, block.timestamp, 1);
        vm.expectRevert(DynamicLPFeesHook.IncompleteOracleRound.selector);
        hook.previewFee(poolId);
    }

    // Smallest valid positive answer (1) must still work and produce a huge deviation.
    function test_oracle_minimalPositiveAnswer() public {
        _initAtParity();
        priceFeed.setRound(1, block.timestamp - 1, block.timestamp);
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.VERY_HIGH_FEE());
        assertGt(bps, hook.SCORE_HIGH());
    }

    // Oracle answer at the very top of int256 must not overflow the deviation math.
    function test_oracle_hugeAnswer_noOverflow() public {
        _initAtParity();
        // pool ~ $3500, oracle enormous => deviation ~ 10000 bps (capped sense), no overflow
        priceFeed.setRound(int256(uint256(1e30)), block.timestamp - 1, block.timestamp);
        (uint24 fee, uint256 bps) = hook.previewFee(poolId);
        assertEq(fee, hook.VERY_HIGH_FEE());
        assertApproxEqAbs(bps, 10000, 5);
    }

    // ============================================================
    // SEQUENCER — boundary + ordering (sequencer checked before oracle)
    // ============================================================

    function test_sequencer_checkedBeforeOracle() public {
        _initAtParity();
        // make BOTH bad: sequencer down AND oracle stale. Sequencer error must win.
        sequencerFeed.setRound(1, block.timestamp - 5000, block.timestamp);
        priceFeed.setRound(int256(ORACLE_ETH_USD), block.timestamp - 1, block.timestamp - 99999 + NOW);
        vm.expectRevert(DynamicLPFeesHook.SequencerDown.selector);
        hook.previewFee(poolId);
    }

    function test_sequencer_graceExactBoundary_reverts() public {
        _initAtParity();
        sequencerFeed.setRound(0, block.timestamp - hook.SEQUENCER_GRACE_PERIOD(), block.timestamp);
        vm.expectRevert(DynamicLPFeesHook.GracePeriodNotOver.selector);
        hook.previewFee(poolId);
    }

    function test_sequencer_graceJustOver_ok() public {
        _initAtParity();
        sequencerFeed.setRound(0, block.timestamp - hook.SEQUENCER_GRACE_PERIOD() - 1, block.timestamp);
        (uint24 fee,) = hook.previewFee(poolId);
        assertEq(fee, hook.LOW_FEE());
    }

    // ============================================================
    // helpers
    // ============================================================

    function _initAtParity() internal {
        _setOraclePrice(ORACLE_ETH_USD);
        _initPoolAtSqrtPrice(_encodeSqrtPriceX96Static(ORACLE_ETH_USD));
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
        deployCodeTo(
            "solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("WETH", "WETH", uint8(18)), WETH
        );
        deployCodeTo("solmate/src/test/utils/mocks/MockERC20.sol:MockERC20", abi.encode("USDC", "USDC", uint8(6)), USDC);
        currency0 = Currency.wrap(WETH);
        currency1 = Currency.wrap(USDC);
    }

    function _deployHook() internal {
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("DynamicLPFeesHook.sol", abi.encode(manager, WETH, USDC, PRICE_FEED, SEQUENCER_FEED), hookAddress);
        hook = DynamicLPFeesHook(hookAddress);
    }

    function _redeploy() internal {
        deployFreshManagerAndRouters();
        _deployMockFeeds();
        _deployWethUsdc();
        _deployHook();
    }

    function _initPoolAtSqrtPrice(uint160 sqrtPriceX96) internal {
        (key, poolId) =
            initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, sqrtPriceX96);
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
