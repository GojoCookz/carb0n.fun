import { Card, SectionTitle, Pill } from '../components/Primitives'
import { Source } from '../components/Form'
import { ADDRESSES, USD_SOURCES } from '../lib/chain'
import { PAIRS, riskCount, type Pair } from '../lib/pairs'

/**
 * What this is, and what it costs you to use it.
 *
 * **This pad is CHAIN-first, not pair-first.** Ethereum L1 is the constant; the pair currency is a
 * per-launch choice out of an allowlist. An earlier version of this page described the product as
 * "trades against wrapped Monero" and "holders are paid in WXMR", which promoted one option out of
 * twenty-two to the identity of the whole thing. WXMR is a pair a creator may pick. It is not the
 * product, and there is no main token.
 *
 * Every count below is COMPUTED from `PAIRS` rather than written down, so the copy cannot drift
 * away from the table it describes.
 */
export function About() {
  const total = PAIRS.length
  const clean = PAIRS.filter((p) => riskCount(p) === 0)
  const pausable = PAIRS.filter((p) => p.risks.pausable)
  const blacklist = PAIRS.filter((p) => p.risks.blacklist)
  const mintable = PAIRS.filter((p) => p.risks.mintable)
  const priceable = PAIRS.filter((p) => USD_SOURCES[p.symbol])

  return (
    <div className="space-y-6">
      <section className="space-y-3.5">
        <SectionTitle>How it works</SectionTitle>
        <Card className="space-y-4 p-5">
          <Step
            n="1"
            title="You create a token"
            body="Fixed supply, minted once. No mint function, no burn, no owner, no upgrade. It cannot be inflated or changed after launch."
          />
          <Step
            n="2"
            title="You choose what it trades against"
            body={`Any one of ${total} allowlisted currencies — WETH, USDC, PEPE, SPX, WXMR and the rest. A Uniswap v4 pool opens against whichever you pick. The choice is per launch; there is no house currency and no main token.`}
          />
          <Step
            n="3"
            title="Holders are paid in that same currency"
            body="A hook takes the fee inside the swap and splits it pro rata to holders, denominated in the pair currency you chose — not in more of the token they already hold. That one constraint is what the whole design is built around."
          />
          <Step
            n="4"
            title="It is live and locked from the first block"
            body="No presale, no bonding curve, no migration step. The pool trades immediately and the liquidity is unremovable by construction: the launcher owns the position and contains no code path that withdraws it."
          />
        </Card>
      </section>

      <section className="space-y-3.5">
        <SectionTitle>What it is not</SectionTitle>
        <Card className="space-y-3.5 p-5">
          <Risk
            title="There is no bonding curve"
            body="Nothing fills up and nothing migrates. Graduation here is a signal — a threshold, a one-way latch and an event for apps to index. It unlocks nothing and pays nothing, because the market cap behind it is a spot price anyone can move inside a single transaction."
          />
          <Risk
            title="Nothing pays out during a trade"
            body="No fee pays anybody during a trade. Fees accrue inside the swap as claims and become real money only when somebody calls sweep(), which anyone may do for a 0.5% bounty. Sell fees wait a further step: they arrive in the launch token, and converting them to the pair currency needs a swap of its own. An earlier build tried to pay out automatically from inside the swap and it was deleted - it never fired on ordinary trades, and making it fire would have let the hook move tokens mid-swap and silently overcharge any router that pays before it swaps. On a quiet pool a sweep can be a while coming."
          />
          <Risk
            title="Explorers will report every pool here at 0% fee"
            body="The pool's own fee field really is zero, because the hook charges instead of the pool. Any indexer reading it reports 0% and is wrong every time. The real rate lives on the hook's PoolConfigured and FeeTaken events."
          />
        </Card>
      </section>

      <section className="space-y-3.5">
        <SectionTitle>Risks you should read</SectionTitle>
        <Card className="space-y-3.5 border-danger-400/25 p-5">
          <Risk
            title="The pair you choose carries its own risks, and they differ"
            body={`${clean.length} of the ${total} allowlisted currencies have no admin powers at all in their deployed bytecode. The other ${total - clean.length} do: ${pausable.length} can be paused (${names(pausable)}), ${blacklist.length} can blacklist an address (${names(blacklist)}), and ${mintable.length} can mint more supply. A pause freezes every pool using that currency; a blacklist silently stops payouts to the address it hits. The launch form shows this per pair before you commit.`}
          />
          <Risk
            title="Depth is a property of the pair, not of this pad"
            body="Holders are paid in the pair currency, so they have to be able to sell it. A thin pair constrains only the tokens launched against it — it is never a reason to drop it from the allowlist, but you should see the number before you pick."
          />
          <Risk
            title="Most pairs have no dollar price on Ethereum L1"
            body={`Chainlink publishes a usable feed for ${priceable.length} of the ${total}. PEPE has no feed of any kind on L1 — not against USD, not against ETH. That is why every threshold in this app is denominated in the pair asset on chain, and why dollar figures appear only where a feed address is verified in this codebase.`}
          />
          <Risk
            title="None of this is deployed, and none of it is audited"
            body="The contracts pass their own test suite, including a run against the real v4 PoolManager on a pinned mainnet fork. That is not an audit and it is not a deployment."
          />
        </Card>
        <Source>
          Admin powers were established by scanning deployed bytecode for function selectors, not by
          reading a project's marketing. Verified 2026-08-31.
        </Source>
      </section>

      <section className="space-y-3.5">
        <SectionTitle>Contracts</SectionTitle>

        <Card className="divide-y divide-ink-700">
          <AddressRow
            label="Uniswap v4 PoolManager"
            value={ADDRESSES.mainnet.poolManager}
            note="the only live contract this depends on"
          />
        </Card>

        <Card className="divide-y divide-ink-700">
          {OURS.map(([name, role]) => (
            <div key={name} className="flex items-center justify-between gap-3 px-4 py-3">
              <span className="min-w-0">
                <span className="block font-display text-[13px] font-semibold text-bone-200">
                  {name}
                </span>
                <span className="block truncate text-[11px] text-bone-500">{role}</span>
              </span>
              <span className="shrink-0 font-mono text-[11px] text-bone-600">not deployed</span>
            </div>
          ))}
        </Card>

        <div className="flex items-center gap-2 px-1">
          <Pill tone="pending">not deployed</Pill>
          <span className="text-[12px] text-bone-500">
            No launchpad address exists yet, on any network.
          </span>
        </div>
      </section>
    </div>
  )
}

