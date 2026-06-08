import { useReadContracts } from "wagmi";
import { encodePacked, keccak256, toHex, type Hex } from "viem";
import { BASE, ENV, IS_DEMO } from "../config/contracts";
import { dynamicLpFeesHookAbi } from "../abi/dynamicLpFeesHook";
import { aggregatorAbi, poolManagerAbi } from "../abi/external";

export interface LiveFeeSnapshot {
  configured: boolean;
  loading: boolean;
  error?: string;
  feePips?: number;
  deviationBps?: number;
  oraclePrice?: number;
  poolPrice?: number;
}

// v4 PoolManager: pools mapping lives at storage slot 6.
const POOLS_SLOT = 6n;

function poolStateSlot(poolId: Hex): Hex {
  return keccak256(encodePacked(["bytes32", "bytes32"], [poolId, toHex(POOLS_SLOT, { size: 32 })]));
}

// sqrtPriceX96 -> Chainlink 1e8 price, matching the hook's two-step FullMath conversion.
function poolPriceFromSqrt(sqrtPriceX96: bigint): number {
  const Q96 = 1n << 96n;
  const intermediate = (sqrtPriceX96 * sqrtPriceX96) / Q96;
  const price8 = (intermediate * 10n ** 20n) / Q96;
  return Number(price8) / 1e8;
}

/**
 * Reads the live fee, oracle price, and pool price directly from Base when a hook
 * address + pool id are configured. Returns `configured: false` in demo mode.
 */
export function useLiveFee(pollMs = 8000): LiveFeeSnapshot {
  const configured = !IS_DEMO && !!ENV.hookAddress && !!ENV.poolId;
  const poolId = ENV.poolId as Hex;

  const { data, isLoading, error } = useReadContracts({
    contracts: [
      {
        address: ENV.hookAddress as `0x${string}`,
        abi: dynamicLpFeesHookAbi,
        functionName: "previewFee",
        args: [poolId],
      },
      {
        address: BASE.ethUsdFeed,
        abi: aggregatorAbi,
        functionName: "latestRoundData",
      },
      {
        address: BASE.poolManager,
        abi: poolManagerAbi,
        functionName: "extsload",
        args: [configured ? poolStateSlot(poolId) : ("0x".padEnd(66, "0") as Hex)],
      },
    ],
    query: {
      enabled: configured,
      refetchInterval: pollMs,
      refetchOnWindowFocus: true,
    },
  });

  if (!configured) return { configured: false, loading: false };
  if (isLoading) return { configured: true, loading: true };
  if (error) return { configured: true, loading: false, error: error.message };

  const previewRes = data?.[0];
  const oracleRes = data?.[1];
  const slotRes = data?.[2];

  // previewFee reverts on bad oracle / sequencer states — surface that cleanly.
  if (previewRes?.status === "failure") {
    return { configured: true, loading: false, error: "previewFee reverted (oracle/sequencer guard)" };
  }

  const [feePips, deviationBps] = (previewRes?.result as readonly [number, bigint]) ?? [undefined, undefined];
  const oracleAnswer = (oracleRes?.result as readonly [bigint, bigint, bigint, bigint, bigint] | undefined)?.[1];
  const slotWord = slotRes?.result as Hex | undefined;

  const oraclePrice = oracleAnswer !== undefined ? Number(oracleAnswer) / 1e8 : undefined;
  let poolPrice: number | undefined;
  if (slotWord) {
    const sqrtPriceX96 = BigInt(slotWord) & ((1n << 160n) - 1n);
    poolPrice = poolPriceFromSqrt(sqrtPriceX96);
  }

  return {
    configured: true,
    loading: false,
    feePips: feePips !== undefined ? Number(feePips) : undefined,
    deviationBps: deviationBps !== undefined ? Number(deviationBps) : undefined,
    oraclePrice,
    poolPrice,
  };
}
