import { useEffect, useMemo, useState } from 'react'
import { Card, Pill, SectionTitle } from '../components/Primitives'
import { LaunchSubmit } from '../components/LaunchSubmit'
import { ModeToggle, OptIn } from '../components/ModeToggle'
import { ImageUpload } from '../components/ImageUpload'
import { BANNER_SPEC, ICON_SPEC } from '../lib/imageFile'
import { pinningConfigured } from '../lib/pin'
import { TextField, NumberField, BpsSlider, Disclosure, Stat, Source } from '../components/Form'
import { GraduationBar } from '../components/GraduationBar'
import { LaunchSummary } from '../components/LaunchSummary'
import { TokenLogo } from '../components/TokenLogo'
import { formatUsd } from '../lib/chain'
import { useDraft } from '../lib/draft-context'
import { ethRouteFor, ETH_ROUTE_CHEAP_BPS } from '../lib/ethRoute'
import { usePairUsd, usdOf } from '../lib/usePairUsd'
import {
  MAX_FEE_BPS,
  OPENING_USD,
  GRADUATION_USD,
  applySimplePreset,
  PLATFORM_VOLUME_BPS,
  VEST_PRESETS,
  annualToHolders,
  annualToHolder,
  fmtDuration,
  holderBps,
  devBuyCap,
  feeSplit,
  fmtAmount,
  fmtBps,
  fmtSupply,
  issueFor,
  maxWalletTokens,
  openingMarketCap,
  openingPrice,
  validate,
  type LaunchDraft,
} from '../lib/launch'
import {
  PAIRS,
  depthBand,
  depthNote,
  formatLiquidity,
  riskCount,
  riskLabels,
  type Pair,
} from '../lib/pairs'

/**
 * Create a launch. The primary screen, and the only one with a primary action.
 *
 * Structure follows what actually decides a launch, in the order a creator decides it: what the
 * token IS, what it trades against, when it is called mature, and only then the knobs. Fees,
 * wallet caps and the dev buy are behind a disclosure with their current values on the closed
 * summary line, because they all have defaults that are already correct and none of them is the
 * decision a first-time creator is making.
 *
 * The submit button SENDS A REAL TRANSACTION, to Sepolia only. Every state in which it cannot do
 * that names the specific reason — no wallet, not connected, wrong network, pair not on the
 * testnet, form invalid — rather than sitting greyed out with nothing to act on. See
 * `LaunchSubmit`.
 */
