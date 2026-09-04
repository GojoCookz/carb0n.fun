import type { LaunchDraft } from './launch'
import { holderBps, openingMarketCap } from './launch'
import type { Pair } from './pairs'

/**
 * One row on the board.
 *
 * **Every field names the contract call or event it comes from.** That is the whole point of this
 * type existing rather than the board reading a blob from an indexer: a launchpad that renders a
 * number it cannot trace is how a board ends up quoting a price nobody can reproduce, and a board
 * is the single most tempting place to put invented data — an empty grid looks like a broken
 * product and a full one looks like a busy market.
 *
 * Nullable fields are nullable on purpose. `marketCapUsd` is null for the fifteen pair currencies
 * with no USD feed on L1; `address` is null before a launch exists. The card renders `—` and says
 * why. It never renders a confident zero.
 */
export type LaunchListing = {
  /** `Launcher.launches[i].token`. Null only for an unlaunched draft. */
  address: `0x${string}` | null
  name: string
  symbol: string
  /** IPFS CID from `LaunchToken.metadata.imageCid`. */
  imageCid: string
  /** `LaunchToken.metadata.bannerCid`. Empty is normal — the card draws a fallback. */
  bannerCid: string
  /** The pair currency, resolved through `PairRegistry`. */
  pair: Pair

  /**
   * The pair address **as it exists on the chain this launch is actually on**.
   *
   * Not the same thing as `pair.address`, and conflating them builds a pool key for a pool that
   * does not exist. `pair` is the DISPLAY identity resolved from the mainnet roster — a Sepolia
   * launch against the tWETH stand-in shows WETH's name, icon, liquidity and risk flags, which is
   * what a reader wants. But its `address` is then mainnet WETH, and quoting or swapping against
   * that on Sepolia reverts with `PoolNotInitialized` on a pool that is plainly trading.
   *
   * Null only for a draft, which has no chain yet.
   */
  chainPair: `0x${string}` | null

  /** `Launcher.launches[i].launchedAt`, unix seconds. Null for a draft. */
  launchedAt: number | null

  /** `FeeHook.marketCapOf(poolId)` — in PAIR-CURRENCY units. Spot, manipulable, display only. */
  marketCapPair: number
  /** Derived off-chain from a named Chainlink feed. Null when no feed exists on L1. */
  marketCapUsd: number | null
  /** `FeeHook.graduation(poolId).threshold` — pair units. */
  thresholdPair: number
  /** The market cap the pool opened at. Equals the creator's seed, by construction. */
  openingPair: number
  /** `FeeHook.graduation(poolId).graduated` — the one-way latch. */
  graduated: boolean

  /**
   * Basis points of every BUY that actually REACH holders, from `FeeHook.PoolConfigured`.
   *
   * **Never read from `PoolKey.fee`**, which is zero on every pool here because the hook charges
   * instead of the pool. An indexer reading the pool reports 0% and is wrong every time.
   *
   * This is net of the burn wedge and the creator's cut, because those are both spent before
   * `_routeFee` divides anything. Quoting the headline rate here would overstate what a holder
   * receives on any pool that burns.
   */
  holderFeeBps: number

  /** `FeeHook.PoolConfigured.feeBps` — the headline rate charged on a buy, before any split. */
  buyFeeBps: number
  /** `FeeHook.PoolConfigured.sellFeeBps`. Zero on most launches; sells are free by default. */
  sellFeeBps: number
  /** `FeeHook.PoolConfigured.burnBps` — share of each swept fee spent buying back and burning. */
  burnBps: number

  /** `Launcher.vaultOf(token)` — null when the creator took their opening buy in the clear. */
  vaultAddress: `0x${string}` | null
  /** Seconds the creator's opening buy vests over. Zero when there is no vault. */
  vestDuration: number

  /** `Distributor.totalDistributed` — pair units paid out since the pool opened. */
  paidToHoldersPair: number | null

  /** True when this is the visitor's own unlaunched configuration, not a real listing. */
  isDraft: boolean
}

/**
 * Render the visitor's own draft through the real card.
 *
 * This is their data, not invented data, and the card marks it as a draft in a way that cannot be
 * missed. It exists because a board with nothing on it teaches nobody what the board is for, and
 * the alternative — mock listings — is the exact failure this project bans.
 */
export function draftToListing(draft: LaunchDraft, pair: Pair, marketCapUsd: number | null): LaunchListing {
  const opening = openingMarketCap(draft)
  return {
    address: null,
    // A draft is not on a chain yet, so there is no real pair address to trade against.
    chainPair: null,
    name: draft.name.trim() || 'Untitled',
    symbol: draft.symbol.trim() || '—',
    imageCid: draft.imageCid.trim(),
    bannerCid: draft.bannerCid.trim(),
    pair,
    launchedAt: null,
    marketCapPair: opening,
    marketCapUsd,
    thresholdPair: draft.graduationThreshold,
    openingPair: opening,
    graduated: false,
    holderFeeBps: holderBps(draft),
    buyFeeBps: draft.feeBps,
    sellFeeBps: draft.sellFeeBps,
    burnBps: draft.burnBps,
    // A draft has no deployed vault. The lock is still shown, because the schedule is written in
    // the launch transaction itself — it is a property of the configuration, not of the address.
    vaultAddress: null,
    vestDuration: draft.vestDuration,
    paidToHoldersPair: null,
    isDraft: true,
  }
}

/** Compact relative age, the way a launchpad reads it. */
export function ageLabel(launchedAt: number | null): string {
  if (launchedAt === null) return 'draft'
  const secs = Math.max(0, Math.floor(Date.now() / 1000) - launchedAt)
  if (secs < 60) return `${secs}s`
  if (secs < 3600) return `${Math.floor(secs / 60)}m`
  if (secs < 86_400) return `${Math.floor(secs / 3600)}h`
  return `${Math.floor(secs / 86_400)}d`
}
