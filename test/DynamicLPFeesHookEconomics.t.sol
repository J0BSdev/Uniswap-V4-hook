// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {DynamicLPFeesHook} from "../src/LPFees/DynamicLPFeesHook.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";

/// @notice Economics + math regression: USD-normalized size scores, WETH/USDC parity, tier logic.
contract DynamicLPFeesHookEconomics is Test, Deployers {
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

    DynamicLPFeesHook hook;
    MockChainlinkAggregator priceFeed;
    MockChainlinkAggregator sequencerFeed;
    PoolId poolId;

    function setUp() public {
        vm.warp(10_000);
        deployFreshManagerAndRouters();
        _deployMockFeeds();
        _deployPair(WETH_MAIN, USDC_MAIN);
        _deployHook(WETH_MAIN, USDC_MAIN);
    }

    // --- regression: old raw-wei formula unfairly penalized USDC ---

    function test_regression_usdcNotUnderweightedVsWeth() public {
        _initAtOracle();
        _seed();

        int256 weth035 = -0.01 ether;
        int256 usdc35 = -35e6;

        (, uint256 wethScore) = hook.previewFee(poolId, true, weth035);
        (, uint256 usdcScore) = hook.previewFee(poolId, false, usdc35);

        assertApproxEqAbs(wethScore, usdcScore, 2, "USD-equivalent trades must score equally");

        // Raw-wei bug: USDC side was ~285714x underweighted vs WETH for same USD.
        uint128 liq = manager.getLiquidity(poolId);
        uint256 buggyUsdc = 35e6 * 10_000 / uint256(liq);
        assertGt(usdcScore, buggyUsdc * 100, "USDC must not use raw 6-dec wei in score");
    }

    function test_usdNotional_orderingHigherTradeHigherScore() public {
        _initAtOracle();
        _seed();

        (, uint256 s001) = hook.previewFee(poolId, true, -0.01 ether);
        (, uint256 s100) = hook.previewFee(poolId, false, -100e6);
        (, uint256 s1k) = hook.previewFee(poolId, false, -1000e6);

        assertLt(s001, s100, "~$35 < ~$100");
        assertLt(s100, s1k, "~$100 < ~$1000");
    }

    function testFuzz_wethUsdcUsdEquivalent_sameSizeScore(uint256 usdcWhole) public {
        usdcWhole = bound(usdcWhole, 1, 100_000);
        _initAtOracle();
        _seed();

        uint256 usdcRaw = usdcWhole * 1e6;
        uint256 wethWei = usdcWhole * 1e18 / 3500;
        vm.assume(wethWei <= uint256(uint128(type(int128).max)));
        vm.assume(usdcRaw <= uint256(uint128(type(int128).max)));

        int256 wethAmt = -int256(wethWei);
        int256 usdcAmt = -int256(usdcRaw);

        (, uint256 wethScore) = hook.previewFee(poolId, true, wethAmt);
        (, uint256 usdcScore) = hook.previewFee(poolId, false, usdcAmt);

        assertApproxEqAbs(wethScore, usdcScore, 3, "WETH/USDC USD parity");
    }

    function testFuzz_usdcSizeScore_matchesReferenceFormula(uint256 usdcRaw) public {
        usdcRaw = bound(usdcRaw, 1e4, 500_000e6);
        _initAtOracle();
        _seed();

        int256 amount = -int256(usdcRaw);
        (, uint256 score) = hook.previewFee(poolId, false, amount);

        uint128 liq = manager.getLiquidity(poolId);
        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        uint256 poolPrice8 = _poolPrice8(sqrtP, true);
        uint256 wethEq = FullMath.mulDiv(usdcRaw, 1e20, poolPrice8);
        uint256 expected = wethEq * 10_000 / uint256(liq);

        assertEq(score, expected);
    }

    function testFuzz_doubleTradeSize_doublesSizeScoreWhenDeviationZero() public {
        uint256 usdcRaw = bound(uint256(keccak256("size")), 1e6, 100_000e6);
        _initAtOracle();
        _seed();

        (, uint256 score1) = hook.previewFee(poolId, false, -int256(usdcRaw));
        (, uint256 score2) = hook.previewFee(poolId, false, -int256(usdcRaw * 2));

        assertApproxEqAbs(score2, score1 * 2, 2);
    }

    function test_sepoliaTokenOrder_usdEquivalentSymmetric() public {
        _redeploySepoliaOrder();

        _initAtOracle();
        _seed();

        // USDC is token0 on Sepolia → zeroForOne=true for USDC in, false for WETH in
        int256 usdc35 = -35e6;
        int256 weth001 = -0.01 ether;

        (, uint256 usdcScore) = hook.previewFee(poolId, true, usdc35);
        (, uint256 wethScore) = hook.previewFee(poolId, false, weth001);

        assertApproxEqAbs(usdcScore, wethScore, 2, "Sepolia token order parity");
    }

    function testFuzz_sepoliaOrder_usdcFormula(uint256 usdcRaw) public {
        usdcRaw = bound(usdcRaw, 1e4, 200_000e6);
        _redeploySepoliaOrder();
        _initAtOracle();
        _seed();

        int256 amount = -int256(usdcRaw);
        (, uint256 score) = hook.previewFee(poolId, true, amount);

        uint128 liq = manager.getLiquidity(poolId);
        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        uint256 poolPrice8 = _poolPrice8(sqrtP, false);
        uint256 wethEq = FullMath.mulDiv(usdcRaw, 1e20, poolPrice8);
        assertEq(score, wethEq * 10_000 / uint256(liq));
    }

    function test_previewFee_swapMatchesBeforeSwap() public {
        _initAtOracle();
        _seed();

        int256 wethAmt = -0.05 ether;
        int256 usdcAmt = -200e6;

        (uint24 feeW,) = hook.previewFee(poolId, true, wethAmt);
        (uint24 feeU,) = hook.previewFee(poolId, false, usdcAmt);

        assertGe(feeW, hook.LOW_FEE());
        assertGe(feeU, hook.LOW_FEE());
        assertLe(feeW, hook.MAX_FEE());
        assertLe(feeU, hook.MAX_FEE());
    }

    // --- helpers ---

    function _redeploySepoliaOrder() internal {
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
        priceFeed.setRound(int256(ORACLE), block.timestamp - 5000, block.timestamp);
        sequencerFeed.setRound(0, block.timestamp - 5000, block.timestamp);
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
        deployCodeTo("DynamicLPFeesHook.sol", abi.encode(manager, weth, usdc, PRICE_FEED, SEQUENCER_FEED), hookAddress);
        hook = DynamicLPFeesHook(hookAddress);
    }

    function _initAtOracle() internal {
        uint160 sqrtP = _encode(ORACLE, currency0 == Currency.wrap(WETH_MAIN) || currency0 == Currency.wrap(WETH_SEP));
        manager.initialize(_key(), sqrtP);
        poolId = _key().toId();
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

    function _seed() internal {
        (uint160 sqrtP, int24 tick,,) = manager.getSlot0(poolId);
        int24 lower = ((tick / 60) - 3) * 60;
        int24 upper = ((tick / 60) + 3) * 60;
        bool weth0 = Currency.unwrap(currency0) == WETH_MAIN || Currency.unwrap(currency0) == WETH_SEP;
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

    function _encode(uint256 oraclePrice8, bool wethToken0) internal pure returns (uint160) {
        uint256 target;
        if (wethToken0) {
            target = FullMath.mulDiv(oraclePrice8, 1 << 192, 1e20);
        } else {
            target = FullMath.mulDiv(1e26, 1 << 192, oraclePrice8 * 1e6);
        }
        return uint160(_sqrt(target));
    }

    function _poolPrice8(uint160 sqrtP, bool wethToken0) internal pure returns (uint256) {
        uint256 step = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), 1 << 96);
        if (wethToken0) return FullMath.mulDiv(step, 1e20, 1 << 96);
        return FullMath.mulDiv(1e20, 1 << 96, step);
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
}
