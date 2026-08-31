---
title: Rewards rework, multi-dividend, sell tax, and a supply locker
description: >
  Design brief. NOTHING HERE IS BUILT. Written 2026-09 after research into current
  Uniswap v4 hook practice. Read it, argue with it, then pick what gets built.
  Baseline before any of this starts: forge test = 192 passed, 0 failed.
---

# What this covers

Four asks, in the order they came up:

1. Confirm why rewards are paid in WETH and not native ETH
2. Let creators customise the fee structure (partly already true)
3. **Multi-dividend** — one token paying rewards in several currencies at once
4. **A supply locker** so buyers can see whether the dev locked anything

Plus a fifth that fell out of the research and is arguably the most valuable:
converting fees into a reward currency is a **crank**, not a swap-time operation, and
that single decision unlocks asks 3 and 4's sibling (a sell tax) off one mechanism.

---

# Part 0 — Research: what v4 hook practice actually looks like in 2026

Everything below was read from primary sources on the dates given, not recalled.

## 0.1 The Trail of Bits hook security guide (2026-07-30)

`https://blog.trailofbits.com/2026/07/30/building-secure-uniswap-v4-hooks/`

The single most relevant document to this brief. Four findings that bear directly on
what we are about to build:

**A hook's accounting can be wrong even when settlement succeeds.** The PoolManager only
checks that the session's currency deltas resolve to zero. It does not validate the
hook's own books. The **Bunni exploit ($8.4M, September 2025)** was exactly this: a
rounding bug in BunniHook's idle-balance accounting. The attacker pushed the tick with a
flash loan, then made 44 tiny withdrawals that each shrank the active balance
disproportionately to the shares burned. **Every transaction satisfied the PoolManager's
settlement invariant.** Our `Distributor` is precisely this class of contract — an
internal accumulator whose correctness the PoolManager will never check for us.

**Keep non-essential code out of the main user flow.** Verbatim from the guide: *"If
reward distribution, dust cleanup, or other non-essential code reverts inside an
`afterRemoveLiquidity` callback, users cannot exit their positions. The same applies to
swaps when non-essential code reverts inside `afterSwap`."* Recommended fix: *"Wrap
optional external calls in try/catch, or move optional logic to a separate function users
can call after exiting."*

This is the entire argument for the crank, written by someone else, before we thought of
it. Swapping WETH→PEPE inside `afterSwap` puts a second pool's liquidity, pausability and
solvency directly in the path of every trade on our token.

**Permission bits must match the code.** The **Sorella Angstrom** finding: the hook
returned a non-zero delta for a fee, but its config did not encode
`afterSwapReturnDelta`. The PoolManager was not authorised to settle the delta, so
**every swap reverted `CurrencyNotSettled` once the fee was enabled.** Our flags are
`0x20CC` and any new return-delta path must be re-checked against them.

**Three accounting invariants they say to test:**
1. No user receives output the accounting did not charge for.
2. A same-transaction round trip cannot create value from accounting alone.
3. Internal accounting matches actual asset balances.

They also say to state explicitly which token behaviours you support — fee-on-transfer,
rebasing, callback-enabled, pausable, blacklistable — and to fuzz with Echidna or Medusa
rather than only testing happy paths.

## 0.2 `poolManager.take()` needs the manager to actually hold that token

From Uniswap's own custom-accounting guide:

> Using `poolManager.take()` requires an ERC20 balance on the PoolManager, i.e. via other
> liquidity pools. If the `.take()` amount exceeds the ERC20 balance, the code will
> revert. As a workaround, use either: 1. `poolManager.mint()` to obtain ERC6909, which
> are also more gas efficient, or 2. a custom swap router.

**This kills the naive version of multi-dividend outright.** A WETH-paired pool cannot
`take()` PEPE, because the singleton holds no PEPE on our behalf. The reward currency can
only ever be obtained by an actual swap, somewhere. It confirms conversion has to be a
separate step, not a fee-taking trick.

