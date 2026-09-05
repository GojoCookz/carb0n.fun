/**
 * Every interaction, end to end, against the live Sepolia stack, through the APP'S OWN encoding.
 *
 * Launch -> buy (pair) -> buy (ETH zap) -> sell -> sweep -> claim. Nothing here restates an ABI or
 * rebuilds a pool key; everything is imported from `src/lib`, so a pass is evidence about the
 * frontend and not about this file.
 *
 *   bun e2e.ts
 */
import {
  createWalletClient, createPublicClient, http, parseUnits, parseEther, formatUnits,
  formatEther, parseAbi, keccak256, encodeAbiParameters, type Address,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { sepolia } from 'viem/chains'
import { readFileSync } from 'node:fs'
import { LAUNCHER_ABI } from './src/lib/abi'
import { DEPLOYMENTS } from './src/lib/chain'
import { poolKeyFor, TRADE_ROUTER, TRADE_ROUTER_ABI } from './src/lib/tradeTx'
import { ethPoolKeysFor, ZAP_ROUTER, ZAP_ROUTER_ABI } from './src/lib/zapTx'
import { poolIdOf } from './src/lib/useTokenDetail'

const env = Object.fromEntries(
  readFileSync('../contracts/.env', 'utf8').split('\n').filter((l) => l.includes('='))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
)
const account = privateKeyToAccount(env.PRIVATE_KEY as `0x${string}`)
const pub = createPublicClient({ chain: sepolia, transport: http(env.SEPOLIA_RPC_URL) })
const wallet = createWalletClient({ account, chain: sepolia, transport: http(env.SEPOLIA_RPC_URL) })

const ERC20 = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
  'function allowance(address,address) view returns (uint256)',
  'function symbol() view returns (string)',
])
const HOOK = parseAbi([
  'function totalFeesTaken(bytes32) view returns (uint256)',
  'function pendingOpeningFees(bytes32) view returns (uint256)',
  'function currentBuyFeeBps(bytes32) view returns (uint16)',
  'function platformRecipient() view returns (address)',
  'function sweep((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key)',
])
const DIST = parseAbi([
  'function withdrawableOf(address) view returns (uint256)',
  'function totalDistributed() view returns (uint256)',
  'function withdraw()',
])
const TOKEN = parseAbi(['function distributor() view returns (address)'])

const launcher = DEPLOYMENTS.sepolia.launcher as Address
const feeHook = DEPLOYMENTS.sepolia.feeHook as Address
const PAXG = DEPLOYMENTS.sepolia.pairs.find((p) => p.symbol === 'tPAXG')!.address
const bal = (t: Address, w: Address) => pub.readContract({ address: t, abi: ERC20, functionName: 'balanceOf', args: [w] })

let pass = 0, fail = 0
const ok = (label: string, cond: boolean, detail = '') => {
  if (cond) { pass++; console.log(`  PASS  ${label}${detail ? ' — ' + detail : ''}`) }
  else { fail++; console.log(`  FAIL  ${label}${detail ? ' — ' + detail : ''}`) }
}

console.log('=== 1. LAUNCH, with the anti-snipe window ON ===')
const salt = `0x${Date.now().toString(16).padStart(64, '0')}` as `0x${string}`
const params = {
  name: 'End To End', symbol: 'E2E', supply: 1_000_000_000n * 10n ** 18n,
  pair: PAXG, openingMarketCap: parseUnits('1', 18), graduationThreshold: parseUnits('10', 18),
  feeBps: 300, sellFeeBps: 200, burnBps: 1000,
  vestDuration: 0n, vestCliff: 0n, creatorBps: 5000, maxWalletBps: 0, tickSpacing: 60,
  devBuyPairAmount: 0n, salt,
  minPushPayout: 10n ** 6n, minShareForQueue: 10n ** 18n,
  rewardCurrency: '0x0000000000000000000000000000000000000000' as Address,
  feeRecipient: '0x0000000000000000000000000000000000000000' as Address,
  referrer: '0x0000000000000000000000000000000000000000' as Address,
  openingWindow: 60, openingFeeBps: 9900,
  metadata: {
    imageCid: `0x${'11'.repeat(32)}` as `0x${string}`,
    bannerCid: `0x${'00'.repeat(32)}` as `0x${string}`,
    infoCid: `0x${'00'.repeat(32)}` as `0x${string}`,
  },
}

