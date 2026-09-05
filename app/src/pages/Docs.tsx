import { Link } from 'react-router-dom'
import { Card, SectionTitle } from '../components/Primitives'
import { Source } from '../components/Form'
import { PAIRS } from '../lib/pairs'

/**
 * The documentation hub.
 *
 * Written as answers, not as a table of contents. Someone opening docs on a launchpad
 * has one of about eight questions, and the fastest thing we can do is answer them on
 * this page rather than route them three clicks deeper.
 *
 * Anything not yet true is marked `soon` inline. A docs page that describes unbuilt
 * features in the present tense is the most expensive kind of lie, because people plan
 * around it.
 */
export function Docs() {
  const chains = PAIRS.filter((p) => p.category === 'chain')

  return (
    <div className="space-y-6">
      <header className="px-1">
        <h1 className="chrome-text font-display text-[30px] font-bold leading-[1.08] tracking-tight">
          How this works.
        </h1>
        <p className="mt-2.5 max-w-[46ch] text-[14px] leading-relaxed text-bone-400">
          A launchpad on Ethereum L1 where every token opens a real Uniswap v4 pool in the same
          transaction, and every buy pays holders in the currency the token trades against.
        </p>
      </header>

      <section className="space-y-3.5">
        <SectionTitle>The short version</SectionTitle>
        <Card className="lit divide-y divide-ink-700">
          {SHORT.map(([q, a]) => (
            <div key={q} className="px-4 py-3.5">
              <p className="font-display text-[13.5px] font-bold text-bone-50">{q}</p>
              <p className="mt-1 text-[12.5px] leading-relaxed text-bone-400">{a}</p>
            </div>
          ))}
        </Card>
      </section>

      <section className="space-y-3.5">
        <SectionTitle>Get paid in other chains</SectionTitle>
        <Card className="lit p-5">
          <p className="text-[13px] leading-relaxed text-bone-400">
            Holders are paid in the currency the token trades against. Pick a wrapped chain and
            that is what lands in their wallet — <span className="text-bone-50">Bitcoin</span>,{' '}
            <span className="text-bone-50">Monero</span>, <span className="text-bone-50">XRP</span>{' '}
            — earned by holding an Ethereum token, without leaving Ethereum.
          </p>

          <div className="mt-4 grid gap-2 sm:grid-cols-2">
            {chains.map((p) => (
              <div
                key={p.symbol}
                className="flex items-baseline justify-between gap-3 rounded-xl border border-ink-700 bg-ink-900 px-3.5 py-2.5"
              >
                <span className="font-mono text-[13px] font-bold text-bone-50">{p.symbol}</span>
                <span className="tnum text-[11px] text-bone-500">
                  {p.liquidityUsd >= 1_000_000
                    ? `$${(p.liquidityUsd / 1_000_000).toFixed(1)}M`
                    : `$${Math.round(p.liquidityUsd / 1000)}K`}{' '}
                  liq
                </span>
              </div>
            ))}
          </div>

          <Source>
            Liquidity measured live from DexScreener, Ethereum pools only. Depth matters here
            because holders have to be able to sell what they are paid — the launch form warns
            when a pair is thin.
          </Source>
        </Card>
      </section>

      <section className="space-y-3.5">
        <SectionTitle>Everything else</SectionTitle>
        <div className="grid gap-3 sm:grid-cols-2">
          {TOPICS.map((t) => (
            <Card key={t.title} className="lit p-4">
              <div className="flex items-baseline justify-between gap-2">
                <p className="font-display text-[14px] font-bold text-bone-50">{t.title}</p>
                {t.soon && (
                  <span className="shrink-0 rounded-md bg-steel-500/20 px-1.5 py-0.5 text-[10px] font-semibold text-steel-300">
                    soon
                  </span>
                )}
              </div>
              <p className="mt-1.5 text-[12.5px] leading-relaxed text-bone-400">{t.body}</p>
              {t.to && (
                <Link
                  to={t.to}
                  className="mt-3 inline-block font-display text-[12.5px] font-bold text-bone-200 underline decoration-ink-600 underline-offset-4 transition-colors duration-200 hover:text-bone-50"
                >
                  {t.linkLabel}
                </Link>
              )}
            </Card>
          ))}
        </div>
      </section>

      <Card className="lit p-5">
        <p className="font-display text-[14px] font-bold text-bone-50">Nothing is deployed</p>
        <p className="mt-1.5 text-[12.5px] leading-relaxed text-bone-400">
          The contracts pass their own suite, including a full launch against the real v4
          PoolManager on a pinned mainnet fork. That is not an audit and it is not a deployment.
          No launchpad address exists on any network.
        </p>
        <Link
          to="/about"
          className="mt-3 inline-block font-display text-[12.5px] font-bold text-bone-200 underline decoration-ink-600 underline-offset-4 transition-colors duration-200 hover:text-bone-50"
        >
          Contracts and risks →
        </Link>
      </Card>
    </div>
  )
}

