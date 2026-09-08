import { useMemo, useState } from 'react'
import { ipfsCandidates, ipfsWalk } from '../lib/ipfs'
import { digestToCids } from '../lib/cid'
import { Link } from 'react-router-dom'
import { Card, Pill, SectionTitle } from '../components/Primitives'
import { Stat, Source } from '../components/Form'
import { GraduationBar } from '../components/GraduationBar'
import { TokenLogo } from '../components/TokenLogo'
import { formatUsd } from '../lib/chain'
import { useDraft } from '../lib/draft-context'
import { usePairUsd, usdOf } from '../lib/usePairUsd'
import {
  distributionFloorTokens,
  fmtAmount,
  fmtBps,
  fmtDuration,
  fmtSupply,
  holderBps,
  maxWalletTokens,
  openingMarketCap,
} from '../lib/launch'

/**
 * The token page, rendered from the launch you configured.
 *
 * **Nothing is deployed, so there is no real token to show.** Rather than invent one — fake
 * holders, fake volume, a `Math.random()` chart — this page renders YOUR draft and labels itself
 * a preview in a way that cannot be missed. Every figure below is either a number you entered, a
 * number derived from it by the same formula the contracts use, or an explicit `—` with the
 * reason attached.
 *
 * The one interactive element is a market-cap SIMULATOR, and it says so. It exists because the
 * one-way latch is the behaviour hardest to describe in a sentence and trivial to show: drag past
 * the threshold, then drag back, and watch it stay graduated.
 */