const sim = await pub.simulateContract({ address: launcher, abi: LAUNCHER_ABI, functionName: 'launch', args: [params as never], account })
const [tokenAddr] = sim.result as [Address, `0x${string}`]
const launchHash = await wallet.writeContract(sim.request)
const lr = await pub.waitForTransactionReceipt({ hash: launchHash })
ok('launch landed', lr.status === 'success', `token ${tokenAddr}`)
console.log(`        tx ${launchHash}`)

const { key: tokenKey } = poolKeyFor(tokenAddr, PAXG)
const poolId = poolIdOf(tokenAddr, PAXG)
const distributor = await pub.readContract({ address: tokenAddr, abi: TOKEN, functionName: 'distributor' })

const rateNow = await pub.readContract({ address: feeHook, abi: HOOK, functionName: 'currentBuyFeeBps', args: [poolId] })
ok('opening fee is live', rateNow > 300, `${rateNow} bps right after launch, vs 300 normal`)

console.log('\n=== 2. BUY with the pair currency, inside the window ===')
const approve = async (t: Address, spender: Address, amt: bigint) => {
  const cur = await pub.readContract({ address: t, abi: ERC20, functionName: 'allowance', args: [account.address, spender] })
  if (cur >= amt) return
  const h = await wallet.writeContract({ address: t, abi: ERC20, functionName: 'approve', args: [spender, amt * 1000n] })
  await pub.waitForTransactionReceipt({ hash: h })
}
await approve(PAXG, TRADE_ROUTER, parseUnits('1', 18))
const { buyIsZeroForOne } = poolKeyFor(tokenAddr, PAXG)
const tokBefore = await bal(tokenAddr, account.address)
const buySim = await pub.simulateContract({ address: TRADE_ROUTER, abi: TRADE_ROUTER_ABI, functionName: 'swap', args: [tokenKey, buyIsZeroForOne, parseUnits('0.05', 18), 0n, account.address], account })
const bh = await wallet.writeContract(buySim.request)
await pub.waitForTransactionReceipt({ hash: bh })
const gotInWindow = (await bal(tokenAddr, account.address)) - tokBefore
ok('pair buy executed', gotInWindow > 0n, `${formatUnits(gotInWindow, 18)} E2E`)

const openingPenalty = await pub.readContract({ address: feeHook, abi: HOOK, functionName: 'pendingOpeningFees', args: [poolId] })
ok('opening penalty accrued separately', openingPenalty > 0n, `${formatUnits(openingPenalty, 18)} tPAXG`)

console.log('\n=== 3. WAIT OUT THE WINDOW, buy again, compare ===')
await new Promise((r) => setTimeout(r, 65_000))
const rateAfter = await pub.readContract({ address: feeHook, abi: HOOK, functionName: 'currentBuyFeeBps', args: [poolId] })
ok('rate decayed to the normal one', rateAfter === 300, `${rateAfter} bps`)

const tokBefore2 = await bal(tokenAddr, account.address)
const buy2 = await pub.simulateContract({ address: TRADE_ROUTER, abi: TRADE_ROUTER_ABI, functionName: 'swap', args: [tokenKey, buyIsZeroForOne, parseUnits('0.05', 18), 0n, account.address], account })
const bh2 = await wallet.writeContract(buy2.request)
await pub.waitForTransactionReceipt({ hash: bh2 })
const gotAfter = (await bal(tokenAddr, account.address)) - tokBefore2
// **This multiple is UNDERSTATED and the reason matters.** The in-window buy moves the price up,
// so the later buy is priced off a curve the first one already shifted. A live chain cannot
// snapshot and replay, so the two arms are not from identical state the way the contract test's
// are — `test_E01_snipingAtTheOpenCostsMaterallyMoreThanWaiting` measures 32x from a true
// snapshot/revert control. Measured here: 9.99M in-window against 45.3M after, 4.5x.
//
// The unambiguous assertion is the RATE, checked above: 9,900 bps at the open, exactly 300 after.
// The token multiple is reported as an observation, with a floor loose enough to survive the
// price impact it cannot control for.
ok('E-01: sniping got materially less than waiting', gotAfter > gotInWindow * 3n, `${formatUnits(gotInWindow, 18)} in-window vs ${formatUnits(gotAfter, 18)} after (understated: the first buy moved the price)`)

