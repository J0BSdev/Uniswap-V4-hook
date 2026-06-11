import type { Address, Hex } from "viem";

const clean = (v?: string) => (typeof v === "string" ? v.trim() : "");

const CHAIN_ID = parseInt(clean(import.meta.env.VITE_CHAIN_ID) || "8453", 10);
const IS_SEPOLIA = CHAIN_ID === 84532;

// Base mainnet addresses the hook is wired to.
export const BASE_MAINNET = {
  weth: "0x4200000000000000000000000000000000000006" as Address,
  usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as Address,
  ethUsdFeed: "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70" as Address,
  sequencerFeed: "0xBCF85224fc0756B9Fa45aA7892530B47e10b6433" as Address,
  poolManager: "0x498581fF718922c3f8e6A244956aF099B2652b2b" as Address,
};

// Base Sepolia — on-chain oracle feed wired to the deployed hook.
export const BASE_SEPOLIA = {
  weth: "0x4200000000000000000000000000000000000006" as Address,
  usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e" as Address,
  ethUsdFeed: (clean(import.meta.env.VITE_ETH_USD_FEED) ||
    "0x0000000000000000000000000000000000000000") as Address,
  sequencerFeed: "0x0000000000000000000000000000000000000000" as Address,
  poolManager: (clean(import.meta.env.VITE_POOL_MANAGER) ||
    "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408") as Address,
};

export const BASE = IS_SEPOLIA ? BASE_SEPOLIA : BASE_MAINNET;

/** Uniswap sorts currencies by address — WETH is token0 on mainnet, USDC on Sepolia. */
export const WETH_IS_CURRENCY0 = BASE.weth.toLowerCase() < BASE.usdc.toLowerCase();

export const POOL_CURRENCIES = {
  currency0: (WETH_IS_CURRENCY0 ? BASE.weth : BASE.usdc) as Address,
  currency1: (WETH_IS_CURRENCY0 ? BASE.usdc : BASE.weth) as Address,
};

const Q96 = 1n << 96n;

/** ETH/USD in human units from sqrtPriceX96 (matches on-chain hook math). */
export function poolPriceFromSqrt(sqrtPriceX96: bigint): number {
  const intermediate = (sqrtPriceX96 * sqrtPriceX96) / Q96;
  const price8 = WETH_IS_CURRENCY0
    ? (intermediate * 10n ** 20n) / Q96
    : (10n ** 20n * Q96) / intermediate;
  return Number(price8) / 1e8;
}

// Token display metadata for the WETH/USDC pool.
export const TOKENS = {
  WETH: { symbol: "WETH", name: "Wrapped Ether", decimals: 18, address: BASE.weth },
  USDC: { symbol: "USDC", name: "USD Coin", decimals: 6, address: BASE.usdc },
} as const;

export type TokenSymbol = keyof typeof TOKENS;

export const ENV = {
  chainId: CHAIN_ID,
  hookAddress: clean(import.meta.env.VITE_HOOK_ADDRESS) as Address | "",
  poolId: clean(import.meta.env.VITE_POOL_ID) as Hex | "",
  baseRpcUrl: clean(import.meta.env.VITE_BASE_RPC_URL),
  universalRouter: clean(import.meta.env.VITE_UNIVERSAL_ROUTER) as Address | "",
  walletConnectProjectId: clean(import.meta.env.VITE_WALLETCONNECT_PROJECT_ID),
  // Fork / dev only: a PoolSwapTest router + a funded dev key let the swap card
  // execute real on-chain swaps without a browser wallet. NEVER set in production.
  swapRouter: clean(import.meta.env.VITE_SWAP_ROUTER) as Address | "",
  devPrivateKey: clean(import.meta.env.VITE_DEV_PRIVATE_KEY) as Hex | "",
};

// The app runs in demo mode until a hook address + pool id are configured.
export const IS_DEMO = !(ENV.hookAddress && ENV.poolId);

// Real on-chain swaps via local dev key (fork only).
export const CAN_SWAP_ONCHAIN = !IS_DEMO && !!ENV.swapRouter && !!ENV.devPrivateKey;

// Swaps via connected MetaMask + deployed PoolSwapTest router (Sepolia public).
export const CAN_SWAP_WITH_WALLET = !IS_DEMO && !!ENV.swapRouter;

/** Sepolia hook oracle feed — updatable via connected wallet. */
export const CAN_NUDGE_MOCK_ORACLE = !IS_DEMO && IS_SEPOLIA && BASE.ethUsdFeed !== "0x0000000000000000000000000000000000000000";

/** True when running against local anvil fork (dev key swaps, no MetaMask required). */
export const IS_FORK_DEV = CAN_SWAP_ONCHAIN && !!ENV.baseRpcUrl && ENV.baseRpcUrl.includes("127.0.0.1");