export function TokenPage() {
  const { draft, pair } = useDraft()
  const usd = usePairUsd(pair?.symbol)

  const opening = openingMarketCap(draft)
  // The burn-aware rate. `feeSplit` describes how the fee is DIVIDED; this is what survives to be
  // divided, and quoting the former to a holder overstates their income on any pool that burns.
  const holders = holderBps(draft)

  // The simulator's state. `latched` reproduces `FeeHook.checkGraduation`: set once, never cleared.
  const [simMultiple, setSimMultiple] = useState(1)
  const simulatedCap = opening * simMultiple
  const [latched, setLatched] = useState(false)
  const graduated = useMemo(() => {
    if (latched) return true
    return draft.graduationThreshold > 0 && simulatedCap >= draft.graduationThreshold
  }, [latched, simulatedCap, draft.graduationThreshold])

  if (graduated && !latched) {
    // Mirrors the contract: the first crossing writes the flag and it is never written back.
    queueMicrotask(() => setLatched(true))
  }

  if (!pair) {
    return (
      <Card className="p-6">
        <p className="text-[14px] text-bone-400">Pick a pair on the launch form first.</p>
      </Card>
    )
  }

  const capUsd = usdOf(usd, simulatedCap)
  const name = draft.name.trim() || 'Untitled'
  const symbol = draft.symbol.trim() || '—'

  return (
    <div className="space-y-6">
      <PreviewBanner />

      {/* --- Identity ------------------------------------------------------------------- */}
      <Card className="overflow-hidden">
        <BannerArt cid={draft.bannerCid} />
        <div className="px-5 pb-5">
          <div className="-mt-7 flex items-end gap-3">
            <Avatar cid={draft.imageCid} symbol={symbol} />
            <div className="min-w-0 flex-1 pb-1">
              <p className="truncate font-display text-[20px] font-bold leading-tight text-bone-50">
                {name}
              </p>
              <p className="truncate font-mono text-[13px] text-bone-400">{symbol}</p>
            </div>
          </div>

          <div className="mt-4 flex flex-wrap items-center gap-2">
            <span className="inline-flex items-center gap-1.5 rounded-full border border-ink-600 bg-ink-900 px-2.5 py-1 text-[11px] font-semibold text-bone-200">
              <TokenLogo pair={pair} size={14} />
              paired with {pair.symbol}
            </span>
            <Pill tone={graduated ? 'volt' : 'neutral'}>
              {graduated ? 'graduated' : 'not graduated'}
            </Pill>
            <Pill tone="volt">LP locked</Pill>
          </div>
        </div>
      </Card>

      {/* --- Graduation ----------------------------------------------------------------- */}
      <Card className="p-5">
        <GraduationBar
          marketCap={simulatedCap}
          threshold={draft.graduationThreshold}
          opening={opening}
          pairSymbol={pair.symbol}
          graduated={graduated}
        />

        <p className="mt-3 text-[12px] leading-relaxed text-bone-500">
          {capUsd !== null ? (
            <>
              ≈ <span className="font-semibold text-bone-200">{formatUsd(capUsd)}</span> at the
              current {pair.symbol} price. The on-chain threshold is in {pair.symbol}, so this dollar
              figure moves with {pair.symbol} even when the token has not.
            </>
          ) : (
            <>
              No {pair.symbol}/USD feed exists on Ethereum L1, so there is no honest dollar figure to
              show here. This is exactly why the threshold is denominated in {pair.symbol} on chain.
            </>
          )}
        </p>

        <Simulator value={simMultiple} onChange={setSimMultiple} latched={latched} />
      </Card>

      {/* --- Dividends ------------------------------------------------------------------ */}
      <section className="space-y-3.5">
        <SectionTitle>Your dividends</SectionTitle>
        <Card className="p-5">
          <div className="grid grid-cols-2 gap-5">
            <Stat label="Claimable now" value="—" sub="no wallet, no deployment" />
            <Stat label="Paid out so far" value="—" sub="no pool exists yet" />
          </div>

          <button
            type="button"
            disabled
            className="mt-5 w-full cursor-not-allowed rounded-xl bg-ink-800 px-5 py-3.5 font-display text-[15px] font-bold text-bone-500"
          >
            Claim {pair.symbol}
          </button>
          <p className="mt-2 text-center text-[12px] leading-snug text-bone-500">
            Off because no Distributor exists to claim from. It is not waiting on a wallet.
          </p>

          <div className="mt-5 space-y-2.5 border-t border-ink-700 pt-4 text-[12px] leading-relaxed text-bone-400">
            <p>
              <span className="font-semibold text-bone-200">Paid in {pair.symbol}</span>, never in{' '}
              {symbol}. <span className="tnum">{fmtBps(holders)}</span> of every buy is split across
              holders pro rata
              {draft.burnBps > 0 && (
                <>
                  {' '}
                  — that is what is left of the {fmtBps(draft.feeBps)} headline rate after the{' '}
                  {fmtBps(draft.burnBps)} burn wedge and the creator&rsquo;s cut, both of which are
                  spent before anything is divided
                </>
              )}
              .
            </p>
            {draft.sellFeeBps > 0 && (
              <p>
                Sell fees reach you too, but not immediately. They arrive as {symbol} and have to be
                swapped for {pair.symbol} first, which the automatic path cannot do — swapping a
                pool from inside its own swap re-enters it mid-update. They wait for a manual sweep,
                which anyone may call for a 0.5% bounty.
              </p>
            )}
            <p>
              <span className="text-bone-200">You claim your dividends yourself.</span> There is a
              push path in the contract, but nothing calls it on a schedule, so treat it as
              something that may happen rather than something that will. Pulling always works and
              never depends on anyone else paying gas.
            </p>
            <p>
              Balances under{' '}
              <span className="tnum font-mono text-bone-200">
                {fmtSupply(distributionFloorTokens(draft))}
              </span>{' '}
              tokens are not added to the payout queue. They can still be claimed directly.
            </p>
          </div>
        </Card>
      </section>

      {/* --- The pool ------------------------------------------------------------------- */}
      <section className="space-y-3.5">
        <SectionTitle>The pool</SectionTitle>
        <Card className="p-5">
          <div className="grid grid-cols-2 gap-5">
            <Stat label="Supply" value={fmtSupply(draft.supply)} sub="fixed, no mint, no burn" />
            <Stat
              label="Opening market cap"
              value={`${fmtAmount(draft.openingMarketCap)} ${pair.symbol}`}
              sub="locked, unremovable"
            />
            <Stat label="Fee on buys" value={fmtBps(draft.feeBps)} sub={`taken in ${pair.symbol}`} />
            <Stat
              label="Fee on sells"
              value={draft.sellFeeBps === 0 ? 'none' : fmtBps(draft.sellFeeBps)}
              sub={draft.sellFeeBps === 0 ? 'free to exit' : `taken in ${symbol}`}
            />
            <Stat
              label="Max wallet"
              value={draft.maxWalletBps === 0 ? 'off' : fmtBps(draft.maxWalletBps)}
              sub={draft.maxWalletBps === 0 ? 'no cap' : `${fmtSupply(maxWalletTokens(draft))} tokens`}
            />
            <Stat
              label="Bought back & burned"
              value={draft.burnBps === 0 ? 'none' : fmtBps(draft.burnBps)}
              sub={draft.burnBps === 0 ? 'no burn wedge' : 'of every swept fee'}
            />
          </div>

          <DevBuyRow
            devBuyPairAmount={draft.devBuyPairAmount}
            vestDuration={draft.vestDuration}
            vestCliff={draft.vestCliff}
            pairSymbol={pair.symbol}
          />

          <div className="mt-5 rounded-xl border border-danger-400/25 bg-danger-400/[0.06] p-4">
            <h3 className="font-display text-[13px] font-bold text-bone-50">
              What an explorer will get wrong
            </h3>
            <ul className="mt-2 space-y-2 text-[12px] leading-relaxed text-bone-400">
              <li>
                It will show this pool at{' '}
                <span className="font-semibold text-bone-200">0% fee</span>. The pool&rsquo;s fee
                field genuinely is zero — the hook charges {fmtBps(draft.feeBps)} instead, and only
                its <span className="font-mono">FeeTaken</span> event carries the real rate.
              </li>
              {draft.sellFeeBps === 0 ? (
                <li>
                  <span className="font-semibold text-bone-200">Sells cost nothing here</span>,
                  because you left the sell rate at zero — not because the contract cannot charge
                  one. It can, and the explorer will show 0% either way.
                </li>
              ) : (
                <li>
                  <span className="font-semibold text-bone-200">
                    It will miss the {fmtBps(draft.sellFeeBps)} sell fee entirely.
                  </span>{' '}
                  Sells are charged in {symbol} rather than {pair.symbol}, because a seller pays{' '}
                  {symbol} in and there is no {pair.symbol} of theirs to take. Those tokens sit as a
                  claim until a sweep converts them.
                </li>
              )}
            </ul>
          </div>
        </Card>
      </section>

      <Link
        to="/"
        className="flex w-full items-center justify-center rounded-xl border border-ink-600 bg-ink-800 px-5 py-3.5 font-display text-[15px] font-bold text-bone-200 transition-colors duration-150 hover:bg-ink-700"
      >
        Back to the launch form
      </Link>
    </div>
  )
}

