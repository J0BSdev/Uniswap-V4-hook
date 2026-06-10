#!/usr/bin/env bash
# Build + deploy the Vite frontend to Vercel (public URL, Base Sepolia).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/frontend"

echo "==> Building production bundle (Base Sepolia)..."
# .env.local overrides .env.production in Vite — hide fork dev config during prod builds.
ENV_LOCAL_BACKUP=""
if [ -f .env.local ]; then
  ENV_LOCAL_BACKUP="$(mktemp)"
  mv .env.local "$ENV_LOCAL_BACKUP"
  trap 'mv -f "$ENV_LOCAL_BACKUP" .env.local 2>/dev/null || true' EXIT
fi
env -u VITE_HOOK_ADDRESS -u VITE_POOL_ID -u VITE_SWAP_ROUTER -u VITE_LP_TICK_LOWER \
  -u VITE_LP_TICK_UPPER -u VITE_BASE_RPC_URL -u VITE_DEV_PRIVATE_KEY -u VITE_CHAIN_ID \
  npm run build:pages

echo "==> Deploying to Vercel..."
if command -v vercel >/dev/null 2>&1; then
  vercel deploy --prod --yes
else
  npx vercel@latest deploy --prod --yes
fi