It also flags a **free optimisation we are currently leaving on the table**: `mint()` to
an ERC-6909 claim is cheaper than `take()`, and `FeeHook` currently uses `take()` on
every single charged swap. See Part 5.

## 0.3 The reward-per-share accumulator is the settled pattern

`LPRewardHook` (akshay-ap, 2026-06) uses the Synthetix / MasterChef accumulator:
one cumulative `accFeePerLiquidityX128` per pool per currency, each position storing a
checkpoint, settle is O(1) regardless of how many swaps happened in between. **No
per-swap loop and no per-LP loop anywhere.** It keeps *two* accumulators because the fee
can land in either currency.

That is the same shape as our `Distributor._magnifiedPayoutPerShare`, and the "one
accumulator per reward currency" extension is the proven route to multi-dividend.

## 0.4 Permissionless cranks are a proven pattern

`The Pool` (Adaptive Reserve Hook) exposes `collectYield()` that **anyone** may call, and
routes fees via `poolManager.donate()` into LP fee growth. Our `Distributor.processBatch`
is already this shape. A `convert()` crank is not novel or exotic; it is how these
systems are already built.

## 0.5 Where a fee should be charged

v4-by-example states charging on the **unspecified** currency is the recommended
practice. We deliberately do not — we charge the *specified* side in `beforeSwap` for
exact-input buys, because paying dividends strictly in the pair currency forces it. That
is why our flags are `0x20CC` and not the `0x2044` every other launchpad uses. Worth
re-stating because any new fee path must respect the same constraint.

---

# Part 1 — Native ETH vs WETH: settled, and why

**Conclusion: keep WETH. Do not add native-ETH pools for the reward currency.**

v4 genuinely supports native ETH — `CurrencyLibrary.ADDRESS_ZERO`, `isAddressZero()`, and
`Currency.transfer` branches on it with a `NativeTransferFailed` error. This is a real v4
capability that v3 lacked. We are choosing not to use it.

The reason is not network congestion. It is that **paying rewards means pushing value to
addresses we do not control**, and with native ETH every payment is a `.call{value:}`
where the recipient can:

- revert in `receive()` — a naive loop then reverts and **nobody** is ever paid
- burn unbounded gas in `receive()` — the batch costs more than it delivers
- re-enter the distributor mid-payment

`Distributor._trySend` already survives the first (raw call, reports failure, cursor moves
on). The residual native-ETH risks are the second and third, and they are not worth
taking for a token whose entire purpose is being pushed to thousands of holders.

ERC-20 also gives **bounded, predictable gas per payment**. Native ETH never does.

Cost of the choice, stated honestly: a creator seeding a launch must hold WETH, not ETH.
Native ETH in v4 is *cheaper* than WETH (no wrap step, and a raw send beats an ERC-20
balance write). We are paying a small gas premium for a large safety margin.

---

# Part 2 — Fee customisation: mostly already built

Already live, per launch, immutable after:

```
feeBps      0..1000     total fee, 10% hard ceiling  (FeeHook.MAX_FEE_BPS)
creatorBps  0..10000    creator's cut OF that fee
```

So **"5/5" already works** if it means 5% holders / 5% creator: `feeBps = 1000`,
`creatorBps = 5000`. That is on the launch form today.

**"5/5" meaning 5% buy / 5% sell does NOT work**, and cannot without Part 3.

---

# Part 3 — The keystone: conversion is a crank, not a swap-time operation

This is the decision everything else depends on.

## The problem

A fee is collected in the pair currency (WETH). A reward is owed in a different currency
(PEPE). Something must swap one for the other. There are only two places to do it.

## Option A — inside the hook, during the swap

v4 permits this. You are already inside `unlock`, so the hook can call
`poolManager.swap()` on another pool. It is also a trap:

- every buyer pays gas for a second swap
- your token inherits the reward pool's slippage on **every trade**
- the reward swap is sandwichable, per trade
- if the reward pool is thin, paused or blacklisted, **trading on your token degrades or
  reverts** — precisely the denial-of-service Trail of Bits calls out

