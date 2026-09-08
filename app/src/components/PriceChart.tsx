import { useMemo, useState } from 'react'
import { toCandles, type PricePoint } from '../lib/priceHistory'

/**
 * Market cap over time, from the pool's own swaps.
 *
 * ## Why market cap and not price
 *
 * A launch token's price is a number like `0.00001397`. Nobody can read that, nobody can compare
 * two of them, and it tells you nothing without also knowing the supply. **Market cap is the same
 * information multiplied by a constant, and it is the number people actually think in.** Supply is
 * fixed at mint and there is no mint or burn function, so `price x supply` is exact rather than an
 * estimate that drifts.
 *
 * The raw price is still shown, small, underneath - it is what the pool actually quotes.
 *
 * ## Candles and line
 *
 * Candles are what anybody who has traded expects, and a line hides the range entirely: four
 * trades that whipsawed and four that drifted draw the same line. On a pool this thin the wick IS
 * the story. The line stays because with two or three trades a candlestick chart is three lonely
 * boxes, and because it reads better as a thumbnail.
 *
 * ## Still hand-drawn SVG
 *
 * A charting library is 40-120 KB gzipped. This is a polyline, some rectangles and a toggle. It
 * also inherits the theme's CSS variables instead of being configured to approximate them.
 *
 * ## No dollars
 *
 * There is no Chainlink feed on Robinhood Chain, so everything is denominated in the pair currency
 * and says so. A dollar figure would have to be invented.
 */
export function PriceChart({
  points,
  pairSymbol,
  loading,
  supply,
}: {
  points: PricePoint[]
  pairSymbol: string
  loading: boolean
  /** Total supply, whole tokens. Fixed at mint - there is no mint or burn. */
  supply: number
}) {
  const [mode, setMode] = useState<'candle' | 'line'>('candle')
  const [hover, setHover] = useState<number | null>(null)

  const candles = useMemo(() => toCandles(points), [points])

  // Candles need timestamps; they arrive a moment after the line does. Fall back rather than
  // showing an empty box in between.
  const canCandle = candles.length >= 2
  const effective = mode === 'candle' && canCandle ? 'candle' : 'line'

  const W = 620
  const H = 220
  const PAD = { t: 14, r: 8, b: 22, l: 8 }

  const geo = useMemo(() => {
    const iw = W - PAD.l - PAD.r
    const ih = H - PAD.t - PAD.b

    const values =
      effective === 'candle'
        ? candles.flatMap((c) => [c.h, c.l])
        : points.map((p) => p.price)
    if (values.length < 2) return null

    let lo = Math.min(...values)
    let hi = Math.max(...values)
    if (hi === lo) {
      hi *= 1.05
      lo *= 0.95
    }
    const pad = (hi - lo) * 0.12
    hi += pad
    lo -= pad

    const y = (v: number) => PAD.t + (1 - (v - lo) / (hi - lo)) * ih
    const n = effective === 'candle' ? candles.length : points.length
    const x = (i: number) => PAD.l + (n === 1 ? iw / 2 : (i / (n - 1)) * iw)

    const line = points
      .map((p, i) => `${i === 0 ? 'M' : 'L'}${x(i).toFixed(2)},${y(p.price).toFixed(2)}`)
      .join(' ')
    const area = `${line} L${x(points.length - 1).toFixed(2)},${H - PAD.b} L${x(0).toFixed(2)},${H - PAD.b} Z`

    // Leave a gap between candles, and never let a body vanish entirely.
    const slot = n > 1 ? iw / n : iw
    const bodyW = Math.max(2, Math.min(18, slot * 0.62))

    return { x, y, line, area, bodyW }
  }, [effective, candles, points])

  const first = points[0]?.price ?? 0
  const last = points[points.length - 1]?.price ?? 0
  const changePct = first > 0 ? ((last - first) / first) * 100 : 0
  const up = changePct >= 0

  const activeCandle = hover !== null && effective === 'candle' ? candles[hover] : null
  const activePoint = hover !== null && effective === 'line' ? points[hover] : null
  const shownPrice = activeCandle?.c ?? activePoint?.price ?? last

  if (loading) {
    return (
      <Frame pairSymbol={pairSymbol}>
        <div className="flex h-[220px] items-center justify-center">
          <div className="h-px w-2/3 animate-pulse bg-ink-600" />
        </div>
      </Frame>
    )
  }

  if (points.length === 0) {
    return (
      <Frame pairSymbol={pairSymbol}>
        <div className="flex h-[220px] flex-col items-center justify-center gap-1.5 text-center">
          <p className="font-display text-[14px] font-semibold text-bone-300">No trades yet.</p>
          <p className="max-w-[36ch] text-[12px] leading-relaxed text-bone-500">
            The pool is live and quoting. This fills in from the pool&rsquo;s own swap events the
            moment somebody trades.
          </p>
        </div>
      </Frame>
    )
  }

  return (
    <Frame
      pairSymbol={pairSymbol}
      headline={
        <div className="flex items-center gap-3">
          <span className="flex items-baseline gap-2">
            <span className="tnum font-mono text-[17px] font-semibold text-bone-100">
              {fmtCap(shownPrice * supply)}
            </span>
            <span
              className={`tnum text-[12px] font-semibold ${up ? 'text-steel-300' : 'text-danger-400'}`}
            >
              {up ? '+' : ''}
              {changePct.toFixed(1)}%
            </span>
          </span>

          <div className="flex overflow-hidden rounded-lg border border-ink-700">
            {(['candle', 'line'] as const).map((m) => (
              <button
                key={m}
                type="button"
                onClick={() => setMode(m)}
                aria-pressed={mode === m}
                title={m === 'candle' && !canCandle ? 'Needs at least two time buckets' : undefined}
                className={[
                  'px-2 py-1 text-[10px] font-semibold uppercase tracking-wide transition-colors',
                  mode === m
                    ? 'bg-bone-50/[0.12] text-bone-100'
                    : 'text-bone-500 hover:text-bone-300',
                ].join(' ')}
              >
                {m === 'candle' ? 'Candles' : 'Line'}
              </button>
            ))}
          </div>
        </div>
      }
    >
      <svg
        viewBox={`0 0 ${W} ${H}`}
        className="h-[220px] w-full touch-none"
        role="img"
        aria-label={`Market cap in ${pairSymbol}, ${points.length} trades, ${changePct.toFixed(1)} percent since the first`}
        onMouseLeave={() => setHover(null)}
        onMouseMove={(e) => {
          const r = e.currentTarget.getBoundingClientRect()
          const rel = ((e.clientX - r.left) / r.width) * W
          const n = effective === 'candle' ? candles.length : points.length
          const i = Math.round(((rel - PAD.l) / (W - PAD.l - PAD.r)) * (n - 1))
          setHover(Math.max(0, Math.min(n - 1, i)))
        }}
      >
        <defs>
          <linearGradient id="pc-fill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="currentColor" stopOpacity="0.26" />
            <stop offset="100%" stopColor="currentColor" stopOpacity="0" />
          </linearGradient>
        </defs>

        {geo && effective === 'line' && (
          <g className={up ? 'text-steel-400' : 'text-danger-400'}>
            <path d={geo.area} fill="url(#pc-fill)" />
            <path
              d={geo.line}
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinejoin="round"
              strokeLinecap="round"
            />
            {points.map((p, i) => (
              <circle
                key={i}
                cx={geo.x(i)}
                cy={geo.y(p.price)}
                r={hover === i ? 4.5 : 2}
                fill="currentColor"
                opacity={hover === null || hover === i ? 1 : 0.4}
              />
            ))}
          </g>
        )}

        {geo &&
          effective === 'candle' &&
          candles.map((c, i) => {
            const rising = c.c >= c.o
            const cx = geo.x(i)
            const yO = geo.y(c.o)
            const yC = geo.y(c.c)
            const top = Math.min(yO, yC)
            // A doji would otherwise be invisible.
            const hgt = Math.max(1.5, Math.abs(yC - yO))
            return (
              <g
                key={i}
                className={rising ? 'text-steel-400' : 'text-danger-400'}
                opacity={hover === null || hover === i ? 1 : 0.45}
              >
                <line
                  x1={cx}
                  y1={geo.y(c.h)}
                  x2={cx}
                  y2={geo.y(c.l)}
                  stroke="currentColor"
                  strokeWidth="1.2"
                />
                <rect
                  x={cx - geo.bodyW / 2}
                  y={top}
                  width={geo.bodyW}
                  height={hgt}
                  fill={rising ? 'currentColor' : 'none'}
                  stroke="currentColor"
                  strokeWidth="1.4"
                />
              </g>
            )
          })}
      </svg>

      <div className="flex items-center justify-between gap-3 px-1 pt-1 text-[10px] text-bone-500">
        <span className="tnum">
          {points.length} trades
          {effective === 'candle' && ` · ${candles.length} candles`}
        </span>
        <span className="tnum">
          {activeCandle
            ? `O ${fmtCap(activeCandle.o * supply)}  H ${fmtCap(activeCandle.h * supply)}  L ${fmtCap(activeCandle.l * supply)}  C ${fmtCap(activeCandle.c * supply)}`
            : `${fmtPrice(shownPrice)} ${pairSymbol} per token`}
        </span>
      </div>
    </Frame>
  )
}

