import { useEffect, useRef, useState } from 'react'
import { activeNetworkId, subscribeNetwork } from '../lib/activeNetwork'

/**
 * Drifting leaves behind the whole app, on the Robinhood theme only.
 *
 * ## Why canvas and not DOM
 *
 * The obvious build is thirty absolutely-positioned divs with CSS keyframes. It looks fine on a
 * desktop and janks on a phone: each one is a composited layer the browser tracks, and this app is
 * mobile-first. One canvas is a single layer no matter how many leaves are on it, and the whole
 * field costs one `requestAnimationFrame` callback.
 *
 * ## Why it is allowed to be behind everything and still be cheap
 *
 * - It stops completely when the tab is hidden. An animation nobody can see must not spend battery.
 * - It stops completely when the network is not Robinhood, and the canvas is removed from the DOM.
 * - Leaf count scales with viewport area, so a phone draws roughly a third of what a desktop does.
 *
 * ## Reduced motion is a hard stop, not a slow-down
 *
 * `prefers-reduced-motion: reduce` is frequently set by people for whom drifting background motion
 * is genuinely unpleasant. It renders ONE static frame instead - the texture survives, the movement
 * does not. It also re-checks when the setting changes, rather than only at mount.
 */

type Leaf = {
  x: number
  y: number
  /** Radius in px. Also drives fall speed, so big leaves fall faster and read as nearer. */
  r: number
  /** Radians. */
  rot: number
  rotSpeed: number
  fall: number
  /** Horizontal sway, as a phase and an amplitude. */
  phase: number
  sway: number
  hue: 'emerald' | 'gold'
  alpha: number
}

/** One leaf, drawn as two mirrored quadratic curves with a centre vein. */
function drawLeaf(ctx: CanvasRenderingContext2D, l: Leaf) {
  const { r } = l
  ctx.save()
  ctx.translate(l.x, l.y)
  ctx.rotate(l.rot)
  ctx.globalAlpha = l.alpha

  // Gold leaves are rarer and slightly brighter - they read as flecks rather than a second colour.
  ctx.fillStyle = l.hue === 'gold' ? '#f0c14b' : '#10d982'

  ctx.beginPath()
  ctx.moveTo(0, -r)
  ctx.quadraticCurveTo(r * 0.9, -r * 0.1, 0, r)
  ctx.quadraticCurveTo(-r * 0.9, -r * 0.1, 0, -r)
  ctx.fill()

  // The vein. Without it a leaf at this size is just a lens shape.
  ctx.globalAlpha = l.alpha * 0.55
  ctx.strokeStyle = l.hue === 'gold' ? '#96700f' : '#02090a'
  ctx.lineWidth = Math.max(0.6, r * 0.07)
  ctx.beginPath()
  ctx.moveTo(0, -r * 0.85)
  ctx.lineTo(0, r * 0.85)
  ctx.stroke()

  ctx.restore()
}

function makeLeaf(w: number, h: number, seeded: boolean): Leaf {
  const r = 7 + Math.random() * 13
  return {
    x: Math.random() * w,
    // On first fill, scatter through the viewport. Afterwards they enter from above.
    y: seeded ? Math.random() * h : -r * 2 - Math.random() * h * 0.3,
    r,
    rot: Math.random() * Math.PI * 2,
    rotSpeed: (Math.random() - 0.5) * 0.012,
    fall: 0.12 + (r / 16) * 0.35,
    phase: Math.random() * Math.PI * 2,
    sway: 0.25 + Math.random() * 0.7,
    // Roughly one in seven is gold. Enough to notice, rare enough to stay an accent.
    hue: Math.random() < 0.14 ? 'gold' : 'emerald',
    alpha: 0.18 + Math.random() * 0.34,
  }
}

export function LeafField() {
  const canvasRef = useRef<HTMLCanvasElement | null>(null)
  const wrapRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    let raf = 0
    let leaves: Leaf[] = []
    let w = 0
    let h = 0
    let running = false
    let dpr = 1

    const wrap = wrapRef.current
    const canvas = canvasRef.current
    if (!wrap || !canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)')

    const resize = () => {
      // Cap DPR at 2. A 3x phone gains nothing visible here and pays 2.25x the fill cost.
      dpr = Math.min(window.devicePixelRatio || 1, 2)
      w = window.innerWidth
      h = window.innerHeight
      canvas.width = Math.floor(w * dpr)
      canvas.height = Math.floor(h * dpr)
      canvas.style.width = `${w}px`
      canvas.style.height = `${h}px`
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

      // Density by area, floored and capped so neither a phone nor an ultrawide misbehaves.
      const target = Math.max(14, Math.min(42, Math.round((w * h) / 34000)))
      if (leaves.length < target) {
        while (leaves.length < target) leaves.push(makeLeaf(w, h, true))
      } else {
        leaves.length = target
      }
    }

    const paint = (t: number) => {
      ctx.clearRect(0, 0, w, h)
      for (const l of leaves) drawLeaf(ctx, l)
      if (!running) return
      for (const l of leaves) {
        l.y += l.fall
        l.x += Math.sin(t * 0.0006 + l.phase) * l.sway * 0.6
        l.rot += l.rotSpeed
        if (l.y - l.r > h) Object.assign(l, makeLeaf(w, h, false))
        if (l.x < -40) l.x = w + 40
        if (l.x > w + 40) l.x = -40
      }
    }

    const frame = (t: number) => {
      paint(t)
      raf = requestAnimationFrame(frame)
    }

    const stop = () => {
      running = false
      cancelAnimationFrame(raf)
      raf = 0
    }

    const start = () => {
      if (raf) return
      if (reduce.matches) {
        // One static frame. The texture is the point; the motion is the part being opted out of.
        running = false
        paint(0)
        return
      }
      running = true
      raf = requestAnimationFrame(frame)
    }

    // A background animation running in a tab nobody is looking at is pure battery cost.
    const onVisibility = () => (document.hidden ? stop() : start())

    resize()
    start()
    window.addEventListener('resize', resize)
    document.addEventListener('visibilitychange', onVisibility)
    reduce.addEventListener('change', () => {
      stop()
      start()
    })

    return () => {
      stop()
      window.removeEventListener('resize', resize)
      document.removeEventListener('visibilitychange', onVisibility)
    }
  }, [])

  return (
    <div
      ref={wrapRef}
      aria-hidden
      className="pointer-events-none fixed inset-0 z-0 overflow-hidden"
      data-leaf-field
    >
      <canvas ref={canvasRef} />
    </div>
  )
}

/**
 * Mount it only on the Robinhood theme.
 *
 * Kept as a separate component so the canvas is genuinely UNMOUNTED on other networks rather than
 * hidden with CSS - a hidden canvas still holds its backing store, which at 2x on a large display
 * is several megabytes of memory for a decoration nobody can see.
 *
 * It subscribes to the network store so switching chains adds or removes the field immediately,
 * rather than on the next navigation.
 */
export function NetworkLeaves() {
  const [network, setNetwork] = useState(activeNetworkId)

  useEffect(() => subscribeNetwork(() => setNetwork(activeNetworkId())), [])

  return network === 'robinhood' ? <LeafField /> : null
}
