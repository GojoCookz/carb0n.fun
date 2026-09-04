# Audit 05 — Economics, incentives and MEV

**Surface:** `src/FeeHook.sol`, `src/Launcher.sol`, `src/Distributor.sol`, `src/ReferralVault.sol`,
`src/VestingVault.sol`, `src/LaunchToken.sol` — read as an **incentive system**, not as code.

**Scope:** where a rational, well-capitalised adversary profits at somebody else's expense. Code
correctness was audits 01–04 and is not re-litigated here; where an economic finding is amplified
by a defect already reported, it is cross-referenced rather than re-counted.

**No file under `src/` was modified.**

New file: **`test/audit/EconAudit.t.sol`** — 44 tests, all green.
Suite total went **545 → 589 passed, 0 failed** (`forge test --no-match-contract Fork`).

---

## What I modelled

Every pool in this file is opened by the **real `Launcher`**, so it is single-sided: one position
holding the entire supply from the snapped opening tick to the far edge, and **zero pair currency
in the pool** until somebody buys. `test/FeeHook.t.sol` seeds a symmetric 1:1 book with liquidity on
both sides, which production never has and which hides every number below.

Every case runs **twice** — `EconAuditTokenIsCurrency0Test` and `EconAuditTokenIsCurrency1Test`.
The economics are identical to the wei in both orderings.

### The closed form the whole audit rests on

`_seedLiquidity` puts all of supply `S` into one position starting at `P_a = M/S`, where `M` is the
creator's `openingMarketCap` in pair units, running to the tick extreme. For a v3 position holding
only currency0 over `[P_a, P_b]`:

```
S = L * (1/sqrt(P_a) - 1/sqrt(P_b))  ~=  L / sqrt(P_a)      (P_b is astronomically large)
```

so **`L * sqrt(P_a) = S * P_a = M`, exactly**. Therefore

```
pairIn(f)  = M * f / (1 - f)          pair cost of a fraction f of supply
marketCap  = M / (1 - f)^2            spot market cap after buying f
avgPrice   = M / (S * (1 - f))
```

Three consequences, all reproduced on a live launcher-seeded pool:

1. **Half the supply costs exactly `M`.** Whatever the creator types into "opening market cap" is
   the price of the float, to the wei. Measured: `M` through the curve buys **49.92%** of supply.
2. **Pushing the spot market cap to a target `T` costs `sqrt(M*T) - M`** through the curve, and it
   is fully reversible in the same transaction.
3. **A round trip returns the input to the wei** — the opening tick is a hard floor with nothing
   below it, so the price walks back to exactly where it started. Measured: opening mcap
   `100.2905`, mcap after a 300-pair round trip `100.2905`. **The only unrecoverable cost of any
   round trip is `feeBps`.**

That last one is the engine of this entire audit. Every attack below is a zero-price-risk round
trip whose only cost is the buy fee, wrapped around a state read or a state write that somebody
else's money depends on.

### Costing convention

Amounts are in **pair units**. Where an absolute figure is needed, gas is priced at
**20 gwei on Ethereum L1** and the pair currency is assumed to be WETH, so 1 pair unit = 1 ETH and
an 800k-gas bundle costs 0.016 pair. Attacks are assumed to be flash-loanable (the pair currency is
allowlisted and liquid by construction — that is what `PairRegistry` is for), so **capital is not a
constraint; only absolute profit versus gas is.**

---

## Findings

**8 findings: 1 critical, 2 high, 3 medium, 2 low.** E-04 is listed for completeness and is a
*sound* result, not a finding.

| # | Severity | Mechanism | Attacker profit | Victim loss | Status |
|---|---|---|---|---|---|
| **E-01** | HIGH | Block-0 snipe of a single-sided open | +157.21 pair on 100 staked | −154.82 of 200 paid in | REPRODUCED |
| **E-02** | HIGH | Spot-price graduation is forgeable, and folding a sweep in makes it *pay* | **+4.01 pair** | signal integrity | REPRODUCED |
| **E-03** | **CRITICAL** | `buy → sweep → sell → withdraw` steals the dividend pot | **+4.87 pair on 40 deployed (12.18% ROI, atomic)** | **83.28% of the honest holder's dividend** | REPRODUCED |
| E-04 | *sound* | Sweep bounty | not farmable, not manufacturable | — | REPRODUCED (sound) |
| **E-05** | MEDIUM | Sweep's internal swaps have zero slippage protection | −8.63 (grief) | 14.92% of the burn never happens | REPRODUCED |
| **E-06** | MEDIUM | `maxWallet` is bypassable end-to-end | — | cap is theatre | REPRODUCED |
| **E-07** | MEDIUM | Vesting removes the dev-buy cap; the launch is born graduated | 78.21% of supply | 21.79% public float | REPRODUCED |
| **E-08** | LOW | 5-deep self-referral sybil | 40.00% of the platform cut, forever | platform treasury | REPRODUCED |
| **E-09** | LOW | At `feeBps = 100` the platform takes 100% of the fee | — | creator + holders get **zero** | REPRODUCED |

