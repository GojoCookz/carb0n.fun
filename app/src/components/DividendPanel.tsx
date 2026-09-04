/**
 * What this wallet has been paid, what is waiting, and where it sits in the push queue.
 *
 * **This is the product, and until now the app rendered none of it.** Holders are paid in the pair
 * currency; that claim was made in prose on three screens and was never shown as a number a reader
 * could check. Every figure here is a `Distributor` call.
 *
 * The queue line is the part worth explaining. `Distributor` pays two ways — a permissionless
 * `processBatch` cursor that walks holders in order (push), and `withdraw()` (pull). A holder who
 * only sees "waiting: $0.00" concludes they are not being paid. Showing the cursor position turns
 * that into "you are 12th of 40, or take it now", which is the truth and is actionable.
 */
import { formatUnits, type Address } from 'viem'
import type { DividendState } from '../lib/useTokenDetail'

/** `null` is "the chain could not answer", and it renders as an em dash, never as zero. */
function amount(v: bigint | null, decimals: number): string {
  if (v === null) return '—'
  const n = Number(formatUnits(v, decimals))
  if (n === 0) return '0'
  if (n < 0.000001) return '<0.000001'
  return n.toLocaleString('en-US', { maximumSignificantDigits: 6 })
}

export function DividendPanel({
  d,
  payoutSymbol,
  payoutDecimals,
  account,
  onClaim,
  claiming,
}: {
  d: DividendState
  payoutSymbol: string
  payoutDecimals: number
  account: Address | null
  onClaim: () => void
  claiming: boolean
}) {
  const sharePct =
    d.shares !== null && d.totalShares !== null && d.totalShares > 0n
      ? (Number(d.shares) / Number(d.totalShares)) * 100
      : null

  // Position in the queue RELATIVE TO THE CURSOR, which is what "how long until I am paid"
  // actually depends on. The cursor wraps, so a holder behind it waits for the lap to complete.
  const ahead =
    d.queuePosition === null
      ? null
      : d.queuePosition >= d.cursor
        ? d.queuePosition - d.cursor
        : d.queueLength - d.cursor + d.queuePosition

  const streaming = d.streamFinish !== null && d.streamFinish * 1000 > Date.now()
  const claimable = d.waiting !== null && d.waiting > 0n

  return (
    <div className="rounded-2xl border border-ink-700 bg-ink-900 p-4">
      <div className="flex items-baseline justify-between gap-2">
        <h2 className="font-display text-[14px] font-bold text-bone-50">Your dividends</h2>
        <span className="font-display text-[11px] font-bold text-bone-500">{payoutSymbol}</span>
      </div>

      {!account ? (
        <p className="mt-3 text-[12px] leading-relaxed text-bone-500">
          Connect a wallet to see what this token has paid you.
        </p>
      ) : (
        <>
          <div className="mt-4 grid grid-cols-2 gap-4">
            <div>
              <p className="text-[11px] uppercase tracking-wider text-bone-500">Received</p>
              <p className="mt-1 font-mono text-[15px] font-bold tabular-nums text-bone-50">
                {amount(d.received, payoutDecimals)}
              </p>
            </div>
            <div>
              <p className="text-[11px] uppercase tracking-wider text-bone-500">Waiting</p>
              <p className="mt-1 font-mono text-[15px] font-bold tabular-nums text-bone-50">
                {amount(d.waiting, payoutDecimals)}
              </p>
            </div>
          </div>

          <div className="mt-3 border-t border-ink-800 pt-3">
            <div className="flex items-baseline justify-between gap-2">
              <span className="text-[11px] uppercase tracking-wider text-bone-500">
                Your share of the register
              </span>
              <span className="font-mono text-[12px] tabular-nums text-bone-300">
                {sharePct === null
                  ? '—'
                  : `${sharePct.toLocaleString('en-US', { maximumFractionDigits: 4 })}%`}
              </span>
            </div>
            <p className="mt-1.5 text-[11px] leading-relaxed text-bone-500">
              Dividends are split by this number, not by market cap — the Distributor divides the
              pair currency it holds across the share register.
            </p>
          </div>

          {/* The queue. */}
          <div className="mt-3 border-t border-ink-800 pt-3">
            <div className="flex items-baseline justify-between gap-2">
              <span className="text-[11px] uppercase tracking-wider text-bone-500">In line</span>
              <span className="font-mono text-[12px] tabular-nums text-bone-300">
                {d.queuePosition === null
                  ? d.queueScanTruncated
                    ? 'unknown'
                    : 'not queued'
                  : `${d.queuePosition + 1} of ${d.queueLength}`}
              </span>
            </div>

            {ahead !== null && d.queueLength > 0 && (
              <>
                <div className="mt-2 h-1 w-full overflow-hidden rounded-full bg-ink-800">
                  <div
                    className="h-full bg-bone-200"
                    style={{
                      width: `${Math.max(2, ((d.queueLength - ahead) / d.queueLength) * 100)}%`,
                    }}
                  />
                </div>
                <p className="mt-1.5 text-[11px] leading-relaxed text-bone-500">
                  {ahead === 0
                    ? 'You are next on the push cursor.'
                    : `${ahead.toLocaleString('en-US')} ahead of you on the push cursor.`}{' '}
                  You never have to wait for it — withdrawing pays you directly.
                </p>
              </>
            )}

            {d.queuePosition === null && d.queueScanTruncated && (
              <p className="mt-1.5 text-[11px] leading-relaxed text-bone-500">
                The queue is longer than this page will scan, so your exact position is not shown
                rather than guessed. Withdrawing does not depend on it.
              </p>
            )}
          </div>

          {streaming && (
            <p className="mt-3 text-[11px] leading-relaxed text-bone-500">
              A distribution is still vesting. Fees reach the contract immediately and become
              claimable over 24 hours, which is what stops somebody buying just before a sweep and
              selling just after.
            </p>
          )}

          <button
            type="button"
            onClick={onClaim}
            disabled={!claimable || claiming}
            className="mt-4 w-full rounded-xl border border-ink-600 bg-ink-800 px-5 py-2.5 font-display text-[13px] font-bold text-bone-200 transition-colors duration-150 hover:bg-ink-700 disabled:cursor-not-allowed disabled:opacity-40"
          >
            {claiming
              ? 'Confirming…'
              : d.waiting === null
                ? 'Cannot read your balance'
                : !claimable
                  ? 'Nothing to claim yet'
                  : `Claim ${amount(d.waiting, payoutDecimals)} ${payoutSymbol}`}
          </button>
        </>
      )}

      <p className="mt-3 border-t border-ink-800 pt-3 text-[11px] leading-relaxed text-bone-500">
        Paid to all holders since launch:{' '}
        <span className="tabular-nums text-bone-400">
          {amount(d.totalDistributed, payoutDecimals)} {payoutSymbol}
        </span>
        {d.pendingPayouts !== null && d.pendingPayouts > 0n && (
          <>
            {' '}
            · carried to the next distribution{' '}
            <span className="tabular-nums text-bone-400">
              {amount(d.pendingPayouts, payoutDecimals)}
            </span>
          </>
        )}
      </p>
    </div>
  )
}