export function Launch() {
  const {draft, pair, set, setDraft} = useDraft()
  const usd = usePairUsd(pair?.symbol)

  const issues = useMemo(() => validate(draft, pair), [draft, pair])

  // The chain can only store pair units, so the two FIXED dollar figures are converted at the
  // live rate and written into the draft. They are not editable anywhere; this is the only place
  // they are ever set, which is what makes "every launch opens at $3,000" true rather than a
  // default somebody can talk themselves out of.
  const rate = usdOf(usd, 1)
  useEffect(() => {
    if (!rate || rate <= 0) return
    const open = OPENING_USD / rate
    const grad = GRADUATION_USD / rate
    if (Math.abs(draft.openingMarketCap - open) > open * 1e-6) set('openingMarketCap', open)
    if (Math.abs(draft.graduationThreshold - grad) > grad * 1e-6) set('graduationThreshold', grad)
  }, [rate, draft.openingMarketCap, draft.graduationThreshold, set])

  const opening = openingMarketCap(draft)
  const split = feeSplit(draft)
  const thresholdUsd = usdOf(usd, draft.graduationThreshold)

  return (
    <div className="space-y-6">
      <Hero />

      <ModeToggle
        mode={draft.mode}
        onChange={(m: LaunchDraft['mode']) => {
          // Snapping back is deliberate: a "simple" launch that quietly kept a 9% tax from an
          // earlier visit to the custom tab is not simple, it is mislabelled.
          if (m === 'simple') setDraft(applySimplePreset(draft))
          else set('mode', 'advanced')
        }}
      />

      {/* --- 1. Identity ---------------------------------------------------------------- */}
      <section className="space-y-3.5">
        <SectionTitle>1 · Your token</SectionTitle>
        <Card className="space-y-5 p-5">
          <TextField
            label="Name"
            hint="Written into the token at launch. There is no setter — nobody can change it later."
            value={draft.name}
            onChange={(v) => set('name', v)}
            placeholder="Silent Horse"
            maxLength={32}
            error={issueFor(issues, 'name')?.message}
          />
          <TextField
            label="Symbol"
            hint="How it shows up in wallets and charts."
            value={draft.symbol}
            onChange={(v) => set('symbol', v.toUpperCase())}
            placeholder="HORSE"
            maxLength={8}
            mono
            error={issueFor(issues, 'symbol')?.message}
          />
          <NumberField
            label="Total supply"
            hint={
              <>
                Minted once, all of it seeded into the pool. There is no mint function and no burn —{' '}
                <span className="text-bone-400">{fmtSupply(draft.supply)}</span> is the number forever.
              </>
            }
            value={draft.supply}
            onChange={(v) => set('supply', v)}
            unit="tokens"
            step="1"
            min={1}
            presets={[
              { label: '100M', value: 100_000_000 },
              { label: '1B', value: 1_000_000_000 },
              { label: '10B', value: 10_000_000_000 },
            ]}
            error={issueFor(issues, 'supply')?.message}
          />
          <ImageUpload
            label="Token image"
            hint="Any photo or logo. Cropped to a square for you."
            spec={ICON_SPEC}
            required
            value={draft.imageCid}
            onChange={(v) => set('imageCid', v)}
          />
          {issueFor(issues, 'imageCid') && !draft.imageCid && (
            <p className="-mt-2 text-[11.5px] leading-relaxed text-danger-400">
              {issueFor(issues, 'imageCid')?.message}
            </p>
          )}

          <ImageUpload
            label="Banner"
            hint="Any wide image. Cropped to 1500 x 500 for you."
            spec={BANNER_SPEC}
            value={draft.bannerCid}
            onChange={(v) => set('bannerCid', v)}
          />

          <CidFallback draft={draft} set={set} />
        </Card>
      </section>

      {/* --- 2. Pair -------------------------------------------------------------------- */}
      <section className="space-y-3.5">
        <SectionTitle>2 · What it trades against</SectionTitle>

        {/* In simple mode the pair is not a question. The picker is the single biggest source of
            decisions on this form — 25 currencies, each with its own depth and admin risks — and
            it is exactly what a first launch does not need to think about. */}
        {draft.mode === 'simple' ? (
          <Card className="flex items-center gap-3 p-4">
            {pair && <TokenLogo pair={pair} size={22} />}
            <span className="min-w-0 flex-1">
              <span className="block font-display text-[14px] font-bold text-bone-50">
                Paired with ETH
              </span>
              <span className="mt-0.5 block text-[11.5px] leading-snug text-bone-500">
                The deepest market on Ethereum. Switch to Custom to pick from{' '}
                {PAIRS.length} others.
              </span>
            </span>
          </Card>
        ) : (
          <PairPicker selected={pair} onPick={(p) => set('pairSymbol', p.symbol)} />
        )}

        {pair && (
          <Card className="space-y-5 p-5">
            <p className="text-[13px] leading-relaxed text-bone-400">
              Every launch opens at{' '}
              <span className="font-semibold text-bone-50">${OPENING_USD.toLocaleString()}</span> and
              graduates at{' '}
              <span className="font-semibold text-bone-50">
                ${GRADUATION_USD.toLocaleString()}
              </span>
              . <span className="text-bone-200">You put in nothing</span> — the whole supply is
              seeded on one side and the book is built by the people who buy. Launching costs gas
              and nothing else.
            </p>

            <div className="grid grid-cols-3 gap-4 border-t border-ink-700 pt-4">
              <Stat
                label="Opens at"
                value={`$${OPENING_USD.toLocaleString()}`}
                sub={`${fmtAmount(opening)} ${pair.symbol}`}
              />
              <Stat
                label="Graduates at"
                value={`$${GRADUATION_USD.toLocaleString()}`}
                sub={`${fmtAmount(draft.graduationThreshold)} ${pair.symbol}`}
              />
              <Stat
                label="Opening price"
                value={fmtAmount(openingPrice(draft))}
                sub={`${pair.symbol} per token`}
              />
            </div>
          </Card>
        )}
      </section>

      {/* --- 3. Graduation -------------------------------------------------------------- */}
      <section className="space-y-3.5">
        <SectionTitle>3 · When it graduates</SectionTitle>
        <Card className="space-y-5 p-5">
          <p className="text-[13px] leading-relaxed text-bone-400">
            Every token graduates at{' '}
            <span className="font-semibold text-bone-50">${GRADUATION_USD.toLocaleString()}</span>{' '}
            market cap. The same bar for every launch, written into the token at creation and
            immutable afterwards.
          </p>

          {pair && draft.graduationThreshold > 0 && (
            <div className="rounded-xl border border-ink-700 bg-ink-900 p-4">
              <GraduationBar
                marketCap={opening}
                threshold={draft.graduationThreshold}
                opening={opening}
                pairSymbol={pair.symbol}
              />
              <p className="mt-3 text-[12px] leading-relaxed text-bone-500">
                {thresholdUsd !== null ? (
                  <>
                    That is about{' '}
                    <span className="font-semibold text-bone-200">{formatUsd(thresholdUsd)}</span> at
                    today&rsquo;s price — but the threshold on chain is{' '}
                    {fmtAmount(draft.graduationThreshold)} {pair.symbol}, so the dollar figure moves
                    whenever {pair.symbol} does.
                  </>
                ) : (
                  <>
                    There is no {pair.symbol}/USD feed on Ethereum L1, so this build shows no dollar
                    figure for it. The threshold is {fmtAmount(draft.graduationThreshold)}{' '}
                    {pair.symbol} on chain either way.
                  </>
                )}
              </p>
            </div>
          )}

          <p className="text-[12px] leading-relaxed text-bone-500">
            A signal, not a move — nothing migrates and nothing unlocks. Your token is on a live
            pool with locked liquidity from block one.
          </p>
        </Card>
      </section>

      {/* --- 4. Knobs ------------------------------------------------------------------- */}
      <section className="space-y-3.5">
        <SectionTitle>4 · Fees and guards</SectionTitle>

        {draft.mode === 'simple' ? (
          <SimpleTerms split={split} />
        ) : (
          <>
            <DividendOptIn draft={draft} set={set} pair={pair} />
            <FeeWalletOptIn draft={draft} set={set} issues={issues} />

        <Disclosure
          title="Trading fee and split"
          summary={`${fmtBps(draft.feeBps)} total · ${fmtBps(split.creatorBps)} you · ${fmtBps(split.platformBps)} platform`}
        >
          <BpsSlider
            label="Fee on buys"
            hint={`Taken by the hook inside the swap, in ${pair?.symbol ?? 'the pair currency'}. Hard cap is 10%.`}
            value={draft.feeBps}
            onChange={(v) => set('feeBps', v)}
            max={MAX_FEE_BPS}
            error={issueFor(issues, 'feeBps')?.message}
            zeroLabel="no fee"
          />
          <BpsSlider
            label="Fee on sells"
            hint={
              draft.sellFeeBps === 0
                ? 'Off. Sells cost nothing, which is the default.'
                : `Taken in your token, then converted to ${pair?.symbol ?? 'the pair'} when fees are swept. Set independently of the buy rate.`
            }
            value={draft.sellFeeBps}
            onChange={(v) => set('sellFeeBps', v)}
            max={MAX_FEE_BPS}
            zeroLabel="free"
            error={issueFor(issues, 'sellFeeBps')?.message}
          />
          <BpsSlider
            label="Buy back and burn"
            hint={
              draft.burnBps === 0
                ? 'Off. Nothing is ever burned.'
                : 'This share of every fee buys your token back from its own pool and destroys it. Comes out of the fee, before your cut and the holders&rsquo;.'
            }
            value={draft.burnBps}
            onChange={(v) => set('burnBps', v)}
            max={10_000}
            step={250}
            zeroLabel="off"
            error={issueFor(issues, 'burnBps')?.message}
          />
          <BpsSlider
            label="Your cut of that fee"
            hint="Comes out of the fee, not on top of it. The rest goes to holders."
            value={draft.creatorBps}
            onChange={(v) => set('creatorBps', v)}
            max={10_000}
            step={250}
          />

          {/* The platform's slice is shown at the same size as the other two. A fee the creator
              pays that is disclosed more quietly than the fees they collect is not disclosed. */}
          <div className="grid grid-cols-3 gap-4 rounded-xl border border-ink-700 bg-ink-900 p-4">
            <Stat label="To you" value={fmtBps(split.creatorBps)} sub="of every buy" />
            <Stat label="To holders" value={fmtBps(split.holdersBps)} sub="of every buy" />
            <Stat label="Platform" value={fmtBps(split.platformBps)} sub="flat, always" />
          </div>

          <p className="rounded-xl border border-ink-700 bg-ink-900 p-4 text-[12px] leading-relaxed text-bone-400">
            The platform takes{' '}
            <span className="font-semibold text-bone-200">{fmtBps(PLATFORM_VOLUME_BPS)} of volume</span>,
            not a share of your fee — a 2% launch and a 9% launch pay the same. It comes off the top
            and your split divides what is left, so &ldquo;to you&rdquo; means all of your own cut.
            It is a constant in the contract with no setter: nobody can raise it after you launch.
          </p>

          <div className="rounded-xl border border-danger-400/25 bg-danger-400/[0.06] p-4">
            <h4 className="font-display text-[13px] font-bold text-bone-50">Two things to know</h4>
            <ul className="mt-2 space-y-2 text-[12px] leading-relaxed text-bone-400">
              <li>
                {draft.sellFeeBps === 0 ? (
                  <>
                    <span className="font-semibold text-bone-200">Sells are free here</span> because
                    you left the sell rate at zero, not because the contract cannot charge one.
                  </>
                ) : (
                  <>
                    <span className="font-semibold text-bone-200">
                      Your {fmtBps(draft.sellFeeBps)} sell fee arrives late.
                    </span>{' '}
                    It is charged in {draft.symbol.trim() || 'your token'} and has to be swapped for{' '}
                    {pair?.symbol ?? 'the pair currency'} on a sweep before anyone is paid.
                  </>
                )}
              </li>
              <li>
                <span className="font-semibold text-bone-200">
                  Explorers will report this pool as 0% fee.
                </span>{' '}
                The pool&rsquo;s own fee field really is zero, because the hook charges instead. The
                real rate is {fmtBps(draft.feeBps)}, and it is carried on the hook&rsquo;s{' '}
                <span className="font-mono">FeeTaken</span> and{' '}
                <span className="font-mono">PoolConfigured</span> events.
              </li>
            </ul>
          </div>
        </Disclosure>

        <Disclosure
          title="Wallet cap and opening buy"
          summary={
            `${draft.maxWalletBps === 0 ? 'no wallet cap' : `${fmtBps(draft.maxWalletBps)} max wallet`}` +
            ` · dev buy ${draft.devBuyPairAmount > 0 ? `${fmtAmount(draft.devBuyPairAmount)} ${pair?.symbol ?? ''}` : 'none'}`
          }
        >
          <BpsSlider
            label="Max wallet"
            hint={
              draft.maxWalletBps === 0
                ? 'Off. Any wallet can buy any amount.'
                : `Caps a buy at ${fmtSupply(maxWalletTokens(draft))} tokens. Selling and wallet-to-wallet transfers are never blocked — a cap that can block a sell is a honeypot.`
            }
            value={draft.maxWalletBps}
            onChange={(v) => set('maxWalletBps', v)}
            max={2000}
            step={10}
            zeroLabel="off"
            error={issueFor(issues, 'maxWalletBps')?.message}
          />
          <NumberField
            label="Your opening buy"
            constraint={
              draft.vestDuration > 0
                ? 'uncapped while locked'
                : `capped at ${fmtAmount(devBuyCap(draft))} ${pair?.symbol ?? ''}`
            }
            hint={
              <>
                Optional. Runs as a normal swap inside the launch and pays the normal fee — you do
                not get a free entry.
              </>
            }
            value={draft.devBuyPairAmount}
            onChange={(v) => set('devBuyPairAmount', v)}
            unit={pair?.symbol ?? '—'}
            optional
            error={issueFor(issues, 'devBuyPairAmount')?.message}
          />

          <VestPicker />

          {draft.vestDuration > 0 && (
            <div className="rounded-xl border border-ink-700 bg-ink-900 p-4">
              <h4 className="font-display text-[13px] font-bold text-bone-50">
                Locking removes the cap
              </h4>
              <p className="mt-1.5 text-[12px] leading-relaxed text-bone-500">
                The 10% limit exists to stop an <span className="italic">undisclosed</span> position
                being dumped on buyers. A lock replaces that protection with a stronger one: the
                size and the schedule are written on chain in your launch transaction, readable
                before anyone buys, and the schedule can be lengthened but{' '}
                <span className="text-bone-200">never shortened</span> — not by you, not by us.
              </p>
              <Source>
                A locked launch is not automatically safer than a capped one. It is differently
                safe, and buyers should read the schedule rather than the label.
              </Source>
            </div>
          )}
        </Disclosure>
          </>
        )}
      </section>

      {pair && draft.mode === 'advanced' && <YieldPanel />}

      {/* --- 5. Review ------------------------------------------------------------------ */}
      <Review issues={issues} draft={draft} />

      {/* Clears the docked summary sheet so the last control is never trapped underneath it. */}
      <div aria-hidden className="h-16" />
      <LaunchSummary />
    </div>
  )
}

