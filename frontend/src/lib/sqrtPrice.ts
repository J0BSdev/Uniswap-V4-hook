import { WETH_IS_CURRENCY0 } from "../config/contracts";

const Q192 = 1n << 192n;

/** Match NetworkConfig.sqrtPriceFromOracle — sqrtPriceX96 for a target ETH/USD (human units). */
export function sqrtPriceFromTargetUsd(targetUsd: number): bigint {
  const oraclePrice8 = BigInt(Math.round(Math.max(100, targetUsd) * 1e8));
  let target: bigint;
  if (WETH_IS_CURRENCY0) {
    target = (oraclePrice8 * Q192) / 10n ** 20n;
  } else {
    target = (10n ** 26n * Q192) / (oraclePrice8 * 10n ** 6n);
  }
  return sqrtBigInt(target);
}

function sqrtBigInt(x: bigint): bigint {
  if (x <= 0n) return 0n;
  let z = (x + 1n) / 2n;
  let y = x;
  while (z < y) {
    y = z;
    z = (x / z + z) / 2n;
  }
  return y;
}

/** Uniswap V4 swap limit: stop when pool spot reaches targetUsd. */
export function sqrtPriceLimitForTarget(targetUsd: number, zeroForOne: boolean): bigint {
  const targetSqrt = sqrtPriceFromTargetUsd(targetUsd);
  const MIN = 4295128739n;
  const MAX = 1461446703485210103287273052203988822378723970342n;
  if (zeroForOne) return targetSqrt > MIN + 1n ? targetSqrt : MIN + 1n;
  return targetSqrt < MAX - 1n ? targetSqrt : MAX - 1n;
}
