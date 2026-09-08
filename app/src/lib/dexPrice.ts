import { useEffect, useState } from 'react'
import { activeNetworkId } from './activeNetwork'

/**
 * USD price for a pair currency, from DexScreener.
 *
 * ## Why a price aggregator and not an oracle
 *
 * `usePairUsd` reads Chainlink, which is the right answer where a feed exists. **There is no
 * Chainlink on Robinhood Chain** - every pair was admitted with `approvePairWithoutOracle` and
 * `Addresses.hasUsdFeed(4663)` is false. So every figure on a Robinhood token page has been
 * denominated in the pair currency, and the page has said so.
 *
 * That is honest and it is also unreadable. A market cap of "15.58K CASHCAT" cannot be compared
 * against anything, and every other tool a trader has open says `$2,959`. Being the only screen
 * showing a different unit reads as being wrong, even when the number is right.
 *
 * ## What this is and is not
 *
 * It is a THIRD-PARTY QUOTE, not an oracle reading, and the UI labels it as such wherever it
 * appears. It is not used to size a transaction, quote a trade or settle a payout - all of those
 * read the pool directly and stay denominated in the pair. It exists so a human can tell whether
 * a number is big or small.
 *
 * A failed or missing quote returns `null` and the caller renders the pair-denominated figure
 * alone. It must never fall back to a guessed price.
 */

/** DexScreener's chain slug is not our network id. */
const DEX_CHAIN: Record<string, string> = {
  mainnet: 'ethereum',
  robinhood: 'robinhood',
  sepolia: '',
}

type Cached = { price: number; at: number }
const cache = new Map<string, Cached>()
const TTL_MS = 60_000

export async function fetchDexUsd(address: string, networkId: string): Promise<number | null> {
  const chain = DEX_CHAIN[networkId]
  if (!chain) return null

  const key = `${chain}:${address.toLowerCase()}`
  const hit = cache.get(key)
  if (hit && Date.now() - hit.at < TTL_MS) return hit.price

  try {
    const res = await fetch(`https://api.dexscreener.com/latest/dex/tokens/${address}`, {
      signal: AbortSignal.timeout(8000),
    })
    if (!res.ok) return null
    const body = (await res.json()) as {
      pairs?: Array<{
        chainId?: string
        priceUsd?: string
        liquidity?: { usd?: number }
      }>
    }

    // Take the DEEPEST pool on the right chain. A thin pool can print any price it likes, and
    // picking the first result would make the figure jump between refreshes.
    const best = (body.pairs ?? [])
      .filter((p) => p.chainId === chain && p.priceUsd)
      .sort((a, b) => (b.liquidity?.usd ?? 0) - (a.liquidity?.usd ?? 0))[0]

    const price = best ? Number(best.priceUsd) : NaN
    if (!Number.isFinite(price) || price <= 0) return null

    cache.set(key, { price, at: Date.now() })
    return price
  } catch {
    return null
  }
}

/** The pair's USD price, or null when there is no quote. Never a guess. */
export function useDexUsd(address: string | null | undefined): number | null {
  const [price, setPrice] = useState<number | null>(null)

  useEffect(() => {
    if (!address) {
      setPrice(null)
      return
    }
    let live = true
    void fetchDexUsd(address, activeNetworkId()).then((p) => {
      if (live) setPrice(p)
    })
    return () => {
      live = false
    }
  }, [address])

  return price
}
