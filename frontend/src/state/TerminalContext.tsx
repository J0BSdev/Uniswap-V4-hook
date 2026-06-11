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
import { useWalletClient } from "wagmi";
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
import { CAN_NUDGE_MOCK_ORACLE, CAN_SWAP_ONCHAIN, CAN_SWAP_WITH_WALLET, ENV, IS_DEMO, IS_FORK_DEV } from "../config/contracts";
import { useLiveFee } from "../hooks/useLiveFee";
import { quoteSwapLive, type LivePoolState } from "../lib/clQuote";
import { reservesFromLiquidity } from "../lib/clReserves";
import { resolveTickBounds } from "../lib/poolTicks";
import { nudgeForkOracle, readForkOraclePrice, refreshMockOracleWithWallet, requestKeeperOracleSync, setForkOraclePrice, syncOracleToChainlink } from "../lib/forkOracle";
import { alignPoolToChainlink, alignPoolToTarget } from "../lib/alignPool";
import { resetForkPoolState } from "../lib/forkReset";
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
  canNudgeMockOracle: boolean;
  mode: "demo" | "live";
  liveError?: string;
  liquidity: bigint;
  clReserves: PoolReserves | null;
  refreshOracle: () => Promise<void>;
  syncToChainlink: () => Promise<void>;
  syncOracleBusy: boolean;
  reserves: PoolReserves;
  oraclePrice: number;
  chainlinkPrice?: number;
  hookOraclePrice?: number;
  poolPrice: number;
  deviationBps: number;
  feePips: number;
  tier: Tier;
  events: FeeEvent[];
  oracleLive: boolean;
  setOraclePrice: (p: number) => Promise<void>;
  setPoolPrice: (p: number) => Promise<void>;
  alignPoolBusy: boolean;
  nudgeOracle: (deltaPct: number) => Promise<void>;
  nudgePool: (wethAmount?: number) => Promise<void>;
  toggleOracleLive: () => void;
  quote: (amountIn: number, dir: SwapDir) => SwapQuote;
  executeSwap: (amountIn: number, dir: SwapDir) => SwapQuote;
  resetPool: () => Promise<void>;
  resetPoolBusy: boolean;
}

const Ctx = createContext<TerminalState | null>(null);

let eventSeq = 0;

