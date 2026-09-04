/**
 * Can a buyer pay in ETH for a launch paired against this currency?
 *
 * `ZapRouter` routes `ETH -> PAIR -> TOKEN`, and hop 1 has to be a **Uniswap v4** pool. v2 and v3
 * liquidity is unreachable from the v4 singleton — different contracts, different accounting — so
 * a pair being deep on v3 says nothing about whether the zap can use it.
 *
 * **Every number below was MEASURED**, not modelled: `app/pairDepth.ts` simulated the trade against
 * the mainnet PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90` at block 25,898,753, and
 * cross-checked it two ways — a local recomputation from `slot0` + `L` using v4-core `SqrtPriceMath`
 * (3/3 exact to the wei) and the same trade quoted on Uniswap v3 (3/3 within 0.24%). Re-run that
 * script before trusting this table; liquidity moves.
 *
 * Two things the cross-check caught that are worth keeping written down:
 *
 * 1. **`PoolKey.fee` is NOT the fee anybody pays.** A protocol fee is switched on for several of
 *    these pools, and the real rate is `pf + lp - pf*lp/1e6` read from `slot0` bits [184,208).
 *    The WBTC and USDC 0.05% pools actually charge 625 pips. Using `PoolKey.fee` produced a
 *    systematic 1.2 bps error on every single pair, invisibly.
 * 2. **Only hookless pools at the four canonical `(fee, tickSpacing)` pairs were scanned.** Real
 *    depth sitting behind a hook or at a non-standard spacing is invisible to that method, so a
 *    `null` here means "not found by a fixed-keyspace scan", not "provably does not exist".
 *
 * `bps` is TOTAL execution cost against the pool mid price, fee included — not pure slippage. A
 * 0.3% pool has a 30 bps floor it can never beat, which is why LINK reads 35 and not 5.
 */

export type EthRoute = {
  /** The v4 fee tier that quoted cheapest at 1 ETH. */
  feeTier: number
  /** Total cost in basis points, fee included, for a 1 ETH buy. */
  bpsAt1Eth: number
}

/**
 * Measured routes. A symbol absent from this map has NO usable v4 ETH pool and the UI must not
 * offer ETH for it — the zap would either revert `PoolNotInitialized` or fill at a price nobody
 * would accept, and both read to a buyer as the token being broken.
 */
const ROUTES: Record<string, EthRoute> = {
  WBTC: { feeTier: 500, bpsAt1Eth: 6.6 },
  WETH: { feeTier: 500, bpsAt1Eth: 6.3 },
  USDC: { feeTier: 500, bpsAt1Eth: 6.7 },
  USDT: { feeTier: 500, bpsAt1Eth: 8.1 },
  LINK: { feeTier: 3000, bpsAt1Eth: 35.0 },
  AAVE: { feeTier: 3000, bpsAt1Eth: 36.7 },
  UNI: { feeTier: 3000, bpsAt1Eth: 38.1 },
  XAUT: { feeTier: 3000, bpsAt1Eth: 41.3 },
  ONDO: { feeTier: 3000, bpsAt1Eth: 59.1 },
  CRV: { feeTier: 3000, bpsAt1Eth: 89.6 },
  PAXG: { feeTier: 3000, bpsAt1Eth: 96.7 },
  // Over 100 bps at 1 ETH. Routable, but the cost is real and the UI says so rather than hiding it.
  APE: { feeTier: 3000, bpsAt1Eth: 196.3 },
  PEPE: { feeTier: 10000, bpsAt1Eth: 190.2 },
  SPX: { feeTier: 10000, bpsAt1Eth: 477.7 },
}

/**
 * The threshold above which the route is shown with a warning rather than silently.
 *
 * PAXG measured 96.7 and ENA measured 569.7, which means both sit close enough to a boundary to
 * flip between readings. Anything derived from this table should treat a near-threshold pair as
 * needing a fresh measurement, not as settled.
 */
export const ETH_ROUTE_CHEAP_BPS = 100

export function ethRouteFor(symbol: string): EthRoute | null {
  return ROUTES[symbol] ?? null
}

/** True when a buyer can pay in ETH for a launch paired against this currency. */
export function hasEthRoute(symbol: string): boolean {
  return ethRouteFor(symbol) !== null
}

/** How many of the roster can take an ETH buyer at all. Computed, never hardcoded prose. */
export function ethRouteCount(): number {
  return Object.keys(ROUTES).length
}
