import { useState } from 'react'
import { Card, SectionTitle, Pill } from '../components/Primitives'
import { Stat, Source } from '../components/Form'
import { DEPLOYMENTS } from '../lib/chain'

/**
 * The referral programme.
 *
 * Translated from BaseStonk's, which is the best-designed part of their product. The
 * one structural idea worth copying exactly:
 *
 *   **Every level earns a share of the SAME trade fee**, scaled by distance — not a
 *   fraction of the fraction below it. Most multi-level schemes decay to nothing by
 *   the third hop because they compound downward. This one does not, which is what
 *   makes recruiting recruiters worth more than recruiting traders.
 *
 * HONESTY, and it is a real gap rather than a deployment detail: **our fee has no
 * platform wedge to pay referrals out of.** `FeeHook._routeFee` splits the fee to the
 * creator and to holders, and that is all of it. A referral must never be paid out of
 * the creator's or the holders' share, so this feature needs a contract change before
 * it can pay anyone. The page says so rather than implying a code is waiting.
 */
export function Rewards() {
  const notDeployed = DEPLOYMENTS.mainnet.pairRegistry === null

  return (
    <div className="space-y-6">
      <Hero />

      <section className="space-y-3.5">
        <SectionTitle>How it will work</SectionTitle>
        <Card className="lit space-y-4 p-5">
          <Step
            n="1"
            title="One link, permanent"
            body="Anyone who arrives through your link is yours — and so is everyone their network brings, five levels down. A referral never expires."
          />
          <Step
            n="2"
            title="Paid per trade, from the reported fee"
            body="Your share is credited from the platform cut each trade reports on-chain. Not estimated from volume, not batched, not reconciled later."
          />
          <Step
            n="3"
            title="In the pair currency of each trade"
            body="A WETH-paired trade pays you WETH; a WXMR-paired trade pays you WXMR. Dust across many tokens settles into one clean payment."
          />
          <Step
            n="4"
            title="Both sides win"
            body="Applying someone's code takes a slice off the platform's cut for you too. Using a code is never worse than not using one."
          />
        </Card>
      </section>

      <section className="space-y-3.5">
        <SectionTitle>Why five levels actually pays</SectionTitle>
        <Card className="lit p-5">
          <p className="text-[13px] leading-relaxed text-bone-400">
            Most multi-level schemes decay to nothing by the third hop, because each level
            takes a fraction <span className="italic">of the fraction below it</span>. This one
            does not. Every level earns a share of the{' '}
            <span className="font-semibold text-bone-50">same trade fee</span>, set by distance
            from the trader.
          </p>

          <div className="mt-4 overflow-hidden rounded-xl border border-ink-700 bg-ink-900">
            <div className="grid grid-cols-2 divide-x divide-ink-700">
              <div className="p-4">
                <p className="text-[10px] font-semibold uppercase tracking-wider text-bone-600">
                  What this is
                </p>
                <p className="mt-2 font-mono text-[13px] text-bone-50">E = Σ ρ&#8342; · Φ&#8342;</p>
                <p className="mt-1.5 text-[11px] leading-snug text-bone-500">
                  each level, a share of the whole fee
                </p>
              </div>
              <div className="p-4">
                <p className="text-[10px] font-semibold uppercase tracking-wider text-bone-600">
                  What it is not
                </p>
                <p className="mt-2 font-mono text-[13px] text-bone-500 line-through decoration-danger-400/70">
                  E = Σ ρ&#7496; · Φ&#8342;
                </p>
                <p className="mt-1.5 text-[11px] leading-snug text-bone-500">
                  compounding down the chain
                </p>
              </div>
            </div>
          </div>

          <p className="mt-4 text-[13px] leading-relaxed text-bone-400">
            The consequence: <span className="font-semibold text-bone-50">a tree outpays a branch.</span>{' '}
            Five people who each build are worth more than fifty who only trade.
          </p>
        </Card>
      </section>

      <Calculator />

      <section className="space-y-3.5">
        <SectionTitle>Your code</SectionTitle>
        <Card className="lit p-5">
          <div className="grid grid-cols-2 gap-5">
            <Stat label="Your code" value="—" sub="issued at launch" />
            <Stat label="Accrued" value="—" sub="nothing has traded" />
          </div>
          <button
            type="button"
            disabled
            className="mt-5 w-full cursor-not-allowed rounded-xl bg-ink-800 px-5 py-3.5 font-display text-[15px] font-bold text-bone-500"
          >
            Generate referral link
          </button>
          <p className="mt-2 text-center text-[12px] leading-snug text-bone-500">
            {notDeployed
              ? 'Nothing is deployed, and the fee has no platform share to pay referrals from yet. Both are needed before a code can pay anyone.'
              : 'Connect a wallet to generate your link.'}
          </p>
        </Card>
      </section>

      <section className="space-y-3.5">
        <SectionTitle>What has to happen first</SectionTitle>
        <Card className="lit border-danger-400/25 p-5">
          <p className="text-[13px] leading-relaxed text-bone-400">
            <span className="font-semibold text-bone-50">
              The fee currently has no platform share.
            </span>{' '}
            <span className="font-mono text-[12px] text-bone-200">FeeHook._routeFee</span> splits
            every fee between the creator and holders — that is the whole of it. A referral must
            be paid out of the platform&rsquo;s own cut and never out of the creator&rsquo;s or the
            holders&rsquo;, so a platform wedge has to exist before any of the above can pay.
          </p>
          <Source>
            Stated here rather than buried, because the alternative is a page that looks like a
            code is waiting for you when the contract cannot pay one.
          </Source>
        </Card>
      </section>
    </div>
  )
}

