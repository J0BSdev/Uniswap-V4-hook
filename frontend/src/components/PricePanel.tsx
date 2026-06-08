import { useState } from "react";
import { useTerminal } from "../state/TerminalContext";
import { fmtBps, fmtUsd } from "../lib/format";

export function PricePanel() {
  const { poolPrice, oraclePrice, deviationBps, oracleLive, toggleOracleLive, setOraclePrice, mode } =
    useTerminal();
  const [draft, setDraft] = useState("");
  const isLive = mode === "live";

  const poolAbove = poolPrice >= oraclePrice;

  function applyDraft() {
    const v = parseFloat(draft);
    if (Number.isFinite(v) && v > 0) setOraclePrice(v);
    setDraft("");
  }

  return (
    <section className="card price-card">
      <div className="card-head">
        <span className="card-title">Price feeds</span>
        {isLive ? (
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
          <span className="price-sub">reference oracle</span>
        </div>
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

      {isLive ? (
        <p className="hint">
          Live values from the deployed hook’s <code>previewFee</code>, the Chainlink ETH/USD feed, and the
          pool’s on-chain <code>sqrtPriceX96</code>.
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
