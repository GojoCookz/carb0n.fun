import { useId, useState, type ReactNode } from 'react'

/**
 * Form primitives.
 *
 * Two rules run through all of them:
 *  1. Every field says what it does to the token, not what it is. "Symbol" is a label; "You
 *     cannot change it after launch" is the thing the user actually needs.
 *  2. An error never appears alone. It carries the contract revert it corresponds to, because
 *     the value being rejected here is the same value that would revert on chain.
 */

const inputBase = [
  'w-full rounded-xl border bg-ink-900 px-3.5 py-3 text-[16px] text-bone-50',
  'placeholder:text-bone-500 transition-colors duration-150',
  'hover:border-ink-600 focus:outline-none',
].join(' ')

function borderFor(invalid: boolean): string {
  return invalid ? 'border-danger-400/70 focus:border-danger-400' : 'border-ink-700 focus:border-bone-200'
}

export function TextField({
  label,
  hint,
  value,
  onChange,
  placeholder,
  maxLength,
  mono,
  error,
  optional,
  constraint,
}: {
  label: string
  hint: string
  value: string
  onChange: (v: string) => void
  placeholder: string
  maxLength?: number
  mono?: boolean
  error?: string
  optional?: boolean
  /** The rule governing what may be typed. Lives on the label line, not under the field. */
  constraint?: string
}) {
  const id = useId()
  const invalid = Boolean(error)
  return (
    <div>
      <Label htmlFor={id} optional={optional} constraint={constraint ?? (maxLength ? `Max ${maxLength} characters` : undefined)}>
        {label}
      </Label>
      <input
        id={id}
        value={value}
        maxLength={maxLength}
        placeholder={placeholder}
        aria-invalid={invalid || undefined}
        aria-describedby={`${id}-hint`}
        onChange={(e) => onChange(e.target.value)}
        className={`mt-1.5 ${inputBase} ${borderFor(invalid)} ${mono ? 'font-mono tracking-wide' : ''}`}
      />
      <FieldFoot id={`${id}-hint`} hint={hint} error={error} counter={
        maxLength ? `${value.length}/${maxLength}` : undefined
      } />
    </div>
  )
}

export function NumberField({
  label,
  hint,
  value,
  onChange,
  unit,
  step = 'any',
  min = 0,
  error,
  optional,
  constraint,
  presets,
}: {
  label: string
  hint: ReactNode
  value: number
  onChange: (v: number) => void
  /** Rendered inside the field. Amounts here are in real units, not basis points. */
  unit: string
  step?: string
  min?: number
  error?: string
  optional?: boolean
  constraint?: string
  /**
   * One-tap common values, rendered as a segmented control.
   *
   * klik.finance makes STARTING LIQUIDITY a 1 / 2 / 5 / 10 segmented control with no free text on
   * the common path, and that is correct: typing a number is the slowest interaction on a phone,
   * and on a form of irreversible decisions a set of sane values is also a recommendation.
   */
  presets?: { label: string; value: number }[]
}) {
  const id = useId()
  const invalid = Boolean(error)
  return (
    <div>
      <Label htmlFor={id} optional={optional} constraint={constraint}>
        {label}
      </Label>
      {presets && presets.length > 0 && (
        <div className="mt-1.5 flex overflow-hidden rounded-xl border border-ink-700 bg-ink-900">
          {presets.map((p, i) => (
            <button
              key={p.label}
              type="button"
              onClick={() => onChange(p.value)}
              aria-pressed={value === p.value}
              className={[
                'min-h-[44px] flex-1 font-mono text-[13px] font-bold transition-colors duration-150',
                i > 0 ? 'border-l border-ink-700' : '',
                value === p.value
                  ? 'bg-bone-50/[0.10] text-bone-50'
                  : 'text-bone-400 hover:bg-ink-800 hover:text-bone-200',
              ].join(' ')}
            >
              {p.label}
            </button>
          ))}
        </div>
      )}

      <div className="relative mt-1.5">
        <input
          id={id}
          type="number"
          inputMode="decimal"
          step={step}
          min={min}
          value={Number.isFinite(value) ? value : ''}
          aria-invalid={invalid || undefined}
          aria-describedby={`${id}-hint`}
          onChange={(e) => onChange(e.target.value === '' ? 0 : Number(e.target.value))}
          className={`${inputBase} ${borderFor(invalid)} tnum pr-20 font-mono [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none`}
        />
        <span className="pointer-events-none absolute inset-y-0 right-3.5 flex items-center font-mono text-[13px] font-semibold text-bone-400">
          {unit}
        </span>
      </div>

      <FieldFoot id={`${id}-hint`} hint={hint} error={error} />
    </div>
  )
}

