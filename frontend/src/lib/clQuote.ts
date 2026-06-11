import { poolPriceFromSqrt, WETH_IS_CURRENCY0 } from "../config/contracts";
import { sqrtPriceSlippageLimit } from "./sqrtPrice";
import { deviationBps, feeForDeviationBps, feePipsToPercent } from "./feeMath";
import { getSqrtRatioAtTick } from "./tickMath";
import type { SwapDir, SwapQuote } from "./demoPool";

const Q96 = 1n << 96n;

export interface LivePoolState {
  sqrtPriceX96: bigint;
  liquidity: bigint;
  tickLower: number;
  tickUpper: number;
  poolPrice: number;
  deviationBpsBefore: number;
  oraclePrice: number;
}

function mulDiv(a: bigint, b: bigint, d: bigint): bigint {
  return (a * b) / d;
}

function mulDivRoundingUp(a: bigint, b: bigint, d: bigint): bigint {
  const product = a * b;
  const result = product / d;
  return product % d > 0n ? result + 1n : result;
}

function divRoundingUp(a: bigint, b: bigint): bigint {
  return (a + b - 1n) / b;
}

function getAmount0Delta(sqrtA: bigint, sqrtB: bigint, liquidity: bigint, roundUp: boolean): bigint {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  if (sqrtA === 0n) return 0n;

  const numerator1 = liquidity << 96n;
  const numerator2 = sqrtB - sqrtA;
  const mul = mulDiv(numerator1, numerator2, sqrtB);
  return roundUp ? divRoundingUp(mul, sqrtA) : mul / sqrtA;
}

function getAmount1Delta(sqrtA: bigint, sqrtB: bigint, liquidity: bigint, roundUp: boolean): bigint {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  const numerator = sqrtB - sqrtA;
  const mul = mulDiv(liquidity, numerator, Q96);
  const rem = (liquidity * numerator) % Q96;
  return roundUp && rem > 0n ? mul + 1n : mul;
}

function getNextSqrtPriceFromAmount0RoundingUp(
  sqrtPX96: bigint,
  liquidity: bigint,
  amount: bigint,
  add: boolean
): bigint {
  if (amount === 0n) return sqrtPX96;

  const numerator1 = liquidity << 96n;
  if (add) {
    const product = amount * sqrtPX96;
    if (amount !== 0n && product / amount === sqrtPX96) {
      const denominator = numerator1 + product;
      if (denominator >= numerator1) {
        return mulDivRoundingUp(numerator1, sqrtPX96, denominator);
      }
    }
    return divRoundingUp(numerator1, numerator1 / sqrtPX96 + amount);
  }

  const product = amount * sqrtPX96;
  if (amount !== 0n && product / amount !== sqrtPX96) throw new Error("PriceOverflow");
  if (numerator1 <= product) throw new Error("PriceOverflow");
  const denominator = numerator1 - product;
  return mulDivRoundingUp(numerator1, sqrtPX96, denominator);
}

function getNextSqrtPriceFromAmount1RoundingDown(
  sqrtPX96: bigint,
  liquidity: bigint,
  amount: bigint,
  add: boolean
): bigint {
  if (add) {
    const quotient =
      amount <= (1n << 160n) - 1n
        ? (amount << 96n) / liquidity
        : mulDiv(amount, Q96, liquidity);
    return sqrtPX96 + quotient;
  }

  const quotient =
    amount <= (1n << 160n) - 1n
      ? divRoundingUp(amount << 96n, liquidity)
      : mulDivRoundingUp(amount, Q96, liquidity);
  if (sqrtPX96 <= quotient) throw new Error("NotEnoughLiquidity");
  return sqrtPX96 - quotient;
}

function getNextSqrtPriceFromInput(
  sqrtPX96: bigint,
  liquidity: bigint,
  amountIn: bigint,
  zeroForOne: boolean
): bigint {
  if (sqrtPX96 === 0n || liquidity === 0n) throw new Error("InvalidPriceOrLiquidity");
  return zeroForOne
    ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountIn, true)
    : getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountIn, true);
}

/** Swap limit from exact input size — never fall back to MIN/MAX sqrt. */
export function sqrtPriceLimitForExactIn(
  sqrtPriceX96: bigint,
  liquidity: bigint,
  amountInWei: bigint,
  zeroForOne: boolean
): bigint {
  const slippageCap = sqrtPriceSlippageLimit(sqrtPriceX96, zeroForOne, 800);

  if (liquidity === 0n || amountInWei === 0n || sqrtPriceX96 <= 0n) {
    return slippageCap;
  }

  try {
    const sqrtNext = getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountInWei, zeroForOne);
    if (zeroForOne) {
      // Tighter floor: closer to current sqrt (max of expected vs slippage cap).
      return sqrtNext > slippageCap ? sqrtNext : slippageCap;
    }
    return sqrtNext < slippageCap ? sqrtNext : slippageCap;
  } catch {
    return slippageCap;
  }
}

function toWei(amount: number, decimals: number): bigint {
  const scale = 10 ** decimals;
  return BigInt(Math.floor(amount * scale));
}

function fromWei(amount: bigint, decimals: number): number {
  return Number(amount) / 10 ** decimals;
}

function absAmountWei(amount: bigint): bigint {
  if (amount >= 0n) return amount;
  const min = -(1n << 255n);
  if (amount === min) return 1n << 255n;
  return -amount;
}

