/**
 * One launched token, with the box that buys and sells it.
 *
 * Distinct from `/preview`, which renders the DRAFT a creator is composing. This route reads a
 * real token off the chain by address, so everything on it is either a chain value or absent.
 *
 * Composition note: the page used to be two components, the card and the trade box. Everything
 * that made this product different from any other pad — who gets paid, how much has actually been
 * paid, which contract holds it — was stated in prose on other screens and shown as a number
 * nowhere. The dividend panel and the fact rows are that gap.
 */
import { useState } from 'react'
import { useParams, Link } from 'react-router-dom'
import { parseAbi } from 'viem'
import { useLaunches } from '../lib/useLaunches'
import { useTokenDetail } from '../lib/useTokenDetail'
import { useWallet } from '../lib/useWallet'
import { poolKeyFor } from '../lib/tradeTx'
import { activeClient, activeDeployment } from '../lib/chain'
import { walletClient, walletErrorMessage, isUserRejection } from '../lib/wallet'
import { TradePanel } from '../components/TradePanel'
import { LaunchCard } from '../components/LaunchCard'
import { DividendPanel } from '../components/DividendPanel'
import { TokenFacts } from '../components/TokenFacts'
import { SweepPanel } from '../components/SweepPanel'
import { PriceChart } from '../components/PriceChart'
import { usePriceHistory } from '../lib/usePriceHistory'

const WITHDRAW_ABI = parseAbi(['function withdraw()'])
// Named components: viem takes an object for a named tuple and an array for an unnamed one, so an
// unnamed signature turns `poolKeyFor`'s object into `Address "undefined" is invalid` at encode
// time rather than anything that names the cause.
const SWEEP_ABI = parseAbi([
  'function sweep((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key)',
])

