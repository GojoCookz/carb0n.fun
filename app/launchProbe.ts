/**
 * Can the app's CURRENT encoding still reach the DEPLOYED launcher?
 *
 * `LaunchParams` gained `openingWindow` and `openingFeeBps` today. Solidity encodes a struct
 * argument into the function selector, so adding a field changes the selector — the deployed
 * launcher cannot accept a call from this build, and the launch button would revert on every
 * attempt. This repo has been bitten by exactly that before.
 *
 * Simulating the app's own encoded calldata against the live contract is the only thing that
 * settles it. `bun launchProbe.ts`
 */
import { createPublicClient, http, toFunctionSelector, encodeFunctionData, type Address } from 'viem'
import { sepolia } from 'viem/chains'
import { readFileSync } from 'node:fs'
import { LAUNCHER_ABI, LAUNCH_PARAMS_COMPONENTS } from './src/lib/abi'
import { DEPLOYMENTS } from './src/lib/chain'

const env = Object.fromEntries(
  readFileSync('../contracts/.env', 'utf8')
    .split('\n')
    .filter((l) => l.includes('='))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
)
const pub = createPublicClient({ chain: sepolia, transport: http(env.SEPOLIA_RPC_URL) })
const launcher = DEPLOYMENTS.sepolia.launcher as Address

const tuple = `(${LAUNCH_PARAMS_COMPONENTS.map(function f(c: any): string {
  return c.type === 'tuple' ? `(${c.components.map(f).join(',')})` : c.type
}).join(',')})`

const sig = `launch(${tuple})`
console.log('this build encodes :', sig)
console.log('selector           :', toFunctionSelector(sig))
console.log('field count        :', LAUNCH_PARAMS_COMPONENTS.length)

const code = await pub.getCode({ address: launcher })
console.log('\ndeployed launcher  :', launcher)
console.log('code bytes         :', code ? (code.length - 2) / 2 : 0)

// Does the DEPLOYED bytecode contain this selector at all? A selector that appears nowhere in the
// dispatch table cannot be reached, no matter what arguments are supplied.
const sel = toFunctionSelector(sig).slice(2)
console.log('selector present in deployed code:', code?.includes(sel) ?? false)

// And the definitive test: simulate the app's real calldata.
const params = {
  name: 'Probe', symbol: 'PROBE', supply: 1_000_000_000n * 10n ** 18n,
  pair: DEPLOYMENTS.sepolia.pairs[0].address, openingMarketCap: 10n ** 18n,
  graduationThreshold: 10n ** 19n, feeBps: 300, sellFeeBps: 0, burnBps: 0,
  vestDuration: 0n, vestCliff: 0n, creatorBps: 2000, maxWalletBps: 0, tickSpacing: 60,
  devBuyPairAmount: 0n, salt: `0x${'11'.repeat(32)}` as `0x${string}`,
  minPushPayout: 10n ** 6n, minShareForQueue: 10n ** 18n,
  rewardCurrency: '0x0000000000000000000000000000000000000000' as Address,
  feeRecipient: '0x0000000000000000000000000000000000000000' as Address,
  referrer: '0x0000000000000000000000000000000000000000' as Address,
  openingWindow: 20, openingFeeBps: 9900,
  metadata: { imageCid: `0x${'22'.repeat(32)}` as `0x${string}`, bannerCid: `0x${'00'.repeat(32)}` as `0x${string}`, infoCid: `0x${'00'.repeat(32)}` as `0x${string}` },
}

console.log('\ncalldata length    :', (encodeFunctionData({ abi: LAUNCHER_ABI, functionName: 'launch', args: [params as never] }).length - 10) / 2, 'bytes of args')

try {
  await pub.simulateContract({
    address: launcher, abi: LAUNCHER_ABI, functionName: 'launch', args: [params as never],
    account: '0xc286b1956c7691d678520e370727D8aB57328556',
  })
  console.log('\nRESULT: the deployed launcher ACCEPTED this build\u2019s encoding.')
} catch (e) {
  const m = (e as Error).message.split('\n').slice(0, 4).join(' | ')
  console.log('\nRESULT: REVERTED ->', m.slice(0, 400))
}
