import { type Hex, type WalletClient } from "viem";
import { BASE, ENV, IS_FORK_DEV } from "../config/contracts";
import { poolManagerAbi } from "../abi/external";
import { deviationBps } from "./feeMath";
import { readMainnetChainlinkEthUsd } from "./chainlinkRef";
import { setForkOraclePrice } from "./forkOracle";
import { poolPriceFromSlot0, poolStateSlot } from "./poolState";
import { createAppPublicClient, requireHex } from "./rpcClient";
import { executeOnchainSwapWithWallet } from "./swapOnchain";

const ON_SEPOLIA = ENV.chainId === 84532;

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
  // Lower pool ETH/USD → swap WETH in (zeroForOne when WETH is token0, oneForZero when USDC is token0).
  return poolPrice > targetUsd ? "WETH" : "USDC";
}

function swapAmountForAlign(tokenIn: "WETH" | "USDC", diffBps: number): number {
  if (tokenIn === "WETH") {
    if (ON_SEPOLIA) {
      if (diffBps > 5000) return 0.0005;
      if (diffBps > 2000) return 0.0003;
      if (diffBps > 1000) return 0.0002;
      if (diffBps > 500) return 0.0001;
      return 0.00005;
    }
    if (diffBps > 5000) return 0.5;
    if (diffBps > 2000) return 0.2;
    if (diffBps > 1000) return 0.1;
    if (diffBps > 500) return 0.05;
    if (diffBps > 100) return 0.02;
    return 0.01;
  }
  if (ON_SEPOLIA) {
    if (diffBps > 5000) return 5;
    if (diffBps > 2000) return 4;
    if (diffBps > 1000) return 3;
    if (diffBps > 500) return 2;
    return 1;
  }
  if (diffBps > 5000) return 500;
  if (diffBps > 2000) return 200;
  if (diffBps > 1000) return 80;
  if (diffBps > 500) return 30;
  if (diffBps > 100) return 10;
  return 5;
}

/** Sync mock oracle + swap until pool spot is within ~0.5% of target USD. */
export async function alignPoolToTarget(targetUsd: number, wallet?: WalletClient): Promise<number> {
  const target = Math.max(100, targetUsd);
  await setForkOraclePrice(target, wallet);

  // Fork demo: no reliable in-range LP — syncing the mock oracle is enough for fee reset.
  if (IS_FORK_DEV) {
    return readOnChainPoolPrice();
  }

  for (let i = 0; i < (ON_SEPOLIA ? 32 : 16); i++) {
    const poolPrice = await readOnChainPoolPrice();
    const diffBps = deviationBps(poolPrice, target);
    if (diffBps <= 50) return poolPrice;

    const tokenIn = swapTokenToMovePrice(poolPrice, target);
    const amountIn = swapAmountForAlign(tokenIn, diffBps);
    try {
      await executeOnchainSwapWithWallet(tokenIn, amountIn, wallet, undefined, target);
    } catch {
      // Pool may lack in-range LP — oracle is already synced; return best-effort spot.
      return poolPrice;
    }
  }

  return readOnChainPoolPrice();
}

/** Align oracle + pool to live Base mainnet Chainlink ETH/USD. */
export async function alignPoolToChainlink(wallet?: WalletClient): Promise<number> {
  const target = await readMainnetChainlinkEthUsd();
  return alignPoolToTarget(target, wallet);
}