export function Token() {
  const { address } = useParams<{ address: string }>()
  const state = useLaunches()
  const { account } = useWallet()
  const [claiming, setClaiming] = useState(false)
  const [claimError, setClaimError] = useState<string | null>(null)
  const [claimNonce, setClaimNonce] = useState(0)
  const [sweeping, setSweeping] = useState(false)
  const [sweepError, setSweepError] = useState<string | null>(null)

  const listing =
    state.kind === 'ok'
      ? state.listings.find((l) => l.address?.toLowerCase() === address?.toLowerCase())
      : undefined

  const detail = useTokenDetail(
    listing?.address ?? null,
    listing?.chainPair ?? null,
    account ?? null,
  )

  const history = usePriceHistory(
    detail.kind === 'ready' ? detail.poolId : null,
    listing?.address ?? null,
    listing?.chainPair ?? null,
    18,
    listing?.pair.decimals ?? 18,
  )

  if (state.kind === 'idle' || state.kind === 'loading') {
    return <p className="py-16 text-center text-[13px] text-bone-500">Reading the chain…</p>
  }
  if (state.kind === 'error') {
    return <p className="py-16 text-center text-[13px] text-danger-400">{state.message}</p>
  }

  if (!listing || !listing.address || !listing.chainPair) {
    return (
      <div className="py-16 text-center">
        <p className="text-[13px] text-bone-400">No launch at that address.</p>
        <Link
          to="/board"
          className="mt-3 inline-block text-[13px] text-bone-500 underline underline-offset-2 hover:text-bone-200"
        >
          Back to the board
        </Link>
      </div>
    )
  }

  /**
   * The PULL path. `Distributor.withdraw()` pays this wallet directly and does not wait for the
   * push cursor — which matters, because nothing in `src/` currently advances that cursor.
   */
  async function claim() {
    if (!account || detail.kind !== 'ready') return
    setClaimError(null)
    setClaiming(true)
    try {
      const wallet = walletClient(account)
      const hash = await wallet.writeContract({
        address: detail.dividends.distributor,
        abi: WITHDRAW_ABI,
        functionName: 'withdraw',
        chain: wallet.chain,
        account,
      })
      const r = await activeClient().waitForTransactionReceipt({ hash })
      if (r.status !== 'success') throw new Error('The claim reverted.')
      setClaimNonce((n) => n + 1)
    } catch (e) {
      if (!isUserRejection(e)) setClaimError(walletErrorMessage(e))
    } finally {
      setClaiming(false)
    }
  }

  /**
   * `sweep()` is permissionless and pays its caller a 0.5% bounty. It is also the ONLY thing that
   * turns accrued claims into money — the automatic path was deleted because it never fired on
   * ordinary trades and making it fire would have broken settlement for third-party routers.
   */
  async function sweep() {
    if (!account || !listing?.chainPair || !listing.address) return
    const feeHook = activeDeployment().feeHook
    if (!feeHook) return
    setSweepError(null)
    setSweeping(true)
    try {
      const { key } = poolKeyFor(listing.address, listing.chainPair)
      const wallet = walletClient(account)
      const hash = await wallet.writeContract({
        address: feeHook,
        abi: SWEEP_ABI,
        functionName: 'sweep',
        args: [key],
        chain: wallet.chain,
        account,
      })
      const r = await activeClient().waitForTransactionReceipt({ hash })
      if (r.status !== 'success') throw new Error('The sweep reverted.')
      setClaimNonce((n) => n + 1)
    } catch (e) {
      if (!isUserRejection(e)) setSweepError(walletErrorMessage(e))
    } finally {
      setSweeping(false)
    }
  }

  return (
    <div className="mx-auto max-w-5xl px-4 py-8">
      <Link
        to="/board"
        className="text-[12px] text-bone-500 underline underline-offset-2 hover:text-bone-200"
      >
        ← Board
      </Link>

      <div className="mt-4 grid gap-5 lg:grid-cols-[minmax(0,1fr)_340px] lg:items-start">
        {/* The card already carries the contract address with a copy button. Repeating it
            underneath as a second link put the same string on screen twice, twenty pixels
            apart, and made the reader check whether they were different. */}
        <div className="min-w-0 space-y-5">
          <LaunchCard listing={listing} />

          <PriceChart
            points={history.points}
            pairSymbol={listing.pair.symbol}
            loading={history.loading}
            supply={history.supply}
            pairAddress={listing.chainPair}
          />

          {detail.kind === 'ready' && (
            <TokenFacts
              listing={listing}
              dividends={detail.dividends}
              fees={detail.fees}
              payoutSymbol={listing.pair.symbol}
              payoutDecimals={listing.pair.decimals}
            />
          )}
        </div>

        {/* Sticky on desktop so the trade box stays reachable, static on mobile where a
            sticky element would eat the viewport it is competing with. */}
        <div className="space-y-5 lg:sticky lg:top-5">
          <TradePanel
            token={listing.address}
            symbol={listing.symbol}
            pair={listing.chainPair}
            pairSymbol={listing.pair.symbol}
            pairDecimals={listing.pair.decimals}
          />

          {detail.kind === 'loading' && (
            <p className="rounded-2xl border border-ink-700 bg-ink-900 p-4 text-[12px] text-bone-500">
              Reading the distributor…
            </p>
          )}
          {detail.kind === 'error' && (
            <p className="rounded-2xl border border-ink-700 bg-ink-900 p-4 text-[12px] leading-relaxed text-bone-500">
              Could not read dividend state: {detail.message}
            </p>
          )}
          {detail.kind === 'ready' && (
            <div key={claimNonce}>
              <DividendPanel
                d={detail.dividends}
                payoutSymbol={listing.pair.symbol}
                payoutDecimals={listing.pair.decimals}
                account={account ?? null}
                onClaim={claim}
                claiming={claiming}
              />
              {claimError && (
                <p className="mt-2 text-[12px] leading-relaxed text-danger-400">{claimError}</p>
              )}
              <div className="mt-5">
                <SweepPanel
                  fees={detail.fees}
                  pairSymbol={listing.pair.symbol}
                  pairDecimals={listing.pair.decimals}
                  tokenSymbol={listing.symbol}
                  account={account ?? null}
                  onSweep={sweep}
                  sweeping={sweeping}
                  error={sweepError}
                />
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
