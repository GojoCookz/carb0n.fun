/**
 * The pair currencies a launch can be priced against.
 *
 * This list IS the product. The pad is chain-first (Ethereum L1), not pair-first — no single
 * entry here is the brand.
 *
 * EVERY field below was verified on-chain on 2026-08-31: bytecode via eth_getCode,
 * symbol/name/decimals via eth_call, admin powers by scanning deployed bytecode for function
 * selectors (pause 0x8456cb59, mint 0x40c10f19, blacklist 0x0ecb93c0/0xe47d6060/0xf9f92be4,
 * upgradeTo 0x3659cfe6, owner 0x8da5cb5b), and pool depth from DexScreener filtered to
 * chainId 'ethereum'. Nothing here comes from a token's marketing.
 *
 * `priceable` mirrors PairRegistry exactly: only pairs with a Chainlink USD feed on L1 can
 * open at a dollar market cap. Everything else quotes its opening in pair units. Promising a
 * USD opening the contract would reject is a lie the UI must not tell.
 *
 * NOTE ON DECIMALS: these are NOT all 18. USDC is 6, SPX and BITCOIN are 8, FLOKI is 9.
 * Any amount math must read `decimals` from this table, never assume 1e18.
 */
export type PairRisk = {
  /** A third party can freeze transfers — which freezes every pool using this pair. */
  pausable: boolean
  /** A third party can block addresses, silently stopping their dividend payouts. */
  blacklist: boolean
  /** Logic can be swapped after deploy, so today's audit does not bind tomorrow. */
  upgradeable: boolean
  /** Supply can be increased after deploy. */
  mintable: boolean
  /** An owner key still exists (not renounced). */
  owned: boolean
}

/**
 * What kind of thing this is, for grouping in the picker.
 *
 * `chain` is the one that matters strategically. BaseStonk's pitch is "get paid in
 * tokenized stocks"; on Ethereum L1 there are effectively no stock tokens a US-based
 * team can touch, so the equivalent here is **get paid in other chains** — Bitcoin,
 * Monero, XRP, wrapped onto Ethereum. That is the same idea with a different asset
 * class, and unlike stocks it carries no securities exposure.
 */
export type PairCategory = 'chain' | 'major' | 'ecosystem' | 'meme' | 'rwa'

export type Pair = {
  symbol: string
  name: string
  address: `0x${string}`
  decimals: number
  category: PairCategory
  priceable: boolean
  /**
   * Has anybody actually looked at this token's bytecode?
   *
   * **Defaults to true only because every hand-written entry below WAS reviewed.** The Robinhood
   * roster is generated from the on-chain registry rather than written here, and nothing in this
   * repo has audited those contracts, so they arrive with `reviewed: false`.
   *
   * It exists because the depth panel prints "no admin powers in bytecode" whenever `riskCount`
   * is zero. For a token nobody examined, an empty risk list means "we did not look", and
   * rendering that as a clean bill of health would be a fabricated safety claim on the one screen
   * where somebody is deciding what to trade against.
   */
  reviewed?: boolean
  /** Total DEX liquidity on Ethereum, USD, measured 2026-08-31. */
  liquidityUsd: number
  /** 24h volume across Ethereum pools, USD, measured 2026-08-31. */
  volume24hUsd: number
  /** Oldest Ethereum pool for this token. Longevity is the strongest trust signal available. */
  liveSince: string
  risks: PairRisk
  /**
   * The single deepest pool behind this pair, read directly from the chain rather than from an
   * aggregator. Present only where a test in this repo actually measures it.
   */
  measuredPool?: {
    label: string
    /** Human-readable reserves, e.g. "306.76 WXMR / 65.12 WETH". */
    reserves: string
    /** Total supply of the pair asset, for scale. */
    totalSupply: string
    source: string
  }
}

const CLEAN: PairRisk = {
  pausable: false,
  blacklist: false,
  upgradeable: false,
  mintable: false,
  owned: false,
}
const r = (p: Partial<PairRisk>): PairRisk => ({ ...CLEAN, ...p })

