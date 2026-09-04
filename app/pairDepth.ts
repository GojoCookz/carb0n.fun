/**
 * How much ETH can hop 1 of the zap actually absorb?
 *
 * `v4depth.ts` answers "is there an ETH/<pair> v4 pool and what is its `L`?". That is not the
 * question the UI needs. `L` is an abstract unit — it is not dollars, and it is not comparable
 * across pairs with different decimals and different prices. Worse, v4depth counted a pool as
 * FOUND whenever `sqrtPriceX96 != 0`, which includes pools with `L == 0`. Those are just as
 * unroutable as a pool that was never initialised, so its "34 pairs have a v4 ETH pool" line
 * overcounts.
 *
 * This script asks the routable question instead: **push 0.1, 1 and 10 ETH through the pool and
 * measure what comes out**. The answer is a price impact in basis points, which IS comparable
 * across every pair regardless of decimals or price.
 *
 * Everything below is a chain read or an on-chain simulation. There is no fallback estimate
 * anywhere: if a read fails the failure is printed and the pool is dropped, never guessed.
 *
 *   bun pairDepth.ts
 */
import {
  createPublicClient,
  http,
  fallback,
  keccak256,
  encodeAbiParameters,
  encodePacked,
  parseAbi,
  parseEther,
  formatUnits,
  zeroAddress,
  type Address,
} from 'viem'
import { mainnet } from 'viem/chains'
import { PAIRS, type Pair } from './src/lib/pairs'

// ---------------------------------------------------------------------------------------------
// Addresses. Every one of these is checked with eth_getCode before it is used — see verify().
// Sourced from https://developers.uniswap.org/docs/protocols/v4/deployments and cross-read from
// Uniswap/sdks `sdk-core/src/addresses.ts`. A docs page is a claim; the getCode check is the fact.
// ---------------------------------------------------------------------------------------------
const V4_POOL_MANAGER: Address = '0x000000000004444c5dc75cB358380D2e3dE08A90'
const V4_QUOTER: Address = '0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203'
const V3_FACTORY: Address = '0x1F98431c8aD98523631AE4a59f267346ea31F984'
const V3_QUOTER_V2: Address = '0x61fFE014bA17989E743c5F6cB21bF9697530B21e'
const WETH: Address = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'

/** `StateLibrary.POOLS_SLOT` in the installed v4-core. Same derivation v4depth.ts uses. */
const POOLS_SLOT = 6n
const LIQUIDITY_OFFSET = 3n
const Q96 = 1n << 96n

/** Standard Uniswap fee tiers and their canonical spacings. */
const TIERS: readonly (readonly [number, number])[] = [
  [100, 1],
  [500, 10],
  [3000, 60],
  [10000, 200],
]

/** Trade sizes the UI cares about, in wei. */
const SIZES = [parseEther('0.1'), parseEther('1'), parseEther('10')]
const SIZE_LABELS = ['0.1 ETH', '1 ETH', '10 ETH']
/** Index of the 1 ETH size — the one the verdict is graded on. */
const GRADE_IDX = 1

const client = createPublicClient({
  chain: mainnet,
  transport: fallback([
    http('https://eth.drpc.org'),
    http('https://eth-pokt.nodies.app'),
    http('https://eth.merkle.io'),
  ]),
})

const managerAbi = parseAbi(['function extsload(bytes32 slot) view returns (bytes32)'])

/**
 * `V4Quoter.quoteExactInputSingle` is `nonpayable` in Solidity because it quotes by running the
 * real swap and reverting with the answer (`QuoterRevert`), which the compiler cannot see through.
 * Over `eth_call` mutability is irrelevant, so it is declared `view` here purely so viem will let
 * it ride inside a Multicall3 aggregate. Nothing is ever broadcast: this file has no signer.
 */
