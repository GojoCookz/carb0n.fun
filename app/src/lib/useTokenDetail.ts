/**
 * Everything the token page shows that is not already on the board card.
 *
 * **Every field is a chain read and names the call it came from.** Nothing here is derived from an
 * indexer, because there isn't one, and nothing is estimated. A field that cannot be read is
 * `null` and the UI renders an absence rather than a plausible zero.
 */
import { useEffect, useState } from 'react'
import { parseAbi, keccak256, encodeAbiParameters, type Address } from 'viem'
import { activeClient, activeDeployment } from './chain'
import { poolKeyFor } from './tradeTx'

const TOKEN_ABI = parseAbi([
  'function distributor() view returns (address)',
  'function totalSupply() view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
])

const DIST_ABI = parseAbi([
  'function payoutToken() view returns (address)',
  'function rewardToken() view returns (address)',
  'function totalDistributed() view returns (uint256)',
  'function totalWithdrawn() view returns (uint256)',
  'function pendingPayouts() view returns (uint256)',
  'function totalShares() view returns (uint256)',
  'function shareOf(address) view returns (uint256)',
  'function withdrawableOf(address) view returns (uint256)',
  'function withdrawnOf(address) view returns (uint256)',
  'function queueLength() view returns (uint256)',
  'function queueAt(uint256) view returns (address)',
  'function cursor() view returns (uint256)',
  'function streamFinish() view returns (uint64)',
  'function STREAM_WINDOW() view returns (uint64)',
])

const HOOK_ABI = parseAbi([
  'function totalFeesTaken(bytes32) view returns (uint256)',
  'function pendingFees(bytes32) view returns (uint256)',
  'function pendingTokenFees(bytes32) view returns (uint256)',
  'function totalBurned(bytes32) view returns (uint256)',
  // Field order is LOAD-BEARING and matches `FeeHook.PoolConfig` exactly. Solidity returns a
  // struct positionally, so a wrong slot does not fail - it reads `feeBps` as `creatorBps`.
  'function poolConfig(bytes32) view returns (address distributor, address pairCurrency, uint16 feeBps, address creator, uint16 creatorBps, bool configured, uint16 sellFeeBps, uint16 burnBps, uint16 platformShareBps, address rewardCurrency)',
])

const POOL_KEY_PARAM = [
  {
    type: 'tuple',
    components: [
      { name: 'currency0', type: 'address' },
      { name: 'currency1', type: 'address' },
      { name: 'fee', type: 'uint24' },
      { name: 'tickSpacing', type: 'int24' },
      { name: 'hooks', type: 'address' },
    ],
  },
] as const

/** v4's `PoolId` is `keccak256(abi.encode(key))`; every field is static so this is exact. */
export function poolIdOf(token: Address, pair: Address): `0x${string}` {
  const { key } = poolKeyFor(token, pair)
  return keccak256(encodeAbiParameters(POOL_KEY_PARAM, [key]))
}

/**
 * `null` means THE CHAIN COULD NOT ANSWER, and the UI must say so rather than print a zero.
 *
 * That is not hypothetical here: the live Sepolia deployment predates several additions to
 * `Distributor`, so `streamFinish` reverts against it. A panel that rendered that as `0` would be
 * telling the reader "nothing is vesting" when the truth is "this build cannot tell".
 */
export type DividendState = {
  distributor: Address
  /** What holders are paid IN. Equals the pair currency unless a reward currency was set. */
  payoutToken: Address | null
  /** Set only when the launch chose a different reward asset. */
  rewardToken: Address | null
  /** `Distributor.totalDistributed` — pair units credited to holders since launch. */
  totalDistributed: bigint | null
  /** Armed by a sweep but not yet vested. Money is instant; entitlement streams over 24h. */
  pendingPayouts: bigint | null
  /** This wallet's claimable balance right now. Zero in the block a distribution lands. */
  waiting: bigint | null
  /** This wallet's lifetime withdrawals. */
  received: bigint | null
  /** This wallet's share register entry, and the denominator it is divided by. */
  shares: bigint | null
  totalShares: bigint | null
  /** Push-queue position. `null` when this wallet is not enqueued at all. */
  queuePosition: number | null
  queueLength: number
  cursor: number
  /** True when the scan hit its bound before finding the wallet, so position is unknown. */
  queueScanTruncated: boolean
  /** Unix seconds the current stream finishes vesting. `null` when the getter is unavailable. */
  streamFinish: number | null
}

export type FeeState = {
  /** `FeeHook.totalFeesTaken(poolId)` — pair-currency fees charged over all time. */
  totalFeesTaken: bigint | null
  /** Charged but not yet swept, held as ERC-6909 claims. */
  pendingFees: bigint | null
  /** Launch-token fees from sells, awaiting conversion on a manual sweep. */
  pendingTokenFees: bigint | null
  /** Launch tokens bought back and sent to the dead address. */
  totalBurned: bigint | null

  /**
   * The rates the pool was actually CONFIGURED with, read from `FeeHook.poolConfig`.
   *
   * **`useLaunches` hardcodes every one of these to zero** — it never reads the hook — so the
   * board's listing reports a 0% fee for a pool that demonstrably charges 3%. These are the real
   * ones and anything rendering a rate must use them.
   */
  feeBps: number | null
  sellFeeBps: number | null
  burnBps: number | null
  creatorBps: number | null
  platformShareBps: number | null
  creator: Address | null
}

export type TokenDetail =
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'ready'; dividends: DividendState; fees: FeeState; poolId: `0x${string}` }

