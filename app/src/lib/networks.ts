/**
 * The network registry, and the seam that lets the app run on more than one chain.
 *
 * **Why this is a separate file from `chain.ts`.** `chain.ts` reached for `DEPLOYMENTS.sepolia`
 * directly in several places, which is correct while exactly one network can be launched on and
 * silently wrong the moment a second exists: a Robinhood Chain launch would look up its pair in
 * Sepolia's registry, find nothing, and the UI would report "not launchable" for a pair that is
 * fine. Adding a network is therefore not a matter of adding a key to an object - the lookups have
 * to become network-aware, and this module is where that happens.
 *
 * **HARD RULE, inherited from `chain.ts` and not relaxed here: nothing in this file invents a
 * value.** A network with no deployment has `null` addresses and an empty pair list, and the UI
 * must render an absence rather than a plausible-looking zero.
 *
 * Contract-side mirror: `contracts/script/Addresses.sol`. If an address changes in one, it changes
 * in both, and both record the byte count that was read from the chain.
 */
import { createPublicClient, http, defineChain, type Chain, type PublicClient } from 'viem'
import { mainnet, sepolia } from 'viem/chains'
import { DEPLOYMENTS, type Deployment } from './chain'
import { PAIRS, type Pair } from './pairs'

/**
 * Robinhood Chain. Not in `viem/chains`, so it is defined here.
 *
 * Arbitrum Nitro, and the gas token is ETH rather than a chain-specific token, which is why
 * `nativeCurrency` reads the way it does.
 */
export const robinhood = defineChain({
  id: 4663,
  name: 'Robinhood Chain',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.mainnet.chain.robinhood.com'] } },
  blockExplorers: {
    default: { name: 'Blockscout', url: 'https://robinhoodchain.blockscout.com' },
  },
  /**
   * MULTICALL3 IS DEPLOYED HERE AND VIEM DID NOT KNOW.
   *
   * Without this entry viem refuses every `multicall` with `Chain "Robinhood Chain" does not
   * support contract "multicall3"`, which is exactly what the token page showed instead of the
   * dividend state: the reads in `useTokenDetail` and `referrals` are all batched.
   *
   * Verified rather than assumed - `eth_getCode` returns 3,808 bytes at the canonical address, and
   * an `aggregate3` carrying two real ERC-20 reads comes back correctly.
   *
   * Note for anyone using it: `Multicall3.getBlockNumber()` reports ~25.9M here while
   * `eth_blockNumber` reports ~57.8M. That is not a broken deployment - this is an Arbitrum Nitro
   * chain, where `block.number` is an L1 approximation. Never use it as an L2 block height.
   */
  contracts: {
    multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' },
  },
})

export type NetworkId = 'sepolia' | 'mainnet' | 'robinhood'

export type NetworkInfo = {
  id: NetworkId
  chain: Chain
  label: string
  explorer: string
  /**
   * The v4 singleton. **Robinhood Chain is NOT at the canonical L1 address** - that slot returns
   * zero bytes there - so this can never be assumed and is recorded per network.
   */
  poolManager: `0x${string}`
  /**
   * Whether a launch can be opened at a DOLLAR market cap on this network.
   *
   * False means no USD oracle was found, so openings are quoted in units of the pair asset. That
   * is a supported mode, not a degraded one: `PairRegistry` has carried an UNPRICEABLE tier
   * (`approvePairWithoutOracle`) since WXMR, which is liquid on L1 and has no Chainlink feed.
   * The UI must switch the market-cap input's unit rather than hide it.
   */
  usdPricing: boolean
  /**
   * Whether native ETH in / ETH out is available.
   *
   * **False on Robinhood Chain, and the reason is specific.** `ZapRouter` wraps and unwraps
   * through a WETH9. The token with 533,961 holders that answers `symbol() == "WETH"` on 4663
   * exposes neither `deposit()` nor `withdraw(uint256)` in its bytecode, and none of the four
   * other WETH-named contracts there do either. It is a bridged ERC-20, not a wrapper. A router
   * constructed against it would revert on every zap, so the ETH entry point is disabled until a
   * real wrapper is found, deployed, or the route is done natively.
   *
   * `Launcher`, `FeeHook` and `PairRegistry` do not depend on this and ship without it.
   */
  nativeZap: boolean
  deployment: Deployment
}

/**
 * LIVE on Robinhood Chain. Every address below was verified with `eth_getCode` after the deploy,
 * and every pair with `PairRegistry.isApproved` read back from the chain - not taken from a deploy
 * log, which only says a transaction was sent.
 *
 * `zapRouter` is null and stays null: the WETH on this chain is a bridged ERC-20 with no
 * `deposit()`, so a router built against it would revert on every zap. Buyers source the pair
 * currency directly here.
 *
 * `ethPoolFee` is null throughout for the same reason - there is no ETH-in route to price.
 */
