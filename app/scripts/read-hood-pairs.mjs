/**
 * Read name/symbol/decimals for every approved Robinhood pair, straight from the chain.
 *
 * The picker needs a display name and `networks.ts` only carries symbol/address/decimals. Names
 * are NOT invented here for exactly the reason this repo keeps relearning: on chain 4663 a symbol
 * identifies nothing - four separate contracts answer XMR/Monero, five answer WETH. The only
 * trustworthy name is the one the contract itself returns.
 *
 * Also re-verifies `decimals`, because USDG is 6 and cbBTC is 8, and a wrong value there misprices
 * an opening by a factor of 1e12.
 */
import { createPublicClient, http, erc20Abi } from 'viem'
import { readFileSync } from 'node:fs'

const RPC = 'https://rpc.mainnet.chain.robinhood.com'
const client = createPublicClient({ transport: http(RPC) })

const src = readFileSync('src/lib/networks.ts', 'utf8')
const dep = src.slice(src.indexOf('const ROBINHOOD_DEPLOYMENT'), src.indexOf('export const NETWORKS'))
const pairs = [...dep.matchAll(/symbol:\s*'([^']+)',\s*address:\s*'(0x[0-9a-fA-F]{40})',\s*decimals:\s*(\d+)/g)].map(
  (m) => ({ symbol: m[1], address: m[2], decimals: Number(m[3]) }),
)

console.log(`Reading ${pairs.length} pairs from Robinhood Chain.\n`)

const results = []
for (const p of pairs) {
  // Direct reads rather than multicall: Robinhood Chain has no multicall3 deployed at the
  // canonical address, and viem refuses to guess one. 90 reads is cheap and this runs once.
  const read = async (functionName) => {
    try {
      return { status: 'success', result: await client.readContract({ address: p.address, abi: erc20Abi, functionName }) }
    } catch {
      return { status: 'failure', result: null }
    }
  }
  const [name, symbol, decimals] = [await read('name'), await read('symbol'), await read('decimals')]

  const onChainDecimals = decimals.status === 'success' ? Number(decimals.result) : null
  const drift = onChainDecimals !== null && onChainDecimals !== p.decimals

  results.push({
    symbol: p.symbol,
    onChainSymbol: symbol.status === 'success' ? symbol.result : null,
    name: name.status === 'success' ? name.result : null,
    address: p.address,
    decimals: onChainDecimals ?? p.decimals,
    drift,
  })

  const flag = drift ? `  <-- DECIMALS DRIFT: file says ${p.decimals}, chain says ${onChainDecimals}` : ''
  console.log(
    `  ${p.symbol.padEnd(13)} ${String(onChainDecimals).padStart(2)}d  ${JSON.stringify(name.status === 'success' ? name.result : '?')}${flag}`,
  )
}

console.log('\n--- paste-ready `name:` additions ---\n')
for (const r of results) {
  console.log(`    ${r.symbol}: ${JSON.stringify(r.name ?? r.symbol)},`)
}

const drifted = results.filter((r) => r.drift)
console.log(`\n${drifted.length} decimals mismatch(es).`)
