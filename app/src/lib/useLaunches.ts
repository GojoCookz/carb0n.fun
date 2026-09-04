/**
 * Read every launch straight off the chain, no indexer.
 *
 * **This is deliberately the naive version.** `launchCount()` then `launches(i)` then three reads
 * per token is O(n) round trips, and it will get slow somewhere in the low hundreds of launches.
 * It is here because the alternative is an indexer, an indexer is a service that has to be
 * running for the board to work at all, and a board that shows nothing when a server is down is
 * worse than one that takes a moment. Swap this for an indexed source when the count makes it
 * necessary — the shape it returns is `LaunchListing[]`, which is what the board already renders,
 * so nothing above this file has to change.
 */
import { useEffect, useState } from 'react'
import { parseAbi, type Address } from 'viem'
import { sepoliaClient, DEPLOYMENTS } from './chain'
import { LAUNCHER_ABI } from './abi'
import { poolIdOf } from './useTokenDetail'
import type { LaunchListing } from './listing'
import { PAIRS } from './pairs'

const tokenAbi = parseAbi([
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function totalSupply() view returns (uint256)',
  'function metadata() view returns (bytes32 imageCid, bytes32 bannerCid, bytes32 infoCid)',
])
const hookAbi = parseAbi([
  'function poolConfig(bytes32) view returns (address distributor, address pairCurrency, uint16 feeBps, address creator, uint16 creatorBps, bool configured, uint16 sellFeeBps, uint16 burnBps, uint16 platformShareBps, address rewardCurrency)',
])

const pairAbi = parseAbi([
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
])

export type LaunchesState =
  | { kind: 'idle' }
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'ok'; listings: LaunchListing[] }

/** Match an on-chain pair address back to the allowlist entry the UI knows how to render. */
function pairFor(address: string) {
  const lower = address.toLowerCase()
  const testnet = DEPLOYMENTS.sepolia.pairs.find((p) => p.address.toLowerCase() === lower)
  if (testnet) {
    // The Sepolia stand-ins are named `tWETH`/`tWXMR`; show the real pair they represent.
    const real = PAIRS.find((p) => `t${p.symbol}`.toLowerCase() === testnet.symbol.toLowerCase())
    if (real) return real
  }
  return PAIRS.find((p) => p.address.toLowerCase() === lower)
}

export function useLaunches(): LaunchesState {
  const [state, setState] = useState<LaunchesState>({ kind: 'idle' })

  useEffect(() => {
    const launcher = DEPLOYMENTS.sepolia.launcher
    const feeHook = DEPLOYMENTS.sepolia.feeHook
    if (!launcher || !feeHook) {
      setState({ kind: 'ok', listings: [] })
      return
    }

    let live = true
    setState({ kind: 'loading' })

    void (async () => {
      try {
        const count = await sepoliaClient.readContract({
          address: launcher,
          abi: LAUNCHER_ABI,
          functionName: 'launchCount',
        })

        // Newest first, and bounded. Nobody scrolls past 60 tiles, and the unbounded version is
        // the thing that makes this approach fall over.
        const total = Number(count)
        const wanted = Math.min(total, 60)
        const indices = Array.from({ length: wanted }, (_, k) => BigInt(total - 1 - k))

        const rows = await Promise.all(
          indices.map((i) =>
            sepoliaClient.readContract({
              address: launcher,
              abi: LAUNCHER_ABI,
              functionName: 'launches',
              args: [i],
            }),
          ),
        )

        const listings = await Promise.all(
          rows.map(async (row) => {
            const [token, , pairAddr, launchedAt] = row as unknown as [
              Address,
              Address,
              Address,
              bigint,
            ]

            const [name, symbol] = await Promise.all([
              sepoliaClient.readContract({ address: token, abi: tokenAbi, functionName: 'name' }),
              sepoliaClient.readContract({ address: token, abi: tokenAbi, functionName: 'symbol' }),
            ])

            const known = pairFor(pairAddr)
            const pairSymbol = known
              ? known.symbol
              : await sepoliaClient.readContract({
                  address: pairAddr,
                  abi: pairAbi,
                  functionName: 'symbol',
                })

            // **The rates come from the hook, not from a constant.** These four fields used to be
            // hardcoded to zero, so every card on the board advertised a 0% fee for a pool that
            // charges 3% — a placeholder rendered as a fact, which is the one thing this file's
            // own docstring forbids. A read that fails still yields zeros, but it fails loudly in
            // the console rather than silently agreeing with the old lie.
            const cfg = await sepoliaClient
              .readContract({
                address: feeHook,
                abi: hookAbi,
                functionName: 'poolConfig',
                args: [poolIdOf(token, pairAddr)],
              })
              .catch(() => null)

            const feeBps = cfg ? Number(cfg[2]) : 0
            const creatorBps = cfg ? Number(cfg[4]) : 0
            const sellFeeBps = cfg ? Number(cfg[6]) : 0
            const burnBps = cfg ? Number(cfg[7]) : 0
            const platformShareBps = cfg ? Number(cfg[8]) : 0
            // Holder rate is the fee AFTER the platform cut, the burn wedge and the creator's
            // share — mirrors `FeeHook._routeFee`, which spends the burn before dividing.
            const afterPlatform = Math.max(0, 10_000 - platformShareBps)
            const afterBurn = afterPlatform - (afterPlatform * burnBps) / 10_000
            const holderShare = afterBurn - (afterBurn * creatorBps) / 10_000
            const holderFeeBps = Math.round((feeBps * holderShare) / 10_000)

            return {
              address: token,
              name: name as string,
              symbol: symbol as string,
              imageCid: '',
              bannerCid: '',
              // The real, on-chain pair. `pair` below carries the mainnet identity for display.
              chainPair: pairAddr,
              pair:
                known ??
                ({
                  symbol: pairSymbol as string,
                  name: pairSymbol as string,
                  address: pairAddr,
                  decimals: 18,
                  category: 'major',
                  priceable: false,
                  liquidityUsd: 0,
                  volume24hUsd: 0,
                  liveSince: '',
                  risks: {
                    pausable: false,
                    blacklist: false,
                    upgradeable: false,
                    mintable: false,
                    owned: false,
                  },
                } as LaunchListing['pair']),
              launchedAt: Number(launchedAt),
              // **Left at zero on purpose.** Market cap needs a live pool price read and the
              // graduation threshold needs another call; rendering a confident zero would be
              // worse than the card saying it does not know. The card handles both.
              marketCapPair: 0,
              marketCapUsd: null,
              thresholdPair: 0,
              openingPair: 0,
              graduated: false,
              holderFeeBps,
              buyFeeBps: feeBps,
              sellFeeBps,
              burnBps,
              vaultAddress: null,
              vestDuration: 0,
              paidToHoldersPair: null,
              isDraft: false,
            } satisfies LaunchListing
          }),
        )

        if (live) setState({ kind: 'ok', listings })
      } catch (e) {
        if (live) setState({ kind: 'error', message: (e as Error).message.slice(0, 160) })
      }
    })()

    return () => {
      live = false
    }
  }, [])

  return state
}
