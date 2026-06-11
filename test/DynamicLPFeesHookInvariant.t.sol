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
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {DynamicLPFeesHook} from "../src/LPFees/DynamicLPFeesHook.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";

// Drives random oracle moves + swaps against a live pool. Keeps feeds healthy
// (sequencer up, oracle fresh) so the only state that changes is pool price + oracle value.
contract InvariantHandler is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public manager;
    DynamicLPFeesHook public hook;
    MockChainlinkAggregator public priceFeed;
    PoolSwapTest public swapRouter;
    PoolKey public key;
    PoolId public poolId;
    address public weth;
    address public usdc;

    uint256 public swaps;
    uint256 public oracleMoves;

    constructor(
        IPoolManager _manager,
        DynamicLPFeesHook _hook,
        MockChainlinkAggregator _priceFeed,
        PoolSwapTest _swapRouter,
        PoolKey memory _key,
        address _weth,
        address _usdc
    ) {
        manager = _manager;
        hook = _hook;
        priceFeed = _priceFeed;
        swapRouter = _swapRouter;
        key = _key;
        poolId = _key.toId();
        weth = _weth;
        usdc = _usdc;
        MockERC20(_weth).approve(address(_swapRouter), type(uint256).max);
        MockERC20(_usdc).approve(address(_swapRouter), type(uint256).max);
    }

    function moveOracle(uint256 price8) public {
        price8 = bound(price8, 500e8, 20_000e8);
        // keep fresh: updatedAt == current block timestamp
        priceFeed.setRound(int256(price8), block.timestamp - 1, block.timestamp);
        oracleMoves++;
    }

    function swap(uint256 amount, bool zeroForOne) public {
        amount = bound(amount, 1e9, 0.5 ether);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        // swaps may revert (price limit / liquidity / extreme price) — that's fine
        try swapRouter.swap(key, params, s, "") {
            swaps++;
        } catch {}
    }
}

contract DynamicLPFeesHookInvariant is Test, Deployers {
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
    InvariantHandler handler;

    function setUp() public {
        vm.warp(NOW);
        deployFreshManagerAndRouters();
        _deployMockFeeds();
        _deployWethUsdc();
        _deployHook();

        _setOraclePrice(ORACLE_ETH_USD);
        (key, poolId) = initPool(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, _encode(ORACLE_ETH_USD)
        );
        _seedWideLiquidity();

        handler = new InvariantHandler(IPoolManager(address(manager)), hook, priceFeed, swapRouter, key, WETH, USDC);
        MockERC20(WETH).mint(address(handler), 500_000 ether);
        MockERC20(USDC).mint(address(handler), 500_000_000e6);

        // only fuzz the handler's two actions
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = InvariantHandler.moveOracle.selector;
        selectors[1] = InvariantHandler.swap.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // CORE INVARIANT: at any reachable state, previewFee either returns a fee that
    // exactly matches an independent recomputation from live slot0 + oracle (and is a
    // valid tier), or it reverts ONLY with PoolPriceNotSet (extreme price rounding).
    function invariant_feeConsistentWithLiveState() public view {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);

        try hook.previewFee(poolId) returns (uint24 fee, uint256 bps) {
            uint256 poolPrice8 = _refConvert(sqrtPriceX96);
            (, int256 ans,,,) = priceFeed.latestRoundData();
            uint256 oracle = uint256(ans);

            uint256 diff = poolPrice8 > oracle ? poolPrice8 - oracle : oracle - poolPrice8;
            uint256 expBps = diff * 10000 / oracle;

            assertEq(bps, expBps, "bps drifted from live recomputation");
            assertEq(fee, _expectedFeeForBps(bps), "fee/tier mismatch");
            assertTrue(
                fee == hook.LOW_FEE() || fee == hook.MEDIUM_FEE() || fee == hook.HIGH_FEE()
                    || fee == hook.VERY_HIGH_FEE(),
                "fee not a valid tier"
            );
            assertGe(fee, hook.MIN_FEE());
            assertLe(fee, hook.MAX_FEE());
        } catch (bytes memory err) {
            assertEq(bytes4(err), DynamicLPFeesHook.PoolPriceNotSet.selector, "unexpected revert reason");
        }
    }

    // Determinism: two consecutive reads in the same state must be identical.
    function invariant_previewFeeDeterministic() public view {
        try hook.previewFee(poolId) returns (uint24 f1, uint256 b1) {
            (uint24 f2, uint256 b2) = hook.previewFee(poolId);
            assertEq(f1, f2);
            assertEq(b1, b2);
        } catch {
            // reverting state is fine for this invariant
        }
    }

    // Pool price must stay within the valid Uniswap sqrt-price band at all times.
    function invariant_poolPriceWithinTickBounds() public view {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        assertGe(sqrtPriceX96, TickMath.MIN_SQRT_PRICE);
        assertLe(sqrtPriceX96, TickMath.MAX_SQRT_PRICE);
    }

    // ---- helpers ----

    function _refConvert(uint160 s) internal pure returns (uint256) {
        uint256 intermediate = FullMath.mulDiv(uint256(s), uint256(s), 1 << 96);
        return FullMath.mulDiv(intermediate, 1e20, 1 << 96);
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

        MockERC20(WETH).mint(address(this), 1_000_000 ether);
        MockERC20(USDC).mint(address(this), 1_000_000_000e6);
        MockERC20(WETH).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(USDC).approve(address(modifyLiquidityRouter), type(uint256).max);

        currency0 = Currency.wrap(WETH);
        currency1 = Currency.wrap(USDC);
    }

    function _deployHook() internal {
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("DynamicLPFeesHook.sol", abi.encode(manager, WETH, USDC, PRICE_FEED, SEQUENCER_FEED), hookAddress);
        hook = DynamicLPFeesHook(hookAddress);
    }

    function _seedWideLiquidity() internal {
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(poolId);
        int24 spacing = key.tickSpacing;
        // wide range so price can move substantially before liquidity runs out
        int24 lower = ((tick - 6000) / spacing) * spacing;
        int24 upper = ((tick + 6000) / spacing) * spacing;

        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), 100 ether, 350_000e6
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: int128(liq), salt: bytes32(0)}),
            ZERO_BYTES
        );
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
