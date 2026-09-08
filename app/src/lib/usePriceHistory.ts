/**
 * Load a pool's swap history for the chart.
 *
 * Kept separate from `useTokenDetail` on purpose: that hook's reads decide what the trade panel
 * says and whether a claim is possible, and a log query that some RPC providers rate-limit or
 * refuse outright must never be able to take those down with it. This one fails to an empty array
 * and the chart draws its own "no trades yet" state.
 */
import { useEffect, useState } from 'react'
import type { Address } from 'viem'
import { activeClient } from './chain'
import { activeNetwork } from './activeNetwork'
import { fetchPriceHistory, fillTimestamps, type PricePoint } from './priceHistory'

export type PriceHistory = {
  points: PricePoint[]
  loading: boolean
  /**
   * Whole tokens in existence.
   *
   * Read from the contract rather than assumed, because supply is a LAUNCH PARAMETER - every
   * token so far happens to be 1e9, and hardcoding that would misprice the first one that is
   * not by whatever factor the creator chose.
   */
  supply: number
}

export function usePriceHistory(
  poolId: `0x${string}` | null,
  token: Address | null,
  pair: Address | null,
  tokenDecimals: number,
  pairDecimals: number,
): PriceHistory {
  const [points, setPoints] = useState<PricePoint[]>([])
  const [supply, setSupply] = useState(0)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!poolId || !token || !pair) {
      setLoading(false)
      return
    }
    let live = true
    setLoading(true)

    void (async () => {
      const net = activeNetwork()
      const client = activeClient()

      // v4 sorts pool currencies by address, so which side the launch token landed on decides
      // whether the pool's price ratio needs inverting. Same comparison the pool key uses.
      const tokenIsCurrency0 = token.toLowerCase() < pair.toLowerCase()

      // Supply is fixed at mint - no mint function, no burn - so one read is enough forever.
      try {
        const raw = await client.readContract({
          address: token,
          abi: [
            {
              name: 'totalSupply',
              type: 'function',
              stateMutability: 'view',
              inputs: [],
              outputs: [{ type: 'uint256' }],
            },
          ] as const,
          functionName: 'totalSupply',
        })
        if (live) setSupply(Number(raw) / 10 ** tokenDecimals)
      } catch {
        // A market cap of zero renders as 0 rather than a wrong number.
      }

      // Bound the range. Scanning from genesis on a chain 57M blocks deep is a request no public
      // RPC will serve, and the pool cannot have traded before it existed anyway.
      const latest = await client.getBlockNumber().catch(() => null)
      const fromBlock = latest !== null && latest > 400_000n ? latest - 400_000n : 0n

      const result = await fetchPriceHistory({
        client,
        poolManager: net.poolManager as Address,
        poolId,
        fromBlock,
        tokenIsCurrency0,
        tokenDecimals,
        pairDecimals,
      })

      if (!live) return
      // Show the line immediately, then upgrade to real timestamps so candles can be bucketed.
      setPoints(result)
      setLoading(false)

      const withTime = await fillTimestamps(client, result)
      if (live) setPoints(withTime)
    })()

    return () => {
      live = false
    }
  }, [poolId, token, pair, tokenDecimals, pairDecimals])

  return { points, loading, supply }
}
