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

/// @notice Economics regression: fee depends on oracle deviation only, not trade size.
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

    function test_feeIndependentOfTradeSize() public {
        _initAtOracle();
        _seed();

        (uint24 gaugeFee, uint256 gaugeBps) = hook.previewFee(poolId);
        (uint24 feeSmall,) = hook.previewFee(poolId, false, -111e6);
        (uint24 feeLarge,) = hook.previewFee(poolId, true, -10 ether);

        assertEq(feeSmall, gaugeFee, "111 USDC must not change fee");
        assertEq(feeLarge, gaugeFee, "10 WETH must not change fee");
        assertEq(gaugeBps, 0);
        assertEq(gaugeFee, hook.LOW_FEE());
    }

    function testFuzz_swapPreviewMatchesGauge(int256 amount, bool zeroForOne) public {
        amount = bound(amount, -1000 ether, 1000 ether);
        _initAtOracle();
        _seed();

        (uint24 gaugeFee, uint256 gaugeBps) = hook.previewFee(poolId);
        (uint24 swapFee, uint256 swapBps) = hook.previewFee(poolId, zeroForOne, amount);

        assertEq(swapFee, gaugeFee);
        assertEq(swapBps, gaugeBps);
    }

    function test_sepoliaTokenOrder_feeSameForBothDirections() public {
        _redeploySepoliaOrder();
        _initAtOracle();
        _seed();

        (uint24 gaugeFee,) = hook.previewFee(poolId);
        (uint24 usdcFee,) = hook.previewFee(poolId, true, -35e6);
        (uint24 wethFee,) = hook.previewFee(poolId, false, -0.01 ether);

        assertEq(usdcFee, gaugeFee);
        assertEq(wethFee, gaugeFee);
    }

    function test_previewFee_swapMatchesBeforeSwap() public {
        _initAtOracle();
        _seed();

        (uint24 gauge,) = hook.previewFee(poolId);
        (uint24 feeW,) = hook.previewFee(poolId, true, -0.05 ether);
        (uint24 feeU,) = hook.previewFee(poolId, false, -200e6);

        assertEq(feeW, gauge);
        assertEq(feeU, gauge);
        assertGe(gauge, hook.LOW_FEE());
        assertLe(gauge, hook.MAX_FEE());
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
