/**
 * Reproduce the reported bug, then prove it is gone.
 *
 * Picking XMR on Robinhood set `pairSymbol = 'XMR'`, the draft resolved it against the Ethereum
 * list, found nothing, and `PairPicker`'s `if (!selected) return null` erased the whole "What it
 * trades against" section. Choosing a currency deleted the chooser.
 *
 * This asserts the section still has content AFTER the pick, rather than just screenshotting it.
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
await new Promise((r) => server.listen(4325, r))

mkdirSync('.shots', { recursive: true })
const browser = await chromium.launch()
const ctx = await browser.newContext({ viewport: { width: 430, height: 1000 } })
await ctx.addInitScript(() => window.localStorage.setItem('carb0n.activeNetwork', 'robinhood'))
const page = await ctx.newPage()
const errs = []
page.on('pageerror', (e) => errs.push(e.message))

await page.goto('http://localhost:4325/', { waitUntil: 'networkidle' })

const custom = page.getByText('Custom', { exact: false }).first()
if (await custom.count()) await custom.click().catch(() => {})
await page.waitForTimeout(400)

const section = () =>
  page.evaluate(() => {
    const h = [...document.querySelectorAll('*')].find((e) =>
      e.textContent?.trim().startsWith('2 \u00b7 What it trades against'),
    )
    const host = h?.parentElement
    return {
      pickerButtons: document.querySelectorAll('button[aria-pressed]').length,
      changeBtn: !!document.querySelector('button'),
      sectionText: (host?.innerText ?? '').replace(/\s+/g, ' ').slice(0, 90),
    }
  })

const change = page.getByRole('button', { name: /^Change$/ }).first()
if (await change.count()) await change.click()
await page.waitForTimeout(500)

const beforePick = await section()
console.log(`  before pick: tiles=${beforePick.pickerButtons}`)

// The exact action that broke it.
const xmr = page.locator('button[aria-pressed]').filter({ hasText: 'XMR' }).first()
if (!(await xmr.count())) {
  console.log('  XMR TILE NOT FOUND')
  process.exit(1)
}
await xmr.click()
await page.waitForTimeout(900)

const afterPick = await page.evaluate(() => {
  const body = document.body.innerText
  const i = body.indexOf('2 \u00b7 What it trades against')
  const j = body.indexOf('3 \u00b7 When it graduates')
  const between = i >= 0 && j > i ? body.slice(i, j).replace(/\s+/g, ' ').trim() : ''
  return { between, len: between.length }
})

await page.screenshot({ path: '.shots/pick-xmr.png' })

console.log(`  after pick : section 2 content = ${JSON.stringify(afterPick.between.slice(0, 100))}`)
console.log(`  section length = ${afterPick.len}`)
console.log(errs.length ? `  PAGE ERRORS: ${[...new Set(errs)].slice(0, 3).join(' | ')}` : '  no page errors')

// The bug was an EMPTY section. Anything under ~40 chars is just the heading.
const ok = afterPick.len > 40
console.log(ok ? '\n  PASS - section still rendered after picking XMR' : '\n  FAIL - section is empty, bug still present')

await browser.close()
server.close()
process.exit(ok ? 0 : 1)
