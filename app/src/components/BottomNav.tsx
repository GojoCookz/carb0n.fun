import { NavLink } from 'react-router-dom'

/**
 * Mobile-first bottom navigation with the primary action elevated in the centre.
 *
 * Reasoning taken from BaseStonk (not its pixels): on a phone the launch action must be
 * thumb-reachable and unmistakably primary. Everything else is navigation and stays quiet.
 * Targets are 44px+ so they clear the iOS minimum.
 */
/**
 * Five slots so the primary action sits dead centre and is reachable by either thumb.
 * Order is by frequency of use, not by importance: Board and Rewards are what people
 * come back for; Launch is the thing they do once.
 */
const items = [
  { to: '/board', label: 'Board', icon: TokensIcon },
  { to: '/rewards', label: 'Rewards', icon: RewardsIcon },
  { to: '/', label: 'Launch', icon: LaunchIcon, primary: true },
  { to: '/docs', label: 'Docs', icon: DocsIcon },
  { to: '/about', label: 'About', icon: AboutIcon },
]

export function BottomNav() {
  return (
    <nav
      aria-label="Primary"
      className="fixed inset-x-0 bottom-0 z-50 border-t border-ink-700 bg-ink-900/95 backdrop-blur-md"
      style={{ paddingBottom: 'env(safe-area-inset-bottom)' }}
    >
      <ul className="mx-auto flex max-w-2xl items-end justify-around px-2 pb-2.5 pt-1.5">
        {items.map(({ to, label, icon: Icon, primary }) => (
          <li key={to} className="flex-1">
            <NavLink
              to={to}
              end={to === '/'}
              className={({ isActive }) =>
                [
                  'group mx-auto flex min-h-[52px] w-full max-w-[104px] flex-col items-center justify-end gap-1 rounded-xl px-1 py-1 transition-colors duration-300',
                  primary ? '' : isActive ? 'text-bone-50' : 'text-bone-500 hover:text-bone-200',
                ].join(' ')
              }
            >
              {({ isActive }) =>
                primary ? (
                  <>
                    <span
                      className={[
                        'flex size-12 -translate-y-3 items-center justify-center rounded-full',
                        'bg-bone-50 text-ink-950 shadow-[0_6px_22px_-6px_rgba(255,255,255,0.45)]',
                        'transition-transform duration-200 ease-(--ease-out-soft)',
                        'group-hover:scale-105 group-active:scale-95',
                      ].join(' ')}
                    >
                      <Icon />
                    </span>
                    <span
                      className={[
                        '-mt-2 text-[11px] font-semibold',
                        isActive ? 'text-bone-50' : 'text-bone-400',
                      ].join(' ')}
                    >
                      {label}
                    </span>
                  </>
                ) : (
                  <>
                    <Icon />
                    <span className="text-[11px] font-medium">{label}</span>
                  </>
                )
              }
            </NavLink>
          </li>
        ))}
      </ul>
    </nav>
  )
}

function TokensIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" aria-hidden>
      <ellipse cx="12" cy="6" rx="7" ry="3" stroke="currentColor" strokeWidth="1.8" />
      <path d="M5 6v6c0 1.66 3.13 3 7 3s7-1.34 7-3V6" stroke="currentColor" strokeWidth="1.8" />
      <path d="M5 12v6c0 1.66 3.13 3 7 3s7-1.34 7-3v-6" stroke="currentColor" strokeWidth="1.8" />
    </svg>
  )
}

function LaunchIcon() {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" aria-hidden>
      <path
        d="M12 3c3.2 2.2 5 5.5 5 9l-2.4 2.2h-5.2L7 12c0-3.5 1.8-6.8 5-9Z"
        stroke="currentColor"
        strokeWidth="1.9"
        strokeLinejoin="round"
      />
      <path d="M9.4 16.5 8 21l4-2 4 2-1.4-4.5" stroke="currentColor" strokeWidth="1.9" strokeLinejoin="round" />
      <circle cx="12" cy="10" r="1.6" fill="currentColor" />
    </svg>
  )
}

function AboutIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" aria-hidden>
      <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8" />
      <path d="M12 11v5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
      <circle cx="12" cy="7.8" r="1.1" fill="currentColor" />
    </svg>
  )
}

function RewardsIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" aria-hidden>
      <path d="M3 9h18v11a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V9Z" stroke="currentColor" strokeWidth="1.7" />
      <path d="M2 6.5h20V9H2z" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round" />
      <path d="M12 6.5V21" stroke="currentColor" strokeWidth="1.7" />
      <path
        d="M12 6.5S10.5 3 8.5 3a2 2 0 0 0 0 4h3.5Zm0 0S13.5 3 15.5 3a2 2 0 0 1 0 4H12Z"
        stroke="currentColor"
        strokeWidth="1.7"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function DocsIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" aria-hidden>
      <path
        d="M5 4.5A1.5 1.5 0 0 1 6.5 3H15l4 4v12.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 5 19.5v-15Z"
        stroke="currentColor"
        strokeWidth="1.7"
        strokeLinejoin="round"
      />
      <path d="M14.5 3v4.5H19M8.5 12h7M8.5 16h4.5" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
    </svg>
  )
}