const ROBINHOOD_DEPLOYMENT: Deployment = {
  pairRegistry: '0xDFf0A6FfD11Eb1494E8A57DD5eF92b23122BaeC0',
  launcher: '0xCc491F9962CA5545163ac425210b69e24AC29a96',
  feeHook: '0xdC0244274F0b4E60Ec4433bfA9d3Ff0632CAa0Cc',
  referralVault: '0x6E87800BEDf09ddA439Ae78c820c58427Ca57947',
  // Deployed after the fact: the original Robinhood deploy shipped the five core contracts and
  // no router, so the trade panel had nothing to call on this chain.
  tradeRouter: '0xD6EdCd3cc28C40b42d6fe31B054eBb93a944A3A6',
  zapRouter: null,
  pairs: [
    // Core. Decimals read on-chain, never assumed: USDG is 6 and cbBTC is 8 where nearly
    // everything else is 18, and a wrong value misprices every launch by a power of ten.
    { symbol: 'WETH', name: 'WETH', address: '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73', decimals: 18, ethPoolFee: null },
    { symbol: 'USDG', name: 'Global Dollar', address: '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168', decimals: 6, ethPoolFee: null },
    // Commodities.
    { symbol: 'cbBTC', name: 'Coinbase Wrapped BTC', address: '0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4', decimals: 8, ethPoolFee: null },
    { symbol: 'SLV', name: 'iShares Silver Trust • Robinhood Token', address: '0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f', decimals: 18, ethPoolFee: null },
    { symbol: 'GLD', name: 'SPDR Gold Trust • Robinhood Token', address: '0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e', decimals: 18, ethPoolFee: null },
    { symbol: 'PAXG', name: 'Paxos Gold', address: '0xc700C81925D1d1C10F996fA7c0Dee83a54C4Bb8D', decimals: 18, ethPoolFee: null },
    // RobinVista synths: USDG-collateralised, 1x perp-hedged on Hyperliquid.
    { symbol: 'XMR', name: 'Monero', address: '0x38F728351fd9565087a4fF0ad5049739e0Ce235c', decimals: 18, ethPoolFee: null },
    { symbol: 'ZEC', name: 'Zcash', address: '0xEc127e99Da1a2eD3d6C0433227154a99B7B29221', decimals: 18, ethPoolFee: null },
    { symbol: 'SOL', name: 'Solana', address: '0x49F98A382Ccbc05f13b3E3aB323D04aBA975642D', decimals: 18, ethPoolFee: null },
    // Community pairs with real depth on this chain.
    { symbol: 'PONS', name: 'Pons', address: '0x39dBED3a2bd333467115dE45665cC57F813C4571', decimals: 18, ethPoolFee: null },
    { symbol: 'AI', name: 'Artificial Inu', address: '0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18', decimals: 18, ethPoolFee: null },
    { symbol: 'CASHCAT', name: 'Cash Cat', address: '0x020bfC650A365f8BB26819deAAbF3E21291018b4', decimals: 18, ethPoolFee: null },
    { symbol: 'FATCOIN', name: 'FATCOIN', address: '0x12D5ee7917cA430073C3A638ee1e6f0648A98a01', decimals: 18, ethPoolFee: null },
    { symbol: 'CME', name: 'Commodity Market Exchange', address: '0xe2324FF2a59F8eCBa8c321c6466e59121C00e795', decimals: 18, ethPoolFee: null },
    { symbol: 'MEME', name: 'A Meme Coin', address: '0x385F4f8ae47651ce5F58F5265395a669f8281e18', decimals: 18, ethPoolFee: null },
    { symbol: 'BONER', name: 'Boner Coin', address: '0x98096d17e191B3dA1d5f99a6D7b3584351b11E18', decimals: 18, ethPoolFee: null },
    { symbol: 'MOO', name: 'Memory cow Moo', address: '0xD9dB30BB0D2b8d2eae3826A1372117E058791e18', decimals: 18, ethPoolFee: null },
    { symbol: 'STONKBROKER', name: 'StonkBroker', address: '0xe934e36A439C94017B64a3FecE66AF12099aBF50', decimals: 18, ethPoolFee: null },
    { symbol: 'SHROOM', name: 'MUSHROOM', address: '0xab093dEF657F15dF31b33922A95e047aDd645B29', decimals: 18, ethPoolFee: null },
    { symbol: 'HOOKR', name: 'Hookr.fun', address: '0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c', decimals: 18, ethPoolFee: null },
    { symbol: 'NUDES', name: 'Send Nudes', address: '0xbe98b75361935b18d688409424a869a4C3dC7401', decimals: 18, ethPoolFee: null },
    { symbol: 'ZZZ', name: 'ZZZ', address: '0x7dbf38976f6D3b9c529e7D9484A71898B409eE6a', decimals: 18, ethPoolFee: null },
    { symbol: 'DELTA', name: 'Delta', address: '0xe8ffd7e24187F72afB08d75B1bb13088A989a791', decimals: 18, ethPoolFee: null },
    { symbol: 'TENDIES', name: 'TENDIES', address: '0x45242320DBB855EeA8Fd36804C6487E10E97FCF9', decimals: 18, ethPoolFee: null },
    { symbol: 'YOLO', name: 'YOLO', address: '0x62C71cd34a52c30d894419CBcc55Db2aFA8032eA', decimals: 18, ethPoolFee: null },
    { symbol: 'ROBINCAT', name: 'ROBINCAT', address: '0xded852De9fe9bA9b6f27f39e8e81CF851A5C79cc', decimals: 18, ethPoolFee: null },
    { symbol: 'microduck', name: 'microduck', address: '0xD5f1afEA47b1A9eab414D2ee740cF1d6d039E725', decimals: 18, ethPoolFee: null },
    { symbol: 'PIPEDOG', name: 'pipedog', address: '0x5Cb6F181081301b44905F3ae15419112ecaBd8A6', decimals: 18, ethPoolFee: null },
    { symbol: 'PAIR', name: 'PAIR', address: '0x6b1d42927B1a84eC28Fa88d4fC6FA7AF404966be', decimals: 18, ethPoolFee: null },
    { symbol: 'IF', name: 'What If', address: '0x232CDFc415D10b673845D83Dc02ba2eaBe7e30d1', decimals: 18, ethPoolFee: null },
  ],
}