## Option B — a permissionless crank *(recommended)*

```
  buy ──► FeeHook takes fee in WETH ──► Distributor holds WETH
                                             │
                                             │  (later, anyone calls)
                                             ▼
                                    convert(rewardToken, amountIn, minOut, deadline)
                                             │
                                             ▼
                              swap WETH → PEPE, credit the PEPE accumulator
```

- gas amortised over many trades instead of charged to every buyer
- one large swap with a real `minOut`, instead of N tiny unprotected ones
- a broken reward pool **stalls conversion**; it does not touch trading
- matches `The Pool`'s `collectYield()` and our own `processBatch` — a shape we have
  already shipped and tested

**Open question for shies:** who is expected to call `convert()` in practice, and what
pays for it? Options: pure altruism (bad), a small caller bounty skimmed from the
converted amount (standard, and self-funding), or we run a keeper (centralised, and
becomes a liability the moment it stops).

---

# Part 4 — What the crank unlocks

## 4.1 Sell tax

Sells are uncharged today because the fee must be payable in the pair currency, and a
sell pays *launch tokens* in. Converting them mid-swap is Option A.

**With a crank it just works**: charge the sell fee in launch tokens, accumulate, let the
crank sell them for the pair currency later. This is how every ordinary tax token
operates. It is the smaller of the two features and it validates the crank, so it should
ship first.

Note this changes the honesty copy currently on the token page and About page, which
states plainly that sells are free. That copy has to move in the same commit.

## 4.2 Multi-dividend (PEPE + FLOKI + SHIB at once)

Doable. The cost lands on **every transfer, forever**, which on L1 is the whole question.

Today `LaunchToken._update` calls `distributor.setBalance` twice per transfer — once per
side. Each writes a correction. Three approaches:

| | Shape | Cost per transfer | Verdict |
|---|---|---|---|
| 1 | Three separate `Distributor`s | 6 external calls | no |
| 2 | One distributor, `_corrections[token][account]` | 2 calls, 3× the correction writes | viable |
| 3 | Index-based, computed at claim time | 2 calls, ~flat | best if it holds up |

Option 3 is what `LPRewardHook` does: the accumulator advances globally, a holder's
checkpoint only moves when *they* are settled, and the owed amount is reconstructed at
claim. Transfers stay cheap; the holder pays when they claim.

**Do not pick from this table on argument. Measure it.** A gas benchmark of 1 vs 2 vs 3
reward tokens against today's baseline is a day of work and decides the design.

**Hard constraint carried over:** `minSharesForDistribution` exists because dividing a
fee by dust inflates the per-share accumulator until `_magnifiedPayoutPerShare * delta`
overflows and **bricks every transfer of the token**. That guard is per-accumulator and
must be replicated for every reward currency, not just the first.

## 4.3 Honest positioning

Multi-token reflections are **not new**. EverGrow paid BUSD; a long tail of SafeMoon
derivatives paid other tokens. All on BSC, because reflections are cheap there.

What is rare is doing it **on Ethereum L1 through a v4 hook**, and the reason is exactly
the gas maths above. That is still a real edge — it is just a narrower claim than "nobody
thought of this", and the narrower claim survives scrutiny. Marketing should use the
narrow one.

---

# Part 5 — Free win found during research: ERC-6909 instead of `take()`

`FeeHook` calls `poolManager.take()` on every charged swap. Uniswap's own docs say
`poolManager.mint()` (ERC-6909 claim) is **more gas efficient**, and it removes the
requirement that the singleton hold a sufficient ERC-20 balance at that instant.

The tradeoff: the Distributor would then hold claims rather than tokens, and needs a
`burn()` step to realise them — which the crank is already going to be, so the two fit
together.

Worth benchmarking alongside Part 4.2. This is a gas saving on **every single buy**.

---

# Part 6 — The supply locker

## 6.1 Read this before building it: there is nothing to lock

