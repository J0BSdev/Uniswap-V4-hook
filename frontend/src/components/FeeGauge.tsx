import type { CSSProperties } from "react";
import { useTerminal } from "../state/TerminalContext";
import { TIERS, deviationProgress, feePipsToPercent } from "../lib/feeMath";
import { fmtBps, fmtPct } from "../lib/format";

// Semicircular SVG gauge: sweep + color encode current risk/fee.
export function FeeGauge() {
  const { feePips, deviationBps, tier } = useTerminal();
  const info = TIERS[tier];
  const progress = deviationProgress(deviationBps);

  const R = 120;
  const CX = 150;
  const CY = 150;
  const circumference = Math.PI * R; // half circle
  const dash = circumference * progress;

  return (
    <section className="card gauge-card" style={{ "--accent": info.accent } as CSSProperties}>
      <div className="card-head">
        <span className="card-title">Oracle risk fee</span>
        <span className="tier-pill" style={{ background: info.accent }}>
          {info.label}
        </span>
      </div>

      <div className="gauge-wrap">
        <svg viewBox="0 0 300 170" className="gauge-svg">
          <path
            d={`M ${CX - R} ${CY} A ${R} ${R} 0 0 1 ${CX + R} ${CY}`}
            className="gauge-track"
            fill="none"
            strokeWidth="16"
            strokeLinecap="round"
          />
          <path
            d={`M ${CX - R} ${CY} A ${R} ${R} 0 0 1 ${CX + R} ${CY}`}
            className="gauge-fill"
            fill="none"
            stroke={info.accent}
            strokeWidth="16"
            strokeLinecap="round"
            strokeDasharray={`${dash} ${circumference}`}
          />
        </svg>
        <div className="gauge-center">
          <div className="gauge-fee" style={{ color: info.accent }}>
            {fmtPct(feePipsToPercent(feePips))}
          </div>
          <div className="gauge-meta">{fmtBps(deviationBps)} divergence</div>
        </div>
      </div>

      <div className="gauge-foot">
        <span>{feePips.toLocaleString()} pips</span>
        <span className="muted">gauge from previewFee · oracle deviation only</span>
      </div>
    </section>
  );
}
