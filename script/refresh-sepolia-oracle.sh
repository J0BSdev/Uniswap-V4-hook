#!/usr/bin/env bash
# Sync Base Sepolia mock Chainlink to the live Base mainnet ETH/USD price.
set -euo pipefail

RPC="${RPC:-https://sepolia.base.org}"
MAINNET_RPC="${MAINNET_RPC:-https://mainnet.base.org}"
KEY="${PRIVATE_KEY:?Set PRIVATE_KEY}"
FEED="${FEED:-0xfA23B8D1773F2A49bE5BE6A846F7ea28160CE451}"
MAINNET_FEED="${MAINNET_FEED:-0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70}"

PRICE=$(cast call "$MAINNET_FEED" "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url "$MAINNET_RPC" | awk 'NR==2 {print $1}')
echo "==> Mainnet Chainlink ETH/USD: $((PRICE / 100000000)) USD (raw $PRICE)"

NOW=$(date +%s)
cast send "$FEED" "setRound(int256,uint256,uint256)" "$PRICE" $((NOW - 120)) $((NOW - 60)) \
  --private-key "$KEY" --rpc-url "$RPC"

echo "==> Sepolia mock oracle synced. Verify previewFee:"
HOOK="${HOOK:-0x06411956e4Eee3971B637A03F1fdc3657C5ce080}"
POOL="${POOL:-0x2ef867edda8d06c391d7912624e692b9e6d792f8f1b0ed01c2206d125b24b164}"
cast call "$HOOK" "previewFee(bytes32)(uint24,uint256)" "$POOL" --rpc-url "$RPC"