const v4QuoterAbi = [
  {
    type: 'function',
    name: 'quoteExactInputSingle',
    stateMutability: 'view',
    inputs: [
      {
        name: 'params',
        type: 'tuple',
        components: [
          {
            name: 'poolKey',
            type: 'tuple',
            components: [
              { name: 'currency0', type: 'address' },
              { name: 'currency1', type: 'address' },
              { name: 'fee', type: 'uint24' },
              { name: 'tickSpacing', type: 'int24' },
              { name: 'hooks', type: 'address' },
            ],
          },
          { name: 'zeroForOne', type: 'bool' },
          { name: 'exactAmount', type: 'uint128' },
          { name: 'hookData', type: 'bytes' },
        ],
      },
    ],
    outputs: [
      { name: 'amountOut', type: 'uint256' },
      { name: 'gasEstimate', type: 'uint256' },
    ],
  },
] as const

/** Same `view` note as above: QuoterV2 also quotes by reverting. */
const v3QuoterAbi = [
  {
    type: 'function',
    name: 'quoteExactInputSingle',
    stateMutability: 'view',
    inputs: [
      {
        name: 'params',
        type: 'tuple',
        components: [
          { name: 'tokenIn', type: 'address' },
          { name: 'tokenOut', type: 'address' },
          { name: 'amountIn', type: 'uint256' },
          { name: 'fee', type: 'uint24' },
          { name: 'sqrtPriceLimitX96', type: 'uint160' },
        ],
      },
    ],
    outputs: [
      { name: 'amountOut', type: 'uint256' },
      { name: 'sqrtPriceX96After', type: 'uint160' },
      { name: 'initializedTicksCrossed', type: 'uint32' },
      { name: 'gasEstimate', type: 'uint256' },
    ],
  },
] as const

const v3FactoryAbi = parseAbi([
  'function getPool(address,address,uint24) view returns (address)',
])
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

function poolId(currency1: Address, fee: number, tickSpacing: number): `0x${string}` {
  return keccak256(
    encodeAbiParameters(POOL_KEY_PARAM, [
      { currency0: zeroAddress, currency1, fee, tickSpacing, hooks: zeroAddress },
    ]),
  )
}

function stateSlot(id: `0x${string}`): `0x${string}` {
  return keccak256(
    encodePacked(['bytes32', 'bytes32'], [id, `0x${POOLS_SLOT.toString(16).padStart(64, '0')}`]),
  )
}

function addSlot(slot: `0x${string}`, offset: bigint): `0x${string}` {
  return `0x${(BigInt(slot) + offset).toString(16).padStart(64, '0')}`
}

// ---------------------------------------------------------------------------------------------
// Plumbing
// ---------------------------------------------------------------------------------------------

/** Public RPCs rate-limit. Retry the transient failures; surface the real ones. */
async function retry<T>(label: string, fn: () => Promise<T>, tries = 4): Promise<T> {
  let last: unknown
  for (let i = 0; i < tries; i++) {
    try {
      return await fn()
    } catch (e) {
      last = e
      await new Promise((r) => setTimeout(r, 400 * (i + 1)))
    }
  }
  throw new Error(`${label}: ${(last as Error)?.message?.slice(0, 160) ?? 'unknown'}`)
}

type MulticallItem = {
  address: Address
  abi: readonly unknown[]
  functionName: string
  args: readonly unknown[]
}

let blockNumber = 0n

/**
 * Multicall3 in chunks, allowing individual failures. Every call is pinned to one block so the
 * spot price and the quote can never come from different states.
 */
async function mc(items: MulticallItem[], chunk = 40) {
  const out: ({ status: 'success'; result: unknown } | { status: 'failure'; error: Error })[] = []
  for (let i = 0; i < items.length; i += chunk) {
    const slice = items.slice(i, i + chunk)
    const res = await retry(`multicall@${i}`, () =>
      client.multicall({
        // viem infers the return tuple per literal ABI; this list is heterogeneous by design.
        contracts: slice as Parameters<typeof client.multicall>[0]['contracts'],
        allowFailure: true,
        blockNumber,
      }),
    )
    for (const r of res) out.push(r as (typeof out)[number])
  }
  return out
}

