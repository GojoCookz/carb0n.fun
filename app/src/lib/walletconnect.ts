/**
 * WalletConnect v2, as a second source for the same EIP-1193 provider the app already speaks.
 *
 * ## Why this exists
 *
 * Until now the only way in was `window.ethereum`. That covers desktop browser extensions and
 * nothing else: on a phone, opening the site in Safari or Chrome and tapping connect did nothing,
 * because there is no injected provider there. Given the app is built mobile-first, the majority
 * case was the unsupported one.
 *
 * ## Why NOT wagmi or AppKit
 *
 * Both would work, and both would mean rewriting all ten call sites in `wallet.ts`'s orbit around
 * React hooks, a QueryClient and a theme layer. `@walletconnect/ethereum-provider` IS an EIP-1193
 * provider, so it drops into `getProvider()` and every existing consumer - `walletClient()`,
 * `switchToActiveChain()`, the launch and trade paths - keeps working untouched. The seam was
 * already in the right place.
 *
 * ## Why it is loaded lazily, and this matters
 *
 * The package pulls in 250 transitive packages. Importing it at module scope would put all of that
 * in the initial bundle of a mobile-first app, to serve a connection method most visitors will not
 * use on any given load. It is therefore behind `import()`, and it is only touched when either:
 *
 *   - the user explicitly picks WalletConnect, or
 *   - a previous session is found in storage, which we detect by reading localStorage keys
 *     directly rather than by booting the library to ask it.
 *
 * ## The projectId is required and is not optional
 *
 * WalletConnect's relay refuses connections without one. There is no default and none can be
 * invented - it identifies our app to their infrastructure. It comes from
 * `VITE_WALLETCONNECT_PROJECT_ID`, and when that is unset `isConfigured()` returns false and the
 * UI never offers the option. That is deliberate: an offered button that cannot work is worse
 * than an absent one.
 */
import type { NetworkInfo } from './networks'
import { NETWORKS } from './networks'

/** The subset of EIP-1193 the app uses. Kept structurally identical to `wallet.ts`'s. */
export type Eip1193 = {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>
  on?: (event: string, handler: (...args: unknown[]) => void) => void
  removeListener?: (event: string, handler: (...args: unknown[]) => void) => void
}

type WcProvider = Eip1193 & {
  connected: boolean
  accounts: string[]
  enable: () => Promise<string[]>
  disconnect: () => Promise<void>
}

const PROJECT_ID = (import.meta.env.VITE_WALLETCONNECT_PROJECT_ID ?? '').trim()

/** WalletConnect namespaces its session storage with this prefix. */
const STORAGE_PREFIX = 'wc@2:'

export function isConfigured(): boolean {
  return PROJECT_ID.length > 0
}

/**
 * Is there a session on disk from a previous visit?
 *
 * Read directly rather than by initialising the provider, because initialising is the expensive
 * thing we are trying to avoid on a cold load with no session.
 */
export function hasStoredSession(): boolean {
  if (typeof window === 'undefined') return false
  try {
    for (let i = 0; i < window.localStorage.length; i++) {
      const k = window.localStorage.key(i)
      if (k?.startsWith(STORAGE_PREFIX)) return true
    }
  } catch {
    // Private mode, or storage disabled. Treat as no session rather than breaking the page.
  }
  return false
}

let provider: WcProvider | null = null
let initInFlight: Promise<WcProvider> | null = null

/**
 * Build the provider once.
 *
 * `initInFlight` deduplicates concurrent callers: the button and the session-restore path can both
 * ask during the same tick, and `EthereumProvider.init` is not cheap enough to run twice.
 */
async function getOrInit(): Promise<WcProvider> {
  if (provider) return provider
  if (initInFlight) return initInFlight

  if (!isConfigured()) {
    throw new Error('WalletConnect is not configured for this deployment.')
  }

  initInFlight = (async () => {
    const { EthereumProvider } = await import('@walletconnect/ethereum-provider')

    const all: NetworkInfo[] = Object.values(NETWORKS)
    const rpcMap: Record<number, string> = {}
    for (const n of all) rpcMap[n.chain.id] = n.chain.rpcUrls.default.http[0]

    const p = (await EthereumProvider.init({
      projectId: PROJECT_ID,
      showQrModal: true,

      // EVERY CHAIN IS OPTIONAL, INCLUDING THE ONE WE ACTUALLY USE.
      //
      // `chains` is a hard requirement: a wallet that cannot serve one of them refuses the whole
      // session. Robinhood Chain is a new network that almost no mobile wallet has heard of, so
      // requiring 4663 would mean nearly every connection attempt fails at the handshake with no
      // useful error. Listing everything as optional lets the session establish, after which
      // `switchToActiveChain()` handles the network the same way it already does for extensions.
      optionalChains: all.map((n) => n.chain.id) as [number, ...number[]],
      rpcMap,

      metadata: {
        name: 'carbonado.fun',
        description: 'A launchpad where holders get paid in the pair.',
        url: window.location.origin,
        // Absolute, because the wallet renders this on a different origin (often a phone).
        icons: [`${window.location.origin}/icon-192.png`],
      },
    })) as unknown as WcProvider

    provider = p
    return p
  })()

  try {
    return await initInFlight
  } finally {
    initInFlight = null
  }
}

/**
 * Open the QR modal and connect. Resolves with the accounts, or rejects if the user closes it.
 *
 * `enable()` both opens the modal and waits for approval; if a session already exists it returns
 * immediately without showing anything.
 */
export async function connectWalletConnect(): Promise<string[]> {
  const p = await getOrInit()
  const accounts = await p.enable()
  return accounts
}

/**
 * Re-attach to a session from a previous visit, without prompting.
 *
 * Returns the accounts, or an empty array when there is nothing to restore. Never throws: a failed
 * restore should leave the user disconnected, not break the page load.
 */
export async function restoreWalletConnect(): Promise<string[]> {
  if (!isConfigured() || !hasStoredSession()) return []
  try {
    const p = await getOrInit()
    return p.connected ? p.accounts : []
  } catch {
    return []
  }
}

/**
 * End the session on both sides.
 *
 * The provider is dropped regardless of whether the remote disconnect succeeded, because the user
 * asked to be disconnected and the local state is the part they can see.
 */
export async function disconnectWalletConnect(): Promise<void> {
  const p = provider
  provider = null
  if (!p) return
  try {
    await p.disconnect()
  } catch {
    // Relay unreachable or session already dead. Nothing useful to tell the user.
  }
}

/** The live provider, or null. Used by `wallet.ts` to decide which provider to hand out. */
export function activeWalletConnectProvider(): Eip1193 | null {
  return provider && provider.connected ? provider : null
}
