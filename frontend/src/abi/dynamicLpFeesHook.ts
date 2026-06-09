// Minimal ABI for the read paths the frontend needs from DynamicLPFeesHook.
export const dynamicLpFeesHookAbi = [
  {
    type: "function",
    name: "previewFee",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      { name: "feePips", type: "uint24" },
      { name: "priceDeviationBps", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "previewFee",
    stateMutability: "view",
    inputs: [
      { name: "poolId", type: "bytes32" },
      { name: "amountSpecified", type: "int256" },
    ],
    outputs: [
      { name: "feePips", type: "uint24" },
      { name: "riskScoreBps", type: "uint256" },
    ],
  },
  { type: "function", name: "MIN_FEE", stateMutability: "view", inputs: [], outputs: [{ type: "uint24" }] },
  { type: "function", name: "LOW_FEE", stateMutability: "view", inputs: [], outputs: [{ type: "uint24" }] },
  { type: "function", name: "MEDIUM_FEE", stateMutability: "view", inputs: [], outputs: [{ type: "uint24" }] },
  { type: "function", name: "HIGH_FEE", stateMutability: "view", inputs: [], outputs: [{ type: "uint24" }] },
  { type: "function", name: "VERY_HIGH_FEE", stateMutability: "view", inputs: [], outputs: [{ type: "uint24" }] },
  { type: "function", name: "MAX_FEE", stateMutability: "view", inputs: [], outputs: [{ type: "uint24" }] },
  { type: "function", name: "SCORE_LOW", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "SCORE_MEDIUM", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "SCORE_HIGH", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "event",
    name: "FeeAdjusted",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "feePips", type: "uint24", indexed: false },
      { name: "riskScoreBps", type: "uint256", indexed: false },
    ],
  },
] as const;
