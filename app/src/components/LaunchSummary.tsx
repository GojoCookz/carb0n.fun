import { useState } from 'react'
import { Link } from 'react-router-dom'
import { TokenLogo } from './TokenLogo'
import { useDraft } from '../lib/draft-context'
import { formatUsd } from '../lib/chain'
import { usePairUsd, usdOf } from '../lib/usePairUsd'
import {
  feeSplit,
  fmtAmount,
  fmtBps,
  fmtDuration,
  fmtSupply,
  graduationMultiple,
  openingMarketCap,
  validate,
} from '../lib/launch'

/**
 * The always-visible answer to "what am I actually about to create?".
 *
 * Taken from klik.finance's create page, which keeps a live summary card pinned beside the form
 * — a `<dl>` of plain terms plus one sentence stating what the launch IS. It is the best idea on
 * that page: a launch form is a list of irreversible decisions, and burying the consequences in a
 * review step at the bottom means the user reads them once, at the end, when they are already
 * committed.
 *
 * Their version is a right-hand column, which only exists on a desktop. Ours is a sheet docked
 * above the bottom nav, because this app is designed at 390 x 844 first and a right rail is not
 * available there. Collapsed it is one line; expanded it is the full set of consequences.
 *
 * We have more to put in it than they do. Klik launches everything against ETH, so their summary
 * has four rows. Ours has to name the pair, the currency holders are actually paid in, the
 * graduation bar, and the fee an explorer will misreport.
 */
export function LaunchSummary() {
  const { draft, pair } = useDraft()
  const usd = usePairUsd(pair?.symbol)
  const [open, setOpen] = useState(false)

  if (!pair) return null

  const issues = validate(draft, pair)
  const opening = openingMarketCap(draft)
  const split = feeSplit(draft)
  const openingUsd = usdOf(usd, opening)
  const symbol = draft.symbol.trim() || 'Your token'

  return (
    <div
      className="fixed inset-x-0 bottom-[74px] z-40 px-3"
      style={{ paddingBottom: 'env(safe-area-inset-bottom)' }}
    >
      <div className="mx-auto max-w-2xl overflow-hidden rounded-(--radius-card) border border-ink-600 bg-ink-850/95 shadow-[0_-8px_32px_-12px_rgba(0,0,0,0.9)] backdrop-blur-md">
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          aria-expanded={open}
          className="flex w-full items-center gap-3 px-4 py-3 text-left transition-colors duration-150 hover:bg-ink-800"
        >
          <TokenLogo pair={pair} size={26} />
          <span className="min-w-0 flex-1">
            <span className="block truncate font-display text-[13px] font-bold text-bone-50">
              {symbol}
              <span className="ml-1.5 font-mono text-[11px] font-medium text-bone-400">
                / {pair.symbol}
              </span>
            </span>
            <span className="tnum block truncate font-mono text-[11px] text-bone-500">
              {fmtAmount(opening)} opening · graduates at {fmtAmount(draft.graduationThreshold)}
            </span>
          </span>
          <span
            className={[
              'shrink-0 rounded-full px-2 py-1 text-[10px] font-bold',
              issues.length === 0 ? 'bg-bone-50/10 text-bone-50' : 'bg-danger-400/15 text-danger-400',
            ].join(' ')}
          >
            {issues.length === 0 ? 'valid' : `${issues.length} to fix`}
          </span>
          <svg
            width="16"
            height="16"
            viewBox="0 0 24 24"
            fill="none"
            aria-hidden
            className={`shrink-0 text-bone-400 transition-transform duration-200 ease-(--ease-out-soft) ${open ? '' : 'rotate-180'}`}
          >
            <path d="m6 9 6 6 6-6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
          </svg>
        </button>

        {/* Capped and scrollable: expanded, this has eight rows plus a paragraph, and at 390x844
            an uncapped sheet covers the form it is summarising. */}
        {open && (
          <dl className="max-h-[58dvh] divide-y divide-ink-700 overflow-y-auto overscroll-contain border-t border-ink-700">
            <Row term="Trades against" def={pair.symbol} />
            <Row term="Supply" def={`${fmtSupply(draft.supply)} ${draft.symbol.trim() || 'tokens'}`} />
            <Row
              term="Opening market cap"
              def={`${fmtAmount(opening)} ${pair.symbol}`}
              sub={openingUsd !== null ? formatUsd(openingUsd) : `no ${pair.symbol}/USD feed on L1`}
            />
            <Row
              term="Graduates at"
              def={`${fmtAmount(draft.graduationThreshold)} ${pair.symbol}`}
              sub={`${graduationMultiple(draft).toLocaleString('en-US', { maximumFractionDigits: 1 })}× the opening`}
            />
            <Row
              term="Holders are paid"
              def={`${fmtBps(split.holdersBps)} of every buy`}
              sub={`in ${pair.symbol}, not in ${draft.symbol.trim() || 'your token'}`}
            />
            <Row term="You keep" def={`${fmtBps(split.creatorBps)} of every buy`} sub={`in ${pair.symbol}`} />
            <Row
              term="Sells"
              def={draft.sellFeeBps === 0 ? 'Not charged' : `${fmtBps(draft.sellFeeBps)}`}
              sub={
                draft.sellFeeBps === 0
                  ? 'free, which is the default'
                  : `taken in ${draft.symbol.trim() || 'your token'}, converted on sweep`
              }
            />
            <Row
              term="Buy back and burn"
              def={draft.burnBps === 0 ? 'Off' : fmtBps(draft.burnBps)}
              sub={draft.burnBps === 0 ? 'nothing is burned' : 'of every fee, destroyed'}
            />
            <Row
              term="Your opening buy"
              def={
                draft.devBuyPairAmount === 0
                  ? 'None'
                  : `${fmtAmount(draft.devBuyPairAmount)} ${pair.symbol}`
              }
              sub={
                draft.devBuyPairAmount === 0
                  ? 'you hold nothing at launch'
                  : draft.vestDuration > 0
                    ? `locked ${fmtDuration(draft.vestDuration)}, published on chain`
                    : 'straight to your wallet, sellable immediately'
              }
            />
            <Row term="Liquidity" def="Locked forever" sub="no admin, no owner, no withdraw path" />

            <div className="px-4 py-3.5">
              <p className="text-[12px] leading-relaxed text-bone-500">
                A carbonado launch: a live Uniswap v4 pool from the first block, liquidity locked with
                no code path out, and every buy paying holders in {pair.symbol}. Explorers will report
                this pool at 0% fee — the real rate is {fmtBps(draft.feeBps)} and the hook charges it.
              </p>
              <Link
                to="/preview"
                className="mt-3 flex w-full items-center justify-center rounded-xl border border-ink-600 bg-ink-800 px-4 py-2.5 font-display text-[13px] font-bold text-bone-200 transition-colors duration-150 hover:bg-ink-700"
              >
                See the token page this makes
              </Link>
            </div>
          </dl>
        )}
      </div>
    </div>
  )
}

function Row({ term, def, sub }: { term: string; def: string; sub?: string }) {
  return (
    <div className="flex items-start justify-between gap-4 px-4 py-2.5">
      <dt className="shrink-0 text-[12px] text-bone-500">{term}</dt>
      <dd className="min-w-0 text-right">
        <span className="tnum block truncate font-display text-[13px] font-bold text-bone-50">{def}</span>
        {sub && <span className="tnum block truncate text-[11px] text-bone-500">{sub}</span>}
      </dd>
    </div>
  )
}
