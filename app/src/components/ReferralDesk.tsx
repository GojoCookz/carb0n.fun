import { useCallback, useEffect, useState } from 'react'
import { formatUnits } from 'viem'
import { Button, Card } from './Primitives'
import { useWallet } from '../lib/useWallet'
import { activeNetwork } from '../lib/activeNetwork'
import { explorerAddress, explorerTx, shortAccount, walletErrorMessage } from '../lib/wallet'
import {
  claimReferral,
  readReferralState,
  referralLink,
  type ReferralState,
} from '../lib/referrals'

/**
 * The working half of the referral programme: your link, what you are owed, and the claim.
 *
 * **This replaces a page that described the feature in the future tense while the vault was
 * already deployed and holding a tier schedule.** Everything here is read from
 * `ReferralVault` - the tiers, the balances, the referrer - so the page cannot drift from the
 * contract the way hand-written copy did.
 *
 * **Balances are per currency because that is how the contract stores them.** A referral is paid
 * in whatever the trade was denominated in, so someone whose network traded four pairs has four
 * balances and four claims. Summing them into one figure would invent a number that exists nowhere
 * on-chain, and this file will not do that.
 *
 * `earned` is shown next to `owed` so a zero balance can be read as "already paid out" rather than
 * "never earned" - two very different facts that a single number cannot distinguish.
 */
