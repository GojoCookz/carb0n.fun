# Audit 01 — Fee accounting and arithmetic in `src/FeeHook.sol`

**Scope:** `src/FeeHook.sol` only — the charging legs (`_beforeSwap` / `_afterSwap`), accrual
(`_accrue`, `pendingFees`, `pendingTokenFees`), redemption (`sweep` / `unlockCallback` /
`autoRedeem`), the split (`_routeFee`, `platformShareBps`, `SWEEP_BOUNTY_BPS`) and `_marketCap`.
`src/Launcher.sol::_configureHook` and `_validate` were read for how the config is produced.
Nothing under `src/` was modified.

**Evidence:** `test/audit/FeeAudit.t.sol`, 32 tests, all passing. Every finding below marked
REPRODUCED has a named test in that file. The full suite is still green:
`forge test --no-match-contract Fork` → **436 passed, 0 failed**.

---

## What was actually exercised

A second, purpose-built v4 world (`FeeAuditWorld`) that can mint pools with **arbitrary** fee
shapes, because `FeeHookHarness` hardcodes `FEE_BPS = 300` / `CREATOR_BPS = 2000` as constants and
`PlatformDilution.t.sol:78` explicitly bounds its burn fuzz to `burnBps <= 5000` — so several of
the configurations below cannot be expressed by the existing suite at all. On top of that I added
a **single-sided** pool builder that seeds liquidity the way `Launcher` really does (all launch
token, nothing below the opening tick); the existing harness seeds a symmetric full range at 1:1,
which is a shape production never has and which hides every "the pool ran out of pair currency"
path. Within that world I exercised: all four swap shapes in both currency orderings; the
exact-in vs exact-out fee base compared on a bit-identical curve via `vm.snapshotState`; sweep
bounty farming by repetition and by fragmentation; cross-pool claim attribution with two pools
sharing one token, one pair currency and one hook; end-to-end wei-level conservation across the
platform/creator/holder/bounty split; the `autoRedeem` burn-reserve round trip decoded from the
`Burned` event; and `_marketCap` swept across the entire legal `sqrtPriceX96` band by writing
`slot0` directly with `vm.store` (1,000 fuzz runs), plus a located overflow boundary.

**Result: 1 high, 2 medium, 2 low, 1 informational.** The high one permanently bricks `sweep()`.

---

## Findings

### F-05 — `sweep()` bricks permanently once the sell-fee pile outgrows the pool's pair reserve

- **SEVERITY: HIGH**
- **Location:** `src/FeeHook.sol:797-813` (the conversion block), specifically the unchecked
  `poolManager.burn(...)` at `:798` paired with the `poolManager.swap(...)` at `:799-810`
- **REPRODUCED** — `test_F05_sweepBricksWhenTheSellPileExceedsThePoolsPairReserve`, passing in
  **both** currency orderings

`unlockCallback` burns the **whole** `pendingTokenFees` claim into a launch-token credit and then
tries to sell all of it in a single exact-input swap. It never checks that the swap consumed what
it burned, and it has no partial path.

A production pool is seeded single-sided, so there is **no liquidity below the opening tick** and
the pool's pair balance is only ever what buyers have put in. As soon as the accumulated sell tax
is worth more pair currency than the pool still holds, that conversion cannot complete. Two
distinct reverts, both confirmed in the trace, both permanent:

| Mode | Condition | Revert |
|---|---|---|
| 1 | Price already pinned at the bottom of the seeded range — i.e. exactly the `sqrtPriceLimitX96` the conversion passes | `Pool.PriceLimitAlreadyExceeded` |
| 2 | Price slightly off the floor, so the swap is legal and **partially fills** | `IPoolManager.CurrencyNotSettled` |

Mode 2 is the delta that opens and never closes: `burn` credits the hook `tokenAmount`, the swap
spends less than that, the remainder is a positive delta nothing takes, and the unlock cycle ends
non-zero.