```solidity
// Launcher.launch
recipient: address(this),      // 100% of supply minted to the launcher
tokenSeed: p.supply,           // 100% of it seeded into the pool
// residual dust:
IERC20(d.token).safeTransfer(address(0xdEaD), leftoverToken);
```

**The entire supply goes into the pool. There is no team allocation, no presale, no
vesting bucket.** The creator's only tokens come from the optional dev buy, which is a
market swap at market price, capped at 10% of the seed.

So the question "did the dev lock their supply?" currently has a stronger answer than any
locker could give: **the dev never received supply to lock.** And the liquidity is
already unremovable by construction — the launcher owns the position and contains no code
path passing a negative `liquidityDelta`.

A locker that implies otherwise would make the product look *less* trustworthy by
suggesting there is a dev bag in the first place.

## 6.2 What is actually worth building

Two real options:

**Option A — lock the dev buy.** The creator's dev-buy tokens arrive wallet-to-wallet
(and, noted separately, bypass `maxWallet`). Letting a creator optionally lock those for
a chosen duration, with the lock visible on the token page, is a genuine signal: *"the
creator bought 8% at launch and cannot sell it for 90 days."* Small, self-contained, and
does not change the supply model.

**Option B — a general locker + optional team allocations.** Bigger, and it is a product
decision, not an engineering one: it means **weakening the current 100%-in-pool
guarantee** so creators can hold back supply. That may well be what the market expects,
but it should be a deliberate trade, not a side effect of adding a locker.

**Recommendation: Option A now, and only consider B if creators actually ask for
allocations.** Either way the UI must show the *absence* of a lock as loudly as its
presence, or a locker becomes a badge that only ever appears positive.

---

# Part 7 — Explicitly out of scope

**Bridging / "unbridging services" / one-stop shop.** A separate product with custody,
security and regulatory surface. Attaching it to an unaudited, undeployed launchpad would
be the riskiest item on this entire list. Parked, deliberately.

---

# Part 8 — Proposed order

1. **Gas benchmark.** 1 vs 2 vs 3 reward currencies, options 2 and 3 from Part 4.2, plus
   `take()` vs `mint()` from Part 5. Produces numbers, no production code.
2. **`convert()` crank.** Permissionless, gas-bounded, `minOut` + deadline, caller-bounty
   question answered. The keystone.
3. **Sell tax.** Smaller, validates the crank, and forces the honesty copy update.
4. **Dev-buy locker.** Self-contained, no dependency on 1–3.
5. **Multi-dividend.** Using whichever accumulator won step 1.

Each step lands green before the next begins. The suite is at 192 and that is not being
traded for velocity.

---

# Part 9 — Test requirements for any of this

Non-negotiable, drawn from Trail of Bits plus what this repo already learned:

- **Both currency orientations.** Every existing suite runs twice for a reason.
- **A pinned mainnet fork case**, matching `LauncherFork.t.sol`.
- **The three accounting invariants**: nothing unpaid-for goes out; no same-tx round trip
  creates value; internal accounting matches real balances.
- **Hostile reward token**: reverting, fee-on-transfer, pausable, blacklisting. State
  which are supported and prove the rest degrade without bricking trading.
- **The overflow guard, per reward currency.** A one-wei first holder must not be able to
  brick transfers through any accumulator.
- **A reverting/paused reward pool must not stop trading** — the whole point of the crank.
- **Fuzz, not just happy paths.** Echidna or Medusa, per the guide.

---

# Open questions for shies

1. Who calls `convert()`, and what pays them? (caller bounty is the standard answer)
2. Sell tax — same rate as buys, or independently settable?
3. How many simultaneous reward currencies is enough? Three? Five? The cap directly sets
   the per-transfer gas floor.
4. Locker: dev-buy only (Option A), or open the door to team allocations (Option B)?
5. Multi-reward splits — fixed at launch, or creator-adjustable later? Adjustable
   reintroduces the "a fee that can change after people buy is a rug with extra steps"
   problem the current design deliberately avoids.