export function ReferralDesk() {
  const w = useWallet()
  const net = activeNetwork()
  const [state, setState] = useState<ReferralState | null>(null)
  const [loading, setLoading] = useState(false)
  const [copied, setCopied] = useState(false)
  const [claiming, setClaiming] = useState<string | null>(null)
  const [txHash, setTxHash] = useState<`0x${string}` | null>(null)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    try {
      setState(await readReferralState(w.account))
    } catch (e) {
      setError(walletErrorMessage(e))
    } finally {
      setLoading(false)
    }
  }, [w.account])

  useEffect(() => {
    void refresh()
  }, [refresh, net.id])

  const onClaim = useCallback(
    async (currency: `0x${string}`, symbol: string) => {
      if (!w.account) return
      setError(null)
      setClaiming(symbol)
      try {
        const hash = await claimReferral(w.account, currency)
        setTxHash(hash)
        await refresh()
      } catch (e) {
        setError(walletErrorMessage(e))
      } finally {
        setClaiming(null)
      }
    },
    [w.account, refresh],
  )

  // No vault on this network. Say which network, so the fix is obvious.
  if (state && !state.vault) {
    return (
      <Card className="lit space-y-2 p-5">
        <p className="text-sm text-bone-200">Referrals are not live on {net.label}.</p>
        <p className="text-xs text-bone-500">
          The vault is deployed per network. Switch networks to see your balances there.
        </p>
      </Card>
    )
  }

  return (
    <div className="space-y-4">
      {/* --- The link ------------------------------------------------------------------ */}
      <Card className="lit space-y-3 p-5">
        <h3 className="text-sm font-semibold text-bone-50">Your link</h3>
        {!w.account ? (
          <div className="space-y-2">
            <p className="text-xs text-bone-500">
              A link is tied to an address, so there is nothing to show until a wallet is connected.
            </p>
            <Button onClick={() => void w.connect()} disabled={w.connecting}>
              {w.connecting ? 'Check your wallet.' : 'Connect wallet'}
            </Button>
          </div>
        ) : (
          <>
            <div className="flex items-center gap-2">
              <code className="min-w-0 flex-1 truncate rounded-lg border border-ink-700 bg-ink-950 px-3 py-2 font-mono text-[11px] text-bone-300">
                {referralLink(w.account)}
              </code>
              <Button
                onClick={() => {
                  void navigator.clipboard.writeText(referralLink(w.account!)).then(() => {
                    setCopied(true)
                    setTimeout(() => setCopied(false), 1600)
                  })
                }}
              >
                {copied ? 'Copied' : 'Copy'}
              </Button>
            </div>
            <p className="text-xs text-bone-500">
              Anyone who launches through this link is recorded on-chain, permanently, on their first
              launch. A second referrer is ignored by the contract - the first one is kept.
            </p>
          </>
        )}
      </Card>

      {/* --- Balances ------------------------------------------------------------------ */}
      <Card className="lit space-y-3 p-5">
        <div className="flex items-center justify-between">
          <h3 className="text-sm font-semibold text-bone-50">Earnings</h3>
          {loading && <span className="text-[11px] text-bone-500">reading chain…</span>}
        </div>

        {!w.account ? (
          <p className="text-xs text-bone-500">Connect a wallet to see what you are owed.</p>
        ) : state?.neverEarned ? (
          <p className="text-xs text-bone-500">
            Nothing yet. Earnings appear here per currency as your network trades - a referral is
            paid in whatever the trade was denominated in.
          </p>
        ) : (
          <div className="space-y-2">
            {state?.balances.map((b) => (
              <div
                key={b.currency}
                className="flex items-center justify-between gap-3 rounded-lg border border-ink-800 bg-ink-950 px-3 py-2.5"
              >
                <div className="min-w-0">
                  <div className="font-mono text-sm text-bone-100">
                    {formatUnits(b.owed, b.decimals)}{' '}
                    <span className="text-bone-400">{b.symbol}</span>
                  </div>
                  {/* Lifetime, so a zero balance reads as "paid out" not "never earned". */}
                  <div className="text-[11px] text-bone-500">
                    {formatUnits(b.earned, b.decimals)} {b.symbol} lifetime
                  </div>
                </div>
                <Button
                  onClick={() => void onClaim(b.currency, b.symbol)}
                  disabled={b.owed === 0n || claiming === b.symbol || !w.onRightChain}
                >
                  {claiming === b.symbol ? 'Claiming…' : b.owed === 0n ? 'Claimed' : 'Claim'}
                </Button>
              </div>
            ))}
          </div>
        )}

        {w.account && !w.onRightChain && (
          <p className="text-xs text-amber-300">
            Your wallet is on another network. Switch to {net.label} to claim.
          </p>
        )}
        {error && <p className="text-xs text-danger-400">{error}</p>}
        {txHash && (
          <a
            href={explorerTx(txHash)}
            target="_blank"
            rel="noreferrer noopener"
            className="inline-block text-xs text-steel-300 underline"
          >
            View claim transaction
          </a>
        )}
      </Card>

      {/* --- Who referred you ---------------------------------------------------------- */}
      {state?.referrer && (
        <Card className="lit p-5">
          <p className="text-xs text-bone-500">
            You were referred by{' '}
            <a
              href={explorerAddress(state.referrer)}
              target="_blank"
              rel="noreferrer noopener"
              className="font-mono text-bone-300 underline"
            >
              {shortAccount(state.referrer)}
            </a>
            . This is recorded on-chain and cannot be changed.
          </p>
        </Card>
      )}

      {/* --- Tiers, read from the contract --------------------------------------------- */}
      {state && state.tiers.length > 0 && (
        <Card className="lit space-y-2 p-5">
          <h3 className="text-sm font-semibold text-bone-50">The split</h3>
          <div className="flex flex-wrap gap-2">
            {state.tiers.map((bps, i) => (
              <span
                key={i}
                className="rounded-full border border-ink-700 bg-ink-900 px-2.5 py-1 text-[11px] text-bone-300"
              >
                Level {i + 1}
                <span className="ml-1.5 font-mono text-bone-400">{(bps / 100).toFixed(0)}%</span>
              </span>
            ))}
          </div>
          <p className="text-xs text-bone-500">
            Read from{' '}
            <a
              href={explorerAddress(state.vault!)}
              target="_blank"
              rel="noreferrer noopener"
              className="underline"
            >
              the vault
            </a>
            , not typed here. Each level takes that share of the platform's cut - never the
            creator's share and never the holders'.
          </p>
        </Card>
      )}
    </div>
  )
}
