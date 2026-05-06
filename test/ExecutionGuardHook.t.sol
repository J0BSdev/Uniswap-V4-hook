// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ExecutionGuardHook} from "../src/ExecutionGuardHook.sol";
import {Types} from "../src/execution-guard/Types.sol";
import {PolicyLib} from "../src/execution-guard/PolicyLib.sol";

/// @notice Three scenarios: small / medium / large trade against the same pool.
///         Verifies that ExecutionGuardHook charges Low / Medium / High fees respectively.
contract ExecutionGuardHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolId;

    ExecutionGuardHook hook;
    PoolId poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Deterministic hook address that encodes the permission flags we declared.
        address hookAddress =
            address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));
        deployCodeTo("ExecutionGuardHook.sol", abi.encode(manager), hookAddress);
        hook = ExecutionGuardHook(hookAddress);

        // Pool MUST be opened as dynamic-fee for the hook's override fee to take effect.
        (key,) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        poolId = key.toId();

        // Seed liquidity. We use a fixed L = 100e18 so the size/liquidity ratio in the
        // risk model is easy to predict from the trade sizes below.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // ─── Scenario 1: small trade -> LOW fee ──────────────────────────────────
    function test_smallTrade_chargesLowFee() public {
        // 0.0001 ether against L = 100e18 -> sizeRatioBps ≈ 0.01 -> Low tier.
        _swap(-0.0001 ether);

        assertEq(uint8(hook.lastTier(poolId)), uint8(Types.RiskTier.Low), "expected Low tier");
        assertEq(hook.lastAppliedFee(poolId), PolicyLib.FEE_LOW, "expected 0.3% fee");
    }

    // ─── Scenario 2: medium trade -> MEDIUM fee ──────────────────────────────
    function test_mediumTrade_chargesMediumFee() public {
        // 2 ether vs L = 100e18 -> sizeRatioBps = 200 (between 100 and 500) -> Medium.
        _swap(-2 ether);

        assertEq(uint8(hook.lastTier(poolId)), uint8(Types.RiskTier.Medium), "expected Medium tier");
        assertEq(hook.lastAppliedFee(poolId), PolicyLib.FEE_MEDIUM, "expected 0.7% fee");
    }

    // ─── Scenario 3: large trade -> HIGH fee ─────────────────────────────────
    function test_largeTrade_chargesHighFee() public {
        // 8 ether vs L = 100e18 -> sizeRatioBps = 800 (>= 500) -> High tier.
        _swap(-8 ether);

        assertEq(uint8(hook.lastTier(poolId)), uint8(Types.RiskTier.High), "expected High tier");
        assertEq(hook.lastAppliedFee(poolId), PolicyLib.FEE_HIGH, "expected 1.2% fee");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _swap(int256 amountSpecified) internal {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap(key, params, settings, ZERO_BYTES);

        // Sanity log so it's easy to eyeball the policy output during runs.
        Types.RiskScore memory s = _readScore();
        console.log("sizeRatioBps     :", s.sizeRatioBps);
        console.log("priceDeviationBps:", s.priceDeviationBps);
        console.log("totalScore       :", s.totalScore);
        console.log("appliedFee (pips):", hook.lastAppliedFee(poolId));
    }

    function _readScore() internal view returns (Types.RiskScore memory s) {
        (s.sizeRatioBps, s.priceDeviationBps, s.totalScore) = hook.lastScore(poolId);
    }
}
