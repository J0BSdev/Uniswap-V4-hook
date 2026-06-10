import { useTerminal } from "../state/TerminalContext";
import { TIERS, feePipsToPercent } from "../lib/feeMath";
import { fmtBps, fmtPct } from "../lib/format";

function timeAgo(ts: number): string {
  const s = Math.max(0, Math.floor((Date.now() - ts) / 1000));
  if (s < 5) return "just now";
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  return `${m}m ago`;
}

export function ActivityFeed() {
  const { events, resetPool, resetPoolBusy } = useTerminal();
  return (
    <section className="card feed-card">
      <div className="card-head">
        <span className="card-title">FeeAdjusted activity</span>
        <button className="btn btn-ghost btn-sm" disabled={resetPoolBusy} onClick={() => void resetPool()}>
          {resetPoolBusy ? "Resetting…" : "Reset pool"}
        </button>
      </div>
      {events.length === 0 ? (
        <p className="empty">No events yet. Swap or move the oracle to emit FeeAdjusted.</p>
      ) : (
        <ul className="feed-list">
          {events.map((e) => {
            const info = TIERS[e.tier];
            return (
              <li key={e.id} className="feed-item">
                <span className="feed-dot" style={{ background: info.accent }} />
                <span className="feed-note">{e.note}</span>
                <span className="feed-bps">{fmtBps(e.deviationBps)}</span>
                <span className="feed-fee" style={{ color: info.accent }}>
                  {fmtPct(feePipsToPercent(e.feePips))}
                </span>
                <span className="feed-time">{timeAgo(e.ts)}</span>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
