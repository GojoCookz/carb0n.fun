/**
 * Find a real logo source for the thirty Robinhood pair currencies.
 *
 * `logoUrl` builds a DexScreener path hardcoded to `tokens/ethereum/<address>`, so every Robinhood
 * address 404s and every tile falls back to two grey initials. Before inventing artwork, check
 * what actually exists: Blockscout carries an `icon_url` field per token, and DexScreener has a
 * `robinhood` path if it indexes the chain at all.
 *
 * Nothing here generates an image. It reports which sources answer, so the fix can point at a real
 * one rather than guessing.
 */
import { readFileSync } from 'node:fs'

const src = readFileSync('src/lib/networks.ts', 'utf8')
const dep = src.slice(src.indexOf('const ROBINHOOD_DEPLOYMENT'), src.indexOf('export const NETWORKS'))
const pairs = [...dep.matchAll(/symbol:\s*'([^']+)',\s*name:\s*'([^']*)',\s*address:\s*'(0x[0-9a-fA-F]{40})'/g)].map(
  (m) => ({ symbol: m[1], name: m[2], address: m[3] }),
)

console.log(`Probing ${pairs.length} pairs.\n`)

const timeout = (ms) => new AbortController.prototype.constructor && AbortSignal.timeout(ms)

async function head(url) {
  try {
    const r = await fetch(url, { method: 'GET', signal: AbortSignal.timeout(12000) })
    return r.ok ? r.status : 0
  } catch {
    return 0
  }
}

let blockscoutHits = 0
let dexHits = 0
const rows = []

for (const p of pairs) {
  let icon = ''
  try {
    const r = await fetch(
      `https://robinhoodchain.blockscout.com/api/v2/tokens/${p.address}`,
      { signal: AbortSignal.timeout(12000) },
    )
    if (r.ok) {
      const j = await r.json()
      icon = j.icon_url || ''
    }
  } catch {
    /* keep going; one bad response must not end the sweep */
  }

  const dex = await head(
    `https://dd.dexscreener.com/ds-data/tokens/robinhood/${p.address.toLowerCase()}.png`,
  )

  if (icon) blockscoutHits++
  if (dex) dexHits++
  rows.push({ ...p, icon, dex })
  console.log(
    `  ${p.symbol.padEnd(13)} blockscout=${icon ? 'YES' : '-'.padEnd(3)} dexscreener=${dex || '-'}`,
  )
}

console.log(`\n  blockscout icons : ${blockscoutHits}/${pairs.length}`)
console.log(`  dexscreener      : ${dexHits}/${pairs.length}`)
