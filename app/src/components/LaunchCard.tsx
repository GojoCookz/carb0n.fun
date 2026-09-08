import { useState } from 'react'
import { ipfsCandidates, ipfsWalk } from '../lib/ipfs'
import { digestToCids } from '../lib/cid'
import { Link } from 'react-router-dom'
import { TokenLogo } from './TokenLogo'
import { GraduationBar } from './GraduationBar'
import { formatUsd, shortAddress } from '../lib/chain'
import { fmtAmount, fmtBps, fmtDuration } from '../lib/launch'
import { ageLabel, type LaunchListing } from '../lib/listing'

// The gateway lives in `lib/ipfs.ts`. It used to be `https://ipfs.io/ipfs/` here, which
// started returning 429 and blanked every image on the pad - see that file for the
// measurement and why a shared public gateway is not infrastructure.

/**
 * One launch on the board.
 *
 * ## Structure taken from lunch.fun, the closest live comparable
 *
 * Their card is the best thing on their site and it is DENSER than ours was without reading as
 * busy, which is the trick worth learning. Three things transfer:
 *
 *  1. **The banner is the card, not a thumbnail.** Art fills the header with the ticker set over
 *     it. Every launch already uploads a banner and we were rendering it nowhere.
 *  2. **A compact badge row over the art**, top-left, read before anything else: pair, tax,
 *     graduated. Ours were a text row at the bottom, below the fold of a small card.
 *  3. **`3/3%` for buy and sell tax.** Five characters carrying both sides. We wrote a sentence.
 *     This is the single best borrowable detail on their board.
 *
 * ## What was NOT taken
 *
 * **Their card shows 24h volume, holder count and price change. Ours cannot and must not.**
 * There is no indexer here, so those are numbers we would have to invent, and a board is the most
 * tempting place in the product to invent them — an empty grid looks broken and a full one looks
 * like a market. Every figure below traces to a contract call or to the visitor's own draft.
 *
 * The contract address stays on the tile with a working copy button. `PairRegistry` is an ADDRESS
 * allowlist precisely because tickers are not identity: 361 separate contracts have used the
 * symbol `GME` on one chain alone.
 */
