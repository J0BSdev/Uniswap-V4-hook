const usd0 = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 0,
});

const usd2 = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

export function fmtUsd(n: number, decimals: 0 | 2 = 2): string {
  if (!Number.isFinite(n)) return "—";
  return decimals === 0 ? usd0.format(n) : usd2.format(n);
}

export function fmtNum(n: number, max = 4): string {
  if (!Number.isFinite(n)) return "—";
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: max }).format(n);
}

export function fmtPct(n: number, max = 2): string {
  if (!Number.isFinite(n)) return "—";
  return `${new Intl.NumberFormat("en-US", { maximumFractionDigits: max }).format(n)}%`;
}

export function fmtBps(bps: number): string {
  return `${new Intl.NumberFormat("en-US").format(Math.round(bps))} bps`;
}

export function shortAddr(addr?: string): string {
  if (!addr) return "";
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}