---

### E-03 — CRITICAL — `buy → sweep → sell → withdraw` takes the holders' dividend pot

`src/FeeHook.sol:745-758` (`sweep`, permissionless) + `src/Distributor.sol:189-205` (`distribute`,
pro-rata against the share register at that instant)
**REPRODUCED**, both orderings — `test_E03_buySweepSellCapturesTheHoldersPot`,
`test_E03b_theProfitCurveAndItsOptimum`, `test_E03c_whereTheDividendAttackStopsClearingGas`,
`test_E03d_theAttackAcrossTheLegalFeeBand`

**Dividend entitlement is measured at a single instant, and the attacker chooses the instant.**

`sweep()` is permissionless and idempotent, and `distribute()` splits against `totalShares` at the
moment it is called. So the attacker does not have to predict a sweep, win a race, or take any price
risk. They call it themselves, in the middle of their own round trip, in one transaction:

```
buy  →  sweep  →  sell  →  withdraw
```

The buy makes them the dominant shareholder. The sweep pays the whole accumulated pot out against
that register. The sell unwinds at the price the buy created (see the closed form: a round trip
returns the input to the wei). `withdraw` collects — and it still works after the sell, because
`Distributor._setShares` writes a correction that preserves `accumulativeOf` when the balance goes
to zero.

**Their entire cost is `feeBps` on the buy. Their revenue is the sweep bounty plus their share of a
pot that other people's trades paid for.**

#### The pool shape that makes it work is the normal one

A memecoin pool's fee pot is built by **turnover** — people who buy and then sell — while the share
register at any instant holds only the **resting float**. Pot large, register small, which is
exactly the ratio this needs. The scenario measured is a 5-pair resting holder and 400 pair of
round-trip volume against a 100-pair opening cap. That is a quiet day.

**This is made materially worse by audit 04 V-01**: the automatic sweep is unreachable from
exact-input swaps, which is the shape every router sends. So on ordinary traffic the pot is *never*
paid out incrementally — it just grows until somebody sweeps, and the attacker is the one with the
strongest incentive to be that somebody.

#### Measured

Default launch (`feeBps = 300`, `creatorBps = 2000`, `M = 100` pair):

```
pot at the moment of attack     :  12.1500 pair
share register before attack    :  46,128,724 tokens  (4.6% of supply, one resting holder)
attacker capital deployed       :  40.0000 pair
attacker share of the register  :  84.78%
ATTACKER NET PROFIT             :  +4.8738 pair       (12.18% ROI, zero blocks held)
                                                      (40.11% of the entire pot)
honest holder owed, honest sweep:   6.4479 pair
honest holder owed, attacked    :   1.0776 pair
HONEST HOLDER LOSS              :  -5.3702 pair       (83.28% of her dividend)
```

The profit curve, same pool, sweeping the attacker's buy size:

```
buyIn(pair) | profit(pair) | ROI on capital
     2.0000 |      1.7670  |  88.35%
     5.0000 |      3.0247  |  60.49%
    10.0000 |      3.9638  |  39.63%
    20.0000 |      4.6271  |  23.13%
    40.0000 |      4.8738  |  12.18%    <- absolute optimum
   120.0000 |      4.1326  |   3.44%
   400.0000 |      0.1948  |   0.04%
```

**88% ROI at the small end and it is never negative in the tested band.** With a flash loan the
capital is free, so the operator sizes for absolute profit, not ROI.

#### Where it stops clearing gas

