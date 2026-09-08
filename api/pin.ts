/**
 * Vercel entry point for the IPFS upload endpoint.
 *
 * **Why this lives at the repo root and not in `app/api/`.** Vercel discovers serverless functions
 * by scanning `<rootDirectory>/api`. This is a monorepo (`app/` + `contracts/`) and the deploy is
 * configured from the repo ROOT, so the scanned path is `/api` - not `app/api`. The first attempt
 * put the file under `app/api/pin.ts`, where Vercel would never have looked: the SPA would have
 * loaded fine and image uploads would have 404'd with nothing in the build log to explain it.
 *
 * **This file is four lines of logic on purpose.** Every guard - the 5 MB cap, the image-only
 * content-type allowlist, the origin allowlist, the fail-loudly-on-the-server rule - lives in
 * `app/server/pin.ts` and is imported. Duplicating a security boundary produces two copies that
 * must agree, and they eventually stop agreeing.
 *
 * `handlePin` already takes a `Request` and returns a `Response`, which is the Edge runtime's
 * signature exactly, so there is nothing to adapt.
 *
 * **Edge rather than Node** because this route holds `PINATA_JWT`: no filesystem, no process
 * spawning, smaller blast radius. Cold start matters too - the upload sits in the launch flow.
 *
 * ENVIRONMENT (Vercel dashboard, Production + Preview):
 *   PINATA_JWT       - the key. NEVER prefixed `VITE_`; those are inlined into the browser bundle,
 *                      which is the exact bug `server/pin.ts` was written to fix.
 *   ALLOWED_ORIGINS  - comma-separated, e.g. "https://carb0n.fun,http://localhost:5173".
 *                      Empty allows all: acceptable on a preview, wrong in production.
 *
 * The client sets `VITE_PIN_ENDPOINT=/api/pin` - same-origin, so no CORS preflight in the common
 * case, and the origin allowlist still catches calls from anywhere else.
 */
import { handlePin } from '../app/server/pin'

export const config = { runtime: 'edge' }

export default function handler(req: Request): Promise<Response> {
  return handlePin(req)
}
