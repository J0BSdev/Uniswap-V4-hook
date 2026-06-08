import type { Address, Hex } from "viem";

// Base mainnet addresses the hook is wired to.
export const BASE = {
  weth: "0x4200000000000000000000000000000000000006" as Address,
  usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as Address,
  ethUsdFeed: "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70" as Address,
  sequencerFeed: "0xBCF85224fc0756B9Fa45aA7892530B47e10b6433" as Address,
  poolManager: "0x498581fF718922c3f8e6A244956aF099B2652b2b" as Address,
};

// Token display metadata for the WETH/USDC pool (token0 = WETH, token1 = USDC).
export const TOKENS = {
  WETH: { symbol: "WETH", name: "Wrapped Ether", decimals: 18, address: BASE.weth },
  USDC: { symbol: "USDC", name: "USD Coin", decimals: 6, address: BASE.usdc },
} as const;

export type TokenSymbol = keyof typeof TOKENS;

function readEnv(key: string): string {
  const v = import.meta.env[key as keyof ImportMetaEnv];
  return typeof v === "string" ? v.trim() : "";
}

export const ENV = {
  hookAddress: readEnv("VITE_HOOK_ADDRESS") as Address | "",
  poolId: readEnv("VITE_POOL_ID") as Hex | "",
  baseRpcUrl: readEnv("VITE_BASE_RPC_URL"),
  universalRouter: readEnv("VITE_UNIVERSAL_ROUTER") as Address | "",
  walletConnectProjectId: readEnv("VITE_WALLETCONNECT_PROJECT_ID"),
};

// The app runs in demo mode until a hook address + pool id are configured.
export const IS_DEMO = !(ENV.hookAddress && ENV.poolId);
