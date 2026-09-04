import { useCallback, useMemo, useState, type ReactNode } from 'react'
import { DEFAULT_DRAFT, type LaunchDraft } from './launch'
import { PAIRS } from './pairs'
import { DraftContext } from './draft-context'

/**
 * The launch being configured, shared between the form and the token-page preview.
 *
 * It lives in sessionStorage rather than in a URL or a server: a draft is not a launch, and a
 * half-filled form should not survive as a shareable link that looks like a real token.
 */
const KEY = 'carbonado.draft.v1'

/**
 * A referrer from `?ref=0x...`, or empty.
 *
 * Read from the URL and never typed by hand. It is captured on FIRST load only, and the launch
 * contract ignores a second referrer for an address that already has one, so a later link cannot
 * reassign somebody else's claim.
 */
function referrerFromUrl(): string {
  try {
    const v = new URLSearchParams(window.location.search).get('ref') ?? ''
    return /^0x[0-9a-fA-F]{40}$/.test(v) ? v : ''
  } catch {
    return ''
  }
}

function load(): LaunchDraft {
  try {
    const raw = sessionStorage.getItem(KEY)
    const ref = referrerFromUrl()

    // Merge over the defaults so an older stored shape cannot leave a field undefined.
    const stored = raw ? (JSON.parse(raw) as Partial<LaunchDraft>) : {}
    // An EXISTING referrer always wins. The contract ignores a second one anyway, so honouring a
    // newer link here would only mislead the UI about who is credited.
    const next = { ...DEFAULT_DRAFT, ...stored, referrer: stored.referrer || ref }

    // **Persist immediately when a referral link brought them here.** Otherwise the referrer
    // lives only in memory until the first keystroke, and a visitor who lands on the link, reads
    // the page and navigates before typing loses the attribution entirely - which is the exact
    // journey a referral link produces.
    if (next.referrer && next.referrer !== stored.referrer) {
      sessionStorage.setItem(KEY, JSON.stringify(next))
    }
    return next
  } catch {
    return DEFAULT_DRAFT
  }
}

export function DraftProvider({ children }: { children: ReactNode }) {
  const [draft, setDraft] = useState<LaunchDraft>(load)

  const set = useCallback(<K extends keyof LaunchDraft>(key: K, value: LaunchDraft[K]) => {
    setDraft((d) => {
      const next = { ...d, [key]: value }
      try {
        sessionStorage.setItem(KEY, JSON.stringify(next))
      } catch {
        // Private mode, quota, whatever. The form still works; it just will not survive a reload.
      }
      return next
    })
  }, [])

  const replace = useCallback((next: LaunchDraft) => {
    try {
      sessionStorage.setItem(KEY, JSON.stringify(next))
    } catch {
      /* private mode; the form still works, it just will not survive a reload */
    }
    setDraft(next)
  }, [])

  const reset = useCallback(() => {
    try {
      sessionStorage.removeItem(KEY)
    } catch {
      /* ignore */
    }
    setDraft(DEFAULT_DRAFT)
  }, [])

  const pair = useMemo(() => PAIRS.find((p) => p.symbol === draft.pairSymbol), [draft.pairSymbol])
  const value = useMemo(
    () => ({draft, pair, set, setDraft: replace, reset}),
    [draft, pair, set, replace, reset],
  )

  return <DraftContext.Provider value={value}>{children}</DraftContext.Provider>
}
