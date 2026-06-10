export const TICK_SPACING = 60;
export const TICK_UNITS = 3;

/** Same tick range formula as script/SeedLiquidity.s.sol. */
export function tickBoundsFromCurrent(tick: number): { lower: number; upper: number } {
  const lower = (Math.trunc(tick / TICK_SPACING) - TICK_UNITS) * TICK_SPACING;
  const upper = (Math.trunc(tick / TICK_SPACING) + TICK_UNITS) * TICK_SPACING;
  return { lower, upper };
}

export function resolveTickBounds(tick: number | undefined, envLower: number, envUpper: number) {
  if (envLower !== 0 && envUpper !== 0) return { lower: envLower, upper: envUpper };
  if (tick !== undefined) return tickBoundsFromCurrent(tick);
  return null;
}
