# DynamicLPFeesHook

DynamicLPFeesHook is a work-in-progress Uniswap v4 hook focused on protecting liquidity providers by dynamically adjusting swap fees based on execution risk.

Instead of using a fixed fee for every swap, the hook compares the current Uniswap pool price with a Chainlink ETH/USD reference price and also considers trade size relative to pool liquidity. When risk increases, the hook raises the LP fee so liquidity providers are better compensated.

## Vision

Liquidity providers are exposed to higher risk when pool prices move away from fair market value or when large trades hit thin liquidity. Static fee pools do not react to these conditions.

This hook is designed to make fees more adaptive:

* low risk swaps pay a lower fee
* higher risk swaps pay a higher fee
* LPs earn more when execution risk increases
* the pool becomes more resilient during volatile or abnormal market conditions

## How It Works

Before each swap, the hook calculates a risk score using two main signals:

1. **Pool price vs Chainlink price**

The hook reads the current Uniswap pool price and compares it with the Chainlink ETH/USD reference price.

If the pool price is close to the oracle price, the swap is considered lower risk.

If the pool price deviates significantly from the oracle price, the swap is considered higher risk.

2. **Trade size vs pool liquidity**

The hook also compares the swap size with the current pool liquidity.

A larger trade relative to available liquidity increases the risk score.

The final risk score is then used to select a dynamic fee tier.

## Fee Tiers

The hook currently uses simple fee tiers:

* low risk → 0.5%
* medium risk → 1%
* high risk → 3%
* very high risk → 5%

The fee is returned to Uniswap v4 using the dynamic fee override mechanism.

## Main Features

* Uniswap v4 `beforeSwap` hook
* Dynamic LP fee calculation
* Chainlink ETH/USD oracle integration
* Base sequencer uptime check
* Oracle freshness and incomplete round protection
* Pool price calculation from `sqrtPriceX96`
* Trade size / liquidity risk scoring
* Dynamic-fee-only pool validation
* WETH/USDC pool validation
* Frontend-friendly `previewFee` functions
* `FeeAdjusted` event for tracking fee changes

## Why This Project

Most AMM pools use static fee tiers, even though swap risk changes constantly.

A small swap in a healthy pool is not the same as a large swap during high deviation or low liquidity conditions.

DynamicLPFeesHook experiments with a more adaptive model where LPs are compensated based on real execution risk.

The goal is not to block trading by default, but to make liquidity provision more risk-aware.

## Current Status

The project is in active development.

The current implementation focuses on:

* comparing Uniswap pool price against Chainlink ETH/USD
* calculating deviation in basis points
* measuring trade size relative to liquidity
* assigning dynamic fee tiers
* validating oracle and sequencer safety
* testing safe, risky and edge-case scenarios

## Roadmap

* Improve liquidity-aware risk scoring
* Add more precise price impact modeling
* Add optional TWAP or volatility-based scoring
* Add gas benchmarks
* Expand test coverage
* Explore multi-pool and multi-oracle support