**What an attacker gains.** This is reachable without an attacker — any large holder dumping
(creator allocation, airdrop, vested unlock) into a young pool does it — but it is also cheaply
**weaponisable**, and that is the part that matters. `sweep()` is the *only* code path that ever
clears `pendingTokenFees`, and it reverts before reaching the line that clears it. So the state is
self-perpetuating. Once tripped:

- every future `sweep()` on that pool reverts, for every caller, forever;
- the pool's **pair-currency** fees are trapped behind it too — they are queued in the same call
  and go down with it (asserted in the test: `pendingFees > 0` and unreachable);
- holders stop being paid dividends permanently, which is the entire product;
- the creator stops being paid, and the platform stops being paid.

The only partial mitigation that survives is `autoRedeem`, which handles pair claims independently
— but it only fires on **exact-output** swaps (see F-06) and only when `autoSweepThreshold` was
armed by `configureGraduation`, so it is not a reliable backstop.

The test also shows the griefing cost is trivial: in the reproduction, a single sell of tokens the
attacker already holds is enough, and there is no minimum position size in the mechanism — only in
how far the price has to be pushed, which on a young single-sided pool is nearly free.

---

### F-01 — `burnBps = 10_000` pays the platform, the creator and the holders exactly nothing

- **SEVERITY: MEDIUM**
- **Location:** `src/FeeHook.sol:332` (the only guard) and `src/FeeHook.sol:818` (where the whole
  total is spent). Contradicts the stated invariant at `src/FeeHook.sol:869-870`.
- **REPRODUCED** — `test_F01_burnBps10000_paysPlatformAndHoldersNothing`

`configurePoolFull` enforces only `creatorBps + burnBps <= BPS`, so `creatorBps = 0,
burnBps = 10_000` is legal. `unlockCallback:818` then computes `toBurn = totalPair` and
`totalPair -= toBurn` leaves zero, so `_routeFee` is never reached and the bounty block at `:847`
is skipped too.

The docstring at `:869-870` states plainly that "no combination of `creatorBps` and `burnBps` can
leave the platform unpaid". That is false. `PlatformDilution.t.sol:78` bounds its fuzz to
`burnBps <= 5000` ("the harness creator takes 50%"), which is exactly why this was never reached —
the assertion `assertGt(volumeBps, 0, "a burn setting starved the platform entirely")` never sees
the configuration that starves it.

**What an attacker gains.** A creator launches a token charging up to the 10% cap, and the
launchpad earns **zero** on it in perpetuity, with no way to fix it (the config is immutable by
design). Holders also receive zero dividends despite the token being marketed as paying them.
`Launcher._validate` adds no bound of its own — it defers to `FeeHook.configurePool`, which owns
the caps (`Launcher.sol:511`) — so this configuration is reachable straight through `launch()`.

The same setting is also asserted to make the automatic path a permanent no-op that still costs
every exact-output trader the gas of reaching it: `autoRedeem` reserves 100%, computes
`payout == 0`, and returns having changed nothing
(`test_F01b_burnBps10000_makesAutoRedeemAPermanentNoOp`).

---

### F-02 — `platformShareBps` is derived from the BUY rate but applied to SELL fees too

- **SEVERITY: MEDIUM**
- **Location:** `src/FeeHook.sol:345` (derivation) applied at `src/FeeHook.sol:876` to a pot that
  `src/FeeHook.sol:797-813` has already merged converted sell fees into
- **REPRODUCED** — `test_F02_sellFeesArePaidToThePlatformAtTheBuyRateShare` (overpay) and
  `test_F02b_theInverseConfigurationUnderpaysThePlatformOnSells` (underpay)

