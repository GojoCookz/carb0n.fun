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
 *   no wallet   -> "Get a wallet", linking out. Nothing else is actionable.
 *   connecting  -> "Check your wallet." The popup is already open behind the tab.
 *   wrong chain -> "Switch to <network>", which also ADDS the chain if the wallet has never seen
 *                  it. On Robinhood Chain that is the common path, not an edge case.
 *   connected   -> the address, which stays visible so "am I connected?" is never a question.
 */
export function WalletButton() {
  const w = useWallet()
  const net = activeNetwork()

  const base =
    'shrink-0 whitespace-nowrap rounded-full border px-2.5 py-1 text-[11px] font-medium leading-none transition-colors outline-none focus-visible:ring-2 focus-visible:ring-steel-400/40'

  if (!w.installed) {
    return (
      <a
        href="https://ethereum.org/en/wallets/find-wallet/"
        target="_blank"
        rel="noreferrer noopener"
        className={`${base} border-ink-700 bg-ink-900 text-bone-400 hover:border-ink-600`}
        title="No wallet extension was detected in this browser."
      >
        Get a wallet
      </a>
    )
  }

  if (!w.account) {
    return (
      <button
        type="button"
        onClick={() => void w.connect()}
        disabled={w.connecting}
        className={`${base} border-steel-500/40 bg-steel-500/10 text-steel-200 hover:border-steel-400/60 disabled:opacity-60`}
      >
        {w.connecting ? 'Check your wallet.' : 'Connect wallet'}
      </button>
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

  return (
    <span
      className={`${base} border-ink-700 bg-ink-900 font-mono text-bone-300`}
      title={`Connected to ${net.label}`}
    >
      {shortAccount(w.account)}
    </span>
  )
}
