import { useReadContracts } from "wagmi";
import { encodePacked, keccak256, toHex, type Hex } from "viem";
import { BASE, ENV, IS_DEMO, poolPriceFromSqrt } from "../config/contracts";
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
  sqrtPriceX96?: bigint;
  liquidity?: bigint;
  tick?: number;
}

const POOLS_SLOT = 6n;
const LIQUIDITY_OFFSET = 3n;

function poolStateSlot(poolId: Hex): Hex {
  return keccak256(encodePacked(["bytes32", "bytes32"], [poolId, toHex(POOLS_SLOT, { size: 32 })]));
}

function poolLiquiditySlot(poolId: Hex): Hex {
  const state = BigInt(poolStateSlot(poolId));
  return toHex(state + LIQUIDITY_OFFSET, { size: 32 });
}

function parseSlot0(word: Hex): { sqrtPriceX96: bigint; tick: number } {
  const data = BigInt(word);
  const sqrtPriceX96 = data & ((1n << 160n) - 1n);
  const tickRaw = Number((data >> 160n) & 0xffffffn);
  const tick = tickRaw >= 0x800000 ? tickRaw - 0x1000000 : tickRaw;
  return { sqrtPriceX96, tick };
}

export function useLiveFee(pollMs = 8000): LiveFeeSnapshot {
  const configured = !IS_DEMO && !!ENV.hookAddress && !!ENV.poolId;
  const poolId = ENV.poolId as Hex;

  const chainId = ENV.chainId as 8453 | 84532;

  const { data, isLoading, error } = useReadContracts({
    contracts: [
      {
        chainId,
        address: ENV.hookAddress as `0x${string}`,
        abi: dynamicLpFeesHookAbi,
        functionName: "previewFee",
        args: [poolId],
      },
      {
        chainId,
        address: BASE.ethUsdFeed,
        abi: aggregatorAbi,
        functionName: "latestRoundData",
      },
      {
        chainId,
        address: BASE.poolManager,
        abi: poolManagerAbi,
        functionName: "extsload",
        args: [configured ? poolStateSlot(poolId) : ("0x".padEnd(66, "0") as Hex)],
      },
      {
        chainId,
        address: BASE.poolManager,
        abi: poolManagerAbi,
        functionName: "extsload",
        args: [configured ? poolLiquiditySlot(poolId) : ("0x".padEnd(66, "0") as Hex)],
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
  const liqRes = data?.[3];

  const oracleAnswer = (oracleRes?.result as readonly [bigint, bigint, bigint, bigint, bigint] | undefined)?.[1];

  let sqrtPriceX96: bigint | undefined;
  let tick: number | undefined;
  let poolPrice: number | undefined;
  if (slotRes?.result) {
    const parsed = parseSlot0(slotRes.result as Hex);
    sqrtPriceX96 = parsed.sqrtPriceX96;
    tick = parsed.tick;
    poolPrice = poolPriceFromSqrt(sqrtPriceX96);
  }

  let liquidity: bigint | undefined;
  if (liqRes?.result) {
    liquidity = BigInt(liqRes.result as Hex) & ((1n << 128n) - 1n);
  }

  const oraclePrice = oracleAnswer !== undefined ? Number(oracleAnswer) / 1e8 : undefined;

  if (previewRes?.status === "failure") {
    const raw = String(previewRes.error ?? "");
    const msg = raw.includes("a887f2d8")
      ? chainId === 84532
        ? "Oracle data is stale — connect wallet and click Refresh oracle."
        : "Oracle data is stale on the fork — run script/setup-fork.sh to reset."
      : raw.includes("617378d7")
        ? "Pool price not set — pool missing or not initialized."
        : raw.includes("d15f73b5")
          ? "Sequencer grace period — wait or reset the fork."
          : raw.includes("032b3d00")
            ? "Base sequencer is down according to Chainlink feed."
            : "previewFee reverted (oracle/sequencer/pool guard)";
    return {
      configured: true,
      loading: false,
      error: msg,
      oraclePrice,
      poolPrice,
      sqrtPriceX96,
      liquidity,
      tick,
    };
  }

  const [feePips, deviationBps] = (previewRes?.result as readonly [number, bigint]) ?? [undefined, undefined];

  return {
    configured: true,
    loading: false,
    feePips: feePips !== undefined ? Number(feePips) : undefined,
    deviationBps: deviationBps !== undefined ? Number(deviationBps) : undefined,
    oraclePrice,
    poolPrice,
    sqrtPriceX96,
    liquidity,
    tick,
  };
}
