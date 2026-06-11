#!/usr/bin/env node
/**
 * Offline parity: frontend feeMath vs hook price/deviation/tier math.
 * Run: node frontend/scripts/fee-parity-check.mjs
 */
import {
  deviationBps,
  deviationBpsFromPrice8,
  feeForDeviationBps,
  poolPrice8FromSqrt,
  SCORE,
  FEE,
} from "../src/lib/feeMath.ts";

function assert(cond, msg) {
  if (!cond) {
    console.error("FAIL:", msg);
    process.exit(1);
  }
}

function sqrtBigInt(x) {
  if (x <= 0n) return 0n;
  let z = (x + 1n) / 2n;
  let y = x;
  while (z < y) {
    y = z;
    z = (x / z + z) / 2n;
  }
  return y;
}

function sqrtForMainnet(usd) {
  const oracle8 = BigInt(Math.round(usd * 1e8));
  const q192 = 1n << 192n;
  return sqrtBigInt((oracle8 * q192) / 10n ** 20n);
}

function sqrtForSepolia(usd) {
  const oracle8 = BigInt(Math.round(usd * 1e8));
  const q192 = 1n << 192n;
  return sqrtBigInt((10n ** 26n * q192) / (oracle8 * 10n ** 6n));
}

// --- tier / deviation (human float) ---
const pool = 1682;
const oracle = 1682;
assert(deviationBps(pool, oracle) === 0, "aligned → 0 bps");
assert(feeForDeviationBps(0) === FEE.LOW, "zero dev → LOW");

const offBps = deviationBps(1682 * 1.03, oracle);
assert(offBps >= 300 && offBps <= 301, `3% off → ~300 bps, got ${offBps}`);
assert(feeForDeviationBps(offBps) === FEE.MEDIUM, "~3% dev → MEDIUM");

// --- poolPrice8FromSqrt round-trip (mainnet WETH0) ---
for (const usd of [1682, 3500, 10000]) {
  const sqrt = sqrtForMainnet(usd);
  const price8 = poolPrice8FromSqrt(sqrt, true);
  const oracle8 = BigInt(Math.round(usd * 1e8));
  const diff = price8 > oracle8 ? price8 - oracle8 : oracle8 - price8;
  assert(diff <= 2n, `${usd} USD round-trip within 2 wei, diff=${diff}`);
  assert(deviationBpsFromPrice8(price8, oracle8) <= 1, `${usd} self-deviation ~0`);
}

// --- tier boundaries ---
assert(feeForDeviationBps(SCORE.LOW - 1) === FEE.LOW);
assert(feeForDeviationBps(SCORE.LOW) === FEE.MEDIUM);
assert(feeForDeviationBps(SCORE.MEDIUM - 1) === FEE.MEDIUM);
assert(feeForDeviationBps(SCORE.MEDIUM) === FEE.HIGH);
assert(feeForDeviationBps(SCORE.HIGH - 1) === FEE.HIGH);
assert(feeForDeviationBps(SCORE.HIGH) === FEE.VERY_HIGH);

// --- Sepolia order (USDC token0) inverts formula ---
{
  const usd = 3500;
  const oracle8 = BigInt(usd * 1e8);
  const sqrt = sqrtForSepolia(usd);
  const price8 = poolPrice8FromSqrt(sqrt, false);
  const diff = price8 > oracle8 ? price8 - oracle8 : oracle8 - price8;
  assert(diff <= 2n, `Sepolia ${usd} round-trip, diff=${diff}`);
}

console.log("fee-parity-check: all passed");
