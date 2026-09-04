import { useState } from 'react'
import { logoUrl, type Pair } from '../lib/pairs'

/**
 * A pair's logo, with a real fallback.
 *
 * The images come from a third party keyed on contract address. When one is missing we render
 * the ticker in a plain disc rather than a broken image or an empty gap — a missing logo must
 * not make a legitimate pair look defunct.
 */
export function TokenLogo({ pair, size = 20 }: { pair: Pair; size?: number }) {
  const [failed, setFailed] = useState(false)

  if (failed) {
    return (
      <span
        aria-hidden
        style={{ width: size, height: size, fontSize: Math.max(8, size * 0.34) }}
        className="flex shrink-0 items-center justify-center rounded-full bg-ink-700 font-bold text-bone-400"
      >
        {pair.symbol.slice(0, 2)}
      </span>
    )
  }

  return (
    <img
      src={logoUrl(pair)}
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
