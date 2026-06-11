// Mirror of DynamicLPFeesHook fee logic. Keep in sync with the Solidity contract.
// Fees are in pips (hundredths of a bip); 1_000_000 pips = 100%.

export const FEE = {
  MIN: 3000, // 0.3%
  LOW: 5000, // 0.5%
  MEDIUM: 10000, // 1%
  HIGH: 30000, // 3%
  VERY_HIGH: 50000, // 5%
  MAX: 100000, // 10%
} as const;

// Deviation thresholds in bps (100 bps = 1%).
export const SCORE = {
  LOW: 100,
  MEDIUM: 500,
  HIGH: 2000,
} as const;

export type Tier = "LOW" | "MEDIUM" | "HIGH" | "VERY_HIGH";

export interface TierInfo {
  tier: Tier;
  label: string;
  feePips: number;
  /** color token used across the UI for this risk level */
  accent: string;
}

export const TIERS: Record<Tier, TierInfo> = {
  LOW: { tier: "LOW", label: "Low risk", feePips: FEE.LOW, accent: "#39d98a" },
  MEDIUM: { tier: "MEDIUM", label: "Elevated", feePips: FEE.MEDIUM, accent: "#f5c451" },
  HIGH: { tier: "HIGH", label: "High risk", feePips: FEE.HIGH, accent: "#ff8a3d" },
  VERY_HIGH: { tier: "VERY_HIGH", label: "Extreme", feePips: FEE.VERY_HIGH, accent: "#ff4d5e" },
};

/** Maps a price-deviation (in bps) to the fee tier, exactly like the contract. */
export function tierForDeviationBps(bps: number): Tier {
  if (bps < SCORE.LOW) return "LOW";
  if (bps < SCORE.MEDIUM) return "MEDIUM";
  if (bps < SCORE.HIGH) return "HIGH";
  return "VERY_HIGH";
}

/** Full fee computation matching getFee(): tier select + min/max clamp. */
export function feeForDeviationBps(bps: number): number {
  let fee = TIERS[tierForDeviationBps(bps)].feePips;
  if (fee < FEE.MIN) fee = FEE.MIN;
  if (fee > FEE.MAX) fee = FEE.MAX;
  return fee;
}

/** Absolute deviation between pool price and oracle price, in bps. */
export function deviationBps(poolPrice: number, oraclePrice: number): number {
  if (oraclePrice <= 0) return 0;
  const diff = Math.abs(poolPrice - oraclePrice);
  return Math.floor((diff * 10000) / oraclePrice);
}

/** pips -> percent string, e.g. 30000 -> "3%". */
export function feePipsToPercent(pips: number): number {
  return pips / 10000;
}

/** Progress 0..1 of where a deviation sits across the full tier range (for gauges). */
export function deviationProgress(bps: number): number {
  const max = SCORE.HIGH * 1.5; // 3000 bps caps the gauge visually
  return Math.min(1, bps / max);
}

/** Match hook _isWethInput — WETH is token0 on Base mainnet fork. */
export function isWethInput(zeroForOne: boolean, wethIsCurrency0 = true): boolean {
  return wethIsCurrency0 ? zeroForOne : !zeroForOne;
}

/** Match hook _tradeWethEquivalent18 (pool spot, 1e8 USD scale). */
export function wethEquivalent18(
  amountInWei: bigint,
  zeroForOne: boolean,
  poolPrice: number,
  wethIsCurrency0 = true
): bigint {
  const tradeSize = amountInWei < 0n ? -amountInWei : amountInWei;
  if (isWethInput(zeroForOne, wethIsCurrency0)) return tradeSize;
  const poolPrice8 = BigInt(Math.max(1, Math.round(poolPrice * 1e8)));
  return (tradeSize * 10n ** 20n) / poolPrice8;
}

/** Match hook _sizeRatioBps — WETH-normalized, not raw wei. */
export function sizeRatioBps(
  liquidity: bigint,
  amountInWei: bigint,
  zeroForOne: boolean,
  poolPrice: number,
  wethIsCurrency0 = true
): number {
  if (liquidity === 0n) return Number.MAX_SAFE_INTEGER;
  const wethEquivalent = wethEquivalent18(amountInWei, zeroForOne, poolPrice, wethIsCurrency0);
  const maxMul = (1n << 256n) - 1n;
  if (wethEquivalent > maxMul / 10_000n) return Number.MAX_SAFE_INTEGER;
  return Number((wethEquivalent * 10_000n) / liquidity);
}

/** Match hook getFee swap path: max(deviation, normalized size/liquidity). */
export function riskScoreBps(
  deviationBpsBefore: number,
  liquidity: bigint,
  amountInWei: bigint,
  zeroForOne: boolean,
  poolPrice: number,
  wethIsCurrency0 = true
): number {
  return Math.max(
    deviationBpsBefore,
    sizeRatioBps(liquidity, amountInWei, zeroForOne, poolPrice, wethIsCurrency0)
  );
}
