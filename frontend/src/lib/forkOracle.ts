import { createWalletClient, http, type WalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base, baseSepolia } from "viem/chains";
import { BASE, CAN_SWAP_ONCHAIN, ENV } from "../config/contracts";
import { aggregatorAbi } from "../abi/external";
import { readMainnetChainlinkEthUsd } from "./chainlinkRef";
import { createAppPublicClient, forkBlockTimestamp, resolveRpcUrl } from "./rpcClient";
import type { Hex } from "viem";

const chain = ENV.chainId === 84532 ? baseSepolia : base;

const mockOracleAbi = [
  ...aggregatorAbi,
  {
    type: "function",
    name: "setRound",
    stateMutability: "nonpayable",
    inputs: [
      { name: "_answer", type: "int256" },
      { name: "_startedAt", type: "uint256" },
      { name: "_updatedAt", type: "uint256" },
    ],
    outputs: [],
  },
] as const;

function devClients() {
  const account = privateKeyToAccount(ENV.devPrivateKey as Hex);
  const transport = http(resolveRpcUrl());
  return {
    public: createAppPublicClient(),
    wallet: createWalletClient({ chain, transport, account }),
    account,
  };
}

async function oracleRoundTimes(): Promise<{ startedAt: bigint; updatedAt: bigint }> {
  const ts = await forkBlockTimestamp();
  return { startedAt: ts - 120n, updatedAt: ts - 60n };
}

/** Read the current ETH/USD price from the Chainlink (or mock) feed. */
export async function readForkOraclePrice(): Promise<number> {
  const client = createAppPublicClient();
  const [, answer] = await client.readContract({
    address: BASE.ethUsdFeed,
    abi: aggregatorAbi,
    functionName: "latestRoundData",
  });
  return Number(answer) / 1e8;
}

async function writeMockOracleRound(wallet: WalletClient, priceUsd: number): Promise<void> {
  const pub = createAppPublicClient();
  const [account] = await wallet.getAddresses();
  const { startedAt, updatedAt } = await oracleRoundTimes();
  const answer = BigInt(Math.round(Math.max(100, priceUsd) * 1e8));
  const hash = await wallet.writeContract({
    chain,
    account,
    address: BASE.ethUsdFeed,
    abi: mockOracleAbi,
    functionName: "setRound",
    args: [answer, startedAt, updatedAt],
  });
  await pub.waitForTransactionReceipt({ hash });
}

/** Refresh mock oracle timestamps via a connected browser wallet. */
export async function refreshMockOracleWithWallet(wallet: WalletClient): Promise<void> {
  const current = await readForkOraclePrice();
  await writeMockOracleRound(wallet, current);
}

/** Write a new ETH/USD price into the mock Chainlink feed. */
export async function setForkOraclePrice(priceUsd: number, wallet?: WalletClient): Promise<void> {
  if (wallet) {
    await writeMockOracleRound(wallet, priceUsd);
    return;
  }
  if (!CAN_SWAP_ONCHAIN) return;
  const { public: pub, wallet: devWallet, account } = devClients();
  const { startedAt, updatedAt } = await oracleRoundTimes();
  const answer = BigInt(Math.round(Math.max(100, priceUsd) * 1e8));
  const hash = await devWallet.writeContract({
    chain,
    account,
    address: BASE.ethUsdFeed,
    abi: mockOracleAbi,
    functionName: "setRound",
    args: [answer, startedAt, updatedAt],
  });
  await pub.waitForTransactionReceipt({ hash });
}

/** Sync Sepolia mock oracle to the live Base mainnet Chainlink ETH/USD price. */
export async function syncOracleToChainlink(wallet?: WalletClient): Promise<number> {
  const reference = await readMainnetChainlinkEthUsd();
  await setForkOraclePrice(reference, wallet);
  return reference;
}

/** Nudge the mock oracle by a percentage, e.g. +1 or -0.5. */
export async function nudgeForkOracle(deltaPct: number, wallet?: WalletClient): Promise<void> {
  const current = await readForkOraclePrice();
  await setForkOraclePrice(current * (1 + deltaPct / 100), wallet);
}

/** Ask Vercel keeper (server-side) to sync mock oracle to mainnet Chainlink. */
export async function requestKeeperOracleSync(): Promise<number | null> {
  try {
    const res = await fetch("/api/sync-oracle", { method: "POST" });
    if (!res.ok) return null;
    const body = (await res.json()) as { priceUsd?: number };
    return body.priceUsd ?? null;
  } catch {
    return null;
  }
}
