import { useMemo, useState } from 'react'
import type { PricePoint } from '../lib/priceHistory'

/**
 * The price of one launch token, in its pair currency, from the pool's own swaps.
 *
 * ## Hand-drawn SVG rather than a charting library
 *
 * Recharts, visx and lightweight-charts are all 40-120 KB gzipped for what is, here, a polyline
 * and some axis labels. This app already refuses to ship a wallet connector's worth of dependency
 * for two transactions; a chart with nine points does not earn one either. It is also the only way
 * the chart can inherit the theme's CSS variables rather than being configured to approximate them.
 *
 * ## Every state is drawn, including the ones that are not a chart
 *
 * A launch that has never traded is the COMMON case on a new pad, and "no data" rendered as an
 * empty box reads as broken. One trade is not a line. Both are handled explicitly.
 *
 * ## No dollars
 *
 * There is no Chainlink feed on Robinhood Chain, so the axis is in pair units and says so. A
 * dollar figure here would have to be invented.
 */
export function PriceChart({
  points,
  pairSymbol,
  loading,
}: {
  points: PricePoint[]
  pairSymbol: string
  loading: boolean
}) {
  const [hover, setHover] = useState<number | null>(null)

  const W = 600
  const H = 200
  const PAD = { t: 14, r: 10, b: 20, l: 10 }

  const geo = useMemo(() => {
    if (points.length < 2) return null

    const prices = points.map((p) => p.price)
    let lo = Math.min(...prices)
    let hi = Math.max(...prices)

    // A perfectly flat series would divide by zero and draw nothing. Give it a band to sit in.
    if (hi === lo) {
      hi = hi * 1.05
      lo = lo * 0.95
    }
    // Breathing room so the line never touches the frame.
    const span = hi - lo
    hi += span * 0.12
    lo -= span * 0.12

    const iw = W - PAD.l - PAD.r
    const ih = H - PAD.t - PAD.b
    const x = (i: number) => PAD.l + (i / (points.length - 1)) * iw
    const y = (p: number) => PAD.t + (1 - (p - lo) / (hi - lo)) * ih

    const line = points.map((p, i) => `${i === 0 ? 'M' : 'L'}${x(i).toFixed(2)},${y(p.price).toFixed(2)}`).join(' ')
    const area = `${line} L${x(points.length - 1).toFixed(2)},${H - PAD.b} L${x(0).toFixed(2)},${H - PAD.b} Z`

    return { x, y, line, area, lo, hi }
  }, [points])

  const first = points[0]?.price ?? 0
  const last = points[points.length - 1]?.price ?? 0
  const changePct = first > 0 ? ((last - first) / first) * 100 : 0
  const up = changePct >= 0

  if (loading) {
    return (
      <Frame pairSymbol={pairSymbol}>
        <div className="flex h-[200px] items-center justify-center">
          <div className="h-px w-2/3 animate-pulse bg-ink-600" />
        </div>
      </Frame>
    )
  }

  if (points.length === 0) {
    return (
      <Frame pairSymbol={pairSymbol}>
        <div className="flex h-[200px] flex-col items-center justify-center gap-1.5 text-center">
          <p className="font-display text-[14px] font-semibold text-bone-300">No trades yet.</p>
          <p className="max-w-[36ch] text-[12px] leading-relaxed text-bone-500">
            The pool is live and quoting. This fills in from the pool&rsquo;s own swap events the
            moment somebody trades.
          </p>
        </div>
      </Frame>
    )
  }

  if (points.length === 1) {
    return (
      <Frame pairSymbol={pairSymbol}>
        <div className="flex h-[200px] flex-col items-center justify-center gap-1.5 text-center">
          <p className="tnum font-mono text-[18px] font-semibold text-bone-100">
            {fmt(points[0].price)}
          </p>
          <p className="text-[12px] text-bone-500">
            One trade so far. A line needs two.
          </p>
        </div>
      </Frame>
    )
  }

  const active = hover !== null ? points[hover] : null

  return (
    <Frame
      pairSymbol={pairSymbol}
      headline={
        <span className="flex items-baseline gap-2">
          <span className="tnum font-mono text-[16px] font-semibold text-bone-100">
            {fmt(active ? active.price : last)}
          </span>
          <span
            className={`tnum text-[12px] font-semibold ${up ? 'text-steel-300' : 'text-danger-400'}`}
          >
            {up ? '+' : ''}
            {changePct.toFixed(1)}%
          </span>
        </span>
      }
    >
      <svg
        viewBox={`0 0 ${W} ${H}`}
        className="h-[200px] w-full touch-none"
        role="img"
        aria-label={`Price of one token in ${pairSymbol}, ${points.length} trades, ${changePct.toFixed(1)} percent since the first`}
        onMouseLeave={() => setHover(null)}
        onMouseMove={(e) => {
          const r = e.currentTarget.getBoundingClientRect()
          const rel = ((e.clientX - r.left) / r.width) * W
          const i = Math.round(((rel - PAD.l) / (W - PAD.l - PAD.r)) * (points.length - 1))
          setHover(Math.max(0, Math.min(points.length - 1, i)))
        }}
      >
        <defs>
          <linearGradient id="pc-fill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="currentColor" stopOpacity="0.26" />
            <stop offset="100%" stopColor="currentColor" stopOpacity="0" />
          </linearGradient>
        </defs>

        <g className={up ? 'text-steel-400' : 'text-danger-400'}>
          {geo && <path d={geo.area} fill="url(#pc-fill)" />}
          {geo && (
            <path
              d={geo.line}
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinejoin="round"
              strokeLinecap="round"
            />
          )}

          {/* Every swap is a real event; marking them stops the line implying continuous data. */}
          {geo &&
            points.map((p, i) => (
              <circle
                key={i}
                cx={geo.x(i)}
                cy={geo.y(p.price)}
                r={hover === i ? 4.5 : 2}
                fill="currentColor"
                opacity={hover === null || hover === i ? 1 : 0.4}
              />
            ))}

          {geo && active && hover !== null && (
            <line
              x1={geo.x(hover)}
              y1={PAD.t}
              x2={geo.x(hover)}
              y2={H - PAD.b}
              stroke="currentColor"
              strokeWidth="1"
              strokeDasharray="3 3"
              opacity="0.5"
            />
          )}
        </g>
      </svg>

      <div className="flex items-center justify-between px-1 pt-1 text-[10px] text-bone-500">
        <span>{points.length} trades</span>
        <span className="tnum">
          {active ? `block ${active.block.toLocaleString()}` : `latest block ${points[points.length - 1].block.toLocaleString()}`}
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
      <div className="mb-2 flex items-baseline justify-between gap-3">
        <h2 className="font-display text-[13px] font-semibold text-bone-300">
          Price <span className="font-normal text-bone-500">in {pairSymbol}</span>
        </h2>
        {headline}
      </div>
      {children}
      <p className="mt-2 text-[10px] leading-relaxed text-bone-600">
        Read from the pool&rsquo;s own <span className="font-mono">Swap</span> events, not an
        indexer. No dollar figure: there is no price feed on this chain.
      </p>
    </div>
  )
}

/** Prices here span many orders of magnitude, so a fixed decimal count is useless. */
function fmt(n: number): string {
  if (n === 0) return '0'
  if (n < 1e-9) return n.toExponential(2)
  if (n < 1e-6) return n.toFixed(10).replace(/0+$/, '')
  if (n < 0.001) return n.toFixed(8).replace(/0+$/, '')
  if (n < 1) return n.toFixed(6).replace(/0+$/, '')
  if (n < 1000) return n.toFixed(4)
  return n.toLocaleString(undefined, { maximumFractionDigits: 2 })
}
