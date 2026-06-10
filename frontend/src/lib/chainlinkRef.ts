import { createPublicClient, http } from "viem";
import { base } from "viem/chains";
import { BASE_MAINNET } from "../config/contracts";
import { aggregatorAbi } from "../abi/external";

const mainnetClient = createPublicClient({
  chain: base,
  transport: http("https://mainnet.base.org"),
});

/** Live Chainlink ETH/USD from Base mainnet (the real feed the hook uses in production). */
export async function readMainnetChainlinkEthUsd(): Promise<number> {
  const [, answer] = await mainnetClient.readContract({
    address: BASE_MAINNET.ethUsdFeed,
    abi: aggregatorAbi,
    functionName: "latestRoundData",
  });
  const price = Number(answer) / 1e8;
  if (!Number.isFinite(price) || price <= 0) throw new Error("Invalid Chainlink answer");
  return price;
}