// =============================================================================================

/**
 * What the creator holds, and whether they can sell it today.
 *
 * This is the single most consequential thing on the page for somebody deciding whether to buy,
 * so it is stated in all three cases rather than only the flattering one. A launchpad that shows
 * a lock badge when there is a lock and renders nothing when there is not is not disclosing — it
 * is advertising, and the absence of a badge is exactly the case a buyer most needs named.
 */
function DevBuyRow({
  devBuyPairAmount,
  vestDuration,
  vestCliff,
  pairSymbol,
}: {
  devBuyPairAmount: number
  vestDuration: number
  vestCliff: number
  pairSymbol: string
}) {
  if (devBuyPairAmount === 0) {
    return (
      <div className="mt-4 rounded-xl border border-ink-700 bg-ink-900 p-4">
        <h3 className="font-display text-[13px] font-bold text-bone-50">The creator holds nothing</h3>
        <p className="mt-1.5 text-[12px] leading-relaxed text-bone-500">
          No opening buy, so there is no creator position to lock, vest, or dump. They still earn
          their share of every fee.
        </p>
      </div>
    )
  }

  const locked = vestDuration > 0

  return (
    <div
      className={[
        'mt-4 rounded-xl border p-4',
        locked ? 'border-ink-700 bg-ink-900' : 'border-danger-400/25 bg-danger-400/[0.06]',
      ].join(' ')}
    >
      <div className="flex flex-wrap items-center gap-2">
        <h3 className="font-display text-[13px] font-bold text-bone-50">
          The creator bought {fmtAmount(devBuyPairAmount)} {pairSymbol} at open
        </h3>
        <Pill tone={locked ? 'volt' : 'neutral'}>{locked ? 'locked' : 'unlocked'}</Pill>
      </div>

      {locked ? (
        <div className="mt-2 space-y-2 text-[12px] leading-relaxed text-bone-400">
          <p>
            Held in a vesting vault created in the same transaction as the launch, releasing over{' '}
            <span className="font-semibold text-bone-200">{fmtDuration(vestDuration)}</span>
            {vestCliff > 0 ? (
              <>
                {' '}
                after a <span className="font-semibold text-bone-200">{fmtDuration(vestCliff)}</span>{' '}
                cliff
              </>
            ) : (
              ' with no cliff'
            )}
            . The schedule can be lengthened but never shortened, and the amount added to but never
            reduced.
          </p>
          <p>
            Because it is locked, the 10% cap on the opening buy does not apply — the vault replaces
            the cap rather than relaxing it.{' '}
            <span className="font-semibold text-bone-200">
              A locked launch is not automatically safer than a capped one
            </span>
            , only differently safe: this position is larger than a capped one would be, and the
            protection is the schedule rather than the size.
          </p>
        </div>
      ) : (
        <p className="mt-2 text-[12px] leading-relaxed text-bone-400">
          Taken in the clear and sellable at any moment, including the block after launch. It is
          capped at{' '}
          <span className="font-semibold text-bone-200">10% of the opening market cap</span> — that
          cap is the only thing limiting it, and the launch reverts rather than trimming a buy that
          exceeds it.
        </p>
      )}
    </div>
  )
}