/**
 * `liquidityUsd` on every entry below was MEASURED FROM POOL BALANCES ON CHAIN, not taken from an
 * aggregator, by `measure.ts` in this directory. Re-run it to refresh.
 *
 * Method: walk the Uniswap v2 and v3 factories for every (pair, quote, feeTier) combination
 * against WETH, USDC and USDT, read the quote-side ERC-20 balance actually sitting in each pool,
 * value it at the Chainlink ETH/USD rate, and double it for the two-sided total. The quote side
 * is the number that matters here because it is what a holder selling a dividend sells INTO.
 *
 * **v3 alone is not enough and getting that wrong is easy.** Most of the meme allowlist predates
 * v3 and still keeps the bulk of its depth in v2 pairs: a v3-only sweep reported PEPE at $186K
 * when the real figure across both is $26.8M, a 144x understatement that would have made the
 * launch form warn creators away from one of the deepest pairs on the list.
 *
 * Zero means no pool was found against any of the three quotes — LBTC is the only one, and it
 * routes through Curve rather than Uniswap. The UI renders that as "could not be measured"
 * rather than as a confident zero.
 *
 * Measured 2026-09 at ETH/USD $2,415.07.
 */
export const PAIRS: Pair[] = [
  // --- Other chains, wrapped onto Ethereum ---------------------------------------------------
  // Measured live 2026-09 via DexScreener (ethereum pools only); admin powers by scanning
  // deployed bytecode for selectors over eth.drpc.org.
  {
    symbol: 'WBTC',
    name: 'Wrapped Bitcoin',
    address: '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599',
    decimals: 8,
    category: 'chain',
    priceable: false,
    liquidityUsd: 186_365_125,
    volume24hUsd: 59_254_472,
    liveSince: '2019-01-31',
    // 4,582 bytes. BitGo custodial: pause + mint + owner all present in bytecode.
    risks: r({ pausable: true, mintable: true, owned: true }),
  },
  {
    symbol: 'tBTC',
    name: 'Threshold Bitcoin',
    address: '0x18084fbA666a33d37592fA2633fD49a74DD93a88',
    decimals: 18,
    category: 'chain',
    priceable: false,
    liquidityUsd: 512_181,
    volume24hUsd: 4_648_130,
    liveSince: '2023-01-18',
    // 12,877 bytes. Threshold Network, decentralised minting: mint + owner, no pause.
    risks: r({ mintable: true, owned: true }),
  },
  {
    symbol: 'LBTC',
    name: 'Lombard Staked Bitcoin',
    address: '0x8236a87084f8B84306f72007F36F2618A5634494',
    decimals: 8,
    category: 'chain',
    priceable: false,
    liquidityUsd: 0,
    volume24hUsd: 541_364,
    liveSince: '2024-08-22',
    // 1,159 bytes — that is a PROXY, not a token. A selector scan of the proxy says
    // nothing about the implementation behind it, so `upgradeable` is the only honest
    // flag and the rest are UNKNOWN rather than absent.
    risks: r({ upgradeable: true }),
  },

  // --- Blue chip / infrastructure -----------------------------------------------------------
  {
    symbol: 'WETH',
    name: 'Wrapped Ether',
    address: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
    decimals: 18,
    category: 'major',
    priceable: true,
    liquidityUsd: 304_317_027,
    volume24hUsd: 224_330_707,
    liveSince: '2017',
    risks: CLEAN,
  },
  {
    symbol: 'USDC',
    name: 'USD Coin',
    address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    decimals: 6,
    category: 'major',
    priceable: true,
    // Not measurable via DexScreener: USDC is almost always the QUOTE side, so it under-reports.
    liquidityUsd: 166_819_066,
    volume24hUsd: 37_633_766,
    liveSince: '2018',
    risks: r({ pausable: true, blacklist: true, upgradeable: true, mintable: true, owned: true }),
  },
  {
    symbol: 'UNI',
    name: 'Uniswap',
    address: '0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984',
    decimals: 18,
    category: 'ecosystem',
    priceable: false,
    liquidityUsd: 18_312_116,
    volume24hUsd: 13_452_442,
    liveSince: '2020-09-17',
    risks: r({ mintable: true }),
  },
  {
    symbol: 'ENA',
    name: 'Ethena',
    address: '0x57e114B691Db790C35207b2e685D4A43181e6061',
    decimals: 18,
    category: 'ecosystem',
    priceable: false,
    liquidityUsd: 894_885,
    volume24hUsd: 2_048_073,
    liveSince: '2024-04-02',
    risks: r({ mintable: true, owned: true }),
  },
  {
    symbol: 'WLFI',
    name: 'World Liberty Financial',
    address: '0xdA5e1988097297dCdc1f90D4dFE7909e847CBeF6',
    decimals: 18,
    category: 'ecosystem',
    priceable: false,
    liquidityUsd: 210_176,
    volume24hUsd: 138_214,
    liveSince: '2025-07-17',
    risks: CLEAN,
  },
  {
    symbol: 'APE',
    name: 'ApeCoin',
    address: '0x4d224452801ACEd8B2F0aebE155379bb5D594381',
    decimals: 18,
    category: 'ecosystem',
    priceable: false,
    liquidityUsd: 135_438,
    volume24hUsd: 115_904,
    liveSince: '2022-03-17',
    risks: CLEAN,
  },

  // --- Majors of the meme complex ------------------------------------------------------------
  {
    symbol: 'PEPE',
    name: 'Pepe',
    address: '0x6982508145454Ce325dDbE47a25d4ec3d2311933',
    decimals: 18,
    category: 'meme',
    priceable: false,
    liquidityUsd: 26_805_486,
    volume24hUsd: 1_243_394,
    liveSince: '2023-04-14',
    risks: CLEAN,
  },
  {
    symbol: 'SPX',
    name: 'SPX6900',
    address: '0xE0f63A424a4439cBE457D80E4f4b51aD25b2c56C',
    decimals: 8,
    category: 'meme',
    priceable: false,
    liquidityUsd: 13_500_883,
    volume24hUsd: 1_525_493,
    liveSince: '2023-08-16',
    risks: CLEAN,
  },
  {
    symbol: 'ELON',
    name: 'Dogelon Mars',
    address: '0x761D38e5ddf6ccf6Cf7c55759d5210750B5D60F3',
    decimals: 18,
    category: 'meme',
    priceable: false,
    liquidityUsd: 5_427_308,
    volume24hUsd: 22_838,
    liveSince: '2021-04-23',
    risks: CLEAN,
  },
  {
    symbol: 'FLOKI',
    name: 'Floki',
    address: '0xcf0C122c6b73ff809C693DB761e7BaeBe62b6a2E',
    decimals: 9,
    category: 'meme',
    priceable: false,
    liquidityUsd: 7_206_709,
    volume24hUsd: 80_247,
    liveSince: '2022-01-23',
    risks: r({ owned: true }),
  },
  {
    symbol: 'Mog',
    name: 'Mog Coin',
    address: '0xaaeE1A9723aaDB7afA2810263653A34bA2C21C7a',
    decimals: 18,
    category: 'meme',
    priceable: false,
    liquidityUsd: 5_234_421,
    volume24hUsd: 138_388,
    liveSince: '2023-07-20',
    risks: CLEAN,
  },
  {
    symbol: 'NPC',
    name: 'Non-Playable Coin',
    address: '0x8eD97a637A790Be1feff5e888d43629dc05408F6',
    decimals: 18,
    category: 'meme',
    priceable: false,
    liquidityUsd: 4_296_497,
    volume24hUsd: 632_352,
    liveSince: '2023-07-29',
    risks: CLEAN,
  },
  {
    symbol: 'SHIB',
    name: 'Shiba Inu',
    address: '0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE',
    decimals: 18,
    category: 'meme',
    priceable: false,
    liquidityUsd: 883_134,
    volume24hUsd: 114_355,
    liveSince: '2020-07-31',
    risks: CLEAN,
  },
  {
    symbol: 'BITCOIN',
    name: 'HarryPotterObamaSonic10Inu',
    address: '0x72e4f9F808C49A2a61dE9C5896298920Dc4EEEa9',
    decimals: 8,
    category: 'meme',
    priceable: false,
    liquidityUsd: 1_379_712,
    volume24hUsd: 84_188,
    liveSince: '2023-05-10',
    risks: CLEAN,
  },
  {
    symbol: 'ANDY',
    name: 'Andy',
    address: '0x68BbEd6A47194EFf1CF514B50Ea91895597fc91E',
    decimals: 18,
    category: 'meme',
    priceable: false,
    liquidityUsd: 1_261_558,
    volume24hUsd: 57_710,
    liveSince: '2024-03-09',
    risks: CLEAN,
  },
  {
    symbol: 'APU',
    name: 'Apu Apustaja',
    address: '0x594DaaD7D77592a2b97b725A7AD59D7E188b5bFa',
    decimals: 18,
    category: 'meme',
    priceable: false,
    liquidityUsd: 1_036_309,
    volume24hUsd: 20_028,
    liveSince: '2024-03-11',
    risks: CLEAN,
  },
  {
    symbol: 'WOJAK',
    name: 'Wojak',
    address: '0x8De39B057CC6522230AB19C0205080a8663331Ef',
    decimals: 18,
    category: 'meme',
    priceable: false,
    liquidityUsd: 908_122,
    volume24hUsd: 204_303,
    liveSince: '2026-01-26',
    risks: CLEAN,
  },
  {
    symbol: 'PORK',
    name: 'PepeFork',
    address: '0xb9f599ce614Feb2e1BBe58F180F370D05b39344E',
    decimals: 18,
    category: 'meme',
    priceable: false,
    liquidityUsd: 73_799,
    volume24hUsd: 66_875,
    liveSince: '2024-01-30',
    risks: r({ mintable: true }),
  },
  {
    symbol: 'WOLF',
    name: 'Landwolf',
    address: '0x67466BE17df832165F8C80a5A120CCc652bD7E69',
    decimals: 18,
    category: 'meme',
    priceable: false,
    liquidityUsd: 709_262,
    volume24hUsd: 59_761,
    liveSince: '2024-04-21',
    risks: CLEAN,
  },
  {
    symbol: 'ANIME',
    name: 'Animecoin',
    address: '0x4DC26fC5854e7648a064a4ABD590bBE71724C277',
    decimals: 18,
    category: 'ecosystem',
    priceable: false,
    liquidityUsd: 143_809,
    volume24hUsd: 74_329,
    liveSince: '2025-01-23',
    risks: r({ owned: true }),
  },

  // --- Wrapped foreign chains ----------------------------------------------------------------
  {
    symbol: 'WXMR',
    name: 'Wrapped Monero',
    address: '0x465e07d6028830124BE2E4aA551fBe12805dB0f5',
    decimals: 18,
    category: 'chain',
    priceable: false,
    liquidityUsd: 316_234,
    volume24hUsd: 18_874,
    liveSince: '2021-01-06',
    risks: r({ pausable: true, blacklist: true, mintable: true, owned: true }),
    measuredPool: {
      label: 'Uniswap V2 WXMR/WETH',
      reserves: '306.76 WXMR / 65.12 WETH',
      totalSupply: '7,000 WXMR',
      source: 'contracts/test/LauncherFork.t.sol · mainnet fork pinned at block 25,875,500',
    },
  },
  {
    symbol: 'WXRP',
    name: 'Wrapped XRP',
    address: '0x39fBBABf11738317a448031930706cd3e612e1B9',
    decimals: 18,
    category: 'chain',
    priceable: false,
    liquidityUsd: 141_263,
    volume24hUsd: 19_431,
    liveSince: '2021-12-15',
    risks: r({ pausable: true, upgradeable: true, mintable: true }),
  },

  // ===========================================================================================
  // REAL-WORLD ASSETS
  //
  // **This is the Ethereum answer to stock-paired launchpads.** Every competitor pairs against
  // tokenized equities, which requires Robinhood Chain because a US-facing team cannot touch
  // securities on L1. But the RWAs that ARE on Ethereum - gold, treasury-backed dollars, private
  // credit - carry none of that exposure and nobody has built a launchpad around them.
  //
  // Every risk flag below was read from DEPLOYED BYTECODE, not from a listing site: the
  // EIP-1967 implementation slot for upgradeability, and selector presence in the runtime code
  // of the implementation for pause/mint/burn/owner. `liquidityUsd: 0` means depth has not been
  // measured yet and the UI says so rather than guessing.
  // ===========================================================================================
  {
    symbol: 'PAXG',
    name: 'Paxos Gold',
    address: '0x45804880De22913dAFE09f4980848ECE6EcbAf78',
    decimals: 18,
    category: 'rwa',
    priceable: false,
    liquidityUsd: 17_157_898,
    volume24hUsd: 0,
    liveSince: '2019-09-05',
    // One ounce of allocated London Good Delivery gold per token. 428,830 oz on chain.
    // A CUSTOM Paxos proxy, not EIP-1967, so the automated slot check misses it - `owner()` and
    // `paused()` both answer on direct call, and the 1,506-byte runtime is a proxy by size.
    // Flagged conservatively: a risk disclosure should err toward naming a power, not omitting it.
    risks: r({ pausable: true, upgradeable: true, owned: true }),
  },
  {
    symbol: 'XAUT',
    name: 'Tether Gold',
    address: '0x68749665FF8D2d112Fa859AA293F07A622782F38',
    decimals: 6,
    category: 'rwa',
    priceable: false,
    liquidityUsd: 1_286_245,
    volume24hUsd: 0,
    liveSince: '2020-01-23',
    // SIX decimals. 707,747 oz.
    risks: r({ upgradeable: true, mintable: true, owned: true }),
  },
  {
    symbol: 'USD1',
    name: 'World Liberty Financial USD',
    address: '0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d',
    decimals: 18,
    category: 'rwa',
    priceable: false,
    liquidityUsd: 348_639,
    volume24hUsd: 0,
    liveSince: '2025-03-25',
    // $1.57B supply. Carries every admin power there is - upgradeable behind an EIP-1967 proxy
    // at 0xa032fe6c..., plus pause, mint, burn and an owner. Large is not the same as safe.
    risks: r({ pausable: true, upgradeable: true, mintable: true, owned: true }),
  },
  {
    symbol: 'ONDO',
    name: 'Ondo Finance',
    address: '0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3',
    decimals: 18,
    category: 'rwa',
    priceable: false,
    liquidityUsd: 317_606,
    volume24hUsd: 0,
    liveSince: '2024-01-18',
    risks: r({ mintable: true }),
  },
  // ---------------------------------------------------------------------------------------------
  // USDY (Ondo US Dollar Yield) WAS HERE AND HAS BEEN REMOVED ON PURPOSE. Do not add it back.
  //
  // It is a tokenised short-term US Treasury note - a yield-bearing debt instrument, sold under
  // Reg S and restricted from US persons by its own issuer. That is a SECURITY, and the rule this
  // roster is held to is: pair currencies are crypto assets and commodities, never tokenised
  // securities. Counsel's position is that revenue sharing on its own is not the problem and
  // tokenised stocks are; a tokenised Treasury note sits on the wrong side of that line for the
  // same reason a tokenised share does.
  //
  // THE TEST FOR ADDING ANYTHING HERE: does the token represent a claim on an issuer's cash flows,
  // debt, or equity? If yes it does not go in this list, whatever its ticker looks like. Gold
  // (PAXG, XAUT) is a commodity claim and stays; a Treasury note is not.
  // ---------------------------------------------------------------------------------------------
  {
    symbol: 'USDf',
    name: 'Falcon USD',
    address: '0xFa2B947eEc368f42195f24F36d2aF29f7c24CeC2',
    decimals: 18,
    category: 'rwa',
    priceable: false,
    liquidityUsd: 513_091,
    volume24hUsd: 0,
    liveSince: '2025-04-01',
    risks: r({ upgradeable: true, mintable: true }),
  },
  // ---------------------------------------------------------------------------------------------
  // WHITE (WhiteRock) WAS HERE AND HAS BEEN REMOVED ON PURPOSE. Do not add it back.
  //
  // The token itself is a plain ERC-20 platform token - checked on chain, no per-share semantics,
  // no claim on an issuer - so it does NOT fail the cash-flows/debt/equity test above. It is
  // removed for a different and deliberate reason: WhiteRock's business is tokenised equities, and
  // the standing instruction is to stay away from that entire area rather than to argue the line.
  //
  // It cost nothing to drop. $898 of liquidity, no v4 ETH pool, unroutable for the zap anyway.
  // When an asset is worth nothing and carries an association, the association is the whole price.
  // ---------------------------------------------------------------------------------------------

  // ===========================================================================================
  // BLUE CHIPS. LINK, AAVE and CRV are three of only eight assets with a DIRECT Chainlink
  // USD feed on L1, so unlike most of this list they can show an honest dollar figure.
  // ===========================================================================================
  {
    symbol: 'LINK',
    name: 'Chainlink',
    address: '0x514910771AF9Ca656af840dff83E8264EcF986CA',
    decimals: 18,
    category: 'ecosystem',
    priceable: false,
    liquidityUsd: 13_189_375,
    volume24hUsd: 8_700_000,
    liveSince: '2017-09-19',
    // Fixed 1B supply and NO admin powers in the deployed bytecode - no pause, no blacklist,
    // no mint, no proxy. The cleanest contract on this entire list.
    risks: r({}),
  },
  {
    symbol: 'AAVE',
    name: 'Aave',
    address: '0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9',
    decimals: 18,
    category: 'ecosystem',
    priceable: false,
    liquidityUsd: 4_684_080,
    volume24hUsd: 0,
    liveSince: '2020-10-02',
    risks: r({ upgradeable: true }),
  },
  {
    symbol: 'CRV',
    name: 'Curve DAO',
    address: '0xD533a949740bb3306d119CC777fa900bA034cd52',
    decimals: 18,
    category: 'ecosystem',
    priceable: false,
    liquidityUsd: 1_226_498,
    volume24hUsd: 0,
    liveSince: '2020-08-13',
    risks: r({ mintable: true }),
  },
  {
    symbol: 'MNT',
    name: 'Mantle',
    address: '0x3c3a81e81dc49A522A592e7622A7E711c06bf354',
    decimals: 18,
    category: 'ecosystem',
    priceable: false,
    liquidityUsd: 7_840,
    volume24hUsd: 0,
    liveSince: '2023-07-17',
    risks: r({ upgradeable: true, mintable: true, owned: true }),
  },
  {
    symbol: 'USDT',
    name: 'Tether USD',
    address: '0xdAC17F958D2ee523a2206206994597C13D831ec7',
    decimals: 6,
    category: 'major',
    priceable: false,
    liquidityUsd: 198_151_605,
    volume24hUsd: 233_880_000,
    liveSince: '2017-11-28',
    // SIX decimals, and it CAN BLACKLIST - verified by direct call, not assumed. A blacklisted
    // holder silently stops receiving dividends, which is why this is disclosed rather than
    // treated as a formality on the deepest asset in crypto.
    risks: r({ pausable: true, blacklist: true, owned: true }),
  },
  {
    symbol: 'TRX',
    name: 'TRON (wrapped)',
    address: '0x50327c6c5a14DCaDE707ABad2E27eB517df87AB5',
    decimals: 6,
    category: 'chain',
    priceable: false,
    liquidityUsd: 774_898,
    volume24hUsd: 0,
    liveSince: '2018-06-25',
    // SIX decimals.
    risks: r({ mintable: true }),
  },
]