export const NETWORKS: Record<NetworkId, NetworkInfo> = {
  sepolia: {
    id: 'sepolia',
    chain: sepolia,
    label: 'Sepolia',
    explorer: 'https://sepolia.etherscan.io',
    poolManager: '0xE03A1074c86CFeDd5C142C4F04F1a1536e203543',
    usdPricing: true, // mock aggregator, see contracts/test/mocks
    nativeZap: true,
    deployment: DEPLOYMENTS.sepolia,
  },
  mainnet: {
    id: 'mainnet',
    chain: mainnet,
    label: 'Ethereum',
    explorer: 'https://etherscan.io',
    poolManager: '0x000000000004444c5dc75cB358380D2e3dE08A90',
    usdPricing: true,
    nativeZap: true,
    deployment: DEPLOYMENTS.mainnet,
  },
  robinhood: {
    id: 'robinhood',
    chain: robinhood,
    label: 'Robinhood Chain',
    explorer: 'https://robinhoodchain.blockscout.com',
    // 24,009 bytes, read via eth_getCode. The canonical L1 address is EMPTY on this chain.
    poolManager: '0x8366a39CC670B4001A1121B8F6A443A643e40951',
    usdPricing: false,
    nativeZap: false,
    deployment: ROBINHOOD_DEPLOYMENT,
  },
}

/**
 * Pair currencies that exist on Robinhood Chain, for when the registry is deployed.
 *
 * **Addresses only, never symbols.** Three separate contracts on 4663 answer
 * `symbol() == "USDG"`, with 279k, 173k and 169k holders. Five answer `WETH` or `wETH`. The same
 * pattern produced four `XMR`/`Monero` contracts and several `Monero-Chan`s. A symbol on this
 * chain identifies nothing, which is exactly why `PairRegistry` is an address allowlist and has
 * no symbol-based entry point.
 */
export const ROBINHOOD_PAIR_CANDIDATES = [
  {
    symbol: 'USDG',
    address: '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168' as const,
    /** SIX, not 18. Getting this wrong misprices every launch against it by 1e12. */
    decimals: 6,
    holders: 279_018,
    /** Confirmed independently: BaseStonk's `RhPairRegistry.usdg()` returns this address. */
    note: 'Global Dollar. 170 bytes, so a proxy.',
  },
  {
    symbol: 'WETH',
    address: '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73' as const,
    decimals: 18,
    holders: 533_961,
    note: 'Bridged ERC-20, NOT a WETH9 - no deposit()/withdraw(). Fine as a pair, unusable for the zap.',
  },
] as const

