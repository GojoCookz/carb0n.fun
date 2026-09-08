import type { Address } from 'viem'
import { activeClient, activeDeployment } from './chain'
import { activeNetwork } from './activeNetwork'
import { walletClient } from './wallet'

/**
 * Reads and claims from `ReferralVault`.
 *
 * **The Rewards page has been describing this as unbuilt since before it was built.** Its
 * docstring said "our fee has no platform wedge to pay referrals out of", which stopped being true
 * when `FeeHook` gained `platformShareBps` and a `platformRecipient`. The vault has been deployed
 * and holding a tier schedule while the page told visitors the feature was still theoretical.
 *
 * What the contract actually gives us:
 *
 *   `referrerOf(user)`          who referred an address, or the zero address
 *   `owed(recipient, currency)` claimable now, per currency
 *   `earned(recipient, currency)` lifetime, so a zero balance can be shown as "paid out" rather
 *                                 than "never earned" - two very different things to a user
 *   `tiers()`                   the bps schedule, read rather than hardcoded in the copy
 *   `claim(currency)`           pull, per currency
 *
 * **Balances are per CURRENCY, not a single number**, because a referral is paid in whatever the
 * trade was denominated in. Someone whose network traded four different pairs has four balances and
 * four claims. A UI that shows one figure would be inventing a total that does not exist on-chain.
 */
export const REFERRAL_VAULT_ABI = [
  {
    name: 'referrerOf',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'user', type: 'address' }],
    outputs: [{ type: 'address' }],
  },
  {
    name: 'owed',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'recipient', type: 'address' },
      { name: 'currency', type: 'address' },
    ],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'earned',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'recipient', type: 'address' },
      { name: 'currency', type: 'address' },
    ],
    outputs: [{ type: 'uint256' }],
  },
  { name: 'tiers', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint16[]' }] },
  {
    name: 'claim',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'currency', type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
] as const

export type ReferralBalance = {
  symbol: string
  currency: Address
  decimals: number
  owed: bigint
  earned: bigint
}

export type ReferralState = {
  vault: Address | null
  tiers: number[]
  referrer: Address | null
  balances: ReferralBalance[]
  /** True when the network has a vault but this wallet has never earned anything at all. */
  neverEarned: boolean
}

/**
 * Reads every approved currency's balance for one wallet.
 *
 * **One multicall over the network's approved pairs**, rather than a subgraph or an indexer: this
 * repo has neither, and inventing a total from anything other than the chain is exactly what the
 * rest of the app refuses to do. It is bounded by the size of the pair allowlist - thirty on
 * Robinhood Chain - and every entry it returns is a number the contract agrees with.
 */
export async function readReferralState(account: Address | null): Promise<ReferralState> {
  const dep = activeDeployment()
  const vault = (dep.referralVault as Address | null) ?? null
  if (!vault) return { vault: null, tiers: [], referrer: null, balances: [], neverEarned: true }

  const client = activeClient()
  const pairs = dep.pairs

  const tiersRaw = await client
    .readContract({ address: vault, abi: REFERRAL_VAULT_ABI, functionName: 'tiers' })
    .catch(() => [] as readonly number[])
  const tiers = [...tiersRaw].map(Number)

  if (!account) {
    return { vault, tiers, referrer: null, balances: [], neverEarned: true }
  }

  const referrerRaw = await client
    .readContract({
      address: vault,
      abi: REFERRAL_VAULT_ABI,
      functionName: 'referrerOf',
      args: [account],
    })
    .catch(() => null)
  const referrer =
    referrerRaw && referrerRaw !== '0x0000000000000000000000000000000000000000'
      ? (referrerRaw as Address)
      : null

  // `allowFailure` so one bad token cannot blank the whole page. A currency that reverts is simply
  // absent rather than rendered as a zero, which would be a claim we cannot support.
  const results = await client.multicall({
    allowFailure: true,
    contracts: pairs.flatMap((p) => [
      {
        address: vault,
        abi: REFERRAL_VAULT_ABI,
        functionName: 'owed' as const,
        args: [account, p.address as Address] as const,
      },
      {
        address: vault,
        abi: REFERRAL_VAULT_ABI,
        functionName: 'earned' as const,
        args: [account, p.address as Address] as const,
      },
    ]),
  })

  const balances: ReferralBalance[] = []
  pairs.forEach((p, i) => {
    const owedR = results[i * 2]
    const earnedR = results[i * 2 + 1]
    const owed = owedR?.status === 'success' ? (owedR.result as bigint) : 0n
    const earned = earnedR?.status === 'success' ? (earnedR.result as bigint) : 0n
    // Only currencies with history are worth a row. Thirty zeroes is noise, not information.
    if (owed > 0n || earned > 0n) {
      balances.push({ symbol: p.symbol, currency: p.address as Address, decimals: p.decimals, owed, earned })
    }
  })

  return { vault, tiers, referrer, balances, neverEarned: balances.length === 0 }
}

/** Claim one currency. Per-currency because that is how the contract stores it. */
export async function claimReferral(account: Address, currency: Address): Promise<`0x${string}`> {
  const vault = activeDeployment().referralVault as Address | null
  if (!vault) throw new Error('No referral vault on this network.')

  const client = activeClient()
  // Simulated first so a revert surfaces as a readable message instead of a wallet-level failure.
  const { request } = await client.simulateContract({
    address: vault,
    abi: REFERRAL_VAULT_ABI,
    functionName: 'claim',
    args: [currency],
    account,
    chain: activeNetwork().chain,
  })
  return walletClient(account).writeContract(request)
}

/**
 * The link a user shares.
 *
 * `?ref=` is the parameter `draft.tsx` already reads on the launch form, so this is the existing
 * mechanism given a front door rather than a second scheme that would have to agree with it.
 */
export function referralLink(account: Address): string {
  const base = typeof window !== 'undefined' ? window.location.origin : 'https://carb0n.fun'
  return `${base}/?ref=${account}`
}
