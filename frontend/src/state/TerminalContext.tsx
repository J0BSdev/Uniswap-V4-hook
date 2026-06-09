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
import { useQueryClient } from "@tanstack/react-query";
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
import { CAN_SWAP_ONCHAIN, ENV, IS_DEMO } from "../config/contracts";
import { useLiveFee } from "../hooks/useLiveFee";
import { quoteSwapLive } from "../lib/clQuote";
import { nudgeForkOracle, readForkOraclePrice, setForkOraclePrice } from "../lib/forkOracle";
import { executeOnchainSwap } from "../lib/swapOnchain";

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
  isFork: boolean;
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
  setOraclePrice: (p: number) => Promise<void>;
  nudgeOracle: (deltaPct: number) => Promise<void>;
  nudgePool: (wethAmount?: number) => Promise<void>;
  toggleOracleLive: () => void;
  quote: (amountIn: number, dir: SwapDir) => SwapQuote;
  executeSwap: (amountIn: number, dir: SwapDir) => SwapQuote;
  resetPool: () => void;
}

const Ctx = createContext<TerminalState | null>(null);

let eventSeq = 0;

export function TerminalProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient();
  const [reserves, setReserves] = useState<PoolReserves>(INITIAL_RESERVES);
  const [oraclePrice, setOracle] = useState<number>(INITIAL_ORACLE);
  const [oracleLive, setOracleLive] = useState<boolean>(true);
  const [events, setEvents] = useState<FeeEvent[]>([]);
  const oracleRef = useRef(oraclePrice);
  oracleRef.current = oraclePrice;

  const live = useLiveFee(CAN_SWAP_ONCHAIN ? 4000 : 8000);
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

  // Demo mode: local oracle drift. Fork mode: nudge mock Chainlink on-chain.
  useEffect(() => {
    if (!oracleLive) return;

    if (isLive && CAN_SWAP_ONCHAIN) {
      const t = setInterval(() => {
        void (async () => {
          try {
            const cur = await readForkOraclePrice();
            const driftPct = (Math.random() - 0.5) * 0.006; // +/- 0.3%
            await setForkOraclePrice(Math.max(100, cur * (1 + driftPct)));
            await queryClient.invalidateQueries();
          } catch {
            /* fork RPC unavailable */
          }
        })();
      }, 4000);
      return () => clearInterval(t);
    }

    if (isLive) return;

    const t = setInterval(() => {
      setOracle((prev) => {
        const driftPct = (Math.random() - 0.5) * 0.004;
        const next = Math.max(100, prev * (1 + driftPct));
        return Math.round(next * 100) / 100;
      });
    }, 3000);
    return () => clearInterval(t);
  }, [oracleLive, isLive, queryClient]);

  const setOraclePrice = useCallback(
    async (p: number) => {
      const clamped = Math.max(100, p);
      if (CAN_SWAP_ONCHAIN) {
        await setForkOraclePrice(clamped);
        await queryClient.invalidateQueries();
        pushEvent(feeForDeviationBps(dev), dev, "Oracle updated (fork)");
        return;
      }
      setOracle(Math.round(clamped * 100) / 100);
      const d = deviationBps(poolPrice(reserves), clamped);
      pushEvent(feeForDeviationBps(d), d, "Oracle updated");
    },
    [reserves, pushEvent, dev, queryClient]
  );

  const nudgeOracle = useCallback(
    async (deltaPct: number) => {
      if (!CAN_SWAP_ONCHAIN) return;
      await nudgeForkOracle(deltaPct);
      await queryClient.invalidateQueries();
      pushEvent(feeForDeviationBps(dev), dev, `Oracle ${deltaPct > 0 ? "+" : ""}${deltaPct}%`);
    },
    [queryClient, pushEvent, dev]
  );

  const nudgePool = useCallback(
    async (wethAmount = 3) => {
      if (!CAN_SWAP_ONCHAIN) return;
      await executeOnchainSwap("WETH", wethAmount);
      await queryClient.invalidateQueries();
      pushEvent(feePips, dev, `Pool moved (${wethAmount} WETH swap)`);
    },
    [queryClient, pushEvent, feePips, dev]
  );

  const toggleOracleLive = useCallback(() => setOracleLive((v) => !v), []);

  const liveQuoteState = () => {
    if (
      !isLive ||
      live.poolPrice === undefined ||
      !live.sqrtPriceX96 ||
      !live.liquidity ||
      live.liquidity === 0n ||
      live.deviationBps === undefined ||
      ENV.lpTickLower === 0 ||
      ENV.lpTickUpper === 0
    ) {
      return null;
    }
    return {
      sqrtPriceX96: live.sqrtPriceX96,
      liquidity: live.liquidity,
      tickLower: ENV.lpTickLower,
      tickUpper: ENV.lpTickUpper,
      poolPrice: live.poolPrice,
      deviationBpsBefore: live.deviationBps,
      oraclePrice: dispOracle,
    };
  };

  const quote = useCallback(
    (amountIn: number, dir: SwapDir) => {
      const liveState = liveQuoteState();
      if (liveState) return quoteSwapLive(liveState, amountIn, dir);
      return quoteSwap(reserves, oraclePrice, amountIn, dir);
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [
      isLive,
      live.poolPrice,
      live.sqrtPriceX96,
      live.liquidity,
      live.deviationBps,
      dispOracle,
      reserves,
      oraclePrice,
    ]
  );

  const executeSwap = useCallback(
    (amountIn: number, dir: SwapDir) => {
      const liveState = liveQuoteState();
      if (liveState) {
        const q = quoteSwapLive(liveState, amountIn, dir);
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
    [
      isLive,
      live.poolPrice,
      live.sqrtPriceX96,
      live.liquidity,
      live.deviationBps,
      dispOracle,
      reserves,
      pushEvent,
    ]
  );

  const resetPool = useCallback(() => {
    setReserves(INITIAL_RESERVES);
    setOracle(INITIAL_ORACLE);
    pushEvent(feeForDeviationBps(0), 0, "Pool reset");
  }, [pushEvent]);

  const value = useMemo<TerminalState>(
    () => ({
      isDemo: IS_DEMO,
      isFork: CAN_SWAP_ONCHAIN,
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
      nudgeOracle,
      nudgePool,
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
      nudgeOracle,
      nudgePool,
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
