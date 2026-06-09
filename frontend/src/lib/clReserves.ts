import { WETH_IS_CURRENCY0 } from "../config/contracts";
import type { PoolReserves } from "./demoPool";
import { getSqrtRatioAtTick } from "./tickMath";

const Q96 = 1n << 96n;

function mulDiv(a: bigint, b: bigint, d: bigint): bigint {
  return (a * b) / d;
}

function amount0ForLiquidity(sqrtA: bigint, sqrtB: bigint, liquidity: bigint): bigint {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  return mulDiv(mulDiv(liquidity << 96n, sqrtB - sqrtA, sqrtB), 1n, sqrtA);
}

function amount1ForLiquidity(sqrtA: bigint, sqrtB: bigint, liquidity: bigint): bigint {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  return mulDiv(liquidity, sqrtB - sqrtA, Q96);
}

/** Token amounts currently sitting in a concentrated position (mirrors LiquidityAmounts). */
export function reservesFromLiquidity(
  liquidity: bigint,
  sqrtPriceX96: bigint,
  tickLower: number,
  tickUpper: number
): PoolReserves {
  if (liquidity === 0n) return { weth: 0, usdc: 0 };

  const sqrtA = getSqrtRatioAtTick(tickLower);
  const sqrtB = getSqrtRatioAtTick(tickUpper);
  const sqrtP = sqrtPriceX96;

  let amount0 = 0n;
  let amount1 = 0n;

  if (sqrtP <= sqrtA) {
    amount0 = amount0ForLiquidity(sqrtA, sqrtB, liquidity);
  } else if (sqrtP < sqrtB) {
    amount0 = amount0ForLiquidity(sqrtP, sqrtB, liquidity);
    amount1 = amount1ForLiquidity(sqrtA, sqrtP, liquidity);
  } else {
    amount1 = amount1ForLiquidity(sqrtA, sqrtB, liquidity);
  }

  const wethRaw = WETH_IS_CURRENCY0 ? amount0 : amount1;
  const usdcRaw = WETH_IS_CURRENCY0 ? amount1 : amount0;
  return {
    weth: Number(wethRaw) / 1e18,
    usdc: Number(usdcRaw) / 1e6,
  };
}
