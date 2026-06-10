import type { Hex, WalletClient } from "viem";
import { BASE, ENV } from "../config/contracts";
import { poolManagerAbi } from "../abi/external";
import { poolPriceFromSlot0, poolStateSlot } from "./poolState";
import { createAppPublicClient, requireHex } from "./rpcClient";
import { setForkOraclePrice } from "./forkOracle";

/** Align mock oracle to the current on-chain pool price (zero divergence). */
export async function resetForkPoolState(wallet?: WalletClient): Promise<number> {
  const client = createAppPublicClient();
  const poolId = requireHex(ENV.poolId, "VITE_POOL_ID");
  const slotWord = await client.readContract({
    address: BASE.poolManager,
    abi: poolManagerAbi,
    functionName: "extsload",
    args: [poolStateSlot(poolId)],
  });
  const poolPrice = poolPriceFromSlot0(slotWord as Hex);
  if (poolPrice === undefined || poolPrice <= 0) {
    throw new Error("Pool sqrtPriceX96 is zero — run script/setup-fork.sh");
  }
  await setForkOraclePrice(poolPrice, wallet);
  return poolPrice;
}