The payoff scales with the pot and the pot scales with the pool, so there is **no size at which it
becomes unprofitable** — only a size at which the profit stops paying for an 800k-gas bundle
(0.016 pair at 20 gwei). Scaling the whole scenario with the opening cap:

```
openingMcap | volume | attacker profit | clears gas?
     0.1000 | 0.4000 |         0.0048  | no
     0.5000 | 2.0000 |         0.0243  | YES
     2.0000 | 8.0000 |         0.0974  | YES
    20.0000 | 80.000 |         0.9748  | YES
   100.0000 | 400.00 |         4.8738  | YES
```

**Break-even sits at an opening market cap of roughly 0.3 ETH.** Every launch anybody would call a
launch is above it, and the attack is repeatable every time the pot rebuilds.

#### It gets worse as the fee rises

`platformShareBps = 100 * BPS / feeBps`, so a higher trading fee leaves a bigger slice for holders —
which is a bigger slice for the attacker to take. Their own cost rises at the same rate, but the pot
they are taking was built by *everybody else's* volume, so the trade nets out in their favour:

```
feeBps | creatorBps | attacker profit
   100 |          0 |   -0.3777      (E-09: holders get nothing, so there is nothing to take)
   300 |          0 |   +6.3755
   600 |          0 |  +16.5329
  1000 |          0 |  +30.1233      <- 75% of the pot, at the legal ceiling
```

A creator who sets a high fee and routes it generously to holders is building a **larger prize for
the front-runner**, not a larger reward for holding.

#### Why this is critical rather than high

It is the only finding here that (a) pays the attacker directly out of another user's balance,
(b) requires no price risk, no inventory, no capital and no race, (c) is repeatable indefinitely,
and (d) makes the product's central promise — *hold and get paid in the pair currency* — false in
practice. A holder in this system is paid whatever is left after every sweep has been front-run.

The fix is not in the sweep. It is that entitlement must not be a single-instant read: a
time-weighted share, a snapshot taken at a block the caller cannot choose, or a minimum holding
period before `withdrawableOf` accrues.

---

### E-01 — HIGH — The block-0 snipe is a free option: downside capped at `feeBps`, upside unbounded

`src/Launcher.sol:599-632` (`_seedLiquidity`), `src/Launcher.sol:636-668` (`_devBuy`)
**REPRODUCED**, both orderings — `test_E01a_theCostOfTheFloatIsExactlyTheOpeningMarketCap`,
`test_E01b_block0SnipeIsAFreeOptionWithAMeasuredPayoff`,
`test_E01c_theDevBuyTakesTheCheapestSliceItDoesNotDefendIt`

The first buyer gets the whole float for the opening market cap. That is the closed form, and it is
measured: `M` through the curve buys **49.92% of supply**.

What makes it an attack rather than a trade is the **asymmetry**. The opening tick is a hard floor
with no liquidity below it, so a sniper who sells straight back recovers everything except the buy
fee. Measured on a default 3% launch:

```
sniper stake                        : 100.0000 pair
supply sniped                       :  49.16%
P/L if nobody ever shows up         :  -3.0000 pair    <- the entire downside, = feeBps
P/L after 200 pair of organic volume: +157.2064 pair
organic buyers paid in              : 200.0000 pair
organic bags now worth              :  45.1804 pair
ORGANIC LOSS                        : -154.8195 pair   (77% of everything they put in)
```

**A 3-pair premium on a 157-pair payoff. A better than 50:1 option, written by the launch itself,
free to anyone in block 0.** The sniper cannot lose more than the fee because the floor means the
price cannot go below where they bought.

#### The dev buy does not defend the opening — it takes the best slice of it

`_devBuy` runs as the first swap inside the launch transaction, so it consumes the cheapest part of
the curve. It does not raise the sniper's cost to reach any given cumulative fraction (the closed
form depends only on cumulative `f`, not on who bought). It simply reserves the cheapest tokens for
the creator. Measured at the full unvested 10% cap:

```
creator supply           :  8.81% of supply
creator average price    : 113,392,330,965 wei/token
sniper supply            : 40.34% of supply
sniper average price     : 223,064,228,200 wei/token   <- 196.71% of the creator's
```

**The dev buy is the best-priced entry in the token's entire life, and it is uncontested and
atomic.** It does not slow the sniper down; it is simply ahead of them in the queue.

#### Is this a bug?

It is inherent to opening single-sided at a price the creator picks. But two things make it worse
than it needs to be and both are in the code's control:

- **Nothing bounds the opening market cap from below.** `_validate` requires only
  `openingMarketCap != 0`. A creator who sets `M` low so that "early buyers get in cheap" is
  literally setting the price at which a bot takes the entire float.
- **There is no opening rate limit** — no per-block cap, no decaying tax, no first-N-blocks
  restriction. Audit 04 V-01 means the fee is not even paid out to holders during those blocks.

The honest summary for the token page: **the opening market cap is not a starting valuation, it is
the strike price of a call option on the whole supply, and it is exercisable by the first
transaction.**

---

### E-02 — HIGH — Graduation is a spot read; forging it is not merely cheap, it *pays*

`src/FeeHook.sol:456-470` (`checkGraduation`), `src/FeeHook.sol:509-524` (`_marketCap` reads
`slot0.sqrtPriceX96`), `src/Launcher.sol:487-489` (threshold validation)
**REPRODUCED**, both orderings — `test_E02_forcingGraduationCostsOnlyTheBuyFee`,
`test_E02b_theCheapestLegalGraduationBarIsOneWeiAboveTheOpen`,
`test_E02c_foldingTheSweepIntoTheGraduationPushPaysForIt`

The docstring at `FeeHook.sol:444-451` states the risk plainly and correctly. This finding is the
**price tag** on it, which the docstring does not have.

Cost to push the spot to a target `T` is `sqrt(M*T) - M` through the curve, and the position unwinds
at the same price in the same transaction. Sells are free on the default launch, so it is a
**one-legged toll on a fully reversible move**. On the repo's own default parameters (`M = 100`,
`T = 5M = 500`):

```
closed-form curve push            : 123.6067 pair
notional sent (grossed for fee)   : 128.4296 pair
NET COST OF A FAKE GRADUATION     :  -3.8528 pair    (77 bps of the threshold)
market cap after the unwind       : 100.2905 pair    <- back at the floor
```

The latch is one-way, so **the token is now permanently "graduated" with a real market cap of
100.29 against a 500 bar.**

#### Fold a sweep in and the attacker is *paid* to do it

The push that fakes the market cap also makes the attacker the dominant shareholder for one instant,
so E-03 composes with it for free:

```
buy → checkGraduation → sweep → sell → withdraw

notional pushed                   : 129.4296 pair
NET P/L OF A FAKE GRADUATION      :  +4.0114 pair
```

**Forging the graduation signal has a negative cost.** The attacker does it, gets paid 4.01 pair,
and the token is graduated forever.

#### And the bar can legally be one wei above the open

`Launcher._validate` only requires `graduationThreshold > openingMarketCap`. A creator who wants a
green tick on day one can have one:

```
cost to latch a 1-wei-above-open bar : -0.0003 pair   (0.03 bps of the opening cap)
```

**Impact.** The hook gates nothing of value on this, which is correct. But the event is the entire
product surface of graduation (`FeeHook.sol:231` — *"Indexers key off it"*), and the three UI
screens, any listing bot and any "graduated" filter are downstream consumers that cannot tell a real
crossing from a 400k-gas transaction. Anything that keys off `Graduated` is keying off a value the
beneficiary can write for less than the gas it costs to read it — and, with the sweep folded in, for
a profit. If graduation is ever to mean anything, it needs a TWAP or a cumulative-volume measure
(`totalFeesTaken` is already tracked per pool and is not spot-manipulable), not `slot0`.

---

### E-05 — MEDIUM — The sweep's internal swaps have no slippage protection; the burn is starved

`src/FeeHook.sol:799-810` (sell-fee conversion) and `:821-832` (buyback), both with
`sqrtPriceLimitX96` pinned at `MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE - 1`
**REPRODUCED**, both orderings — `test_E05_sandwichingTheBurnAndTheSellConversion`,
`test_E05b_theBurnIsPredictableButTooSmallToBeWorthSandwiching`

`unlockCallback` runs two swaps against the token's own pool with **zero slippage protection**, and
because `sweep` is permissionless the attacker does not even need to front-run — they bracket the
sweep inside their own transaction.

Measured against an honest sweep from the identical state (`sellFeeBps = 500`, `burnBps = 2000`):