`platformShareBps = PLATFORM_VOLUME_BPS * BPS / feeBps` converts "1% of volume" into "this fraction
of the fee". That identity only holds for money that arrived **at the rate `feeBps`**. Sell fees
arrive at `sellFeeBps`, are converted to the pair currency in `unlockCallback`, merged into the
same `totalPair`, and handed to `_routeFee`, which applies the buy-derived share to all of it.

The platform's actual take on sell volume is therefore
`(sellFeeBps / feeBps) × 1%`, unbounded in both directions across the legal range:

| `feeBps` | `sellFeeBps` | `platformShareBps` | measured platform take of **sell** volume |
|---|---|---|---|
| 100 (floor) | 1000 (cap) | 10 000 | **912 bps** — ~9.1× the documented flat rate |
| 1000 (cap) | 100 | 1 000 | **9 bps** — ~0.09× |

`PlatformFee.t.sol:79` asserts `assertLe(volumeBpsEarned, PLATFORM_VOLUME_BPS, "platform was
overpaid")`. It passes only because that fuzz hardcodes `sellFeeBps: 0`. With a sell tax
configured, the assertion is false.

**What an attacker gains.** Two directions, both real:

- **Creator underpays the platform.** Set `feeBps = 1000`, `sellFeeBps = 100`. The platform earns
  0.09% of sell volume instead of 1%. On a token whose volume is mostly exits this is a ~91%
  discount on the launchpad's revenue, chosen by the customer.
- **Creator accidentally destroys their own revenue.** Set `feeBps = 100` (the floor) with any
  meaningful sell tax and `platformShareBps` is `10_000` — the platform takes **100%** of every
  sell fee. The test asserts creator and holders receive exactly zero from the sell tax, while the
  UI would show a configured `creatorBps` of 50%.

---

### F-03 — Exact-output buys are systematically undercharged by exactly `feeBps`

- **SEVERITY: LOW**
- **Location:** `src/FeeHook.sol:591-592` (exact-in base) vs `src/FeeHook.sol:643-644`
  (exact-out base)
- **REPRODUCED** — `test_F03_exactOutputBuysAreSystematicallyUndercharged`,
  `test_F03b_theDiscountScalesWithTheRate`

The two legs charge the same rate on **different bases**:

- `_beforeSwap` charges `feeBps` of the amount the trader **hands over** — the fee comes *out of*
  the input, so the pool only receives `(1 − r)·G`.
- `_afterSwap` charges `feeBps` of the amount the pool **consumed**, added *on top*.

For the same delivered output those differ by exactly the fee rate. Measured on one pool, one
state, bit-identical curve (state snapshot + revert), 10% fee:

```
exact-in  fee: 10 000e18   trader paid 100 000e18
exact-out fee:  9 000e18   trader paid  99 000e18   <- same tokens delivered
fee discount for routing exact-output: 1000 bps (== feeBps)
```

At a realistic 3% rate the discount is 300 bps, again exactly `feeBps`. The relationship is
`feeOut / feeIn == 1 − r`.

**What an attacker gains.** Any router, aggregator or bot gets a deterministic fee discount of
`feeBps` (i.e. 3% off a 3% fee, 10% off a 10% fee) purely by expressing the buy as exact-output
instead of exact-input, and the trader also spends strictly less pair currency for the identical
number of tokens (`99 000e18` vs `100 000e18`). No capital, no timing, no MEV — just a different
`amountSpecified` sign. Revenue leakage scales with the share of flow that routes exact-output,
which for aggregators is not small. Rated LOW rather than MEDIUM because the loss is bounded by
`feeBps × feeBps` of volume and nothing is stolen, only under-collected.

Note this is a *different* issue from the partial-fill overcharge already documented at
`src/FeeHook.sol:550-554`; that one is acknowledged in-code, this one is not.

---

### F-04 — An auto-sweep's "reserved for burn" is burn-fractioned a second time

- **SEVERITY: LOW**
- **Location:** `src/FeeHook.sol:690-692` (the reserve) vs `src/FeeHook.sol:818` (the second
  application). Contradicts the intent stated at `src/FeeHook.sol:686-689`.
