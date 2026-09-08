/**
 * Price history for a launch, built from the pool's own Swap events.
 *
 * ## Why this reads the chain instead of an API
 *
 * There is no indexer behind this app - the board already reads `Launcher.launches` directly, for
 * the same reason. And on Robinhood Chain there is no data provider to call even if we wanted one:
 * screeners show the chain's tokens with a dash for price because nothing there prices anything.
 * The pool emits its own price on every swap, so that is the source.
 *
 * ## Where the price comes from
 *
 * Uniswap v4's `Swap` event carries `sqrtPriceX96`, the square root of the pool price in Q64.96
 * fixed point, AFTER the swap. So:
 *
 *     price(token1 per token0) = (sqrtPriceX96 / 2**96) ** 2
 *
 * Two corrections turn that into something a human can read:
 *
 * 1. **Decimals.** The raw ratio is in base units. `PAIR_PER_TOKEN` needs
 *    `* 10**(decimals0 - decimals1)`. This matters enormously here - USDG is 6 decimals and cbBTC
 *    is 8 against everything else's 18, and getting it wrong misprices by twelve orders of
 *    magnitude rather than by a rounding error.
 * 2. **Ordering.** v4 sorts currencies by address, so the launch token is currency0 in about half
 *    of all launches and currency1 in the rest. When it is currency1 the ratio must be inverted.
 *
 * ## Denominated in the pair currency, never in dollars
 *
 * `Addresses.hasUsdFeed(4663)` is false: there is no Chainlink on Robinhood Chain, so no honest
 * dollar figure exists for any of these. The series is in pair units and the UI says which pair.
 */
import { parseAbiItem, type Address, type PublicClient } from 'viem'

/** v4 emits this from the PoolManager singleton for every pool. `id` and `sender` are indexed. */
export const SWAP_EVENT = parseAbiItem(
  'event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)',
)

export type PricePoint = {
  block: number
  /** Unix seconds. Zero when the block header could not be fetched. */
  time: number
  /** Price of ONE launch token, in pair currency. */
  price: number
  /** Pair-currency size of the swap, absolute, for volume bars. */
  size: number
  /** True when the trade increased the launch token's price. */
  up: boolean
}

const Q96 = 2 ** 96

/**
 * Convert a `sqrtPriceX96` into "pair currency per launch token".
 *
 * Done in floating point deliberately. This value is for a CHART - it is never used to size a
 * transaction, quote a trade, or decide a payout, all of which read the pool directly. Precision
 * beyond a few significant figures would be invisible at chart resolution.
 */
export function priceFromSqrtX96(
  sqrtPriceX96: bigint,
  tokenIsCurrency0: boolean,
  tokenDecimals: number,
  pairDecimals: number,
): number {
  const ratio = (Number(sqrtPriceX96) / Q96) ** 2 // token1 per token0, base units

  const [dec0, dec1] = tokenIsCurrency0
    ? [tokenDecimals, pairDecimals]
    : [pairDecimals, tokenDecimals]

  const adjusted = ratio * 10 ** (dec0 - dec1)

  // `adjusted` is pair-per-token only when the token sorted first; otherwise it is its reciprocal.
  return tokenIsCurrency0 ? adjusted : 1 / adjusted
}

export type HistoryArgs = {
  client: PublicClient
  poolManager: Address
  poolId: `0x${string}`
  fromBlock: bigint
  tokenIsCurrency0: boolean
  tokenDecimals: number
  pairDecimals: number
}

/**
 * Every swap on one pool, oldest first.
 *
 * Returns an empty array rather than throwing when the RPC refuses the range: a token page that
 * renders without a chart is fine, a token page that fails to render is not.
 */
