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

/** Nothing is deployed on Robinhood Chain yet. Nulls, not placeholders. */
const ROBINHOOD_DEPLOYMENT: Deployment = {
  pairRegistry: null,
  launcher: null,
  feeHook: null,
  referralVault: null,
  zapRouter: null,
  pairs: [],
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
 * The network the app is currently pointed at.
 *
 * Still Sepolia. This is the single place that changes when a deployment lands, and it is a
 * constant rather than a runtime toggle on purpose: a network picker that can select a chain with
 * no contracts deployed is a picker that offers transactions which cannot succeed. Wire the toggle
 * to `deployableNetworks()` when there is more than one entry in it.
 */
export const ACTIVE_NETWORK: NetworkId = 'sepolia'

export function network(id: NetworkId = ACTIVE_NETWORK): NetworkInfo {
  return NETWORKS[id]
}

/** Networks that actually have a launcher. The only safe source for a network picker. */
export function deployableNetworks(): NetworkInfo[] {
  return Object.values(NETWORKS).filter((n) => n.deployment.launcher !== null)
}

const CLIENTS = new Map<NetworkId, PublicClient>()

/** One client per network, created on first use. */
export function clientFor(id: NetworkId = ACTIVE_NETWORK): PublicClient {
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