// =============================================================================================

/**
 * The number this whole product is actually about, and the one the UI was not showing.
 *
 * > **Dividends are a percentage of trading VOLUME, not a cut of an LP fee.**
 *
 * "2.4% of every buy" is technically complete and means nothing to anybody. The same fact stated
 * as "at $50k a day this pays holders roughly 438 WETH a year, about 88% of the opening market
 * cap" is the entire pitch. Volume compounds daily; market cap does not have to.
 *
 * The volume is a slider because nobody can know it, and it is labelled as an assumption. What the
 * contract guarantees is the percentage - which is fixed at launch and cannot be changed by
 * anyone, including us.
 */
function YieldPanel() {
  const { draft, pair } = useDraft()
  const usd = usePairUsd(pair?.symbol)
  const cap = openingMarketCap(draft)

  // Expressed as a MULTIPLE of the opening market cap rather than an absolute, because the
  // absolute is meaningless on its own: 50 a day is nothing against a 500 cap and delirious
  // against a 5 cap. A flat default produced a headline 8,760% - arithmetically correct and
  // indistinguishable from a scam.
  const [volumeMultiple, setVolumeMultiple] = useState(0.2)
  const dailyVolume = cap * volumeMultiple

  if (!pair) return null

  const delivered = annualToHolders(draft, dailyVolume)
  // What ONE PERCENT OF THE SUPPLY receives. The Distributor splits a real pair-currency balance
  // by the share register, so a per-holder amount is the honest second figure here — market cap is
  // a manipulable spot price that appears nowhere in the payout calculation.
  const perOnePercent = annualToHolder(draft, dailyVolume, 0.01)
  const deliveredUsd = usdOf(usd, delivered)
  const perOnePercentUsd = usdOf(usd, perOnePercent)

  // Daily volume above about half the market cap is not a normal market, and a yield derived
  // from it should not be presented as though it were.
  const implausible = volumeMultiple > 0.5

  return (
    <section className="space-y-3.5">
      <SectionTitle>What holders actually earn</SectionTitle>
      <Card className="lit p-5">
        <p className="text-[13px] leading-relaxed text-bone-400">
          Holder dividends are a share of{' '}
          <span className="font-semibold text-bone-50">trading volume</span>, not a slice of a pool
          fee. Volume compounds daily; your market cap does not have to.
        </p>

        <EthRouteNote symbol={pair.symbol} />

        <label
          htmlFor="dailyvol"
          className="mt-5 block font-display text-[13px] font-semibold text-bone-200"
        >
          Assumed daily volume
          <span className="ml-2 rounded-md bg-steel-500/20 px-1.5 py-0.5 text-[10px] font-semibold text-steel-300">
            your guess
          </span>
        </label>
        <input
          id="dailyvol"
          type="range"
          min={0.02}
          max={1}
          step={0.02}
          value={volumeMultiple}
          onChange={(e) => setVolumeMultiple(Number(e.target.value))}
          className="mt-3 h-1.5 w-full cursor-pointer appearance-none rounded-full bg-ink-700 accent-bone-50"
        />
        <p className="tnum mt-2 font-mono text-[15px] font-bold text-bone-50">
          {fmtAmount(dailyVolume)} {pair.symbol} / day
          <span className="ml-2 text-[12px] font-medium text-bone-500">
            {(volumeMultiple * 100).toFixed(0)}% of market cap
          </span>
        </p>

        <div className="mt-6 grid grid-cols-2 gap-5 border-t border-ink-700 pt-5">
          <Stat
            label="Paid to holders / year"
            value={`${fmtAmount(delivered)} ${pair.symbol}`}
            sub={deliveredUsd !== null ? formatUsd(deliveredUsd) : 'no USD feed on L1'}
          />
          <Stat
            label="If you hold 1% of supply"
            value={`${fmtAmount(perOnePercent)} ${pair.symbol}`}
            sub={perOnePercentUsd !== null ? formatUsd(perOnePercentUsd) : 'no USD feed on L1'}
          />
        </div>

        {implausible && (
          <p className="mt-4 rounded-xl border border-danger-400/25 bg-danger-400/[0.06] p-3 text-[12px] leading-relaxed text-bone-400">
            <span className="font-semibold text-danger-400">That is not a normal market.</span>{' '}
            Turning over more than half your market cap every day is exceptional and rarely lasts.
            The figure above is real arithmetic on an assumption that mostly is not.
          </p>
        )}

        <Source>
          Arithmetic on the rate you set and the volume you assumed — {fmtBps(holderBps(draft))} of
          every buy reaches holders after your cut and any burn. The Distributor splits the pair
          currency it is actually holding across the share register, so what any one wallet receives
          is its share of the supply, not a rate against market cap. It is not a promise: a token
          that stops trading stops paying.
        </Source>
      </Card>
    </section>
  )
}

