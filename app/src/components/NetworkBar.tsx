import { useSyncExternalStore } from 'react'
import { Link } from 'react-router-dom'
import { Logo } from './Logo'
import {
  activeNetworkId,
  setActiveNetwork,
  selectableNetworks,
  subscribeNetwork,
} from '../lib/activeNetwork'
import { NETWORKS, type NetworkId } from '../lib/networks'
import { isDeployed } from '../lib/activeNetwork'
import { WalletButton } from './WalletButton'

/**
 * Top bar: who we are, which chain, and whether anything is live.
 *
 * It carries our own mark rather than Ethereum's. The previous version put the raw Ethereum glyph
 * here, which borrowed credibility that is not ours to borrow - the homage belongs *inside* our
 * mark's construction, not as a substitute for it.
 *
 * **This used to read a hardcoded "Ethereum Sepolia / testnet".** It kept saying that after
 * Robinhood Chain went live with a full deployment and thirty approved pairs, because the string
 * was typed by hand and nobody revisited it. Everything here is DERIVED now: the list of networks
 * comes from which ones actually have a launcher, and the badge from whether the selected one is a
 * testnet.
 *
 * **Only networks with a deployed launcher are offered.** A picker that can select a chain with no
 * contracts is a picker offering transactions that cannot succeed - the control looks fine and the
 * transaction reverts with something unreadable.
 *
 * The status light is never green on a testnet. A light that reads "ok" while the contracts are
 * unaudited and hold no real value is the smallest possible lie with the largest payoff for us.
 */

/** Testnets are a property of the network, not of the string in the badge. */
const TESTNETS: ReadonlySet<NetworkId> = new Set<NetworkId>(['sepolia'])

export function NetworkBar() {
  const id = useSyncExternalStore(subscribeNetwork, activeNetworkId, activeNetworkId)
  const options = selectableNetworks()
  const current = NETWORKS[id]
  const isTestnet = TESTNETS.has(id)
  const deployed = isDeployed(id)

  return (
    <div className="lit border-b border-ink-800 bg-ink-950/80 backdrop-blur-xl">
      <div className="mx-auto flex max-w-2xl items-center gap-3 px-4 py-2.5">
        <Link to="/" aria-label="carbonado.fun home" className="shrink-0">
          <Logo size={19} />
        </Link>

        <span className="ml-auto flex shrink-0 items-center gap-2">
          <WalletButton />
          {/* A native <select> on purpose: it is keyboard accessible, works on mobile without a
              portal, and cannot drift out of sync with the store because its value IS the store. */}
          <label className="sr-only" htmlFor="network-select">
            Network
          </label>
          <select
            id="network-select"
            value={id}
            onChange={(e) => setActiveNetwork(e.target.value as NetworkId)}
            className="cursor-pointer rounded-full border border-ink-700 bg-ink-900 px-2.5 py-1 text-[11px] font-medium leading-none text-bone-300 outline-none transition-colors hover:border-ink-600 focus-visible:ring-2 focus-visible:ring-steel-400/40"
            title="Switch network. Only chains with a deployed launcher are listed."
          >
            {options.map((n) => (
              <option key={n.id} value={n.id}>
                {n.label}
              </option>
            ))}
          </select>

          <span
            className="flex items-center gap-1.5 rounded-full border border-ink-700 bg-ink-900 px-2 py-1"
            title={
              !deployed
                ? `No launcher is deployed on ${current.label} yet. Launching opens after the audit.`
                : isTestnet
                  ? 'A test network. Tokens here hold no real value.'
                  : `Live on ${current.label}. The contracts are unaudited - see the docs before committing real value.`
            }
          >
            <span
              aria-hidden
              className={`size-1.5 rounded-full ${
                !deployed ? 'bg-ink-600' : isTestnet ? 'bg-steel-400' : 'bg-emerald-400'
              }`}
            />
            <span className="whitespace-nowrap text-[10px] font-semibold leading-none text-bone-500">
              {!deployed ? 'not deployed' : isTestnet ? 'testnet' : 'live'}
            </span>
          </span>
        </span>
      </div>
    </div>
  )
}