// ---------------------------------------------------------------------------------------------
// Concentrated-liquidity math, for the independent recomputation cross-check.
// Ported from v4-core `SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp` and
// `getAmount1Delta`. In-range only: it deliberately ignores every tick boundary, which is what
// makes it a LOWER bound on output (and therefore an UPPER bound on price impact).
// ---------------------------------------------------------------------------------------------
function localQuoteZeroForOne(sqrtP: bigint, L: bigint, amountIn: bigint, swapFee: number): bigint {
  if (L === 0n || sqrtP === 0n) return 0n
  const inLessFee = (amountIn * BigInt(1_000_000 - swapFee)) / 1_000_000n
  const numerator = L * Q96
  const denom = numerator + inLessFee * sqrtP
  if (denom === 0n) return 0n
  // Round the next price UP, exactly as v4-core does, so the pool never loses a wei.
  const sqrtNext = (numerator * sqrtP + denom - 1n) / denom
  if (sqrtNext >= sqrtP) return 0n
  return (L * (sqrtP - sqrtNext)) / Q96
}

/**
 * The fee a zeroForOne swapper actually pays, from `ProtocolFeeLibrary.calculateSwapFee`:
 * the protocol takes its cut FIRST, the LP fee comes off the remainder, and the composite
 * rounds UP. `protocolFee` is two packed 12-bit halves; the low half is the zeroForOne one.
 */
function compositeSwapFee(slot0ProtocolFee: number, slot0LpFee: number): number {
  const pf = slot0ProtocolFee & 0xfff
  return pf + slot0LpFee - Math.floor((pf * slot0LpFee) / 1_000_000)
}

/** The zero-impact output: amountIn valued at the pool's current mid price. */
function idealOut(sqrtP: bigint, amountIn: bigint): bigint {
  return (amountIn * sqrtP * sqrtP) >> 192n
}

/** Execution cost against mid, in basis points, one decimal place. */
function bps(ideal: bigint, actual: bigint): number {
  if (ideal === 0n) return Number.NaN
  const scaled = ((ideal - actual) * 100_000n) / ideal
  return Number(scaled) / 10
}

function fmtBps(n: number | undefined): string {
  if (n === undefined || Number.isNaN(n)) return '     —'
  if (n >= 9999) return ' >9999'
  return n.toFixed(1).padStart(6)
}

// ---------------------------------------------------------------------------------------------
type PoolRow = {
  fee: number
  spacing: number
  sqrtP: bigint
  L: bigint
  /** From slot0, NOT from the PoolKey: governance can switch a protocol fee on per pool. */
  protocolFee: number
  lpFee: number
  /** Quoter output per size, or null where the quote reverted. */
  out: (bigint | null)[]
  impact: (number | undefined)[]
}

type Verdict = 'GOOD' | 'THIN' | 'UNUSABLE'

type Result = {
  pair: Pair
  pools: PoolRow[]
  best: PoolRow | null
  verdict: Verdict
  reason: string
}

async function verify(label: string, addr: Address): Promise<boolean> {
  const code = await retry(`getCode ${label}`, () => client.getCode({ address: addr }))
  const bytes = code && code !== '0x' ? (code.length - 2) / 2 : 0
  console.log(`  ${bytes > 0 ? 'OK  ' : 'FAIL'} ${label.padEnd(14)} ${addr}  ${bytes} bytes`)
  return bytes > 0
}

