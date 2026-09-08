# Deploying the app

The reasoning that used to sit in `vercel.json` lives here instead, because **Vercel's schema
rejects unknown top-level keys** — including comment keys like `"//"`. Three deployments failed
before that was established, so it is written down rather than remembered.

## Layout

This is a monorepo: `app/` (Vite SPA) and `contracts/` (Foundry). Vercel builds from the
**repository root** unless told otherwise, and the root has no `index.html`.

| path | role |
|---|---|
| `vercel.json` | root config: builds `app/`, serves `app/dist` |
| `api/pin.ts` | the IPFS upload endpoint, discovered by Vercel at `<root>/api` |
| `app/server/pin.ts` | the actual handler, with every guard in it |

## The three failures, in order

**1. 404 on every path.** No config existed, so Vercel built the repo root, which has no
`index.html`. Setting *Root Directory → `app`* in the dashboard fixes it, but that is a click a
human must repeat for every new project and preview environment. The root `vercel.json` makes the
correct layout a property of the repo instead.

**2. `bun: command not found`.** The first config declared `bun install` / `bun run build`. Vercel
only provisions Bun when it detects a `bun.lockb` or a `packageManager` field in `package.json` —
this repo has neither. It builds with Bun *locally*, which is exactly why the assumption went
unexamined. Commands now use `npm`, which is always present.

**3. `should NOT have additional property "//"`.** The config carried `"//"` keys explaining the
first two fixes. Vercel's schema validation refuses unknown top-level properties, and it runs
*before* the build — so `buildSkipped: true` and the deployment errored with no build log at all,
which is why it looked like a build failure and was not one.

The lesson from all three: **read the error rather than infer it.** The real message came from
`GET /api/v13/deployments/<id>` → `errorMessage`, not from the dashboard UI.

## Function discovery

Vercel scans `<rootDirectory>/api` for serverless functions. With the deploy configured from the
repo root that path is `/api`, **not** `app/api`. A file placed in `app/api/pin.ts` is never found:
the SPA loads perfectly and uploads 404 with nothing in the build log to explain it.

`api/pin.ts` is a four-line shim that imports `handlePin` from `app/server/pin.ts`. Every guard —
the 5 MB cap, the image-only content-type allowlist, the origin allowlist, the fail-loudly-on-the-
server rule — stays in the shared handler. Duplicating a security boundary produces two copies that
must agree and eventually will not.

## The rewrite

```json
{ "source": "/((?!api/).*)", "destination": "/index.html" }
```

The negative lookahead is load-bearing. An SPA needs unknown paths to fall through to `index.html`,
but a naive `/(.*)` swallows `/api/*` too — the upload endpoint would return the HTML shell and fail
with a JSON parse error pointing nowhere near the cause. Verified against `/`, `/token/0x…`,
`/create`, `/assets/*` and `/api/pin`.

## Environment variables

Set in the Vercel dashboard for **Production and Preview**:

| name | value | why |
|---|---|---|
| `PINATA_JWT` | the key | **Never** prefix `VITE_`. Those are inlined into the browser bundle, which is the bug `app/server/pin.ts` exists to have fixed. |
| `ALLOWED_ORIGINS` | `https://carb0n.fun,http://localhost:5173` | Empty allows all: fine on a preview, wrong in production. |
| `VITE_PIN_ENDPOINT` | `/api/pin` | Same-origin, so no CORS preflight in the common case. |

## Verifying a deploy

Reproduce the declared build locally before pushing — the exact chain, not an approximation:

```
cd app && npm install && npm run build     # must produce app/dist/index.html
```

Then after deploy:

```
GET /            -> HTML shell
GET /api/pin     -> JSON (405 "POST only"), NOT the HTML shell
```

If `/api/pin` returns HTML, the rewrite is swallowing the function route.