export function LaunchCard({ listing }: { listing: LaunchListing }) {
  const {
    address,
    name,
    symbol,
    pair,
    marketCapPair,
    marketCapUsd,
    thresholdPair,
    openingPair,
    graduated,
    holderFeeBps,
    buyFeeBps,
    sellFeeBps,
    burnBps,
    vestDuration,
    isDraft,
  } = listing

  const body = (
    <>
      {/* --- Art, ticker and the badges that matter most ------------------------------- */}
      <div className="relative">
        <Banner cid={listing.bannerCid} />

        <div className="absolute inset-x-0 top-0 flex items-start justify-between gap-2 p-2.5">
          <Badges
            pairSymbol={pair.symbol}
            buyFeeBps={buyFeeBps}
            sellFeeBps={sellFeeBps}
            burnBps={burnBps}
            vestDuration={vestDuration}
          />
          {graduated && (
            <span className="shrink-0 rounded-md bg-bone-50 px-1.5 py-0.5 font-mono text-[10px] font-bold uppercase text-ink-950">
              grad
            </span>
          )}
        </div>

        {/* No blend mode. `mix-blend-overlay` vanishes against dark art and behaves differently
            on every photo a creator uploads; a fixed opacity over the scrim reads on both. */}
        <p
          className="pointer-events-none absolute bottom-1 right-3 max-w-[62%] truncate font-display text-[26px] font-bold uppercase leading-none tracking-tight text-bone-50/30"
          style={{ textShadow: '0 1px 12px rgba(0,0,0,0.5)' }}
        >
          {symbol}
        </p>
      </div>

      {/* --- Identity ------------------------------------------------------------------- */}
      {/* `relative` so the avatar's negative margin lifts it ABOVE the banner rather than being
          painted over by this block's own background. */}
      <div className="relative flex items-start gap-2.5 px-3.5 pb-3">
        <Avatar cid={listing.imageCid} symbol={symbol} />

        <div className="min-w-0 flex-1 pt-2.5">
          <div className="flex items-baseline justify-between gap-2">
            <p className="min-w-0 truncate font-display text-[15px] font-bold leading-tight text-bone-50">
              {name}
            </p>
            <span className="tnum shrink-0 text-[10.5px] font-semibold text-bone-500">
              {ageLabel(listing.launchedAt)}
            </span>
          </div>

          <p className="mt-0.5 flex items-center gap-1.5 truncate font-mono text-[11.5px] text-bone-400">
            <span className="font-semibold text-bone-200">${symbol}</span>
            <span className="text-bone-600">·</span>
            <TokenLogo pair={pair} size={12} />
            <span>{pair.symbol}</span>
          </p>
        </div>
      </div>

      <div className="px-3.5 pb-3">
        <AddressChip address={address} />
      </div>

      {/* --- The number and the bar -----------------------------------------------------
          **Only rendered when it is actually known.** The board reads launches straight off the
          chain and does not fetch a pool price per token, so `thresholdPair` is zero for a real
          launch — and drawing "MARKET CAP 0 / graduates at 0" is a confident zero, which is
          precisely the invented number a board must never show. Absent beats wrong. */}
      {thresholdPair > 0 && (
        <div className="border-t border-ink-700 px-3.5 py-3">
          <div className="mb-2.5 flex items-end justify-between gap-3">
            <div className="min-w-0">
              <p className="text-[10px] font-semibold uppercase tracking-wider text-bone-500">
                Market cap
              </p>
              <p className="tnum mt-0.5 truncate font-display text-[19px] font-bold leading-none text-bone-50">
                {fmtAmount(marketCapPair)}{' '}
                <span className="font-mono text-[12px] font-medium text-bone-400">
                  {pair.symbol}
                </span>
              </p>
            </div>
            {marketCapUsd !== null && (
              <p className="tnum shrink-0 text-right text-[11px] text-bone-500">
                {formatUsd(marketCapUsd)}
              </p>
            )}
          </div>

          <GraduationBar
            compact
            marketCap={marketCapPair}
            threshold={thresholdPair}
            opening={openingPair}
            pairSymbol={pair.symbol}
          />
        </div>
      )}

      {holderFeeBps > 0 && (
        <div className="border-t border-ink-700 px-3.5 py-2.5">
          <p className="truncate text-[11.5px] text-bone-500">
            <span className="tnum font-semibold text-bone-200">{fmtBps(holderFeeBps)}</span> of
            every buy to holders, in {pair.symbol}
          </p>
        </div>
      )}
    </>
  )

  const shell =
    'block overflow-hidden rounded-(--radius-card) border bg-ink-850 transition-colors duration-150'

  if (isDraft) {
    return (
      <div className={`${shell} border-steel-500/40`}>
        <p className="border-b border-steel-500/30 bg-steel-500/10 px-3.5 py-2 text-[11px] font-semibold text-bone-200">
          Your draft — not launched, visible only to you
        </p>
        {body}
        <Link
          to="/"
          className="block border-t border-ink-700 px-4 py-2.5 text-center font-display text-[12.5px] font-bold text-bone-400 transition-colors duration-150 hover:bg-ink-800 hover:text-bone-200"
        >
          Keep editing
        </Link>
      </div>
    )
  }

  return <div className={`${shell} border-ink-700 hover:border-ink-600`}>{body}</div>
}

/**
 * The badge row, in the order somebody scanning a grid needs them.
 *
 * The pair comes first because it is what a holder gets PAID IN, which is the whole product. The
 * tax is second because it is what they pay. Anything that is off renders nothing at all — a row
 * of `0%` badges on every tile trains people to stop reading the row.
 */
function Badges({
  pairSymbol,
  buyFeeBps,
  sellFeeBps,
  burnBps,
  vestDuration,
}: {
  pairSymbol: string
  buyFeeBps: number
  sellFeeBps: number
  burnBps: number
  vestDuration: number
}) {
  const chip =
    'rounded-md border border-ink-700/60 bg-ink-950/75 px-1.5 py-0.5 font-mono text-[10px] font-semibold backdrop-blur-sm'

  return (
    <div className="flex min-w-0 flex-wrap items-center gap-1">
      <span className={`${chip} text-bone-200`}>⇄ {pairSymbol}</span>

      {/* Both sides in five characters. A trailing `/0` would be noise, so a free sell is a
          single figure and the tooltip carries the detail.

          **Hidden entirely when the rate is unknown.** A card read from the launcher does not
          fetch the hook's config, so `buyFeeBps` is zero because nobody asked — not because the
          launch is free. Rendering `0%` there would be an invented number. */}
      {buyFeeBps > 0 && (
        <span
          className={`${chip} ${sellFeeBps > 0 ? 'text-danger-400' : 'text-bone-400'}`}
          title={
            sellFeeBps > 0
              ? `${fmtBps(buyFeeBps)} on buys, ${fmtBps(sellFeeBps)} on sells`
              : `${fmtBps(buyFeeBps)} on buys, sells are free`
          }
        >
          {sellFeeBps > 0 ? `${buyFeeBps / 100}/${sellFeeBps / 100}%` : `${buyFeeBps / 100}%`}
        </span>
      )}

      {burnBps > 0 && (
        <span
          className={`${chip} text-bone-400`}
          title={`${fmtBps(burnBps)} of every swept fee buys this token back and burns it`}
        >
          burn
        </span>
      )}

      {vestDuration > 0 && (
        <span
          className={`${chip} text-bone-400`}
          title={`The creator's opening buy is locked for ${fmtDuration(vestDuration)}`}
        >
          locked
        </span>
      )}
    </div>
  )
}

