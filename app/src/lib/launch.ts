/**
 * The launch configuration, and the derived numbers the UI shows.
 *
 * HARD RULE: every function here mirrors a specific line of the Solidity, and says which.
 * Nothing in this file estimates, models, or invents. If the contract would reject a value,
 * `validate` reports the same reason the contract would revert with.
 *
 * Sources, all in `contracts/src/`:
 *   Launcher.sol      MAX_DEV_BUY_BPS, MIN_MAX_WALLET_BPS, _validate, _openingSqrtPrice
 *   FeeHook.sol       MAX_FEE_BPS, BPS, _routeFee, configureGraduation, _marketCap
 *   LaunchToken.sol   maxWallet, initialize (supply / 1e6 distribution floor)
 */
import type { Pair } from './pairs'

/** FeeHook.BPS / Launcher.BPS */
export const BPS = 10_000
/** FeeHook.MAX_FEE_BPS — 10% is the most any launch may charge. */
export const MAX_FEE_BPS = 1000
/** Launcher.MAX_DEV_BUY_BPS — the creator's opening buy, as a share of the pair seed. */
export const MAX_DEV_BUY_BPS = 1000
/** Launcher.MIN_MAX_WALLET_BPS — below this a cap stops being anti-whale and blocks transfers. */
export const MIN_MAX_WALLET_BPS = 10

/** Every launch opens here. Fixed, not configurable. */
export const OPENING_USD = 3_000
/** Every launch graduates here. Fixed, not configurable. */
export const GRADUATION_USD = 30_000

/**
 * Which door the creator came in through.
 *
 * **Simple is not a subset of advanced with fields hidden — it is a different product.** It makes
 * exactly one decision (the coin) and fixes everything else at values that are already correct.
 * Advanced is where the pair list, the tax, the dividends and the locks live. A form that shows
 * both paths with equal weight has not actually chosen a default, and the default is the thing
 * that decides whether a first-time creator finishes.
 */
export type LaunchMode = 'simple' | 'advanced'

/** Simple mode, fixed. 2% a side, ETH-quoted, everything to the creator, no dividends. */
export const SIMPLE_PRESET = {
  pairSymbol: 'WETH',
  feeBps: 200,
  sellFeeBps: 200,
  burnBps: 0,
  /** 100% of the creator's own cut — the platform's slice is taken before this applies. */
  creatorBps: 10_000,
  maxWalletBps: 0,
  devBuyPairAmount: 0,
  vestDuration: 0,
  vestCliff: 0,
} as const

export type LaunchDraft = {
  mode: LaunchMode
  name: string
  symbol: string
  /** Whole tokens. On chain this is multiplied by 1e18. */
  supply: number
  pairSymbol: string
  /** Whole units of the pair currency seeded as Opening market cap. */
  openingMarketCap: number
  /** Whole units of the pair currency. Market cap at which the launch is signalled as mature. */
  graduationThreshold: number
  /** Charged on BUYS, in the pair currency. */
  feeBps: number
  /**
   * Charged on SELLS, in the launch token, converted to the pair currency on a sweep.
   * Independent of the buy rate. Zero means sells are free.
   */
  sellFeeBps: number
  /** Share of each swept fee that buys the token back from its own pool and burns it. */
  burnBps: number
  creatorBps: number
  maxWalletBps: number
  devBuyPairAmount: number
  /**
   * Seconds the dev buy vests over. ZERO sends it straight to the creator's wallet and keeps the
   * 10% cap; non-zero routes it into a vault and REMOVES the cap.
   */
  vestDuration: number
  /** Seconds before anything unlocks. Must not exceed the duration. */
  vestCliff: number
  /** IPFS CID. Required — `Launcher._validate` reverts `ImageRequired` without it. */
  imageCid: string
  /** IPFS CID for a 1500x500 banner. Optional; a launch with none renders a fallback. */
  bannerCid: string
  /**
   * Where creator fees are paid. Empty means the launching wallet.
   *
   * Separate from the signer on purpose: a team splitter, multisig or cold wallet is a different
   * address from the hot one that signs a launch. Written once at launch, with no setter.
   */
  feeRecipient: string
  /** Who referred this creator. Captured from `?ref=` and never typed by hand. */
  referrer: string
  /**
   * What holders are paid dividends IN. A SYMBOL from the allowlist, empty meaning the pair.
   *
   * The creator picks this. A coin quoted in PEPE does not have to pay PEPE - the pair is what
   * it trades against, not a decision about what its holders earn.
   */
  rewardSymbol: string
}

