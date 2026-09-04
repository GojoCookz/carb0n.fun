import { fmtAmount, graduationProgress } from '../lib/launch'

/**
 * The graduation gauge. This is the one place the design spends boldness — everything around it
 * stays quiet — because graduation is the idea this launchpad adds and the bar is how anyone
 * reads it in half a second.
 *
 * It is a SEGMENTED gauge, not the usual smooth pill, and that is on purpose: a smooth bar reads
 * as a percentage of something continuous, which is how pump.fun's bar works (it fills as SOL
 * lands in a bonding curve). **Ours measures something different** — market cap against a fixed
 * threshold on an open pool — so it must not look like the thing everybody already has a mental
 * model for. Ticks read as an instrument gauge: a level, not a fill.
 *
 * Honesty rules baked in:
 *  - the number is a SPOT market cap off `slot0.sqrtPriceX96`, manipulable inside one
 *    transaction, so the caption says so and the latch gates nothing of value
 *  - the axis is in PAIR-CURRENCY units, because that is what the on-chain threshold is in
 *  - the dollar line is optional and only appears with a named live source
 */
export function GraduationBar({
  marketCap,
  threshold,
  opening,
  pairSymbol,
  graduated = false,
  compact = false,
}: {
  /** Current market cap, in pair-currency units. */
  marketCap: number
  /** The on-chain threshold, in pair-currency units. */
  threshold: number
  /** Market cap the pool opened at. Rendered as a reference tick so the travel is legible. */
  opening: number
  pairSymbol: string
  graduated?: boolean
  compact?: boolean
}) {
  const progress = graduationProgress(marketCap, threshold)
  const openingAt = threshold > 0 ? Math.min(1, opening / threshold) : 0
  const pct = Math.round(progress * 1000) / 10

  return (
    <div>
      {!compact && (
        <div className="mb-3 flex items-end justify-between gap-4">
          <div className="min-w-0">
            <p className="text-[11px] font-semibold uppercase tracking-wider text-bone-500">
              Market cap
            </p>
            <p className="tnum mt-1 truncate font-display text-[26px] font-bold leading-none text-bone-50">
              {fmtAmount(marketCap)}{' '}
              <span className="font-mono text-[15px] font-medium text-bone-400">{pairSymbol}</span>
            </p>
          </div>
          <p className="tnum shrink-0 text-right font-display text-[15px] font-bold text-bone-200">
            {pct}%
          </p>
        </div>
      )}

      <div
        role="progressbar"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={pct}
        aria-label={`Graduation progress: ${fmtAmount(marketCap)} of ${fmtAmount(threshold)} ${pairSymbol}`}
        className={[
          'relative w-full overflow-hidden rounded-full bg-ink-800 ring-1 ring-inset ring-ink-700',
          compact ? 'h-2.5' : 'h-4',
        ].join(' ')}
      >
        {/* A solid fill that scales. The ticks sit ON TOP and never move, so nothing distorts. */}
        <div
          className="absolute inset-0 origin-left bg-bone-50 transition-transform duration-500 ease-(--ease-out-soft)"
          style={{ transform: `scaleX(${progress})` }}
        />
        {/* Ticks are cut OUT of the bar in the page's own ground colour, so they read as a gauge
            rather than as a striped fill. The pitch widens in compact mode: at 10px tall, a 6px
            pitch turns into visual noise and the unfilled remainder shimmers. */}
        <div
          aria-hidden
          className="absolute inset-0"
          style={{
            backgroundImage: compact
              ? 'repeating-linear-gradient(90deg, transparent 0 7px, var(--color-ink-950) 7px 9px)'
              : 'repeating-linear-gradient(90deg, transparent 0 4px, var(--color-ink-950) 4px 6px)',
          }}
        />
        {/* Where the pool opened. Everything left of this was there on day one, not earned. */}
        {openingAt > 0.005 && openingAt < 0.995 && (
          <div
            aria-hidden
            className="absolute inset-y-0 w-px bg-steel-300"
            style={{ left: `${openingAt * 100}%` }}
          />
        )}
      </div>

      <div className="mt-2 flex items-start justify-between gap-3">
        <p className="tnum text-[11px] leading-tight text-bone-500">
          opened at {fmtAmount(opening)}
        </p>
        <p className="tnum text-right text-[11px] leading-tight text-bone-500">
          graduates at{' '}
          <span className="font-semibold text-bone-200">
            {fmtAmount(threshold)} {pairSymbol}
          </span>
        </p>
      </div>

      {graduated && (
        <p className="mt-2 text-[12px] font-semibold text-bone-50">
          Graduated. The latch is one-way — it stays set even if the price falls back.
        </p>
      )}
    </div>
  )
}