- **REPRODUCED** — `test_F04_autoSweepReserveIsBurnFractionedTwice`

`autoRedeem` parks `amount × burnBps / BPS` back into `pendingFees` so a later manual sweep can
spend it on the buyback the auto path cannot run. But `unlockCallback` has no way to know that
balance is already earmarked, so it applies `burnBps` to it **again**. Measured at `burnBps = 2000`:

```
reserved for burn by the auto sweep : 10 021.84e18
pair actually spent on the buyback  :  2 004.37e18   <- 20% of the reserve, not the reserve
```

Only `burnBps²` of the original fee is ever burned; the other `burnBps × (1 − burnBps)` is silently
re-routed to the platform, creator and holders.

**What an attacker gains.** Nothing directly — no value is stolen or lost. What is wrong is the
documented behaviour: the comment at `:686-689` exists specifically to promise that "the burn
wedge would look armed and do nothing" is prevented, and on any pool busy enough for auto-sweep to
carry its volume the wedge under-fires by an order of magnitude. A creator who chose a 20% burn as
their tokenomics gets ~4%, and the deflation claim in their marketing is wrong. Reported because
a silently-wrong burn rate is exactly the kind of number that ends up in a listing page.

---

### F-06 — `_tryAutoSweep` is unreachable on the default router shape

- **SEVERITY: INFORMATIONAL**
- **Location:** `src/FeeHook.sol:650`, guarded by the early return at `src/FeeHook.sol:631`
- **REASONED, plus observed as a precondition** in `test_F04_...` (`assertGt(backlog,
  autoSweepThreshold)` holds after an exact-input buy without the auto path having fired)

`_tryAutoSweep` is called at the very end of `_afterSwap`, after `if (exactInput) return` at
`:631`. Exact-input is the shape every router, aggregator and swap UI sends by default — the same
observation the file's own header makes at `:50-53` about the original zero-fee bug. So the
automatic payout path only ever runs on exact-output trades. It is not broken, but it will fire far
less often than the design reads, and it is the only backstop that survives F-05.

---

## Checked and found sound

Do not re-audit these; each has a passing test in `test/audit/FeeAudit.t.sol`.

**Currency selection across all eight shapes.** All four swap shapes × both currency orderings were
walked by hand against `Hooks.afterSwap`'s specified/unspecified assignment and exercised in both
concrete suites. `_beforeSwap:585-597` and `_afterSwap:624-647` pick the correct currency in every
one of the eight cases. The specified/unspecified reasoning in the header docblock is accurate.

**No double-charging.** The `exactInput` early return at `:631` is a correct and complete mutual
exclusion between the two legs. Already covered by `test_buyIsNeverDoubleCharged`.

**`_routeFee` can never sum to more than `fee`.** `toPlatform + (fee − toPlatform)` is `fee` by
construction and `toHolders` is a remainder, not a second division — the three parts sum to exactly
`fee` for all inputs. Verified end-to-end at wei precision against a real sweep at a deliberately
awkward `feeBps = 333` / `creatorBps = 3333`:
`test_sound_theThreeSlicesSumToExactlyTheSweptAmount` asserts platform + creator + holders + bounty
`== swept` exactly, and that the hook retains zero.

**`platformShareBps` truncation across 100..1000 bps.** `1_000_000 / feeBps` fits `uint16` for the
entire legal range (max 10 000 at the floor) and cannot divide by zero (the floor check at `:337`
runs first). Truncation is toward zero, so the platform is under- not over-paid, by at most
`1/platformShareBps` ≈ 0.1% relative at the worst point. Not a problem **on buy volume** — the
sell-volume case is F-02.

