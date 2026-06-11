// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// DynamicLPFeesHook — raises LP swap fees when pool price deviates from Chainlink ETH/USD

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

    address internal immutable WETH;
    address internal immutable USDC;
    /// @dev True when WETH is currency0 (Base mainnet); false when USDC is currency0 (Base Sepolia).
    bool internal immutable wethIsCurrency0;

    // Fee tiers in pips (1_000_000 = 100%)
    uint24 public constant MIN_FEE = 3000; // 0.3%
    uint24 public constant LOW_FEE = 5000; // 0.5%
    uint24 public constant MEDIUM_FEE = 10000; // 1%
    uint24 public constant HIGH_FEE = 30000; // 3%
    uint24 public constant VERY_HIGH_FEE = 50000; // 5%
    uint24 public constant MAX_FEE = 100000; // 10%

    // Deviation thresholds in bps (100 bps = 1%)
    uint256 public constant SCORE_LOW = 100;
    uint256 public constant SCORE_MEDIUM = 500;
    uint256 public constant SCORE_HIGH = 2000;

    // Chainlink safety thresholds
    uint256 public constant SEQUENCER_GRACE_PERIOD = 3600; // seconds to wait after sequencer recovery
    uint256 public constant MAX_ORACLE_STALENESS = 3600; // max oracle answer age in seconds

    AggregatorV3Interface public immutable priceFeed; // ETH/USD
    AggregatorV3Interface public immutable sequencerUptimeFeed; // Base sequencer uptime

    error MustUseDynamicFees();
    error InvalidPoolPair();
    error SequencerDown();
    error GracePeriodNotOver();
    error CurrentOraclePriceNotSet();
    error IncompleteOracleRound();
    error StaleOraclePrice();
    error PoolPriceNotSet();

    // riskScoreBps = max(oracle deviation, tradeSize/liquidity) used for the tier
    event FeeAdjusted(PoolId indexed poolId, uint24 feePips, uint256 riskScoreBps);

    constructor(IPoolManager _manager, address _weth, address _usdc, address _priceFeed, address _sequencerFeed)
        BaseHook(_manager)
    {
        WETH = _weth;
        USDC = _usdc;
        wethIsCurrency0 = _weth < _usdc;
        priceFeed = AggregatorV3Interface(_priceFeed);
        sequencerUptimeFeed = AggregatorV3Interface(_sequencerFeed);
    }

    // Oracle deviation only — for the risk gauge (no trade size).
    function previewFee(PoolId poolId) external view returns (uint24 feePips, uint256 priceDeviationBps) {
        return getFee(poolId);
    }

    // Swap-aware preview — same logic as _beforeSwap (USD-normalized size / liquidity).
    function previewFee(PoolId poolId, bool zeroForOne, int256 amountSpecified)
        external
        view
        returns (uint24 feePips, uint256 riskScoreBps)
    {
        return getFee(poolId, zeroForOne, amountSpecified);
    }

    // Which hook callbacks are enabled — deploy address must match via HookMiner
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

    // Pool init validation — must use dynamic fee flag and WETH/USDC pair
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFees();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (!((c0 == WETH && c1 == USDC) || (c0 == USDC && c1 == WETH))) {
            revert InvalidPoolPair();
        }
        return BaseHook.beforeInitialize.selector;
    }

    // Before each swap: compute fee, emit event, return fee with OVERRIDE flag
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        (uint24 fee, uint256 riskScoreBps) = getFee(poolId, params.zeroForOne, params.amountSpecified);
        emit FeeAdjusted(poolId, fee, riskScoreBps);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // Oracle deviation only.
    function getFee(PoolId poolId) internal view returns (uint24 feePips, uint256 riskScoreBps) {
        return _feeFromScore(_priceDeviationBps(poolId));
    }

    // Oracle deviation + USD-normalized trade size / liquidity execution risk.
    function getFee(PoolId poolId, bool zeroForOne, int256 amountSpecified)
        internal
        view
        returns (uint24 feePips, uint256 riskScoreBps)
    {
        uint256 priceScore = _priceDeviationBps(poolId);
        uint256 sizeScore = _sizeRatioBps(poolId, zeroForOne, amountSpecified);
        riskScoreBps = priceScore > sizeScore ? priceScore : sizeScore;
        return _feeFromScore(riskScoreBps);
    }

    function _priceDeviationBps(PoolId poolId) internal view returns (uint256 priceDeviationBps) {
        _checkSequencer();
        uint256 oraclePrice = _readOraclePrice();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolPriceNotSet();

        uint256 poolPrice = _getPoolPriceFromSqrtPriceX96(sqrtPriceX96);
        if (poolPrice == 0) revert PoolPriceNotSet();

        uint256 diff = poolPrice > oraclePrice ? poolPrice - oraclePrice : oraclePrice - poolPrice;
        priceDeviationBps = diff * 10000 / oraclePrice;
    }

    function _sizeRatioBps(PoolId poolId, bool zeroForOne, int256 amountSpecified)
        internal
        view
        returns (uint256 sizeRatioBps)
    {
        if (amountSpecified == 0) return 0;

        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity == 0) return type(uint256).max;

        uint256 tradeSize = _absAmount(amountSpecified);
        uint256 wethEquivalent18 = _tradeWethEquivalent18(poolId, zeroForOne, tradeSize);
        // Saturate on overflow — extreme inputs map to max execution-risk score.
        if (wethEquivalent18 > type(uint256).max / 10_000) return type(uint256).max;
        sizeRatioBps = wethEquivalent18 * 10_000 / uint256(liquidity);
    }

    /// @dev Express input amount as WETH wei (18 dec) at pool spot so WETH/USDC trades are comparable.
    function _tradeWethEquivalent18(PoolId poolId, bool zeroForOne, uint256 tradeSize)
        internal
        view
        returns (uint256 wethEquivalent18)
    {
        if (_isWethInput(zeroForOne)) return tradeSize;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolPriceNotSet();
        uint256 poolPrice8 = _getPoolPriceFromSqrtPriceX96(sqrtPriceX96);
        // USDC (6 dec) → WETH wei: usdcRaw * 1e20 / poolPrice8
        return FullMath.mulDiv(tradeSize, 1e20, poolPrice8);
    }

    function _isWethInput(bool zeroForOne) internal view returns (bool) {
        return wethIsCurrency0 ? zeroForOne : !zeroForOne;
    }

    function _absAmount(int256 amount) internal pure returns (uint256) {
        if (amount >= 0) return uint256(amount);
        // type(int256).min has no positive int256 counterpart; uint256 abs is 2^255.
        if (amount == type(int256).min) return uint256(type(int256).max) + 1;
        return uint256(-amount);
    }

    function _feeFromScore(uint256 totalScore) internal pure returns (uint24 feePips, uint256 riskScoreBps) {
        riskScoreBps = totalScore;
        if (totalScore < SCORE_LOW) feePips = LOW_FEE;
        else if (totalScore < SCORE_MEDIUM) feePips = MEDIUM_FEE;
        else if (totalScore < SCORE_HIGH) feePips = HIGH_FEE;
        else feePips = VERY_HIGH_FEE;
        if (feePips < MIN_FEE) feePips = MIN_FEE;
        if (feePips > MAX_FEE) feePips = MAX_FEE;
    }

    // Ensure Base sequencer is up and grace period has passed (answer 0 = up, 1 = down)
    function _checkSequencer() internal view {
        address feed = address(sequencerUptimeFeed);
        if (feed == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD) revert GracePeriodNotOver();
    }

    // Read Chainlink ETH/USD — must be positive, fresh, and a complete round
    function _readOraclePrice() internal view returns (uint256 oraclePrice) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        if (answer <= 0) revert CurrentOraclePriceNotSet();
        if (answeredInRound < roundId) revert IncompleteOracleRound();
        if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) revert StaleOraclePrice();
        oraclePrice = uint256(answer);
    }

    // sqrtPriceX96 → Chainlink 1e8 scale (1e20 = 1e12 decimal diff + 1e8 chainlink decimals)
    // Done in two FullMath steps so the intermediate never overflows 256 bits across the
    function _getPoolPriceFromSqrtPriceX96(uint160 sqrtPriceX96) internal view returns (uint256 poolPrice8) {
        uint256 intermediate = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        if (wethIsCurrency0) {
            poolPrice8 = FullMath.mulDiv(intermediate, 1e20, 1 << 96);
        } else {
            poolPrice8 = FullMath.mulDiv(1e20, 1 << 96, intermediate);
        }
    }
}