export const DEFAULT_DRAFT: LaunchDraft = {
  mode: 'simple',
  name: '',
  symbol: '',
  supply: 1_000_000_000,
  // FIXED. Not a preset, not a default - there is no control for either of these and no way to
  // change them. Stored in PAIR units because that is the only denomination the chain has;
  // OPENING_USD / GRADUATION_USD are the numbers, and these are them at the live rate.
  openingMarketCap: 1.25,
  graduationThreshold: 12.5,
  ...SIMPLE_PRESET,
  imageCid: '',
  bannerCid: '',
  feeRecipient: '',
  referrer: '',
  rewardSymbol: '',
}

/** Snap a draft back to the fixed simple-mode values, keeping only what the creator authored. */
export function applySimplePreset(d: LaunchDraft): LaunchDraft {
  return { ...d, ...SIMPLE_PRESET, mode: 'simple' }
}

/** A 0x address, or empty. Anything else is refused rather than sent to a contract. */
export function isAddressish(v: string): boolean {
  return v.trim().length === 0 || /^0x[0-9a-fA-F]{40}$/.test(v.trim())
}

// ---------------------------------------------------------------------------------------------
// Derived numbers
// ---------------------------------------------------------------------------------------------

/**
 * Opening market cap, in pair-currency units.
 *
 * This is a NUMBER THE CREATOR CHOOSES, not a deposit. `Launcher` derives the opening price from
 * it — `p0 = marketCap / supply` — and seeds the whole supply single-sided from that price
 * outward, so the creator supplies no pair currency at all.
 *
 * The realised cap is within one tick-spacing of the number asked for, because a position can
 * only start on a tick boundary and the launcher snaps the opening price to one rather than
 * leaving a gap with no liquidity in it.
 */
export function openingMarketCap(d: LaunchDraft): number {
  return d.openingMarketCap
}

/** Opening price of one token, in pair-currency units. */
export function openingPrice(d: LaunchDraft): number {
  return d.supply > 0 ? d.openingMarketCap / d.supply : 0
}

/** How many times the opening market cap the graduation bar sits at. */
export function graduationMultiple(d: LaunchDraft): number {
  return d.openingMarketCap > 0 ? d.graduationThreshold / d.openingMarketCap : 0
}

/**
 * Progress toward graduation, 0-1, at a given market cap.
 * Mirrors `FeeHook.graduationProgressBps`, including the cap at full.
 */
export function graduationProgress(marketCap: number, threshold: number): number {
  if (threshold <= 0) return 0
  return Math.min(1, marketCap / threshold)
}

/**
 * FeeHook.PLATFORM_VOLUME_BPS — the platform's flat cut, in basis points OF VOLUME.
 *
 * Of volume, not of the fee. A 2% launch and a 9% launch both pay 1%; everything above it is the
 * creator's. It is a constant on the hook with no setter, so it is the same for every launch and
 * cannot be changed after yours exists.
 */
export const PLATFORM_VOLUME_BPS = 100

/**
 * FeeHook._routeFee — the three-way split, in the order the contract performs it.
 *
 * **The platform is taken off the top, and `creatorBps` divides what is LEFT.** That ordering is
 * what makes a 100% creator share legal: it means all of the creator's own cut, not all of the
 * fee. Splitting the headline rate instead would let `creatorBps = 10000` leave nothing to pay
 * the platform with.
 */
export function feeSplit(d: LaunchDraft): {
  platformBps: number
  holdersBps: number
  creatorBps: number
} {
  const platform = Math.min(PLATFORM_VOLUME_BPS, d.feeBps)
  const rest = d.feeBps - platform
  const creator = Math.round((rest * d.creatorBps) / BPS)
  return { platformBps: platform, holdersBps: rest - creator, creatorBps: creator }
}

/** LaunchToken.maxWallet — whole tokens. Zero disables the cap. */
export function maxWalletTokens(d: LaunchDraft): number {
  return d.maxWalletBps === 0 ? 0 : (d.supply * d.maxWalletBps) / BPS
}

/**
 * Launcher._validate — the dev buy ceiling, in pair units.
 *
 * **Infinite when the buy is vested.** The cap and the vault protect buyers from the same thing
 * by different means: the cap limits how much can be dumped, the vault publishes the size and the
 * schedule on chain and forbids ever shortening them.
 */
