/**
 * Rasterise the mark into the PNG sizes that SVG favicons do not cover.
 *
 * ## Why this exists at all
 *
 * `public/favicon.svg` handles every modern desktop browser. Two places still need raster:
 *
 * - **iOS home screen.** Safari ignores SVG icons entirely for `apple-touch-icon`. Without a
 *   PNG, "Add to Home Screen" screenshots the page and uses that, which on a dark app is an
 *   unreadable grey square.
 * - **Android / PWA install.** The manifest wants 192 and 512 PNGs.
 *
 * ## Why the raster variants are NOT just the favicon scaled up
 *
 * The favicon is a rounded tile. iOS applies its OWN squircle mask on top, so shipping
 * pre-rounded corners gets them clipped twice and leaves dark wedges outside the mask. The
 * raster variants are therefore FULL BLEED - square, no radius, no transparency - and the OS
 * does the rounding. Same reason the hairline edge is dropped: it would sit under the mask.
 *
 * ## Why this is not a dependency
 *
 * `@resvg/resvg-js` is a native module and this repo builds on Vercel, where a native module
 * in `package.json` is a build risk for an asset that changes maybe twice a year. It is
 * installed with `--no-save`, run, and removed. The PNGs are committed. To regenerate:
 *
 *     npm install --no-save @resvg/resvg-js
 *     node scripts/gen-icons.mjs
 *     npm uninstall @resvg/resvg-js
 */
import { Resvg } from '@resvg/resvg-js'
import { writeFileSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const publicDir = join(here, '..', 'public')

/**
 * The full-bleed variant. Geometry is identical to `favicon.svg` - same apex, same waist,
 * same widened gap - with the tile squared off and the hairline removed, both because the
 * platform mask would eat them.
 */
const fullBleed = `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <defs>
    <linearGradient id="lit" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#ffffff"/><stop offset="55%" stop-color="#d5d7de"/><stop offset="100%" stop-color="#9a9caa"/>
    </linearGradient>
    <linearGradient id="mid" x1="1" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#c9cbd3"/><stop offset="100%" stop-color="#7b7d8a"/>
    </linearGradient>
    <linearGradient id="dark" x1="0" y1="1" x2="1" y2="0">
      <stop offset="0%" stop-color="#4a4c57"/><stop offset="100%" stop-color="#8b8d99"/>
    </linearGradient>
  </defs>
  <rect width="64" height="64" fill="#08090c"/>
  <path d="M32 5 L14.5 26 L20.3 29 L32 29 Z" fill="url(#lit)"/>
  <path d="M32 5 L49.5 26 L43.7 29 L32 29 Z" fill="url(#mid)"/>
  <path d="M32 59 L14.5 41 L20.3 38 L32 38 Z" fill="url(#dark)"/>
  <path d="M32 59 L49.5 41 L43.7 38 L32 38 Z" fill="url(#mid)" opacity="0.62"/>
  <path d="M20.3 29 L43.7 29" stroke="#ffffff" stroke-opacity="0.5" stroke-width="1"/>
  <path d="M20.3 38 L43.7 38" stroke="#ffffff" stroke-opacity="0.18" stroke-width="0.8"/>
</svg>`

const targets = [
  { name: 'apple-touch-icon.png', size: 180, svg: fullBleed },
  { name: 'icon-192.png', size: 192, svg: fullBleed },
  { name: 'icon-512.png', size: 512, svg: fullBleed },
  // A raster fallback for the handful of contexts that still refuse SVG. Rounded, because
  // nothing masks this one.
  { name: 'favicon-32.png', size: 32, svg: readFileSync(join(publicDir, 'favicon.svg'), 'utf8') },
]

for (const { name, size, svg } of targets) {
  const png = new Resvg(svg, { fitTo: { mode: 'width', value: size } }).render().asPng()
  writeFileSync(join(publicDir, name), png)
  console.log(`  ${name.padEnd(22)} ${String(size).padStart(3)}px  ${String(png.length).padStart(6)} B`)
}