export async function fetchPriceHistory(a: HistoryArgs): Promise<PricePoint[]> {
  let logs
  try {
    logs = await a.client.getLogs({
      address: a.poolManager,
      event: SWAP_EVENT,
      args: { id: a.poolId },
      fromBlock: a.fromBlock,
      toBlock: 'latest',
    })
  } catch {
    return []
  }

  const points: PricePoint[] = []
  let prev = 0

  for (const l of logs) {
    const args = l.args as {
      amount0?: bigint
      amount1?: bigint
      sqrtPriceX96?: bigint
    }
    if (args.sqrtPriceX96 === undefined) continue

    const price = priceFromSqrtX96(
      args.sqrtPriceX96,
      a.tokenIsCurrency0,
      a.tokenDecimals,
      a.pairDecimals,
    )
    if (!Number.isFinite(price) || price <= 0) continue

    // The pair leg of the swap, whichever side that is, as a positive number.
    const pairRaw = a.tokenIsCurrency0 ? (args.amount1 ?? 0n) : (args.amount0 ?? 0n)
    const size = Math.abs(Number(pairRaw)) / 10 ** a.pairDecimals

    points.push({
      block: Number(l.blockNumber ?? 0n),
      time: 0,
      price,
      size,
      up: prev === 0 ? true : price >= prev,
    })
    prev = price
  }

  return points
}

/**
 * Fill in block timestamps.
 *
 * Candles are TIME buckets, and a swap log carries only a block number. Block height is a
 * tempting proxy but it is wrong the moment block production stutters, which is exactly when
 * a chart matters.
 *
 * Bounded to `MAX_BLOCK_LOOKUPS` distinct blocks. A busy pool would otherwise fire hundreds
 * of `eth_getBlockByNumber` calls to draw a picture, and past that point candles are dense
 * enough that a few missing ones change nothing.
 */
const MAX_BLOCK_LOOKUPS = 120

export async function fillTimestamps(
  client: PublicClient,
  points: PricePoint[],
): Promise<PricePoint[]> {
  const blocks = [...new Set(points.map((p) => p.block))].slice(-MAX_BLOCK_LOOKUPS)
  const times = new Map<number, number>()

  await Promise.all(
    blocks.map(async (b) => {
      try {
        const blk = await client.getBlock({ blockNumber: BigInt(b) })
        times.set(b, Number(blk.timestamp))
      } catch {
        // A missing header is not worth failing the chart over.
      }
    }),
  )

  return points.map((p) => ({ ...p, time: times.get(p.block) ?? 0 }))
}

export type Candle = {
  t: number
  o: number
  h: number
  l: number
  c: number
  /** Pair-currency volume traded inside the bucket. */
  v: number
}

/**
 * Bucket swaps into OHLC candles.
 *
 * **Empty buckets are dropped rather than carried forward.** A flat candle drawn across a
 * period with no trades looks exactly like a period of stable price, and on a new launch that
 * is the difference between "nobody traded" and "the price held". The gap is the information.
 *
 * The bucket size adapts to the span so a token minutes old and one weeks old both get a
 * readable number of candles, rather than one fat bar or four hundred slivers.
 */
export function toCandles(points: PricePoint[], target = 40): Candle[] {
  const usable = points.filter((p) => p.time > 0)
  if (usable.length === 0) return []
  if (usable.length === 1) {
    const p = usable[0]
    return [{ t: p.time, o: p.price, h: p.price, l: p.price, c: p.price, v: p.size }]
  }

  const first = usable[0].time
  const last = usable[usable.length - 1].time
  const span = Math.max(1, last - first)
  const bucket = Math.max(1, Math.floor(span / target))

  const out: Candle[] = []
  let cur: Candle | null = null

  for (const p of usable) {
    const slot = Math.floor((p.time - first) / bucket)
    const slotTime = first + slot * bucket
    if (!cur || cur.t !== slotTime) {
      if (cur) out.push(cur)
      cur = { t: slotTime, o: p.price, h: p.price, l: p.price, c: p.price, v: p.size }
    } else {
      cur.h = Math.max(cur.h, p.price)
      cur.l = Math.min(cur.l, p.price)
      cur.c = p.price
      cur.v += p.size
    }
  }
  if (cur) out.push(cur)
  return out
}
