/**
 * Pinning an image to IPFS.
 *
 * ## THE KEY IN THIS FILE IS PUBLIC. THIS IS A TESTNET-ONLY ARRANGEMENT.
 *
 * `VITE_` variables are inlined into the bundle at build time, so the JWT below ships to every
 * visitor and anyone reading the JavaScript can upload to the account it belongs to. That was an
 * explicit, informed decision to unblock a Sepolia demo, and it is written down here rather than
 * in a commit message because this is the file somebody will read before shipping to mainnet.
 *
 * **Before mainnet this must become a server-side upload** — a small proxy holding the key, or
 * Pinata's signed one-time upload URLs. Until then, use a key scoped to a throwaway account with
 * a spend cap, and rotate it when the demo ends.
 *
 * The CID returned by the service is the one written on chain. We do NOT compute a CID locally:
 * a file's real CID depends on how the pinning service chunks and frames it (UnixFS/dag-pb vs
 * raw), so a locally-derived digest would frequently point at content nobody has pinned — an
 * image that resolves nowhere, recorded permanently in write-once metadata.
 */

const PINATA_ENDPOINT = 'https://api.pinata.cloud/pinning/pinFileToIPFS'

function jwt(): string | null {
  const v = import.meta.env.VITE_PINATA_JWT
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : null
}

/** False until a key is configured. The UI must say so rather than fail on submit. */
export function pinningConfigured(): boolean {
  return jwt() !== null
}

export type PinResult = { cid: string }

export async function pinImage(blob: Blob, filename: string): Promise<PinResult> {
  const token = jwt()
  if (!token) {
    throw new Error(
      'Image uploads are not configured yet. Add VITE_PINATA_JWT to the app\u2019s .env and restart the dev server.',
    )
  }

  const form = new FormData()
  form.append('file', blob, filename)
  form.append('pinataOptions', JSON.stringify({ cidVersion: 1 }))

  let res: Response
  try {
    res = await fetch(PINATA_ENDPOINT, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
      body: form,
    })
  } catch {
    throw new Error('Could not reach the pinning service. Check your connection and try again.')
  }

  if (!res.ok) {
    // Do not echo the response body: it can contain the key or account details.
    if (res.status === 401 || res.status === 403) {
      throw new Error('The pinning key was rejected. It may be expired or revoked.')
    }
    throw new Error(`The upload failed (HTTP ${res.status}).`)
  }

  const body = (await res.json()) as { IpfsHash?: string }
  if (!body.IpfsHash) throw new Error('The pinning service returned no CID.')
  return { cid: body.IpfsHash }
}