```
tokens burned, honest sweep  : 2,485,137,650,544,957,729,522,577
tokens burned, sandwiched    : 2,114,265,945,431,577,572,275,012
BURN SHORTFALL               :   370,871,705,113,380,157,247,565   (14.92% of the burn)
attacker P/L                 : -8.6260 pair
```

**This is a grief, not a theft.** The attacker's own P/L is negative in every configuration tested,
because the round-trip fee dwarfs what a sandwich of this size can extract (see the arithmetic in
the *sound* section below — the burn is 60 bps of the pool's pair reserve against a 600 bps
break-even). But the shortfall is **permanent**: supply that should have been destroyed never is,
and the deflation the creator advertised silently under-delivers by up to ~15%.

The realistic trigger is not a dedicated attacker. It is that **anyone running the E-03 dividend
attack starves the burn as a free side effect**, because the same large buy that makes them the
dominant shareholder also inflates the price the burn executes at. E-03 is highly profitable, so
this will happen on every pool that has both features armed.

One line fixes the exposure that matters: pass a real `sqrtPriceLimitX96` derived from the pre-swap
`slot0` plus a tolerance, on both internal swaps. Audit 04 V-04 wants the same swaps clamped for a
different reason (unsettled credit), so the two fixes are the same edit.

---

### E-06 — MEDIUM — `maxWallet` does not bound the final holding, only a single purchase

`src/LaunchToken.sol:170-183` (`_update` checks the cap only when `from == poolManager`)
**REPRODUCED**, both orderings — `test_E06_maxWalletIsBypassedByBuyingWideAndConsolidating`

Capping only buys is deliberate and correct — a cap that can block a sell is a honeypot, and the
docstring at `LaunchToken.sol:41-43` says so. The consequence is that **wallet-to-wallet transfers
are uncapped, so the cap does not bound the final holding either.** Buy wide, then consolidate:

```
advertised cap                : 200 bps of supply   ("2% max wallet")
wallets used                  : 12
final SINGLE-wallet holding   : 2,376 bps of supply  (23.76% — 11.9x the advertised cap)
evasion gas, buy leg          : 2,522,744
evasion gas, consolidate leg  :   400,898
gas per extra wallet          :   243,636
```

At 20 gwei that is **0.0049 pair (~$17) per extra wallet**, and a wallet buys 2% of supply. So the
price of owning 24% of a token that advertises a 2% cap is about **$200 in gas**. On a launch whose
opening cap is 100 pair, that 24% is worth ~31 pair.

**Verdict: on a single purchase the cap does exactly what it says, and that is worth something —
it stops a lazy one-click whale.** As a claim about the distribution of the token it is theatre, and
it should not be presented on the token page as a holder-concentration guarantee. Note also that
`Launcher.MIN_MAX_WALLET_BPS` is 0.1%, so the tightest legal cap costs an attacker 24x more gas but
is bypassed by exactly the same two steps.

---

### E-07 — MEDIUM — A vested dev buy is uncapped, and the launch is born graduated

`src/Launcher.sol:491-510` (the cap applies only to the unvested path),
`src/Launcher.sol:487-489` (threshold vs opening cap), `src/VestingVault.sol:53` (7-day floor)
**REPRODUCED**, both orderings — `test_E07_theWorstHonestLookingLaunch`,
`test_E07b_theFloorOnAnUncappedDevBuyIsSevenDays`

The worst launch that still reads as responsible on a token page: max fee, all of it to the creator,
a "1% max wallet" badge, a "5x to graduate" bar, and a 365-day vest with a 30-day cliff over a dev
buy of 4x the opening market cap.

```
creator supply            : 78.21% of supply
public float              : 21.79%
graduation bar            : 500.0000 pair
spot mcap in launch block : 2,112.5357 pair    <- 4.2x the bar
graduation progress bps   : 10,000             <- the UI bar is full before the first buyer
```

Two things fall out:

1. **The launch is born graduated.** `_validate` compares the threshold against
   `openingMarketCap` — a number that the dev buy in the *same transaction* immediately invalidates.
   `checkGraduation` succeeds in the launch block. This is precisely the outcome
   `GraduationThresholdTooLow` (`Launcher.sol:487`) exists to prevent, and the check is measured
   against the wrong quantity. The correct comparison is against the post-dev-buy market cap, which
   the launcher already has everything needed to compute.
