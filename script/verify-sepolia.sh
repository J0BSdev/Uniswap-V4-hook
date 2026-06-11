#!/usr/bin/env bash
# Verify DynamicLPFeesHook (+ mock feeds) on Base Sepolia after setup-sepolia.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -f .env ]; then set -a; source .env; set +a; fi

RPC="${RPC:-${BASE_RPC_URL:-https://sepolia.base.org}}"
KEY="${PRIVATE_KEY:?Set PRIVATE_KEY in .env}"
API="${BASESCAN_API_KEY:?Set BASESCAN_API_KEY in .env}"
HOOK="${HOOK_ADDR:-${HOOK_ADDRESS:-}}"
FEED="${ORACLE_FEED:-}"

if [ -z "$HOOK" ]; then
  ENV_FILE="$ROOT/frontend/.env.development"
  if [ -f "$ENV_FILE" ]; then
    HOOK=$(grep '^VITE_HOOK_ADDRESS=' "$ENV_FILE" | cut -d= -f2)
    FEED=$(grep '^VITE_ETH_USD_FEED=' "$ENV_FILE" | cut -d= -f2)
  fi
fi

if [ -z "$HOOK" ]; then
  echo "Set HOOK_ADDR or run setup-sepolia.sh first"
  exit 1
fi

PM="0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408"
WETH="0x4200000000000000000000000000000000000006"
USDC="0x036CbD53842c5426634e7929541eC2318f3dCF7e"

# Read feeds from hook if not provided
if [ -z "$FEED" ]; then
  FEED=$(cast call "$HOOK" "priceFeed()(address)" --rpc-url "$RPC")
fi
SEQ=$(cast call "$HOOK" "sequencerUptimeFeed()(address)" --rpc-url "$RPC")

ARGS=$(cast abi-encode "constructor(address,address,address,address,address)" "$PM" "$WETH" "$USDC" "$FEED" "$SEQ")

echo "==> Verifying DynamicLPFeesHook at $HOOK ..."
forge verify-contract \
  "$HOOK" \
  src/LPFees/DynamicLPFeesHook.sol:DynamicLPFeesHook \
  --chain-id 84532 \
  --rpc-url "$RPC" \
  --etherscan-api-key "$API" \
  --constructor-args "$ARGS" \
  --watch

echo "==> Verifying mock price feed at $FEED ..."
forge verify-contract \
  "$FEED" \
  test/mocks/MockChainlinkAggregator.sol:MockChainlinkAggregator \
  --chain-id 84532 \
  --rpc-url "$RPC" \
  --etherscan-api-key "$API" \
  --watch || echo "(price feed verify skipped — may already be verified)"

echo "==> Done. Check: https://sepolia.basescan.org/address/$HOOK#code"