function Frame({
  children,
  pairSymbol,
  headline,
}: {
  children: React.ReactNode
  pairSymbol: string
  headline?: React.ReactNode
}) {
  return (
    <div className="rounded-(--radius-card) border border-ink-700 bg-ink-850 p-4">
      <div className="mb-2 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-2">
        <h2 className="font-display text-[13px] font-semibold text-bone-300">
          Market cap <span className="font-normal text-bone-500">in {pairSymbol}</span>
        </h2>
        {headline}
      </div>
      {children}
      <p className="mt-2 text-[10px] leading-relaxed text-bone-600">
        Market cap is price x supply, and supply is fixed at mint - there is no mint or burn. Read
        from the pool&rsquo;s own <span className="font-mono">Swap</span> events, not an indexer. No
        dollar figure: there is no price feed on this chain.
      </p>
    </div>
  )
}

/** Caps span many orders of magnitude, so a fixed decimal count is useless. */
function fmtCap(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return '0'
  if (n >= 1_000_000_000) return `${(n / 1_000_000_000).toFixed(2)}B`
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(2)}K`
  if (n >= 1) return n.toFixed(2)
  return n.toFixed(4)
}

function fmtPrice(n: number): string {
  if (n === 0) return '0'
  if (n < 1e-9) return n.toExponential(2)
  if (n < 1e-6) return n.toFixed(10).replace(/0+$/, '')
  if (n < 0.001) return n.toFixed(8).replace(/0+$/, '')
  if (n < 1) return n.toFixed(6).replace(/0+$/, '')
  return n.toFixed(4)
}
