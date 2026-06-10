import type { VercelRequest, VercelResponse } from "@vercel/node";
import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base, baseSepolia } from "viem/chains";

const MAINNET_FEED = "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70";
const SEPOLIA_FEED = process.env.SEPOLIA_ETH_USD_FEED || "0xfA23B8D1773F2A49bE5BE6A846F7ea28160CE451";
const SEPOLIA_RPC = process.env.SEPOLIA_RPC_URL || "https://sepolia.base.org";

const aggregatorAbi = [
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
] as const;

const mockOracleAbi = [
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
] as const;

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST" && req.method !== "GET") {
    return res.status(405).json({ error: "Method not allowed" });
  }

  const key = process.env.ORACLE_KEEPER_PRIVATE_KEY;
  if (!key) {
    return res.status(503).json({ error: "ORACLE_KEEPER_PRIVATE_KEY not configured on Vercel" });
  }

  try {
    const mainnet = createPublicClient({ chain: base, transport: http("https://mainnet.base.org") });
    const [, answer] = await mainnet.readContract({
      address: MAINNET_FEED as `0x${string}`,
      abi: aggregatorAbi,
      functionName: "latestRoundData",
    });

    const priceUsd = Number(answer) / 1e8;
    const now = BigInt(Math.floor(Date.now() / 1000));
    const price8 = BigInt(Math.round(priceUsd * 1e8));

    const account = privateKeyToAccount(key as `0x${string}`);
    const wallet = createWalletClient({
      account,
      chain: baseSepolia,
      transport: http(SEPOLIA_RPC),
    });
    const sepolia = createPublicClient({ chain: baseSepolia, transport: http(SEPOLIA_RPC) });

    const hash = await wallet.writeContract({
      address: SEPOLIA_FEED as `0x${string}`,
      abi: mockOracleAbi,
      functionName: "setRound",
      args: [price8, now - 120n, now - 60n],
    });
    await sepolia.waitForTransactionReceipt({ hash });

    return res.status(200).json({ ok: true, priceUsd, tx: hash });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return res.status(500).json({ error: message });
  }
}
