import { useTerminal } from "../state/TerminalContext";
import { FEE, SCORE, TIERS, feePipsToPercent } from "../lib/feeMath";
import { fmtPct } from "../lib/format";

const ROWS = [
  { tier: "LOW" as const, range: `0 – ${SCORE.LOW} bps`, fee: FEE.LOW },
  { tier: "MEDIUM" as const, range: `${SCORE.LOW} – ${SCORE.MEDIUM} bps`, fee: FEE.MEDIUM },
  { tier: "HIGH" as const, range: `${SCORE.MEDIUM} – ${SCORE.HIGH} bps`, fee: FEE.HIGH },
  { tier: "VERY_HIGH" as const, range: `≥ ${SCORE.HIGH} bps`, fee: FEE.VERY_HIGH },
];

export function TierLegend() {
  const { tier } = useTerminal();
  return (
    <section className="card legend-card">
      <div className="card-head">
        <span className="card-title">Fee tiers</span>
        <span className="muted">divergence → fee</span>
      </div>
      <div className="legend-list">
        {ROWS.map((r) => {
          const info = TIERS[r.tier];
          const active = tier === r.tier;
          return (
            <div key={r.tier} className={`legend-row ${active ? "active" : ""}`}>
              <span className="legend-dot" style={{ background: info.accent }} />
              <span className="legend-name">{info.label}</span>
              <span className="legend-range">{r.range}</span>
              <span className="legend-fee" style={{ color: active ? info.accent : undefined }}>
                {fmtPct(feePipsToPercent(r.fee))}
              </span>
            </div>
          );
        })}
      </div>
    </section>
  );
}