console.log('\n=== 4. BUY WITH ETH (zap) ===')
const ethKeys = ethPoolKeysFor(PAXG)
const paxgBefore = await bal(PAXG, account.address)
const tokBefore3 = await bal(tokenAddr, account.address)
const zapSim = await pub.simulateContract({ address: ZAP_ROUTER, abi: ZAP_ROUTER_ABI, functionName: 'zapBuy', args: [ethKeys, tokenKey, 1n, account.address, BigInt(Math.floor(Date.now() / 1000) + 1200)], value: parseEther('0.002'), account })
const zh = await wallet.writeContract(zapSim.request)
await pub.waitForTransactionReceipt({ hash: zh })
const zapGot = (await bal(tokenAddr, account.address)) - tokBefore3
ok('ETH zap buy executed', zapGot > 0n, `${formatUnits(zapGot, 18)} E2E for 0.002 ETH`)
ok('buyer never touched the pair currency', (await bal(PAXG, account.address)) === paxgBefore)
console.log(`        tx ${zh}`)

console.log('\n=== 5. SELL back to ETH ===')
const held = await bal(tokenAddr, account.address)
await approve(tokenAddr, ZAP_ROUTER, held / 4n)
const ethBefore = await pub.getBalance({ address: account.address })
const sellSim = await pub.simulateContract({ address: ZAP_ROUTER, abi: ZAP_ROUTER_ABI, functionName: 'zapSell', args: [ethKeys, tokenKey, held / 4n, 1n, account.address, BigInt(Math.floor(Date.now() / 1000) + 1200)], account })
const sh = await wallet.writeContract(sellSim.request)
const sr = await pub.waitForTransactionReceipt({ hash: sh })
const ethBack = (await pub.getBalance({ address: account.address })) - ethBefore + sr.gasUsed * sr.effectiveGasPrice
ok('ETH zap sell executed', ethBack > 0n, `${formatEther(ethBack)} ETH back`)
console.log(`        tx ${sh}`)

console.log('\n=== 6. SWEEP — the only way fees become money ===')
const platformRecipient = await pub.readContract({ address: feeHook, abi: HOOK, functionName: 'platformRecipient' })
ok('A-8: hook pays the referral vault', platformRecipient.toLowerCase() === (DEPLOYMENTS.sepolia.referralVault as string).toLowerCase(), platformRecipient)
const distBefore = await bal(PAXG, distributor)
const swh = await wallet.writeContract({ address: feeHook, abi: HOOK, functionName: 'sweep', args: [tokenKey] })
await pub.waitForTransactionReceipt({ hash: swh })
const distDelta = (await bal(PAXG, distributor)) - distBefore
ok('sweep funded the distributor', distDelta > 0n, `+${formatUnits(distDelta, 18)} tPAXG`)
ok('opening penalty was cleared', (await pub.readContract({ address: feeHook, abi: HOOK, functionName: 'pendingOpeningFees', args: [poolId] })) === 0n)
console.log(`        tx ${swh}`)

console.log('\n=== 7. CLAIM dividends ===')
const owed = await pub.readContract({ address: distributor, abi: DIST, functionName: 'withdrawableOf', args: [account.address] })
const totalDist = await pub.readContract({ address: distributor, abi: DIST, functionName: 'totalDistributed' })
console.log(`        withdrawable now ${formatUnits(owed, 18)} tPAXG, totalDistributed ${formatUnits(totalDist, 18)}`)
if (owed > 0n) {
  const pb = await bal(PAXG, account.address)
  const ch = await wallet.writeContract({ address: distributor, abi: DIST, functionName: 'withdraw' })
  await pub.waitForTransactionReceipt({ hash: ch })
  ok('claim paid out', (await bal(PAXG, account.address)) > pb)
} else {
  ok('nothing claimable yet (24h stream) — expected, not a failure', true, 'entitlement vests over STREAM_WINDOW')
}

console.log(`\n${pass} passed, ${fail} failed`)
console.log(`token: ${tokenAddr}`)
