/**
 * The upload endpoint. **This is the only place the Pinata key is allowed to exist.**
 *
 * The browser used to hold that key, because it was read from a `VITE_` variable and those are
 * inlined into the bundle at build time — every visitor received a working credential. This moves
 * it behind a request the client cannot read.
 *
 * Deploy as a serverless function (Vercel `api/pin.ts`, Cloudflare Worker, Netlify function) or run
 * it standalone with `bun server/pin.ts`. Then set `VITE_PIN_ENDPOINT` in the app's `.env` to its
 * URL. The URL is not a secret; the key it holds is.
 *
 * Set `PINATA_JWT` in the SERVER environment. Never in `VITE_` anything.
 *
 * Deliberately small and boring. It has one job and three guards:
 *   - a size cap, so this cannot be used as free unlimited storage
 *   - a content-type allowlist, so it pins images and not archives
 *   - an origin allowlist, so it is not an open relay for anyone who finds the URL
 *
 * Rate limiting is NOT implemented here because it belongs at the edge (Cloudflare, Vercel), and a
 * fake in-memory limiter on a serverless function that cold-starts per request would be security
 * theatre. Put a real one in front of this before it faces the public.
 */

const PINATA_ENDPOINT = 'https://api.pinata.cloud/pinning/pinFileToIPFS'
const MAX_BYTES = 5 * 1024 * 1024
const ALLOWED_TYPES = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif'])

/** Comma-separated list, e.g. "https://carb0n.fun,http://localhost:5173". Empty allows all. */
const ALLOWED_ORIGINS = (process.env.ALLOWED_ORIGINS ?? '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)

function cors(origin: string | null): Record<string, string> {
  const allow =
    ALLOWED_ORIGINS.length === 0 ? '*' : origin && ALLOWED_ORIGINS.includes(origin) ? origin : ''
  return allow
    ? {
        'Access-Control-Allow-Origin': allow,
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
      }
    : {}
}

export async function handlePin(req: Request): Promise<Response> {
  const origin = req.headers.get('origin')
  const headers = { 'Content-Type': 'application/json', ...cors(origin) }

  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(origin) })
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'POST only' }), { status: 405, headers })
  }
  if (ALLOWED_ORIGINS.length > 0 && (!origin || !ALLOWED_ORIGINS.includes(origin))) {
    return new Response(JSON.stringify({ error: 'origin not allowed' }), { status: 403, headers })
  }

  const jwt = process.env.PINATA_JWT
  if (!jwt) {
    // Fail loudly on the SERVER, vaguely to the client. A misconfigured deploy should page an
    // operator, not teach a visitor what is missing.
    console.error('PINATA_JWT is not set; refusing to accept uploads')
    return new Response(JSON.stringify({ error: 'uploads unavailable' }), { status: 503, headers })
  }

  let form: FormData
  try {
    form = await req.formData()
  } catch {
    return new Response(JSON.stringify({ error: 'expected multipart/form-data' }), { status: 400, headers })
  }

  const file = form.get('file')
  if (!(file instanceof File)) {
    return new Response(JSON.stringify({ error: 'no file' }), { status: 400, headers })
  }
  if (file.size > MAX_BYTES) {
    return new Response(JSON.stringify({ error: 'too large' }), { status: 413, headers })
  }
  if (!ALLOWED_TYPES.has(file.type)) {
    return new Response(JSON.stringify({ error: 'unsupported type' }), { status: 415, headers })
  }

  const out = new FormData()
  out.append('file', file, file.name || 'upload')
  out.append('pinataOptions', JSON.stringify({ cidVersion: 1 }))

  const res = await fetch(PINATA_ENDPOINT, {
    method: 'POST',
    headers: { Authorization: `Bearer ${jwt}` },
    body: out,
  })

  if (!res.ok) {
    // Log upstream detail server-side; return none of it. The body can name the account.
    console.error('pinata rejected upload', res.status, await res.text().catch(() => ''))
    return new Response(JSON.stringify({ error: 'upload failed' }), { status: 502, headers })
  }

  const body = (await res.json()) as { IpfsHash?: string }
  if (!body.IpfsHash) {
    return new Response(JSON.stringify({ error: 'no cid returned' }), { status: 502, headers })
  }
  return new Response(JSON.stringify({ cid: body.IpfsHash }), { status: 200, headers })
}

// Standalone: `PINATA_JWT=... bun server/pin.ts`
if (import.meta.main) {
  const port = Number(process.env.PORT ?? 8787)
  Bun.serve({ port, fetch: handlePin })
  console.log(`pin endpoint listening on http://localhost:${port}`)
}

export default { fetch: handlePin }
