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

/** Networks that actually have a launcher. The ONLY safe source for a network picker. */
export function selectableNetworks(): NetworkInfo[] {
  return Object.values(NETWORKS).filter((n) => n.deployment.launcher !== null)
}

function isSelectable(id: string | null): id is NetworkId {
  if (!id) return false
  const n = (NETWORKS as Record<string, NetworkInfo | undefined>)[id]
  return !!n && n.deployment.launcher !== null
}

/**
 * Prefers a real mainnet over a testnet when both are available.
 *
 * Sepolia stays selectable on purpose - it is where the ETH-side contracts live until L1 is
 * audited - but it must never be what a first-time visitor lands on while a production chain is
 * deployed.
 */
function defaultNetwork(): NetworkId {
  const live = selectableNetworks()
  if (live.length === 0) return 'sepolia'
  const production = live.find((n) => n.id !== 'sepolia')
  return (production ?? live[0]).id
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

export function setActiveNetwork(id: NetworkId): void {
  if (!isSelectable(id)) return
  if (id === current) return
  current = id
  try {
    window.localStorage.setItem(STORAGE_KEY, id)
  } catch {
    // Not being able to remember the choice is survivable; failing to switch is not.
  }
  for (const fn of listeners) fn()
}

/** `useSyncExternalStore` contract. */
export function subscribeNetwork(fn: () => void): () => void {
  listeners.add(fn)
  return () => listeners.delete(fn)
}
