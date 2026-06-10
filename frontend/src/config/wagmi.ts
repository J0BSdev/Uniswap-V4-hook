import { http, createConfig } from "wagmi";
import { base, baseSepolia } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import { ENV } from "./contracts";

const mainnetRpc = ENV.baseRpcUrl && ENV.chainId === 8453 ? ENV.baseRpcUrl : "https://mainnet.base.org";
const sepoliaRpc = ENV.baseRpcUrl && ENV.chainId === 84532 ? ENV.baseRpcUrl : "https://sepolia.base.org";
const forkRpc = ENV.baseRpcUrl && ENV.chainId === 8453 && ENV.baseRpcUrl.includes("127.0.0.1")
  ? ENV.baseRpcUrl
  : mainnetRpc;

export const wagmiConfig = createConfig({
  chains: [base, baseSepolia],
  connectors: [injected()],
  transports: {
    [base.id]: http(forkRpc),
    [baseSepolia.id]: http(sepoliaRpc),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
