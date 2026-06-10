import { createPublicClient, http, type Hex } from "viem";
import { base, baseSepolia } from "viem/chains";
import { ENV } from "../config/contracts";

export function createAppPublicClient() {
  const chain = ENV.chainId === 84532 ? baseSepolia : base;
  const isLocal =
    !!ENV.baseRpcUrl &&
    (ENV.baseRpcUrl.includes("127.0.0.1") || ENV.baseRpcUrl.includes("localhost"));
  const browserRpc =
    typeof window !== "undefined" && isLocal ? `${window.location.origin}/rpc` : undefined;
  const rpc =
    browserRpc ||
    ENV.baseRpcUrl ||
    (ENV.chainId === 84532 ? "https://sepolia.base.org" : "https://mainnet.base.org");
  return createPublicClient({ chain, transport: http(rpc) });
}

export function requireHex(value: string, label: string): Hex {
  const v = value.trim();
  if (!v.startsWith("0x")) throw new Error(`${label} must be a hex string`);
  return v as Hex;
}
