import { useEffect, useState } from 'react'
import type { Address } from 'viem'
import { activeClient, activeDeployment } from './chain'
import { activePairs } from './activeNetwork'

/**
 * Platform revenue owed to the treasury, and the means to withdraw it.
 *
 * ## Where the money comes from
 *
 * Every sweep splits its fee four ways - a bounty to whoever called it, the platform's cut, the
 * creator's cut, and the holders' cut. The platform's cut goes to `ReferralVault`, which pays each
 * referrer tier in turn and credits **everything left over, including every tier nobody occupies**,
 * to `treasury`.
 *
 * ## Why it is not deposited automatically
 *
 * `claim()` pays `msg.sender`, so the treasury has to ask. That looks like friction and it is
 * deliberate: **a push on every sweep would let the recipient's behaviour fail the sweep**, and
 * sweeps are permissionless, so anyone could brick a pool's payouts by making the platform
 * transfer revert. Crediting and letting the owner withdraw cannot be griefed.
 *
 * ## The address is READ, never hardcoded
 *
 * `vault.treasury()` is the authority. Writing the address into the app would create a second
 * source of truth that silently disagrees with the contract the day either changes.
 */

export const VAULT_ABI = [
  {
    name: 'treasury',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'address' }],
  },
  {
    name: 'owed',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ type: 'address' }, { type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'earned',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ type: 'address' }, { type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'claim',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'currency', type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
] as const

export type RevenueLine = {
  symbol: string
  address: Address
  decimals: number
  owed: bigint
  earned: bigint
}

export type TreasuryState =
  | { kind: 'loading' }
  /** Connected, but not the treasury. The panel renders nothing at all. */
  | { kind: 'not-treasury' }
  | { kind: 'none' }
  | { kind: 'ready'; treasury: Address; lines: RevenueLine[]; total: number }

/**
 * Is this wallet the treasury, and what is it owed?
 *
 * Reads every approved currency in one multicall. `allowFailure` because a pair that has never
 * earned anything still answers zero, but a broken token should not take the whole panel down.
 */
export function useTreasury(account: Address | null): TreasuryState {
  const [state, setState] = useState<TreasuryState>({ kind: 'loading' })

  useEffect(() => {
    const vault = activeDeployment().referralVault as Address | null
    if (!account || !vault) {
      setState({ kind: 'none' })
      return
    }

    let live = true
    void (async () => {
      const client = activeClient()

      let treasury: Address
      try {
        treasury = (await client.readContract({
          address: vault,
          abi: VAULT_ABI,
          functionName: 'treasury',
        })) as Address
      } catch {
        if (live) setState({ kind: 'none' })
        return
      }

      // The gate. Case-insensitive because wallets return mixed checksums.
      if (treasury.toLowerCase() !== account.toLowerCase()) {
        if (live) setState({ kind: 'not-treasury' })
        return
      }

      const pairs = activePairs()
      const calls = pairs.flatMap((p) => [
        {
          address: vault,
          abi: VAULT_ABI,
          functionName: 'owed' as const,
          args: [treasury, p.address as Address] as const,
        },
        {
          address: vault,
          abi: VAULT_ABI,
          functionName: 'earned' as const,
          args: [treasury, p.address as Address] as const,
        },
      ])

      let results: Array<{ status: string; result?: unknown }> = []
      try {
        results = (await client.multicall({ contracts: calls, allowFailure: true })) as typeof results
      } catch {
        if (live) setState({ kind: 'none' })
        return
      }

      const lines: RevenueLine[] = []
      pairs.forEach((p, i) => {
        const o = results[i * 2]
        const e = results[i * 2 + 1]
        const owed = o?.status === 'success' ? (o.result as bigint) : 0n
        const earnedV = e?.status === 'success' ? (e.result as bigint) : 0n
        // Show anything that has EVER earned, not just what is currently owed - a zero balance
        // after a claim is a fact worth seeing, not an empty list.
        if (owed > 0n || earnedV > 0n) {
          lines.push({
            symbol: p.symbol,
            address: p.address as Address,
            decimals: p.decimals,
            owed,
            earned: earnedV,
          })
        }
      })

      lines.sort((a, b) => (b.owed > a.owed ? 1 : b.owed < a.owed ? -1 : 0))

      if (live) {
        setState({
          kind: 'ready',
          treasury,
          lines,
          total: lines.reduce((n, l) => n + Number(l.owed) / 10 ** l.decimals, 0),
        })
      }
    })()

    return () => {
      live = false
    }
  }, [account])

  return state
}
