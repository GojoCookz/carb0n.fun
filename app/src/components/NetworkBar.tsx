import { Link } from 'react-router-dom'
import { Logo } from './Logo'
import { DEPLOYMENTS } from '../lib/chain'

/**
 * Top bar: who we are, what chain, and whether anything is live.
 *
 * It carries our own mark rather than Ethereum's. The previous version put the raw
 * Ethereum glyph here, which borrowed credibility that is not ours to borrow — the
 * homage belongs *inside* our mark's construction, not as a substitute for it.
 *
 * **The status is DERIVED from `DEPLOYMENTS`, never typed by hand.** It read "not deployed" for
 * a while after the launcher went live on Sepolia, because it was a hardcoded string nobody
 * revisited. A status light is the one element on a page that must not be able to drift, so the
 * only way to change it now is to change the deployment record it reads.
 *
 * It is never green. Sepolia is a test network, and a status light that reads as "ok" while the
 * contracts are unaudited and hold no real value is the smallest possible lie with the largest
 * possible payoff for us.
 */
export function NetworkBar() {
  const live = DEPLOYMENTS.sepolia.launcher !== null
  const mainnetLive = DEPLOYMENTS.mainnet.launcher !== null

  return (
    <div className="lit border-b border-ink-800 bg-ink-950/80 backdrop-blur-xl">
      <div className="mx-auto flex max-w-2xl items-center gap-3 px-4 py-2.5">
        <Link to="/" aria-label="carbonado.fun home" className="shrink-0">
          <Logo size={19} />
        </Link>

        <span className="ml-auto flex shrink-0 items-center gap-3">
          <span className="whitespace-nowrap text-[11px] leading-none text-bone-500">
            Ethereum <span className="text-bone-400">{mainnetLive ? 'L1' : 'Sepolia'}</span>
          </span>
          <span
            className="flex items-center gap-1.5 rounded-full border border-ink-700 bg-ink-900 px-2 py-1"
            title={
              live
                ? 'The launcher is live on the Sepolia test network. Mainnet requires an audit.'
                : 'No launcher is deployed on any network.'
            }
          >
            <span aria-hidden className="size-1.5 rounded-full bg-steel-400" />
            <span className="whitespace-nowrap text-[10px] font-semibold leading-none text-bone-500">
              {live ? 'testnet' : 'not deployed'}
            </span>
          </span>
        </span>
      </div>
    </div>
  )
}
