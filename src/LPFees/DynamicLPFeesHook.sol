// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DynamicLPFeesHook
/// @author Lovro Posel
/// @notice V4 hook that raises LP swap fees when pool price deviates from Chainlink ETH/USD.

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract DynamicLPFeesHook is BaseHook {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // --- Base mainnet ---
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    
    uint24 public constant MIN_FEE = 3000; // 0.3%
    uint24 public constant LOW_FEE = 5000; // 0.5%
    uint24 public constant MEDIUM_FEE = 10000; // 1%
    uint24 public constant HIGH_FEE = 30000; // 3%
    uint24 public constant VERY_HIGH_FEE = 50000; // 5%
    uint24 public constant MAX_FEE = 100000; // 10%

    // --- deviation score thresholds (bps) ---
    uint256 public constant SCORE_LOW = 100; // < 1%
    uint256 public constant SCORE_MEDIUM = 500; // < 5%
    uint256 public constant SCORE_HIGH = 2000; // < 20%

    // Chainlink recommendation: wait after sequencer recovery before using price feeds.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 3600;

    //Max age of ETH/USD oracle answer before reverting.
    uint256 public constant MAX_ORACLE_STALENESS = 3600;

    AggregatorV3Interface public immutable priceFeed;
    AggregatorV3Interface public immutable sequencerUptimeFeed;

    error MustUseDynamicFees();
    error InvalidPoolPair();
    error SequencerDown();
    error GracePeriodNotOver();
    error CurrentOraclePriceNotSet();
    error IncompleteOracleRound();
    error StaleOraclePrice();
    error PoolPriceNotSet();

    /// @notice Emitted on every swap when the dynamic fee is applied.
    event FeeAdjusted(PoolId indexed poolId, uint24 feePips, uint256 priceDeviationBps);

    constructor(IPoolManager _manager) BaseHook(_manager) {
        priceFeed = AggregatorV3Interface(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);
        sequencerUptimeFeed = AggregatorV3Interface(0xBCF85224fc0756B9Fa45aA7892530B47e10b6433);
    }

    // Live fee for the next swap — same logic as _beforeSwap, callable by the frontend.
    function previewFee(PoolId poolId) external view returns (uint24 feePips, uint256 priceDeviationBps) {
        return getFee(poolId);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
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

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFees();
        if (Currency.unwrap(key.currency0) != WETH || Currency.unwrap(key.currency1) != USDC) {
            revert InvalidPoolPair();
        }
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        (uint24 fee, uint256 priceDeviationBps) = getFee(poolId);
        emit FeeAdjusted(poolId, fee, priceDeviationBps);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function getFee(PoolId poolId) internal view returns (uint24 feePips, uint256 priceDeviationBps) {
        _checkSequencer();
        uint256 oraclePrice = _readOraclePrice();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolPriceNotSet();

        uint256 poolPrice = _getPoolPriceFromSqrtPriceX96(sqrtPriceX96);
        if (poolPrice == 0) revert PoolPriceNotSet();

        uint256 diff = poolPrice > oraclePrice ? poolPrice - oraclePrice : oraclePrice - poolPrice;
        priceDeviationBps = diff * 10000 / oraclePrice;

        uint256 totalScore = priceDeviationBps;
        if (totalScore < SCORE_LOW) feePips = LOW_FEE;
        else if (totalScore < SCORE_MEDIUM) feePips = MEDIUM_FEE;
        else if (totalScore < SCORE_HIGH) feePips = HIGH_FEE;
        else feePips = VERY_HIGH_FEE;
        if (feePips < MIN_FEE) feePips = MIN_FEE;
        if (feePips > MAX_FEE) feePips = MAX_FEE;
    }

    // Chainlink L2 pattern: sequencer up + grace period elapsed.
    function _checkSequencer() internal view {
        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD) revert GracePeriodNotOver();
    }

    function _readOraclePrice() internal view returns (uint256 oraclePrice) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        if (answer <= 0) revert CurrentOraclePriceNotSet();
        if (answeredInRound < roundId) revert IncompleteOracleRound();
        if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) revert StaleOraclePrice();
        oraclePrice = uint256(answer);
    }

    // Converts pool sqrt price to Chainlink-compatible 1e8 scale (10^(18-6+8) = 1e20).
    // WETH/USDC pool with token0 = WETH (18 decimals) and token1 = USDC (6 decimals).
    function _getPoolPriceFromSqrtPriceX96(uint160 sqrtPriceX96) internal pure returns (uint256 poolPrice8) {
        uint256 priceRaw = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 192);
        poolPrice8 = priceRaw * 1e20;
    }
}