export function devBuyCap(d: LaunchDraft): number {
  if (d.vestDuration > 0) return Infinity
  return (d.openingMarketCap * MAX_DEV_BUY_BPS) / BPS
}

/**
 * Basis points of every BUY that actually reach holders.
 *
 * Three things come out ahead of them, in the contract's own order: the burn wedge is spent in
 * `unlockCallback`, then `_routeFee` takes the platform's flat cut off the top, then `creatorBps`
 * divides the remainder. Quoting anything earlier in that chain overstates holder income.
 */
export function holderBps(d: LaunchDraft): number {
  const afterBurn = (d.feeBps * (BPS - d.burnBps)) / BPS
  const afterPlatform = Math.max(0, afterBurn - PLATFORM_VOLUME_BPS)
  return (afterPlatform * (BPS - d.creatorBps)) / BPS
}

/**
 * The number BaseStonk leads with, and the strongest thing about this product:
 *
 * > **Dividends are a percentage of trading VOLUME, not a cut of an LP fee.**
 *
 * A token routing 3% of volume to holders on $200k a day delivers roughly $2.2M a year — a very
 * large number relative to the token's own market cap, because volume compounds daily and market
 * cap does not have to.
 *
 * This is arithmetic, not a promise. Volume is the input nobody can guarantee: a token that stops
 * trading stops paying. What the contract guarantees is the PERCENTAGE.
 */
export function annualToHolders(d: LaunchDraft, dailyVolumePair: number): number {
  return (dailyVolumePair * 365 * holderBps(d)) / BPS
}

/**
 * What a holder of `shareOfSupply` (0-1) receives out of that delivery.
 *
 * **Denominated in the pair currency the Distributor actually holds, and split by the SHARE
 * REGISTER — never expressed against market cap.** `Distributor` divides a real balance of pair
 * currency by real balances of the launch token (`_magnifiedPayoutPerShare` over `totalShares`);
 * market cap is a spot price that appears nowhere in that calculation and is manipulable in one
 * transaction. Dividing income by it produces a percentage that describes neither the money in the
 * contract nor anybody's actual entitlement.
 */
export function annualToHolder(
  d: LaunchDraft,
  dailyVolumePair: number,
  shareOfSupply: number,
): number {
  return annualToHolders(d, dailyVolumePair) * shareOfSupply
}

/** Human duration for a vesting schedule. */
export function fmtDuration(seconds: number): string {
  if (seconds === 0) return 'none'
  const days = Math.round(seconds / 86_400)
  if (days >= 365 && days % 365 === 0) return `${days / 365} year${days > 365 ? 's' : ''}`
  return `${days} day${days === 1 ? '' : 's'}`
}

export const VEST_PRESETS = [
  { label: 'None', value: 0 },
  { label: '7d', value: 7 * 86_400 },
  { label: '30d', value: 30 * 86_400 },
  { label: '90d', value: 90 * 86_400 },
  { label: '1y', value: 365 * 86_400 },
]

/**
 * Distributor.minSharesForDistribution — `supply / 1e6`.
 * Below this many tokens in real hands a fee is CARRIED rather than spread, because dividing by
 * dust inflates the per-share accumulator until it overflows and bricks every transfer.
 */
export function distributionFloorTokens(d: LaunchDraft): number {
  return d.supply / 1e6
}

// ---------------------------------------------------------------------------------------------
// Validation — the same rules, in the same order, as the contracts
// ---------------------------------------------------------------------------------------------

export type Issue = { field: keyof LaunchDraft; message: string; revert: string }

