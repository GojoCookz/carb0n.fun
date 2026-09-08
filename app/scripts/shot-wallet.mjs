/**
 * Screenshot the wallet button in the states that matter, on a real rendering engine.
 *
 * Launches Playwright's OWN bundled Chromium - not the user's Chrome, and not their profile - so
 * nothing here can touch an installed extension or a wallet vault.
 *
 * Headless Chromium has no injected provider, which makes it exactly the case worth checking:
 * it is what a phone browser looks like to this code. Before this change that path rendered
 * "Get a wallet" and dead-ended.
 */
import { chromium } from 'playwright'
import { createServer } from 'node:http'
import { readFileSync, existsSync } from 'node:fs'
import { join, extname } from 'node:path'

const DIST = join(process.cwd(), 'dist')
const TYPES = {
  '.html': 'text/html',
  '.js': 'text/javascript',
  '.css': 'text/css',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.json': 'application/json',
  '.webmanifest': 'application/manifest+json',
}

// Static server with SPA fallback, mirroring the rewrite in vercel.json.
const server = createServer((req, res) => {
  const url = (req.url ?? '/').split('?')[0]
  let file = join(DIST, url === '/' ? 'index.html' : url.slice(1))
  if (!existsSync(file) || url === '/') file = join(DIST, 'index.html')
  try {
    const body = readFileSync(file)
    res.writeHead(200, { 'Content-Type': TYPES[extname(file)] ?? 'application/octet-stream' })
    res.end(body)
  } catch {
    res.writeHead(404).end('not found')
  }
})

await new Promise((r) => server.listen(4319, r))
const base = 'http://localhost:4319'

const browser = await chromium.launch()
const errors = []

async function shot(name, width, height, prep) {
  const ctx = await browser.newContext({ viewport: { width, height } })
  const page = await ctx.newPage()
  page.on('pageerror', (e) => errors.push(`${name}: ${e.message}`))
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(`${name} console: ${m.text().slice(0, 160)}`)
  })
  await page.goto(base, { waitUntil: 'networkidle' })
  if (prep) await prep(page)
  await page.screenshot({ path: `.shots/${name}.png` })
  // Report what the wallet control actually says, so the check does not depend on my reading a PNG.
  const label = await page
    .locator('header button, header a')
    .filter({ hasText: /wallet|connect|switch|0x/i })
    .first()
    .textContent()
    .catch(() => null)
  console.log(`  ${name.padEnd(26)} ${width}x${height}  control: ${JSON.stringify(label)}`)
  await ctx.close()
}

await shot('wallet-mobile', 390, 844)
await shot('wallet-desktop', 1280, 800)

// The mobile connect path: no injected provider, so this must go straight to WalletConnect.
await shot('wallet-mobile-clicked', 390, 844, async (page) => {
  const btn = page.locator('header button').filter({ hasText: /connect/i }).first()
  if (await btn.count()) {
    await btn.click()
    await page.waitForTimeout(3500)
  }
})

console.log('')
console.log(errors.length ? '  PAGE ERRORS:' : '  no page errors')
for (const e of [...new Set(errors)].slice(0, 10)) console.log(`    ${e}`)

await browser.close()
server.close()
