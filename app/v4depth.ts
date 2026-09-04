/**
 * Does hop 1 actually EXIST on mainnet, for the pairs this product is for?
 *
 * `ZapRouter` calls `PoolManager.swap` on a v4 PoolKey. v2 and v3 liquidity is unreachable from
 * the v4 singleton — different contracts, different accounting. So "ETH/PAXG has $17.2M across
 * v2+v3" says nothing about whether the zap can route through it. This asks the v4 singleton
 * directly, for every pair in the roster, across every standard fee tier.
 *
 *   bun v4depth.ts
 */
import {
  createPublicClient,
  http,
  fallback,
  keccak256,
  encodeAbiParameters,
  encodePacked,
  parseAbi,
  zeroAddress,
  type Address,
} from 'viem'
import { mainnet } from 'viem/chains'
import { PAIRS } from './src/lib/pairs'

const V4_POOL_MANAGER: Address = '0x000000000004444c5dc75cB358380D2e3dE08A90'
/** `StateLibrary.POOLS_SLOT` in the installed v4-core. */
const POOLS_SLOT = 6n
const LIQUIDITY_OFFSET = 3n

const client = createPublicClient({
  chain: mainnet,
  transport: fallback([
    http('https://eth.drpc.org'),
    http('https://eth-pokt.nodies.app'),
    http('https://eth.merkle.io'),
  ]),
})

const managerAbi = parseAbi(['function extsload(bytes32 slot) view returns (bytes32)'])

const POOL_KEY_PARAM = [
  {
    type: 'tuple',
    components: [
      { name: 'currency0', type: 'address' },
      { name: 'currency1', type: 'address' },
      { name: 'fee', type: 'uint24' },
      { name: 'tickSpacing', type: 'int24' },
      { name: 'hooks', type: 'address' },
    ],
  },
] as const

/** Standard Uniswap fee tiers and their canonical spacings. */
const TIERS: [number, number][] = [
  [100, 1],
  [500, 10],
  [3000, 60],
  [10000, 200],
]

function poolId(currency1: Address, fee: number, tickSpacing: number): `0x${string}` {
  return keccak256(
    encodeAbiParameters(POOL_KEY_PARAM, [
      { currency0: zeroAddress, currency1, fee, tickSpacing, hooks: zeroAddress },
    ]),
  )
}

function stateSlot(id: `0x${string}`): `0x${string}` {
  return keccak256(encodePacked(['bytes32', 'bytes32'], [id, `0x${POOLS_SLOT.toString(16).padStart(64, '0')}`]))
}

function addSlot(slot: `0x${string}`, offset: bigint): `0x${string}` {
  return `0x${(BigInt(slot) + offset).toString(16).padStart(64, '0')}`
}

let withPool = 0
let without = 0

console.log('v4 singleton:', V4_POOL_MANAGER)
console.log('Asking: is there an ETH/<pair> pool ON UNISWAP V4 with non-zero liquidity?\n')

for (const p of PAIRS) {
  const addr = p.address as Address | undefined
  if (!addr || addr === zeroAddress) {
    console.log(`${p.symbol.padEnd(7)} no address in the roster`)
    continue
  }
  const found: string[] = []
  for (const [fee, spacing] of TIERS) {
    const id = poolId(addr, fee, spacing)
    const base = stateSlot(id)
    try {
      const slot0 = await client.readContract({
        address: V4_POOL_MANAGER,
        abi: managerAbi,
        functionName: 'extsload',
        args: [base],
      })
      // sqrtPriceX96 is the low 160 bits; zero means the pool was never initialised.
      const sqrtPrice = BigInt(slot0) & ((1n << 160n) - 1n)
      if (sqrtPrice === 0n) continue
      const liqWord = await client.readContract({
        address: V4_POOL_MANAGER,
        abi: managerAbi,
        functionName: 'extsload',
        args: [addSlot(base, LIQUIDITY_OFFSET)],
      })
      const liquidity = BigInt(liqWord) & ((1n << 128n) - 1n)
      found.push(`fee=${fee} L=${liquidity}`)
    } catch (e) {
      found.push(`fee=${fee} READ FAILED ${(e as Error).message.slice(0, 40)}`)
    }
  }
  if (found.length === 0) {
    console.log(`${p.symbol.padEnd(7)} NO v4 ETH pool at any standard tier`)
    without++
  } else {
    console.log(`${p.symbol.padEnd(7)} ${found.join('  |  ')}`)
    withPool++
  }
}

console.log(`\n${withPool} pair(s) have a v4 ETH pool, ${without} do not.`)