/**
 * A percentage expressed in basis points, which is what the contracts take. The slider is the
 * control and the number is the readout — on a phone, dragging beats typing four digits.
 */
export function BpsSlider({
  label,
  hint,
  value,
  onChange,
  max,
  step = 25,
  error,
  zeroLabel,
}: {
  label: string
  hint: ReactNode
  value: number
  onChange: (v: number) => void
  max: number
  step?: number
  error?: string
  /** Shown instead of "0%" when zero means "off" rather than "none". */
  zeroLabel?: string
}) {
  const id = useId()
  return (
    <div>
      <div className="flex items-baseline justify-between gap-3">
        <Label htmlFor={id}>{label}</Label>
        <EditablePercent value={value} max={max} onChange={onChange} zeroLabel={zeroLabel} />
      </div>
      <input
        id={id}
        type="range"
        min={0}
        max={max}
        step={step}
        value={value}
        aria-describedby={`${id}-hint`}
        onChange={(e) => onChange(Number(e.target.value))}
        className="mt-3 h-1.5 w-full cursor-pointer appearance-none rounded-full bg-ink-700 accent-bone-50"
      />
      <FieldFoot id={`${id}-hint`} hint={hint} error={error} />
    </div>
  )
}

/**
 * The slider's read-out, which is also an input.
 *
 * **A slider alone cannot express intent.** Dragging is good for exploring a range and bad for
 * saying "three point five", and these values are basis points that a creator often arrives
 * already knowing — the slider's 0.25% step cannot even reach 3.4%. Making the number typeable
 * costs one control and removes a whole class of "close enough" launches, which matters because
 * the value is written on chain once and never again.
 *
 * The two stay in sync rather than competing: typing moves the slider, dragging updates the text.
 * Commit is on blur or Enter; Escape restores what was there before, so an abandoned edit cannot
 * leave a half-typed number behind.
 */
function EditablePercent({
  value,
  max,
  onChange,
  zeroLabel,
}: {
  value: number
  max: number
  onChange: (v: number) => void
  zeroLabel?: string
}) {
  const [editing, setEditing] = useState(false)
  const [text, setText] = useState('')

  function commit(raw: string) {
    const pct = Number.parseFloat(raw)
    setEditing(false)
    // A field left empty or filled with nonsense keeps the previous value. Coercing it to zero
    // would silently turn "I changed my mind" into "charge nothing".
    if (!Number.isFinite(pct)) return
    // Basis points are integers on chain; rounding here rather than at submit means the number
    // shown after typing is exactly the number that gets launched.
    const bps = Math.round(pct * 100)
    onChange(Math.max(0, Math.min(max, bps)))
  }

  if (editing) {
    return (
      <span className="flex items-baseline gap-1">
        <input
          autoFocus
          inputMode="decimal"
          value={text}
          aria-label="Percentage"
          onChange={(e) => setText(e.target.value)}
          onBlur={(e) => commit(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') commit((e.target as HTMLInputElement).value)
            if (e.key === 'Escape') setEditing(false)
          }}
          className="tnum w-[4.5ch] rounded-md border border-bone-400/50 bg-ink-950 px-1 py-0.5 text-right font-mono text-[14px] font-bold text-bone-50 outline-none"
        />
        <span className="font-mono text-[14px] font-bold text-bone-50">%</span>
      </span>
    )
  }

  return (
    <button
      type="button"
      onClick={() => {
        setText((value / 100).toString())
        setEditing(true)
      }}
      title="Click to type an exact value"
      // The dotted underline is the only thing telling anyone this is editable. Without it the
      // affordance is discoverable solely by hovering, which on a phone means not at all - and an
      // input nobody finds is not an input.
      className="tnum rounded-md border border-transparent px-1 py-0.5 font-mono text-[14px] font-bold text-bone-50 underline decoration-bone-500/50 decoration-dotted decoration-from-font underline-offset-4 transition-colors duration-150 hover:border-ink-600 hover:bg-ink-900 hover:decoration-bone-200"
    >
      {value === 0 && zeroLabel ? zeroLabel : `${(value / 100).toFixed(2)}%`}
    </button>
  )
}