/**
 * Whether a buyer can pay in ETH for this pair, said at the moment the pair is chosen.
 *
 * This is a funnel fact, not a trivium: with no v4 ETH pool the buyer has to go and acquire the
 * pair currency before they can press Buy, which is the single thing `ZapRouter` exists to remove.
 * A creator picking WXMR should learn that here and not from an empty order book.
 */
function EthRouteNote({ symbol }: { symbol: string }) {
  const route = ethRouteFor(symbol)

  if (!route) {
    return (
      <p className="mt-4 rounded-xl border border-danger-400/25 bg-danger-400/[0.06] p-3 text-[12px] leading-relaxed text-bone-400">
        <span className="font-semibold text-danger-400">Buyers cannot pay in ETH.</span> No Uniswap
        v4 ETH/{symbol} pool was found, so anyone buying has to source {symbol} themselves first.
        Holders are still paid in {symbol} either way — this is about the buyer, not the payout.
      </p>
    )
  }

  const dear = route.bpsAt1Eth > ETH_ROUTE_CHEAP_BPS
  return (
    <p
      className={`mt-4 rounded-xl border p-3 text-[12px] leading-relaxed ${
        dear
          ? 'border-danger-400/25 bg-danger-400/[0.06] text-bone-400'
          : 'border-ink-700 bg-ink-950 text-bone-400'
      }`}
    >
      <span className="font-semibold text-bone-50">Buyers can pay in ETH.</span> Routed
      ETH&nbsp;&rarr;&nbsp;{symbol}&nbsp;&rarr;&nbsp;your token in one transaction, through the{' '}
      {route.feeTier / 10_000}% v4 pool, costing{' '}
      <span className="tnum">{route.bpsAt1Eth.toFixed(1)} bps</span> on a 1 ETH buy
      {dear ? ' — which is steep, and it comes out of what your buyer receives.' : '.'}
    </p>
  )
}

