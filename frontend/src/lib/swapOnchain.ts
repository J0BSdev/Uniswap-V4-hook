import {
  createPublicClient,
  createWalletClient,
  http,
  parseUnits,
  parseEventLogs,
  maxUint256,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { BASE, ENV } from "../config/contracts";
import { erc20Abi, feeAdjustedEvent, poolSwapTestAbi } from "../abi/external";

const DYNAMIC_FEE_FLAG = 0x800000;
const TICK_SPACING = 60;
const MIN_SQRT_PRICE = 4295128739n;
const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342n;

export interface OnchainSwapResult {
  hash: Hex;
  feePips: number;
  deviationBps: number;
}

function clients() {
  const rpc = ENV.baseRpcUrl || "https://mainnet.base.org";
  const account = privateKeyToAccount(ENV.devPrivateKey as Hex);
  const transport = http(rpc);
  const publicClient = createPublicClient({ chain: base, transport });
  const walletClient = createWalletClient({ chain: base, transport, account });
  return { publicClient, walletClient, account };
}

const poolKey = (hooks: Address) =>
  ({
    currency0: BASE.weth,
    currency1: BASE.usdc,
    fee: DYNAMIC_FEE_FLAG,
    tickSpacing: TICK_SPACING,
    hooks,
  }) as const;

/** Executes a real swap through PoolSwapTest using the configured dev key. */
export async function executeOnchainSwap(
  tokenIn: "WETH" | "USDC",
  amountIn: number
): Promise<OnchainSwapResult> {
  const { publicClient, walletClient, account } = clients();
  const router = ENV.swapRouter as Address;
  const hook = ENV.hookAddress as Address;

  const zeroForOne = tokenIn === "WETH";
  const decimals = tokenIn === "WETH" ? 18 : 6;
  const amountWei = parseUnits(amountIn.toString(), decimals);
  const tokenAddr = tokenIn === "WETH" ? BASE.weth : BASE.usdc;

  // Ensure the router can pull the input token.
  const allowance = await publicClient.readContract({
    address: tokenAddr,
    abi: erc20Abi,
    functionName: "allowance",
    args: [account.address, router],
  });
  if (allowance < amountWei) {
    const approveHash = await walletClient.writeContract({
      address: tokenAddr,
      abi: erc20Abi,
      functionName: "approve",
      args: [router, maxUint256],
    });
    await publicClient.waitForTransactionReceipt({ hash: approveHash });
  }

  const hash = await walletClient.writeContract({
    address: router,
    abi: poolSwapTestAbi,
    functionName: "swap",
    args: [
      poolKey(hook),
      {
        zeroForOne,
        amountSpecified: -amountWei, // exact input
        sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE + 1n : MAX_SQRT_PRICE - 1n,
      },
      { takeClaims: false, settleUsingBurn: false },
      "0x",
    ],
  });

  const receipt = await publicClient.waitForTransactionReceipt({ hash });

  const events = parseEventLogs({
    abi: [feeAdjustedEvent],
    logs: receipt.logs,
    eventName: "FeeAdjusted",
  });
  const ev = events[0]?.args as { feePips: number; priceDeviationBps: bigint } | undefined;

  return {
    hash,
    feePips: ev ? Number(ev.feePips) : 0,
    deviationBps: ev ? Number(ev.priceDeviationBps) : 0,
  };
}
