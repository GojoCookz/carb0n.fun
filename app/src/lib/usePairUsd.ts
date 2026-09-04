import { useEffect, useState } from 'react'
import { fetchPairUsd, USD_SOURCES, type PairUsd } from './chain'

export type UsdState =
  /** No feed this build can verify. The UI must render `—`, never a guess. */
  | { kind: 'none' }
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'ok'; price: PairUsd }

/**
 * Live USD price for a pair currency, or an explicit "there is no source" state.
 *
 * The `none` case is not a failure — it is the normal, expected answer for most pairs on L1 and
 * the reason the on-chain threshold is denominated in pair units. Callers must render it as a
 * stated absence, not as zero.
 */
function initialFor(symbol: string | undefined): UsdState {
  return !symbol || !USD_SOURCES[symbol] ? { kind: 'none' } : { kind: 'loading' }
}

export function usePairUsd(symbol: string | undefined): UsdState {
  const [state, setState] = useState<UsdState>(() => initialFor(symbol))

  // Adjust state during render when the pair changes, rather than in an effect. Doing it in an
  // effect would paint one frame of the PREVIOUS pair's price under the new pair's name.
  const [seenSymbol, setSeenSymbol] = useState(symbol)
  if (seenSymbol !== symbol) {
    setSeenSymbol(symbol)
    setState(initialFor(symbol))
  }

  useEffect(() => {
    if (!symbol || !USD_SOURCES[symbol]) return

    let live = true

    fetchPairUsd(symbol)
      .then((price) => {
        if (!live) return
        setState(price ? { kind: 'ok', price } : { kind: 'none' })
      })
      .catch((e: unknown) => {
        if (!live) return
        setState({ kind: 'error', message: e instanceof Error ? e.message : 'feed unreachable' })
      })

    return () => {
      live = false
    }
  }, [symbol])

  return state
}

/** Dollar value of `amount` units of the pair, or null when there is no source to derive it from. */
export function usdOf(state: UsdState, amount: number): number | null {
  return state.kind === 'ok' ? state.price.usd * amount : null
}
