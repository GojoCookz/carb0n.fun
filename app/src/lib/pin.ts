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

/**
 * Where uploads POST to.
 *
 * **Defaults to the same-origin `/api/pin`, which is the route this repo ships.** It used to
 * require `VITE_PIN_ENDPOINT` to be set before uploads were even offered, which meant the shipped
 * site told every creator "no pinning key is configured" and pushed them at a paste-a-CID field -
 * while the function was sitting right there, correctly deployed, answering 405 to GET.
 *
 * Requiring an environment variable to name a path that is fixed by the deployment is not
 * configuration, it is a step somebody has to remember. The override stays for pointing a local
 * dev build at a remote endpoint.
 */
function endpoint(): string {
  const v = import.meta.env.VITE_PIN_ENDPOINT
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : '/api/pin'
}

/**
 * Is there somewhere to upload to? Now always true, because the route always exists.
 *
 * **This does NOT mean the server can pin.** `/api/pin` answers 503 until `PINATA_JWT` is set in
 * the server environment. That is deliberately a runtime error with a specific message rather than
 * a hidden UI state: a missing key is an operator problem to fix, not a reason to make every
 * creator paste a content hash by hand.
 */
export function pinningConfigured(): boolean {
  return true
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
    // 503 is the ONE case the operator can fix, so it must not read as a generic failure. The
    // route returns it when PINATA_JWT is absent from the server environment.
    if (res.status === 503) {
      throw new Error(
        'Image uploads are switched off on the server. PINATA_JWT is not set for this deployment.',
      )
    }
    throw new Error(`The upload failed (HTTP ${res.status}).`)
  }

  const body = (await res.json()) as { cid?: string; IpfsHash?: string }
  const cid = body.cid ?? body.IpfsHash
  if (!cid) throw new Error('The upload service returned no CID.')
  return { cid }
}
