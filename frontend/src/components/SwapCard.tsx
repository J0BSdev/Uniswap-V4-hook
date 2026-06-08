import { useMemo, useState, type CSSProperties, type ReactNode } from "react";
import { useTerminal } from "../state/TerminalContext";
import type { SwapDir } from "../lib/demoPool";
import { TIERS } from "../lib/feeMath";
import { fmtBps, fmtNum, fmtPct } from "../lib/format";

export function SwapCard() {
  const { quote, executeSwap, isDemo } = useTerminal();
  const [dir, setDir] = useState<SwapDir>("WETH_TO_USDC");
  const [amount, setAmount] = useState("1");
  const [flash, setFlash] = useState<string | null>(null);

  const tokenIn = dir === "WETH_TO_USDC" ? "WETH" : "USDC";
  const tokenOut = dir === "WETH_TO_USDC" ? "USDC" : "WETH";

  const amt = parseFloat(amount);
  const q = useMemo(
    () => (Number.isFinite(amt) && amt > 0 ? quote(amt, dir) : null),
    [amt, dir, quote]
  );

  const tierAccent = q ? TIERS[tierFromFee(q.feePips)].accent : "var(--accent)";

  function flip() {
    setDir((d) => (d === "WETH_TO_USDC" ? "USDC_TO_WETH" : "WETH_TO_USDC"));
  }

  function onSwap() {
    if (!q) return;
    const res = executeSwap(amt, dir);
    setFlash(
      `Swapped ${fmtNum(res.amountIn)} ${res.tokenIn} → ${fmtNum(res.amountOut)} ${res.tokenOut} · fee ${fmtPct(
        res.feePercent
      )}`
    );
    setTimeout(() => setFlash(null), 3200);
  }

  return (
    <section className="card swap-card" style={{ "--accent": tierAccent } as CSSProperties}>
      <div className="card-head">
        <span className="card-title">Swap</span>
        <span className="muted">{isDemo ? "simulated" : "live"} · dynamic fee applied</span>
      </div>

      <div className="swap-field">
        <div className="swap-field-top">
          <span>You pay</span>
        </div>
        <div className="swap-field-row">
          <input
            className="amount-input"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            inputMode="decimal"
            placeholder="0.0"
          />
          <span className="token-pill">{tokenIn}</span>
        </div>
      </div>

      <div className="flip-row">
        <button className="flip-btn" onClick={flip} aria-label="Flip direction">
          ⇅
        </button>
      </div>

      <div className="swap-field">
        <div className="swap-field-top">
          <span>You receive</span>
        </div>
        <div className="swap-field-row">
          <input className="amount-input muted" value={q ? fmtNum(q.amountOut) : "0.0"} readOnly />
          <span className="token-pill">{tokenOut}</span>
        </div>
      </div>

      <div className="quote-box">
        <Row label="Dynamic fee">
          <strong style={{ color: tierAccent }}>{q ? fmtPct(q.feePercent) : "—"}</strong>
        </Row>
        <Row label="Fee amount">{q ? `${fmtNum(q.feeAmount)} ${tokenIn}` : "—"}</Row>
        <Row label="Price impact">{q ? fmtPct(q.priceImpactPct) : "—"}</Row>
        <Row label="Divergence after">{q ? fmtBps(q.deviationBpsAfter) : "—"}</Row>
      </div>

      <button className="btn btn-primary btn-swap" disabled={!q} onClick={onSwap}>
        {q ? `Swap ${tokenIn} for ${tokenOut}` : "Enter an amount"}
      </button>

      {flash && <div className="flash">{flash}</div>}
    </section>
  );
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="quote-row">
      <span className="muted">{label}</span>
      <span>{children}</span>
    </div>
  );
}

// Map an applied fee back to its tier so the swap card can color-code the quote.
function tierFromFee(feePips: number): "LOW" | "MEDIUM" | "HIGH" | "VERY_HIGH" {
  if (feePips <= TIERS.LOW.feePips) return "LOW";
  if (feePips <= TIERS.MEDIUM.feePips) return "MEDIUM";
  if (feePips <= TIERS.HIGH.feePips) return "HIGH";
  return "VERY_HIGH";
}
