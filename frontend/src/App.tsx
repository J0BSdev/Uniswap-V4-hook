import { Header } from "./components/Header";
import { FeeGauge } from "./components/FeeGauge";
import { PricePanel } from "./components/PricePanel";
import { TierLegend } from "./components/TierLegend";
import { SwapCard } from "./components/SwapCard";
import { ActivityFeed } from "./components/ActivityFeed";
import { useTerminal } from "./state/TerminalContext";
import { ENV, IS_FORK_DEV } from "./config/contracts";

function StatusBanner() {
  const { isDemo, liveError, mode, deviationBps } = useTerminal();
  const isLive = mode === "live";
  const isSepolia = ENV.chainId === 84532;
  const poolMisaligned = isLive && isSepolia && deviationBps > 500;

  if (liveError) {
    return (
      <div className="demo-banner banner-error">
        <strong>Live read issue:</strong> {liveError}. Check the RPC and that the pool is initialized.
      </div>
    );
  }
  if (isDemo) {
    return (
      <div className="demo-banner">
        <strong>Demo mode.</strong> Set <code>VITE_HOOK_ADDRESS</code> and <code>VITE_POOL_ID</code> in{" "}
        <code>.env.development</code> (Sepolia) or run <code>bash script/setup-fork.sh</code> for the local fork.
      </div>
    );
  }
  if (IS_FORK_DEV) {
    return (
      <div className="demo-banner banner-fork">
        <strong>Local fork demo.</strong> Full swap + align works via dev key — no MetaMask needed. Best way to try
        the hook after cloning the repo.
      </div>
    );
  }
  if (poolMisaligned) {
    return (
      <div className="demo-banner banner-warn">
        <strong>Pool vs oracle mismatch.</strong> Spot and Chainlink reference differ — fees are elevated. Connect
        MetaMask on Base Sepolia and use <strong>Align to Chainlink</strong> (needs ETH + WETH/USDC), or run{" "}
        <code>bash script/setup-fork.sh</code> for a working local demo.
      </div>
    );
  }
  if (isSepolia) {
    return (
      <div className="demo-banner banner-sepolia">
        <strong>Base Sepolia testnet.</strong> Connect MetaMask on chain 84532 to swap. Chainlink reference is read
        from Base mainnet.
      </div>
    );
  }
  return null;
}

export default function App() {
  return (
    <div className="app">
      <div className="bg-grid" aria-hidden />
      <div className="container">
        <Header />
        <StatusBanner />
        <main className="grid">
          <div className="col col-left">
            <FeeGauge />
            <PricePanel />
            <TierLegend />
          </div>
          <div className="col col-right">
            <SwapCard />
            <ActivityFeed />
          </div>
        </main>
        <footer className="footer">
          <span>DynamicLPFeesHook · Uniswap V4 · {ENV.chainId === 84532 ? "Base Sepolia testnet" : ENV.baseRpcUrl.includes("127.0.0.1") ? "Base fork" : "Base"}</span>
          <span className="muted">Fees rise with execution risk to protect LPs from toxic flow.</span>
        </footer>
      </div>
    </div>
  );
}