/**
 * The address, with a copy button that actually copies. A control that looks like it does
 * something and does nothing is the failure this project bans, so before a launch exists there is
 * no button at all — just a statement that the address is assigned at launch.
 */
function AddressChip({ address }: { address: string | null }) {
  const [copied, setCopied] = useState(false)

  if (!address) {
    return <p className="font-mono text-[10.5px] text-bone-600">address assigned at launch</p>
  }

  return (
    <button
      type="button"
      onClick={async (e) => {
        e.preventDefault()
        try {
          await navigator.clipboard.writeText(address)
          setCopied(true)
          setTimeout(() => setCopied(false), 1400)
        } catch {
          // Clipboard is permission-gated. Say nothing rather than claim a copy that failed.
        }
      }}
      className="inline-flex items-center gap-1.5 rounded-md border border-ink-700 bg-ink-900 px-1.5 py-1 font-mono text-[10.5px] text-bone-400 transition-colors duration-150 hover:border-ink-600 hover:text-bone-200"
    >
      <span className="text-bone-600">CA</span>
      {shortAddress(address)}
      {copied ? (
        <svg width="11" height="11" viewBox="0 0 24 24" fill="none" aria-hidden>
          <path d="m5 13 4 4L19 7" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" />
        </svg>
      ) : (
        <svg width="11" height="11" viewBox="0 0 24 24" fill="none" aria-hidden>
          <rect x="9" y="9" width="11" height="11" rx="2" stroke="currentColor" strokeWidth="2" />
          <path d="M5 15V5a2 2 0 0 1 2-2h10" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
        </svg>
      )}
      <span className="sr-only">{copied ? 'Address copied' : 'Copy contract address'}</span>
    </button>
  )
}

/** The 1500x500 banner, at its real aspect ratio. Falls back to a hatch, never a broken image. */
function Banner({ cid }: { cid: string }) {
  const [failed, setFailed] = useState(false)

  if (!cid || failed) {
    return (
      <div aria-hidden className="relative h-[92px] w-full overflow-hidden bg-ink-800">
        <div
          className="absolute inset-0 opacity-40"
          style={{
            backgroundImage:
              'repeating-linear-gradient(115deg, transparent 0 9px, var(--color-ink-700) 9px 10px)',
          }}
        />
      </div>
    )
  }

  return (
    <div className="relative h-[92px] w-full overflow-hidden bg-ink-800">
      <img
        src={ipfsCandidates(cid, digestToCids(cid))[0]}
        alt=""
        loading="lazy"
        onError={ipfsWalk(ipfsCandidates(cid, digestToCids(cid)), () => setFailed(true))}
        className="size-full object-cover"
      />
      {/* Keeps the badges and ticker legible over arbitrary user art. */}
      <div
        aria-hidden
        className="absolute inset-0"
        style={{
          background:
            'linear-gradient(to bottom, rgba(0,0,0,0.45) 0%, rgba(0,0,0,0.05) 45%, rgba(0,0,0,0.35) 100%)',
        }}
      />
    </div>
  )
}

function Avatar({ cid, symbol }: { cid: string; symbol: string }) {
  const [failed, setFailed] = useState(false)

  if (!cid || failed) {
    return (
      <div
        aria-hidden
        className="relative z-10 -mt-5 flex size-12 shrink-0 items-center justify-center rounded-xl border-2 border-ink-850 bg-ink-800 font-display text-[14px] font-bold text-bone-500"
      >
        {symbol.slice(0, 2)}
      </div>
    )
  }

  return (
    <img
      src={ipfsCandidates(cid, digestToCids(cid))[0]}
      alt=""
      loading="lazy"
      onError={ipfsWalk(ipfsCandidates(cid, digestToCids(cid)), () => setFailed(true))}
      className="relative z-10 -mt-5 size-12 shrink-0 rounded-xl border-2 border-ink-850 bg-ink-800 object-cover"
    />
  )
}
