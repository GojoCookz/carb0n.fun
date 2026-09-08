/**
 * Screenshot the Robinhood theme on a real engine, mobile first.
 *
 * Playwright's own bundled Chromium - never the user's Chrome or profile.
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
await new Promise((r) => server.listen(4322, r))
const base = 'http://localhost:4322'

mkdirSync('.shots', { recursive: true })
const browser = await chromium.launch()

async function shot(name, path, width, height, network = 'robinhood') {
  const ctx = await browser.newContext({ viewport: { width, height } })
  await ctx.addInitScript((n) => window.localStorage.setItem('carb0n.activeNetwork', n), network)
  const page = await ctx.newPage()
  const errs = []
  page.on('pageerror', (e) => errs.push(e.message))
  await page.goto(base + path, { waitUntil: 'networkidle' })
  // Let the leaf canvas actually put something on screen before capturing.
  await page.waitForTimeout(1200)

  const diag = await page.evaluate(() => {
    const html = document.documentElement
    const cs = getComputedStyle(html)
    const canvas = document.querySelector('[data-leaf-field] canvas')
    return {
      network: html.getAttribute('data-network'),
      ink950: cs.getPropertyValue('--color-ink-950').trim(),
      steel400: cs.getPropertyValue('--color-steel-400').trim(),
      gold400: cs.getPropertyValue('--color-gold-400').trim(),
      hasGradient: cs.backgroundImage !== 'none',
      canvas: canvas ? `${canvas.width}x${canvas.height}` : 'ABSENT',
    }
  })

  await page.screenshot({ path: `.shots/${name}.png` })
  console.log(`  ${name.padEnd(22)} ${String(width).padStart(4)}x${height}  net=${diag.network} ink=${diag.ink950} emerald=${diag.steel400} gold=${diag.gold400} grad=${diag.hasGradient} canvas=${diag.canvas}`)
  if (errs.length) console.log(`      PAGE ERRORS: ${[...new Set(errs)].slice(0, 3).join(' | ')}`)
  await ctx.close()
}

await shot('hood-launch-m', '/', 390, 844)
await shot('hood-board-m', '/board', 390, 844)
await shot('hood-launch-d', '/', 1280, 900)
await shot('eth-launch-m', '/', 390, 844, 'mainnet')

await browser.close()
server.close()
