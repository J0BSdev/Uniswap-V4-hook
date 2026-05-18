// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LPYieldHook
/// @author Lovro Posel
/// @notice Uniswap v4 hook that charges a *risk-adjusted* swap fee. Big trades against
///         thin pools (or pools that have drifted away from their reference price) pay
///         more, protecting LP yield during high-execution-risk conditions.
/// @dev    Deliberately minimal. No oracles, no external calls. The risk model and the
///         fee policy live in tiny pure libraries so they are easy to swap out.

import {BaseHook} from "../lib/v4-hooks-public/src/base/BaseHook.sol";
  
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {Types} from "./execution-guard/Types.sol";
import {RiskModelLib} from "./execution-guard/RiskModelLib.sol";
import {PolicyLib} from "./execution-guard/PolicyLib.sol";

contract LPYieldHook is BaseHook {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // ─── Errors ──────────────────────────────────────────────────────────────
    error MustUseDynamicFees();

    // ─── Events ──────────────────────────────────────────────────────────────
    event FeeAdjusted(
        PoolId indexed poolId,
        Types.RiskTier tier,
        uint24 feePips,
        uint256 sizeRatioBps,
        uint256 priceDeviationBps,
        uint256 totalScore
    );

    // ─── Per-pool state ──────────────────────────────────────────────────────

    /// @notice Reference sqrt price captured at pool initialization. The risk model
    ///         compares the live price against this to estimate "drift" / volatility.
    mapping(PoolId => uint160) public referenceSqrtPriceX96;

    /// @notice Last fee (in pips, no flag) applied by the hook. Useful for tests / UI.
    mapping(PoolId => uint24) public lastAppliedFee;

    /// @notice Last risk tier picked by the policy.
    mapping(PoolId => Types.RiskTier) public lastTier;

    /// @notice Last full risk score (size + deviation breakdown).
    mapping(PoolId => Types.RiskScore) public lastScore;

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    // ─── Permissions ─────────────────────────────────────────────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Hook callbacks ──────────────────────────────────────────────────────

    /// @dev Pool MUST be opened with `LPFeeLibrary.DYNAMIC_FEE_FLAG`, otherwise the
    ///      override fee returned by `_beforeSwap` would be silently ignored.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFees();
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Snapshot the initial price as the deviation reference.
    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        override
        returns (bytes4)
    {
        referenceSqrtPriceX96[key.toId()] = sqrtPriceX96;
        return BaseHook.afterInitialize.selector;
    }

    /// @dev The hot path: build inputs, score the trade, pick a fee, return it.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        // 1. Gather raw inputs from the live pool state.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        Types.RiskInputs memory inputs = Types.RiskInputs({
            tradeSize: _abs(params.amountSpecified),
            liquidity: liquidity,
            sqrtPriceX96: sqrtPriceX96,
            referenceSqrtPriceX96: referenceSqrtPriceX96[poolId]
        });

        // 2. Run the risk model (pure) and ask the policy for a fee (pure).
        Types.RiskScore memory score = RiskModelLib.computeRiskScore(inputs);
        (uint24 feePips, Types.RiskTier tier) = PolicyLib.decideFee(score.totalScore);

        // 3. Persist for inspection and emit a single event for indexers / UIs.
        lastAppliedFee[poolId] = feePips;
        lastTier[poolId] = tier;
        lastScore[poolId] = score;
        emit FeeAdjusted(poolId, tier, feePips, score.sizeRatioBps, score.priceDeviationBps, score.totalScore);

        // 4. Return the fee with the override flag so the PoolManager uses it for THIS swap only.
        return
            (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feePips | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    /// @dev Absolute value of a v4 amountSpecified (negative = exactInput, positive = exactOutput).
    function _abs(int256 x) private pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
