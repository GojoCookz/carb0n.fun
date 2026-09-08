/**
 * Where IPFS images are fetched from.
 *
 * ## Why not ipfs.io
 *
 * Every image on the site pointed at `https://ipfs.io/ipfs/`, the public gateway, and it stopped
 * working. Measured: **ipfs.io returns 429 Too Many Requests**, and the browser reports the
 * resulting error page as `ERR_BLOCKED_BY_RESPONSE.NotSameOrigin` - which reads like a CORS bug
 * and is actually rate limiting. Caught in a user's console log, at which point every token image,
 * banner and avatar on the pad was blank.
 *
 * A free public gateway shared by the entire internet is not infrastructure. It has no obligation
 * to us and no capacity reserved for us.
 *
 * ## What replaces it
 *
 * The dedicated Pinata gateway that comes with the account already pinning these files. Measured
 * on the same CID that ipfs.io refused: **200, `Access-Control-Allow-Origin: *`,
 * `Content-Type: image/png`**.
 *
 * ipfs.io is kept as a FALLBACK rather than deleted, because a CID somebody pasted by hand may
 * live on a pin we do not own. The dedicated gateway is tried first and the public one catches the
 * rest, so a self-hosted image never depends on a shared queue and a foreign one still resolves.
 */

/** Ours, from the account that pins uploads. Tried first. */
const PRIMARY = 'https://green-definite-jaguar-68.mypinata.cloud/ipfs/'

/** Public, shared, rate-limited. Only reached when the primary has no copy. */
const FALLBACK = 'https://ipfs.io/ipfs/'

/**
 * Every URL worth trying for one stored image, in order.
 *
 * ## Two dimensions of uncertainty, not one
 *
 * **The codec.** The token stores a bare 32-byte digest, so the CID has to be rebuilt and the
 * codec byte guessed. Pinata returns raw (`bafkrei`) for small files and dag-pb (`bafybei`) for
 * anything it chunks, so the right answer differs per file. Measured on two real launches: TESTCAT
 * resolves as `bafkrei` and 403s as `bafybei`; BBC CAT is the exact opposite. Guessing one codec
 * breaks roughly half of all artwork, which is what was live.
 *
 * **The gateway.** ipfs.io is rate-limiting us (429, which the browser reports as a CORS-shaped
 * `ERR_BLOCKED_BY_RESPONSE`), while our dedicated gateway answers 200 with `Access-Control-Allow-Origin: *`.
 *
 * So: both codecs on our gateway first, then both on the public one. Four candidates, tried only
 * as far as needed - the first hit ends it, and a working image costs exactly one request.
 */
export function ipfsCandidates(cidOrDigest: string, extraCids: string[] = []): string[] {
  const c = cidOrDigest.trim()
  const cids = c.startsWith('0x') ? extraCids : [c, ...extraCids]
  const unique = [...new Set(cids.filter(Boolean))]
  return [...unique.map((x) => `${PRIMARY}${x}`), ...unique.map((x) => `${FALLBACK}${x}`)]
}

export function ipfsUrl(cid: string): string {
  const c = cid.trim()
  if (!c) return ''
  return `${PRIMARY}${c}`
}

export function ipfsFallbackUrl(cid: string): string {
  const c = cid.trim()
  if (!c) return ''
  return `${FALLBACK}${c}`
}

/**
 * `onError` handler that walks a candidate list before giving up.
 *
 * The index is kept on the element itself rather than in React state: an `img` that fails during
 * paint can fire `onError` before a state update lands, and a stale index would restart the walk
 * and loop forever.
 */
export function ipfsWalk(candidates: string[], onExhausted: () => void) {
  return (e: React.SyntheticEvent<HTMLImageElement>) => {
    const img = e.currentTarget
    const next = Number(img.dataset.ipfsTry ?? '0') + 1
    if (next >= candidates.length) {
      onExhausted()
      return
    }
    img.dataset.ipfsTry = String(next)
    img.src = candidates[next]
  }
}
