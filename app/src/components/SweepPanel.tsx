/**
 * The button that turns accrued fees into actual money.
 *
 * **This is not a power-user extra, it is the only path.** Fees accrue inside the swap as ERC-6909
 * claims and stay claims until somebody calls `sweep()`. An earlier build tried to do it
 * automatically from inside `afterSwap`; it was deleted, because it never fired on ordinary trades
 * and making it fire would have let the hook move ERC-20 mid-swap and silently overcharge any
 * router that pays before it swaps. So the manual call is the whole mechanism, and until this
 * panel existed the app had no way to make it.
 *
 * `sweep()` is permissionless and pays the caller `SWEEP_BOUNTY_BPS` (0.5%) of what it releases.
 * That bounty is what makes this a job somebody takes rather than a favour — but nobody is
 * obliged to, so the panel states the honest position: at a small pot the bounty does not cover
 * the gas, and holders wait.
 */
import { formatUnits, type Address } from 'viem'
import type { FeeState } from '../lib/useTokenDetail'

/** `FeeHook.SWEEP_BOUNTY_BPS`. */
const SWEEP_BOUNTY_BPS = 50n

function amount(v: bigint | null, decimals: number): string {
  if (v === null) return '—'
  const n = Number(formatUnits(v, decimals))
  if (n === 0) return '0'
  if (n < 0.000001) return '<0.000001'
  return n.toLocaleString('en-US', { maximumSignificantDigits: 6 })
}

export function SweepPanel({
  fees,
  pairSymbol,
  pairDecimals,
  tokenSymbol,
  tokenDecimals = 18,
  account,
  onSweep,
  sweeping,
  error,
}: {
  fees: FeeState
  pairSymbol: string
  pairDecimals: number
  tokenSymbol: string
  tokenDecimals?: number
  account: Address | null
  onSweep: () => void
  sweeping: boolean
  error: string | null
}) {
  const pending = fees.pendingFees
  const pendingToken = fees.pendingTokenFees
  const hasPair = pending !== null && pending > 0n
  const hasToken = pendingToken !== null && pendingToken > 0n
  const anything = hasPair || hasToken

  const bounty = pending === null ? null : (pending * SWEEP_BOUNTY_BPS) / 10_000n

  return (
    <div className="rounded-2xl border border-ink-700 bg-ink-900 p-4">
      <div className="flex items-baseline justify-between gap-2">
        <h2 className="font-display text-[14px] font-bold text-bone-50">Unswept fees</h2>
        <span className="font-display text-[11px] font-bold text-bone-500">anyone can sweep</span>
      </div>

      <div className="mt-4 grid grid-cols-2 gap-4">
        <div>
          <p className="text-[11px] uppercase tracking-wider text-bone-500">Waiting, in {pairSymbol}</p>
          <p className="mt-1 font-mono text-[15px] font-bold tabular-nums text-bone-50">
            {amount(pending, pairDecimals)}
          </p>
        </div>
        <div>
          <p className="text-[11px] uppercase tracking-wider text-bone-500">Sell tax, unconverted</p>
          <p className="mt-1 font-mono text-[15px] font-bold tabular-nums text-bone-50">
            {amount(pendingToken, tokenDecimals)}
          </p>
        </div>
      </div>

      {hasToken && (
        <p className="mt-3 text-[11px] leading-relaxed text-bone-500">
          Sell tax arrives in {tokenSymbol} and has to be swapped for {pairSymbol} before holders
          can be paid in it. That swap happens on the sweep, not on the sell.
        </p>
      )}

      <button
        type="button"
        onClick={onSweep}
        disabled={!account || !anything || sweeping}
        className="mt-4 w-full rounded-xl border border-ink-600 bg-ink-800 px-5 py-2.5 font-display text-[13px] font-bold text-bone-200 transition-colors duration-150 hover:bg-ink-700 disabled:cursor-not-allowed disabled:opacity-40"
      >
        {sweeping
          ? 'Confirming…'
          : !account
            ? 'Connect a wallet to sweep'
            : !anything
              ? 'Nothing to sweep'
              : bounty !== null && bounty > 0n
                ? `Sweep — keep ${amount(bounty, pairDecimals)} ${pairSymbol}`
                : 'Sweep'}
      </button>

      {error && <p className="mt-2 text-[12px] leading-relaxed text-danger-400">{error}</p>}

      <p className="mt-3 border-t border-ink-800 pt-3 text-[11px] leading-relaxed text-bone-500">
        Sweeping pays holders, the creator and the platform, and pays{' '}
        <span className="text-bone-400">you 0.5%</span> of what it releases for the gas. Nobody is
        obliged to do it — on a small or quiet pool the bounty will not cover the transaction, and
        the fees simply wait. Claiming what you are already owed never depends on this.
      </p>
    </div>
  )
}
