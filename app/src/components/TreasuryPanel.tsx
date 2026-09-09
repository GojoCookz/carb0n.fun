import { useState } from 'react'
import { formatUnits, type Address } from 'viem'
import { useWallet } from '../lib/useWallet'
import { walletClient, walletErrorMessage, isUserRejection, shortAccount } from '../lib/wallet'
import { activeClient, activeDeployment } from '../lib/chain'
import { useTreasury, VAULT_ABI, type RevenueLine } from '../lib/treasury'

/**
 * Platform revenue, claimable by the treasury wallet and nobody else.
 *
 * ## Why this exists
 *
 * The platform's cut of every trade is credited to `treasury` inside `ReferralVault`, and `claim()`
 * pays `msg.sender`. Before this panel the only way to collect it was to hand-assemble calldata and
 * paste it into a wallet's hex field - which is a thing an operator will get wrong once and then
 * stop doing.
 *
 * ## Why it is credited rather than pushed
 *
 * `sweep()` is permissionless. If it PUSHED to the platform and that transfer could fail, anybody
 * could brick payouts for an entire pool by making the platform transfer revert. Crediting a
 * balance and letting the owner withdraw cannot be griefed.
 *
 * ## What hiding it does and does not do
 *
 * The panel renders nothing unless the connected wallet equals `vault.treasury()`. **That is
 * tidiness, not security** - anyone can read the treasury address out of the bundle or off the
 * chain. The actual protection is in the contract: `claim()` pays the caller, so a stranger who
 * finds this UI and calls it claims their own zero balance and wastes their own gas.
 *
 * The address is read from `vault.treasury()`, never hardcoded, so this panel cannot disagree with
 * the contract about who the owner is.
 */
export function TreasuryPanel() {
  const { account } = useWallet()
  const state = useTreasury((account ?? null) as Address | null)
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState<string | null>(null)
  const [nonce, setNonce] = useState(0)

  // Everyone who is not the treasury sees nothing at all.
  if (!account || state.kind === 'not-treasury' || state.kind === 'none') return null
  if (state.kind === 'loading') return null

  const claimable = state.lines.filter((l) => l.owed > 0n)

  async function claim(line: RevenueLine) {
    const vault = activeDeployment().referralVault as Address | null
    if (!vault || !account) return

    setError(null)
    setDone(null)
    setBusy(line.symbol)
    try {
      const wallet = walletClient(account as Address)
      const hash = await wallet.writeContract({
        address: vault,
        abi: VAULT_ABI,
        functionName: 'claim',
        args: [line.address],
        chain: wallet.chain,
        account: account as Address,
      })
      const receipt = await activeClient().waitForTransactionReceipt({ hash })
      if (receipt.status !== 'success') throw new Error('The claim reverted.')
      setDone(`${fmt(line.owed, line.decimals)} ${line.symbol} sent to your wallet.`)
      setNonce((n) => n + 1)
    } catch (e) {
      if (!isUserRejection(e)) setError(walletErrorMessage(e))
    } finally {
      setBusy(null)
    }
  }

  return (
    <section className="mt-10" key={nonce}>
      <div className="rounded-(--radius-card) border border-gold-500/30 bg-ink-850 p-5">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <h2 className="font-display text-[15px] font-bold text-bone-100">Platform revenue</h2>
          <span className="font-mono text-[11px] text-bone-500">
            treasury {shortAccount(state.treasury)}
          </span>
        </div>

        <p className="mt-2 text-[12px] leading-relaxed text-bone-500">
          The platform&rsquo;s share of every trade, after any referrer tiers. Credited rather than
          sent, because <span className="font-mono">sweep()</span> is permissionless and a push that
          could fail would let anyone stall a pool&rsquo;s payouts.
        </p>

        {claimable.length === 0 ? (
          <p className="mt-4 rounded-xl border border-ink-700 bg-ink-900 px-4 py-3 text-[13px] text-bone-400">
            Nothing owed right now.
            {state.lines.length > 0 && ' Everything earned so far has been claimed.'}
          </p>
        ) : (
          <ul className="mt-4 space-y-2">
            {claimable.map((l) => (
              <li
                key={l.address}
                className="flex items-center justify-between gap-3 rounded-xl border border-ink-700 bg-ink-900 px-4 py-3"
              >
                <span className="min-w-0">
                  <span className="value block font-mono text-[15px] font-semibold">
                    {fmt(l.owed, l.decimals)} {l.symbol}
                  </span>
                  <span className="mt-0.5 block text-[11px] text-bone-500">
                    {fmt(l.earned, l.decimals)} {l.symbol} earned since launch
                  </span>
                </span>
                <button
                  type="button"
                  onClick={() => void claim(l)}
                  disabled={busy !== null}
                  className="shrink-0 rounded-lg border border-gold-500/40 bg-gold-500/10 px-3.5 py-2 font-display text-[13px] font-semibold text-gold-300 transition-colors hover:border-gold-400/60 disabled:opacity-50"
                >
                  {busy === l.symbol ? 'Check your wallet.' : 'Claim'}
                </button>
              </li>
            ))}
          </ul>
        )}

        {done && (
          <p className="mt-3 rounded-xl border border-steel-500/40 bg-steel-500/10 px-4 py-3 text-[12px] text-steel-200">
            {done}
          </p>
        )}
        {error && (
          <p className="mt-3 rounded-xl border border-danger-400/40 bg-danger-400/10 px-4 py-3 text-[12px] text-danger-400">
            {error}
          </p>
        )}

        <p className="mt-3 text-[10px] leading-relaxed text-bone-600">
          Only this wallet sees this panel, and only this wallet can collect:{' '}
          <span className="font-mono">claim()</span> pays whoever calls it. The treasury address is
          read from the vault, not written into the app.
        </p>
      </div>
    </section>
  )
}

/** Trailing zeros are noise on a revenue figure. */
function fmt(v: bigint, decimals: number): string {
  const n = Number(formatUnits(v, decimals))
  if (n === 0) return '0'
  if (n < 0.0001) return n.toExponential(2)
  if (n < 1) return n.toFixed(6).replace(/0+$/, '')
  return n.toLocaleString(undefined, { maximumFractionDigits: 4 })
}