/**
 * Arithmetic on numbers the visitor enters, against a rate they set. Not a projection,
 * not a promise, and the rate is explicitly marked as unset — because it is.
 */
function Calculator() {
  const [dailyVolume, setDailyVolume] = useState(100_000)
  const [rateBps, setRateBps] = useState(50)

  const annualVolume = dailyVolume * 365
  const annualFees = (annualVolume * rateBps) / 10_000

  const fmt = (n: number) =>
    n >= 1_000_000
      ? `$${(n / 1_000_000).toLocaleString('en-US', { maximumFractionDigits: 2 })}M`
      : `$${Math.round(n).toLocaleString('en-US')}`

  return (
    <section className="space-y-3.5">
      <SectionTitle>Run the arithmetic</SectionTitle>
      <Card className="lit p-5">
        <label htmlFor="vol" className="font-display text-[13px] font-semibold text-bone-200">
          Your network&rsquo;s daily volume
        </label>
        <input
          id="vol"
          type="range"
          min={10_000}
          max={5_000_000}
          step={10_000}
          value={dailyVolume}
          onChange={(e) => setDailyVolume(Number(e.target.value))}
          className="mt-3 h-1.5 w-full cursor-pointer appearance-none rounded-full bg-ink-700 accent-bone-50"
        />
        <p className="tnum mt-2 font-mono text-[15px] font-bold text-bone-50">{fmt(dailyVolume)} / day</p>

        <label
          htmlFor="rate"
          className="mt-6 block font-display text-[13px] font-semibold text-bone-200"
        >
          Assumed platform cut
          <span className="ml-2 rounded-md bg-danger-400/12 px-1.5 py-0.5 text-[10px] font-semibold text-danger-400">
            not set yet
          </span>
        </label>
        <input
          id="rate"
          type="range"
          min={10}
          max={100}
          step={5}
          value={rateBps}
          onChange={(e) => setRateBps(Number(e.target.value))}
          className="mt-3 h-1.5 w-full cursor-pointer appearance-none rounded-full bg-ink-700 accent-bone-50"
        />
        <p className="tnum mt-2 font-mono text-[15px] font-bold text-bone-50">
          {(rateBps / 100).toFixed(2)}% of volume
        </p>

        <div className="mt-6 grid grid-cols-2 gap-5 border-t border-ink-700 pt-5">
          <Stat label="Annual volume" value={fmt(annualVolume)} />
          <Stat
            label="Fee pool it generates"
            value={fmt(annualFees)}
            sub="your share is a slice of this"
          />
        </div>

        <Source>
          Arithmetic on the numbers above, nothing else. The platform cut does not exist in the
          contracts yet, so the second slider is an assumption you are choosing — not a rate
          anybody is offering.
        </Source>
      </Card>
    </section>
  )
}

function Hero() {
  return (
    <Card className="lit relative overflow-hidden px-5 pb-6 pt-7">
      <div aria-hidden className="pointer-events-none absolute inset-0 overflow-hidden">
        <div className="absolute -right-16 -top-28 size-72 rounded-full bg-bone-50/[0.06] blur-[72px]" />
      </div>
      <div className="relative">
        <Pill tone="pending">not live</Pill>
        <h1 className="chrome-text mt-4 font-display text-[30px] font-bold leading-[1.08] tracking-tight">
          Earn on every
          <br />
          trade you bring.
        </h1>
        <p className="mt-3 max-w-[42ch] text-[14px] leading-relaxed text-bone-400">
          Not once at signup — on every trade your network ever makes, five levels deep, paid in
          the currency each trade actually used.
        </p>
      </div>
    </Card>
  )
}

function Step({ n, title, body }: { n: string; title: string; body: string }) {
  return (
    <div className="flex gap-3.5">
      <span className="mt-0.5 flex size-6 shrink-0 items-center justify-center rounded-full bg-bone-50/10 font-display text-[12px] font-bold text-bone-50">
        {n}
      </span>
      <div className="min-w-0">
        <p className="font-display text-[14px] font-bold text-bone-50">{title}</p>
        <p className="mt-1 text-[13px] leading-relaxed text-bone-400">{body}</p>
      </div>
    </div>
  )
}