/**
 * The lock. Presets rather than a seconds field, because nobody thinks in seconds and the contract
 * only accepts a 7-day floor anyway.
 */
function VestPicker() {
  const { draft, set } = useDraft()

  return (
    <div>
      <p className="font-display text-[13px] font-semibold text-bone-200">
        Lock your opening buy
        <span className="ml-1.5 font-sans text-[11px] font-medium text-bone-500">optional</span>
      </p>

      <div className="mt-1.5 flex overflow-hidden rounded-xl border border-ink-700 bg-ink-900">
        {VEST_PRESETS.map((p, i) => (
          <button
            key={p.label}
            type="button"
            onClick={() => {
              set('vestDuration', p.value)
              if (p.value === 0) set('vestCliff', 0)
              else if (draft.vestCliff > p.value) set('vestCliff', 0)
            }}
            aria-pressed={draft.vestDuration === p.value}
            className={[
              'min-h-[44px] flex-1 font-mono text-[13px] font-bold transition-colors duration-150',
              i > 0 ? 'border-l border-ink-700' : '',
              draft.vestDuration === p.value
                ? 'bg-bone-50/[0.10] text-bone-50'
                : 'text-bone-400 hover:bg-ink-800 hover:text-bone-200',
            ].join(' ')}
          >
            {p.label}
          </button>
        ))}
      </div>

      <p className="mt-1.5 text-[12px] leading-snug text-bone-500">
        {draft.vestDuration === 0
          ? 'Your buy goes straight to your wallet and you can sell it whenever.'
          : `Released evenly over ${fmtDuration(draft.vestDuration)}. The schedule is written on chain in your launch transaction, so buyers can read it before they buy.`}
      </p>
    </div>
  )
}