function PreviewBanner() {
  return (
    <div className="rounded-(--radius-card) border border-steel-500/40 bg-steel-500/10 px-4 py-3.5">
      <p className="font-display text-[13px] font-bold text-bone-50">Preview — this token does not exist</p>
      <p className="mt-1 text-[12px] leading-relaxed text-bone-400">
        Built from the form you just filled in. Every number is either yours or derived from yours by
        the same formula the contracts use. Nothing here was read from a chain, because there is
        nothing deployed to read.
      </p>
    </div>
  )
}

/**
 * A labelled simulation. It moves the price, nothing else, and the label says so — this is the
 * only element on the page that shows a number the user did not choose, so it has to be
 * unmistakable.
 */
function Simulator({
  value,
  onChange,
  latched,
}: {
  value: number
  onChange: (v: number) => void
  latched: boolean
}) {
  return (
    <div className="mt-5 rounded-xl border border-steel-500/40 bg-steel-500/[0.08] p-4">
      <div className="flex items-baseline justify-between gap-3">
        <label htmlFor="sim" className="font-display text-[13px] font-bold text-bone-50">
          Simulate the price
        </label>
        <span className="tnum font-mono text-[13px] font-bold text-bone-200">{value}× opening</span>
      </div>
      <input
        id="sim"
        type="range"
        min={1}
        max={100}
        step={1}
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
        className="mt-3 h-1.5 w-full cursor-pointer appearance-none rounded-full bg-ink-700 accent-bone-50"
      />
      <p className="mt-2.5 text-[12px] leading-relaxed text-bone-400">
        {latched
          ? 'Drag it back down. It stays graduated — the latch is one-way, exactly as the contract behaves. An event stream that could retract a past event would be unindexable.'
          : 'Drag past the threshold to fire graduation, then drag back and see what happens.'}
      </p>
      <Source>
        A simulation, not a measurement. Nothing here has traded. Reproduces
        `FeeHook.checkGraduation`.
      </Source>
    </div>
  )
}

// The gateway lives in `lib/ipfs.ts`. It used to be `https://ipfs.io/ipfs/` here, which
// started returning 429 and blanked every image on the pad - see that file for the
// measurement and why a shared public gateway is not infrastructure.

function Avatar({ cid, symbol }: { cid: string; symbol: string }) {
  const [failed, setFailed] = useState(false)
  const usable = cid.trim().length > 0 && !failed

  return usable ? (
    <img
      src={ipfsCandidates(cid, digestToCids(cid))[0]}
      alt=""
      onError={ipfsWalk(ipfsCandidates(cid, digestToCids(cid)), () => setFailed(true))}
      className="size-16 shrink-0 rounded-2xl border-2 border-ink-850 bg-ink-800 object-cover"
    />
  ) : (
    <div
      aria-hidden
      className="flex size-16 shrink-0 items-center justify-center rounded-2xl border-2 border-ink-850 bg-ink-800 font-display text-[18px] font-bold text-bone-500"
    >
      {symbol.slice(0, 2)}
    </div>
  )
}

function BannerArt({ cid }: { cid: string }) {
  const [failed, setFailed] = useState(false)
  const usable = cid.trim().length > 0 && !failed

  if (usable) {
    return (
      <img
        src={ipfsCandidates(cid, digestToCids(cid))[0]}
        alt=""
        onError={ipfsWalk(ipfsCandidates(cid, digestToCids(cid)), () => setFailed(true))}
        className="h-24 w-full object-cover"
      />
    )
  }

  // The documented fallback for a launch with no banner. Not an error state.
  return (
    <div aria-hidden className="relative h-24 w-full overflow-hidden bg-ink-800">
      <div
        className="absolute inset-0 opacity-40"
        style={{
          backgroundImage:
            'repeating-linear-gradient(115deg, transparent 0 9px, var(--color-ink-700) 9px 10px)',
        }}
      />
    </div>
  )
}
