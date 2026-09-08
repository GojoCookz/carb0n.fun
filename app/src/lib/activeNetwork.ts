/**
 * The network the app is currently pointed at, switchable at RUNTIME.
 *
 * **Why this exists.** Sepolia was hardcoded across fourteen files - `DEPLOYMENTS.sepolia`,
 * `sepoliaClient`, `switchToSepolia`, and copy reading "live on Sepolia". That was correct while
 * exactly one network had contracts on it. It stopped being correct the moment Robinhood Chain went
 * live: the app was talking to a test network while a real deployment with thirty approved pairs
 * sat unused.
 *
 * A build-time constant cannot fix that, because the user chooses the chain, not the bundler. So
 * the active network is a tiny observable store: components subscribe, non-React modules read it
 * synchronously, and every consumer changes together when it flips.
 *
 * **The selection rule is deliberately narrow: only networks with a deployed launcher may be
 * selected.** A picker that can select a chain with no contracts is a picker offering transactions
 * that cannot succeed - the button would look fine and the transaction would revert with something
 * unreadable.
 *
 * The choice is persisted, because being bounced back to a different chain on every reload is
 * worse than the storage. It is validated on read: a stored value naming a network that has since
 * lost its deployment falls back to the default rather than being trusted.
 */
import { NETWORKS, type NetworkId, type NetworkInfo } from './networks'

const STORAGE_KEY = 'carb0n.activeNetwork'

/**
 * The networks a user may pick between.
 *
 * **Sepolia is excluded from the picker even though it has a launcher.** It is a test network; the
 * tokens on it are worthless and offering it beside two real chains invites someone to launch into
 * a void and think they shipped. It stays reachable for development via `?network=sepolia`.
 *
 * **Ethereum mainnet is INCLUDED even though nothing is deployed there yet**, because hiding it
 * answers the wrong question. A user who wants Ethereum should see that we know about it and that
 * it is not open yet - not be left wondering whether the product supports it at all. The launch
 * controls stay disabled and name that reason; the network is visible, not silently missing.
 */
const PRODUCTION: readonly NetworkId[] = ['mainnet', 'robinhood']

export function selectableNetworks(): NetworkInfo[] {
  const forced = devOverride()
  const ids = forced ? ([...PRODUCTION, forced] as NetworkId[]) : PRODUCTION
  return ids.map((id) => NETWORKS[id])
}

/** `?network=sepolia` keeps the testnet reachable for development without shipping it to users. */
function devOverride(): NetworkId | null {
  if (typeof window === 'undefined') return null
  try {
    const q = new URLSearchParams(window.location.search).get('network')
    return q && q in NETWORKS ? (q as NetworkId) : null
  } catch {
    return null
  }
}

/** Whether a network can actually receive a launch right now. */
export function isDeployed(id: NetworkId): boolean {
  return NETWORKS[id].deployment.launcher !== null
}

/**
 * A network is selectable if it exists and is on offer - NOT if it has a launcher.
 *
 * Those came apart when Ethereum mainnet joined the picker without a deployment. Gating selection
 * on `launcher !== null` would have made the option unclickable with no explanation, which is
 * worse than letting someone select it and reading why it is closed.
 */
function isSelectable(id: string | null): id is NetworkId {
  if (!id) return false
  if (!(id in NETWORKS)) return false
  return selectableNetworks().some((n) => n.id === id)
}

/**
 * Prefers a real mainnet over a testnet when both are available.
 *
 * Sepolia stays selectable on purpose - it is where the ETH-side contracts live until L1 is
 * audited - but it must never be what a first-time visitor lands on while a production chain is
 * deployed.
 */
/** Default to a network that can actually receive a launch today. */
function defaultNetwork(): NetworkId {
  const usable = selectableNetworks().find((n) => n.deployment.launcher !== null)
  return (usable ?? NETWORKS.robinhood).id
}

function readStored(): NetworkId {
  if (typeof window === 'undefined') return defaultNetwork()
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY)
    // Validated, not trusted: a network can lose its deployment between visits.
    if (isSelectable(raw)) return raw
  } catch {
    // Storage can throw in private modes. A default is always better than a crash.
  }
  return defaultNetwork()
}

let current: NetworkId = readStored()
const listeners = new Set<() => void>()

/** Synchronous read, for modules that are not React components. */
export function activeNetworkId(): NetworkId {
  return current
}

export function activeNetwork(): NetworkInfo {
  return NETWORKS[current]
}

/**
 * Paints the network's skin by setting `data-network` on <html>.
 *
 * **Done here rather than in a component on purpose.** The CSS variables in `index.css` are the
 * single source of colour for the entire app, so flipping one attribute retints everything at once
 * - including the elements nobody would remember to update. Driving it from a React effect instead
 * would mean the theme lags the store by a render and could be missed entirely by anything that
 * renders outside the tree.
 */
function paint(id: NetworkId): void {
  if (typeof document === 'undefined') return
  document.documentElement.setAttribute('data-network', id)
}

export function setActiveNetwork(id: NetworkId): void {
  if (!isSelectable(id)) return
  if (id === current) return
  current = id
  try {
    window.localStorage.setItem(STORAGE_KEY, id)
  } catch {
    // Not being able to remember the choice is survivable; failing to switch is not.
  }
  paint(id)
  for (const fn of listeners) fn()
}

// Paint on load too, so a restored choice is themed before first render rather than flashing the
// default palette and correcting itself.
paint(current)

/** `useSyncExternalStore` contract. */
export function subscribeNetwork(fn: () => void): () => void {
  listeners.add(fn)
  return () => listeners.delete(fn)
}
