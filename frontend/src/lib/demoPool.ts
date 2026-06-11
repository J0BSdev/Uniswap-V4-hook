import { deviationBps, feeForDeviationBps, feePipsToPercent } from "./feeMath";

// A lightweight constant-product (x*y=k) model of the WETH/USDC pool used for the
// DEMO mode. token0 = WETH, token1 = USDC. Pool price = USDC reserve / WETH reserve.
export interface PoolReserves {
  weth: number; // WETH units (human)
  usdc: number; // USDC units (human)
}

export type SwapDir = "WETH_TO_USDC" | "USDC_TO_WETH";

export interface SwapQuote {
  amountIn: number;
  amountOut: number;
  tokenIn: "WETH" | "USDC";
  tokenOut: "WETH" | "USDC";
  feePips: number;
  feePercent: number;
  feeAmount: number; // in tokenIn units
  deviationBpsBefore: number;
  deviationBpsAfter: number;
  poolPriceBefore: number;
  poolPriceAfter: number;
  priceImpactPct: number;
  newReserves: PoolReserves;
}

export function poolPrice(r: PoolReserves): number {
  if (r.weth <= 0) return 0;
  return r.usdc / r.weth;
}

/** Synthetic x*y=k reserves for quoting at a given spot ETH/USD (no on-chain LP needed). */
export function virtualReservesFromPrice(poolPriceUsd: number, weth = 1000): PoolReserves {
  const p = Number.isFinite(poolPriceUsd) && poolPriceUsd > 0 ? poolPriceUsd : 0;
  return { weth, usdc: p * weth };
}

export const INITIAL_RESERVES: PoolReserves = { weth: 1000, usdc: 3_500_000 };
export const INITIAL_ORACLE = 3500;

/**
 * Quotes a swap exactly the way the hook + AMM would: the dynamic fee is computed
 * from the CURRENT deviation (pool vs oracle), then the constant-product curve is
 * applied to the post-fee input.
 */
export function quoteSwap(
  reserves: PoolReserves,
  oraclePrice: number,
  amountIn: number,
  dir: SwapDir
): SwapQuote {
  const priceBefore = poolPrice(reserves);
  const devBefore = deviationBps(priceBefore, oraclePrice);
  const feePips = feeForDeviationBps(devBefore);
  const feePercent = feePipsToPercent(feePips);
  const feeFraction = feePips / 1_000_000;

  const safeAmount = Number.isFinite(amountIn) && amountIn > 0 ? amountIn : 0;
  const feeAmount = safeAmount * feeFraction;
  const amountInAfterFee = safeAmount - feeAmount;

  let newReserves: PoolReserves;
  let amountOut: number;
  let tokenIn: "WETH" | "USDC";
  let tokenOut: "WETH" | "USDC";

  if (dir === "WETH_TO_USDC") {
    tokenIn = "WETH";
    tokenOut = "USDC";
    const k = reserves.weth * reserves.usdc;
    const newWeth = reserves.weth + amountInAfterFee;
    const newUsdc = k / newWeth;
    amountOut = reserves.usdc - newUsdc;
    newReserves = { weth: newWeth, usdc: newUsdc };
  } else {
    tokenIn = "USDC";
    tokenOut = "WETH";
    const k = reserves.weth * reserves.usdc;
    const newUsdc = reserves.usdc + amountInAfterFee;
    const newWeth = k / newUsdc;
    amountOut = reserves.weth - newWeth;
    newReserves = { weth: newWeth, usdc: newUsdc };
  }

  const priceAfter = poolPrice(newReserves);
  const devAfter = deviationBps(priceAfter, oraclePrice);

  // Price impact = how far the swap moved the pool's mid price.
  const priceImpactPct =
    priceBefore > 0 ? Math.abs((priceAfter - priceBefore) / priceBefore) * 100 : 0;

  return {
    amountIn: safeAmount,
    amountOut: Math.max(0, amountOut),
    tokenIn,
    tokenOut,
    feePips,
    feePercent,
    feeAmount,
    deviationBpsBefore: devBefore,
    deviationBpsAfter: devAfter,
    poolPriceBefore: priceBefore,
    poolPriceAfter: priceAfter,
    priceImpactPct,
    newReserves,
  };
}
