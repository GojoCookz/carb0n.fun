/**
 * Chain constants and live reads.
 *
 * HARD RULE for this file: every value the UI renders must trace to a source. Nothing here
 * invents a number. Where a figure comes from an oracle or an RPC, the UI shows where it
 * came from. Where we have no data yet (because nothing is deployed), the UI says so
 * instead of rendering a plausible-looking zero.
 */
import { createPublicClient, http, formatUnits } from 'viem'
import { mainnet, optimism, sepolia } from 'viem/chains'

/** Verified on-chain 2026-08-31 via eth_getCode. Byte counts in contracts/script/Addresses.sol */
export const ADDRESSES = {
  mainnet: {
    poolManager: '0x000000000004444c5dc75cB358380D2e3dE08A90',
    weth: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
    /** Chainlink ETH/USD proxy, 8 decimals, ~1h heartbeat. The ONLY USD feed verified here. */
    ethUsdFeed: '0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419',
    /** BTSE wrapped Monero. 18 dp. The pair asset this launchpad is built around. */
    wxmr: '0x465e07d6028830124BE2E4aA551fBe12805dB0f5',
    /** Uniswap V2 WXMR/WETH pool, created 2021-01-06. The deepest WXMR market. */
    wxmrWethV2Pool: '0x14C10b4bDcCd9d3f8940Fb79E0eE00121391D6dE',
  },
  sepolia: {
    poolManager: '0xE03A1074c86CFeDd5C142C4F04F1a1536e203543',
  },
  /**
   * There is NO XMR/USD Chainlink feed on Ethereum L1 - both published aggregators return
   * zero bytes there. This one is live on Optimism and is read cross-chain purely to DISPLAY
   * a reference price. It is never used to price a launch on-chain.
   */
  optimism: {
    xmrUsdFeed: '0x2a8D91686A048E98e6CCF1A89E82f40D14312672',
  },
} as const

/**
 * A pair currency that is ACTUALLY LAUNCHABLE on a given network.
 *
 * This is not the same list as `PAIRS` in `pairs.ts`, and conflating them is how every launch
 * but two would revert. `PAIRS` describes the 25 mainnet currencies the product is for;
 * `PairRegistry` is an address allowlist, and on Sepolia it holds exactly two test tokens.
 * A picker that offers a currency the registry has never heard of is offering a transaction
 * that cannot succeed.
 */
export type LaunchablePair = {
  symbol: string
  address: `0x${string}`
  decimals: number
  /**
   * Fee tier of a v4 ETH/<pair> pool that has been VERIFIED to exist, or null when there is none.
   *
   * This is what decides whether a buyer may pay in ETH. `ZapRouter` needs hop 1 to exist; without
   * it the zap reverts `PoolNotInitialized`, which reads to a user as the token being broken. So
   * the currency selector offers ETH only where this is set, and says plainly why when it is not.
   *
   * **On Sepolia this pool was seeded by us at a price we invented** (`script/DeployZap.s.sol`),
   * because tPAXG is a mock with no market anywhere. It proves the routing. It says nothing about
   * anybody's economics.
   */
  ethPoolFee: number | null
}

export type Deployment = {
  pairRegistry: `0x${string}` | null
  launcher: `0x${string}` | null
  feeHook: `0x${string}` | null
  /** Splits the platform's cut between referrers and the treasury. */
  referralVault: `0x${string}` | null
  /** ETH in / ETH out routing, so a buyer never has to source the pair currency. */
  zapRouter: `0x${string}` | null
  /** Empty until the registry is deployed AND its approvals have been read from the chain. */
  pairs: LaunchablePair[]
}

/**
 * Null means "not deployed", and the UI must say so rather than render a dead control.
 *
 * **Every address here was verified with `eth_getCode` and every pair with
 * `PairRegistry.isApproved`** before being written down. An address pasted from a deploy log is
 * a claim, not a fact — the log says a transaction was sent, not that code is at that slot on
 * the chain the app will actually talk to.
 */