/** Match hook _tradeWethEquivalent18 + _sizeRatioBps (WETH-normalized, not raw wei). */
function sizeRatioBps(
  liquidity: bigint,
  amountInWei: bigint,
  zeroForOne: boolean,
  poolPrice: number
): number {
  if (liquidity === 0n) return Number.MAX_SAFE_INTEGER;
  const tradeSize = absAmountWei(amountInWei);
  const isWethIn = WETH_IS_CURRENCY0 ? zeroForOne : !zeroForOne;
  const poolPrice8 = BigInt(Math.max(1, Math.round(poolPrice * 1e8)));
  const wethEquivalent18 = isWethIn ? tradeSize : (tradeSize * 10n ** 20n) / poolPrice8;
  const maxMul = (1n << 256n) - 1n;
  if (wethEquivalent18 > maxMul / 10_000n) return Number.MAX_SAFE_INTEGER;
  return Number((wethEquivalent18 * 10_000n) / liquidity);
}

function riskScoreBps(
  deviationBpsBefore: number,
  liquidity: bigint,
  amountInWei: bigint,
  zeroForOne: boolean,
  poolPrice: number
): number {
  return Math.max(deviationBpsBefore, sizeRatioBps(liquidity, amountInWei, zeroForOne, poolPrice));
}

/**
 * Quotes a swap against live concentrated liquidity.
 * Fee mirrors on-chain getFee: max(oracle deviation, tradeSize/liquidity).
 */
export function quoteSwapLive(state: LivePoolState, amountIn: number, dir: SwapDir): SwapQuote {
  const safeAmount = Number.isFinite(amountIn) && amountIn > 0 ? amountIn : 0;
  const wethToUsdc = dir === "WETH_TO_USDC";
  const zeroForOne = WETH_IS_CURRENCY0 ? wethToUsdc : !wethToUsdc;
  const tokenIn = wethToUsdc ? "WETH" : "USDC";
  const tokenOut = wethToUsdc ? "USDC" : "WETH";
  const inDecimals = tokenIn === "WETH" ? 18 : 6;
  const outDecimals = tokenOut === "WETH" ? 18 : 6;

  const priceBefore = state.poolPrice;
  const amountInWei = safeAmount > 0 ? toWei(safeAmount, inDecimals) : 0n;
  const scoreBps = riskScoreBps(
    state.deviationBpsBefore,
    state.liquidity,
    amountInWei,
    zeroForOne,
    state.poolPrice
  );
  const feePips = feeForDeviationBps(scoreBps);
  const feePercent = feePipsToPercent(feePips);
  const feeFraction = feePips / 1_000_000;
  const feeAmount = safeAmount * feeFraction;

  if (safeAmount === 0 || state.liquidity === 0n) {
    return emptyQuote(safeAmount, tokenIn, tokenOut, feePips, feePercent, feeAmount, scoreBps, priceBefore);
  }
  const feeWei = BigInt(Math.floor(Number(amountInWei) * feeFraction));
  const amountInAfterFee = amountInWei - feeWei;

  const sqrtLower = getSqrtRatioAtTick(state.tickLower);
  const sqrtUpper = getSqrtRatioAtTick(state.tickUpper);
  let sqrtP = state.sqrtPriceX96;
  let sqrtNext: bigint;

  try {
    sqrtNext = getNextSqrtPriceFromInput(sqrtP, state.liquidity, amountInAfterFee, zeroForOne);
    if (zeroForOne) {
      sqrtNext = sqrtNext < sqrtLower ? sqrtLower : sqrtNext;
    } else {
      sqrtNext = sqrtNext > sqrtUpper ? sqrtUpper : sqrtNext;
    }
  } catch {
    return emptyQuote(safeAmount, tokenIn, tokenOut, feePips, feePercent, feeAmount, scoreBps, priceBefore);
  }

  let amountOutWei: bigint;
  try {
    amountOutWei = zeroForOne
      ? getAmount1Delta(sqrtNext, sqrtP, state.liquidity, false)
      : getAmount0Delta(sqrtP, sqrtNext, state.liquidity, false);
  } catch {
    return emptyQuote(safeAmount, tokenIn, tokenOut, feePips, feePercent, feeAmount, scoreBps, priceBefore);
  }

  const amountOut = fromWei(amountOutWei, outDecimals);
  const priceAfter = poolPriceFromSqrt(sqrtNext);
  const devAfter = deviationBps(priceAfter, state.oraclePrice);
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
    deviationBpsBefore: scoreBps,
    deviationBpsAfter: devAfter,
    poolPriceBefore: priceBefore,
    poolPriceAfter: priceAfter,
    priceImpactPct,
    newReserves: { weth: 0, usdc: 0 },
  };
}

function emptyQuote(
  amountIn: number,
  tokenIn: "WETH" | "USDC",
  tokenOut: "WETH" | "USDC",
  feePips: number,
  feePercent: number,
  feeAmount: number,
  scoreBps: number,
  poolPrice: number
): SwapQuote {
  return {
    amountIn,
    amountOut: 0,
    tokenIn,
    tokenOut,
    feePips,
    feePercent,
    feeAmount,
    deviationBpsBefore: scoreBps,
    deviationBpsAfter: scoreBps,
    poolPriceBefore: poolPrice,
    poolPriceAfter: poolPrice,
    priceImpactPct: 0,
    newReserves: { weth: 0, usdc: 0 },
  };
}
