import { Header } from "./components/Header";
import { FeeGauge } from "./components/FeeGauge";
import { PricePanel } from "./components/PricePanel";
import { TierLegend } from "./components/TierLegend";
import { SwapCard } from "./components/SwapCard";
import { ActivityFeed } from "./components/ActivityFeed";
import { useTerminal } from "./state/TerminalContext";
import { ENV } from "./config/contracts";

function StatusBanner() {
  const { isDemo, liveError } = useTerminal();
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
        <strong>Demo mode.</strong> Running on a simulated WETH/USDC pool and oracle. Set
        <code> VITE_HOOK_ADDRESS</code> and <code>VITE_POOL_ID</code> in <code>.env.local</code> to read live data from
        Base.
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
          <span>DynamicLPFeesHook · Uniswap V4 · {ENV.chainId === 84532 ? "Base Sepolia" : ENV.baseRpcUrl.includes("127.0.0.1") ? "Base fork" : "Base"}</span>
          <span className="muted">Fees rise with execution risk to protect LPs from toxic flow.</span>
        </footer>
      </div>
    </div>
  );
}
