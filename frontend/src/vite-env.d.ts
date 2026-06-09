/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_HOOK_ADDRESS?: string;
  readonly VITE_POOL_ID?: string;
  readonly VITE_BASE_RPC_URL?: string;
  readonly VITE_UNIVERSAL_ROUTER?: string;
  readonly VITE_WALLETCONNECT_PROJECT_ID?: string;
  readonly VITE_SWAP_ROUTER?: string;
  readonly VITE_DEV_PRIVATE_KEY?: string;
  readonly VITE_LP_TICK_LOWER?: string;
  readonly VITE_LP_TICK_UPPER?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
