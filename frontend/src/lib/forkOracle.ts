import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base, baseSepolia } from "viem/chains";
import { BASE, CAN_SWAP_ONCHAIN, ENV } from "../config/contracts";

const chain = ENV.chainId === 84532 ? baseSepolia : base;
import { aggregatorAbi } from "../abi/external";
import type { Hex } from "viem";

function clients() {
  const rpc = ENV.baseRpcUrl || "http://127.0.0.1:8545";
  const account = privateKeyToAccount(ENV.devPrivateKey as Hex);
  const transport = http(rpc);
  return {
    public: createPublicClient({ chain, transport }),
    wallet: createWalletClient({ chain, transport, account }),
  };
}

/** Read the current ETH/USD price from the (mock) Chainlink feed on the fork. */
export async function readForkOraclePrice(): Promise<number> {
  const { public: client } = clients();
  const [, answer] = await client.readContract({
    address: BASE.ethUsdFeed,
    abi: aggregatorAbi,
    functionName: "latestRoundData",
  });
  return Number(answer) / 1e8;
}

/** Write a new ETH/USD price into the mock Chainlink feed (fork only). */
export async function setForkOraclePrice(priceUsd: number): Promise<void> {
  if (!CAN_SWAP_ONCHAIN) return;
  const { public: pub, wallet } = clients();
  const now = BigInt(Math.floor(Date.now() / 1000));
  const answer = BigInt(Math.round(Math.max(100, priceUsd) * 1e8));
  const hash = await wallet.writeContract({
    address: BASE.ethUsdFeed,
    abi: [
      ...aggregatorAbi,
      {
        type: "function",
        name: "setRound",
        stateMutability: "nonpayable",
        inputs: [
          { name: "_answer", type: "int256" },
          { name: "_startedAt", type: "uint256" },
          { name: "_updatedAt", type: "uint256" },
        ],
        outputs: [],
      },
    ] as const,
    functionName: "setRound",
    args: [answer, now - 120n, now - 60n],
  });
  await pub.waitForTransactionReceipt({ hash });
}

/** Nudge the fork oracle by a percentage, e.g. +1 or -0.5. */
export async function nudgeForkOracle(deltaPct: number): Promise<void> {
  const current = await readForkOraclePrice();
  await setForkOraclePrice(current * (1 + deltaPct / 100));
}
