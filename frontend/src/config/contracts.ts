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

// Direct property access so Vite statically replaces these in production builds.
const clean = (v?: string) => (typeof v === "string" ? v.trim() : "");

export const ENV = {
  hookAddress: clean(import.meta.env.VITE_HOOK_ADDRESS) as Address | "",
  poolId: clean(import.meta.env.VITE_POOL_ID) as Hex | "",
  baseRpcUrl: clean(import.meta.env.VITE_BASE_RPC_URL),
  universalRouter: clean(import.meta.env.VITE_UNIVERSAL_ROUTER) as Address | "",
  walletConnectProjectId: clean(import.meta.env.VITE_WALLETCONNECT_PROJECT_ID),
  // Fork / dev only: a PoolSwapTest router + a funded dev key let the swap card
  // execute real on-chain swaps without a browser wallet. NEVER set in production.
  swapRouter: clean(import.meta.env.VITE_SWAP_ROUTER) as Address | "",
  devPrivateKey: clean(import.meta.env.VITE_DEV_PRIVATE_KEY) as Hex | "",
  // Tick bounds of the seeded LP position (from SeedLiquidity script logs).
  lpTickLower: parseInt(clean(import.meta.env.VITE_LP_TICK_LOWER) || "0", 10),
  lpTickUpper: parseInt(clean(import.meta.env.VITE_LP_TICK_UPPER) || "0", 10),
};

// The app runs in demo mode until a hook address + pool id are configured.
export const IS_DEMO = !(ENV.hookAddress && ENV.poolId);

// Real on-chain swaps are available on the fork when a swap router + dev key are set.
export const CAN_SWAP_ONCHAIN = !IS_DEMO && !!ENV.swapRouter && !!ENV.devPrivateKey;
