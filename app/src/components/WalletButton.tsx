import { useEffect, useRef, useState } from 'react'
import { useWallet } from '../lib/useWallet'
import { activeNetwork } from '../lib/activeNetwork'
import { shortAccount } from '../lib/wallet'

/**
 * Connect / wrong-chain / connected, in the top bar.
 *
 * **This exists because there was no global way to connect a wallet.** The only connect controls
 * lived at the bottom of the launch form and inside the trade panel, so a visitor who wanted to
 * see their address, or connect before doing anything, had nowhere to click. The wallet layer was
 * complete; the entry point was missing.
 *
 * **It shows exactly one state at a time, and each one names its own next action** - the same rule
 * the launch button follows. A control that is merely greyed out tells the user they are stuck
 * without telling them why or what to do.
 *
 *   nothing possible -> "Get a wallet", linking out. Nothing else is actionable.
 *   connecting       -> "Check your wallet." The popup, or the phone, is already waiting.
 *   wrong chain      -> "Switch to <network>", which also ADDS the chain if the wallet has never
 *                       seen it. On Robinhood Chain that is the common path, not an edge case.
 *   connected        -> the address, which stays visible so "am I connected?" is never a question.
 *
 * **Why a menu appears only sometimes.** With an extension AND WalletConnect available there is a
 * real choice and the user must make it. With only one route there is no choice, so clicking
 * connects immediately rather than opening a menu with one item in it - which is how a desktop
 * user with MetaMask, and a phone user with neither, both get a single tap.
 */
export function WalletButton() {
  const w = useWallet()
  const net = activeNetwork()
  const [menuOpen, setMenuOpen] = useState(false)
  const wrapRef = useRef<HTMLDivElement>(null)

  // A menu that survives a click elsewhere, or Escape, is a menu the user has to fight.
  useEffect(() => {
    if (!menuOpen) return
    const onDown = (e: MouseEvent) => {
      if (!wrapRef.current?.contains(e.target as Node)) setMenuOpen(false)
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setMenuOpen(false)
    }
    document.addEventListener('mousedown', onDown)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDown)
      document.removeEventListener('keydown', onKey)
    }
  }, [menuOpen])

  const base =
    'shrink-0 whitespace-nowrap rounded-full border px-2.5 py-1 text-[11px] font-medium leading-none transition-colors outline-none focus-visible:ring-2 focus-visible:ring-steel-400/40'

  const menuItem =
    'block w-full px-3 py-2 text-left text-[11px] leading-tight transition-colors hover:bg-ink-800 focus-visible:bg-ink-800 outline-none'

  // No extension and no WalletConnect projectId. There is genuinely nothing to click.
  if (!w.canConnect) {
    return (
      <a
        href="https://ethereum.org/en/wallets/find-wallet/"
        target="_blank"
        rel="noreferrer noopener"
        className={`${base} border-ink-700 bg-ink-900 text-bone-400 hover:border-ink-600`}
        title="No wallet extension was detected, and WalletConnect is not configured for this deployment."
      >
        Get a wallet
      </a>
    )
  }

  if (!w.account) {
    const bothRoutes = w.hasInjected && w.hasWalletConnect

    if (!bothRoutes) {
      return (
        <button
          type="button"
          onClick={() => void w.connect('auto')}
          disabled={w.connecting}
          className={`${base} border-steel-500/40 bg-steel-500/10 text-steel-200 hover:border-steel-400/60 disabled:opacity-60`}
        >
          {w.connecting ? 'Check your wallet.' : 'Connect wallet'}
        </button>
      )
    }

    return (
      <div ref={wrapRef} className="relative">
        <button
          type="button"
          onClick={() => setMenuOpen((o) => !o)}
          disabled={w.connecting}
          aria-haspopup="menu"
          aria-expanded={menuOpen}
          className={`${base} border-steel-500/40 bg-steel-500/10 text-steel-200 hover:border-steel-400/60 disabled:opacity-60`}
        >
          {w.connecting ? 'Check your wallet.' : 'Connect wallet'}
        </button>

        {menuOpen && !w.connecting && (
          <div
            role="menu"
            className="absolute right-0 z-50 mt-1.5 w-52 overflow-hidden rounded-xl border border-ink-700 bg-ink-900 py-1 shadow-xl shadow-black/60"
          >
            <button
              type="button"
              role="menuitem"
              className={`${menuItem} text-bone-200`}
              onClick={() => {
                setMenuOpen(false)
                void w.connect('injected')
              }}
            >
              <span className="font-medium">Browser wallet</span>
              <span className="mt-0.5 block text-[10px] text-bone-500">
                The extension in this browser
              </span>
            </button>
            <button
              type="button"
              role="menuitem"
              className={`${menuItem} text-bone-200`}
              onClick={() => {
                setMenuOpen(false)
                void w.connect('walletconnect')
              }}
            >
              <span className="font-medium">WalletConnect</span>
              <span className="mt-0.5 block text-[10px] text-bone-500">
                Scan a QR code with a phone
              </span>
            </button>
          </div>
        )}
      </div>
    )
  }

  if (!w.onRightChain) {
    return (
      <button
        type="button"
        onClick={() => void w.switchChain()}
        className={`${base} border-amber-500/40 bg-amber-500/10 text-amber-200 hover:border-amber-400/60`}
        title={`Your wallet is on another network. This switches it to ${net.label}, adding the chain if it has never seen it.`}
      >
        Switch to {net.label}
      </button>
    )
  }

  // Connected. Disconnect is offered ONLY for WalletConnect, because a site cannot revoke an
  // injected provider's permission - offering it there would clear the address and then silently
  // reconnect on the next load, which the reload immediately exposes as a lie.
  if (!w.isWalletConnect) {
    return (
      <span
        className={`${base} border-ink-700 bg-ink-900 font-mono text-bone-300`}
        title={`Connected to ${net.label}`}
      >
        {shortAccount(w.account)}
      </span>
    )
  }

  return (
    <div ref={wrapRef} className="relative">
      <button
        type="button"
        onClick={() => setMenuOpen((o) => !o)}
        aria-haspopup="menu"
        aria-expanded={menuOpen}
        className={`${base} border-ink-700 bg-ink-900 font-mono text-bone-300 hover:border-ink-600`}
        title={`Connected to ${net.label} over WalletConnect`}
      >
        {shortAccount(w.account)}
      </button>

      {menuOpen && (
        <div
          role="menu"
          className="absolute right-0 z-50 mt-1.5 w-52 overflow-hidden rounded-xl border border-ink-700 bg-ink-900 py-1 shadow-xl shadow-black/60"
        >
          <div className="px-3 py-2 text-[10px] leading-tight text-bone-500">
            Connected over WalletConnect to {net.label}.
          </div>
          <button
            type="button"
            role="menuitem"
            className={`${menuItem} text-red-300`}
            onClick={() => {
              setMenuOpen(false)
              void w.disconnect()
            }}
          >
            Disconnect
          </button>
        </div>
      )}
    </div>
  )
}