/** How far into the push queue we are willing to scan before giving up and saying so. */
const QUEUE_SCAN_LIMIT = 400

export function useTokenDetail(
  token: Address | null,
  pair: Address | null,
  account: Address | null,
  /**
   * Bump to force a refetch.
   *
   * **Without this, nothing on the page changed after a claim or a sweep.** The caller already
   * incremented a nonce and used it as a React `key`, which remounts the subtree but re-runs
   * nothing - the hook's effect was keyed on [token, pair, account], none of which change when a
   * transaction lands. A user had to reload the page to see money they had just moved, and
   * reported exactly that.
   */
  nonce = 0,
): TokenDetail {
  const [state, setState] = useState<TokenDetail>({ kind: 'loading' })

  useEffect(() => {
    let live = true
    const feeHook = activeDeployment().feeHook as Address | null
    if (!token || !pair || !feeHook) {
      setState({ kind: 'error', message: 'Nothing deployed to read from on this network.' })
      return
    }

    ;(async () => {
      try {
        const poolId = poolIdOf(token, pair)
        const distributor = await activeClient().readContract({
          address: token,
          abi: TOKEN_ABI,
          functionName: 'distributor',
        })

        const d = { address: distributor, abi: DIST_ABI } as const
        const h = { address: feeHook, abi: HOOK_ABI } as const
        const who = account ?? '0x0000000000000000000000000000000000000000'

        // **`allowFailure: true` on purpose.** The Sepolia deployment predates several additions
        // to `Distributor` — `streamFinish` is not on that bytecode and reverts. One missing
        // getter must not blank the whole panel, and a field that cannot be read has to arrive
        // here as `null` so the UI can render an absence instead of a confident zero.
        const reads = await activeClient().multicall({
          allowFailure: true,
          contracts: [
            { ...d, functionName: 'payoutToken' },
            { ...d, functionName: 'rewardToken' },
            { ...d, functionName: 'totalDistributed' },
            { ...d, functionName: 'pendingPayouts' },
            { ...d, functionName: 'totalShares' },
            { ...d, functionName: 'queueLength' },
            { ...d, functionName: 'cursor' },
            { ...d, functionName: 'streamFinish' },
            { ...d, functionName: 'withdrawableOf', args: [who] },
            { ...d, functionName: 'withdrawnOf', args: [who] },
            { ...d, functionName: 'shareOf', args: [who] },
            { ...h, functionName: 'totalFeesTaken', args: [poolId] },
            { ...h, functionName: 'pendingFees', args: [poolId] },
            { ...h, functionName: 'pendingTokenFees', args: [poolId] },
            { ...h, functionName: 'totalBurned', args: [poolId] },
            { ...h, functionName: 'poolConfig', args: [poolId] },
          ],
        })

        const big = (i: number): bigint | null =>
          reads[i].status === 'success' ? (reads[i].result as bigint) : null
        const addr = (i: number): Address | null =>
          reads[i].status === 'success' ? (reads[i].result as Address) : null

        const queueLength = Number(big(5) ?? 0n)
        const cursor = Number(big(6) ?? 0n)

        // **The queue index is `internal`, so it has to be found by scanning.** Bounded, and the
        // UI says "unknown" rather than guessing when the bound is hit — a made-up queue position
        // is worse than no queue position.
        let queuePosition: number | null = null
        let queueScanTruncated = false
        if (account && queueLength > 0) {
          const scanTo = Math.min(queueLength, QUEUE_SCAN_LIMIT)
          const entries = (await activeClient().multicall({
            allowFailure: false,
            contracts: Array.from({ length: scanTo }, (_, i) => ({
              ...d,
              functionName: 'queueAt' as const,
              args: [BigInt(i)] as const,
            })),
          })) as Address[]
          const idx = entries.findIndex((a) => a.toLowerCase() === account.toLowerCase())
          if (idx >= 0) queuePosition = idx
          else if (scanTo < queueLength) queueScanTruncated = true
        }

        if (!live) return
        const rewardToken = addr(1)
        setState({
          kind: 'ready',
          poolId,
          dividends: {
            distributor,
            payoutToken: addr(0),
            rewardToken:
              rewardToken === null || rewardToken === '0x0000000000000000000000000000000000000000'
                ? null
                : rewardToken,
            totalDistributed: big(2),
            pendingPayouts: big(3),
            totalShares: big(4),
            queueLength,
            cursor,
            streamFinish: big(7) === null ? null : Number(big(7)),
            waiting: big(8),
            received: big(9),
            shares: big(10),
            queuePosition,
            queueScanTruncated,
          },
          fees: {
            totalFeesTaken: big(11),
            pendingFees: big(12),
            pendingTokenFees: big(13),
            totalBurned: big(14),
            ...(reads[15].status === 'success'
              ? (() => {
                  const c = reads[15].result as readonly unknown[]
                  return {
                    feeBps: Number(c[2]),
                    creator: c[3] as Address,
                    creatorBps: Number(c[4]),
                    sellFeeBps: Number(c[6]),
                    burnBps: Number(c[7]),
                    platformShareBps: Number(c[8]),
                  }
                })()
              : {
                  feeBps: null,
                  creator: null,
                  creatorBps: null,
                  sellFeeBps: null,
                  burnBps: null,
                  platformShareBps: null,
                }),
          },
        })
      } catch (e) {
        if (live) setState({ kind: 'error', message: (e as Error).message.split('\n')[0] })
      }
    })()

    return () => {
      live = false
    }
  }, [token, pair, account, nonce])

  return state
}