/**
 * The active network is RUNTIME state now, not a build-time constant - see `activeNetwork.ts`.
 *
 * It was a constant while exactly one chain had contracts, and that stopped being true the moment
 * Robinhood Chain went live: the user picks the chain, not the bundler. Re-exported here so there
 * is still exactly one answer to "which network are we on".
 */
export { activeNetworkId, activeNetwork, setActiveNetwork, selectableNetworks } from './activeNetwork'

export function network(id: NetworkId): NetworkInfo {
  return NETWORKS[id]
}

/** Networks that actually have a launcher. The only safe source for a network picker. */
export function deployableNetworks(): NetworkInfo[] {
  return Object.values(NETWORKS).filter((n) => n.deployment.launcher !== null)
}

const CLIENTS = new Map<NetworkId, PublicClient>()

/** One client per network, created on first use. */
export function clientFor(id: NetworkId): PublicClient {
  const existing = CLIENTS.get(id)
  if (existing) return existing
  const info = NETWORKS[id]
  const client = createPublicClient({
    chain: info.chain,
    transport: http(info.chain.rpcUrls.default.http[0]),
  }) as PublicClient
  CLIENTS.set(id, client)
  return client
}

/** Network-aware replacement for the `DEPLOYMENTS.sepolia.pairs` lookups in `chain.ts`. */
/**
 * The pair roster FOR ONE NETWORK, in the shape the launch UI renders.
 *
 * ## The bug this fixes
 *
 * The picker mapped `PAIRS` - a hand-written list of Ethereum mainnet tokens - regardless of which
 * network was selected. So on Robinhood Chain it offered WBTC, USDC, PEPE, SHIB and friends: none
 * of which exist on 4663, none of which are in that registry, and every one of which would have
 * failed at `PairRegistry.isApproved`. Meanwhile the thirty currencies actually approved there were
 * not offered at all.
 *
 * ## Ethereum assets stay on Ethereum; Robinhood assets stay on Robinhood
 *
 * The two rosters are kept strictly separate, and the separation is the point rather than an
 * implementation detail. `deployment.pairs` is what the on-chain registry approved for that
 * network - it is the only list that can actually be launched against - so it is the source of
 * truth here, and `PAIRS` only supplies presentation metadata where the ADDRESS matches. Addresses
 * never collide across chains, so a mainnet entry can never leak into the Robinhood list by
 * sharing a ticker.
 *
 * ## Where a Robinhood pair has no metadata, it says so
 *
 * Liquidity, volume and age come from a mainnet measurement that has no Robinhood equivalent, so
 * they arrive as zero, which `formatLiquidity` already renders as an em dash. They are NOT
 * estimated. `reviewed: false` marks the risk block as unexamined rather than clean.
 */
export function pairsForNetwork(id: NetworkId): Pair[] {
  const approved = NETWORKS[id].deployment.pairs

  // ETHEREUM ASSETS STAY ON ETHEREUM. `PAIRS` is a researched list of real mainnet addresses, and
  // mainnet has no on-chain roster yet because nothing is deployed there. Showing it is browsing,
  // not a promise: `LaunchSubmit` independently refuses to submit on an undeployed network with
  // "Nothing is deployed. This button will not pretend to submit." Falling back only when the
  // approved list is EMPTY means a deployed network can never be overridden by this.
  if (approved.length === 0 && id === 'mainnet') return PAIRS

  return approved.map((lp): Pair => {
    const known = PAIRS.find((p) => p.address.toLowerCase() === lp.address.toLowerCase())

    // Same token, same chain: use the reviewed record, but trust the registry's decimals, since
    // those were read back from this chain after approval.
    if (known) return { ...known, decimals: lp.decimals, address: lp.address }

    return {
      symbol: lp.symbol,
      name: lp.name,
      address: lp.address,
      decimals: lp.decimals,
      category: 'ecosystem',
      // No Chainlink feed exists on Robinhood Chain, so nothing here can be quoted in dollars.
      priceable: false,
      liquidityUsd: 0,
      volume24hUsd: 0,
      liveSince: '',
      risks: { pausable: false, blacklist: false, upgradeable: false, mintable: false, owned: false },
      reviewed: false,
    }
  })
}


export function launchablePairOn(id: NetworkId, address: string) {
  return (
    NETWORKS[id].deployment.pairs.find(
      (p) => p.address.toLowerCase() === address.toLowerCase(),
    ) ?? null
  )
}

export function explorerAddressUrl(id: NetworkId, address: string): string {
  return `${NETWORKS[id].explorer}/address/${address}`
}

export function explorerTxUrl(id: NetworkId, hash: string): string {
  return `${NETWORKS[id].explorer}/tx/${hash}`
}
