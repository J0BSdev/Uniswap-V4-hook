import { useQuery, keepPreviousData } from "@tanstack/react-query";
import { useEffect, useRef } from "react";
import type { Hex } from "viem";
import { BASE, CAN_SWAP_ONCHAIN, ENV, IS_DEMO } from "../config/contracts";
import { deviationBps as calcDeviationBps, feeForDeviationBps } from "../lib/feeMath";
import { dynamicLpFeesHookAbi } from "../abi/dynamicLpFeesHook";
import { aggregatorAbi, poolManagerAbi } from "../abi/external";
import {
  liquidityFromSlot,
  poolLiquiditySlot,
  poolPriceFromSlot0,
  poolStateSlot,
  parseSlot0,
} from "../lib/poolState";
import { createAppPublicClient, requireHex } from "../lib/rpcClient";
import { readMainnetChainlinkEthUsd } from "../lib/chainlinkRef";
import { CAN_NUDGE_MOCK_ORACLE } from "../config/contracts";

export interface LiveFeeSnapshot {
  configured: boolean;
  loading: boolean;
  error?: string;
  feePips?: number;
  deviationBps?: number;
  oraclePrice?: number;
  /** Live Chainlink ETH/USD from Base mainnet (reference price). */
  chainlinkPrice?: number;
  poolPrice?: number;
  sqrtPriceX96?: bigint;
  liquidity?: bigint;
  tick?: number;
}

function decodePreviewError(raw: string, chainId: number): string {
  if (raw.includes("a887f2d8")) {
    return chainId === 84532
      ? "Oracle data is stale — connect wallet and click Refresh oracle."
      : "Oracle data is stale — run script/setup-fork.sh to reset the fork.";
  }
  if (raw.includes("617378d7")) return "Pool price not set — pool missing or not initialized.";
  if (raw.includes("d15f73b5")) return "Sequencer grace period — wait or reset the fork.";
  if (raw.includes("032b3d00")) return "Base sequencer is down according to Chainlink feed.";
  return raw ? `previewFee reverted: ${raw.slice(0, 120)}` : "previewFee reverted (oracle/sequencer/pool guard)";
}

async function fetchLiveFee(): Promise<Omit<LiveFeeSnapshot, "configured" | "loading">> {
  const client = createAppPublicClient();
  const hookAddress = requireHex(ENV.hookAddress, "VITE_HOOK_ADDRESS");
  const poolId = requireHex(ENV.poolId, "VITE_POOL_ID");
  const stateSlot = poolStateSlot(poolId);
  const liqSlot = poolLiquiditySlot(poolId);

  const [slotWord, liqWord, oracleRes] = await Promise.all([
    client.readContract({
      address: BASE.poolManager,
      abi: poolManagerAbi,
      functionName: "extsload",
      args: [stateSlot],
    }),
    client.readContract({
      address: BASE.poolManager,
      abi: poolManagerAbi,
      functionName: "extsload",
      args: [liqSlot],
    }),
    client.readContract({
      address: BASE.ethUsdFeed,
      abi: aggregatorAbi,
      functionName: "latestRoundData",
    }),
  ]);

  const slotHex = slotWord as Hex;
  const { sqrtPriceX96, tick } = parseSlot0(slotHex);
  const poolPrice = poolPriceFromSlot0(slotHex);
  const liquidity = liquidityFromSlot(liqWord as Hex);
  const [, oracleAnswer] = oracleRes;
  const oraclePrice = Number(oracleAnswer) / 1e8;

  let chainlinkPrice: number | undefined;
  try {
    chainlinkPrice = await readMainnetChainlinkEthUsd();
  } catch {
    chainlinkPrice = CAN_NUDGE_MOCK_ORACLE ? undefined : oraclePrice;
  }

  const computedDev =
    poolPrice !== undefined && oraclePrice > 0
      ? calcDeviationBps(poolPrice, oraclePrice)
      : undefined;

  let feePips: number | undefined;
  let deviationBps: number | undefined;
  let error: string | undefined;

  try {
    const [fee, dev] = await client.readContract({
      address: hookAddress,
      abi: dynamicLpFeesHookAbi,
      functionName: "previewFee",
      args: [poolId],
    });
    feePips = Number(fee);
    deviationBps = Number(dev);
  } catch (e) {
    error = decodePreviewError(e instanceof Error ? e.message : String(e), ENV.chainId);
    feePips = computedDev !== undefined ? feeForDeviationBps(computedDev) : undefined;
    deviationBps = computedDev;
  }

  if (poolPrice === undefined) {
    error = error ?? "Pool sqrtPriceX96 is zero — re-run script/setup-fork.sh";
  }

  return {
    error,
    feePips,
    deviationBps,
    oraclePrice,
    chainlinkPrice,
    poolPrice,
    sqrtPriceX96: sqrtPriceX96 > 0n ? sqrtPriceX96 : undefined,
    liquidity,
    tick,
  };
}

export function useLiveFee(pollMs = 8000): LiveFeeSnapshot {
  const configured = !IS_DEMO && !!ENV.hookAddress && !!ENV.poolId;
  const lastGood = useRef<Omit<LiveFeeSnapshot, "configured" | "loading">>({});

  const { data, isLoading, error } = useQuery({
    queryKey: ["liveFee", ENV.chainId, ENV.hookAddress, ENV.poolId, ENV.baseRpcUrl],
    queryFn: fetchLiveFee,
    enabled: configured,
    refetchInterval: pollMs,
    refetchOnWindowFocus: true,
    retry: 1,
    placeholderData: keepPreviousData,
  });

  useEffect(() => {
    if (data?.poolPrice !== undefined && data.poolPrice > 0 && data.oraclePrice !== undefined && data.oraclePrice > 0) {
      lastGood.current = data;
    }
  }, [data]);

  const merged =
    CAN_SWAP_ONCHAIN && data && (data.poolPrice === undefined || data.poolPrice <= 0) && lastGood.current.poolPrice
      ? {
          ...lastGood.current,
          ...data,
          poolPrice: lastGood.current.poolPrice,
          sqrtPriceX96: lastGood.current.sqrtPriceX96 ?? data.sqrtPriceX96,
          liquidity: data.liquidity ?? lastGood.current.liquidity,
          deviationBps: data.deviationBps ?? lastGood.current.deviationBps,
          feePips: data.feePips ?? lastGood.current.feePips,
        }
      : data;

  if (!configured) return { configured: false, loading: false };
  if (isLoading && !merged) return { configured: true, loading: true };
  if (error) {
    return {
      configured: true,
      loading: false,
      error: error instanceof Error ? error.message : String(error),
      ...lastGood.current,
    };
  }

  return { configured: true, loading: false, ...merged! };
}
