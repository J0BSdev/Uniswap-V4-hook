#!/usr/bin/env node
/**
 * Offline parity check: frontend feeMath vs reference Solidity formulas.
 * Run: node frontend/scripts/fee-parity-check.mjs
 */
import {
  sizeRatioBps,
  wethEquivalent18,
  riskScoreBps,
  feeForDeviationBps,
} from "../src/lib/feeMath.ts";

const ORACLE = 3500;
const POOL = 3500;
const LIQ = 263584689741913849n;

function assert(cond, msg) {
  if (!cond) {
    console.error("FAIL:", msg);
    process.exit(1);
  }
}

// USD-equivalent: 0.01 WETH ≈ 35 USDC @ $3500
const weth001 = 10n ** 16n;
const usdc35 = 35n * 10n ** 6n;
const scoreW = sizeRatioBps(LIQ, weth001, true, POOL, true);
const scoreU = sizeRatioBps(LIQ, usdc35, false, POOL, true);
assert(Math.abs(scoreW - scoreU) <= 2, `USD parity: WETH=${scoreW} USDC=${scoreU}`);

// Old raw-wei bug: WETH would dominate
const rawW = Number((weth001 * 10000n) / LIQ);
const rawU = Number((usdc35 * 10000n) / LIQ);
assert(rawW > rawU * 1000, "sanity: raw wei asymmetric");
assert(scoreU >= rawU, "USDC normalized score uses WETH-equiv not raw");

// Sepolia order (USDC token0): USDC in = zeroForOne true
const scoreSepUsdc = sizeRatioBps(LIQ, usdc35, true, POOL, false);
const scoreSepWeth = sizeRatioBps(LIQ, weth001, false, POOL, false);
assert(Math.abs(scoreSepUsdc - scoreSepWeth) <= 2, "Sepolia token order parity");

// Double size → double score
const s1 = sizeRatioBps(LIQ, usdc35, false, POOL, true);
const s2 = sizeRatioBps(LIQ, usdc35 * 2n, false, POOL, true);
assert(Math.abs(s2 - s1 * 2) <= 1, "linear size scaling");

// riskScore max(deviation, size)
const dev = 50;
const risk = riskScoreBps(dev, LIQ, weth001, true, POOL, true);
assert(risk === Math.max(dev, scoreW), "risk = max(dev, size)");

assert(feeForDeviationBps(0) === 5000, "zero dev → LOW tier");

console.log("fee-parity-check: all passed");
