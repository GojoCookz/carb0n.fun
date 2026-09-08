/**
 * Buy and sell a launched token.
 *
 * Deliberately small. A trade box is five decisions — what you pay with, direction, amount,
 * slippage, confirm — and everything beyond those competes with them. The panel refuses to draw a
 * number it has not actually quoted from the pool; an empty output line is correct where an
 * optimistic one is a lie the user pays for.
 *
 * **The default is ETH, and that is the most important line in this file.** Holders are paid in the
 * pair currency — that is the product. But making the BUYER source it is a different thing, and it
 * killed the funnel at step one: a launch paired against PAXG asked a first-time buyer to go and
 * acquire PAXG. The zap routes ETH -> pair -> token in one transaction, so the pair currency is
 * still what pays holders and is no longer something anybody has to hold.
 *
 * **No green buy button.** The palette here is achromatic on purpose — the pair roster is the
 * subject and the interface does not spend colour on itself. Direction is carried by which tab is
 * lit and by `danger-400` on the sell side, which is the one hue this product already owns.
 */
import { useEffect, useRef, useState } from 'react'
import { formatUnits, type Address } from 'viem'
import { submitTrade, quoteTrade, type TradePhase } from '../lib/tradeTx'
import { submitZap, quoteZap, zapAvailable } from '../lib/zapTx'
import { explorerTx, walletErrorMessage, isUserRejection } from '../lib/wallet'
import { useWallet } from '../lib/useWallet'
import { activeNetwork } from '../lib/activeNetwork'

/** 1% default. High enough to clear a normal block, low enough that a sandwich is not free. */
const DEFAULT_SLIPPAGE_BPS = 100
const SLIPPAGE_CHOICES = [50, 100, 300] as const

function fmt(v: bigint, decimals: number): string {
  const n = Number(formatUnits(v, decimals))
  if (n === 0) return '0'
  if (n < 0.000001) return '<0.000001'
  return n.toLocaleString('en-US', { maximumSignificantDigits: 6 })
}

