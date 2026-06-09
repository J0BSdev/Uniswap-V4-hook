import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import {
  INITIAL_ORACLE,
  INITIAL_RESERVES,
  poolPrice,
  quoteSwap,
  type PoolReserves,
  type SwapDir,
  type SwapQuote,
} from "../lib/demoPool";
import { deviationBps, feeForDeviationBps, tierForDeviationBps, type Tier } from "../lib/feeMath";
import { ENV, IS_DEMO } from "../config/contracts";
import { useLiveFee } from "../hooks/useLiveFee";
import { reservesFromLiquidity } from "../lib/clReserves";

export interface FeeEvent {
  id: number;
  ts: number;
  feePips: number;
  deviationBps: number;
  tier: Tier;
  note: string;
}

interface TerminalState {
  isDemo: boolean;
  mode: "demo" | "live";
  liveError?: string;
  reserves: PoolReserves;
  oraclePrice: number;
  poolPrice: number;
  deviationBps: number;
  feePips: number;
  tier: Tier;
  events: FeeEvent[];
  oracleLive: boolean;
  // actions
  setOraclePrice: (p: number) => void;
  toggleOracleLive: () => void;
  quote: (amountIn: number, dir: SwapDir) => SwapQuote;
  executeSwap: (amountIn: number, dir: SwapDir) => SwapQuote;
  resetPool: () => void;
}

const Ctx = createContext<TerminalState | null>(null);

let eventSeq = 0;

export function TerminalProvider({ children }: { children: ReactNode }) {
  const [reserves, setReserves] = useState<PoolReserves>(INITIAL_RESERVES);
  const [oraclePrice, setOracle] = useState<number>(INITIAL_ORACLE);
  const [oracleLive, setOracleLive] = useState<boolean>(true);
  const [events, setEvents] = useState<FeeEvent[]>([]);
  const oracleRef = useRef(oraclePrice);
  oracleRef.current = oraclePrice;

  const live = useLiveFee();
  const isLive = live.configured && !live.error && live.feePips !== undefined;

  // Demo-derived values (used in demo mode and for the what-if swap simulator).
  const demoPoolPrice = poolPrice(reserves);
  const demoDev = deviationBps(demoPoolPrice, oraclePrice);

  // Displayed values prefer live on-chain data when a hook is configured.
  const pPrice = isLive && live.poolPrice !== undefined ? live.poolPrice : demoPoolPrice;
  const dispOracle = isLive && live.oraclePrice !== undefined ? live.oraclePrice : oraclePrice;
  const dev = isLive ? live.deviationBps! : demoDev;
  const feePips = isLive ? live.feePips! : feeForDeviationBps(demoDev);
  const tier = tierForDeviationBps(dev);

  const pushEvent = useCallback((feePips: number, devBps: number, note: string) => {
    setEvents((prev) =>
      [
        {
          id: ++eventSeq,
          ts: Date.now(),
          feePips,
          deviationBps: devBps,
          tier: tierForDeviationBps(devBps),
          note,
        },
        ...prev,
      ].slice(0, 12)
    );
  }, []);

  // Demo: gently drift the oracle to mimic a live Chainlink feed.
  useEffect(() => {
    if (!oracleLive || isLive) return;
    const t = setInterval(() => {
      setOracle((prev) => {
        const driftPct = (Math.random() - 0.5) * 0.004; // +/- 0.2%
        const next = Math.max(100, prev * (1 + driftPct));
        return Math.round(next * 100) / 100;
      });
    }, 3000);
    return () => clearInterval(t);
  }, [oracleLive, isLive]);

  const setOraclePrice = useCallback(
    (p: number) => {
      const clamped = Math.max(100, p);
      setOracle(Math.round(clamped * 100) / 100);
      const d = deviationBps(poolPrice(reserves), clamped);
      pushEvent(feeForDeviationBps(d), d, "Oracle updated");
    },
    [reserves, pushEvent]
  );

  const toggleOracleLive = useCallback(() => setOracleLive((v) => !v), []);

  // In live mode derive simulator reserves from on-chain CL liquidity + seeded tick bounds.
  const liveSimReserves = (): PoolReserves => {
    const price = live.poolPrice ?? demoPoolPrice;
    if (
      live.liquidity &&
      live.liquidity > 0n &&
      live.sqrtPriceX96 &&
      ENV.lpTickLower !== 0 &&
      ENV.lpTickUpper !== 0
    ) {
      return reservesFromLiquidity(live.liquidity, live.sqrtPriceX96, ENV.lpTickLower, ENV.lpTickUpper);
    }
    // Fallback until liquidity slot is loaded.
    return { weth: 120, usdc: 120 * price };
  };

  const quote = useCallback(
    (amountIn: number, dir: SwapDir) =>
      isLive && live.poolPrice !== undefined
        ? quoteSwap(liveSimReserves(), dispOracle, amountIn, dir)
        : quoteSwap(reserves, oraclePrice, amountIn, dir),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [isLive, live.poolPrice, dispOracle, reserves, oraclePrice]
  );

  const executeSwap = useCallback(
    (amountIn: number, dir: SwapDir) => {
      if (isLive && live.poolPrice !== undefined) {
        // What-if against live state — do not mutate (the real pool is on-chain).
        const q = quoteSwap(liveSimReserves(), dispOracle, amountIn, dir);
        pushEvent(
          q.feePips,
          q.deviationBpsBefore,
          `What-if ${q.tokenIn}→${q.tokenOut} @ ${(q.feePips / 10000).toFixed(2)}%`
        );
        return q;
      }
      const q = quoteSwap(reserves, oracleRef.current, amountIn, dir);
      setReserves(q.newReserves);
      pushEvent(
        q.feePips,
        q.deviationBpsBefore,
        `Swap ${q.tokenIn}→${q.tokenOut} @ ${(q.feePips / 10000).toFixed(2)}%`
      );
      return q;
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [isLive, live.poolPrice, dispOracle, reserves, pushEvent]
  );

  const resetPool = useCallback(() => {
    setReserves(INITIAL_RESERVES);
    setOracle(INITIAL_ORACLE);
    pushEvent(feeForDeviationBps(0), 0, "Pool reset");
  }, [pushEvent]);

  const value = useMemo<TerminalState>(
    () => ({
      isDemo: IS_DEMO,
      mode: isLive ? "live" : "demo",
      liveError: live.configured ? live.error : undefined,
      reserves,
      oraclePrice: dispOracle,
      poolPrice: pPrice,
      deviationBps: dev,
      feePips,
      tier,
      events,
      oracleLive,
      setOraclePrice,
      toggleOracleLive,
      quote,
      executeSwap,
      resetPool,
    }),
    [
      isLive,
      live.configured,
      live.error,
      reserves,
      dispOracle,
      pPrice,
      dev,
      feePips,
      tier,
      events,
      oracleLive,
      setOraclePrice,
      toggleOracleLive,
      quote,
      executeSwap,
      resetPool,
    ]
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useTerminal(): TerminalState {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useTerminal must be used within TerminalProvider");
  return ctx;
}
