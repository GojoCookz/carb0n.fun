import { useState } from 'react'
import { Button, Card } from './Primitives'
import { launchablePairFor } from '../lib/chain'
import { activeNetwork } from '../lib/activeNetwork'
import { useWallet } from '../lib/useWallet'
import { submitLaunch, type LaunchPhase } from '../lib/launchTx'
import { explorerAddress, explorerTx, shortAccount, walletErrorMessage } from '../lib/wallet'
import type { LaunchDraft } from '../lib/launch'

/**
 * The one control on this site that spends money.
 *
 * **It shows exactly one call to action at a time, and every disabled state names its own
 * reason.** A launch has five separate preconditions — a wallet exists, it is connected, it is on
 * the right network, the chosen pair is on that network, the form is valid — and a single greyed
 * "Launch" button satisfying none of them tells the user nothing about which one they failed.
 *
 * Nothing here is optimistic. The token address comes from a mined receipt, not from a simulation
 * that "should" succeed, because reporting an address for a transaction that later reverted is
 * exactly the kind of confident lie this project bans.
 */
export function LaunchSubmit({
  draft,
  formIssues,
}: {
  draft: LaunchDraft
  formIssues: number
}) {
  const w = useWallet()
  const [phase, setPhase] = useState<LaunchPhase>({ kind: 'idle' })

  const net = activeNetwork()
  const launcher = net.deployment.launcher
  const pair = launchablePairFor(draft.pairSymbol)
  const busy =
    phase.kind === 'funding' || phase.kind === 'approving' || phase.kind === 'launching'

  // --- Terminal state: it worked. ---------------------------------------------------------
  if (phase.kind === 'done') {
    return (
      <Card className="border-bone-400/40 p-5">
        <p className="font-display text-[15px] font-bold text-bone-50">
          {draft.symbol.trim() || 'Your token'} is live on {net.label}
        </p>
        <p className="mt-1.5 text-[12px] leading-relaxed text-bone-400">
          Confirmed in a mined block, not predicted. {net.label} — these are test
          tokens with no value.
        </p>
        <div className="mt-4 space-y-2">
          <LinkRow label="Token" value={phase.token} href={explorerAddress(phase.token)} />
          <LinkRow label="Transaction" value={phase.hash} href={explorerTx(phase.hash)} />
        </div>
        <button
          type="button"
          onClick={() => setPhase({ kind: 'idle' })}
          className="mt-4 w-full rounded-xl border border-ink-600 bg-ink-800 px-5 py-3 font-display text-[14px] font-bold text-bone-200 transition-colors duration-150 hover:bg-ink-700"
        >
          Launch another
        </button>
      </Card>
    )
  }

  // --- Preconditions ----------------------------------------------------------------------
  //
  // ORDER IS DELIBERATE: everything knowable WITHOUT a wallet is checked before anything that
  // needs one. Asking someone to connect, approve a network switch, and only then telling them
  // their chosen pair does not exist on that network is three wasted interactions to deliver
  // information we had before they touched anything.
  if (!launcher) {
    return <Blocked reason="Nothing is deployed. This button will not pretend to submit." />
  }

  if (!pair) {
    return (
      <Blocked
        reason={`${draft.pairSymbol} is not on ${net.label}. The registry allows ${net.deployment.pairs
          .map((p) => p.symbol)
          .join(' and ')} only, so pick WETH or WXMR to launch here. Nothing is substituted for you.`}
      />
    )
  }

  if (formIssues > 0) {
    return <Blocked reason="Fix the items above first." />
  }

  // `canConnect`, not "is an extension installed". On a phone there is never an injected provider,
  // so the old check blocked the launch form outright on the device most people are holding, even
  // though WalletConnect could have connected them.
  if (!w.canConnect) {
    return (
      <Blocked reason="No wallet found. Install a browser wallet, or open this page on a device with a wallet app." />
    )
  }

  if (!w.account) {
    return (
      <div className="space-y-2">
        <Button onClick={() => void w.connect()} disabled={w.connecting}>
          {w.connecting ? 'Check your wallet…' : 'Connect wallet'}
        </Button>
        {w.error && <ErrorNote message={w.error} />}
      </div>
    )
  }

  if (!w.onRightChain) {
    return (
      <div className="space-y-2">
        <Button onClick={() => void w.switchChain()}>Switch to {net.label}</Button>
        <p className="text-center text-[12px] leading-snug text-bone-500">
          Your wallet is on a different network. Your wallet is on another
          network.
        </p>
        {w.error && <ErrorNote message={w.error} />}
      </div>
    )
  }

  // --- Ready ------------------------------------------------------------------------------
  const label =
    phase.kind === 'funding'
              ? `Buying ${pair.symbol} with your ETH.`
              : phase.kind === 'approving'
      ? `Approving ${pair.symbol}…`
      : phase.kind === 'launching'
        ? 'Launching…'
        : 'Launch token'

  return (
    <div className="space-y-2">
      <Button
        disabled={busy}
        onClick={() => {
          void (async () => {
            try {
              await submitLaunch(draft, pair, w.account!, setPhase)
            } catch (e) {
              setPhase({ kind: 'error', message: walletErrorMessage(e) })
            }
          })()
        }}
      >
        {label}
      </Button>

      <p className="text-center text-[12px] leading-snug text-bone-500">
        {busy ? (
          'Waiting on the network. Do not close this tab.'
        ) : (
          <>
            Signing as{' '}
            <span className="font-mono text-bone-400">{shortAccount(w.account)}</span>, paired
            against <span className="font-mono text-bone-400">{pair.symbol}</span> on {net.label}.
            {draft.devBuyPairAmount > 0 && ' Two signatures: an approval, then the launch.'}
          </>
        )}
      </p>

      {(phase.kind === 'approving' || phase.kind === 'launching') && phase.hash && (
        <p className="text-center text-[12px]">
          <a
            href={explorerTx(phase.hash)}
            target="_blank"
            rel="noreferrer"
            className="text-bone-400 underline decoration-ink-600 underline-offset-2 hover:text-bone-200"
          >
            View on Etherscan
          </a>
        </p>
      )}

      {phase.kind === 'error' && <ErrorNote message={phase.message} />}
    </div>
  )
}

function Blocked({ reason }: { reason: string }) {
  return (
    <Button disabled disabledReason={reason}>
      Launch token
    </Button>
  )
}

function ErrorNote({ message }: { message: string }) {
  return (
    <p className="rounded-xl border border-danger-400/25 bg-danger-400/[0.06] px-4 py-3 text-[12px] leading-relaxed text-bone-400">
      {message}
    </p>
  )
}

function LinkRow({ label, value, href }: { label: string; value: string; href: string }) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer"
      className="flex items-center justify-between gap-3 rounded-xl border border-ink-700 bg-ink-900 px-3.5 py-2.5 transition-colors duration-150 hover:border-ink-600"
    >
      <span className="text-[11px] font-semibold uppercase tracking-wider text-bone-500">
        {label}
      </span>
      <span className="min-w-0 truncate font-mono text-[11.5px] text-bone-300">{value}</span>
    </a>
  )
}