export function TradePanel({
  token,
  symbol,
  pair,
  pairSymbol,
  pairDecimals = 18,
  tokenDecimals = 18,
}: {
  token: Address
  symbol: string
  pair: Address
  pairSymbol: string
  pairDecimals?: number
  tokenDecimals?: number
}) {
  const { account, onRightChain, connect, switchChain, connecting, installed } = useWallet()

  // Whether a hop-1 pool actually exists for this pair, read from the deployment record rather
  // than assumed. Offering ETH where there is no ETH pool would send a transaction that reverts
  // `PoolNotInitialized`, which a buyer reads as the token being broken.
  const canZap = zapAvailable(pair)

  const [useEth, setUseEth] = useState(canZap)
  const [isBuy, setIsBuy] = useState(true)
  const [amount, setAmount] = useState('')
  const [slippageBps, setSlippageBps] = useState<number>(DEFAULT_SLIPPAGE_BPS)
  const [phase, setPhase] = useState<TradePhase>({ kind: 'idle' })
  const [quote, setQuote] = useState<bigint | null>(null)
  const [quoting, setQuoting] = useState(false)

  const parsed = Number(amount)
  const amountValid = amount.trim() !== '' && Number.isFinite(parsed) && parsed > 0
  const busy = phase.kind === 'approving' || phase.kind === 'trading'

  // On the ETH path the spent asset on a buy is ether and the received asset on a sell is ether.
  // The token side is unchanged either way.
  const settleSymbol = useEth ? 'ETH' : pairSymbol
  const settleDecimals = useEth ? 18 : pairDecimals
  const inSymbol = isBuy ? settleSymbol : symbol
  const outSymbol = isBuy ? symbol : settleSymbol
  const outDecimals = isBuy ? tokenDecimals : settleDecimals

  // Quote against the live route, debounced, and drop any answer that arrives after the inputs
  // have moved on — otherwise a slow reply overwrites a newer one and the user reads a stale price.
  const seq = useRef(0)
  useEffect(() => {
    if (!account || !onRightChain || !amountValid) {
      setQuote(null)
      setQuoting(false)
      return
    }
    const mine = ++seq.current
    setQuoting(true)
    const t = setTimeout(async () => {
      const args = {
        token,
        pair,
        pairDecimals,
        tokenDecimals,
        isBuy,
        amount: parsed,
        account,
      }
      const q = useEth ? await quoteZap(args) : await quoteTrade(args)
      if (mine !== seq.current) return
      setQuote(q)
      setQuoting(false)
    }, 350)
    return () => clearTimeout(t)
  }, [
    account,
    onRightChain,
    amountValid,
    parsed,
    isBuy,
    useEth,
    token,
    pair,
    pairDecimals,
    tokenDecimals,
  ])

  async function run() {
    if (!account) return
    setPhase({ kind: 'idle' })
    const args = {
      token,
      pair,
      pairDecimals,
      tokenDecimals,
      isBuy,
      amount: parsed,
      slippageBps,
      account,
    }
    try {
      if (useEth) await submitZap(args, setPhase)
      else await submitTrade(args, setPhase)
      setAmount('')
    } catch (e) {
      if (isUserRejection(e)) {
        setPhase({ kind: 'idle' })
        return
      }
      setPhase({ kind: 'error', message: walletErrorMessage(e) })
    }
  }

  const tab =
    'flex-1 rounded-lg py-2.5 font-display text-[13px] font-bold transition-colors duration-150'
  const currencyPill =
    'rounded-md px-2 py-1 font-display text-[11px] font-bold transition-colors duration-150'

  // The settlement currency, rendered beside the row it actually governs — the pay row on a buy,
  // the receive row on a sell. Two pills rather than a dropdown: there are exactly two options,
  // and hiding one behind a menu is what made the pair-currency requirement invisible in the first
  // place. Absent entirely when no ETH pool exists, because a control that cannot be used is worse
  // than no control.
  // **Each option says whether it is one hop or two.** `routed` is the whole zap explained in a
  // word: paying in ETH costs an extra swap through the ETH/pair pool, and a trader who is going
  // to be charged for that hop should be able to see it before they are. `direct` is the pair
  // currency, which touches only the launch pool.
  const selector = canZap ? (
    <span className="flex gap-1 rounded-lg border border-ink-700 bg-ink-950 p-0.5">
      <button
        type="button"
        onClick={() => setUseEth(true)}
        className={`${currencyPill} flex items-baseline gap-1 ${
          useEth ? 'bg-ink-700 text-bone-50' : 'text-bone-500 hover:text-bone-200'
        }`}
      >
        ETH
        <span className="font-sans text-[9px] font-medium uppercase tracking-wide opacity-60">
          routed
        </span>
      </button>
      <button
        type="button"
        onClick={() => setUseEth(false)}
        className={`${currencyPill} flex items-baseline gap-1 ${
          !useEth ? 'bg-ink-700 text-bone-50' : 'text-bone-500 hover:text-bone-200'
        }`}
      >
        {pairSymbol}
        <span className="font-sans text-[9px] font-medium uppercase tracking-wide opacity-60">
          direct
        </span>
      </button>
    </span>
  ) : null

  return (
    <div className="rounded-2xl border border-ink-700 bg-ink-900 p-4">
      {/* Direction. Two buttons rather than a swap arrow: the arrow hides which way you are
          pointed, and on a taxed pool the two directions are not symmetric. */}
      <div className="mb-4 flex gap-1.5 rounded-xl border border-ink-700 bg-ink-950 p-1">
        <button
          type="button"
          onClick={() => setIsBuy(true)}
          className={`${tab} ${isBuy ? 'bg-ink-700 text-bone-50' : 'text-bone-500 hover:text-bone-200'}`}
        >
          Buy
        </button>
        <button
          type="button"
          onClick={() => setIsBuy(false)}
          className={`${tab} ${!isBuy ? 'bg-ink-700 text-danger-400' : 'text-bone-500 hover:text-bone-200'}`}
        >
          Sell
        </button>
      </div>

      {/* **Not a `<label>` wrapping all of this, deliberately.** The currency selector is made of
          real buttons, and a `<label>`'s content model excludes interactive descendants other than
          its own labelled control. Nesting them there meant a click on the ETH pill would also be
          forwarded to the amount input, and it is invalid HTML besides. The label now wraps only
          the text that labels the field, associated by `htmlFor`. */}
      <div>
        <div className="flex min-h-[26px] items-center justify-between gap-2">
          <label
            htmlFor="trade-amount"
            className="text-[11px] uppercase tracking-wider text-bone-500"
          >
            You pay
          </label>
          {isBuy && selector}
        </div>
        <div className="mt-1.5 flex items-center gap-2 rounded-xl border border-ink-700 bg-ink-950 px-3.5 transition-colors duration-150 focus-within:border-ink-600">
          <input
            id="trade-amount"
            inputMode="decimal"
            placeholder="0.0"
            value={amount}
            onChange={(e) => {
              const v = e.target.value
              if (v === '' || /^\d*\.?\d*$/.test(v)) setAmount(v)
            }}
            className="min-w-0 flex-1 bg-transparent py-3 text-[17px] tabular-nums text-bone-50 outline-none placeholder:text-steel-500"
          />
          <span className="font-display text-[13px] font-bold text-bone-400">{inSymbol}</span>
        </div>
      </div>

      {/* Output. Blank until the route has actually answered. */}
      <div className="mt-3">
        <div className="flex min-h-[26px] items-center justify-between gap-2">
          <span className="text-[11px] uppercase tracking-wider text-bone-500">You receive</span>
          {!isBuy && selector}
        </div>
        <div className="mt-1.5 flex items-center justify-between gap-2 rounded-xl border border-ink-800 bg-ink-950/60 px-3.5 py-3">
          <span className="min-w-0 truncate text-[17px] tabular-nums text-bone-200">
            {quoting ? (
              <span className="text-steel-500">quoting…</span>
            ) : quote !== null ? (
              fmt(quote, outDecimals)
            ) : (
              <span className="text-steel-500">—</span>
            )}
          </span>
          <span className="font-display text-[13px] font-bold text-bone-400">{outSymbol}</span>
        </div>
        {quote !== null && (
          <p className="mt-1.5 text-[11px] leading-relaxed text-bone-500">
            At worst{' '}
            <span className="tabular-nums text-bone-400">
              {fmt((quote * BigInt(10_000 - slippageBps)) / 10_000n, outDecimals)} {outSymbol}
            </span>{' '}
            after slippage. The quote already includes the trading fee.
          </p>
        )}
      </div>

      <div className="mt-4 flex items-center gap-2">
        <span className="text-[11px] uppercase tracking-wider text-bone-500">Slippage</span>
        {SLIPPAGE_CHOICES.map((bps) => (
          <button
            key={bps}
            type="button"
            onClick={() => setSlippageBps(bps)}
            className={`rounded-md px-2 py-1 text-[11px] font-bold tabular-nums transition-colors duration-150 ${
              slippageBps === bps
                ? 'bg-bone-200 text-ink-950'
                : 'bg-ink-800 text-bone-500 hover:text-bone-200'
            }`}
          >
            {bps / 100}%
          </button>
        ))}
      </div>

      {/* What the ETH path actually is. Said out loud because a router that silently converts
          your money into an asset you did not choose is the kind of thing people find out about
          from a block explorer. */}
      {useEth && (
        <p className="mt-3 text-[11px] leading-relaxed text-bone-500">
          Routed <span className="text-bone-400">ETH → {pairSymbol} → {symbol}</span> in one
          transaction. Holders are still paid in {pairSymbol}; you just never have to hold it.
        </p>
      )}
      {!canZap && (
        <p className="mt-3 text-[11px] leading-relaxed text-bone-500">
          No ETH pool exists for {pairSymbol} on this network, so this launch can only be traded in{' '}
          {pairSymbol}.
        </p>
      )}

      {/* The sell-side pin. A pool sitting at its price limit rejects every sell until a buy
          lifts it off. That is a v4 property, not a fault in this pool, and a trader who meets it
          without warning concludes the token is a honeypot. */}
      {!isBuy && (
        <p className="mt-3 text-[11px] leading-relaxed text-bone-500">
          A pool that has never been bought from sits at its opening price and cannot process a
          sell. If this reverts and nothing has traded yet, that is why.
        </p>
      )}

      <div className="mt-4">
        {!installed ? (
          <p className="rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-center text-[13px] text-bone-500">
            No browser wallet detected.
          </p>
        ) : !account ? (
          <button
            type="button"
            onClick={connect}
            disabled={connecting}
            className="w-full rounded-xl border border-ink-600 bg-ink-800 px-5 py-3 font-display text-[14px] font-bold text-bone-200 transition-colors duration-150 hover:bg-ink-700 disabled:opacity-50"
          >
            {connecting ? 'Check your wallet…' : 'Connect wallet'}
          </button>
        ) : !onRightChain ? (
          <button
            type="button"
            onClick={switchChain}
            className="w-full rounded-xl border border-ink-600 bg-ink-800 px-5 py-3 font-display text-[14px] font-bold text-bone-200 transition-colors duration-150 hover:bg-ink-700"
          >
            Switch to {activeNetwork().label}
          </button>
        ) : (
          <button
            type="button"
            onClick={run}
            disabled={!amountValid || busy}
            className={`w-full rounded-xl px-5 py-3 font-display text-[14px] font-bold transition-colors duration-150 disabled:cursor-not-allowed disabled:opacity-40 ${
              isBuy
                ? 'bg-bone-50 text-ink-950 hover:bg-white'
                : 'border border-danger-400/40 bg-danger-400/10 text-danger-400 hover:bg-danger-400/20'
            }`}
          >
            {phase.kind === 'approving'
              ? 'Approving…'
              : phase.kind === 'trading'
                ? 'Confirming…'
                : !amountValid
                  ? 'Enter an amount'
                  : `${isBuy ? 'Buy' : 'Sell'} ${symbol} ${useEth ? 'with ETH' : `with ${pairSymbol}`}`}
          </button>
        )}
      </div>

      {phase.kind === 'done' && (
        <p className="mt-3 text-[12px] text-bone-200">
          Done — received {fmt(phase.amountOut, outDecimals)} {outSymbol}.{' '}
          <a
            href={explorerTx(phase.hash)}
            target="_blank"
            rel="noreferrer"
            className="text-bone-400 underline underline-offset-2 hover:text-bone-200"
          >
            View
          </a>
        </p>
      )}
      {phase.kind === 'error' && (
        <p className="mt-3 text-[12px] leading-relaxed text-danger-400">{phase.message}</p>
      )}
      {busy && phase.hash && (
        <p className="mt-3 text-[12px] text-bone-500">
          <a
            href={explorerTx(phase.hash)}
            target="_blank"
            rel="noreferrer"
            className="underline underline-offset-2 hover:text-bone-200"
          >
            Track on Etherscan
          </a>
        </p>
      )}
    </div>
  )
}
