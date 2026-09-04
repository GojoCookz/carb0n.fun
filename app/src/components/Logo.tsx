import { useId } from 'react'

/**
 * The mark.
 *
 * ## What it is
 *
 * A faceted octahedron in the Ethereum lineage — same tall bipyramid silhouette, same
 * six-plane construction, same trick of letting each face catch light differently so a
 * flat vector reads as a solid. That is deliberate homage: this pad only exists on L1
 * and the mark should say so before a word does.
 *
 * ## What makes it OURS rather than Ethereum's
 *
 * Two changes, and both mean something:
 *
 * 1. **The waist is a gap, not a seam.** Ethereum's mark is one continuous solid pinched
 *    at the middle. Ours is cut clean through and held apart — two bodies, one object.
 *    That is the product: a token and the currency it is paired against, in one pool.
 *
 * 2. **The halves are lit from opposite sides.** The upper body takes the highlight, the
 *    lower takes the shadow, so the eye reads a bright half and a dark half rather than a
 *    single gem. Two assets, not one.
 *
 * The dividend is the gap. Value crosses it in both directions.
 *
 * ## Why chrome and not a colour
 *
 * The Ethereum mark is not grey, it is *metal*. Everything in this app takes its accent
 * from that material rather than from a hue — see `.chrome` in `index.css`. A launchpad
 * whose pair roster is the actual subject cannot afford to spend a colour on its own logo.
 */
export function LogoMark({ size = 28, className = '' }: { size?: number; className?: string }) {
  // Gradients must be uniquely identified or a second instance on the page steals the
  // first one's fill. `useId` is the supported way to do that in React 18+.
  const id = useId()
  const lit = `${id}-lit`
  const mid = `${id}-mid`
  const dark = `${id}-dark`

  return (
    <svg
      width={size}
      height={size * (53 / 33)}
      viewBox="0 0 33 53"
      fill="none"
      role="img"
      aria-label="carbonado.fun"
      className={`shrink-0 ${className}`}
    >
      <defs>
        <linearGradient id={lit} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#ffffff" />
          <stop offset="55%" stopColor="#d5d7de" />
          <stop offset="100%" stopColor="#9a9caa" />
        </linearGradient>
        <linearGradient id={mid} x1="1" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#c9cbd3" />
          <stop offset="100%" stopColor="#7b7d8a" />
        </linearGradient>
        <linearGradient id={dark} x1="0" y1="1" x2="1" y2="0">
          <stop offset="0%" stopColor="#4a4c57" />
          <stop offset="100%" stopColor="#8b8d99" />
        </linearGradient>
      </defs>

      {/*
        GEOMETRY NOTE. The gap is the mark, so it has to survive a 19px header render.
        An earlier version used a 3.5-unit gap in a 53-unit box: about two pixels at
        header size, which vanished and left the thing reading as Ethereum's own glyph.
        It is now 7 units — 13% of the height — and the two halves are pushed apart in
        brightness as well as in space, so the split is legible before the facets are.
      */}

      {/* --- UPPER BODY: apex at top, cut flat across the waist. Takes the highlight. --- */}
      <path d="M16.5 1 L0 21.5 L5.5 24.5 L16.5 24.5 Z" fill={`url(#${lit})`} />
      <path d="M16.5 1 L33 21.5 L27.5 24.5 L16.5 24.5 Z" fill={`url(#${mid})`} />

      {/* --- THE GAP: y 24.5 → 31.5. Nothing is drawn here, and that is the point. --- */}

      {/* --- LOWER BODY: an exact mirror of the upper about y=28, so the gap is a clean
              parallel band rather than a wedge. Takes the shadow. --- */}
      <path d="M16.5 52 L0 34.5 L5.5 31.5 L16.5 31.5 Z" fill={`url(#${dark})`} />
      <path d="M16.5 52 L33 34.5 L27.5 31.5 L16.5 31.5 Z" fill={`url(#${mid})`} opacity="0.62" />

      {/* Rim of light on the cut faces, so the gap reads machined rather than broken. */}
      <path d="M5.5 24.5 L27.5 24.5" stroke="#ffffff" strokeOpacity="0.5" strokeWidth="0.9" />
      <path d="M5.5 31.5 L27.5 31.5" stroke="#ffffff" strokeOpacity="0.18" strokeWidth="0.7" />
    </svg>
  )
}

/**
 * Mark plus wordmark. Set lowercase and tight — a launchpad that shouts in its own
 * header has nothing else to say.
 *
 * The TLD is set dimmer and lighter than the name. `carbonado` is the brand and `.fun` is an
 * address; giving them equal weight makes the reader parse a domain instead of a word. Same
 * type size so the baseline stays honest, three steps down in contrast so the eye doesn't.
 */
export function Logo({ size = 22, className = '' }: { size?: number; className?: string }) {
  return (
    <span className={`inline-flex items-center gap-2.5 ${className}`}>
      <LogoMark size={size} />
      <span
        className="font-display font-bold leading-none"
        style={{ fontSize: size * 0.86, letterSpacing: '-0.035em' }}
      >
        <span className="chrome-text">carbonado</span>
        <span className="font-medium text-bone-500">.fun</span>
      </span>
    </span>
  )
}
