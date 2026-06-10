import { useState } from "react";
import { useTerminal } from "../state/TerminalContext";
import { fmtBps, fmtNum, fmtUsd } from "../lib/format";

export function PricePanel() {
  const {
    poolPrice,
    oraclePrice,
    deviationBps,
    clReserves,
    liquidity,
    oracleLive,
    toggleOracleLive,
    setOraclePrice,
    nudgeOracle,
    nudgePool,
    refreshOracle,
    mode,
    isFork,
    canNudgeMockOracle,
    liveError,
  } = useTerminal();
  const [draft, setDraft] = useState("");
  const isLive = mode === "live";

  const poolAbove = poolPrice >= oraclePrice;

  function applyDraft() {
    const v = parseFloat(draft);
    if (Number.isFinite(v) && v > 0) void setOraclePrice(v);
    setDraft("");
  }

  return (
    <section className="card price-card">
      <div className="card-head">
        <span className="card-title">Price feeds</span>
        {isLive && isFork ? (
          <button className={`chip ${oracleLive ? "chip-on" : ""}`} onClick={toggleOracleLive}>
            <span className="dot" /> {oracleLive ? "Oracle drift on" : "Oracle drift off"}
          </button>
        ) : isLive ? (
          <span className="chip chip-on">
            <span className="dot" /> On-chain · auto-refresh
          </span>
        ) : (
          <button className={`chip ${oracleLive ? "chip-on" : ""}`} onClick={toggleOracleLive}>
            <span className="dot" /> {oracleLive ? "Oracle live" : "Oracle paused"}
          </button>
        )}
      </div>

      <div className="price-grid">
        <div className="price-cell">
          <span className="price-label">Pool price</span>
          <span className="price-value">{fmtUsd(poolPrice)}</span>
          <span className="price-sub">spot from sqrtPriceX96</span>
        </div>
        <div className="price-cell">
          <span className="price-label">Chainlink ETH/USD</span>
          <span className="price-value">{fmtUsd(oraclePrice)}</span>
          <span className="price-sub">{isFork ? "mock oracle · fork" : canNudgeMockOracle ? "mock oracle · Sepolia" : "reference oracle"}</span>
        </div>
        {clReserves && (
          <div className="price-cell">
            <span className="price-label">CL depth (seeded range)</span>
            <span className="price-value">{fmtNum(clReserves.weth)} WETH</span>
            <span className="price-sub">{fmtNum(clReserves.usdc)} USDC · L={liquidity.toString()}</span>
          </div>
        )}
      </div>

      <div className="dev-row">
        <div className="dev-bar">
          <div
            className={`dev-fill ${poolAbove ? "up" : "down"}`}
            style={{ width: `${Math.min(100, (deviationBps / 3000) * 100)}%` }}
          />
        </div>
        <div className="dev-meta">
          <span className={poolAbove ? "up-text" : "down-text"}>
            {poolAbove ? "▲ pool above" : "▼ pool below"} oracle
          </span>
          <strong>{fmtBps(deviationBps)}</strong>
        </div>
      </div>

      {isLive && isFork ? (
        <>
          <div className="fork-controls">
            <span className="fork-label">Oracle</span>
            <button className="btn btn-ghost btn-sm" onClick={() => void nudgeOracle(-1)}>
              −1%
            </button>
            <button className="btn btn-ghost btn-sm" onClick={() => void nudgeOracle(1)}>
              +1%
            </button>
            <span className="fork-label">Pool</span>
            <button className="btn btn-ghost btn-sm" onClick={() => void nudgePool(3)}>
              Swap 3 WETH ↓
            </button>
          </div>
          <div className="oracle-control">
            <input
              className="input"
              placeholder="Set oracle ETH/USD…"
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && applyDraft()}
              inputMode="decimal"
            />
            <button className="btn btn-ghost" onClick={applyDraft}>
              Set
            </button>
          </div>
          <p className="hint">
            Fork mode: oracle auto-drifts every 4s (toggle above). Use buttons or swap to create divergence and
            watch the fee tier react via real <code>previewFee</code>.
          </p>
        </>
      ) : isLive && canNudgeMockOracle ? (
        <>
          {liveError?.includes("stale") && (
            <div className="fork-controls">
              <button className="btn btn-primary btn-sm" onClick={() => void refreshOracle()}>
                Refresh oracle
              </button>
              <span className="hint" style={{ margin: 0 }}>
                Connect MetaMask on Base Sepolia, then refresh stale mock Chainlink timestamps.
              </span>
            </div>
          )}
          <div className="fork-controls">
            <span className="fork-label">Oracle</span>
            <button className="btn btn-ghost btn-sm" onClick={() => void nudgeOracle(-1)}>
              −1%
            </button>
            <button className="btn btn-ghost btn-sm" onClick={() => void nudgeOracle(1)}>
              +1%
            </button>
          </div>
          <div className="oracle-control">
            <input
              className="input"
              placeholder="Set oracle ETH/USD…"
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && applyDraft()}
              inputMode="decimal"
            />
            <button className="btn btn-ghost" onClick={applyDraft}>
              Set
            </button>
          </div>
          <p className="hint">
            Base Sepolia testnet: mock Chainlink feed — nudge the oracle to watch <code>previewFee</code> tiers update
            live.
          </p>
        </>
      ) : isLive ? (
        <p className="hint">
          Live values from the deployed hook’s <code>previewFee</code>, Chainlink ETH/USD, and on-chain{" "}
          <code>sqrtPriceX96</code>.
        </p>
      ) : (
        <>
          <div className="oracle-control">
            <input
              className="input"
              placeholder="Set oracle ETH/USD…"
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && applyDraft()}
              inputMode="decimal"
            />
            <button className="btn btn-ghost" onClick={applyDraft}>
              Set
            </button>
          </div>
          <p className="hint">
            Move the oracle (or swap to move the pool) to watch the fee tier react in real time.
          </p>
        </>
      )}
    </section>
  );
}