export function TerminalProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient();
  const { data: walletClient } = useWalletClient();
  const [reserves, setReserves] = useState<PoolReserves>(INITIAL_RESERVES);
  const [oraclePrice, setOracle] = useState<number>(INITIAL_ORACLE);
  const [oracleLive, setOracleLive] = useState<boolean>(false);
  const [events, setEvents] = useState<FeeEvent[]>([]);
  const [resetPoolBusy, setResetPoolBusy] = useState(false);
  const [syncOracleBusy, setSyncOracleBusy] = useState(false);
  const [alignPoolBusy, setAlignPoolBusy] = useState(false);
  const oracleSyncAttempted = useRef(false);
  const oracleRef = useRef(oraclePrice);
  oracleRef.current = oraclePrice;

  const live = useLiveFee(CAN_SWAP_ONCHAIN ? 4000 : 8000);

  const poolOk = live.poolPrice !== undefined && live.poolPrice > 0;
  const oracleOk = live.oraclePrice !== undefined && live.oraclePrice > 0;
  const forkLive = CAN_SWAP_ONCHAIN && live.configured && !live.loading;
  const hasLivePool = forkLive ? poolOk && oracleOk : live.configured && poolOk && oracleOk;
  const isLive = hasLivePool;

  const demoPoolPrice = poolPrice(reserves);
  const demoDev = deviationBps(demoPoolPrice, oraclePrice);

  const pPrice = isLive ? live.poolPrice! : forkLive ? (live.poolPrice ?? 0) : demoPoolPrice;
  const chainlinkPrice = forkLive || isLive ? live.chainlinkPrice : undefined;
  const hookOraclePrice = forkLive || isLive ? live.oraclePrice : undefined;
  const dispOracle =
    forkLive || isLive ? (live.chainlinkPrice ?? live.oraclePrice ?? 0) : oraclePrice;
  const liveDev = deviationBps(pPrice, hookOraclePrice ?? dispOracle);
  const dev = isLive
    ? (live.deviationBps ?? liveDev)
    : forkLive && live.error
      ? (live.deviationBps ?? 0)
      : demoDev;
  const feePips = isLive
    ? (live.feePips ?? feeForDeviationBps(liveDev))
    : forkLive && live.error
      ? (live.feePips ?? feeForDeviationBps(liveDev))
      : feeForDeviationBps(demoDev);
  const tier = tierForDeviationBps(dev);

  const liquidity = live.liquidity ?? 0n;
  const tickBounds = resolveTickBounds(live.tick, ENV.lpTickLower, ENV.lpTickUpper);

  const clReserves = useMemo(() => {
    if (!isLive || live.sqrtPriceX96 === undefined || liquidity === 0n || !tickBounds) return null;
    return reservesFromLiquidity(liquidity, live.sqrtPriceX96, tickBounds.lower, tickBounds.upper);
  }, [isLive, live.sqrtPriceX96, liquidity, tickBounds]);

  const oracleWallet = CAN_NUDGE_MOCK_ORACLE ? walletClient : undefined;

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

  const refreshOracle = useCallback(async () => {
    if (!oracleWallet) return;
    await refreshMockOracleWithWallet(oracleWallet);
    await queryClient.invalidateQueries();
    pushEvent(feePips, dev, "Oracle timestamps refreshed");
  }, [oracleWallet, queryClient, pushEvent, feePips, dev]);

  const syncToChainlink = useCallback(async () => {
    if (!CAN_NUDGE_MOCK_ORACLE && !CAN_SWAP_ONCHAIN) return;
    setSyncOracleBusy(true);
    try {
      const wallet = oracleWallet ?? (CAN_SWAP_ONCHAIN ? undefined : undefined);
      if (CAN_SWAP_ONCHAIN) {
        const synced = await alignPoolToChainlink(wallet);
        await queryClient.invalidateQueries();
        pushEvent(feeForDeviationBps(0), 0, `Aligned to Chainlink $${synced.toFixed(2)}`);
        return;
      }
      if (oracleWallet) {
        const synced = await syncOracleToChainlink(oracleWallet);
        await queryClient.invalidateQueries();
        pushEvent(feePips, dev, `Oracle synced to Chainlink $${synced.toFixed(2)}`);
        return;
      }
      const synced = await requestKeeperOracleSync();
      if (synced !== null) {
        await queryClient.invalidateQueries();
        pushEvent(feePips, dev, `Oracle synced to Chainlink $${synced.toFixed(2)}`);
      }
    } finally {
      setSyncOracleBusy(false);
    }
  }, [oracleWallet, queryClient, pushEvent, feePips, dev]);

  const setPoolPrice = useCallback(
    async (p: number) => {
      const target = Math.max(100, p);
      setAlignPoolBusy(true);
      try {
        const wallet = CAN_SWAP_ONCHAIN ? undefined : oracleWallet;
        if (!CAN_SWAP_ONCHAIN && !CAN_SWAP_WITH_WALLET) {
          throw new Error("Swap router not configured");
        }
        if (!CAN_SWAP_ONCHAIN && !wallet) {
          throw new Error("Connect MetaMask on Base Sepolia to set pool price");
        }
        const result = await alignPoolToTarget(target, wallet);
        await queryClient.invalidateQueries();
        pushEvent(feeForDeviationBps(0), 0, `Pool aligned to $${result.toFixed(2)}`);
      } finally {
        setAlignPoolBusy(false);
      }
    },
    [oracleWallet, queryClient, pushEvent]
  );


  useEffect(() => {
    if (!CAN_NUDGE_MOCK_ORACLE || CAN_SWAP_ONCHAIN || !isLive || oracleSyncAttempted.current) return;
    if (!live.chainlinkPrice || !live.oraclePrice) return;

    const driftBps = deviationBps(live.oraclePrice, live.chainlinkPrice);
    const stale = live.error?.includes("stale");
    if (!stale && driftBps < 50) return;

    oracleSyncAttempted.current = true;
    void syncToChainlink();
  }, [isLive, live.chainlinkPrice, live.oraclePrice, live.error, syncToChainlink]);

  useEffect(() => {
    if (!oracleLive) return;

    if (isLive && CAN_SWAP_ONCHAIN) {
      const t = setInterval(() => {
        void (async () => {
          try {
            const cur = await readForkOraclePrice();
            const driftPct = (Math.random() - 0.5) * 0.006;
            await setForkOraclePrice(Math.max(100, cur * (1 + driftPct)), oracleWallet);
            await queryClient.invalidateQueries();
          } catch {
            /* RPC unavailable */
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
  }, [oracleLive, isLive, queryClient, oracleWallet]);

  const setOraclePrice = useCallback(
    async (p: number) => {
      const clamped = Math.max(100, p);
      if (CAN_SWAP_ONCHAIN || oracleWallet) {
        await setForkOraclePrice(clamped, oracleWallet);
        await queryClient.invalidateQueries();
        pushEvent(feeForDeviationBps(dev), dev, "Oracle updated");
        return;
      }
      setOracle(Math.round(clamped * 100) / 100);
      const d = deviationBps(poolPrice(reserves), clamped);
      pushEvent(feeForDeviationBps(d), d, "Oracle updated");
    },
    [reserves, pushEvent, dev, queryClient, oracleWallet]
  );

  const nudgeOracle = useCallback(
    async (deltaPct: number) => {
      if (!CAN_SWAP_ONCHAIN && !oracleWallet) return;
      await nudgeForkOracle(deltaPct, oracleWallet);
      await queryClient.invalidateQueries();
      pushEvent(feeForDeviationBps(dev), dev, `Oracle ${deltaPct > 0 ? "+" : ""}${deltaPct}%`);
    },
    [queryClient, pushEvent, dev, oracleWallet]
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

  const buildLiveQuoteState = useCallback((): LivePoolState | null => {
    if (
      !(isLive || forkLive) ||
      live.sqrtPriceX96 === undefined ||
      live.liquidity === undefined ||
      live.liquidity <= 0n ||
      live.poolPrice === undefined ||
      live.poolPrice <= 0 ||
      !tickBounds
    ) {
      return null;
    }
    return {
      sqrtPriceX96: live.sqrtPriceX96,
      liquidity: live.liquidity,
      tickLower: tickBounds.lower,
      tickUpper: tickBounds.upper,
      poolPrice: live.poolPrice,
      deviationBpsBefore: live.deviationBps ?? liveDev,
      oraclePrice: hookOraclePrice ?? dispOracle,
    };
  }, [isLive, forkLive, live.sqrtPriceX96, live.liquidity, live.poolPrice, live.deviationBps, liveDev, hookOraclePrice, dispOracle, tickBounds]);

  const quote = useCallback(
    (amountIn: number, dir: SwapDir) => {
      const liveState = buildLiveQuoteState();
      if (liveState) return quoteSwapLive(liveState, amountIn, dir);
      if (forkLive) {
        const oracle = hookOraclePrice ?? dispOracle;
        return quoteSwap({ weth: 0, usdc: 0 }, oracle || 0, amountIn, dir);
      }
      if (!isLive) return quoteSwap(reserves, oraclePrice, amountIn, dir);
      return quoteSwap({ weth: 0, usdc: 0 }, dispOracle, amountIn, dir);
    },
    [buildLiveQuoteState, forkLive, isLive, dispOracle, hookOraclePrice, reserves, oraclePrice]
  );

  const executeSwap = useCallback(
    (amountIn: number, dir: SwapDir) => {
      const liveState = buildLiveQuoteState();
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
    [buildLiveQuoteState, reserves, pushEvent]
  );

  const resetPool = useCallback(async () => {
    setResetPoolBusy(true);
    try {
      if (isLive && (CAN_SWAP_ONCHAIN || oracleWallet)) {
        setOracleLive(false);
        const synced = await resetForkPoolState(CAN_SWAP_ONCHAIN ? undefined : oracleWallet);
        await queryClient.invalidateQueries();
        setEvents([]);
        pushEvent(feeForDeviationBps(0), 0, `Pool aligned to Chainlink $${synced.toFixed(2)}`);
        return;
      }
      setReserves(INITIAL_RESERVES);
      setOracle(INITIAL_ORACLE);
      setOracleLive(false);
      setEvents([]);
      pushEvent(feeForDeviationBps(0), 0, "Pool reset");
    } finally {
      setResetPoolBusy(false);
    }
  }, [isLive, queryClient, pushEvent, oracleWallet]);

  const value = useMemo<TerminalState>(
    () => ({
      isDemo: IS_DEMO,
      isFork: IS_FORK_DEV,
      canNudgeMockOracle: CAN_NUDGE_MOCK_ORACLE,
      mode: forkLive || isLive ? "live" : "demo",
      liveError: live.configured ? live.error : undefined,
      liquidity,
      clReserves,
      refreshOracle,
      syncToChainlink,
      syncOracleBusy,
      alignPoolBusy,
      reserves,
      oraclePrice: dispOracle,
      chainlinkPrice,
      hookOraclePrice,
      poolPrice: pPrice,
      deviationBps: dev,
      feePips,
      tier,
      events,
      oracleLive,
      setOraclePrice,
      setPoolPrice,
      nudgeOracle,
      nudgePool,
      toggleOracleLive,
      quote,
      executeSwap,
      resetPool,
      resetPoolBusy,
    }),
    [
      isLive,
      forkLive,
      live.configured,
      live.error,
      liquidity,
      clReserves,
      refreshOracle,
      syncToChainlink,
      syncOracleBusy,
      alignPoolBusy,
      reserves,
      dispOracle,
      chainlinkPrice,
      hookOraclePrice,
      pPrice,
      dev,
      feePips,
      tier,
      events,
      oracleLive,
      setOraclePrice,
      setPoolPrice,
      nudgeOracle,
      nudgePool,
      toggleOracleLive,
      quote,
      executeSwap,
      resetPool,
      resetPoolBusy,
    ]
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useTerminal(): TerminalState {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useTerminal must be used within TerminalProvider");
  return ctx;
}