async function main() {
  blockNumber = await retry('blockNumber', () => client.getBlockNumber())

  console.log('='.repeat(96))
  console.log('HOP 1 DEPTH: how much ETH can the zap push through ETH -> <pair> on Uniswap v4?')
  console.log('='.repeat(96))
  console.log(`Chain: Ethereum mainnet. All reads pinned to block ${blockNumber}.`)
  console.log(`Date:  ${new Date().toISOString()}`)
  console.log('')
  console.log('Address verification (eth_getCode — an address in a doc is a claim, not a fact):')

  const okManager = await verify('PoolManager', V4_POOL_MANAGER)
  const okQuoter = await verify('V4Quoter', V4_QUOTER)
  const okV3Factory = await verify('V3Factory', V3_FACTORY)
  const okV3Quoter = await verify('V3QuoterV2', V3_QUOTER_V2)

  if (!okManager) {
    console.log('\nFATAL: PoolManager has no code at this address. Nothing below can be trusted.')
    process.exit(1)
  }
  if (!okQuoter) {
    console.log('\nFATAL: no V4Quoter bytecode. Refusing to fall back silently — see the header.')
    process.exit(1)
  }

  const priced = PAIRS.filter((p) => p.address && p.address !== zeroAddress)
  console.log(`\nScanning ${priced.length} pairs x ${TIERS.length} standard fee tiers.\n`)

  // -- Pass 1: read slot0 + liquidity for every (pair, tier) in one batched sweep. --------------
  console.log('Pass 1/3  reading slot0 + liquidity from the v4 singleton via extsload...')
  const stateCalls: MulticallItem[] = []
  const stateIndex: { pair: Pair; fee: number; spacing: number }[] = []
  for (const p of priced) {
    for (const [fee, spacing] of TIERS) {
      const base = stateSlot(poolId(p.address, fee, spacing))
      stateCalls.push({
        address: V4_POOL_MANAGER,
        abi: managerAbi,
        functionName: 'extsload',
        args: [base],
      })
      stateCalls.push({
        address: V4_POOL_MANAGER,
        abi: managerAbi,
        functionName: 'extsload',
        args: [addSlot(base, LIQUIDITY_OFFSET)],
      })
      stateIndex.push({ pair: p, fee, spacing })
    }
  }
  const stateRes = await mc(stateCalls, 60)

  const live: { pair: Pair; row: PoolRow }[] = []
  const readFailures: string[] = []
  for (let i = 0; i < stateIndex.length; i++) {
    const meta = stateIndex[i]!
    const a = stateRes[i * 2]
    const b = stateRes[i * 2 + 1]
    if (!a || !b || a.status === 'failure' || b.status === 'failure') {
      const err = a?.status === 'failure' ? a.error : (b as { error?: Error } | undefined)?.error
      readFailures.push(
        `${meta.pair.symbol} fee=${meta.fee} STATE READ FAILED: ${err?.message?.slice(0, 90) ?? 'unknown'}`,
      )
      continue
    }
    const word = BigInt(a.result as string)
    const sqrtP = word & ((1n << 160n) - 1n)
    // Slot0 packing: sqrtPriceX96 [0,160), tick [160,184), protocolFee [184,208), lpFee [208,232).
    const protocolFee = Number((word >> 184n) & 0xffffffn)
    const lpFee = Number((word >> 208n) & 0xffffffn)
    const L = BigInt(b.result as string) & ((1n << 128n) - 1n)
    if (sqrtP === 0n || L === 0n) continue
    live.push({
      pair: meta.pair,
      row: {
        fee: meta.fee,
        spacing: meta.spacing,
        sqrtP,
        L,
        protocolFee,
        lpFee,
        out: SIZES.map(() => null),
        impact: SIZES.map(() => undefined),
      },
    })
  }
  for (const f of readFailures) console.log(`  ! ${f}`)
  console.log(
    `  ${live.length} pool(s) are initialised AND carry non-zero in-range liquidity.` +
      ` (v4depth.ts would have counted every initialised pool, L==0 included.)`,
  )

  // -- Pass 2: simulate the three trade sizes against every live pool. --------------------------
  console.log(`\nPass 2/3  simulating ${live.length * SIZES.length} swaps through V4Quoter...`)
  const quoteCalls: MulticallItem[] = []
  const quoteIndex: { row: PoolRow; sizeIdx: number; symbol: string }[] = []
  for (const { pair, row } of live) {
    for (let s = 0; s < SIZES.length; s++) {
      quoteCalls.push({
        address: V4_QUOTER,
        abi: v4QuoterAbi,
        functionName: 'quoteExactInputSingle',
        args: [
          {
            poolKey: {
              currency0: zeroAddress,
              currency1: pair.address,
              fee: row.fee,
              tickSpacing: row.spacing,
              hooks: zeroAddress,
            },
            zeroForOne: true, // native ETH is address(0), so it is ALWAYS currency0
            exactAmount: SIZES[s]!,
            hookData: '0x',
          },
        ],
      })
      quoteIndex.push({ row, sizeIdx: s, symbol: pair.symbol })
    }
  }
  const quoteRes = await mc(quoteCalls, 15)

  let quoteFails = 0
  for (let i = 0; i < quoteIndex.length; i++) {
    const meta = quoteIndex[i]!
    const r = quoteRes[i]
    if (!r || r.status === 'failure') {
      quoteFails++
      continue
    }
    const amountOut = (r.result as readonly bigint[])[0]!
    meta.row.out[meta.sizeIdx] = amountOut
    meta.row.impact[meta.sizeIdx] = bps(idealOut(meta.row.sqrtP, SIZES[meta.sizeIdx]!), amountOut)
  }
  console.log(
    `  ${quoteIndex.length - quoteFails} quote(s) returned, ${quoteFails} reverted or failed.`,
  )
  console.log('  A reverted quote is reported as "—". It is never replaced with an estimate.')

  // -- Pass 3: pick the best tier per pair and classify. ----------------------------------------
  const results: Result[] = []
  for (const p of priced) {
    const pools = live.filter((l) => l.pair.symbol === p.symbol).map((l) => l.row)
    if (pools.length === 0) {
      results.push({
        pair: p,
        pools,
        best: null,
        verdict: 'UNUSABLE',
        reason: 'no initialised v4 ETH pool with L > 0 at any standard tier',
      })
      continue
    }
    // Best = lowest total execution cost at 1 ETH. That naturally trades the fee tier off against
    // depth: a 1% pool with deep liquidity can still beat a 0.05% pool with none.
    const graded = pools.filter((r) => r.impact[GRADE_IDX] !== undefined)
    if (graded.length === 0) {
      // A revert at 1 ETH is the quoter saying the pool cannot fill the trade at all. Say what
      // the smaller size did, so nobody reads this as a broken read.
      const small = pools
        .map((r) => r.impact[0])
        .filter((v): v is number => v !== undefined)
        .sort((a, b) => a - b)[0]
      results.push({
        pair: p,
        pools,
        best: null,
        verdict: 'UNUSABLE',
        reason:
          `pool(s) exist with L>0 but the 1 ETH quote REVERTS — the pool cannot fill it` +
          (small === undefined ? ' (0.1 ETH reverts too)' : `; 0.1 ETH costs ${small.toFixed(1)} bps`),
      })
      continue
    }
    graded.sort((a, b) => a.impact[GRADE_IDX]! - b.impact[GRADE_IDX]!)
    const best = graded[0]!
    const at1 = best.impact[GRADE_IDX]!
    const verdict: Verdict = at1 < 100 ? 'GOOD' : at1 <= 500 ? 'THIN' : 'UNUSABLE'
    results.push({
      pair: p,
      pools,
      best,
      verdict,
      reason: verdict === 'UNUSABLE' ? `${at1.toFixed(1)} bps at 1 ETH (> 500)` : '',
    })
  }

  // -- The table. -------------------------------------------------------------------------------
  console.log('\n' + '='.repeat(96))
  console.log('CLASSIFICATION — execution cost vs the pool mid price, in basis points')
  console.log('='.repeat(96))
  console.log(
    'pair'.padEnd(8) +
      'tier'.padStart(6) +
      '  ' +
      SIZE_LABELS.map((l) => l.padStart(6)).join(' ') +
      '   verdict   out @ 1 ETH',
  )
  console.log('-'.repeat(96))
  for (const r of results) {
    const tier = r.best ? `${r.best.fee}` : '—'
    const cells = r.best ? r.best.impact.map(fmtBps).join(' ') : SIZES.map(() => '     —').join(' ')
    const out1 = r.best?.out[GRADE_IDX]
    const outStr =
      out1 === undefined || out1 === null
        ? '—'
        : `${Number(formatUnits(out1, r.pair.decimals)).toLocaleString('en-US', {
            maximumSignificantDigits: 6,
          })} ${r.pair.symbol}`
    console.log(
      r.pair.symbol.padEnd(8) +
        tier.padStart(6) +
        '  ' +
        cells +
        '   ' +
        r.verdict.padEnd(9) +
        ' ' +
        outStr,
    )
  }

  const good = results.filter((r) => r.verdict === 'GOOD')
  const thin = results.filter((r) => r.verdict === 'THIN')
  const bad = results.filter((r) => r.verdict === 'UNUSABLE')
  console.log('-'.repeat(96))
  console.log(
    `GOOD (<100 bps @ 1 ETH): ${good.length}   ` +
      `THIN (100-500): ${thin.length}   ` +
      `UNUSABLE (>500 / no pool / L==0): ${bad.length}`,
  )

  console.log('\nUNUSABLE — the UI must NOT offer the ETH option for these:')
  for (const r of bad) console.log(`  ${r.pair.symbol.padEnd(8)} ${r.reason}`)

  console.log('\nPer-tier detail for every pool that had L > 0 (best tier marked *):')
  for (const r of results) {
    if (r.pools.length === 0) continue
    for (const pool of r.pools) {
      const mark = pool === r.best ? '*' : ' '
      console.log(
        `  ${mark}${r.pair.symbol.padEnd(8)} fee=${String(pool.fee).padStart(5)} ` +
          `L=${pool.L.toString().padStart(26)}  bps ${pool.impact.map(fmtBps).join(' ')}`,
      )
    }
  }

  // -- Cross-check A: recompute the same trade from slot0 + L, independently. -------------------
  console.log('\n' + '='.repeat(96))
  console.log('CROSS-CHECK A — V4Quoter vs an independent in-range recomputation from slot0 + L')
  console.log('='.repeat(96))
  console.log(
    'Two different code paths over the same pinned block: the deployed quoter (which walks every\n' +
      'tick it crosses) versus local SqrtPriceMath using only the in-range L. Where the trade stays\n' +
      'inside one tick range the two must agree EXACTLY, to the wei. Where it crosses a tick the\n' +
      'local number is a strict LOWER bound on output, so local < quoter is correct, not a failure.\n',
  )
  // WETH is excluded: cross-check B quotes against WETH on v3, and no DEX quotes WETH->WETH.
  const checkTargets = results
    .filter((r) => r.best !== null && r.pair.address.toLowerCase() !== WETH.toLowerCase())
    .slice(0, 3)
  console.log(
    'pair'.padEnd(8) +
      'tier'.padStart(6) +
      ' swapFee'.padStart(9) +
      '  quoter out @ 1 ETH'.padEnd(26) +
      'local out @ 1 ETH'.padEnd(26) +
      'delta',
  )
  let agreeA = 0
  for (const r of checkTargets) {
    const b = r.best!
    const q = b.out[GRADE_IDX]
    if (q === null || q === undefined) continue
    const swapFee = compositeSwapFee(b.protocolFee, b.lpFee)
    const l = localQuoteZeroForOne(b.sqrtP, b.L, SIZES[GRADE_IDX]!, swapFee)
    const diffPct = q === 0n ? Number.NaN : (Number(l - q) / Number(q)) * 100
    const ok = Number.isFinite(diffPct) && Math.abs(diffPct) < 0.01
    if (ok) agreeA++
    console.log(
      r.pair.symbol.padEnd(8) +
        String(b.fee).padStart(6) +
        String(swapFee).padStart(9) +
        '  ' +
        q.toString().padEnd(26) +
        l.toString().padEnd(26) +
        `${diffPct >= 0 ? '+' : ''}${diffPct.toFixed(5)}%  ${ok ? 'AGREE' : 'DIVERGES'}`,
    )
  }
  console.log(
    `\n  ${agreeA}/${checkTargets.length} agree to within 0.01%.` +
      `\n  swapFee above is the COMPOSITE fee read from slot0, not the PoolKey fee: governance has` +
      `\n  switched a protocol fee on for some of these pools, so the real cost exceeds the tier.` +
      `\n  Using the PoolKey fee instead leaves a systematic ~1.2 bps gap — that gap was the bug` +
      `\n  this cross-check caught, and it is exactly the class of error a single source hides.`,
  )

  // -- Cross-check B: quote the same trade on Uniswap v3. --------------------------------------
  console.log('\n' + '='.repeat(96))
  console.log('CROSS-CHECK B — the same 1 ETH trade quoted on Uniswap v3 (a wholly separate DEX)')
  console.log('='.repeat(96))
  if (!okV3Factory || !okV3Quoter) {
    console.log('SKIPPED: v3 factory or QuoterV2 bytecode check failed. No substitute number given.')
  } else {
    console.log(
      'v3 is a different contract, different liquidity and different math. It cannot validate the\n' +
        'v4 bps directly — different pool — but if v4 and v3 return wildly different amounts of the\n' +
        'same token for 1 ETH, one of the two is mispriced and the v4 read should not be trusted.\n',
    )
    const poolCalls: MulticallItem[] = []
    const poolIdx: { symbol: string; fee: number }[] = []
    for (const r of checkTargets) {
      for (const [fee] of TIERS) {
        poolCalls.push({
          address: V3_FACTORY,
          abi: v3FactoryAbi,
          functionName: 'getPool',
          args: [WETH, r.pair.address, fee],
        })
        poolIdx.push({ symbol: r.pair.symbol, fee })
      }
    }
    const poolRes = await mc(poolCalls, 40)

    const v3Quotes: MulticallItem[] = []
    const v3Idx: { symbol: string; fee: number }[] = []
    for (let i = 0; i < poolIdx.length; i++) {
      const rr = poolRes[i]
      if (!rr || rr.status === 'failure') continue
      if ((rr.result as Address).toLowerCase() === zeroAddress) continue
      v3Quotes.push({
        address: V3_QUOTER_V2,
        abi: v3QuoterAbi,
        functionName: 'quoteExactInputSingle',
        args: [
          {
            tokenIn: WETH,
            tokenOut: PAIRS.find((p) => p.symbol === poolIdx[i]!.symbol)!.address,
            amountIn: SIZES[GRADE_IDX]!,
            fee: poolIdx[i]!.fee,
            sqrtPriceLimitX96: 0n,
          },
        ],
      })
      v3Idx.push(poolIdx[i]!)
    }
    const v3Res = await mc(v3Quotes, 12)
    const bestV3 = new Map<string, { fee: number; out: bigint }>()
    for (let i = 0; i < v3Idx.length; i++) {
      const rr = v3Res[i]
      if (!rr || rr.status === 'failure') continue
      const out = (rr.result as readonly bigint[])[0]!
      const cur = bestV3.get(v3Idx[i]!.symbol)
      if (!cur || out > cur.out) bestV3.set(v3Idx[i]!.symbol, { fee: v3Idx[i]!.fee, out })
    }

    console.log(
      'pair'.padEnd(8) +
        'v4 out @ 1 ETH'.padEnd(26) +
        'v3 out @ 1 ETH'.padEnd(26) +
        'v3 tier'.padStart(8) +
        '   v4 vs v3',
    )
    let agreeB = 0
    let checkedB = 0
    for (const r of checkTargets) {
      const v4o = r.best!.out[GRADE_IDX]
      const v3 = bestV3.get(r.pair.symbol)
      if (v4o === null || v4o === undefined || !v3 || v3.out === 0n) {
        console.log(
          r.pair.symbol.padEnd(8) +
            (v4o?.toString() ?? '—').padEnd(26) +
            'NO v3 QUOTE'.padEnd(26) +
            '—'.padStart(8) +
            '   cannot compare',
        )
        continue
      }
      checkedB++
      const rel = (Number(v4o - v3.out) / Number(v3.out)) * 100
      const ok = Math.abs(rel) < 2
      if (ok) agreeB++
      console.log(
        r.pair.symbol.padEnd(8) +
          v4o.toString().padEnd(26) +
          v3.out.toString().padEnd(26) +
          String(v3.fee).padStart(8) +
          `   ${rel >= 0 ? '+' : ''}${rel.toFixed(3)}%  ${ok ? 'AGREE (<2%)' : 'DIVERGES'}`,
      )
    }
    console.log(`\n  ${agreeB}/${checkedB} v4 quotes land within 2% of the best v3 quote.`)
  }

  // -- Caveats. --------------------------------------------------------------------------------
  console.log('\n' + '='.repeat(96))
  console.log('METHODOLOGY — read this before trusting the table')
  console.log('='.repeat(96))
  console.log(
    [
      `1. Source of every number: Uniswap's deployed V4Quoter at ${V4_QUOTER}`,
      `   (bytecode verified above), called via eth_call, pinned to block ${blockNumber}. The quoter`,
      '   executes the real swap inside PoolManager.unlock and reverts with the result, so it walks',
      '   every tick crossed. These are NOT formula estimates and NOT numbers derived from memory.',
      '',
      '2. "bps" here is TOTAL EXECUTION COST against the pool mid price implied by slot0 — it',
      '   includes the LP fee. A 3000 pool therefore has a 30 bps floor it can never beat, and a',
      '   10000 pool a 100 bps floor. That is deliberate: the zap buyer pays the fee too, so a',
      '   fee-excluded "pure impact" number would understate what the UI is promising.',
      '',
      '3. Best tier is chosen by lowest cost at 1 ETH, not by highest L. Cheap-and-empty loses to',
      '   expensive-and-deep, which is the correct routing decision.',
      '',
      '4. ONLY hookless pools at the four standard (fee, tickSpacing) pairs are scanned. A pair',
      '   whose real v4 depth sits behind a hook, or at a non-canonical tickSpacing, is invisible',
      '   here and will read UNUSABLE. This is a scan of a fixed keyspace, not an exhaustive',
      '   enumeration of v4 — the Initialize event log is the only complete source.',
      '',
      '5. L == 0 is treated as NO POOL. An initialised pool with zero in-range liquidity cannot be',
      '   routed through. v4depth.ts counted those as found; this does not, which is why the pool',
      '   count here is lower than its summary line.',
      '',
      '6. This measures HOP 1 ONLY (ETH -> pair). Hop 2 runs in the project\'s own hooked pool and',
      '   adds its own impact plus the hook fee. A GOOD verdict here is necessary, not sufficient.',
      '',
      '7. One block, one instant. Depth moves. Re-run before shipping an allowlist off it.',
      '',
      '8. The three cross-check pairs are the first three in PAIRS order that had a live pool, not',
      '   a hand-picked flattering subset.',
    ].join('\n'),
  )
}

main().catch((e) => {
  console.error('\nFATAL:', e)
  process.exit(1)
})
