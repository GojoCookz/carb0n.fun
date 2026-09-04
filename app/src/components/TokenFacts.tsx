/**
 * The four things a reader needs about a launch, behind disclosure rows rather than in a wall.
 *
 * A launch has more true facts than fit on a screen, and the choice is between a wall nobody reads
 * and a summary that omits the uncomfortable ones. Rows that state their own headline value and
 * open on demand keep both: the address count and the tax split are visible without a click, and
 * the detail is one tap away.
 *
 * **The fee dialog shows CONFIGURED and REALISED side by side.** The configured split is what the
 * contract fixes at launch; the realised totals are what has actually happened. Showing only the
 * first is how a pad ends up advertising a holder rate nobody has ever been paid.
 */
import { useEffect, useState, type ReactNode } from 'react'
import { formatUnits, type Address } from 'viem'
import { shortAddress } from '../lib/chain'
import type { DividendState, FeeState } from '../lib/useTokenDetail'
import type { LaunchListing } from '../lib/listing'

function Row({
  label,
  value,
  onOpen,
}: {
  label: string
  value: string
  onOpen: () => void
}) {
  return (
    <button
      type="button"
      onClick={onOpen}
      className="flex w-full items-center justify-between gap-3 rounded-xl border border-ink-800 bg-ink-950/60 px-3.5 py-3 text-left transition-colors duration-150 hover:border-ink-600"
    >
      <span className="min-w-0">
        <span className="block font-display text-[13px] font-bold text-bone-200">{label}</span>
        <span className="mt-0.5 block truncate text-[11px] text-bone-500">{value}</span>
      </span>
      <span aria-hidden className="shrink-0 text-[13px] text-steel-500">
        &rsaquo;
      </span>
    </button>
  )
}

function Dialog({
  title,
  onClose,
  children,
}: {
  title: string
  onClose: () => void
  children: ReactNode
}) {
  // Escape closes, and the body does not scroll behind the sheet. Both are the kind of thing that
  // is invisible when present and infuriating when missing.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      window.removeEventListener('keydown', onKey)
      document.body.style.overflow = prev
    }
  }, [onClose])

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={title}
      className="fixed inset-0 z-50 flex items-end justify-center bg-ink-950/80 p-0 sm:items-center sm:p-6"
      onClick={onClose}
    >
      <div
        className="max-h-[85vh] w-full max-w-md overflow-y-auto rounded-t-2xl border border-ink-700 bg-ink-900 p-5 sm:rounded-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mb-4 flex items-center justify-between gap-3">
          <h3 className="font-display text-[15px] font-bold text-bone-50">{title}</h3>
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg px-2 py-1 text-[12px] text-bone-500 transition-colors duration-150 hover:text-bone-200"
          >
            Close
          </button>
        </div>
        {children}
      </div>
    </div>
  )
}

function Line({ k, v, sub }: { k: string; v: ReactNode; sub?: string }) {
  return (
    <div className="flex items-baseline justify-between gap-3 border-b border-ink-800 py-2.5 last:border-0">
      <span className="text-[11px] uppercase tracking-wider text-bone-500">{k}</span>
      <span className="text-right">
        <span className="block font-mono text-[13px] tabular-nums text-bone-100">{v}</span>
        {sub && <span className="mt-0.5 block text-[11px] text-bone-500">{sub}</span>}
      </span>
    </div>
  )
}

function AddressLine({ k, a }: { k: string; a: Address | null }) {
  const [copied, setCopied] = useState(false)
  if (!a) return <Line k={k} v="—" sub="not deployed" />
  return (
    <div className="flex items-baseline justify-between gap-3 border-b border-ink-800 py-2.5 last:border-0">
      <span className="text-[11px] uppercase tracking-wider text-bone-500">{k}</span>
      <button
        type="button"
        onClick={() => {
          navigator.clipboard?.writeText(a)
          setCopied(true)
          setTimeout(() => setCopied(false), 1200)
        }}
        className="font-mono text-[13px] text-bone-100 underline decoration-ink-600 underline-offset-4 transition-colors duration-150 hover:text-bone-50"
      >
        {copied ? 'copied' : shortAddress(a)}
      </button>
    </div>
  )
}

function bps(n: number | null): string {
  if (n === null) return '—'
  return `${(n / 100).toLocaleString('en-US', { maximumFractionDigits: 2 })}%`
}

/** `null` is "the chain could not answer", and it renders as an em dash, never as zero. */
function amount(v: bigint | null, decimals: number): string {
  if (v === null) return '—'
  const n = Number(formatUnits(v, decimals))
  if (n === 0) return '0'
  if (n < 0.000001) return '<0.000001'
  return n.toLocaleString('en-US', { maximumSignificantDigits: 6 })
}

function positive(v: bigint | null): boolean {
  return v !== null && v > 0n
}