/**
 * The label carries the CONSTRAINT; the line under the field carries the CONSEQUENCE.
 *
 * klik.finance does this and it is the right split: "NAME — Max 50 characters" sits with the
 * label because it governs what you may type, while "you cannot change it after launch" belongs
 * under the field because it is what happens afterwards. Putting both below the input makes the
 * hard rule compete with the explanation and the user reads neither.
 */
function Label({
  children,
  htmlFor,
  optional,
  constraint,
}: {
  children: ReactNode
  htmlFor?: string
  optional?: boolean
  constraint?: string
}) {
  return (
    <div className="flex items-baseline gap-2">
      <label htmlFor={htmlFor} className="font-display text-[13px] font-semibold text-bone-200">
        {children}
        {optional && (
          <span className="ml-1.5 font-sans text-[11px] font-medium text-bone-500">optional</span>
        )}
      </label>
      {constraint && (
        <span className="min-w-0 truncate text-[11px] font-medium text-bone-500">{constraint}</span>
      )}
    </div>
  )
}

function FieldFoot({
  id,
  hint,
  error,
  counter,
}: {
  id: string
  hint: ReactNode
  error?: string
  counter?: string
}) {
  return (
    <div className="mt-1.5 flex items-start justify-between gap-3">
      <p id={id} className="text-[12px] leading-snug text-bone-500">
        {error ? <span className="font-medium text-danger-400">{error}</span> : hint}
      </p>
      {counter && <span className="tnum shrink-0 text-[11px] text-bone-500">{counter}</span>}
    </div>
  )
}

/**
 * Progressive disclosure. Four decisions matter on this form; the rest have defaults that
 * already match what the contracts expect. Burying them is not hiding them — the summary line
 * states the current values so a closed panel is still readable.
 */
export function Disclosure({
  title,
  summary,
  children,
}: {
  title: string
  summary: string
  children: ReactNode
}) {
  const [open, setOpen] = useState(false)
  const id = useId()
  return (
    <div className="rounded-(--radius-card) border border-ink-700 bg-ink-850">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        aria-controls={id}
        className="flex w-full items-center gap-3 px-4 py-3.5 text-left transition-colors duration-150 hover:bg-ink-800"
      >
        <span className="min-w-0 flex-1">
          <span className="block font-display text-[14px] font-bold text-bone-50">{title}</span>
          <span className="tnum mt-0.5 block truncate font-mono text-[11px] text-bone-500">{summary}</span>
        </span>
        <svg
          width="18"
          height="18"
          viewBox="0 0 24 24"
          fill="none"
          aria-hidden
          className={`shrink-0 text-bone-400 transition-transform duration-200 ease-(--ease-out-soft) ${open ? 'rotate-180' : ''}`}
        >
          <path d="m6 9 6 6 6-6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
        </svg>
      </button>
      {open && (
        <div id={id} className="space-y-5 border-t border-ink-700 px-4 pb-5 pt-4">
          {children}
        </div>
      )}
    </div>
  )
}

/** A labelled value in a derived-numbers panel. */
export function Stat({
  label,
  value,
  sub,
}: {
  label: string
  value: ReactNode
  sub?: ReactNode
}) {
  return (
    <div className="min-w-0">
      <p className="text-[11px] font-medium uppercase tracking-wider text-bone-500">{label}</p>
      <p className="tnum mt-1 truncate font-display text-[15px] font-bold text-bone-50">{value}</p>
      {sub && <p className="tnum mt-0.5 truncate text-[11px] text-bone-500">{sub}</p>}
    </div>
  )
}

/**
 * A claim that would otherwise be taken on trust, with its origin attached. Used anywhere a
 * number came from a measurement rather than from the user's own input.
 */
export function Source({ children }: { children: ReactNode }) {
  return (
    <p className="mt-2 flex gap-1.5 text-[11px] leading-relaxed text-bone-500">
      <span aria-hidden className="mt-[5px] size-1 shrink-0 rounded-full bg-steel-400" />
      <span className="min-w-0">{children}</span>
    </p>
  )
}