const SHORT: [string, string][] = [
  [
    'Is there a bonding curve?',
    'No. Creating a token opens a real Uniswap v4 pool in the same transaction. The first candle is a pool price, not a curve that migrates somewhere else later.',
  ],
  [
    'Can the liquidity be pulled?',
    'No. The launcher opens the position in its own name and contains no code path that removes it — no admin function, no owner, no upgrade. That is stronger than burning an LP token.',
  ],
  [
    'What do holders actually receive?',
    'A share of every buy, in the pair currency, pro rata to their balance. Never in more of the token they already hold.',
  ],
  [
    'Are sells taxed?',
    'Only if the creator set a sell rate — it defaults to zero and is capped at 10%, the same ceiling as buys. Sells are charged in the launch token rather than the pair currency, because a seller pays the token in and has no pair currency to take. Those tokens are swapped for the pair currency on a sweep and then paid out like any other fee.',
  ],
  [
    'Why do fees arrive late?',
    'Nothing pays holders during a trade. Fees accrue inside the swap as claims and become real money only when somebody calls sweep(), which anyone may do for a 0.5% bounty. An earlier build tried to pay out automatically from inside the swap; it was deleted, because it never fired on ordinary trades and making it fire would have let the hook move tokens mid-swap and silently overcharge any router that pays before it swaps. Sell fees wait a further step because converting them into the pair currency needs a swap of its own. On a quiet pool this can be a while.',
  ],
  [
    'Why does my explorer say 0% fee?',
    "Because the pool's fee field genuinely is zero — the hook charges instead of the pool. The real rate lives on the hook's PoolConfigured and FeeTaken events.",
  ],
  [
    'What does graduation unlock?',
    'Nothing. It is a signal — a threshold, a one-way latch and an event for apps to index. The market cap behind it is a spot price anyone can move in one transaction, so nothing of value hangs off it.',
  ],
]

const TOPICS: { title: string; body: string; soon?: boolean; to?: string; linkLabel?: string }[] = [
  {
    title: 'Launching',
    body: 'One transaction: token, pool, opening price, optional dev buy. Fixed supply, no mint, no owner.',
    to: '/',
    linkLabel: 'Open the form →',
  },
  {
    title: 'Graduation',
    body: 'A threshold in pair-currency units, fixed at launch, latched one way. Denominated in the pair because most pairs have no USD feed on L1.',
    to: '/preview',
    linkLabel: 'See the bar →',
  },
  {
    title: 'Pair risk',
    body: 'Every pair carries its own admin powers and its own depth. Both are shown before you commit, measured from bytecode and live pools.',
    to: '/about',
    linkLabel: 'Read the risks →',
  },
  {
    title: 'Referrals',
    body: 'Five levels, each earning a share of the same trade fee rather than a fraction of the fraction below it.',
    soon: true,
    to: '/rewards',
    linkLabel: 'How it will work →',
  },
  {
    title: 'Dividend baskets',
    body: 'Pay holders in several assets at once rather than only the pair currency, converted on-chain with a price floor.',
    soon: true,
  },
  {
    title: 'Dev-buy vesting',
    body: 'Route the creator buy into a vault that releases linearly, with the schedule published on-chain in the launch transaction itself.',
    soon: true,
  },
]