export function TokenFacts({
  listing,
  dividends,
  fees,
  payoutSymbol,
  payoutDecimals,
  tokenDecimals = 18,
}: {
  listing: LaunchListing
  dividends: DividendState
  fees: FeeState
  payoutSymbol: string
  payoutDecimals: number
  tokenDecimals?: number
}) {
  const [open, setOpen] = useState<null | 'contracts' | 'fees' | 'facts'>(null)

  // **Rates come from `FeeHook.poolConfig`, NOT from the listing.** `useLaunches` hardcodes every
  // fee field to zero because it never reads the hook, so a listing reports 0% for a pool that
  // demonstrably charges 3%. Rendering that would be printing a placeholder as a fact.
  const buyBps = fees.feeBps
  const sellBps = fees.sellFeeBps
  const burnBps = fees.burnBps
  const known = buyBps !== null && burnBps !== null && fees.creatorBps !== null

  // The PLATFORM takes a flat share of VOLUME, so its share of the FEE is whatever fraction of the
  // fee that flat rate represents. `platformShareBps` is that number, computed once on chain.
  const platformShare = fees.platformShareBps
  const afterPlatform = platformShare === null ? null : Math.max(0, 10_000 - platformShare)
  const burnWedge =
    afterPlatform === null || burnBps === null ? null : (afterPlatform * burnBps) / 10_000
  const afterBurn = afterPlatform === null || burnWedge === null ? null : afterPlatform - burnWedge
  const creatorWedge =
    afterBurn === null || fees.creatorBps === null ? null : (afterBurn * fees.creatorBps) / 10_000
  const holderShare =
    afterBurn === null || creatorWedge === null ? null : afterBurn - creatorWedge

  return (
    <div className="space-y-2">
      <Row
        label="Contracts & wallets"
        value="token, pool, distributor, vault"
        onOpen={() => setOpen('contracts')}
      />
      <Row
        label="Where the fee goes"
        value={known ? `${bps(buyBps)} buy / ${bps(sellBps)} sell` : 'rates unavailable'}
        onOpen={() => setOpen('fees')}
      />
      <Row
        label="Launch facts"
        value={`paired with ${listing.pair.symbol}`}
        onOpen={() => setOpen('facts')}
      />

      {open === 'contracts' && (
        <Dialog title="Contracts & wallets" onClose={() => setOpen(null)}>
          <AddressLine k="Token" a={listing.address} />
          <AddressLine k="Pair currency" a={listing.chainPair} />
          <AddressLine k="Distributor" a={dividends.distributor} />
          <AddressLine k="Vesting vault" a={listing.vaultAddress} />
          <p className="mt-4 text-[11px] leading-relaxed text-bone-500">
            The Distributor is the contract that holds and splits holder dividends. The vault, when
            one exists, holds the creator's own opening buy on a schedule that can be extended but
            never shortened.
          </p>
        </Dialog>
      )}

      {open === 'fees' && (
        <Dialog title="Where the fee goes" onClose={() => setOpen(null)}>
          <Line k="Buy fee" v={bps(buyBps)} />
          <Line
            k="Sell fee"
            v={bps(sellBps)}
            sub={sellBps === 0 ? 'sells are free on this launch' : 'charged in the token'}
          />
          <div className="mt-4 mb-1 text-[11px] uppercase tracking-wider text-bone-500">
            How each buy fee divides
          </div>
          <Line k="Platform" v={bps(platformShare)} sub="a flat 1% of volume" />
          <Line k="Buyback & burn" v={bps(burnWedge)} />
          <Line k="Creator" v={bps(creatorWedge)} />
          <Line
            k="Holders"
            v={bps(holderShare)}
            sub={
              holderShare !== null && buyBps !== null
                ? `${bps((holderShare * buyBps) / 10_000)} of every buy`
                : undefined
            }
          />

          <div className="mt-5 mb-1 text-[11px] uppercase tracking-wider text-bone-500">
            Since launch — what actually happened
          </div>
          <Line
            k="Fees charged"
            v={`${amount(fees.totalFeesTaken, payoutDecimals)} ${payoutSymbol}`}
          />
          <Line
            k="Paid to holders"
            v={`${amount(dividends.totalDistributed, payoutDecimals)} ${payoutSymbol}`}
          />
          <Line
            k="Tokens burned"
            v={`${amount(fees.totalBurned, tokenDecimals)} ${listing.symbol}`}
          />
          {positive(fees.pendingFees) && (
            <Line
              k="Charged, not yet swept"
              v={`${amount(fees.pendingFees, payoutDecimals)} ${payoutSymbol}`}
              sub="held as claims until somebody sweeps"
            />
          )}
          {positive(fees.pendingTokenFees) && (
            <Line
              k="Sell tax awaiting conversion"
              v={`${amount(fees.pendingTokenFees, tokenDecimals)} ${listing.symbol}`}
              sub="a sell tax does not pay holders on the sell"
            />
          )}

          <p className="mt-4 text-[11px] leading-relaxed text-bone-500">
            The holder rate is the fee after the platform's cut, the burn wedge and the creator's
            share — not the headline rate. Quoting the headline would overstate what a holder
            receives on any pool that burns.
          </p>
        </Dialog>
      )}

      {open === 'facts' && (
        <Dialog title="Launch facts" onClose={() => setOpen(null)}>
          <Line k="Paired with" v={listing.pair.symbol} sub="what holders are paid in" />
          <Line k="Buy fee" v={bps(buyBps)} />
          <Line k="Sell fee" v={bps(sellBps)} />
          <Line k="Buyback & burn" v={bps(burnBps)} />
          <Line
            k="Opening market cap"
            v={`${listing.openingPair.toLocaleString('en-US', { maximumSignificantDigits: 6 })} ${listing.pair.symbol}`}
          />
          <Line
            k="Graduation bar"
            v={`${listing.thresholdPair.toLocaleString('en-US', { maximumSignificantDigits: 6 })} ${listing.pair.symbol}`}
            sub={listing.graduated ? 'graduated' : 'not yet'}
          />
          <Line
            k="Creator's buy"
            v={listing.vaultAddress ? 'locked in a vault' : 'taken in the clear'}
            sub={
              listing.vestDuration > 0
                ? `vests over ${Math.round(listing.vestDuration / 86_400)} days`
                : undefined
            }
          />
          <Line k="Venue" v="Uniswap v4" sub="liquidity locked from block zero" />
          <p className="mt-4 text-[11px] leading-relaxed text-bone-500">
            Liquidity is locked by there being no way out: the Launcher owns the position and
            contains no code path that removes it. No admin, no owner, no upgrade.
          </p>
        </Dialog>
      )}
    </div>
  )
}
