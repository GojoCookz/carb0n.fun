import type { ReactNode } from 'react'

export function Card({ children, className = '' }: { children: ReactNode; className?: string }) {
  return (
    <div className={`rounded-(--radius-card) border border-ink-700 bg-ink-850 ${className}`}>{children}</div>
  )
}

export function SectionTitle({ children, count }: { children: ReactNode; count?: ReactNode }) {
  return (
    <h2 className="flex items-baseline gap-2.5 font-display text-[19px] font-bold tracking-tight text-bone-50">
      {children}
      {count !== undefined && <span className="tnum text-[14px] font-medium text-bone-500">{count}</span>}
    </h2>
  )
}

/**
 * Every empty state must say what is missing AND what to do next. "No data" on its own is a
 * dead end, and a list that renders nothing with no explanation reads as a bug.
 */
export function EmptyState({
  title,
  body,
  action,
}: {
  title: string
  body: string
  action?: ReactNode
}) {
  return (
    <Card className="px-5 py-9 text-center">
      <div
        className="mx-auto mb-4 flex size-11 items-center justify-center rounded-full border border-dashed border-ink-600 text-bone-500"
        aria-hidden
      >
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
          <path d="M4 7h16M4 12h16M4 17h9" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
        </svg>
      </div>
      <p className="font-display text-[15px] font-semibold text-bone-200">{title}</p>
      <p className="mx-auto mt-1.5 max-w-[38ch] text-[13px] leading-relaxed text-bone-500">{body}</p>
      {action && <div className="mt-5">{action}</div>}
    </Card>
  )
}

/**
 * Status pill. `tone="pending"` is used for anything not yet live - it must never look like a
 * success state, because a launchpad that implies it is deployed when it is not is a lie.
 */
export function Pill({
  children,
  tone = 'neutral',
}: {
  children: ReactNode
  tone?: 'neutral' | 'volt' | 'pending'
}) {
  const tones = {
    neutral: 'border-ink-600 bg-ink-800 text-bone-400',
    volt: 'border-bone-400/40 bg-bone-50/10 text-bone-50',
    pending: 'border-steel-500/40 bg-steel-500/10 text-steel-300',
  }
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-semibold tracking-wide ${tones[tone]}`}
    >
      {children}
    </span>
  )
}

export function Button({
  children,
  onClick,
  disabled,
  disabledReason,
  variant = 'primary',
  type = 'button',
}: {
  children: ReactNode
  onClick?: () => void
  disabled?: boolean
  /** Shown to the user when disabled. A dead control with no explanation is a bug, not a design. */
  disabledReason?: string
  variant?: 'primary' | 'ghost'
  type?: 'button' | 'submit'
}) {
  const base =
    'inline-flex w-full items-center justify-center gap-2 rounded-xl px-5 py-3.5 font-display text-[15px] font-bold transition-all duration-150 ease-(--ease-out-soft) disabled:cursor-not-allowed'
  const variants = {
    primary:
      'bg-volt-500 text-ink-950 hover:bg-volt-400 active:scale-[0.985] disabled:bg-ink-800 disabled:text-bone-500',
    ghost:
      'border border-ink-600 bg-ink-800 text-bone-200 hover:border-ink-600 hover:bg-ink-700 active:scale-[0.985] disabled:text-bone-500',
  }
  return (
    <span className="block">
      <button
        type={type}
        onClick={onClick}
        disabled={disabled}
        title={disabled ? disabledReason : undefined}
        className={`${base} ${variants[variant]}`}
      >
        {children}
      </button>
      {disabled && disabledReason && (
        <span className="mt-2 block text-center text-[12px] leading-snug text-bone-500">{disabledReason}</span>
      )}
    </span>
  )
}
