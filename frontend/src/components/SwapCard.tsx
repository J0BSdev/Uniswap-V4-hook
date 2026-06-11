import { useMemo, useState, type CSSProperties, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useTerminal } from "../state/TerminalContext";
import type { SwapDir } from "../lib/demoPool";
import { TIERS, feePipsToPercent } from "../lib/feeMath";
import { fmtBps, fmtNum, fmtPct } from "../lib/format";
import { CAN_SWAP_ONCHAIN } from "../config/contracts";
import { executeOnchainSwap } from "../lib/swapOnchain";

const DEFAULT_SWAP_AMOUNT = CAN_SWAP_ONCHAIN ? "0.1" : "1";

export function SwapCard() {
  const { quote, executeSwap } = useTerminal();
  const queryClient = useQueryClient();
  const [dir, setDir] = useState<SwapDir>("WETH_TO_USDC");
  const [amount, setAmount] = useState(DEFAULT_SWAP_AMOUNT);
  const [flash, setFlash] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

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

  async function onSwap() {
    if (!q || busy) return;
    setErrorMsg(null);

    if (CAN_SWAP_ONCHAIN) {
      setBusy(true);
      setFlash(`Submitting ${tokenIn}→${tokenOut} swap…`);
      try {
        const res = await executeOnchainSwap(tokenIn, amt, q.feePips);
        const appliedFee = res.feePips > 0 ? res.feePips : q.feePips;
        setFlash(
          `On-chain swap confirmed · applied fee ${fmtPct(feePipsToPercent(appliedFee))} (${res.hash.slice(
            0,
            10
          )}…)`
        );
        await queryClient.invalidateQueries();
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        setErrorMsg(msg.length > 140 ? `${msg.slice(0, 140)}…` : msg);
        setFlash(null);
      } finally {
        setBusy(false);
        setTimeout(() => setFlash(null), 5000);
      }
      return;
    }

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
        <span className="muted">
          {CAN_SWAP_ONCHAIN ? "live on-chain · dynamic fee applied" : "what-if simulator · applies the live tier"}
        </span>
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
        <Row label="Swap fee (oracle + size)">
          <strong style={{ color: tierAccent }}>{q ? fmtPct(q.feePercent) : "—"}</strong>
        </Row>
        <Row label="Fee amount">{q ? `${fmtNum(q.feeAmount)} ${tokenIn}` : "—"}</Row>
        <Row label="Price impact">{q ? fmtPct(q.priceImpactPct) : "—"}</Row>
        <Row label="Divergence after">{q ? fmtBps(q.deviationBpsAfter) : "—"}</Row>
      </div>

      <button className="btn btn-primary btn-swap" disabled={!q || busy} onClick={onSwap}>
        {busy ? "Confirming…" : q ? `Swap ${tokenIn} for ${tokenOut}` : "Enter an amount"}
      </button>

      {flash && <div className="flash">{flash}</div>}
      {errorMsg && <div className="flash flash-error">{errorMsg}</div>}
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
