import { encodePacked, keccak256, type Hex } from "viem";
import { poolPriceFromSqrt } from "../config/contracts";

/** bytes32(uint256(6)) — matches StateLibrary.POOLS_SLOT */
export const POOLS_SLOT_BYTES =
  "0x0000000000000000000000000000000000000000000000000000000000000006" as Hex;

/** keccak256(abi.encodePacked(poolId, POOLS_SLOT)) — matches StateLibrary._getPoolStateSlot */
export function poolStateSlot(poolId: Hex): Hex {
  return keccak256(encodePacked(["bytes32", "bytes32"], [poolId, POOLS_SLOT_BYTES]));
}

export function parseSlot0(word: Hex): { sqrtPriceX96: bigint; tick: number } {
  const data = BigInt(word);
  const sqrtPriceX96 = data & ((1n << 160n) - 1n);
  const tickRaw = Number((data >> 160n) & 0xffffffn);
  const tick = tickRaw >= 0x800000 ? tickRaw - 0x1000000 : tickRaw;
  return { sqrtPriceX96, tick };
}

export function poolPriceFromSlot0(word: Hex): number | undefined {
  const { sqrtPriceX96 } = parseSlot0(word);
  if (sqrtPriceX96 <= 4295128740n) return undefined;
  const price = poolPriceFromSqrt(sqrtPriceX96);
  if (price === undefined || !Number.isFinite(price) || price < 50) return undefined;
  return price;
}
 