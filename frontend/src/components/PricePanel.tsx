import { useState } from "react";
import { useTerminal } from "../state/TerminalContext";
import { fmtBps, fmtUsd } from "../lib/format";

export function PricePanel() {
  const {
    poolPrice,
    oraclePrice,
    chainlinkPrice,
    hookOraclePrice,
    deviationBps,
    oracleLive,
    toggleOracleLive,
    setOraclePrice,
    setPoolPrice,
    nudgeOracle,
    nudgePool,
    refreshOracle,
    syncToChainlink,
    syncOracleBusy,
    syncError,
    alignPoolBusy,
    resetPool,
    resetPoolBusy,
    mode,
    isFork,
    canNudgeMockOracle,
    liveError,
  } = useTerminal();
  const [oracleDraft, setOracleDraft] = useState("");
  const [poolDraft, setPoolDraft] = useState("");
  const isLive = mode === "live";
  const busy = syncOracleBusy || alignPoolBusy || resetPoolBusy;

  const refOracle = chainlinkPrice ?? hookOraclePrice ?? oraclePrice;
  const poolAbove = poolPrice >= refOracle;

  function applyOracleDraft() {
    const v = parseFloat(oracleDraft);
    if (Number.isFinite(v) && v > 0) void setOraclePrice(v);
    setOracleDraft("");
  }

  function applyPoolDraft() {
    const v = parseFloat(poolDraft);
    if (Number.isFinite(v) && v > 0) void setPoolPrice(v);
    setPoolDraft("");
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
            <span className="dot" /> Base Sepolia · testnet
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
          <span className="price-value">{fmtUsd(chainlinkPrice ?? oraclePrice)}</span>
          <span className="price-sub">
            {canNudgeMockOracle ? "live · Base mainnet Chainlink" : "on-chain Chainlink feed"}
          </span>
        </div>
        {canNudgeMockOracle && hookOraclePrice !== undefined && (
          <div className="price-cell">
            <span className="price-label">Hook oracle</span>
            <span className="price-value">{fmtUsd(hookOraclePrice)}</span>
            <span className="price-sub">on-chain · Sepolia hook feed</span>
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

      {(syncError || liveError) && (
        <p className="hint" style={{ color: "var(--danger, #ff4d5e)" }}>
          {syncError ?? liveError}
        </p>
      )}

      {isLive && isFork ? (
        <>
          <div className="fork-controls">
            <button className="btn btn-primary btn-sm" disabled={busy} onClick={() => void syncToChainlink()}>
              {busy ? "Aligning…" : "Align to Chainlink"}
            </button>
            <button className="btn btn-ghost btn-sm" disabled={busy} onClick={() => void resetPool()}>
              Reset pool
            </button>
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
              placeholder="Set pool ETH/USD…"
              value={poolDraft}
              onChange={(e) => setPoolDraft(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && applyPoolDraft()}
              inputMode="decimal"
            />
            <button className="btn btn-ghost" disabled={alignPoolBusy} onClick={applyPoolDraft}>
              Set pool
            </button>
          </div>
          <div className="oracle-control">
            <input
              className="input"
              placeholder="Set oracle ETH/USD…"
              value={oracleDraft}
              onChange={(e) => setOracleDraft(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && applyOracleDraft()}
              inputMode="decimal"
            />
            <button className="btn btn-ghost" onClick={applyOracleDraft}>
              Set oracle
            </button>
          </div>
          <p className="hint">
            Fork mode: use <strong>Align to Chainlink</strong> or <strong>Set pool</strong> to move spot price + oracle
            together. Swaps run via the local dev key.
          </p>
        </>
      ) : isLive && (canNudgeMockOracle || isFork) ? (
        <>
          <div className="fork-controls">
            <button className="btn btn-primary btn-sm" disabled={busy} onClick={() => void syncToChainlink()}>
              {busy ? "Aligning…" : "Align to Chainlink"}
            </button>
            {liveError?.includes("stale") && (
              <button className="btn btn-ghost btn-sm" onClick={() => void refreshOracle()}>
                Refresh timestamps
              </button>
            )}
          </div>
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
              placeholder="Set pool ETH/USD…"
              value={poolDraft}
              onChange={(e) => setPoolDraft(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && applyPoolDraft()}
              inputMode="decimal"
            />
            <button className="btn btn-ghost" disabled={alignPoolBusy} onClick={applyPoolDraft}>
              Set pool
            </button>
          </div>
          <div className="oracle-control">
            <input
              className="input"
              placeholder="Set hook oracle ETH/USD…"
              value={oracleDraft}
              onChange={(e) => setOracleDraft(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && applyOracleDraft()}
              inputMode="decimal"
            />
            <button className="btn btn-ghost" onClick={applyOracleDraft}>
              Set oracle
            </button>
          </div>
          <p className="hint">
            Base Sepolia testnet — connect MetaMask, then use <strong>Align to Chainlink</strong> or{" "}
            <strong>Set pool</strong>. Chainlink reference price is read from Base mainnet.
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
              value={oracleDraft}
              onChange={(e) => setOracleDraft(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && applyOracleDraft()}
              inputMode="decimal"
            />
            <button className="btn btn-ghost" onClick={applyOracleDraft}>
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
