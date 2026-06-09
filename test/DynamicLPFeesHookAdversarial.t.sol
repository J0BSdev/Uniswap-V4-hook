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

// Adversarial integration suite: attacks the swap-fee application path, the
// feed-timestamp trust boundary, multi-pool isolation, and fee-flag validity.
contract DynamicLPFeesHookAdversarial is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant PRICE_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    uint256 internal constant NOW = 1_000_000;
    uint256 internal constant ORACLE_ETH_USD = 3500e8;

    // PoolManager Swap event (last field `fee` is the actually-applied LP fee)
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
    // 1. The fee ACTUALLY charged in a swap == our dynamic tier
    // ============================================================

    function test_appliedSwapFee_matchesTier_low() public {
        _initAndSeed(0);
        _assertAppliedFeeEquals(hook.LOW_FEE());
    }

    function test_appliedSwapFee_matchesTier_medium() public {
        _initAndSeed(300);
        _assertAppliedFeeEquals(hook.MEDIUM_FEE());
    }

    function test_appliedSwapFee_matchesTier_high() public {
        _initAndSeed(1000);
        _assertAppliedFeeEquals(hook.HIGH_FEE());
    }

    function test_appliedSwapFee_matchesTier_veryHigh() public {
        _initAndSeed(2500);
        _assertAppliedFeeEquals(hook.VERY_HIGH_FEE());
    }

    // Fuzz: whatever the deviation, the applied fee equals previewFee and the
    // swap NEVER reverts due to fee validation (fee always <= MAX_LP_FEE).
    function testFuzz_appliedFeeAlwaysValidAndMatchesPreview(uint256 deltaBps, bool up) public {
        deltaBps = bound(deltaBps, 0, up ? 50_000 : 9000);
        int256 signed = up ? int256(deltaBps) : -int256(deltaBps);

        _setOraclePrice(ORACLE_ETH_USD);
        _initPool(_encode(_withBps(ORACLE_ETH_USD, signed)));
        _seedLiquidity();

        int256 amount = -0.0005 ether;
        (uint24 previewFee,) = hook.previewFee(poolId, amount);

        vm.recordLogs();
        _swap(true, amount);
        uint24 applied = _readAppliedFee();

        assertEq(applied, previewFee, "applied != preview");
        assertLe(applied, LPFeeLibrary.MAX_LP_FEE, "fee exceeds protocol max");
        assertLe(applied, hook.MAX_FEE(), "fee exceeds hook cap");
    }

    // ============================================================
    // 2. Feed-timestamp trust boundary (future timestamps)
    // ============================================================
    // Real same-chain Chainlink feeds can never report a future timestamp, and
    // the feed addresses are immutable + hardcoded to Base's official feeds.
    // These tests pin that assumption: a future timestamp would panic (underflow).

    function test_oracle_futureUpdatedAt_panics_documentsTrustBoundary() public {
        _initParity();
        priceFeed.setRound(int256(ORACLE_ETH_USD), block.timestamp, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        hook.previewFee(poolId);
    }

    function test_sequencer_futureStartedAt_panics_documentsTrustBoundary() public {
        _initParity();
        sequencerFeed.setRound(0, block.timestamp + 1, block.timestamp);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        hook.previewFee(poolId);
    }

    // updatedAt == block.timestamp (age 0) is the freshest possible and must pass.
    function test_oracle_ageZero_ok() public {
        _initParity();
        priceFeed.setRound(int256(ORACLE_ETH_USD), block.timestamp, block.timestamp);
        (uint24 fee,) = hook.previewFee(poolId);
        assertEq(fee, hook.LOW_FEE());
    }

    // ============================================================
    // 3. Sequencer answer semantics
    // ============================================================

    function testFuzz_sequencerNonZeroAnswer_isDown(int256 answer) public {
        vm.assume(answer != 0);
        answer = bound(answer, type(int256).min, type(int256).max);
        _initParity();
        sequencerFeed.setRound(answer, block.timestamp - 5000, block.timestamp);
        vm.expectRevert(DynamicLPFeesHook.SequencerDown.selector);
        hook.previewFee(poolId);
    }

    function test_sequencerNegativeAnswer_isDown() public {
        _initParity();
        sequencerFeed.setRound(-1, block.timestamp - 5000, block.timestamp);
        vm.expectRevert(DynamicLPFeesHook.SequencerDown.selector);
        hook.previewFee(poolId);
    }

    // ============================================================
    // 4. Multi-pool isolation (same pair, different tickSpacing)
    // ============================================================

    function test_multiplePools_independentFees() public {
        // pool A at parity -> LOW
        _setOraclePrice(ORACLE_ETH_USD);
        (PoolKey memory keyA, PoolId idA) = _initPoolWithSpacing(_encode(ORACLE_ETH_USD), 60);

        // pool B at +1000 bps -> HIGH (different tickSpacing => different poolId)
        (PoolKey memory keyB, PoolId idB) = _initPoolWithSpacing(_encode(_withBps(ORACLE_ETH_USD, 1000)), 10);

        keyA; keyB;
        (uint24 feeA,) = hook.previewFee(idA);
        (uint24 feeB,) = hook.previewFee(idB);

        assertEq(feeA, hook.LOW_FEE());
        assertEq(feeB, hook.HIGH_FEE());
        assertTrue(PoolId.unwrap(idA) != PoolId.unwrap(idB));
    }

    // ============================================================
    // 5. Swap direction independence — fee identical both ways
    // ============================================================

    function testFuzz_feeSameRegardlessOfSwapDirection(uint256 deltaBps) public {
        deltaBps = bound(deltaBps, 0, 1900);

        _setOraclePrice(ORACLE_ETH_USD);
        _initPool(_encode(_withBps(ORACLE_ETH_USD, int256(deltaBps))));
        _seedLiquidity();

        int256 amount0 = -0.0005 ether;
        int256 amount1 = -1e6;

        vm.recordLogs();
        _swap(true, amount0);
        uint24 feeZeroForOne = _readAppliedFee();

        vm.recordLogs();
        _swap(false, amount1);
        uint24 feeOneForZero = _readAppliedFee();

        (uint24 preview0,) = hook.previewFee(poolId, amount0);
        (uint24 preview1,) = hook.previewFee(poolId, amount1);
        assertEq(feeZeroForOne, preview0);
        assertEq(feeOneForZero, preview1);
    }

    // ============================================================
    // 6. Repeated swaps don't drift / accumulate state (stateless hook)
    // ============================================================

    function test_repeatedSwaps_feeStableWhenPriceStable() public {
        _initAndSeed(0);
        int256 amount = -0.00001 ether;
        for (uint256 i = 0; i < 5; i++) {
            (uint24 preview,) = hook.previewFee(poolId, amount);
            vm.recordLogs();
            _swap(true, amount);
            assertEq(_readAppliedFee(), preview);
        }
    }

    // ============================================================
    // helpers
    // ============================================================

    function _assertAppliedFeeEquals(uint24 expected) internal {
        int256 amount = -0.0005 ether;
        (uint24 preview,) = hook.previewFee(poolId, amount);
        assertEq(preview, expected, "preview tier mismatch");
        vm.recordLogs();
        _swap(true, amount);
        assertEq(_readAppliedFee(), expected, "applied fee tier mismatch");
    }

    function _readAppliedFee() internal view returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != SWAP_TOPIC) continue;
            (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            found = true;
        }
        assertTrue(found, "no Swap event captured");
    }

    function _initAndSeed(int256 deltaBps) internal {
        _setOraclePrice(ORACLE_ETH_USD);
        _initPool(_encode(_withBps(ORACLE_ETH_USD, deltaBps)));
        _seedLiquidity();
    }

    function _initParity() internal {
        _setOraclePrice(ORACLE_ETH_USD);
        _initPool(_encode(ORACLE_ETH_USD));
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

    function _initPoolWithSpacing(uint160 sqrtPriceX96, int24 spacing)
        internal
        returns (PoolKey memory k, PoolId id)
    {
        k = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: IHooks(address(hook))
        });
        manager.initialize(k, sqrtPriceX96);
        id = k.toId();
    }

    function _seedLiquidity() internal {
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(poolId);
        int24 spacing = key.tickSpacing;
        int24 lower = ((tick - 120) / spacing) * spacing;
        int24 upper = ((tick + 120) / spacing) * spacing;

        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), 10 ether, 35_000e6
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: int128(liq), salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(key, params, settings, ZERO_BYTES);
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
