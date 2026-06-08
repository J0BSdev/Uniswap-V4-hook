import { useAccount, useConnect, useDisconnect } from "wagmi";
import { shortAddr } from "../lib/format";

export function ConnectButton() {
  const { address, isConnected, chain } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();

  if (isConnected && address) {
    const wrongChain = chain?.id !== 8453;
    return (
      <button className={`btn btn-ghost wallet ${wrongChain ? "wallet-warn" : ""}`} onClick={() => disconnect()}>
        <span className="dot" />
        {wrongChain ? "Wrong network" : shortAddr(address)}
      </button>
    );
  }

  const injected = connectors[0];
  return (
    <button
      className="btn btn-primary"
      disabled={!injected || isPending}
      onClick={() => injected && connect({ connector: injected })}
    >
      {isPending ? "Connecting…" : "Connect wallet"}
    </button>
  );
}