function Hero() {
  return (
    <Card className="relative overflow-hidden px-5 pb-6 pt-7">
      <div aria-hidden className="pointer-events-none absolute inset-0 overflow-hidden">
        <div className="absolute -right-10 -top-24 size-64 rounded-full bg-bone-50/[0.07] blur-[64px]" />
      </div>
      <div className="relative">
        <Pill tone="volt">ETHEREUM L1</Pill>
        {/* The headline used to be "Holders get paid in the pair", which was the product when
            dividends WERE the product. They are now one switch among several, and Simple mode has
            them off entirely - so the old headline contradicted the mode selector directly beneath
            it. The pad is the product; the token is what you build with it. */}
        <h1 className="mt-4 font-display text-[30px] font-bold leading-[1.08] tracking-tight text-bone-50">
          Build the token
          <br />
          you actually want.
        </h1>
        <p className="mt-3 max-w-[42ch] text-[14px] leading-relaxed text-bone-400">
          Launch on a live Uniswap v4 pool in one transaction. Take the defaults and be done, or
          choose the pair, the tax, the burn, the locks — and whether holders get paid a{' '}
          <span className="text-bone-200">dividend in the pair currency</span> rather than more of
          your token.
        </p>
      </div>
    </Card>
  )
}

/**
 * Pair selection. Closed by default showing the current choice, because 22 options is a wall on a
 * 390px screen and the default is right for most launches.
 */
