---
title: BaseStonk feature port to Ethereum L1
description: >
  Read from docs.basestonk.io 2026-09. Supersedes the keeper-crank recommendation in
  rewards-and-locker.md, which was written without reading those docs and got the
  central architecture call wrong.
---

# The correction that started this

`rewards-and-locker.md` recommended a **permissionless keeper crank** for converting
fees into reward assets, arguing that converting inside the swap puts a second pool's
liquidity in the path of every trade.

**BaseStonk converts on-chain with no keeper.** They solved the objection rather than
routing around it, with a price floor plus a halving retry plus graceful degradation:

```
P     = min(P_gate, P_market)                take the LOWER of two prices
floor = P x (1 - phi) x (1 - sigma/10000)    phi = real per-hop venue fee
                                             sigma = 100 bps/hop, capped 300/route

if impact(x) > sigma:  refuse, x <- x/2, retry     up to 8 times
if no size clears:     pay the PAIR CURRENCY instead
```

Three things worth stealing outright:

1. **`min(P_gate, P_market)`, not "check the two agree".** Checking agreement means an
   attacker must move both prices. Taking the minimum means they must move the one that
   is *already lower* - the expensive direction.
2. **Halve-and-retry** converts a thin slot in small pieces across several trades rather
   than eating one bad fill.
3. **Fallback to pair currency** answers "what if the reward pool is paused or thin".
   The slot degrades; trading never breaks.

A crank may still be right **on L1 specifically** - see Part 9 - but that is a gas
argument, not a safety one, and it was presented as the latter.

---

# Part 1 - Feature inventory

`OK` we have it, `NO` missing

| # | Feature | BaseStonk | Us |
|---|---|---|---|
| 1 | v4 pool from block one, no curve | OK | OK |
| 2 | Liquidity unpullable | OK | OK |
| 3 | Fee taken inside the swap by hook | OK | OK |
| 4 | Dividends in the pair currency | OK | OK |
| 5 | Max wallet, buys only | OK | OK |
| 6 | Dev buy, capped | OK | OK |
| 7 | **Single-sided seeding, launch price is a floor** | OK | **OK - shipped 5779da4** |
| 8 | **Dividend baskets, up to 10 assets** | OK | NO |
| 9 | **Sell tax, set independently of buy tax** | OK | NO |
| 10 | **Buyback and burn wedge** | OK | NO |
| 11 | **Liquidity wedge** | OK | NO |
| 12 | **Dev-buy vesting vault** | OK | NO |
| 13 | **Community takeover / controller seat** | OK | NO |
| 14 | **5-level referrals** | OK | NO |
| 15 | Platform token + dual buyback flywheel | OK | **REJECTED - Part 6.5** |
| 16 | Platform basket vault (46 assets) | OK | **REJECTED - depends on 15** |
| 17 | **Stock pairs, 3 pricing routes** | OK | **BLOCKED - Part 9** |
| 18 | **REST API / indexer** | OK | NO |
| 19 | Graduation signal | NO | OK |

---

# Part 2 - Dividend baskets (feature 8)

Creator picks up to 10 assets with weights at launch. Holders are paid in those assets,
converted on-chain, pushed as people trade.

**The pitch is arithmetic, and it is the strongest thing in their docs:**

> Dividends are a percentage of **trading volume**, not a cut of an LP fee. A 3% holder
> share on $200k/day delivers ~$2.2M of real assets per year.

| Daily vol | Annual vol | Delivered/yr | @$2M cap | @$5M cap |
|---|---|---|---|---|
| $200k | $73M | ~$2.2M | 110% | 44% |
| $500k | $182M | ~$5.5M | 275% | 110% |
| $1M | $365M | ~$11M | 550% | 220% |

Our UI says "2.4% of every buy to holders" and never converts that into an annual
figure. **That number is the product and we are not showing it.** No contract work
required - it is arithmetic on values we already hold.

## The controller seat

Basket *composition* sits behind a seat; the *percentage* never does.

```solidity
function setBasket(address[] tokens, uint16[] weights)  // 1..10, weights sum 10000
function transferBasketControl(address to)
function renounceBasket()                               // one-way, forever
```

No duplicates, no zero address or weight, never the launch token, empty means pair
currency. Renounce at launch via a flag in the launch tuple, or any time after. Public
`basketRenounced` so anyone can check whether the mix is policy or constant. **Nothing
in flight is lost on a rebuild** - value in a replaced slot moves to a residual entry
that keeps draining on the same pro-rata maths.

## Accounting

The accumulator we already have:

