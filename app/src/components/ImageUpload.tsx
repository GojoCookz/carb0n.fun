import { useEffect, useRef, useState } from 'react'
import {
  ACCEPT_ATTR,
  fmtBytes,
  prepareImage,
  type ImageSpec,
  type PreparedImage,
} from '../lib/imageFile'
import { pinImage, pinningConfigured } from '../lib/pin'
import { cidToBytes32 } from '../lib/cid'

type Phase =
  | { kind: 'empty' }
  | { kind: 'preparing' }
  | { kind: 'ready'; image: PreparedImage }
  | { kind: 'uploading'; image: PreparedImage }
  | { kind: 'done'; image: PreparedImage }
  | { kind: 'error'; message: string; image?: PreparedImage }

/**
 * Pick an image, see it, upload it.
 *
 * Replaces a text box that asked for an IPFS CID. That field was not a hard requirement of the
 * contract — the contract needs 32 bytes, and where those bytes come from is entirely the app's
 * problem. Asking a creator to arrive with a content identifier already in hand pushed the app's
 * job onto the one person least equipped to do it, and it is the single most likely reason
 * somebody abandons the form.
 *
 * **The preview is the cropped result, not the source file.** Showing the original and cropping
 * silently on submit means the first time anyone sees what was actually published is after it is
 * permanent.
 */
export function ImageUpload({
  label,
  hint,
  spec,
  required,
  value,
  onChange,
}: {
  label: string
  hint: string
  spec: ImageSpec
  required?: boolean
  /** The CID currently stored on the draft. */
  value: string
  onChange: (cid: string) => void
}) {
  const [phase, setPhase] = useState<Phase>({ kind: 'empty' })
  const inputRef = useRef<HTMLInputElement>(null)
  const configured = pinningConfigured()

  // Object URLs leak until revoked, and this component can churn through several per session.
  useEffect(() => {
    const url =
      phase.kind === 'ready' || phase.kind === 'uploading' || phase.kind === 'done'
        ? phase.image.previewUrl
        : phase.kind === 'error'
          ? phase.image?.previewUrl
          : undefined
    return () => {
      if (url) URL.revokeObjectURL(url)
    }
  }, [phase])

  async function handleFile(file: File) {
    setPhase({ kind: 'preparing' })
    let image: PreparedImage
    try {
      image = await prepareImage(file, spec)
    } catch (e) {
      setPhase({ kind: 'error', message: (e as Error).message })
      return
    }

    if (!configured) {
      // The crop is real and worth showing even with nowhere to send it. Saying "not configured"
      // over a blank box would look like the picker itself is broken.
      setPhase({ kind: 'error', message: uploadsOffMessage, image })
      return
    }

    setPhase({ kind: 'uploading', image })
    try {
      const { cid } = await pinImage(image.blob, `${spec.label.replace(/\s+/g, '-')}.png`)
      // The service can return a CID form the contract cannot store. Catch it HERE, while the
      // user is still standing in front of the upload, not at submit.
      const digest = cidToBytes32(cid)
      if (!digest.ok) {
        setPhase({ kind: 'error', message: `Unusable CID from the pinning service: ${digest.reason}`, image })
        return
      }
      onChange(cid)
      setPhase({ kind: 'done', image })
    } catch (e) {
      setPhase({ kind: 'error', message: (e as Error).message, image })
    }
  }

  const image =
    phase.kind === 'ready' || phase.kind === 'uploading' || phase.kind === 'done'
      ? phase.image
      : phase.kind === 'error'
        ? phase.image
        : undefined

  const busy = phase.kind === 'preparing' || phase.kind === 'uploading'

  return (
    <div>
      <div className="mb-1.5 flex items-baseline justify-between gap-3">
        <label className="font-display text-[13px] font-semibold text-bone-200">
          {label}
          {!required && <span className="ml-1.5 text-[11px] font-medium text-bone-500">optional</span>}
        </label>
        {value && phase.kind !== 'error' && (
          <button
            type="button"
            onClick={() => {
              onChange('')
              setPhase({ kind: 'empty' })
            }}
            className="text-[11px] font-semibold text-bone-500 underline underline-offset-2 hover:text-bone-300"
          >
            Remove
          </button>
        )}
      </div>

      <input
        ref={inputRef}
        type="file"
        accept={ACCEPT_ATTR}
        className="sr-only"
        onChange={(e) => {
          const f = e.target.files?.[0]
          if (f) void handleFile(f)
          // Reset so picking the SAME file again still fires a change event.
          e.target.value = ''
        }}
      />

      <button
        type="button"
        disabled={busy}
        onClick={() => inputRef.current?.click()}
        className={[
          'flex w-full items-center gap-3 rounded-xl border border-dashed p-3 text-left transition-colors duration-150',
          busy ? 'cursor-wait' : 'hover:border-ink-600 hover:bg-ink-800',
          phase.kind === 'error' ? 'border-danger-400/40 bg-danger-400/[0.05]' : 'border-ink-600 bg-ink-900',
        ].join(' ')}
      >
        <Thumb image={image} spec={spec} busy={busy} />

        <span className="min-w-0 flex-1">
          <span className="block font-display text-[13.5px] font-semibold text-bone-100">
            {phase.kind === 'preparing'
              ? 'Reading the image…'
              : phase.kind === 'uploading'
                ? 'Uploading to IPFS…'
                : phase.kind === 'done'
                  ? 'Uploaded'
                  : image
                    ? 'Choose a different image'
                    : 'Choose an image'}
          </span>
          <span className="mt-0.5 block text-[11.5px] leading-snug text-bone-500">
            {image
              ? `${image.width} x ${image.height}, ${fmtBytes(image.bytes)}${image.cropped ? ' — cropped to fit' : ''}`
              : hint}
          </span>
        </span>
      </button>

      {phase.kind === 'error' && (
        <p className="mt-1.5 text-[11.5px] leading-relaxed text-danger-400">{phase.message}</p>
      )}

      {phase.kind === 'done' && value && (
        <p className="mt-1.5 truncate font-mono text-[11px] text-bone-500" title={value}>
          {value}
        </p>
      )}

      {!configured && phase.kind === 'empty' && (
        <p className="mt-1.5 text-[11.5px] leading-relaxed text-bone-500">
          Uploads are not switched on yet, so this will crop your image and then stop. You can still
          paste a CID below if you have one.
        </p>
      )}
    </div>
  )
}

