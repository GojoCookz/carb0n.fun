/**
 * Screenshot the open pair picker so the logo grid can actually be looked at.
 *
 * Reports how many tiles resolved a real remote image versus the generated mark, because "24 of 30
 * have logos" is a claim about the network, not about what rendered.
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
await new Promise((r) => server.listen(4324, r))

mkdirSync('.shots', { recursive: true })
const browser = await chromium.launch()

for (const [name, w, h] of [
  ['logos-m', 430, 1000],
  ['logos-d', 1100, 1000],
]) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h } })
  await ctx.addInitScript(() => window.localStorage.setItem('carb0n.activeNetwork', 'robinhood'))
  const page = await ctx.newPage()
  await page.goto('http://localhost:4324/', { waitUntil: 'networkidle' })

  const custom = page.getByText('Custom', { exact: false }).first()
  if (await custom.count()) await custom.click().catch(() => {})
  await page.waitForTimeout(400)
  const change = page.getByRole('button', { name: /^Change$/ }).first()
  if (await change.count()) await change.click()

  // Remote images need time; the generated marks are instant.
  await page.waitForTimeout(6000)

  const counts = await page.evaluate(() => {
    const btns = [...document.querySelectorAll('button[aria-pressed]')]
    let img = 0
    let mark = 0
    let broken = 0
    for (const b of btns) {
      const i = b.querySelector('img')
      if (i) {
        if (i.naturalWidth > 0) img++
        else broken++
      } else if (b.querySelector('span[aria-hidden]')) mark++
    }
    return { total: btns.length, img, mark, broken }
  })

  await page.screenshot({ path: `.shots/${name}.png` })
  console.log(`  ${name.padEnd(10)} ${w}x${h}  tiles=${counts.total} realLogo=${counts.img} generatedMark=${counts.mark} broken=${counts.broken}`)
  await ctx.close()
}

await browser.close()
server.close()
