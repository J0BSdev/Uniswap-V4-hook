import { useAccount, useConnect, useConnectors, useDisconnect, useSwitchChain } from "wagmi";
import { CAN_SWAP_ONCHAIN, ENV } from "../config/contracts";
import { shortAddr } from "../lib/format";

type AppChainId = 8453 | 84532;
const targetChainId = ENV.chainId as AppChainId;

function hasInjected(): boolean {
  return typeof window !== "undefined" && !!window.ethereum;
}

export function ConnectButton() {
  const { address, isConnected, chain } = useAccount();
  const connectors = useConnectors();
  const { connect, isPending, error } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: switching } = useSwitchChain();

  const injected = connectors.find((c) => c.type === "injected");
  const devWallet = connectors.find((c) => c.id === "fork-dev");

  if (isConnected && address) {
    const wrongChain = chain?.id !== targetChainId;
    return (
      <div className="wallet-actions">
        {wrongChain && (
          <button
            className="btn btn-ghost btn-sm wallet-warn"
            disabled={switching}
            onClick={() => switchChain({ chainId: targetChainId })}
          >
            {switching ? "Switching…" : `Switch to ${targetChainId === 84532 ? "Sepolia" : "Base"}`}
          </button>
        )}
        <button
          className={`btn btn-ghost wallet ${wrongChain ? "wallet-warn" : ""}`}
          onClick={() => disconnect()}
        >
          <span className="dot" />
          {wrongChain ? "Wrong network" : shortAddr(address)}
        </button>
      </div>
    );
  }

  const connectInjected = () => {
    if (!injected) return;
    connect({ connector: injected, chainId: targetChainId });
  };

  const connectDev = () => {
    if (!devWallet) return;
    connect({ connector: devWallet, chainId: targetChainId });
  };

  if (CAN_SWAP_ONCHAIN && devWallet && !hasInjected()) {
    return (
      <button className="btn btn-primary" disabled={isPending} onClick={connectDev}>
        {isPending ? "Connecting…" : "Connect dev wallet"}
      </button>
    );
  }

  return (
    <div className="wallet-actions">
      {CAN_SWAP_ONCHAIN && devWallet && (
        <button className="btn btn-ghost btn-sm" disabled={isPending} onClick={connectDev}>
          Dev wallet
        </button>
      )}
      <button
        className="btn btn-primary"
        disabled={!injected || isPending}
        onClick={connectInjected}
        title={injected ? undefined : "Install MetaMask or another injected wallet"}
      >
        {isPending ? "Connecting…" : "Connect wallet"}
      </button>
      {error && <span className="wallet-error">{error.message.split("\n")[0]}</span>}
    </div>
  );
}

declare global {
  interface Window {
    ethereum?: unknown;
  }
}