const uploadsOffMessage =
  'Cropped, but there is nowhere to upload it yet — no pinning key is configured. Paste a CID below instead, or ask for uploads to be switched on.'

/**
 * The preview, at the ASPECT RATIO OF THE TARGET.
 *
 * Sized from the spec rather than from a square/not-square flag. A 1500x500 banner shown in a
 * portrait box misrepresents the crop the user is approving, which defeats the purpose of showing
 * it at all — the whole reason the preview is the cropped output is so nobody discovers the
 * framing after it is permanent.
 */
function Thumb({ image, spec, busy }: { image?: PreparedImage; spec: ImageSpec; busy: boolean }) {
  const ratio = spec.width / spec.height
  const height = 48
  const width = Math.round(height * Math.min(ratio, 2.6))
  const box = { width, height }

  if (!image) {
    return (
      <span
        aria-hidden
        style={box}
        className="flex shrink-0 items-center justify-center rounded-lg border border-ink-700 bg-ink-850 text-bone-600"
      >
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
          <rect x="3" y="5" width="18" height="14" rx="2" stroke="currentColor" strokeWidth="1.7" />
          <circle cx="8.5" cy="10" r="1.5" fill="currentColor" />
          <path d="m4 17 5-4 4 3 3-2 4 3" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round" />
        </svg>
      </span>
    )
  }

  return (
    <span
      style={box}
      className="relative shrink-0 overflow-hidden rounded-lg border border-ink-700"
    >
      <img src={image.previewUrl} alt="" className="size-full object-cover" />
      {busy && <span className="absolute inset-0 animate-pulse bg-ink-950/60" />}
    </span>
  )
}
