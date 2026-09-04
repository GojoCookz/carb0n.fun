/**
 * Wallet connection, using viem's `custom` transport over the injected EIP-1193 provider.
 *
 * **No wallet library.** wagmi/RainbowKit/ConnectKit each pull in a connector registry, a query
 * client and a theme layer to solve a problem this app does not have: it targets one chain and
 * sends at most two transactions. viem is already a dependency for reads, and `custom(provider)`
 * is the whole integration.
 *
 * Everything here REPORTS rather than throws where the user can act on it, because a rejected
 * signature is a normal outcome, not an error state — a wallet popup the user closes must leave
 * the form exactly as it was.
 */
import { createWalletClient, custom, type Address, type WalletClient } from 'viem'
import { sepolia } from 'viem/chains'

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

export function getProvider(): Eip1193 | null {
  return typeof window !== 'undefined' && window.ethereum ? window.ethereum : null
}

export function hasWallet(): boolean {
  return getProvider() !== null
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

export async function connect(): Promise<Address[]> {
  const p = getProvider()
  if (!p) throw new Error('No wallet found.')
  const accounts = (await p.request({ method: 'eth_requestAccounts' })) as Address[]
  return accounts
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
export async function switchToSepolia(): Promise<void> {
  const p = getProvider()
  if (!p) throw new Error('No wallet found.')
  const hexId = `0x${sepolia.id.toString(16)}`
  try {
    await p.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: hexId }] })
  } catch (e) {
    if ((e as { code?: number }).code !== 4902) throw e
    await p.request({
      method: 'wallet_addEthereumChain',
      params: [
        {
          chainId: hexId,
          chainName: 'Sepolia',
          nativeCurrency: { name: 'Sepolia Ether', symbol: 'ETH', decimals: 18 },
          rpcUrls: ['https://ethereum-sepolia-rpc.publicnode.com'],
          blockExplorerUrls: ['https://sepolia.etherscan.io'],
        },
      ],
    })
  }
}

export function walletClient(account: Address): WalletClient {
  const p = getProvider()
  if (!p) throw new Error('No wallet found.')
  return createWalletClient({ account, chain: sepolia, transport: custom(p) })
}

export function shortAccount(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`
}

export function explorerTx(hash: string): string {
  return `https://sepolia.etherscan.io/tx/${hash}`
}

export function explorerAddress(a: string): string {
  return `https://sepolia.etherscan.io/address/${a}`
}
