import { useTerminal } from "../state/TerminalContext";
import { ConnectButton } from "./ConnectButton";

export function Header() {
  const { isDemo } = useTerminal();
  return (
    <header className="header">
      <div className="brand">
        <div className="brand-mark" aria-hidden>
          <span />
          <span />
          <span />
        </div>
        <div className="brand-text">
          <h1>
            Dynamic LP Fees<span className="brand-sub">/ WETH·USDC risk terminal</span>
          </h1>
          <p>Uniswap V4 hook on Base — fees scale with pool-vs-oracle divergence</p>
        </div>
      </div>
      <div className="header-actions">
        {isDemo && (
          <span className="badge badge-demo" title="No hook address configured — running on a simulated pool">
            DEMO
          </span>
        )}
        <ConnectButton />
      </div>
    </header>
  );
}
