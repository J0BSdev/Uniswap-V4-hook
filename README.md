# DynamicLPFeesHook

DynamicLPFeesHook is a work-in-progress Uniswap v4 hook focused on protecting liquidity providers by dynamically adjusting swap fees based on pool price deviation.

Instead of using a fixed fee for every swap, the hook compares the current Uniswap pool price with a Chainlink ETH/USD reference price. When the pool price moves further away from the oracle reference price, the hook increases the swap fee so liquidity providers are better compensated for higher execution risk.

## Vision

Liquidity providers are exposed to higher risk when pool prices move away from fair market value. Static fee pools do not react to changing market conditions, even when the pool price becomes significantly different from an external market reference.

This hook is designed to make LP fees more adaptive:

* low-risk swaps pay a lower fee
* higher-risk swaps pay a higher fee
* LPs earn more when pool price deviation increases
* the pool becomes more resilient during volatile or abnormal market conditions

## How It Works

Before each swap, the hook calculates a risk score based on price deviation.

The hook:

1. Reads the latest Chainlink ETH/USD reference price.
2. Reads the current Uniswap pool price from `sqrtPriceX96`.
3. Converts the pool price into the same price scale as Chainlink.
4. Calculates the deviation between the pool price and the oracle price.
5. Selects a dynamic fee tier based on that deviation.
6. Returns the selected fee to Uniswap v4 using the dynamic fee override mechanism.

If the pool price is close to the Chainlink reference price, the swap is considered lower risk.

If the pool price deviates significantly from the Chainlink reference price, the swap is considered higher risk and receives a higher fee.

## Fee Tiers

The hook currently uses simple deviation-based fee tiers:

* deviation below 1% → 0.5% fee
* deviation below 5% → 1% fee
* deviation below 20% → 3% fee
* deviation above 20% → 5% fee

These tiers are designed to keep fees lower during normal market conditions and increase LP compensation when execution risk is higher.

## Main Features

* Uniswap v4 `beforeSwap` hooks
* Dynamic LP fee calculation
* Chainlink ETH/USD oracle integration
* Base sequencer uptime check
* Oracle freshness check
* Incomplete oracle round protection
* Pool price calculation from `sqrtPriceX96`
* Dynamic-fee-only pool validation
* WETH/USDC pool validation
* Frontend-friendly `previewFee` function
* `FeeAdjusted` event for tracking fee changes

## Why This Project

Most AMM pools use static fee tiers, even though swap risk changes over time.

A swap executed when the pool price is close to fair market value is not the same as a swap executed when the pool price is far away from an external reference price.

DynamicLPFeesHook experiments with a more adaptive model where LPs are compensated based on oracle-aware execution risk.

The goal is not to block trading by default, but to make liquidity provision more risk-aware.

## Current Status

The project is in active development.

The current implementation focuses on:

* comparing Uniswap pool price against Chainlink ETH/USD
* calculating price deviation in basis points
* assigning dynamic fee tiers
* validating oracle and sequencer safety
* testing normal, risky and edge-case scenarios



## Roadmap

* Add liquidity-aware risk scoring
* Add trade-size based fee adjustments
* Add TWAP-based volatility scoring
* Add optional multi-oracle support
* Add gas benchmarks
* Expand test coverage



## Try the demo (fork)

Interactive demo on a **local Base mainnet fork** — no MetaMask, no testnet ETH. Fee tiers react to oracle vs pool divergence in real time.

### Prerequisites

* [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)
* Node.js 18+ and `npm`

### 1. Contract tests

```bash
forge test
```

All hook tests should pass (159+).

### 2. Start the fork demo

From the repo root:

```bash
bash script/setup-fork.sh
cd frontend && npm install && npm run dev:fork
```

Open **http://127.0.0.1:5173/**

`setup-fork.sh` starts anvil (Base fork), deploys the hook + WETH/USDC pool, installs a controllable mock Chainlink feed, and writes `frontend/.env.fork.local`.

### 3. Manual test checklist

Use the UI at http://127.0.0.1:5173/:

| Step | Action | Expected |
|------|--------|----------|
| 1 | Load page | Fee gauge ~**0.5%**, divergence ~**0 bps**, pool ≈ Chainlink ETH/USD |
| 2 | Click **+1%** (oracle) | Fee rises to **1%** (elevated tier), divergence ~100 bps |
| 3 | Click **Align to Chainlink** | Fee back to **0.5%**, divergence ~0 |
| 4 | Click **+1%** again, then **−1%** | Fee tier moves up/down with oracle |
| 5 | Enter swap amount, click **Swap** | On-chain swap confirms; activity feed shows applied fee |

Fee comes from the hook’s on-chain `previewFee` (oracle deviation only). The swap card quote uses the same tier.

### 4. Optional: CLI sanity check

After `setup-fork.sh`, with addresses from `frontend/.env.fork.local`:

```bash
source frontend/.env.fork.local
cast call $VITE_HOOK_ADDRESS \
  "previewFee(bytes32)(uint24,uint256)" $VITE_POOL_ID \
  --rpc-url $VITE_BASE_RPC_URL
# → 5000 0  (0.5% fee, 0 bps deviation when aligned)
```

### Troubleshooting

| Problem | Fix |
|---------|-----|
| Page shows demo mode, no fork controls | Re-run `bash script/setup-fork.sh`, then `npm run dev:fork` |
| Align / oracle buttons error | Hard refresh (Ctrl+Shift+R); ensure anvil is running on `:8545` |
| Stale oracle / weird fees | Re-run `bash script/setup-fork.sh` (resets fork state) |

### Base Sepolia (testnet)

For a live testnet deploy (MetaMask, real RPC), use `.env` + deploy scripts — see `script/DeployBaseSepolia.s.sol` and `script/verify-sepolia.sh`. The fork demo above is the recommended path for reviewers.