```
acc += delta_in / S_total
owed(h) = s_h x (acc - acc_h)
```

O(1) per holder. `Distributor._magnifiedPayoutPerShare` is this. Extending it to N
slots is the work.

---

# Part 3 - Single-sided seeding (feature 7) - DONE

Shipped in `5779da4`. Recorded here because the rest of the doc assumes it.

The creator gives an **opening market cap**, not a deposit. The whole supply is seeded
single-sided from that price outward and the pair side of the book is built by buyers.
Launching costs gas and nothing else, and the opening price is a floor because below it
there is nothing on the other side to pay with.

Consequences already handled:

- Opening price is snapped to a tick **before** the pool is initialised, so the first
  buyer does not cross an empty gap.
- Direction is geometry: a range above the price holds only currency0, below holds only
  currency1, so the side the token sorted onto decides it.
- **Fees had to move to ERC-6909 claims plus a `sweep()`**, because `take()` needs the
  singleton to hold the currency and a fresh single-sided pool holds none.

Their depth definition is worth keeping: `dy = L(sqrt(Pa) - sqrt(Pb))`. Depth is **how
much comes out for a given move**, not pool balance. They rank routes by output released
by a 2% move. Our board should do the same rather than showing TVL.

---

# Part 4 - Wedges (features 9, 10, 11)

Tax splits into named wedges that must sum to the whole, immutable after launch:

```
tau = w_payees + w_burn + w_liquidity + w_rewards
```

- **burn** - buys the token from its own pool and sends it to dead, *in the same
  transaction as the trade that funded it*
- **liquidity** - deepens the token's own pool
- **rewards** - to the distributor
- **payees** - creator, up to 8 wallets with custom shares

Burn effect on supply: `S(t+1) = S(t) - V x w_burn / (10000 x p)`. Burn pressure scales
with volume and **inversely with price** - the same dollar burns more tokens when the
price is lower.

**Buy and sell rates are separate sliders in their V6**, each up to 10% in 0.1% steps,
and the token page shows both. Our sell tax is unblocked now that `sweep()` exists: take
the fee in launch tokens, accumulate, convert on a sweep.

---

# Part 5 - Dev-buy vesting (feature 12)

The locker, and better than what was originally proposed.

- Vault per launch, linear release over **7 / 30 / 90 / 365 days**, optional cliff
- `VaultCreated(token, vault, beneficiary, vestCliff, vestDuration)` emitted **in the
  launch transaction** - the point is disclosure, not the lock
- 7-day floor, cliff <= duration
- **Extend, never shorten. Add, never subtract.** Up to 32 schedules per vault
- Beneficiary seat transferable - a project outliving its founding wallet
- `release()` callable by anyone; `vaultOf(token)` returns `address(0)` if unvested

**The honest trade, which they publish:** a vested dev buy is **uncapped**. The 10% cap
applies only to the unvested path. They swapped a cap for a disclosure.

**Locked tokens still accrue dividends.** Two one-way exits: `renounceAccrual`, and
`renounceOnTakeover` which fires automatically in a CTO transaction.

---

# Part 6 - Community takeover (feature 13)

`LaunchControl`, a registry of who controls each token's page - artwork, description,
links, operator seat. Explicitly **no power over pool, tax, split, supply or holdings**.

- `handOver(token, to)` - direct
- `handOverWithSig` - EIP-712 signed off-chain, anyone can submit; names token,
  recipient, nonce, expiry
- `proposeReassign(token, to)` -> **7-day clock** -> `executeReassign` by anyone
- **Founder veto:** `cancelReassign` any time in those 7 days kills it

> "A takeover the platform could execute instantly would make the platform the real
> controller of every token."

---

# Part 6.5 - NO PLATFORM TOKEN. Ever. (features 15 and 16)

**Settled product decision, not an open question. Do not reopen it.**

BaseStonk's platform token is the centre of their design: two buyback-and-burn engines,
a 46-asset platform vault, launches routing a share of their rewards into it. It is
genuinely clever and we are **not** copying it.

## Why a platform token kills a launchpad

1. **It puts the venue in competition with its own customers.** Every launch that pairs
   against the platform's token is a launch that did not pair against what its creator
   actually wanted. The pad starts steering pair selection toward itself and the roster
   stops being an honest menu.
2. **It moves the operator to the other side of the table.** Once platform revenue is a
   standing bid on a token the operator holds, every decision - which pairs get listed,
   which launches get promoted - carries a second motive. Creators feel that.
3. **It is a distraction from the only job that matters**, which is people deploying and
   trading. pump.fun was the largest launchpad on any chain for years with no platform
   token at all.
