import type { LaunchMode } from '../lib/launch'

/**
 * The first and most consequential control on the form.
 *
 * **Simple is not advanced with fields hidden.** It fixes the pair to ETH, the tax to 2% a side
 * and the split to everything-to-you, and it does so because those are already the right answers
 * for almost everybody. Advanced is where the twenty-five pair currencies, the dividend switch,
 * the burn wedge and the vesting live — real value, and also exactly what makes a first-time
 * creator close the tab.
 *
 * Switching back to simple SNAPS THOSE VALUES BACK rather than remembering them. A mode that
 * silently keeps a 9% tax from a previous visit is a mode that lies about what it is.
 */
export function ModeToggle({
  mode,
  onChange,
}: {
  mode: LaunchMode
  onChange: (m: LaunchMode) => void
}) {
  return (
    <div className="grid grid-cols-2 gap-2">
      <Option
        active={mode === 'simple'}
        title="Simple"
        body="ETH-paired, 2% a side, all of it yours. One decision: the coin."
        onClick={() => onChange('simple')}
      />
      <Option
        active={mode === 'advanced'}
        title="Custom"
        body="Choose the pair, the tax, dividends, burn and locks."
        onClick={() => onChange('advanced')}
      />
    </div>
  )
}

function Option({
  active,
  title,
  body,
  onClick,
}: {
  active: boolean
  title: string
  body: string
  onClick: () => void
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={[
        'rounded-xl border p-3.5 text-left transition-colors duration-150',
        active
          ? 'border-bone-400/50 bg-bone-50/[0.07]'
          : 'border-ink-700 bg-ink-900 hover:border-ink-600',
      ].join(' ')}
    >
      <span className="flex items-center gap-2">
        <span
          aria-hidden
          className={[
            'size-3.5 shrink-0 rounded-full border-2',
            active ? 'border-bone-50 bg-bone-50' : 'border-ink-600',
          ].join(' ')}
        />
        <span
          className={`font-display text-[14px] font-bold ${active ? 'text-bone-50' : 'text-bone-300'}`}
        >
          {title}
        </span>
      </span>
      <span className="mt-1.5 block text-[11.5px] leading-snug text-bone-500">{body}</span>
    </button>
  )
}

/**
 * A capability behind a yes/no. Answering yes reveals its controls.
 *
 * Every optional feature on this form uses this: dividends, the burn wedge, the dev-buy lock, a
 * separate fee wallet. The question is asked in plain language and the panel only exists once the
 * answer is yes, so the form a creator who wants none of it sees is four questions long.
 */
export function OptIn({
  question,
  hint,
  on,
  onChange,
  children,
}: {
  question: string
  hint?: string
  on: boolean
  onChange: (v: boolean) => void
  children?: React.ReactNode
}) {
  return (
    <div
      className={[
        'rounded-xl border transition-colors duration-150',
        on ? 'border-ink-600 bg-ink-900' : 'border-ink-700 bg-ink-900/60',
      ].join(' ')}
    >
      <div className="flex items-start justify-between gap-3 p-3.5">
        <span className="min-w-0">
          <span className="block font-display text-[13.5px] font-semibold text-bone-100">
            {question}
          </span>
          {hint && <span className="mt-0.5 block text-[11.5px] leading-snug text-bone-500">{hint}</span>}
        </span>

        <button
          type="button"
          role="switch"
          aria-checked={on}
          aria-label={question}
          onClick={() => onChange(!on)}
          className={[
            'relative mt-0.5 h-6 w-10 shrink-0 rounded-full transition-colors duration-150',
            on ? 'bg-bone-50' : 'bg-ink-700',
          ].join(' ')}
        >
          <span
            aria-hidden
            className={[
              'absolute top-0.5 size-5 rounded-full transition-all duration-150 ease-(--ease-out-soft)',
              on ? 'left-[18px] bg-ink-950' : 'left-0.5 bg-bone-500',
            ].join(' ')}
          />
        </button>
      </div>

      {on && children && (
        <div className="space-y-4 border-t border-ink-700 p-3.5">{children}</div>
      )}
    </div>
  )
}
