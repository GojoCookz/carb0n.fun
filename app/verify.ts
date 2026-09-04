/**
 * Every address on the allowlist must be a live ERC-20 whose symbol and decimals match what we
 * claim. A pair list is an ADDRESS allowlist; a wrong entry there is not a typo, it points a
 * launch at the wrong asset permanently.
 */
import { createPublicClient, http, fallback, parseAbi } from 'viem'
import { mainnet } from 'viem/chains'
import { PAIRS } from './src/lib/pairs'

const client = createPublicClient({
  chain: mainnet,
  transport: fallback([
    http('https://eth.merkle.io'),
    http('https://eth-pokt.nodies.app'),
    http('https://ethereum-rpc.publicnode.com'),
  ]),
})
const erc20 = parseAbi([
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
])

let bad = 0
for (const p of PAIRS) {
  try {
    const [sym, dec] = await Promise.all([
      client.readContract({ address: p.address, abi: erc20, functionName: 'symbol' }),
      client.readContract({ address: p.address, abi: erc20, functionName: 'decimals' }),
    ])
    const decOk = Number(dec) === p.decimals
    // Symbols legitimately differ in case (XAUt vs XAUT, Mog vs MOG), so compare case-insensitively.
    const symOk = String(sym).toLowerCase() === p.symbol.toLowerCase()
    if (!decOk || !symOk) {
      bad++
      console.log(`MISMATCH ${p.symbol.padEnd(8)} chain says symbol=${sym} decimals=${dec}`)
    }
  } catch (e) {
    bad++
    console.log(`UNREADABLE ${p.symbol.padEnd(8)} ${p.address} ${(e as Error).message.slice(0, 60)}`)
  }
}
console.log(bad === 0 ? `OK all ${PAIRS.length} pairs verified on mainnet` : `${bad} PROBLEM(S)`)
