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
  zapRouter: null,
  pairs: [
    // Core. Decimals read on-chain, never assumed: USDG is 6 and cbBTC is 8 where nearly
    // everything else is 18, and a wrong value misprices every launch by a power of ten.
    { symbol: 'WETH', address: '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73', decimals: 18, ethPoolFee: null },
    { symbol: 'USDG', address: '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168', decimals: 6, ethPoolFee: null },
    // Commodities.
    { symbol: 'cbBTC', address: '0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4', decimals: 8, ethPoolFee: null },
    { symbol: 'SLV', address: '0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f', decimals: 18, ethPoolFee: null },
    { symbol: 'GLD', address: '0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e', decimals: 18, ethPoolFee: null },
    { symbol: 'PAXG', address: '0xc700C81925D1d1C10F996fA7c0Dee83a54C4Bb8D', decimals: 18, ethPoolFee: null },
    // RobinVista synths: USDG-collateralised, 1x perp-hedged on Hyperliquid.
    { symbol: 'XMR', address: '0x38F728351fd9565087a4fF0ad5049739e0Ce235c', decimals: 18, ethPoolFee: null },
    { symbol: 'ZEC', address: '0xEc127e99Da1a2eD3d6C0433227154a99B7B29221', decimals: 18, ethPoolFee: null },
    { symbol: 'SOL', address: '0x49F98A382Ccbc05f13b3E3aB323D04aBA975642D', decimals: 18, ethPoolFee: null },
    // Community pairs with real depth on this chain.
    { symbol: 'PONS', address: '0x39dBED3a2bd333467115dE45665cC57F813C4571', decimals: 18, ethPoolFee: null },
    { symbol: 'AI', address: '0x2E8c31162b855A2ffa90F6F8634643Ad6F111e18', decimals: 18, ethPoolFee: null },
    { symbol: 'CASHCAT', address: '0x020bfC650A365f8BB26819deAAbF3E21291018b4', decimals: 18, ethPoolFee: null },
    { symbol: 'FATCOIN', address: '0x12D5ee7917cA430073C3A638ee1e6f0648A98a01', decimals: 18, ethPoolFee: null },
    { symbol: 'CME', address: '0xe2324FF2a59F8eCBa8c321c6466e59121C00e795', decimals: 18, ethPoolFee: null },
    { symbol: 'MEME', address: '0x385F4f8ae47651ce5F58F5265395a669f8281e18', decimals: 18, ethPoolFee: null },
    { symbol: 'BONER', address: '0x98096d17e191B3dA1d5f99a6D7b3584351b11E18', decimals: 18, ethPoolFee: null },
    { symbol: 'MOO', address: '0xD9dB30BB0D2b8d2eae3826A1372117E058791e18', decimals: 18, ethPoolFee: null },
    { symbol: 'STONKBROKER', address: '0xe934e36A439C94017B64a3FecE66AF12099aBF50', decimals: 18, ethPoolFee: null },
    { symbol: 'SHROOM', address: '0xab093dEF657F15dF31b33922A95e047aDd645B29', decimals: 18, ethPoolFee: null },
    { symbol: 'HOOKR', address: '0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c', decimals: 18, ethPoolFee: null },
    { symbol: 'NUDES', address: '0xbe98b75361935b18d688409424a869a4C3dC7401', decimals: 18, ethPoolFee: null },
    { symbol: 'ZZZ', address: '0x7dbf38976f6D3b9c529e7D9484A71898B409eE6a', decimals: 18, ethPoolFee: null },
    { symbol: 'DELTA', address: '0xe8ffd7e24187F72afB08d75B1bb13088A989a791', decimals: 18, ethPoolFee: null },
    { symbol: 'TENDIES', address: '0x45242320DBB855EeA8Fd36804C6487E10E97FCF9', decimals: 18, ethPoolFee: null },
    { symbol: 'YOLO', address: '0x62C71cd34a52c30d894419CBcc55Db2aFA8032eA', decimals: 18, ethPoolFee: null },
    { symbol: 'ROBINCAT', address: '0xded852De9fe9bA9b6f27f39e8e81CF851A5C79cc', decimals: 18, ethPoolFee: null },
    { symbol: 'microduck', address: '0xD5f1afEA47b1A9eab414D2ee740cF1d6d039E725', decimals: 18, ethPoolFee: null },
    { symbol: 'PIPEDOG', address: '0x5Cb6F181081301b44905F3ae15419112ecaBd8A6', decimals: 18, ethPoolFee: null },
    { symbol: 'PAIR', address: '0x6b1d42927B1a84eC28Fa88d4fC6FA7AF404966be', decimals: 18, ethPoolFee: null },
    { symbol: 'IF', address: '0x232CDFc415D10b673845D83Dc02ba2eaBe7e30d1', decimals: 18, ethPoolFee: null },
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
