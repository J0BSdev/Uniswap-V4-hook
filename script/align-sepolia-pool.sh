#!/usr/bin/env bash
# Sync mock oracle + move Sepolia pool spot to live Base mainnet Chainlink ETH/USD.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${RPC:-https://sepolia.base.org}"
MAINNET_RPC="${MAINNET_RPC:-https://mainnet.base.org}"
KEY="${PRIVATE_KEY:?Set PRIVATE_KEY}"
HOOK="${HOOK:-0x06411956e4Eee3971B637A03F1fdc3657C5ce080}"
FEED="${FEED:-0xfA23B8D1773F2A49bE5BE6A846F7ea28160CE451}"
MAINNET_FEED="${MAINNET_FEED:-0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70}"

ORACLE_PRICE8=$(cast call "$MAINNET_FEED" "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url "$MAINNET_RPC" | awk 'NR==2 {print $1}')
ORACLE_USD=$((ORACLE_PRICE8 / 100000000))
echo "==> Live Chainlink ETH/USD: \$${ORACLE_USD}"

cd "$ROOT"
HOOK_ADDR="$HOOK" ETH_USD_FEED="$FEED" ORACLE_PRICE8="$ORACLE_PRICE8" \
  forge script script/AlignSepoliaPool.s.sol:AlignSepoliaPool \
  --rpc-url "$RPC" --broadcast --private-key "$KEY"

echo "==> Done. Redeploy frontend if hook/pool env changed."
