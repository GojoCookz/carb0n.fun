/**
 * Wallet connection, using viem's `custom` transport over an EIP-1193 provider.
 *
 * **No wallet library.** wagmi/RainbowKit/ConnectKit each pull in a connector registry, a query
 * client and a theme layer to solve a problem this app does not have: it targets one chain and
 * sends at most two transactions. viem is already a dependency for reads, and `custom(provider)`
 * is the whole integration.
 *
 * **Two providers, one seam.** The provider is no longer always `window.ethereum`. It is either
 * the injected one or a WalletConnect session, and `getProvider()` is the single place that
 * decides. Everything downstream - `walletClient()`, `switchToActiveChain()`, the launch and
 * trade paths - was already routed through it, so adding a second source needed no changes at any
 * of the ten call sites. See `walletconnect.ts` for why that library and why it loads lazily.
 *
 * Everything here REPORTS rather than throws where the user can act on it, because a rejected
 * signature is a normal outcome, not an error state — a wallet popup the user closes must leave
 * the form exactly as it was.
 */
import { createWalletClient, custom, type Address, type WalletClient } from 'viem'
import { activeNetwork } from './activeNetwork'
import {
  activeWalletConnectProvider,
  connectWalletConnect,
  disconnectWalletConnect,
  isConfigured as walletConnectConfigured,
  restoreWalletConnect,
} from './walletconnect'

export { walletConnectConfigured, restoreWalletConnect }

/** The subset of EIP-1193 this app uses. */
type Eip1193 = {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>
  on?: (event: string, handler: (...args: unknown[]) => void) => void
  removeListener?: (event: string, handler: (...args: unknown[]) => void) => void
}

declare global {
  interface Window {
    ethereum?: Eip1193
  }
}

/**
 * The provider to talk to, in priority order.
 *
 * A live WalletConnect session wins over the injected provider. That order is deliberate: the only
 * way to hold a WC session is to have deliberately scanned a QR code, whereas `window.ethereum` is
 * injected without asking. If a user on a desktop with MetaMask installed goes out of their way to
 * connect a phone wallet, sending their transactions to MetaMask instead would be the wrong answer
 * every time.
 */
export function getProvider(): Eip1193 | null {
  const wc = activeWalletConnectProvider()
  if (wc) return wc
  return typeof window !== 'undefined' && window.ethereum ? window.ethereum : null
}

/**
 * Is there an INJECTED provider? Distinct from "can the user connect at all".
 *
 * On a phone browser this is false while WalletConnect is still perfectly available, so this must
 * not be used to decide whether to offer a connect button - `WalletButton` asks about both.
 */
export function hasInjectedWallet(): boolean {
  return typeof window !== 'undefined' && !!window.ethereum
}

export function hasWallet(): boolean {
  return getProvider() !== null
}

/**
 * Is the live session a WalletConnect one?
 *
 * Drives whether "Disconnect" is offered. A site cannot revoke an injected provider's permission -
 * clearing local state there would show "disconnected" and then silently reconnect on reload,
 * which is a lie the next page load exposes.
 */
export function isWalletConnectSession(): boolean {
  return activeWalletConnectProvider() !== null
}

export type WalletError = { code: number; message: string }

/** EIP-1193 user-rejection. Treated as a normal cancel, never surfaced as a failure. */
export function isUserRejection(e: unknown): boolean {
  const code = (e as { code?: number } | null)?.code
  return code === 4001 || code === 5000
}

/** A message worth showing. Wallet errors are verbose and mostly not for humans. */
export function walletErrorMessage(e: unknown): string {
  if (isUserRejection(e)) return 'You rejected the request in your wallet.'
  const m = (e as { shortMessage?: string; message?: string } | null) ?? {}
  const raw = m.shortMessage || m.message || 'Something went wrong.'
  // viem appends the full request body to some errors; the first line is the useful part.
  return raw.split('\n')[0].slice(0, 200)
}

