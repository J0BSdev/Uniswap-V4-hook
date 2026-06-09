import { http, createConfig } from "wagmi";
import { base, baseSepolia } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import { ENV } from "./contracts";

const mainnetRpc = ENV.chainId === 8453 && ENV.baseRpcUrl ? ENV.baseRpcUrl : "https://mainnet.base.org";
const sepoliaRpc = ENV.chainId === 84532 && ENV.baseRpcUrl ? ENV.baseRpcUrl : "https://sepolia.base.org";

export const wagmiConfig = createConfig({
  chains: [base, baseSepolia],
  connectors: [injected()],
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