export const DEPLOYMENTS: { sepolia: Deployment; mainnet: Deployment } = {
  sepolia: {
    // Redeployed once `LaunchParams` gained `feeRecipient` and `referrer`. Adding fields to a
    // struct argument CHANGES THE FUNCTION SELECTOR, so the previous launcher could not have
    // accepted a call from this build at all - the button would have reverted on every attempt.
    pairRegistry: '0xd2Ed630c334355e8A38f06FddF9F2C72bf776340',
    launcher: '0x900C3d3db6629D421CBE8aB1C5CFC35FC566A133',
    feeHook: '0xe8fbfdB1A38E87b5cCf52b98dC7510E7E18Fe0CC',
    referralVault: '0x0497b2983f2802a3492E407fC45898DE917897F7',
    // Redeployed when `ZapRouter` gained a `deadline` argument and a WETH wrap path — the
    // constructor and both entry-point selectors changed, so the previous address could not have
    // accepted a call from this build.
    zapRouter: '0x71cC4afbF4cB6c6878A2405063F8810EE3B2dDBB',
    // Confirmed `isApproved() == true` for both, and `isApproved()` false for mainnet WETH,
    // which is the control that proves the call is reading what it claims to read.
    pairs: [
      // No ETH pool for these two. A zap through them would revert `PoolNotInitialized`, so the
      // panel must not offer ETH on a launch paired against them.
      { symbol: 'tWETH', address: '0x12FdCD633e5829E7Da7DACd8707432e9574aA156', decimals: 18, ethPoolFee: null },
      { symbol: 'tWXMR', address: '0x23f8dc6fD672fC62a900d96aad44D851216A877F', decimals: 18, ethPoolFee: null },
      // Seeded by `DeployZap`: tick 69060, ~997 tPAXG to the ether, at a price we invented.
      { symbol: 'tPAXG', address: '0x5B36658F7EF7c79c4e7ec46463FeB04012744F0c', decimals: 18, ethPoolFee: 3000 },
    ],
  },
  // Mainnet needs an audit first. Nothing is deployed and nothing may be.
  mainnet: {
    pairRegistry: null,
    launcher: null,
    feeHook: null,
    referralVault: null,
    zapRouter: null,
    pairs: [],
  },
}

/**
 * The fee tier of the ETH pool for a pair currency ON THE CHAIN THE LAUNCH IS ON, or null.
 *
 * Keyed by the chain address rather than the display symbol, because a Sepolia launch shows the
 * mainnet pair's name and icon while trading against a stand-in — looking this up by symbol would
 * answer for the wrong token.
 */
export function ethPoolFeeFor(chainPair: string | null): number | null {
  if (!chainPair) return null
  const p = DEPLOYMENTS.sepolia.pairs.find(
    (x) => x.address.toLowerCase() === chainPair.toLowerCase(),
  )
  return p?.ethPoolFee ?? null
}

/** The only network a launch may currently be sent to. */
export const LAUNCH_CHAIN = sepolia

/**
 * Which Sepolia test token stands in for a mainnet pair currency.
 *
 * Deliberately a SHORT list that fails closed. The alternative — quietly substituting tWETH for
 * whatever the user picked — would let someone configure a PEPE-paired launch, sign it, and get a
 * token paired against a test WETH they never chose. Everything not named here returns null and
 * the UI says the pair is not on the testnet, which is the truth.
 */
const SEPOLIA_STANDIN: Record<string, string> = {
  WETH: 'tWETH',
  WXMR: 'tWXMR',
  PAXG: 'tPAXG',
}

export function launchablePairFor(mainnetSymbol: string): LaunchablePair | null {
  const testSymbol = SEPOLIA_STANDIN[mainnetSymbol]
  if (!testSymbol) return null
  return DEPLOYMENTS.sepolia.pairs.find((p) => p.symbol === testSymbol) ?? null
}

export const mainnetClient = createPublicClient({
  chain: mainnet,
  transport: http('https://ethereum-rpc.publicnode.com'),
})

export const sepoliaClient = createPublicClient({
  chain: sepolia,
  transport: http('https://ethereum-sepolia-rpc.publicnode.com'),
})

export const optimismClient = createPublicClient({
  chain: optimism,
  transport: http('https://optimism-rpc.publicnode.com'),
})