4. **It is the closest thing here to a security.** A token whose value accrues
   automatically from protocol revenue, bought and burnt by the protocol itself, is
   squarely Howey-shaped: money in, common enterprise, profit expected from the efforts
   of others. A trading fee paid to an operator is not. This is the largest legal
   exposure the design could take on, and declining it costs nothing.

## What replaces it

Nothing needs to. The pad earns a **fee** - revenue, not a security. Growth comes from
referrals and from the pair roster being the best on L1, not from a token that has to be
marketed separately from the product.

**A brand name is not a ticker.** If the pad is renamed, that is a name. There is no
token behind it, because there is nothing to tokenise.

---

# Part 7 - Referrals (feature 14)

Five levels, and the design detail that makes it work:

> **Every level earns a share of the SAME trade fee**, set by distance from the trader -
> not a fraction of a fraction. `E = sum(rho_d x Phi_d)`, explicitly **not**
> `sum(rho^d x Phi_d)`.

- Paid from the platform's **reported on-chain cut**, never estimated from volume
- Accrues in the pair currency of each trade, settled as one clean transfer on a rolling
  schedule; small balances roll forward
- Never expires; using a code also cuts the platform's take for the applier
- Paid out of the platform's cut only - creator and holder economics unchanged

**Blocker:** `FeeHook._routeFee` splits the fee between creator and holders and nothing
else. There is no platform share for a referral to come out of, and it must never come
out of the other two. A platform wedge has to exist first. The `/rewards` page states
this rather than implying a code is waiting.

---

# Part 8 - Anti-snipe details worth stealing

**Time-weighted allocation.** Vault rounds weight a holder by balance *and* duration,
integrated over the window, not by snapshot:

```
w_h = sum over [t0,t1] of b_h(t) x dt
```

> "A single-block snapshot is trivially sniped - buy immediately before it, sell
> immediately after - and the block is announced on chain when the round commits."

**The decaying toll.** A launch can arm a window of 10 seconds to 30 minutes where buys
pay a rate starting at 99% and falling linearly to the normal buy tax. Sells never pay
it: a sniper leaving harms nobody and they already paid on the way in. The token page
shows a live meter with the current rate and countdown - **the meter is the difference
between a protection and a trap.**

---

# Part 9 - What actually changes on L1

The real porting work. Their design assumes Base gas; ours cannot.

| Their assumption | L1 reality |
|---|---|
| Convert up to 10 basket slots on-chain per trade | 10 routed swaps per trade is unaffordable |
| Halve-and-retry up to 8x | 8 failed attempts is 8x the gas |
| Push dividends automatically as people trade | pushing to N holders per trade is brutal |
| Several hundred admitted pair tokens | L1 has fewer routable pairs, and thinner ones |

**So the L1 answer is a hybrid:**

- Keep the **floor guard and `min(P_gate, P_market)`** - pure win, costs nothing
- Keep **fallback to pair currency** - pure win
- **Convert opportunistically, not every trade.** We already have `sweep()`; conversion
  belongs there. This is where a crank earns its place, on gas grounds
- **Cap basket slots below 10** until benchmarked. Three may already be too many

## Stock pairs (feature 17) - BLOCKED, and not technically

They pair against Coinbase B20 and ST0x wrapped stocks on Base. L1 equivalents are Ondo
and Backed. **The blocker is legal:** these are Reg S instruments explicitly barred to
U.S. persons, and this project is US-based. Robinhood issues theirs through a Jersey
entity and a Lithuanian MiFID II firm and bans Americans outright. We have no such
structure.

**The L1 substitute is already shipped:** pay holders in **other chains** rather than in
stocks - WBTC, tBTC, LBTC, WXMR, WXRP, all wrapped onto Ethereum, all categorised in
`pairs.ts`. Same idea, different asset class, no securities exposure.

---

# Part 10 - Build order

1. **Sell tax** - smallest, unblocked by `sweep()`, forces the honesty copy update
2. **Burn wedge** - a third leg in `_routeFee`
3. **Dev-buy vesting vault** - self-contained, biggest trust win
4. **Volume-based yield figure in the UI** - no contract work, strongest single line in
   their whole pitch
5. **Basket benchmark on L1** - decides slot cap and conversion location
6. **Baskets** with floor guard, `min()` price and pair fallback
7. **Controller seat** then **LaunchControl**
8. **Platform fee wedge**, which unblocks referrals
9. **Referrals** - needs an indexer, so it follows the API

Items 1-4 are days. Items 5-9 are the real project.