2. **A capped buyer pays the creator 818 bps of their spend.** With `feeBps = 1000` and
   `creatorBps = 10000`, a buyer filling the 1% max wallet spends 24.1005 pair and hands
   1.9718 pair straight to the creator, while the creator holds 78% of the supply they are buying.

And the floor on the lock is seven days:

```
supply locked                    : 89.69% (on a 9x-opening-cap vested dev buy)
fully released after             : 7 days
```

**The trade is stated honestly in `VestingVault`'s own docstring** ("a vested dev buy is UNCAPPED …
a vested launch is not automatically safer than a capped one, it is *differently* safe"), so this is
not a hidden defect. It is a **parameter space that lets a 78%-supply, 10%-fee, 100%-to-creator
launch present with a max-wallet badge and a completed graduation bar.** The disclosure only works
if the front end surfaces the vault size and the schedule as prominently as it surfaces the
graduation tick — otherwise the two protections cancel: the cap is bypassed by choosing to vest, and
the vest is disclosed in an event nobody renders.

---

### E-08 — LOW — A five-deep self-referral chain refunds 40% of the platform cut, forever

`src/ReferralVault.sol:113-121` (`setReferrer`, write-once **per user**),
`src/Launcher.sol:461-463` (called during `launch`)
**REPRODUCED** — `test_E08_aFiveDeepSelfReferralChainRefundsFortyPercentOfThePlatformCut`,
`test_E08b_theSybilCannotDeepenTheChainBeyondFiveTiers`

`setReferrer` is write-once per *address*, which is not the same as per *person*. A chain is
established by launching, and **launching is free apart from gas** — that is the headline feature of
single-sided seeding. So one operator spins up six wallets, launches five throwaway tokens to wire
`W1 ← W2 ← W3 ← W4 ← W5`, then launches the real token naming `W5`. Every tier of the advertised
20/10/5/3/2 schedule is then occupied by the same person.

```
setup: 5 junk launches, total gas : 10,450,081     (~0.21 pair at 20 gwei)
real launch gas                   :  2,083,246
honest volume                     : 1,000.0000 pair
platform cut on that volume       :     9.9490 pair
REFUNDED TO THE SYBIL WALLETS     :     3.9796 pair   (40.00% of the cut, 0.39% of volume)
left for the treasury             :     5.9694 pair
```

**Payback is ~53 pair of lifetime volume**, after which it is pure margin. On a launch doing 1,000
pair of volume the operator recovers 3.98 pair for 0.21 pair of gas — an **18x return**, and the
claim persists for the life of the token.

Rated LOW, not higher, for three structural reasons that are all real and all in the code:

- **The victim is the platform treasury, not a user.** No holder, buyer or creator loses anything.
- **The loss is bounded and known at deploy time**: `sum(schedule) = 40%` and `MAX_TIERS = 5` is a
  hard cap in the bytecode. `test_E08b` builds a nine-deep chain and confirms **exactly 5** wallets
  are ever paid. The sybil cannot compound it by digging deeper.
- **`referrerOf` is write-once and a referrer must already exist**, so cycles are impossible and the
  walk is bounded regardless.

It should nevertheless be priced in as **an unconditional 40% haircut on referral revenue**, because
there is no cost to sybilling it and any operator running more than one launch will. If the schedule
is meant to reward real distribution, tiers 2–5 buy nothing that tier 1 does not already buy, and
deleting them cuts the leak from 40% to 20% with no loss of the legitimate use case.

Related, and worth one line: `Launcher._configureHook` records the referrer against **`msg.sender`**
(`Launcher.sol:462`) while `FeeHook._routeFee` credits against **`cfg.creator`**, which is
`p.feeRecipient` when set (`Launcher.sol:448`). A creator who routes fees to a team multisig
silently orphans their own referrer's claim, and it lands with the treasury instead.

---

### E-09 — LOW — At the minimum legal fee the platform takes 100% and holders get nothing

`src/FeeHook.sol:345` — `platformShareBps = PLATFORM_VOLUME_BPS * BPS / feeBps`
**REPRODUCED**, both orderings — `test_E09_atTheMinimumFeeTheHoldersAndCreatorGetNothing`

At `feeBps = 100` — which `configurePoolFull` explicitly accepts, since the floor check is
`feeBps < PLATFORM_VOLUME_BPS` — that expression evaluates to exactly `BPS`. `_routeFee` then sends
the whole fee to the platform and `rest` is zero. Measured on a 100-pair buy, with the creator
advertising `creatorBps = 8000`:

```
feeBps | platform | creator | holders
   100 |   0.9950 |  0.0000 |  0.0000     <- creator and holders receive NOTHING
   110 |   0.9949 |  0.0796 |  0.0199
   150 |   0.9949 |  0.3980 |  0.0995
   200 |   0.9950 |  0.7960 |  0.1990
   300 |   0.9949 |  1.5920 |  0.3980
```

The arithmetic is correct and the design intent (`FeeHook.sol:156-175`) is deliberate and good — a
flat share of volume is the right shape. The problem is presentational and it is at the boundary: a
creator who picks a **1% fee with 80% to holders** is configuring a launch that pays holders
**zero**, and nothing reverts, warns or clamps. The band is steep enough that even 1.5% delivers
only a third of the headline. Either raise the floor to something where the split is meaningful, or
have the launcher compute and return the effective creator/holder rate so a UI can show the real
number before signing.

---

## Sound / not worth attacking — with the numbers that make it so

Each of these was modelled as an attack, measured, and found not to pay. They are listed with the
figure that closes them, because "we thought about it" is not a finding.

**Wash trading can never be profitable.** `test_sound_washTradingIsAlwaysLossy`
The platform's flat 1% of volume comes off the top before the creator/holder split, so the maximum
any single party can recover from their own fee is `(1 - 100/feeBps) * 0.995 < 1`. Measured with the
attacker as *both* the creator (`creatorBps = 10000`) and effectively the whole holder base, at the
`feeBps = 1000` ceiling — the most favourable configuration that exists:

```
wash trade P/L over 500 pair of self-volume : -4.9750 pair
platform take                               : +4.9750 pair
```

Every wei of the loss is the platform's cut. There is no fee configuration in the legal band where
this turns positive. **This is the single best economic property in the system** and it is why the
volume-denominated platform fee should not be changed to a share-of-fee.

**The sweep bounty cannot be farmed by splitting.** `test_E04a_splittingTheSweepCannotFarmTheBounty`
`sweep` is idempotent and pays 0.5% of what is actually pending, so N calls over the same pot pay
0.5% of the pot once — minus a wei of truncation each — and cost N times the gas:

```
bounty, one sweep  : 0.0075 pair    gas: 165,835
bounty, ten sweeps : 0.0075 pair    gas: 744,320   (4.5x the gas, identical bounty)
```

**Manufacturing volume to farm the bounty is strictly lossy.**
`test_E04b_manufacturingVolumeToFarmTheBountyIsLossy`
You pay `feeBps` to create a pot and take 0.5% of it back:

```
wash-trade-for-bounty P/L : -2.9850 pair on a 100 pair round trip
```

The bounty is 1/60th of the fee that creates it at the default rate, and 1/200th at the ceiling.
It is priced correctly: enough to pay a bot's gas, never enough to be worth manufacturing.

**Sandwiching the burn wedge is ~10x underwater.**
`test_E05b_theBurnIsPredictableButTooSmallToBeWorthSandwiching`
A sandwich of a victim buy `v` in a book of pair depth `R` extracts roughly `a*v/(2R)` against a
round-trip cost of `feeBps * a`, so it only pays when `v > 2 * feeBps * R` — **6% of the pool's pair
reserve** at the default 3% fee. The burn wedge is nowhere near that:

```
pool pair reserve                : 200.0000 pair
burn notional (the 'victim')     :   1.2000 pair
...as bps of the reserve         :  60 bps
sandwich break-even needs        : 600 bps
dedicated sandwicher P/L         : -11.3129 pair
```

The same arithmetic closes the sell-fee conversion, which is smaller still. **Both are safe from a
dedicated sandwicher purely because they are small relative to the book** — which means the
protection is a coincidence of sizing, not a property of the code, and it evaporates if `burnBps` or
the accumulation window is ever increased. The griefing exposure in E-05 stands regardless.

**There is no JIT-liquidity MEV.** `test_sound_thereIsNoLpFeeSoThereIsNoJitMev`
`PoolKey.fee` is **0** on every launch (`Launcher.sol:350`) and the hook keeps the entire fee, so a
liquidity provider earns nothing at all. Measured: a JIT LP that adds a full-range position, absorbs
a 500-pair trade and withdraws is left with pure inventory risk and **0.0015 pair** of movement,
none of it fee income. This removes the whole JIT class — nobody has a reason to add liquidity in
front of a large swap and pull it afterwards. It is a genuine and underrated benefit of taking the
fee in the hook.

