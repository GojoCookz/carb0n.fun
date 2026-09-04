/**
 * Turning "a photo on someone's phone" into "exactly the asset the contract expects".
 *
 * **The app crops; it does not demand.** `LaunchMetadata` documents the banner as 1500x500, and
 * the previous form simply printed that requirement next to a text box. Almost nobody can produce
 * a 1500x500 file on a phone, so a rule stated that way is not a specification, it is a way of
 * making the field somebody else's problem. Any image is accepted and cover-cropped to spec here.
 *
 * Cover-crop rather than letterbox: a banner with bars baked into it is worse than a tight crop,
 * and it is permanent — metadata is written once and never again.
 */

/** What the file picker will accept. HEIC is excluded because browsers cannot decode it. */
export const ACCEPTED_TYPES = ['image/png', 'image/jpeg', 'image/webp', 'image/gif']
export const ACCEPT_ATTR = ACCEPTED_TYPES.join(',')

/** Refused before decode. A phone photo is ~5MB; anything far past that is not a token icon. */
export const MAX_INPUT_BYTES = 15 * 1024 * 1024

/** Square icon. 512 is the largest size any surface here renders, doubled for retina. */
export const ICON_SPEC = { width: 512, height: 512, label: 'square icon' } as const
/** The banner dimensions `types/LaunchMetadata.sol` documents. */
export const BANNER_SPEC = { width: 1500, height: 500, label: '1500 x 500 banner' } as const

export type ImageSpec = { width: number; height: number; label: string }

export type PreparedImage = {
  blob: Blob
  /** Object URL for preview. The CALLER owns this and must revoke it. */
  previewUrl: string
  width: number
  height: number
  bytes: number
  /** True when the source was not already the target aspect ratio, so pixels were discarded. */
  cropped: boolean
}

export function fileTypeError(file: File): string | null {
  if (!ACCEPTED_TYPES.includes(file.type)) {
    return 'That is not an image we can read. Use PNG, JPEG, WebP or GIF.'
  }
  if (file.size > MAX_INPUT_BYTES) {
    return `That file is ${(file.size / 1024 / 1024).toFixed(1)}MB. The limit is ${MAX_INPUT_BYTES / 1024 / 1024}MB.`
  }
  return null
}

function loadImage(file: File): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file)
    const img = new Image()
    img.onload = () => {
      URL.revokeObjectURL(url)
      resolve(img)
    }
    img.onerror = () => {
      URL.revokeObjectURL(url)
      reject(new Error('That image could not be decoded. It may be corrupt.'))
    }
    img.src = url
  })
}

/**
 * Cover-crop to the exact target size.
 *
 * Always re-encodes, even when the source already matches. That is deliberate: it strips EXIF,
 * which on a phone photo carries GPS coordinates and a device identifier. A launch image is
 * published permanently to a public network, and silently publishing someone's home location
 * alongside their token is not a tradeoff worth making to save a few milliseconds.
 */
export async function prepareImage(file: File, spec: ImageSpec): Promise<PreparedImage> {
  const err = fileTypeError(file)
  if (err) throw new Error(err)

  const img = await loadImage(file)
  const srcRatio = img.naturalWidth / img.naturalHeight
  const dstRatio = spec.width / spec.height
  const cropped = Math.abs(srcRatio - dstRatio) > 0.01

  // The largest rectangle of the SOURCE with the target aspect ratio, centred.
  let sw = img.naturalWidth
  let sh = img.naturalHeight
  if (srcRatio > dstRatio) {
    sw = Math.round(img.naturalHeight * dstRatio)
  } else {
    sh = Math.round(img.naturalWidth / dstRatio)
  }
  const sx = Math.round((img.naturalWidth - sw) / 2)
  const sy = Math.round((img.naturalHeight - sh) / 2)

  const canvas = document.createElement('canvas')
  canvas.width = spec.width
  canvas.height = spec.height
  const ctx = canvas.getContext('2d')
  if (!ctx) throw new Error('This browser will not give us a canvas to resize with.')
  ctx.imageSmoothingQuality = 'high'
  ctx.drawImage(img, sx, sy, sw, sh, 0, 0, spec.width, spec.height)

  const blob = await new Promise<Blob | null>((resolve) => {
    // PNG, not WebP: this is pinned forever and read by wallets, explorers and bots, some of
    // which still do not decode WebP. Permanence beats a smaller file.
    canvas.toBlob(resolve, 'image/png')
  })
  if (!blob) throw new Error('The image could not be re-encoded.')

  return {
    blob,
    previewUrl: URL.createObjectURL(blob),
    width: spec.width,
    height: spec.height,
    bytes: blob.size,
    cropped,
  }
}

export function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`
  return `${(n / 1024 / 1024).toFixed(1)} MB`
}
