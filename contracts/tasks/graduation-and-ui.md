---
title: Graduation signal, then the launchpad UI
description: >
  Managed by a Kimaki handoff. Do not move or delete without updating the
  thread that created it. Contracts are green at 143 tests before this starts.
---

# Read first

- `tasks/feehook-and-launcher.md` — what was built and the four defects found.
- `script/Addresses.sol` — every address here was verified on chain, including
  the Chainlink feed enumeration that decides job 1's design.

Baseline: `forge test` = **143 passed, 0 failed**. Do not regress it.

# Job 1 — Graduation signal

shies' model, in his words: tokens **go live to the DEX immediately**, and when
one reaches a threshold the platform and trading apps get a notification that it
is "graduating" — i.e. mature. There is **no bonding curve and no liquidity
migration**. The LP is already locked from block 0 by `Launcher`.

So graduation is a **signal, not a mechanism**.

## Denominate the threshold in the PAIR ASSET, not USD

This is settled and evidence-backed — do not re-litigate it. Chainlink's mainnet
reference-data-directory was enumerated (292 feeds, 192 Crypto) and cross-checked
against the FeedRegistry:

```
DIRECT   ETH · USDC · UNI · WLFI · APE · LINK · AAVE · CRV
DERIVED  SHIB  (only SHIB/ETH exists; multiply by ETH/USD)
NONE     PEPE · SPX · ELON · FLOKI · Mog · NPC · ANDY · APU · WOJAK ·
         PORK · WOLF · ENA · ANIME · XMR · XRP
```

**PEPE has no feed of any kind on L1.** A USD threshold is therefore impossible
on chain for exactly the memecoin pairs this launchpad exists to serve. Pair-unit
thresholds work uniformly for every pair, need no oracle, and keep a manipulable
spot price out of the latch. **The UI renders dollars off-chain.**

## Requirements

- Threshold set at launch, in pair-currency units. Immutable afterwards.
- **One-way latch.** Once graduated, never un-graduates, even if price falls.
- `checkGraduation(PoolId)` permissionless and idempotent; emits `Graduated`
  once. Indexers key off that event.
- **Gate nothing of value on it.** Market cap is derived from `slot0`'s
  sqrtPriceX96, which is a spot price manipulable inside one transaction. A
  notification is an acceptable use; a payout or unlock is not. Say so in the
  docstring.
- Watch EIP-170: `Launcher` is at 9,790 B of 24,576. Prefer putting this on the
  hook or a standalone reader over growing `Launcher`.

## Tests required

Local suite plus a **pinned mainnet fork** case, matching `LauncherFork.t.sol`
(fork block 25,875,500, real PoolManager, real WXMR). Cover: below threshold does
not fire, crossing fires exactly once, falling back below does not un-latch, and
a second call is a no-op.

# Job 2 — UI

Only after job 1 is green. `app/` is Vite + TypeScript.

**Load the `house-ui` skill FIRST**, before `frontend-design` or `impeccable`.
Non-negotiables from `~/.claude/CLAUDE.md`:

- **Mobile-first, 390x844 designed and screenshotted first.** One primary action
  per screen.
- **Never write UI blind.** Research real references → build → serve via
  `kimaki tunnel` + `tuistory` → screenshot with `playwriter` at desktop AND
  390x844 → critique → fix → re-screenshot. Minimum one loop.
- **No fake data. Ever.** No invented prices, holder counts, volumes or charts.
  If a feed does not exist, render `—`, not a confident zero and not
  `Math.random()`. This has been a real violation in a sibling project.
- Stock shadcn/Tailwind defaults shipped unmodified are not a deliverable.

## Screens, in priority order

1. **Launch form** — name, symbol, supply, pair picker, fee split, max wallet,
   dev buy, image (required) + banner 1500x500 (optional).
2. **Token page** — price, the graduation progress bar, holder dividend claim.
3. **Board** — live launches.

## Two things the UI must surface honestly

- **Pair depth warning.** Depth is a per-pair property. Real measured example:
  the main WXMR/WETH V2 pool holds **306.76 WXMR / 65.12 WETH** (~$314K) against
  a 7,000 total WXMR supply. A creator picking a thin pair should see that before
  they commit, not after.
- **Sells are currently free**, and the pool's `fee` field reads 0 because the
  hook charges instead. Any "0% fee" a naive indexer shows is wrong — display the
  real rate from the `FeeTaken` / `PoolConfigured` events.

# Open product decision, needs shies

Sells are uncharged by design (the fee must be payable in the pair currency).
Nobody has actually decided whether that is right. Do not add a sell tax
unilaterally.
