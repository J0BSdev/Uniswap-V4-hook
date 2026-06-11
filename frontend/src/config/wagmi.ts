import { http, createConfig } from "wagmi";
import { base, baseSepolia } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import { CAN_SWAP_ONCHAIN, ENV } from "./contracts";
import { forkDevWallet } from "./forkDevConnector";

const mainnetRpc =
  ENV.baseRpcUrl && ENV.chainId === 8453
    ? typeof window !== "undefined" && ENV.baseRpcUrl.includes("127.0.0.1")
      ? `${window.location.origin}/rpc`
      : ENV.baseRpcUrl
    : "https://mainnet.base.org";
const sepoliaRpc = ENV.baseRpcUrl && ENV.chainId === 84532 ? ENV.baseRpcUrl : "https://sepolia.base.org";

const connectors = CAN_SWAP_ONCHAIN
  ? [injected(), forkDevWallet()]
  : [injected()];

export const wagmiConfig = createConfig({
  chains: ENV.chainId === 84532 ? [baseSepolia, base] : [base, baseSepolia],
  connectors,
  transports: {
    [base.id]: http(mainnetRpc),
    [baseSepolia.id]: http(sepoliaRpc),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
