import { Link } from 'react-router-dom'
import { Card, EmptyState, SectionTitle, Pill } from '../components/Primitives'
import { Source } from '../components/Form'
import { LaunchCard } from '../components/LaunchCard'
import { DEPLOYMENTS } from '../lib/chain'
import { useDraft } from '../lib/draft-context'
import { usePairUsd, usdOf } from '../lib/usePairUsd'
import { draftToListing, type LaunchListing } from '../lib/listing'
import { openingMarketCap } from '../lib/launch'
import { useLaunches } from '../lib/useLaunches'

/**
 * The board of live launches.
 *
 * **There are none, because nothing is deployed**, and `listings` is genuinely empty rather than
 * seeded with placeholders. Fake rows here would be indistinguishable from real ones the moment
 * the contracts go live, which is exactly how invented data survives into production — and a board
 * is the most tempting place of all to put it, because an empty grid looks like a broken product
 * and a full one looks like a busy market.
 *
 * What is shown instead is the visitor's OWN draft, rendered through the real `LaunchCard`,
 * labelled as a draft on the card itself. That is their data, so it is not invented, and it does
 * the job an empty grid cannot: it shows what the board is for.
 */
export function Board() {
  const { draft, pair } = useDraft()
  const usd = usePairUsd(pair?.symbol)

  // Read straight from `Launcher.launches` rather than an indexer. See `useLaunches` for why,
  // and for the point at which this stops being the right call.
  const launches = useLaunches()
  const listings: LaunchListing[] = launches.kind === 'ok' ? launches.listings : []
  const notDeployed = DEPLOYMENTS.mainnet.pairRegistry === null

  const started = draft.name.trim().length > 0 || draft.symbol.trim().length > 0
  const draftListing =
    pair && started ? draftToListing(draft, pair, usdOf(usd, openingMarketCap(draft))) : null

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between gap-3">
        <SectionTitle count={launches.kind === 'loading' ? '…' : listings.length}>
          Launches
        </SectionTitle>
        {notDeployed && <Pill tone="pending">testnet</Pill>}
      </div>

      {launches.kind === 'loading' && (
        <Card className="p-5">
          <p className="text-[13px] text-bone-400">Reading launches from the chain…</p>
        </Card>
      )}

      {launches.kind === 'error' && (
        <Card className="border-danger-400/25 p-5">
          <p className="font-display text-[14px] font-bold text-bone-50">
            Could not read the launcher
          </p>
          <p className="mt-1.5 text-[12px] leading-relaxed text-bone-400">
            {launches.message}
          </p>
          <p className="mt-2 text-[12px] leading-relaxed text-bone-500">
            The board reads every launch directly from the chain, so this is an RPC problem rather
            than a missing token. Nothing is lost — reload and it will read again.
          </p>
        </Card>
      )}

      {listings.length > 0 && (
        <div className="grid gap-3 sm:grid-cols-2">
          {listings.map((l) => (
            // Only a LAUNCHED card is a link. A draft has no address, so wrapping it would produce
          // a link to nowhere that still looks clickable.
          l.address ? (
            <Link
              key={l.address}
              to={`/t/${l.address}`}
              className="block rounded-2xl transition-opacity duration-150 hover:opacity-90 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-bone-50"
            >
              <LaunchCard listing={l} />
            </Link>
          ) : (
            <LaunchCard key={l.symbol} listing={l} />
          )
          ))}
        </div>
      )}

      {launches.kind === 'ok' && listings.length === 0 && (
        <EmptyState
          title="No launches yet"
          body="Nothing has been launched through this launcher. The moment something is, it appears here — newest first, read straight from the chain rather than from an index."
          action={
            <Link
              to="/"
              className="inline-flex items-center gap-2 rounded-xl bg-bone-50 px-5 py-3 font-display text-[14px] font-bold text-ink-950 transition-colors duration-150 hover:bg-volt-400"
            >
              Configure a launch
            </Link>
          }
        />
      )}

      {draftListing && (
        <section className="space-y-3.5">
          <SectionTitle>Yours, in progress</SectionTitle>
          <div className="grid gap-3 sm:grid-cols-2">
            <LaunchCard listing={draftListing} />
          </div>
          <Source>
            The same card a real launch gets. Every number on it is one you entered or one derived
            from yours by the formula the contracts use — nothing was read from a chain, because
            there is nothing deployed to read.
          </Source>
        </section>
      )}

      <section className="space-y-3.5">
        <SectionTitle>Where each number comes from</SectionTitle>
        <Card className="divide-y divide-ink-700">
          {ROWS.map(([label, detail, origin]) => (
            <div key={label} className="px-4 py-3.5">
              <div className="flex items-baseline justify-between gap-3">
                <span className="font-display text-[13.5px] font-bold text-bone-50">{label}</span>
                <span className="shrink-0 font-mono text-[10.5px] text-bone-500">{origin}</span>
              </div>
              <p className="mt-1 text-[12px] leading-relaxed text-bone-500">{detail}</p>
            </div>
          ))}
        </Card>
        <Source>
          Each row names the call or event it reads. A board that shows a number it cannot trace is
          how a launchpad ends up quoting a price nobody can reproduce.
        </Source>
      </section>

      <section className="space-y-3.5">
        <SectionTitle>Two things this board will not do</SectionTitle>
        <Card className="p-5">
          <div className="space-y-4 text-[12.5px] leading-relaxed text-bone-400">
            <p>
              <span className="font-semibold text-bone-200">
                It will not read the fee off the pool.
              </span>{' '}
              Every pool here has a fee field of exactly zero, because the hook charges instead of
              the pool. An indexer that reads <span className="font-mono">PoolKey.fee</span> reports
              0% and is wrong every time. The real rate comes off{' '}
              <span className="font-mono">PoolConfigured</span> and{' '}
              <span className="font-mono">FeeTaken</span>.
            </p>
            <p>
              <span className="font-semibold text-bone-200">
                It will not identify a token by its ticker.
              </span>{' '}
              Every card carries the contract address, because symbols are not identity — on one
              chain alone, 361 separate contracts have claimed the symbol{' '}
              <span className="font-mono">GME</span>. That is the same reason{' '}
              <span className="font-mono">PairRegistry</span> is an address allowlist.
            </p>
          </div>
        </Card>
      </section>
    </div>
  )
}

const ROWS: [string, string, string][] = [
  [
    'Market cap',
    'Total supply times the pool price, in units of the pair currency. A spot number, manipulable inside one transaction, and never used to gate anything.',
    'FeeHook.marketCapOf',
  ],
  [
    'Graduation progress',
    'That market cap against the threshold the creator fixed at launch. The latch is one-way.',
    'FeeHook.graduationProgressBps',
  ],
  [
    'Dollar value',
    'Derived off chain from a named Chainlink feed. Fifteen of the 22 pair currencies have no feed of any kind on L1, and those cards say so instead of showing a number.',
    'Chainlink, off chain',
  ],
  [
    'Holder rate',
    'What share of every buy reaches holders. Never read from the pool, which reports zero by design.',
    'FeeHook.PoolConfigured',
  ],
  [
    'Contract address',
    'The only reliable identity a token has. Shown on every card, copyable.',
    'Launcher.launches',
  ],
  [
    'Age',
    'When the launch transaction landed, not when it was indexed.',
    'Launcher.launches[i].launchedAt',
  ],
]
