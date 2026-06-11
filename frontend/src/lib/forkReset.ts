import type { WalletClient } from "viem";
import { alignPoolToChainlink, alignPoolToTarget } from "./alignPool";

/** Reset pool + oracle to live Chainlink ETH/USD (fork dev key or connected wallet). */
export async function resetForkPoolState(wallet?: WalletClient): Promise<number> {
  return alignPoolToChainlink(wallet);
}

export { alignPoolToTarget, alignPoolToChainlink };