/** Our own contracts. No addresses, because none exist — a placeholder link would be a dead one. */
const OURS: [string, string][] = [
  ['PairRegistry', 'the address allowlist a launch may pair against'],
  ['Launcher', 'creates the token, opens the pool, locks the liquidity'],
  ['FeeHook', 'takes the fee inside the swap; holds the graduation latch'],
  ['Distributor', 'the dividend ledger, one per launch'],
  ['LaunchToken', 'the ERC-20 every launch clones'],
]

/** Up to three symbols, then a count. A twelve-item inline list is not read by anyone. */
function names(pairs: Pair[]): string {
  const shown = pairs.slice(0, 3).map((p) => p.symbol)
  const rest = pairs.length - shown.length
  return rest > 0 ? `${shown.join(', ')} and ${rest} more` : shown.join(', ')
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

function Risk({ title, body }: { title: string; body: string }) {
  return (
    <div className="min-w-0">
      <p className="font-display text-[14px] font-bold text-bone-50">{title}</p>
      <p className="mt-1 text-[13px] leading-relaxed text-bone-400">{body}</p>
    </div>
  )
}

function AddressRow({ label, value, note }: { label: string; value: string; note: string }) {
  return (
    <a
      href={`https://etherscan.io/address/${value}`}
      target="_blank"
      rel="noreferrer noopener"
      className="flex items-center justify-between gap-3 px-4 py-3 transition-colors duration-150 hover:bg-ink-800"
    >
      <span className="min-w-0">
        <span className="block font-display text-[13px] font-semibold text-bone-200">{label}</span>
        <span className="block truncate font-mono text-[11px] text-bone-500">{value}</span>
      </span>
      <span className="shrink-0 text-right">
        <span className="block text-[11px] text-bone-500">{note}</span>
        <span className="mt-0.5 block text-[11px] font-semibold text-bone-200">Etherscan ↗</span>
      </span>
    </a>
  )
}
