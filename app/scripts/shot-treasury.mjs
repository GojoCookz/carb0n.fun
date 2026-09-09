/**
 * Prove the treasury panel is gated.
 *
 * Two runs against the same build: one with a stub wallet reporting the TREASURY address, one
 * reporting a stranger. The panel must appear in the first and be completely absent in the second.
 * Checking only the happy path would pass even if the gate were missing entirely.
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
await new Promise((r) => server.listen(4326, r))

mkdirSync('.shots', { recursive: true })
const browser = await chromium.launch()

const TREASURY = '0xeFd515Fc021f281f12Da5dF64cAafF9Aa3077868'
const STRANGER = '0x1111111111111111111111111111111111111111'

async function run(label, who) {
  const ctx = await browser.newContext({ viewport: { width: 900, height: 1000 } })
  await ctx.addInitScript((addr) => {
    window.localStorage.setItem('carb0n.activeNetwork', 'robinhood')
    // Minimal EIP-1193 stub: enough for the app to believe a wallet is connected.
    window.ethereum = {
      request: async ({ method }) => {
        if (method === 'eth_accounts' || method === 'eth_requestAccounts') return [addr]
        if (method === 'eth_chainId') return '0x1237'
        return null
      },
      on: () => {},
      removeListener: () => {},
    }
  }, who)

  const page = await ctx.newPage()
  await page.goto('http://localhost:4326/about', { waitUntil: 'networkidle' })
  await page.waitForTimeout(7000)
  await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight))
  await page.waitForTimeout(1500)

  const found = await page.evaluate(() => document.body.innerText.includes('Platform revenue'))
  await page.screenshot({ path: `.shots/treasury-${label}.png`, fullPage: false })
  console.log(`  ${label.padEnd(10)} ${who.slice(0, 10)}...  panel visible: ${found}`)
  await ctx.close()
  return found
}

const asOwner = await run('owner', TREASURY)
const asStranger = await run('stranger', STRANGER)

console.log('')
const ok = asOwner && !asStranger
console.log(ok ? '  PASS - visible to the treasury, absent for everyone else' : '  FAIL - gate is wrong')

await browser.close()
server.close()
process.exit(ok ? 0 : 1)