const AGGREGATOR_V3_ABI = [
  {
    name: 'latestRoundData',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [
      { name: 'roundId', type: 'uint80' },
      { name: 'answer', type: 'int256' },
      { name: 'startedAt', type: 'uint256' },
      { name: 'updatedAt', type: 'uint256' },
      { name: 'answeredInRound', type: 'uint80' },
    ],
  },
  { name: 'decimals', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
] as const

const ERC20_ABI = [
  { name: 'totalSupply', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'decimals', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
  { name: 'symbol', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
] as const

export type XmrPrice = {
  usd: number
  updatedAt: Date
  /** Shown in the UI. A number without a stated origin is not allowed here. */
  source: string
}

/** Live XMR/USD from Chainlink on Optimism. Throws on failure - callers render an error, never a 0. */
export async function fetchXmrUsd(): Promise<XmrPrice> {
  const [roundData, decimals] = await Promise.all([
    optimismClient.readContract({
      address: ADDRESSES.optimism.xmrUsdFeed,
      abi: AGGREGATOR_V3_ABI,
      functionName: 'latestRoundData',
    }),
    optimismClient.readContract({
      address: ADDRESSES.optimism.xmrUsdFeed,
      abi: AGGREGATOR_V3_ABI,
      functionName: 'decimals',
    }),
  ])
  const [, answer, , updatedAt] = roundData
  if (answer <= 0n) throw new Error('XMR/USD feed returned a non-positive answer')
  return {
    usd: Number(formatUnits(answer, decimals)),
    updatedAt: new Date(Number(updatedAt) * 1000),
    source: 'Chainlink XMR/USD · Optimism',
  }
}

export type WxmrFacts = {
  totalSupply: bigint
  decimals: number
  symbol: string
  source: string
}

/** Live facts about the real WXMR contract on Ethereum mainnet. */
export async function fetchWxmrFacts(): Promise<WxmrFacts> {
  const [totalSupply, decimals, symbol] = await Promise.all([
    mainnetClient.readContract({ address: ADDRESSES.mainnet.wxmr, abi: ERC20_ABI, functionName: 'totalSupply' }),
    mainnetClient.readContract({ address: ADDRESSES.mainnet.wxmr, abi: ERC20_ABI, functionName: 'decimals' }),
    mainnetClient.readContract({ address: ADDRESSES.mainnet.wxmr, abi: ERC20_ABI, functionName: 'symbol' }),
  ])
  return { totalSupply, decimals, symbol, source: 'Ethereum mainnet · eth_call' }
}

/**
 * Which pair currencies this build can put a DOLLAR number next to, and where that number
 * comes from.
 *
 * This map is short on purpose, and its shortness is the product's whole thesis made visible.
 * Chainlink's mainnet directory was enumerated (292 feeds, 192 Crypto) and cross-checked against
 * the FeedRegistry: of the 22 pairs in `pairs.ts`, **PEPE, SPX, ELON, FLOKI, Mog, NPC, ANDY, APU,
 * WOJAK, PORK, WOLF, ENA, ANIME, XMR and XRP have no feed of any kind on L1.** That is exactly why
 * the graduation threshold is denominated in the pair asset on chain and dollars are rendered
 * here, off chain, where being unavailable costs nothing.
 *
 * A pair absent from this map renders `—`, never a guess and never a stale constant. USDC is
 * absent deliberately: a USDC/USD feed does exist on L1, but its address has not been verified in
 * this repo, and "everyone knows it is a dollar" is not a source.
 */
export const USD_SOURCES: Record<string, { label: string; chain: string }> = {
  WETH: { label: 'Chainlink ETH/USD', chain: 'Ethereum L1' },
  // Read cross-chain purely to DISPLAY a reference price. Never used to price a launch.
  WXMR: { label: 'Chainlink XMR/USD', chain: 'Optimism' },
}

export type PairUsd = { usd: number; updatedAt: Date; source: string }

/** Live USD price for one whole unit of a pair currency, or null if this build has no source. */
export async function fetchPairUsd(symbol: string): Promise<PairUsd | null> {
  const src = USD_SOURCES[symbol]
  if (!src) return null

  const client = symbol === 'WXMR' ? optimismClient : mainnetClient
  const feed = symbol === 'WXMR' ? ADDRESSES.optimism.xmrUsdFeed : ADDRESSES.mainnet.ethUsdFeed

  const [roundData, decimals] = await Promise.all([
    client.readContract({ address: feed, abi: AGGREGATOR_V3_ABI, functionName: 'latestRoundData' }),
    client.readContract({ address: feed, abi: AGGREGATOR_V3_ABI, functionName: 'decimals' }),
  ])
  const [, answer, , updatedAt] = roundData
  if (answer <= 0n) throw new Error(`${symbol} feed returned a non-positive answer`)

  return {
    usd: Number(formatUnits(answer, decimals)),
    updatedAt: new Date(Number(updatedAt) * 1000),
    source: `${src.label} · ${src.chain}`,
  }
}

export function shortAddress(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`
}

/**
 * Cents are noise above about a hundred dollars. A market cap rendered as `$12,333.16` implies a
 * precision the underlying spot price does not have, and the two trailing digits are the first
 * thing to churn on every block.
 */
export function formatUsd(n: number): string {
  return n.toLocaleString('en-US', {
    style: 'currency',
    currency: 'USD',
    maximumFractionDigits: n >= 100 ? 0 : 2,
  })
}
