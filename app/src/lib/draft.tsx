import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { DEFAULT_DRAFT, type LaunchDraft } from './launch'
import { activePairs, subscribeNetwork } from './activeNetwork'
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

  /**
   * Resolve the selected pair AGAINST THE ACTIVE NETWORK'S ROSTER.
   *
   * **This looked the symbol up in `PAIRS` - the hand-written Ethereum list - while the picker
   * offers the active network's approved currencies.** On Robinhood Chain the two lists barely
   * overlap, so picking XMR set `pairSymbol = 'XMR'`, the lookup found nothing in the Ethereum
   * list, `pair` came back `undefined`, and `PairPicker`'s `if (!selected) return null` erased the
   * entire "What it trades against" section. Choosing a currency made the chooser disappear.
   *
   * Two defences, because either alone leaves a hole:
   *
   * 1. Look in the right list.
   * 2. **Never return undefined when the roster is non-empty.** A draft persists in sessionStorage
   *    across a network switch, so a symbol that was valid on one chain can be meaningless on the
   *    next. Falling back to the first approved currency keeps the form usable; returning nothing
   *    deletes a section of the page and gives the user no way to fix it.
   */
  const [networkTick, setNetworkTick] = useState(0)
  useEffect(() => subscribeNetwork(() => setNetworkTick((n) => n + 1)), [])

  const pair = useMemo(() => {
    const roster = activePairs()
    return roster.find((p) => p.symbol === draft.pairSymbol) ?? roster[0]
    // `networkTick` is the dependency that matters here even though it is not read: switching
    // networks changes what `activePairs()` returns without changing `draft.pairSymbol`.
  }, [draft.pairSymbol, networkTick])
  const value = useMemo(
    () => ({draft, pair, set, setDraft: replace, reset}),
    [draft, pair, set, replace, reset],
  )

  return <DraftContext.Provider value={value}>{children}</DraftContext.Provider>
}
