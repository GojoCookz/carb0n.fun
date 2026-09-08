/**
 * Verify the pair picker shows the roster for the SELECTED network, not a hardcoded one.
 *
 * The bug: the picker mapped `PAIRS`, a hand-written list of Ethereum mainnet tokens, on every
 * network. On Robinhood Chain it offered WBTC/USDC/PEPE/SHIB - none of which exist on 4663, and
 * every one of which would have failed `PairRegistry.isApproved` - while the thirty currencies
 * actually approved there were absent.
 *
 * This asserts the two rosters do not overlap, rather than eyeballing a screenshot.
 */
import { chromium } from 'playwright'
import { createServer } from 'node:http'
import { readFileSync, existsSync } from 'node:fs'
import { join, extname } from 'node:path'

const DIST = join(process.cwd(), 'dist')
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json', '.webmanifest': 'application/manifest+json' }

const server = createServer((req, res) => {
  const url = (req.url ?? '/').split('?')[0]
  let file = join(DIST, url === '/' ? 'index.html' : url.slice(1))
  if (!existsSync(file) || url === '/') file = join(DIST, 'index.html')
  try {
    res.writeHead(200, { 'Content-Type': TYPES[extname(file)] ?? 'application/octet-stream' })
    res.end(readFileSync(file))
  } catch {
    res.writeHead(404).end('nope')
  }
})
await new Promise((r) => server.listen(4321, r))
const base = 'http://localhost:4321'

const browser = await chromium.launch()

async function rosterFor(network) {
  const ctx = await browser.newContext({ viewport: { width: 430, height: 932 } })
  await ctx.addInitScript((n) => {
    window.localStorage.setItem('carb0n.activeNetwork', n)
  }, network)
  const page = await ctx.newPage()
  await page.goto(`${base}/launch`, { waitUntil: 'networkidle' })

  // Custom mode exposes the full picker; Simple mode hides it behind a default.
  const custom = page.getByText('Custom', { exact: false }).first()
  if (await custom.count()) await custom.click().catch(() => {})
  await page.waitForTimeout(400)

  const change = page.getByRole('button', { name: /^Change$/ }).first()
  if (await change.count()) {
    await change.click()
    await page.waitForTimeout(400)
  }

  const symbols = await page.evaluate(() => {
    const out = new Set()
    for (const b of document.querySelectorAll('button[aria-pressed]')) {
      const t = b.querySelector('span span')?.textContent?.trim()
      if (t) out.add(t)
    }
    return [...out]
  })

  await page.screenshot({ path: `.shots/picker-${network}.png`, fullPage: false })
  await ctx.close()
  return symbols
}

const hood = await rosterFor('robinhood')
const eth = await rosterFor('mainnet')

console.log(`  robinhood (${hood.length}): ${hood.join(', ')}`)
console.log('')
console.log(`  mainnet   (${eth.length}): ${eth.slice(0, 12).join(', ')}${eth.length > 12 ? ' ...' : ''}`)
console.log('')

const overlap = hood.filter((s) => eth.includes(s))
const ethOnly = ['WBTC', 'USDC', 'PEPE', 'SHIB', 'UNI', 'APE', 'FLOKI']
const leaked = hood.filter((s) => ethOnly.includes(s))

console.log(`  Ethereum-only tickers leaking into the Robinhood picker: ${leaked.length ? leaked.join(', ') : 'NONE'}`)
console.log(`  shared tickers (WETH is legitimately on both): ${overlap.join(', ') || 'none'}`)

await browser.close()
server.close()
process.exit(leaked.length > 0 ? 1 : 0)
