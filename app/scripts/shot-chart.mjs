/**
 * Render the real HOOD1 token page and screenshot the chart.
 *
 * Hits the live Robinhood RPC, so this proves the whole path: getLogs against the PoolManager,
 * sqrtPriceX96 decoded, ordering and decimals applied, and something drawn.
 */
import { chromium } from 'playwright'
import { createServer } from 'node:http'
import { readFileSync, existsSync, mkdirSync } from 'node:fs'
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
await new Promise((r) => server.listen(4323, r))

mkdirSync('.shots', { recursive: true })
const browser = await chromium.launch()
// TESTCAT - the current test launch, paired against CASHCAT.
const HOOD1 = '0xe5be828144498E945E55DeE62C5cCc0B4180ac18'

for (const [name, w, h] of [
  ['chart-m', 390, 900],
  ['chart-d', 1280, 900],
]) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h } })
  await ctx.addInitScript(() => window.localStorage.setItem('carb0n.activeNetwork', 'robinhood'))
  const page = await ctx.newPage()
  const errs = []
  page.on('pageerror', (e) => errs.push(e.message))

  await page.goto(`http://localhost:4323/t/${HOOD1}`, { waitUntil: 'networkidle' })
  // Log queries against a live RPC are slower than the page.
  await page.waitForTimeout(9000)

  const state = await page.evaluate(() => {
    const txt = document.body.innerText
    return {
      noTrades: txt.includes('No trades yet'),
      oneTrade: txt.includes('One trade so far'),
      tradeCount: (txt.match(/(\d+) trades/) || [])[1] ?? null,
      hasPath: !!document.querySelector('svg path[stroke-width="2"]'),
      dots: document.querySelectorAll('svg circle').length,
    }
  })

  await page.screenshot({ path: `.shots/${name}.png`, fullPage: false })
  console.log(`  ${name.padEnd(10)} ${w}x${h}  trades=${state.tradeCount} line=${state.hasPath} points=${state.dots} noTrades=${state.noTrades} oneTrade=${state.oneTrade}`)
  if (errs.length) console.log(`      ERRORS: ${[...new Set(errs)].slice(0, 2).join(' | ')}`)
  await ctx.close()
}

await browser.close()
server.close()
