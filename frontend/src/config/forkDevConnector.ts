import { createConnector } from "@wagmi/core";
import {
  createWalletClient,
  custom,
  http,
  numberToHex,
  type Address,
  type EIP1193RequestFn,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base, baseSepolia } from "viem/chains";
import { CAN_SWAP_ONCHAIN, ENV } from "./contracts";

function forkRpcUrl(): string {
  const isLocal =
    !!ENV.baseRpcUrl &&
    (ENV.baseRpcUrl.includes("127.0.0.1") || ENV.baseRpcUrl.includes("localhost"));
  if (typeof window !== "undefined" && isLocal) return `${window.location.origin}/rpc`;
  return ENV.baseRpcUrl || "http://127.0.0.1:8545";
}

forkDevWallet.type = "forkDev" as const;

/** Local Anvil account — signs txs without MetaMask (fork dev only). */
export function forkDevWallet() {
  if (!CAN_SWAP_ONCHAIN || !ENV.devPrivateKey) {
    throw new Error("forkDevWallet requires VITE_DEV_PRIVATE_KEY");
  }

  const account = privateKeyToAccount(ENV.devPrivateKey as Hex);
  const chain = ENV.chainId === 84532 ? baseSepolia : base;
  const chainId = ENV.chainId as 8453 | 84532;
  let connected = false;

  return createConnector((config) => ({
    id: "fork-dev",
    name: "Anvil dev wallet",
    type: forkDevWallet.type,

    async connect({ chainId: requestedChainId } = {}) {
      connected = true;
      return {
        accounts: [account.address],
        chainId: requestedChainId ?? chainId,
      } as never;
    },

    async disconnect() {
      connected = false;
    },

    async getAccounts() {
      return connected ? ([account.address] as readonly Address[]) : [];
    },

    async getChainId() {
      return chainId;
    },

    async isAuthorized() {
      return connected;
    },

    onAccountsChanged() {},
    onChainChanged() {},
    onDisconnect() {},

    async getProvider() {
      const rpc = forkRpcUrl();
      const walletClient = createWalletClient({
        account,
        chain,
        transport: http(rpc),
      });

      const request = (async ({ method, params }) => {
        if (method === "eth_requestAccounts") {
          connected = true;
          return [account.address];
        }
        if (method === "eth_accounts") return connected ? [account.address] : [];
        if (method === "eth_chainId") return numberToHex(chainId);
        return walletClient.request({ method, params } as never);
      }) as EIP1193RequestFn;

      return custom({ request })({ retryCount: 0 });
    },

    async getClient({ chainId: requestedChainId } = {}) {
      const rpc = forkRpcUrl();
      const activeChain = config.chains.find((c) => c.id === (requestedChainId ?? chainId)) ?? chain;
      return createWalletClient({
        account,
        chain: activeChain,
        transport: http(rpc),
      });
    },
  }));
}
