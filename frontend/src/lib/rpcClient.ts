import { createPublicClient, http, type Hex } from "viem";
import { base, baseSepolia } from "viem/chains";
import { ENV } from "../config/contracts";

export function resolveRpcUrl(): string {
  const isLocal =
    !!ENV.baseRpcUrl &&
    (ENV.baseRpcUrl.includes("127.0.0.1") || ENV.baseRpcUrl.includes("localhost"));
  if (typeof window !== "undefined" && isLocal) {
    return `${window.location.origin}/rpc`;
  }
  return (
    ENV.baseRpcUrl ||
    (ENV.chainId === 84532 ? "https://sepolia.base.org" : "https://mainnet.base.org")
  );
}

export function createAppPublicClient() {
  const chain = ENV.chainId === 84532 ? baseSepolia : base;
  return createPublicClient({ chain, transport: http(resolveRpcUrl()) });
}

/** On-chain timestamp — use for mock oracle rounds (avoids stale/future vs anvil block). */
export async function forkBlockTimestamp(): Promise<bigint> {
  const block = await createAppPublicClient().getBlock();
  return block.timestamp;
}

export function requireHex(value: string, label: string): Hex {
  const v = value.trim();
  if (!v.startsWith("0x")) throw new Error(`${label} must be a hex string`);
  return v as Hex;
}