/**
 * WETH, explicitly - NOT `PAIRS[0]`.
 *
 * It used to be the first entry, which silently became WBTC the moment the wrapped chains were
 * added to the top of the list. A default that moves when the list is reordered is a default
 * nobody chose.
 */
export const DEFAULT_PAIR = PAIRS.find((p) => p.symbol === 'WETH') ?? PAIRS[0]

/** Token logos, served by DexScreener and keyed on the lowercased contract address. */
/**
 * DexScreener's chain slug, which is NOT the same string as our network id.
 *
 * This function existed with `ethereum` hardcoded into the path, so every Robinhood address asked
 * DexScreener for a token on the wrong chain, got a 404, and fell back to two grey initials. All
 * thirty Robinhood tiles were blank for that one word.
 *
 * Measured after fixing: 24 of the 30 Robinhood currencies have an image on the `robinhood` path.
 * The six without are the non-meme assets - WETH, USDG, cbBTC, SLV, GLD, PAXG - which have no
 * DexScreener presence there at all. Those fall through to `TokenLogo`'s generated mark.
 */
const DEXSCREENER_CHAIN: Record<string, string> = {
  mainnet: 'ethereum',
  robinhood: 'robinhood',
  // Testnet tokens are mocks that no aggregator has ever seen. Sending the request anyway would
  // just be 30 guaranteed 404s per page load.
  sepolia: '',
}

