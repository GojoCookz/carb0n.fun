/**
 * NO TOKENISED SECURITIES IN THE PAIR ROSTER. Enforced, not remembered.
 *
 *   bun pairPolicy.ts
 *
 * The standing instruction is to stay away from tokenised equities entirely rather than argue
 * where the line is. Counsel's position is that revenue sharing on its own is not the issue and
 * tokenised STOCKS are; the product decision that follows is that this pad never touches them.
 *
 * A comment beside a list does not survive somebody adding "just one" RWA pair six months from
 * now. This does: it fails loudly, it runs in CI, and it checks the roster against how tokenised
 * equities are ACTUALLY named and issued rather than against a vibe.
 *
 * **What this can and cannot do.** It catches the known issuers and the naming conventions they
 * use. It cannot recognise a tokenised share nobody has told it about, and it is not a substitute
 * for reading what a token is before adding it. A pass means "nothing known-bad is in the list",
 * never "everything in the list is fine".
 */
import { PAIRS } from './src/lib/pairs'

/**
 * How tokenised equities are actually named on chain. Each of these is a real, live convention.
 *
 * The `on` suffix is Ondo's (`NVDAon`, `TSLAon`, `SPYon`) and is the one that matters most right
 * now — stockereum.com's entire quote list is built from them, which is exactly the product we are
 * deliberately not building.
 */
const EQUITY_NAMING: ReadonlyArray<{ pattern: RegExp; issuer: string }> = [
  { pattern: /^[A-Z]{1,6}on$/, issuer: 'Ondo tokenised equities (NVDAon, TSLAon, SPYon...)' },
  { pattern: /^b[A-Z]{2,6}$/, issuer: 'Backed Finance bTokens (bCSPX, bNIU...)' },
  { pattern: /^d[A-Z]{2,6}$/, issuer: 'Dinari dShares' },
  // **Case-sensitive, and that matters.** The xStocks convention is an uppercase ticker with a
  // LOWERCASE `x` suffix (`TSLAx`, `AAPLx`). Written case-insensitively this matched `SPX` and
  // `TRX` — a memecoin and a layer-1 — because they happen to end in X. A policy check that cries
  // wolf gets switched off, so the pattern has to be the convention and not a resemblance to it.
  { pattern: /^[A-Z]{2,6}x$/, issuer: 'Swarm / xStocks style (TSLAx, AAPLx)' },
]

/** Issuer contracts we will not pair against, by address. Lowercased. */
const DENYLIST: ReadonlyArray<{ address: string; why: string }> = [
  {
    address: '0x96f6ef951840721adbf46ac996b59e0235cb985c',
    why: 'USDY — Ondo tokenised US Treasury note. Reg S, US persons restricted by the issuer.',
  },
  {
    address: '0x9cdf242ef7975d8c68d5c1f5b6905801699b1940',
    why: 'WHITE — WhiteRock. Token itself is a plain ERC-20, but the business is tokenised equities.',
  },
]

/**
 * Words in a token's NAME that mean it represents a claim on somebody. `Yield` is in here because
 * the thing that made USDY unacceptable was that it is a yield-bearing note, not that it was
 * called a stock.
 */
const CLAIM_WORDS = [
  'stock', 'share', 'equity', 'treasury', 'bond', 'note', 'yield',
  'dividend', 'security', 'fund', 'etf', 'index',
]

let failures = 0
const fail = (msg: string) => {
  failures++
  console.log(`  FAIL  ${msg}`)
}

console.log(`Checking ${PAIRS.length} pair currencies against the no-securities rule.\n`)

for (const p of PAIRS) {
  const addr = (p.address ?? '').toLowerCase()

  const denied = DENYLIST.find((d) => d.address === addr)
  if (denied) fail(`${p.symbol} is on the denylist — ${denied.why}`)

  const named = EQUITY_NAMING.find((n) => n.pattern.test(p.symbol))
  if (named) {
    fail(`${p.symbol} matches a tokenised-equity naming convention — ${named.issuer}`)
  }

  const hit = CLAIM_WORDS.find((w) => p.name.toLowerCase().includes(w))
  if (hit) {
    fail(`${p.symbol} ("${p.name}") contains "${hit}" — does it represent a claim on an issuer?`)
  }
}

// Gold is the deliberate exception and it should be VISIBLE rather than silently allowed, so that
// anybody reading the output knows a commodity claim was considered and kept on purpose.
const commodities = PAIRS.filter((p) => ['PAXG', 'XAUT'].includes(p.symbol)).map((p) => p.symbol)
if (commodities.length) {
  console.log(`  NOTE  commodity claims kept on purpose: ${commodities.join(', ')}`)
  console.log('        gold is a claim on metal, not on an issuer\u2019s cash flows.\n')
}

if (failures === 0) {
  console.log('PASS — no tokenised securities in the roster.')
  console.log('       This proves nothing known-bad is present, not that everything present is fine.')
} else {
  console.log(`\n${failures} problem(s). The rule: does this token represent a claim on an issuer's`)
  console.log("cash flows, debt or equity? If yes it does not belong in the pair roster.")
  process.exit(1)
}
