/**
 * Pinning an image to IPFS.
 *
 * ## NO SECRET IN THIS FILE, AND NONE IN THE BUNDLE.
 *
 * This used to read `VITE_PINATA_JWT` and send it straight from the browser. `VITE_` variables are
 * INLINED INTO THE BUNDLE at build time, so that key shipped to every visitor and anyone reading
 * the JavaScript could upload to the account it belonged to. It was a documented, deliberate
 * shortcut for a Sepolia demo, and it was still a live credential on a public site.
 *
 * The upload now goes to an endpoint WE control, whose URL is configured with `VITE_PIN_ENDPOINT`.
 * A URL is not a secret. The Pinata key lives on whatever serves that endpoint and never reaches a
 * client. A reference implementation is in `server/pin.ts` — about twenty lines, deployable as a
 * serverless function.
 *
 * **If `VITE_PIN_ENDPOINT` is unset the app says uploads are unavailable and offers a CID field
 * instead.** It does not fall back to a client-side key, because a fallback that leaks a
 * credential is not a fallback.
 *
 * The CID returned by the service is the one written on chain. We do NOT compute a CID locally: a
 * file's real CID depends on how the pinning service chunks and frames it (UnixFS/dag-pb vs raw),
 * so a locally-derived digest would frequently point at content nobody has pinned — an image that
 * resolves nowhere, recorded permanently in write-once metadata.
 */

function endpoint(): string | null {
  const v = import.meta.env.VITE_PIN_ENDPOINT
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : null
}

/** False until an upload endpoint is configured. The UI must say so rather than fail on submit. */
export function pinningConfigured(): boolean {
  return endpoint() !== null
}

export type PinResult = { cid: string }

export async function pinImage(blob: Blob, filename: string): Promise<PinResult> {
  const url = endpoint()
  if (!url) {
    throw new Error(
      'Image uploads are not configured. Set VITE_PIN_ENDPOINT to your upload endpoint, or paste an IPFS CID directly.',
    )
  }

  const form = new FormData()
  form.append('file', blob, filename)

  let res: Response
  try {
    res = await fetch(url, { method: 'POST', body: form })
  } catch {
    throw new Error('Could not reach the upload service. Check your connection and try again.')
  }

  if (!res.ok) {
    // Never echo the response body: an upstream error can carry account details.
    if (res.status === 401 || res.status === 403) {
      throw new Error('The upload service rejected the request.')
    }
    if (res.status === 413) throw new Error('That file is too large to upload.')
    throw new Error(`The upload failed (HTTP ${res.status}).`)
  }

  const body = (await res.json()) as { cid?: string; IpfsHash?: string }
  const cid = body.cid ?? body.IpfsHash
  if (!cid) throw new Error('The upload service returned no CID.')
  return { cid }
}
