import { Header } from "./components/Header";
import { FeeGauge } from "./components/FeeGauge";
import { PricePanel } from "./components/PricePanel";
import { TierLegend } from "./components/TierLegend";
import { SwapCard } from "./components/SwapCard";
import { ActivityFeed } from "./components/ActivityFeed";
import { useTerminal } from "./state/TerminalContext";

function DemoBanner() {
  const { isDemo } = useTerminal();
  if (!isDemo) return null;
  return (
    <div className="demo-banner">
      <strong>Demo mode.</strong> Running on a simulated WETH/USDC pool and oracle. Set
      <code> VITE_HOOK_ADDRESS</code> and <code>VITE_POOL_ID</code> in <code>.env.local</code> to read live data from Base.
    </div>
  );
}

export default function App() {
  return (
    <div className="app">
      <div className="bg-grid" aria-hidden />
      <div className="container">
        <Header />
        <DemoBanner />
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
          <span>DynamicLPFeesHook · Uniswap V4 · Base</span>
          <span className="muted">Fees rise with execution risk to protect LPs from toxic flow.</span>
        </footer>
      </div>
    </div>
  );
}
