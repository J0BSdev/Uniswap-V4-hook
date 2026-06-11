import { type Hex, type WalletClient } from "viem";
import { BASE, ENV, WETH_IS_CURRENCY0 } from "../config/contracts";
import { poolManagerAbi } from "../abi/external";
import { deviationBps } from "./feeMath";
import { readMainnetChainlinkEthUsd } from "./chainlinkRef";
import { setForkOraclePrice, syncOracleToChainlink } from "./forkOracle";
import { poolPriceFromSlot0, poolStateSlot } from "./poolState";
import { createAppPublicClient, requireHex } from "./rpcClient";
import { executeOnchainSwapWithWallet } from "./swapOnchain";

async function readOnChainPoolPrice(): Promise<number> {
  const client = createAppPublicClient();
  const poolId = requireHex(ENV.poolId, "VITE_POOL_ID");
  const slotWord = await client.readContract({
    address: BASE.poolManager,
    abi: poolManagerAbi,
    functionName: "extsload",
    args: [poolStateSlot(poolId)],
  });
  const price = poolPriceFromSlot0(slotWord as Hex);
  if (price === undefined || price <= 0) {
    throw new Error("Pool not initialized — run script/setup-fork.sh");
  }
  return price;
}

function swapTokenToMovePrice(poolPrice: number, targetUsd: number): "WETH" | "USDC" {
  const needLower = poolPrice > targetUsd;
  if (WETH_IS_CURRENCY0) return needLower ? "WETH" : "USDC";
  return needLower ? "USDC" : "WETH";
}

function swapAmountUsd(diffBps: number): number {
  if (diffBps > 5000) return 2500;
  if (diffBps > 2000) return 800;
  if (diffBps > 1000) return 300;
  if (diffBps > 500) return 100;
  if (diffBps > 100) return 30;
  return 10;
}

/** Sync mock oracle + swap until pool spot is within ~0.5% of target USD. */
export async function alignPoolToTarget(targetUsd: number, wallet?: WalletClient): Promise<number> {
  const target = Math.max(100, targetUsd);
  await setForkOraclePrice(target, wallet);

  for (let i = 0; i < 16; i++) {
    const poolPrice = await readOnChainPoolPrice();
    const diffBps = deviationBps(poolPrice, target);
    if (diffBps <= 50) return poolPrice;

    const tokenIn = swapTokenToMovePrice(poolPrice, target);
    const amountIn = swapAmountUsd(diffBps);
    await executeOnchainSwapWithWallet(tokenIn, amountIn, wallet);
  }

  return readOnChainPoolPrice();
}

/** Align oracle + pool to live Base mainnet Chainlink ETH/USD. */
export async function alignPoolToChainlink(wallet?: WalletClient): Promise<number> {
  const target = await readMainnetChainlinkEthUsd();
  if (wallet) return alignPoolToTarget(target, wallet);
  await syncOracleToChainlink();
  return alignPoolToTarget(target);
}
