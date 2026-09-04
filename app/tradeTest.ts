/**
 * Prove a buy and a sell actually execute through the app's own encoding.
 *
 * **Imports `poolKeyFor` and `TRADE_ROUTER_ABI` from `src/lib/tradeTx.ts` rather than restating
 * them.** A test that rebuilds the pool key is a test of the test: it passes while the real panel
 * is wrong, because the two copies drifted. The only thing this file adds is a private key, which
 * is the one part a browser supplies and a script cannot borrow.
 *
 *   bun tradeTest.ts
 */
import {
  createWalletClient,
  createPublicClient,
  http,
  parseUnits,
  parseEther,
  formatUnits,
  formatEther,
  encodeAbiParameters,
  keccak256,
  parseAbi,
  type Address,
  type Hash,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { sepolia } from 'viem/chains'
import { readFileSync } from 'node:fs'
import { poolKeyFor, TRADE_ROUTER, TRADE_ROUTER_ABI } from './src/lib/tradeTx'
import { ethPoolKeyFor, zapAvailable, ZAP_ROUTER, ZAP_ROUTER_ABI } from './src/lib/zapTx'
import { DEPLOYMENTS } from './src/lib/chain'
import { LAUNCHER_ABI } from './src/lib/abi'

const env = Object.fromEntries(
  readFileSync('../contracts/.env', 'utf8')
    .split('\n')
    .filter((l) => l.includes('='))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
)

const account = privateKeyToAccount(env.PRIVATE_KEY as `0x${string}`)
const pub = createPublicClient({ chain: sepolia, transport: http(env.SEPOLIA_RPC_URL) })
const wallet = createWalletClient({ account, chain: sepolia, transport: http(env.SEPOLIA_RPC_URL) })

const ERC20 = [
  { name: 'balanceOf', type: 'function', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { name: 'approve', type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 's', type: 'address' }, { name: 'v', type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { name: 'allowance', type: 'function', stateMutability: 'view', inputs: [{ name: 'o', type: 'address' }, { name: 's', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { name: 'symbol', type: 'function', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
] as const

// Restating this ABI is what broke the first run: I wrote the tuple as (token, pair, creator)
// when the contract returns (token, creator, pair), so the script called symbol() on a wallet.
// The app's ABI is the one the app actually uses, so it is the only one worth testing against.
const LAUNCHER = LAUNCHER_ABI

const bal = (t: Address, who: Address) =>
  pub.readContract({ address: t, abi: ERC20, functionName: 'balanceOf', args: [who] })

async function ensureApproval(token: Address, amount: bigint, label: string) {
  const cur = await pub.readContract({
    address: token, abi: ERC20, functionName: 'allowance', args: [account.address, TRADE_ROUTER],
  })
  if (cur >= amount) return
  const h = await wallet.writeContract({
    address: token, abi: ERC20, functionName: 'approve', args: [TRADE_ROUTER, amount * 100n],
  })
  await pub.waitForTransactionReceipt({ hash: h })
  console.log(`   approved ${label}`)
}

async function trade(token: Address, pair: Address, isBuy: boolean, amountIn: bigint) {
  // The exact call the panel builds. Nothing restated.
  const { key, buyIsZeroForOne } = poolKeyFor(token, pair)
  const zeroForOne = isBuy ? buyIsZeroForOne : !buyIsZeroForOne
  const inToken = isBuy ? pair : token

  await ensureApproval(inToken, amountIn, isBuy ? 'pair' : 'token')

  const quoted = (await pub.simulateContract({
    address: TRADE_ROUTER, abi: TRADE_ROUTER_ABI, functionName: 'swap',
    args: [key, zeroForOne, amountIn, 0n, account.address], account,
  })).result as bigint

  const minOut = (quoted * 9900n) / 10_000n // 1%, same default as the panel
  const { request } = await pub.simulateContract({
    address: TRADE_ROUTER, abi: TRADE_ROUTER_ABI, functionName: 'swap',
    args: [key, zeroForOne, amountIn, minOut, account.address], account,
  })
  const hash = await wallet.writeContract(request)
  const r = await pub.waitForTransactionReceipt({ hash })
  return { quoted, hash, ok: r.status === 'success' }
}

const launcher = DEPLOYMENTS.sepolia.launcher as Address
const count = await pub.readContract({ address: launcher, abi: LAUNCHER, functionName: 'launchCount' })
console.log(`launchCount = ${count}\n`)

let pass = 0
let fail = 0

for (let i = 0n; i < count; i++) {
  const [token, , pair] = (await pub.readContract({
    address: launcher, abi: LAUNCHER, functionName: 'launches', args: [i],
  })) as [Address, Address, Address, bigint]

  const [tSym, pSym] = await Promise.all([
    pub.readContract({ address: token, abi: ERC20, functionName: 'symbol' }),
    pub.readContract({ address: pair, abi: ERC20, functionName: 'symbol' }),
  ])

  const pairHeld = await bal(pair, account.address)
  console.log(`── ${tSym} / ${pSym}`)
  console.log(`   pair held: ${formatUnits(pairHeld, 18)} ${pSym}`)

  const spend = parseUnits('0.5', 18)
  if (pairHeld < spend) {
    console.log(`   SKIP - not enough ${pSym} to buy with\n`)
    continue
  }

  try {
    const before = await bal(token, account.address)
    const b = await trade(token, pair, true, spend)
    const after = await bal(token, account.address)
    const got = after - before

    // The negative control: a "successful" tx that moved nothing is a failure.
    if (b.ok && got > 0n) {
      console.log(`   BUY  ok  +${formatUnits(got, 18)} ${tSym}`)
      pass++
    } else {
      console.log(`   BUY  FAILED - status=${b.ok} received=${got}`)
      fail++
      continue
    }

    // Sell a tenth of what we just bought, back to the pair.
    const sellAmt = got / 10n
    const pBefore = await bal(pair, account.address)
    const s = await trade(token, pair, false, sellAmt)
    const pAfter = await bal(pair, account.address)
    const back = pAfter - pBefore

    if (s.ok && back > 0n) {
      console.log(`   SELL ok  +${formatUnits(back, 18)} ${pSym}`)
      pass++
    } else {
      console.log(`   SELL FAILED - status=${s.ok} received=${back}`)
      fail++
    }
  } catch (e) {
    console.log(`   ERROR ${(e as Error).message.split('\n')[0].slice(0, 150)}`)
    fail++
  }
  console.log()
}

// ===================================================================================================
// THE ZAP: ETH in, ETH out, and the pair currency never moves in the trader's wallet
// ===================================================================================================
//
// Same discipline as above — every encoding is imported from `src/lib/zapTx.ts`, so this proves the
// panel's calldata rather than a second copy of it. The one thing it adds is a private key.
//
// Three claims are checked, and the third is the one the product lives on:
//   1. ether goes out and the launch token comes in, in ONE transaction
//   2. the trader's pair-currency balance does not move by a single wei, in either direction
//   3. the fee still lands in the Distributor, so holders can still be paid

// The tuple's components must be NAMED here. viem accepts an object for a named tuple and an
// array for an unnamed one, so an unnamed signature turns `poolKeyFor`'s object into
// `Address "undefined" is invalid` at encode time rather than anything that names the cause.
/** Far enough out that the live test never measures the deadline unless it means to. */
const DEADLINE = BigInt(Math.floor(Date.now() / 1000) + 3600)

const HOOK_ABI = parseAbi([
  'function totalFeesTaken(bytes32) view returns (uint256)',
  'function sweep((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key)',
])
const TOKEN_ABI = parseAbi(['function distributor() view returns (address)'])

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

/** v4's `PoolId` is `keccak256(abi.encode(key))`, and every field is static, so this is exact. */
function poolIdOf(k: {
  currency0: Address
  currency1: Address
  fee: number
  tickSpacing: number
  hooks: Address
}): `0x${string}` {
  return keccak256(encodeAbiParameters(POOL_KEY_PARAM, [k]))
}

/**
 * The quote entry points ALWAYS revert, carrying the answer in `ZapQuote(uint256)`. That is what
 * makes it impossible to use a quote call to execute a swap with no slippage floor, and it is why
 * quoting needs neither a balance nor an approval — the revert unwinds before anything settles.
 */
async function quote(fn: 'quoteZapBuy' | 'quoteZapSell', args: readonly unknown[]): Promise<bigint> {
  try {
    await pub.simulateContract({
      address: ZAP_ROUTER, abi: ZAP_ROUTER_ABI, functionName: fn, args: args as never, account,
    })
  } catch (e) {
    const raw = String((e as { cause?: { data?: unknown } })?.cause?.data ?? '')
    const m = /^0x[0-9a-f]{8}([0-9a-f]{64})$/i.exec(raw)
    if (m) return BigInt(`0x${m[1]}`)
    // viem may have already decoded it against the ABI.
    const decoded = (e as { cause?: { data?: { errorName?: string; args?: unknown[] } } })?.cause?.data
    if (decoded && typeof decoded === 'object' && decoded.errorName === 'ZapQuote') {
      return decoded.args?.[0] as bigint
    }
    throw e
  }
  throw new Error(`${fn} returned instead of reverting - deployed bytecode is not ZapRouter`)
}

/** Ether actually moved, with the gas the transaction itself burned added back in. */
async function ethMoved(before: bigint, hash: Hash): Promise<bigint> {
  const r = await pub.getTransactionReceipt({ hash })
  const gas = r.gasUsed * r.effectiveGasPrice
  const after = await pub.getBalance({ address: account.address })
  return after - before + gas
}

console.log('\n=== ZAP: ETH in / ETH out ===\n')

for (let i = 0n; i < count; i++) {
  const [token, , pair] = (await pub.readContract({
    address: launcher, abi: LAUNCHER, functionName: 'launches', args: [i],
  })) as [Address, Address, Address, bigint]

  const [tSym, pSym] = await Promise.all([
    pub.readContract({ address: token, abi: ERC20, functionName: 'symbol' }),
    pub.readContract({ address: pair, abi: ERC20, functionName: 'symbol' }),
  ])
  console.log(`── ${tSym} / ${pSym}`)

  const ethKey = ethPoolKeyFor(pair)
  if (!zapAvailable(pair) || !ethKey) {
    // Not a failure. There is genuinely no ETH/<pair> pool for these, and the panel says so
    // rather than offering a button that reverts.
    console.log(`   SKIP - no ETH/${pSym} pool on this network\n`)
    continue
  }

  const { key: tokenKey } = poolKeyFor(token, pair)
  const poolId = poolIdOf(tokenKey)
  const feeHook = DEPLOYMENTS.sepolia.feeHook as Address
  const distributor = await pub.readContract({
    address: token, abi: TOKEN_ABI, functionName: 'distributor',
  })

  try {
    // ---- BUY: pay ether, receive the launch token -----------------------------------------
    const spend = parseEther('0.002')
    const quoted = await quote('quoteZapBuy', [ethKey, tokenKey, spend])
    const minOut = (quoted * 9900n) / 10_000n // 1%, the panel's default

    const tokenBefore = await bal(token, account.address)
    const pairBefore = await bal(pair, account.address)
    const feesBefore = await pub.readContract({
      address: feeHook, abi: HOOK_ABI, functionName: 'totalFeesTaken', args: [poolId],
    })
    const ethBefore = await pub.getBalance({ address: account.address })

    const { request: buyReq } = await pub.simulateContract({
      address: ZAP_ROUTER, abi: ZAP_ROUTER_ABI, functionName: 'zapBuy',
      args: [ethKey, tokenKey, minOut, account.address, DEADLINE], value: spend, account,
    })
    const buyHash = await wallet.writeContract(buyReq)
    const buyReceipt = await pub.waitForTransactionReceipt({ hash: buyHash })

    const got = (await bal(token, account.address)) - tokenBefore
    const pairAfterBuy = await bal(pair, account.address)
    const ethDelta = await ethMoved(ethBefore, buyHash)

    if (buyReceipt.status === 'success' && got > 0n) {
      console.log(`   ZAP BUY  ok  -${formatEther(-ethDelta)} ETH  +${formatUnits(got, 18)} ${tSym}`)
      console.log(`      quoted ${formatUnits(quoted, 18)}, received ${formatUnits(got, 18)}`)
      console.log(`      tx ${buyHash}`)
      pass++
    } else {
      console.log(`   ZAP BUY  FAILED - status=${buyReceipt.status} received=${got}`)
      fail++
      continue
    }

    // THE CLAIM. Not "the buyer ended with little pair currency" — not one wei of it moved.
    if (pairAfterBuy === pairBefore) {
      console.log(`      the buyer's ${pSym} balance did not move at all`)
      pass++
    } else {
      console.log(`      FAILED - ${pSym} balance moved by ${pairAfterBuy - pairBefore}`)
      fail++
    }

    // ---- The fee still reaches the Distributor ---------------------------------------------
    // Fees accrue inside the swap as ERC-6909 claims and become real ERC-20 on a sweep, because a
    // single-sided pool holds no pair currency for `take()` to draw on.
    const charged = (await pub.readContract({
      address: feeHook, abi: HOOK_ABI, functionName: 'totalFeesTaken', args: [poolId],
    })) - feesBefore
    const distBefore = await bal(pair, distributor)
    const sweepHash = await wallet.writeContract({
      address: feeHook, abi: HOOK_ABI, functionName: 'sweep', args: [tokenKey],
    })
    await pub.waitForTransactionReceipt({ hash: sweepHash })
    const distDelta = (await bal(pair, distributor)) - distBefore

    if (charged > 0n && distDelta > 0n) {
      console.log(`      fee charged ${formatUnits(charged, 18)} ${pSym}; distributor +${formatUnits(distDelta, 18)} ${pSym}`)
      pass++
    } else {
      console.log(`      FAILED - fee=${charged} distributorDelta=${distDelta}`)
      fail++
    }

    // ---- SELL: pay the launch token, receive ether -----------------------------------------
    const sellAmt = got / 10n
    const allowance = await pub.readContract({
      address: token, abi: ERC20, functionName: 'allowance', args: [account.address, ZAP_ROUTER],
    })
    if (allowance < sellAmt) {
      const h = await wallet.writeContract({
        address: token, abi: ERC20, functionName: 'approve', args: [ZAP_ROUTER, sellAmt * 100n],
      })
      await pub.waitForTransactionReceipt({ hash: h })
    }

    const sellQuote = await quote('quoteZapSell', [ethKey, tokenKey, sellAmt])
    const pairBeforeSell = await bal(pair, account.address)
    const ethBeforeSell = await pub.getBalance({ address: account.address })

    const { request: sellReq } = await pub.simulateContract({
      address: ZAP_ROUTER, abi: ZAP_ROUTER_ABI, functionName: 'zapSell',
      args: [ethKey, tokenKey, sellAmt, (sellQuote * 9900n) / 10_000n, account.address, DEADLINE], account,
    })
    const sellHash = await wallet.writeContract(sellReq)
    const sellReceipt = await pub.waitForTransactionReceipt({ hash: sellHash })
    const backInEth = await ethMoved(ethBeforeSell, sellHash)
    const pairAfterSell = await bal(pair, account.address)

    if (sellReceipt.status === 'success' && backInEth > 0n && pairAfterSell === pairBeforeSell) {
      console.log(`   ZAP SELL ok  -${formatUnits(sellAmt, 18)} ${tSym}  +${formatEther(backInEth)} ETH`)
      console.log(`      ${pSym} balance still untouched`)
      console.log(`      tx ${sellHash}`)
      pass++
    } else {
      console.log(
        `   ZAP SELL FAILED - status=${sellReceipt.status} eth=${backInEth} pairMoved=${pairAfterSell - pairBeforeSell}`,
      )
      fail++
    }
  } catch (e) {
    console.log(`   ZAP ERROR ${(e as Error).message.split('\n')[0].slice(0, 200)}`)
    fail++
  }
  console.log()
}

console.log(`\n${pass} passed, ${fail} failed`)