**`SWEEP_BOUNTY_BPS` cannot be farmed.** Two independent attacks tested and both fail:
- *Repetition* — `sweep` zeroes both counters and the `pairAmount == 0 && tokenAmount == 0` early
  return at `:751` makes every subsequent call a no-op. 20 consecutive sweeps pay exactly the first
  bounty and nothing more (`test_sound_sweepBountyCannotBeFarmedByRepetition`).
- *Fragmentation* — `sweep` has no amount parameter, so a backlog cannot be split; and because the
  bounty is a linear 0.5% with floor division, sweeping five times pays ≤ sweeping once
  (`test_sound_fragmentingSweepsNeverEarnsMoreBounty`: 15e18 either way).

**Fees are not cross-attributed between pools.** Two pools sharing the same launch token, the same
pair currency and the same hook keep independent `pendingFees` at their own configured rates, and
sweeping one does not touch the other (`test_sound_feesAreNotCrossAttributedBetweenPools`). One
pool cannot redeem another's ERC-6909 claims even though the hook's claim balance is a single
global figure per currency, because `pendingFees[id]` is the only thing ever burned
(`test_sound_onePoolCannotRedeemAnothersClaims`).

**`_accrue` cannot double-count or lose a fee.** Buys and sells write to disjoint counters
(`pendingFees` vs `pendingTokenFees`), `mint` precedes the returned delta in both legs so the
hook's net delta is zero, and the mint/burn pair is symmetric. The one asymmetry —
`totalFeesTaken` is incremented only for buys (`:731`) — is diagnostics-only and matches the
`FeeTaken`/`FeeAccrued` event semantics.

**`autoRedeem`'s deltas balance mid-swap.** `mint` (debt) in `_accrue`, then `burn` (credit) +
`take` (debt) inside `autoRedeem`, then the returned `+fee` on the unspecified currency — net zero
across the unlock cycle. `take` drawing on reserves the trader has not settled yet is real but
correctly isolated by the `try/catch` at `:671-675`.

**The buyback swap at `:821-832` cannot partially fill in practice.** Unlike the sell conversion
(F-05), it spends pair currency to buy the launch token, and a single-sided pool holds the entire
unsold supply on that side. Its `zeroForOne`/`sqrtPriceLimitX96` pairing was checked in both
orderings and is correct.

**`_marketCap` does not overflow, does not lose meaningful precision, and never reads high.**
1,000 fuzz runs across the entire legal band (`MIN_SQRT_PRICE`..`MAX_SQRT_PRICE`) × supplies from
1e18 to 1e33 (a SHIB-sized supply), each asserted against a strictly-higher-precision upper bound
computed by squaring the price first and rounding both steps up:
`testFuzz_marketCapNeverOverflowsAndNeverReadsHigh`. The chained-`mulDiv` split is correct and the
"errs LOW" claim at `:506-508` holds — truncation is toward zero at both steps, so a graduation can
be late by a wei of market cap but never early. Both tick extremes return finite values at a real
1e27 supply (`test_marketCapSurvivesBothTickExtremes`; `MIN` truncates to 0, which is correct, not
a revert).

The overflow boundary was **located**, not assumed: `_marketCap` reverts once `supply × price`
exceeds `2^256`, which at `MAX_SQRT_PRICE` (price ≈ `2^128`) puts the boundary just above `2^128`
wei of supply, ~3.4e20 whole tokens. `Launcher` puts no upper bound on `supply`, so it is
technically reachable — but it needs an absurd supply *and* a price of ~`2^128` pair-wei per
token-wei simultaneously. A 1e33 supply survives the very top of the band
(`test_marketCapOverflowBoundaryIsUnreachableInPractice`). Not worth a guard.

---

## Not found

I did not find any path that lets a caller **extract** value from the hook: no way to redeem
another pool's claims, no way to farm the bounty, no way to make the three-way split exceed the
fee, and no rounding direction that favours the caller. The hook retains nothing after a
successful sweep. The value-at-risk in this surface is availability (F-05) and mis-configuration
(F-01, F-02), not theft.