function PairPicker({ selected, onPick }: { selected: Pair | undefined; onPick: (p: Pair) => void }) {
  const [open, setOpen] = useState(false)

  if (!selected) return null

  return (
    <div className="space-y-3">
      <Card className="p-4">
        <div className="flex items-center gap-3">
          <TokenLogo pair={selected} size={38} />
          <div className="min-w-0 flex-1">
            <p className="truncate font-display text-[17px] font-bold text-bone-50">{selected.symbol}</p>
            <p className="truncate text-[12px] text-bone-500">{selected.name}</p>
          </div>
          <button
            type="button"
            onClick={() => setOpen((o) => !o)}
            aria-expanded={open}
            className="shrink-0 rounded-lg border border-ink-600 bg-ink-800 px-3 py-2 font-display text-[13px] font-semibold text-bone-200 transition-colors duration-150 hover:bg-ink-700"
          >
            {open ? 'Done' : 'Change'}
          </button>
        </div>

        <DepthPanel pair={selected} />
      </Card>

      {open && (
        <div className="grid grid-cols-2 gap-2">
          {PAIRS.map((p) => {
            const active = p.symbol === selected.symbol
            return (
              <button
                key={p.symbol}
                type="button"
                onClick={() => {
                  onPick(p)
                  setOpen(false)
                }}
                aria-pressed={active}
                className={[
                  'flex items-center gap-2 rounded-xl border px-3 py-2.5 text-left transition-colors duration-150',
                  active
                    ? 'border-bone-200 bg-bone-50/[0.08]'
                    : 'border-ink-700 bg-ink-900 hover:border-ink-600',
                ].join(' ')}
              >
                <TokenLogo pair={p} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate font-display text-[13px] font-bold text-bone-50">
                    {p.symbol}
                  </span>
                  <span className="tnum block truncate text-[10px] text-bone-500">
                    {formatLiquidity(p.liquidityUsd)} liq
                  </span>
                </span>
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

/**
 * Depth is a per-pair property and a creator should see it BEFORE they commit, not after. It is
 * never a reason to drop a pair from the registry — a thin pair constrains only the tokens
 * launched against it.
 */
function DepthPanel({ pair }: { pair: Pair }) {
  const band = depthBand(pair)
  const risks = riskLabels(pair)

  return (
    <div className="mt-4 border-t border-ink-700 pt-4">
      <div className="grid grid-cols-3 gap-3">
        <Stat label="Liquidity" value={formatLiquidity(pair.liquidityUsd)} />
        <Stat label="24h volume" value={formatLiquidity(pair.volume24hUsd)} />
        <Stat label="Live since" value={pair.liveSince.slice(0, 4)} />
      </div>

      <div
        className={[
          'mt-3.5 rounded-xl border p-3',
          band === 'thin'
            ? 'border-danger-400/30 bg-danger-400/[0.06]'
            : 'border-ink-700 bg-ink-900',
        ].join(' ')}
      >
        <p className="text-[12px] leading-relaxed text-bone-400">
          {band === 'thin' && <span className="font-semibold text-danger-400">Thin pair. </span>}
          {depthNote(pair)}
        </p>

        {pair.measuredPool && (
          <p className="tnum mt-2 font-mono text-[11px] leading-relaxed text-bone-500">
            {pair.measuredPool.label}: {pair.measuredPool.reserves}, against{' '}
            {pair.measuredPool.totalSupply} in existence.
          </p>
        )}

        <Source>
          Liquidity and volume measured 2026-08-31 from DexScreener, Ethereum pools only. The
          deep/thin bands are our rule, not a measurement.
          {pair.measuredPool && <> Reserves read on chain: {pair.measuredPool.source}.</>}
        </Source>
      </div>

      <div className="mt-3 flex flex-wrap items-center gap-1.5">
        <span className="rounded-md bg-ink-800 px-1.5 py-0.5 text-[10px] font-semibold text-bone-400">
          {pair.decimals} decimals
        </span>
        {riskCount(pair) === 0 ? (
          <span className="rounded-md bg-bone-50/10 px-1.5 py-0.5 text-[10px] font-semibold text-bone-200">
            no admin powers in bytecode
          </span>
        ) : (
          risks.map((l) => (
            <span
              key={l}
              className="rounded-md bg-danger-400/12 px-1.5 py-0.5 text-[10px] font-semibold text-danger-400"
            >
              {l}
            </span>
          ))
        )}
      </div>
    </div>
  )
}

/**
 * Simple mode's entire fee story, stated rather than configured.
 *
 * There is nothing to adjust here, so there are no controls — just the four numbers that apply
 * and the fact that they are fixed. A row of disabled sliders would imply the values are a
 * choice somebody made badly rather than the point of the mode.
 */
function SimpleTerms({ split }: { split: ReturnType<typeof feeSplit> }) {
  return (
    <Card className="p-5">
      <div className="grid grid-cols-3 gap-4">
        <Stat label="Buys" value="2%" sub="paid by the buyer" />
        <Stat label="Sells" value="2%" sub="paid by the seller" />
        <Stat label="You keep" value={fmtBps(split.creatorBps)} sub="of every trade" />
      </div>

      <p className="mt-4 text-[12px] leading-relaxed text-bone-400">
        The platform takes{' '}
        <span className="font-semibold text-bone-200">{fmtBps(PLATFORM_VOLUME_BPS)} of volume</span>{' '}
        — a flat rate, the same on every launch, fixed in the contract with no setter. Everything
        else is yours.
      </p>
      <p className="mt-2 text-[12px] leading-relaxed text-bone-500">
        No dividends, no burn, no wallet cap, no lock. Switch to{' '}
        <span className="font-semibold text-bone-300">Custom</span> if you want any of them.
      </p>
    </Card>
  )
}

/**
 * "Do you want to pay holders dividends?" — and if yes, IN WHAT.
 *
 * **The creator picks the token. The pad does not pick for them.** A coin quoted in PEPE does not
 * have to pay PEPE; the pair is what it trades against, not a decision about what its holders
 * earn. Defaulting the picker to the pair currency is a convenience, not a constraint — every
 * allowlisted currency is selectable.
 */
function DividendOptIn({
  draft,
  set,
  pair,
}: {
  draft: LaunchDraft
  set: <K extends keyof LaunchDraft>(key: K, value: LaunchDraft[K]) => void
  pair: Pair | undefined
}) {
  const on = draft.creatorBps < 10_000
  const holderPct = (10_000 - draft.creatorBps) / 100
  const rewardSymbol = draft.rewardSymbol || pair?.symbol || '—'

  return (
    <OptIn
      question="Pay holders dividends?"
      hint="Holders earn from every trade, automatically, in whatever token you choose."
      on={on}
      // Turning it on hands holders a quarter by default so the slider starts somewhere real.
      onChange={(v) => set('creatorBps', v ? 7_500 : 10_000)}
    >
      <BpsSlider
        label="Holders' share of your cut"
        hint={`You keep the rest. At ${holderPct}% to holders you keep ${(draft.creatorBps / 100).toFixed(0)}% of your own fee.`}
        value={10_000 - draft.creatorBps}
        onChange={(v) => set('creatorBps', 10_000 - v)}
        max={10_000}
        step={250}
      />

      <div>
        <p className="mb-2 font-display text-[13px] font-semibold text-bone-200">
          Paid in{' '}
          <span className="font-mono text-[12px] font-normal text-bone-500">
            currently {rewardSymbol}
          </span>
        </p>
        <RewardPicker
          selected={rewardSymbol}
          onPick={(sym) => set('rewardSymbol', sym)}
        />
        <p className="mt-2 text-[11.5px] leading-relaxed text-bone-500">
          Any allowlisted currency, not just the one you trade against. Fees arrive in{' '}
          {pair?.symbol ?? 'the pair'} and are converted when a holder claims — if a route cannot be
          found they are paid {pair?.symbol ?? 'the pair'} instead, never nothing.
        </p>
      </div>
    </OptIn>
  )
}

/** Every allowlisted currency, as a scrollable row of chips. */
function RewardPicker({
  selected,
  onPick,
}: {
  selected: string
  onPick: (symbol: string) => void
}) {
  return (
    <div className="-mx-1 flex gap-1.5 overflow-x-auto px-1 pb-1">
      {PAIRS.map((p) => (
        <button
          key={p.symbol}
          type="button"
          onClick={() => onPick(p.symbol)}
          aria-pressed={p.symbol === selected}
          className={[
            'flex shrink-0 items-center gap-1.5 rounded-lg border px-2.5 py-1.5 font-mono text-[12px] font-semibold transition-colors duration-150',
            p.symbol === selected
              ? 'border-bone-400/50 bg-bone-50/[0.08] text-bone-50'
              : 'border-ink-700 bg-ink-900 text-bone-400 hover:border-ink-600',
          ].join(' ')}
        >
          <TokenLogo pair={p} size={14} />
          {p.symbol}
        </button>
      ))}
    </div>
  )
}

/**
 * "Should fees go somewhere other than this wallet?" — the yes/no pattern the whole custom mode
 * is built on.
 *
 * Off by default and off is the honest default: most creators want paying where they stand. The
 * panel only exists once the answer is yes, so a creator who does not need a team wallet never
 * reads a word about one.
 */
function FeeWalletOptIn({
  draft,
  set,
  issues,
}: {
  draft: LaunchDraft
  set: <K extends keyof LaunchDraft>(key: K, value: LaunchDraft[K]) => void
  issues: ReturnType<typeof validate>
}) {
  const on = draft.feeRecipient.length > 0

  return (
    <OptIn
      question="Send fees to a different wallet?"
      hint="A team wallet, splitter or multisig. Off means the wallet you launch from."
      on={on}
      onChange={(v) => set('feeRecipient', v ? '0x' : '')}
    >
      <TextField
        label="Fee wallet"
        hint="Written once at launch. There is no setter, so this cannot be changed afterwards — by you or by us."
        value={draft.feeRecipient}
        onChange={(v) => set('feeRecipient', v.trim())}
        placeholder="0x…"
        mono
        error={issueFor(issues, 'feeRecipient')?.message}
      />
    </OptIn>
  )
}

/**
 * The old CID text boxes, kept as an escape hatch rather than deleted.
 *
 * Two groups still need them: anyone who already pinned their art somewhere and does not want it
 * re-uploaded, and everyone at all while no pinning key is configured. It is COLLAPSED by
 * default, because a form that shows the expert path and the normal path with equal weight has
 * not actually chosen a normal path.
 *
 * It opens itself when uploads are off, since in that state it is the only way through.
 */
function CidFallback({
  draft,
  set,
}: {
  draft: LaunchDraft
  set: <K extends keyof LaunchDraft>(key: K, value: LaunchDraft[K]) => void
}) {
  const configured = pinningConfigured()
  const [open, setOpen] = useState(!configured)

  return (
    <div className="rounded-xl border border-ink-700 bg-ink-900">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        className="flex w-full items-center justify-between gap-3 px-3.5 py-2.5 text-left"
      >
        <span className="min-w-0">
          <span className="block font-display text-[12.5px] font-semibold text-bone-300">
            Already have an IPFS CID?
          </span>
          <span className="mt-0.5 block text-[11px] text-bone-500">
            {configured
              ? 'Paste it instead of uploading.'
              : 'Uploads are off, so this is the way through for now.'}
          </span>
        </span>
        <span aria-hidden className="shrink-0 text-bone-500">
          {open ? '−' : '+'}
        </span>
      </button>

      {open && (
        <div className="space-y-4 border-t border-ink-700 px-3.5 pb-4 pt-3.5">
          <TextField
            label="Image CID"
            hint="Stored on chain as bytes32, so a link that rots cannot take the token with it."
            value={draft.imageCid}
            onChange={(v) => set('imageCid', v.trim())}
            placeholder="bafybeigdyrzt5."
            mono
          />
          <TextField
            label="Banner CID"
            hint="1500 x 500."
            value={draft.bannerCid}
            onChange={(v) => set('bannerCid', v.trim())}
            placeholder="bafybeih4x2q."
            mono
            optional
          />
        </div>
      )}
    </div>
  )
}

function Review({
  issues,
  draft,
}: {
  issues: ReturnType<typeof validate>
  draft: LaunchDraft
}) {
  return (
    <section className="space-y-3.5">
      <SectionTitle>5 · Review</SectionTitle>

      {issues.length > 0 ? (
        <Card className="p-5">
          <h3 className="font-display text-[14px] font-bold text-bone-50">
            {issues.length} thing{issues.length === 1 ? '' : 's'} to fix
          </h3>
          <ul className="mt-3 space-y-2.5">
            {issues.map((i) => (
              <li key={`${i.field}-${i.revert}`} className="flex gap-2.5 text-[13px] leading-snug">
                <span aria-hidden className="mt-[7px] size-1 shrink-0 rounded-full bg-danger-400" />
                <span className="min-w-0 text-bone-400">
                  {i.message}
                  {i.revert && (
                    <span className="ml-1.5 font-mono text-[11px] text-bone-500">{i.revert}()</span>
                  )}
                </span>
              </li>
            ))}
          </ul>
          <p className="mt-4 text-[12px] leading-relaxed text-bone-500">
            These are the launcher&rsquo;s own rules. Each one names the error the transaction would
            revert with.
          </p>
        </Card>
      ) : (
        <Card className="p-5">
          <div className="flex items-center gap-2.5">
            <span aria-hidden className="size-1.5 rounded-full bg-bone-50" />
            <p className="font-display text-[14px] font-bold text-bone-50">
              This configuration would pass every check in the launcher.
            </p>
          </div>
          <p className="mt-2 text-[12px] leading-relaxed text-bone-500">
            Checked against `Launcher._validate`, `FeeHook.configurePool` and
            `FeeHook.configureGraduation`, in the same order the contracts run them.
          </p>
        </Card>
      )}

      <LaunchSubmit draft={draft} formIssues={issues.length} />
    </section>
  )
}
