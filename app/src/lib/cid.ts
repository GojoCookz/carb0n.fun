/**
 * IPFS CID (the string a user pastes) -> `bytes32` (what `LaunchMetadata` actually stores).
 *
 * **The contract does not store a CID.** It stores the 32-byte multihash DIGEST inside one, and
 * the frontend reassembles the printable CID by prepending the known codec bytes. That is a
 * deliberate storage decision documented in `types/LaunchMetadata.sol` — a CID string costs at
 * minimum two slots and encodes a gateway hostname that will outlive nobody.
 *
 * So a form field holding `bafybei...` cannot be handed to `launch()` as-is, and the failure mode
 * if you try is not a revert — viem would reject the type, or worse, a wrong-length value would
 * silently truncate and the token would carry an image nobody can resolve, permanently, because
 * metadata is written once and never again.
 *
 * Two encodings are accepted because both are in the wild:
 *   - **CIDv0** — `Qm...`, base58btc, 34 bytes: `0x12 0x20` then the 32-byte sha2-256 digest.
 *   - **CIDv1** — `b...`, base32 lower, `0x01 <codec> 0x12 0x20` then the digest.
 *
 * Anything else is REJECTED rather than coerced. A launch is irreversible and metadata is
 * write-once, so guessing at a malformed identifier is the one thing this must not do.
 */

const BASE58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
const BASE32 = 'abcdefghijklmnopqrstuvwxyz234567'

export type CidResult = { ok: true; digest: `0x${string}` } | { ok: false; reason: string }

/** The zero value. `LaunchMetadata` treats it as "not set", which is legal for banner and info. */
export const ZERO_BYTES32 = `0x${'0'.repeat(64)}` as const

function toHex(bytes: number[]): `0x${string}` {
  return `0x${bytes.map((b) => b.toString(16).padStart(2, '0')).join('')}` as `0x${string}`
}

function decodeBase58(s: string): number[] | null {
  const out: number[] = []
  for (const ch of s) {
    let carry = BASE58.indexOf(ch)
    if (carry < 0) return null
    for (let i = 0; i < out.length; i++) {
      carry += out[i] * 58
      out[i] = carry & 0xff
      carry >>= 8
    }
    while (carry > 0) {
      out.push(carry & 0xff)
      carry >>= 8
    }
  }
  // Leading '1's are leading zero bytes, by definition of base58btc.
  for (const ch of s) {
    if (ch !== '1') break
    out.push(0)
  }
  return out.reverse()
}

function decodeBase32(s: string): number[] | null {
  let bits = 0
  let value = 0
  const out: number[] = []
  for (const ch of s) {
    const idx = BASE32.indexOf(ch)
    if (idx < 0) return null
    value = (value << 5) | idx
    bits += 5
    if (bits >= 8) {
      bits -= 8
      out.push((value >> bits) & 0xff)
    }
  }
  return out
}

/**
 * Parse a CID down to its 32-byte digest.
 *
 * Empty input returns the zero value rather than an error, because the banner and info CIDs are
 * genuinely optional. The REQUIRED-ness of the image is enforced by `validate`, not here — this
 * function's job is to convert, and conflating the two would make an optional field impossible.
 */
export function cidToBytes32(raw: string): CidResult {
  const s = raw.trim()
  if (s.length === 0) return { ok: true, digest: ZERO_BYTES32 }

  let bytes: number[] | null = null

  if (s.startsWith('Qm')) {
    bytes = decodeBase58(s)
    if (!bytes) return { ok: false, reason: 'Not valid base58 — check for a typo.' }
    if (bytes.length !== 34 || bytes[0] !== 0x12 || bytes[1] !== 0x20) {
      return { ok: false, reason: 'Not a sha2-256 CIDv0.' }
    }
    return { ok: true, digest: toHex(bytes.slice(2)) }
  }

  if (s.startsWith('b')) {
    bytes = decodeBase32(s.slice(1))
    if (!bytes) return { ok: false, reason: 'Not valid base32 — CIDv1 is lowercase.' }
    // 0x01 version, one codec byte, then the multihash.
    if (bytes.length < 4 || bytes[0] !== 0x01) {
      return { ok: false, reason: 'Not a CIDv1.' }
    }
    const mh = bytes.slice(2)
    if (mh[0] !== 0x12 || mh[1] !== 0x20 || mh.length < 34) {
      return { ok: false, reason: 'Not a sha2-256 multihash.' }
    }
    return { ok: true, digest: toHex(mh.slice(2, 34)) }
  }

  return { ok: false, reason: 'Not an IPFS CID. Expected one starting Qm… or b…' }
}