**The opening price is a hard floor and the round trip is exact.**
`test_sound_theOpeningPriceIsAHardFloor`
There is no liquidity below the opening tick, so no amount of selling pushes the price through it:

```
opening mcap                     : 100.2905 pair
mcap after a 300-pair round trip : 100.2905 pair
```

This is worth stating as a *sound* property because it is what makes the pool honest — the creator
cannot be dumped through their own floor — and simultaneously what makes E-01 and E-02 free. It cuts
both ways and the report should say so.

**The referral schedule cannot be deepened.** `test_E08b_theSybilCannotDeepenTheChainBeyondFiveTiers`
A nine-deep chain pays **exactly 5** wallets. `MAX_TIERS` is in the bytecode, the schedule is
constructor-fixed, and `credit`'s walk is bounded by `tierCount`. The sybil's take is capped at 40%
and cannot be compounded.

**Fee immutability holds under every economic attack tried.** No path was found by which a creator
changes `feeBps`, `creatorBps`, `burnBps`, the graduation threshold or the payout route after
people have bought. That is audit 03's surface and it held here too.

---

## Cross-references — economic amplifiers of already-reported defects

- **Audit 04 V-01** (the auto sweep is unreachable from exact-input swaps) is what lets the dividend
  pot grow unpaid on ordinary router traffic. Without it, E-03's prize would be drained
  incrementally by honest trades. **Fixing V-01 materially shrinks E-03; leaving it makes E-03 a
  standing bounty on every pool.**
- **Audit 04 V-03** (a price-limited exact-input buy pays the full fee on input it never spent,
  measured at a 90.87% effective rate) is the one attack surface in the system where a sandwicher
  can impose a large loss on a *specific* victim. It pairs naturally with E-01: the sniper who owns
  the float is also the party best placed to move the price into a later buyer's limit.
- **Audit 04 V-04** (the buyback can leave an unsettled pair credit) wants exactly the same one-line
  clamp on `unlockCallback`'s swaps that E-05 wants for slippage. One edit closes both.
- **Audit 01 F-05** (`sweep()` bricks once the sell-fee pile outgrows the pool's pair reserve) is a
  denial of the payout path. It is not economically exploitable for profit, but it is the failure
  mode a launch with a sell tax will actually hit, and it is still open.

---

## Plainly

**The system's money-in / money-out arithmetic is sound.** The platform's flat 1% of volume makes
wash trading provably lossy in every legal configuration, the sweep bounty is priced too low to
manufacture and cannot be split, there is no LP fee so there is no JIT MEV, the fee split is
genuinely immutable, and the referral leak is hard-capped in the bytecode. Those are real properties
and several of them are better than the comparable launchpads.

**What is wrong is that two pieces of state that other people's money depends on are readable and
writable at an instant the attacker chooses.**

- `Distributor`'s share register at the moment of `sweep()` decides who is paid. The attacker picks
  the moment. **+4.87 pair for zero blocks of risk, 83.28% of an honest holder's dividend, 88% ROI
  at the small end, break-even at a 0.3 ETH opening cap, repeatable forever.** That is E-03 and it
  is the finding to fix first.
- `slot0.sqrtPriceX96` at the moment of `checkGraduation()` decides whether a launch is "mature".
  The attacker picks the moment, and with the sweep folded into the same bundle they are **paid
  4.01 pair** to write it.

And one thing that is not a defect but should be said in plain language on the token page rather
than in a docstring: **the opening market cap is the strike price of a call option on the entire
supply, exercisable by the first transaction, with a premium equal to the trading fee.** At the
repo's own default parameters that option cost 3 pair and paid 157.

---

## Reproduction

```
$env:PATH="C:\Users\shies\.foundry\bin;$env:PATH"
forge test --match-path "test/audit/EconAudit.t.sol" -vv     # 44 tests, all logging their numbers
forge test --no-match-contract Fork                          # 589 passed, 0 failed
```

Every figure in this document is a `console2.log` line from that run, in both currency orderings,
against a pool opened by the real `Launcher`.
