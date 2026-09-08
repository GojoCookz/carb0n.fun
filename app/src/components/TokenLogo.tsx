import { useState } from 'react'
import { logoUrl, type Pair } from '../lib/pairs'
import { activeNetworkId } from '../lib/activeNetwork'

/**
 * A pair's logo, with a fallback that is a MARK rather than an apology.
 *
 * ## Why the fallback got this much attention
 *
 * People choose tokens by picture, not by reading. A grid of thirty tiles where every one is the
 * same grey disc with two grey letters is a grid nobody can navigate - the eye has nothing to
 * latch onto, so the list may as well be alphabetical text.
 *
 * Real images cover 24 of the 30 Robinhood currencies. The six that have none are the non-meme
 * assets, and they still need to be *distinguishable at a glance*, so the fallback derives a
 * stable colour pair from the contract address. Same token, same colours, forever; different
 * tokens, visibly different tiles.
 *
 * ## Why the address and not the symbol
 *
 * A symbol identifies nothing on chain 4663 - four separate contracts answer XMR there, five
 * answer WETH. Two different tokens sharing a ticker MUST NOT get the same tile, or the fallback
 * actively helps an impersonator. The address is the only unique thing available.
 */
export function TokenLogo({ pair, size = 20 }: { pair: Pair; size?: number }) {
  const [failed, setFailed] = useState(false)
  const src = logoUrl(pair, activeNetworkId())

  if (failed || !src) {
    const { from, to, ink } = markColors(pair.address)
    return (
      <span
        aria-hidden
        style={{
          width: size,
          height: size,
          fontSize: Math.max(8, size * 0.36),
          background: `linear-gradient(135deg, ${from} 0%, ${to} 100%)`,
          color: ink,
        }}
        className="flex shrink-0 items-center justify-center rounded-full font-display font-bold leading-none tracking-tight"
      >
        {initials(pair.symbol)}
      </span>
    )
  }

  return (
    <img
      src={src}
      alt=""
      width={size}
      height={size}
      loading="lazy"
      onError={() => setFailed(true)}
      style={{ width: size, height: size }}
      className="shrink-0 rounded-full bg-ink-700 object-cover"
    />
  )
}

/**
 * One or two characters that actually distinguish the token.
 *
 * `symbol.slice(0, 2)` gives "ST" for STONKBROKER and "SH" for SHROOM, which is fine, but "MO" for
 * both MOO and a future MOON. Taking the first letter of each word where there is one, and
 * otherwise first-and-last, separates far more of them.
 */
function initials(symbol: string): string {
  const words = symbol.split(/[\s_-]+/).filter(Boolean)
  if (words.length > 1) return (words[0][0] + words[1][0]).toUpperCase()
  if (symbol.length <= 2) return symbol.toUpperCase()
  return (symbol[0] + symbol[symbol.length - 1]).toUpperCase()
}

/**
 * A deterministic colour pair from the address.
 *
 * FNV-1a rather than a sum of char codes: addresses share long common prefixes and a naive sum
 * clusters them into a handful of near-identical hues, which defeats the entire point. Saturation
 * and lightness are fixed so every tile has the same weight against the dark surface and no token
 * can accidentally shout louder than the rest of the grid.
 */
function markColors(address: string): { from: string; to: string; ink: string } {
  let h = 2166136261
  for (let i = 0; i < address.length; i++) {
    h ^= address.charCodeAt(i)
    h = Math.imul(h, 16777619)
  }
  const hue = Math.abs(h) % 360
  // The second stop is offset rather than random so the gradient always reads as one material.
  const hue2 = (hue + 38) % 360
  return {
    from: `hsl(${hue} 62% 46%)`,
    to: `hsl(${hue2} 58% 30%)`,
    ink: 'rgba(255,255,255,0.92)',
  }
}
