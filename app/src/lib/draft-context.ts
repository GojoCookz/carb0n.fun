import { createContext, useContext } from 'react'
import type { LaunchDraft } from './launch'
import type { Pair } from './pairs'

/**
 * Split out from `draft.tsx` so that file exports a component and nothing else — mixing a
 * provider and its hook in one module breaks React Fast Refresh for the whole subtree.
 */
export type DraftCtx = {
  draft: LaunchDraft
  pair: Pair | undefined
  set: <K extends keyof LaunchDraft>(key: K, value: LaunchDraft[K]) => void
  /** Replace the whole draft. For mode switches, which change many fields at once. */
  setDraft: (d: LaunchDraft) => void
  reset: () => void
}

export const DraftContext = createContext<DraftCtx | null>(null)

export function useDraft(): DraftCtx {
  const ctx = useContext(DraftContext)
  if (!ctx) throw new Error('useDraft must be used inside <DraftProvider>')
  return ctx
}