export function validate(d: LaunchDraft, pair: Pair | undefined): Issue[] {
  const out: Issue[] = []

  if (d.name.trim().length === 0) {
    out.push({ field: 'name', message: 'Give it a name.', revert: '' })
  }
  if (d.symbol.trim().length < 2) {
    out.push({ field: 'symbol', message: 'At least 2 characters.', revert: '' })
  }
  if (!pair) {
    out.push({ field: 'pairSymbol', message: 'Pick what it trades against.', revert: 'PairNotApproved' })
  }
  if (d.imageCid.trim().length === 0) {
    out.push({
      field: 'imageCid',
      message: 'An image is required. A token with none is unlistable.',
      revert: 'ImageRequired',
    })
  }
  if (d.supply < 1) {
    out.push({ field: 'supply', message: 'At least 1 whole token.', revert: 'SupplyTooLow' })
  }
  if (d.openingMarketCap <= 0) {
    out.push({ field: 'openingMarketCap', message: 'Opening market cap cannot be zero.', revert: 'SeedTooLow' })
  }
  if (d.graduationThreshold <= d.openingMarketCap) {
    out.push({
      field: 'graduationThreshold',
      message: `Must be above the opening market cap (${fmtAmount(d.openingMarketCap)}), or the token is born graduated.`,
      revert: 'GraduationThresholdTooLow',
    })
  }
  if (d.feeBps > MAX_FEE_BPS) {
    out.push({ field: 'feeBps', message: 'The hard cap is 10%.', revert: 'FeeTooHigh' })
  }
  if (d.sellFeeBps > MAX_FEE_BPS) {
    out.push({ field: 'sellFeeBps', message: 'The hard cap is 10%.', revert: 'FeeTooHigh' })
  }
  if (d.creatorBps + d.burnBps > BPS) {
    out.push({
      field: 'burnBps',
      message: 'Your cut and the burn both come out of the fee, so together they cannot exceed it.',
      revert: 'CreatorShareTooHigh',
    })
  }
  if (d.vestDuration > 0 && d.devBuyPairAmount === 0) {
    out.push({
      field: 'devBuyPairAmount',
      message: 'There is nothing to vest. Set an opening buy, or turn the lock off.',
      revert: 'VestRequiresDevBuy',
    })
  }
  if (d.vestDuration > 0 && d.vestDuration < 7 * 86_400) {
    out.push({
      field: 'vestDuration',
      message: 'Seven days is the shortest lock the contract accepts.',
      revert: 'VestTooShort',
    })
  }
  if (d.vestCliff > d.vestDuration) {
    out.push({
      field: 'vestCliff',
      message: 'The cliff cannot be longer than the lock itself.',
      revert: 'VestCliffExceedsDuration',
    })
  }
  if (d.creatorBps > BPS) {
    out.push({ field: 'creatorBps', message: 'Cannot exceed 100% of the fee.', revert: 'CreatorShareTooHigh' })
  }
  if (d.maxWalletBps !== 0 && d.maxWalletBps < MIN_MAX_WALLET_BPS) {
    out.push({
      field: 'maxWalletBps',
      message: 'Below 0.1% a cap blocks ordinary buys instead of whales.',
      revert: 'MaxWalletTooSmall',
    })
  }
  if (!isAddressish(d.feeRecipient)) {
    out.push({
      field: 'feeRecipient',
      message: 'That is not a wallet address. Leave it blank to be paid where you launch from.',
      revert: '',
    })
  }
  if (d.devBuyPairAmount > devBuyCap(d)) {
    out.push({
      field: 'devBuyPairAmount',
      message: `Capped at 10% of the seed (${fmtAmount(devBuyCap(d))}). The launch reverts rather than trimming it.`,
      revert: 'DevBuyTooLarge',
    })
  }

  return out
}

export function issueFor(issues: Issue[], field: keyof LaunchDraft): Issue | undefined {
  return issues.find((i) => i.field === field)
}

// ---------------------------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------------------------

/** A pair-currency amount. Never rounds a small number to zero — that reads as "free". */
export function fmtAmount(n: number): string {
  if (!Number.isFinite(n)) return '—'
  if (n === 0) return '0'
  if (Math.abs(n) >= 1_000_000) return `${(n / 1_000_000).toLocaleString('en-US', { maximumFractionDigits: 2 })}M`
  if (Math.abs(n) >= 1000) return n.toLocaleString('en-US', { maximumFractionDigits: 0 })
  if (Math.abs(n) >= 1) return n.toLocaleString('en-US', { maximumFractionDigits: 4 })
  return n.toLocaleString('en-US', { maximumFractionDigits: 10 })
}

/** Whole-token counts. */
export function fmtSupply(n: number): string {
  if (!Number.isFinite(n) || n === 0) return '0'
  if (n >= 1e12) return `${(n / 1e12).toLocaleString('en-US', { maximumFractionDigits: 2 })}T`
  if (n >= 1e9) return `${(n / 1e9).toLocaleString('en-US', { maximumFractionDigits: 2 })}B`
  if (n >= 1e6) return `${(n / 1e6).toLocaleString('en-US', { maximumFractionDigits: 2 })}M`
  if (n >= 1e3) return n.toLocaleString('en-US', { maximumFractionDigits: 0 })
  return n.toLocaleString('en-US', { maximumFractionDigits: 4 })
}

export function fmtBps(bps: number): string {
  return `${(bps / 100).toLocaleString('en-US', { maximumFractionDigits: 2 })}%`
}
