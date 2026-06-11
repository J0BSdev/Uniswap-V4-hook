import {
  createPublicClient,
  createWalletClient,
  http,
  parseUnits,
  parseEventLogs,
  maxUint256,
  type Address,
  type Hex,
  type TransactionReceipt,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base, baseSepolia } from "viem/chains";
import { BASE, ENV, POOL_CURRENCIES, WETH_IS_CURRENCY0 } from "../config/contracts";
import { dynamicLpFeesHookAbi } from "../abi/dynamicLpFeesHook";
import { erc20Abi, poolManagerAbi, poolSwapTestAbi } from "../abi/external";
import { sqrtPriceLimitForTarget } from "./sqrtPrice";

const DYNAMIC_FEE_FLAG = 0x800000;
const OVERRIDE_FEE_MASK = 0xbfffff;
const TICK_SPACING = 60;
const MIN_SQRT_PRICE = 4295128739n;
const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342n;

export interface OnchainSwapResult {
  hash: Hex;
  feePips: number;
  riskScoreBps: number;
}

function clients() {
  const rpc = ENV.baseRpcUrl || "https://mainnet.base.org";
  const account = privateKeyToAccount(ENV.devPrivateKey as Hex);
  const transport = http(rpc);
  const chain = ENV.chainId === 84532 ? baseSepolia : base;
  const publicClient = createPublicClient({ chain, transport });
  const walletClient = createWalletClient({ chain, transport, account });
  return { publicClient, walletClient, account };
}

const poolKey = (hooks: Address) =>
  ({
    currency0: POOL_CURRENCIES.currency0,
    currency1: POOL_CURRENCIES.currency1,
    fee: DYNAMIC_FEE_FLAG,
    tickSpacing: TICK_SPACING,
    hooks,
  }) as const;

/** Strip V4 dynamic-fee override flag (0x400000) if present. */
function cleanFeePips(raw: number | bigint): number {
  return Number(raw) & OVERRIDE_FEE_MASK;
}

/** Read applied fee from hook FeeAdjusted, then PoolManager Swap, in that order. */
export function extractAppliedFeeFromReceipt(
  receipt: TransactionReceipt,
  hook: Address
): { feePips: number; riskScoreBps: number } {
  const hookAddr = hook.toLowerCase();

  const feeAdjusted = parseEventLogs({
    abi: dynamicLpFeesHookAbi,
    logs: receipt.logs,
    eventName: "FeeAdjusted",
  }).filter((e) => e.address.toLowerCase() === hookAddr);

  if (feeAdjusted.length > 0) {
    const ev = feeAdjusted[feeAdjusted.length - 1]!;
    return {
      feePips: cleanFeePips(ev.args.feePips),
      riskScoreBps: Number(ev.args.riskScoreBps),
    };
  }

  const swaps = parseEventLogs({
    abi: poolManagerAbi,
    logs: receipt.logs,
    eventName: "Swap",
  }).filter((e) => e.address.toLowerCase() === BASE.poolManager.toLowerCase());

  if (swaps.length > 0) {
    const ev = swaps[swaps.length - 1]!;
    return {
      feePips: cleanFeePips(ev.args.fee),
      riskScoreBps: 0,
    };
  }

  return { feePips: 0, riskScoreBps: 0 };
}

async function swapWithAccount(
  tokenIn: "WETH" | "USDC",
  amountIn: number,
  account: Address,
  walletClient: WalletClient,
  previewFeePips?: number,
  targetPoolUsd?: number
): Promise<OnchainSwapResult> {
  const rpc = ENV.baseRpcUrl || (ENV.chainId === 84532 ? "https://sepolia.base.org" : "https://mainnet.base.org");
  const chain = ENV.chainId === 84532 ? baseSepolia : base;
  const publicClient = createPublicClient({ chain, transport: http(rpc) });
  const router = ENV.swapRouter as Address;
  const hook = ENV.hookAddress as Address;
  if (!router) throw new Error("VITE_SWAP_ROUTER not configured");

  const zeroForOne = WETH_IS_CURRENCY0 ? tokenIn === "WETH" : tokenIn === "USDC";
  const decimals = tokenIn === "WETH" ? 18 : 6;
  const amountWei = parseUnits(amountIn.toString(), decimals);
  const tokenAddr = tokenIn === "WETH" ? BASE.weth : BASE.usdc;
  const priceLimit =
    targetPoolUsd !== undefined
      ? sqrtPriceLimitForTarget(targetPoolUsd, zeroForOne)
      : zeroForOne
        ? MIN_SQRT_PRICE + 1n
        : MAX_SQRT_PRICE - 1n;

  const allowance = await publicClient.readContract({
    address: tokenAddr,
    abi: erc20Abi,
    functionName: "allowance",
    args: [account, router],
  });
  if (allowance < amountWei) {
    const approveHash = await walletClient.writeContract({
      account,
      chain: walletClient.chain ?? chain,
      address: tokenAddr,
      abi: erc20Abi,
      functionName: "approve",
      args: [router, maxUint256],
    });
    await publicClient.waitForTransactionReceipt({ hash: approveHash });
  }

  const hash = await walletClient.writeContract({
    account,
    chain: walletClient.chain ?? chain,
    address: router,
    abi: poolSwapTestAbi,
    functionName: "swap",
    args: [
      poolKey(hook),
      {
        zeroForOne,
        amountSpecified: -amountWei,
        sqrtPriceLimitX96: priceLimit,
      },
      { takeClaims: false, settleUsingBurn: false },
      "0x",
    ],
  });

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  const { feePips, riskScoreBps } = extractAppliedFeeFromReceipt(receipt, hook);

  return {
    hash,
    feePips: feePips > 0 ? feePips : (previewFeePips ?? 0),
    riskScoreBps,
  };
}

/** Executes a real swap through PoolSwapTest using the configured dev key. */
export async function executeOnchainSwap(
  tokenIn: "WETH" | "USDC",
  amountIn: number,
  previewFeePips?: number
): Promise<OnchainSwapResult> {
  const { walletClient, account } = clients();
  return swapWithAccount(tokenIn, amountIn, account.address, walletClient, previewFeePips);
}

/** Swap via connected MetaMask wallet (Sepolia) or dev key when wallet omitted on fork. */
export async function executeOnchainSwapWithWallet(
  tokenIn: "WETH" | "USDC",
  amountIn: number,
  wallet?: WalletClient,
  previewFeePips?: number,
  targetPoolUsd?: number
): Promise<OnchainSwapResult> {
  if (wallet) {
    const [address] = await wallet.getAddresses();
    return swapWithAccount(tokenIn, amountIn, address, wallet, previewFeePips, targetPoolUsd);
  }
  return executeOnchainSwap(tokenIn, amountIn, previewFeePips);
}