/** Which way in. `auto` picks the only sensible one for the current device. */
export type Transport = 'auto' | 'injected' | 'walletconnect'

/**
 * Connect.
 *
 * **`auto` is what makes the phone case work, and it is why this is not just an injected call.**
 * Every in-form connect button in the app - the one under the launch form, the one in the trade
 * panel - already calls this function. Routing the no-injected-provider case to WalletConnect here
 * means all of them start working on mobile without any of them changing.
 *
 * Priority when `auto`:
 *   1. an existing WC session, which is already an answer
 *   2. an injected provider, because a desktop user with an extension expects their extension
 *   3. WalletConnect, which on a phone is the only thing left
 */
export async function connect(transport: Transport = 'auto'): Promise<Address[]> {
  if (transport === 'walletconnect') {
    return (await connectWalletConnect()) as Address[]
  }

  if (transport === 'injected') {
    const injected = typeof window !== 'undefined' ? window.ethereum : null
    if (!injected) throw new Error('No wallet extension found in this browser.')
    return (await injected.request({ method: 'eth_requestAccounts' })) as Address[]
  }

  const existing = activeWalletConnectProvider()
  if (existing) return (await existing.request({ method: 'eth_accounts' })) as Address[]

  if (hasInjectedWallet()) return connect('injected')
  if (walletConnectConfigured()) return connect('walletconnect')

  throw new Error('No wallet found.')
}

/**
 * End the session and forget the account.
 *
 * Only meaningful for WalletConnect: an injected provider has no concept of a site disconnecting
 * itself, so for those this is a no-op and the UI does not offer it. Leaving a WC user with no way
 * out would strand them on whichever wallet they first scanned.
 */
export async function disconnect(): Promise<void> {
  await disconnectWalletConnect()
}

/** Accounts already authorised, without prompting. Used to restore state on load. */
export async function currentAccounts(): Promise<Address[]> {
  const p = getProvider()
  if (!p) return []
  try {
    return (await p.request({ method: 'eth_accounts' })) as Address[]
  } catch {
    return []
  }
}

export async function currentChainId(): Promise<number | null> {
  const p = getProvider()
  if (!p) return null
  try {
    const hex = (await p.request({ method: 'eth_chainId' })) as string
    return Number.parseInt(hex, 16)
  } catch {
    return null
  }
}

/**
 * Move the wallet to Sepolia, adding the network if the wallet has never seen it.
 *
 * The 4902 branch is not optional. A wallet that does not know the chain rejects the switch with
 * that code, and without handling it the user gets "unrecognized chain" and no way forward.
 */
export async function switchToActiveChain(): Promise<void> {
  const p = getProvider()
  if (!p) throw new Error('No wallet found.')
  const net = activeNetwork()
  const hexId = `0x${net.chain.id.toString(16)}`
  try {
    await p.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: hexId }] })
  } catch (e) {
    if ((e as { code?: number }).code !== 4902) throw e
    await p.request({
      method: 'wallet_addEthereumChain',
      params: [
        {
          chainId: hexId,
          chainName: net.chain.name,
          nativeCurrency: net.chain.nativeCurrency,
          rpcUrls: [net.chain.rpcUrls.default.http[0]],
          blockExplorerUrls: [net.explorer],
        },
      ],
    })
  }
}

/**
 * Kept so existing imports keep working; it follows the active network like everything else now.
 *
 * The old name was the bug: hardcoded to Sepolia, so the button under a failed launch offered to
 * move the user to a test network regardless of which chain the app was pointed at.
 */
export const switchToSepolia = switchToActiveChain

export function walletClient(account: Address): WalletClient {
  const p = getProvider()
  if (!p) throw new Error('No wallet found.')
  return createWalletClient({ account, chain: activeNetwork().chain, transport: custom(p) })
}

export function shortAccount(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`
}

export function explorerTx(hash: string): string {
  return `${activeNetwork().explorer}/tx/${hash}`
}

export function explorerAddress(a: string): string {
  return `${activeNetwork().explorer}/address/${a}`
}