export function logoUrl(p: Pair, networkId = 'mainnet'): string {
  const chain = DEXSCREENER_CHAIN[networkId] ?? 'ethereum'
  if (!chain) return ''
  return `https://dd.dexscreener.com/ds-data/tokens/${chain}/${p.address.toLowerCase()}.png`
}

export function riskCount(p: Pair): number {
  return Object.values(p.risks).filter(Boolean).length
}

export function riskLabels(p: Pair): string[] {
  const out: string[] = []
  if (p.risks.pausable) out.push('can pause')
  if (p.risks.blacklist) out.push('can blacklist')
  if (p.risks.upgradeable) out.push('upgradeable')
  if (p.risks.mintable) out.push('mintable')
  if (p.risks.owned) out.push('has owner')
  return out
}

/**
 * Depth is a PER-PAIR property, not a platform ceiling.
 *
 * The registry is an allowlist and a creator picks a pair per launch, so a thin pair constrains
 * only the tokens launched against it — it is never a reason to drop the pair. But a creator
 * picking a thin one should see that before they commit, because holders are paid dividends IN
 * this currency and have to be able to sell it.
 *
 * The bands below are OUR RULE, not a measurement, and the UI says so. The measurement is
 * `liquidityUsd` / `volume24hUsd`, both read from DexScreener on 2026-08-31 and filtered to
 * chainId 'ethereum'.
 */
export type DepthBand = 'deep' | 'moderate' | 'thin' | 'unmeasured'

export function depthBand(p: Pair): DepthBand {
  if (p.liquidityUsd === 0) return 'unmeasured'
  if (p.liquidityUsd >= 10_000_000) return 'deep'
  if (p.liquidityUsd >= 1_000_000) return 'moderate'
  return 'thin'
}

export function depthNote(p: Pair): string {
  switch (depthBand(p)) {
    case 'deep':
      return `Holders can sell ${p.symbol} dividends without moving its price much.`
    case 'moderate':
      return `${p.symbol} has real but limited depth. Large dividend sells will move its price.`
    case 'thin':
      return `${p.symbol} is thin. Holders paid in it may struggle to sell without moving its price, and your pool inherits that.`
    case 'unmeasured':
      return `Depth for ${p.symbol} could not be measured: it is almost always the quote side of a pool, so aggregators under-report it.`
  }
}

export function formatLiquidity(n: number): string {
  if (n === 0) return '—'
  if (n >= 1_000_000) return `$${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `$${Math.round(n / 1_000)}K`
  return `$${n}`
}
