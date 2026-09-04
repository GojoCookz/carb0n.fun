# Round 2 — Audit 02 re-run: the streaming machinery in `src/Distributor.sol`

Re-audit after the streaming migration (`0793cba`, `c23b964`, `4fd4df5`). The brief was to attack
the FIXES, not the thing they replaced.

- **Surface:** `src/Distributor.sol` only. **Nothing in `src/` was modified.** `git diff -- src/`
  is empty.
- **New tests:** `test/audit/round2/DividendAudit2.t.sol` (26 tests),
  `test/audit/round2/StreamInvariant.t.sol` (6 stateful invariants at 16,384 calls each, plus one
  scripted non-vacuity control).
- **Suite:** baseline 601 passing / 0 failing → **634 passing / 0 failing**
  (`forge test --no-match-contract Fork`).

## Verdict up front

**The CRITICAL (E-03, instant capture) is genuinely dead.** I attacked it from five directions and
could not get a single base unit out of a zero-block position. The two properties that kill it —
`_checkpoint` cannot advance inside one block, and `_arm` credits the accumulator with nothing —
hold under 1,001-run fuzzing and 16,384-call stateful invariants, including through the paths that
did not exist in round 1 (`flush()`, the carry, a 20-hour stale checkpoint, a 1e6× mid-stream share
swing, `setExcluded` timing).

The Yearn weighted-average window also holds: **`streamFinish` can never be pushed further than one
`STREAM_WINDOW` ahead**, which is the Synthetix S-1 griefing defence that the whole design rests on.
That is now an explicit invariant.

What I did find is a family of **truncation and clock-reset defects in the new code**. None of them
lets an attacker take money. All of them either destroy dust or delay dust. One of them — the
converter delta check added in `4fd4df5` — is a real hole that settles a holder's entire claim while
paying them nothing, but it requires a hostile converter.

### Counts by severity

| Severity | Count | IDs |
|---|---|---|
| CRITICAL | 0 | — |
| HIGH | 0 | — |
| MEDIUM | 1 | R2-04 |
| LOW | 2 | R2-01, R2-03 |
| INFO | 1 | R2-02 |

---

## What I actually exercised

Reproduced by test unless marked otherwise.

**Arithmetic (`_arm` → `_checkpoint` → `withdrawableOf`)**
- Value conservation under 1,000-run fuzz across `distribute` / `flush` / `setBalance` / `withdraw`
  / warp orderings, at 2, 6 and 18 decimals.
- Stateful invariants, 6 × 256 runs × 64 depth = 16,384 calls each, with `flush()` and
  `setExcluded` in the handler (neither is in the existing `test/DistributorInvariant.t.sol`).
- `_perShareNow()` vs `_checkpoint()` rounding parity — `withdrawableOf` compared byte-for-byte
  against what `withdraw()` and `processBatch()` actually transfer, in the same block.
- The weighted-average window: convexity, sub-additivity of the rate, and the
  `finish ≤ now + STREAM_WINDOW` bound.
- The `vested == 0` branch, with and without a griefer re-arming.
- The dust carry (`_arm` line 303) and its round-trip through `flush()`.
- Overflow: `total * MAGNITUDE`, `elapsed * streamRate`, `vested * MAGNITUDE / shares`.

**Griefing**
- `flush()` called every block for 3,000 consecutive blocks, at 3,600 / 7,100 / 8,000 / 1e12 / 1e18
  base units, each against a side-by-side ungriefed control on the same wall clock.
- `flush()` spammed 200× inside one block.
- `setBalance` every block for a full window (the `LaunchToken._update` traffic pattern).

**Instant capture**
- Fuzzed buy → sweep → `flush` → `flush` → sell inside one block, over amount × attacker share ×
  honest share × pre-elapsed.
- A whale buying into a 20-hour stale checkpoint (the residual I most expected to survive).
- `setExcluded(false)` mid-stream.
- A 1e6× `totalShares` swing mid-stream.

**Converter**
- A converter that takes nothing but makes the distributor's balance fall by re-entering
  `processBatch`, on both the pull and the push path, each with a negative control.

### Harness note that cost me an hour, and would have produced a fabricated CRITICAL

`vm.warp(block.timestamp + dt)` **inside a loop in one test function is a no-op after the first
iteration.** solc treats `TIMESTAMP` as loop-invariant within a call frame and hoists it, so every
warp targets the same stale value. My first pass at the flush-grind probe read as "value creation,
101× the pot, distributor catastrophically insolvent". It was entirely an artefact. Every timed test
in this file goes through `vm.getBlockTimestamp()`, which is an external cheatcode call and cannot be
hoisted. The existing `test/DistributorInvariant.t.sol` is *not* affected — its `warp` is a separate
handler call, i.e. a separate frame.

---

## Findings

### R2-04 — MEDIUM — a re-entrant converter settles a holder's whole claim and pays them nothing

**Where:** `src/Distributor.sol:518` (`heldBefore`), `src/Distributor.sol:529-536` (the `taken`
test), reached from `src/Distributor.sol:450` (`withdraw`) and `src/Distributor.sol:479`
(`processBatch`).

**Status: REPRODUCED** — `test_R2_07_aReentrantConverterSettlesAClaimWithoutPayingIt`,
`test_R2_07c_thePushPathAlsoSettlesAClaimItNeverPaid`, with negative control
`test_R2_07b_control_withoutTheReentrancyTheHolderIsPaid`.

Round 1's D-01 fix changed the success test from "what the converter returned" to "what the
converter took":

```solidity
uint256 taken = heldBefore - IERC20(payoutToken).balanceOf(address(this));
if (taken != 0) { ... return true; }
```

`taken` is a property of **this contract's balance**, not of the allowance. `processBatch` is
permissionless and re-entrant-reachable from inside `convert`. A converter that pulls nothing but
re-enters `processBatch` causes *somebody else's* payout to leave the contract, and the outer frame
reads that drop as proof the converter spent the allowance.

Because `withdraw()` increments `_withdrawn[msg.sender]` (line 450) *before* calling `_trySend`, a
`true` return finalises the claim. Measured: alice is debited `99999999999999999999` and receives
**zero**, in both the pair currency and the reward currency, with `PayoutSent(alice, amount)`
emitted. On the push path `processBatch` reports `sentTotal = 99999999999999999999` while
`199999999999999999998` actually left the contract, and none of it went to the account it was
credited against.

Round 1's `test_sound_aReentrantConverterCannotDoublePay` cannot see this: it only asserts nobody is
paid **more** than they are owed. This is an under-payment.

**Attacker gain:** the converter does not gain directly; the holder's dividend is destroyed (left on
the distributor, later claimable pro-rata by everyone else). A converter that also holds shares
converts other holders' claims into its own future entitlement.

**Trust boundary, stated plainly:** `converter` is a platform-wide singleton set once by the Launcher
deployer (`Launcher.initRewardConverter`, `Launcher.sol:306`), so this needs a malicious or
adversarially-composed converter, not a creator-supplied one. That is why it is MEDIUM and not HIGH.
It is still a real hole, because the contract's own documentation treats the converter as untrusted
("Judged by what it TOOK, not by what it SAID", "never an unbounded allowance"), and D-01 exists
precisely because a converter can lie.

**Fix:** measure allowance consumption, which no third party can move, instead of a balance delta:

```solidity
try IRewardConverter(converter).convert(payoutToken, rewardToken, amount, to) returns (uint256 out) {
    uint256 left = IERC20(payoutToken).allowance(address(this), converter);
    _clearAllowance();
    uint256 taken = amount - left;      // exactly what it pulled through OUR approval
    ...
}
```

This also removes the `heldBefore - balanceAfter` underflow panic already reported as round-1 D-07
(a converter that sends payout currency back reverts `withdraw()` and the whole batch), since the
subtraction is then over two numbers the converter alone controls. A `nonReentrant` guard on
`withdraw` / `processBatch` is a reasonable belt-and-braces addition but is not sufficient on its
own — the delta would still be wrong for any other cause of an outflow.

---

### R2-03 — LOW (MEDIUM for low-decimal pairs) — `_checkpoint` truncation destroys a real fraction of small streams, with no attacker

**Where:** `src/Distributor.sol:238` (`vested = (elapsed * streamRate) / MAGNITUDE`) together with
`src/Distributor.sol:245` (`lastCheckpoint = upTo`).

**Status: REPRODUCED** — `test_R2_03_frequentCheckpointsDestroyPartOfASmallStream`,
`test_R2_03c_lowDecimalPairsLoseARealFractionOfEverySmallStream`, control
`test_R2_03b_sound_frequentCheckpointsAreFreeOnANormalStream`.

**This is a hole in the round-2 "pre-magnified rate" fix specifically.** `streamRate` was made
pre-magnified (documented at `Distributor.sol:94-102`) exactly so that a low-decimal pair would not
truncate to zero. But `_checkpoint` divides the magnitude straight back out on every single call and
then advances `lastCheckpoint` by the **full** elapsed interval, discarding the remainder. The
`vested == 0` guard on line 244 protects the case where the vest rounds all the way to zero; it does
nothing for a vest that rounds from 6.9 to 6.

`LaunchToken._update` calls `setBalance` twice per transfer, so on a token that trades every block
`_checkpoint` runs ~7,200 times per 24h window, and each call can strand up to one base unit.

Measured, 6-decimal pair (USDC/USDG), checkpointed once per 12s block for a full window:

| fee armed | never vests | loss |
|---|---|---|
| 0.01 USDG (`10_000`) | `2_800` | **28.00%** |
| 0.10 USDG (`100_000`) | `6_400` | 6.40% |
| 1.00 USDG (`1_000_000`) | `6_400` | 0.64% |
| 10.0 USDG (`10_000_000`) | `6_400` | 0.06% |

The absolute loss saturates at ~6,400 base units per window (≈ one per checkpoint), which is
0.0064 USDG on a 6-decimal pair and 6,400 wei on an 18-decimal pair. The 18-decimal case is
genuinely nothing; the low-decimal case eats double-digit percentages of small fee streams, which is
exactly the population the magnification fix was written for. On an 18-decimal pair the same effect
destroys a third of a 3,600-wei stream (`3599 → 2400`) — real, but worthless.

The money is not stolen. It sits on the distributor unaccounted and outside `pendingPayouts`, so
`flush()` cannot recover it.

**Fix:** advance the clock only by the time actually paid for, leaving the sub-unit remainder on it:

```solidity
uint256 vested = (uint256(upTo - from) * streamRate) / MAGNITUDE;
if (vested == 0) return;
lastCheckpoint = from + uint64((vested * MAGNITUDE) / streamRate);
```

This is the same idea as the existing `vested == 0` guard, generalised from "round to zero" to
"round to anything". It also removes most of R2-02.

---

### R2-01 — LOW — permissionless `flush()` can pin `lastCheckpoint` to `now` and freeze a small stream indefinitely

**Where:** `src/Distributor.sol:326` (`flush`, permissionless), `src/Distributor.sol:303-304` (the
dust carry that makes it infinitely re-callable), `src/Distributor.sol:308`
(`lastCheckpoint = uint64(nowTs)`, unconditional), `src/Distributor.sol:244` (the `vested == 0`
early return whose whole purpose the reset defeats).

**Status: REPRODUCED** — `test_R2_01_flushGrindFreezesVestingOnASmallStream`,
`test_R2_01c_theStallThresholdIsAboutSevenThousandBaseUnits`, controls
`test_R2_01d_sound_aLargeStreamShrugsOffTheSameGrind` and
`test_R2_08_sound_theSubUnitBranchSelfHealsWhenNobodyArms`.

`_arm` always leaves 1 wei of truncation dust in `pendingPayouts` (line 303), so `flush()` is
callable forever with no new money. Every call ends in `_arm`, whose last line resets
`lastCheckpoint` to `block.timestamp` — including in the case where `_checkpoint` had just
*deliberately declined* to advance it so the sub-unit fraction could accumulate. The elapsed term is
therefore permanently clamped to one block, and if one block's vest rounds to zero it stays zero.

Measured: a 3,600-unit stream, ground with `flush()` once per 12s block for 3,000 blocks (36,000s,
41% of the window) — `totalDistributed == 0`, `withdrawableOf(alice) == 0`, while the identical
ungriefed stream on the same clock has vested normally. The griefer also pushes `streamFinish`
further out than the control's.

**Bound (this is what caps the severity):** the stall requires `blockTime × total / window < 1`,
i.e. `total < ~7,200` base units. Measured: 3,600 stalls, 7,100 stalls, 8,000 does not. On an
18-decimal pair that is 7,200 wei. On a 6-decimal pair it is $0.0072. A 1e18 stream under the same
3,000-block grind is bit-identical to the control, including `streamFinish`.

**Attacker gain: none.** The value is delayed, not taken — stop grinding and it all arrives
(`test_R2_01b`). The griefer's balance is asserted to be zero. Cost is ~25-30k gas per block, forever.

Note that `audit/08-streaming-designs.md` §6 specified `minStreamNotify` — "a dust floor below which
a distribution is CARRIED, not notified... the anti-grief lock" — and it **was not implemented**.
That one guard closes this: dust can never re-arm, so `flush()` stops being a free clock reset.

---

### R2-02 — INFO — every `_arm` permanently strands one or two base units

**Where:** `src/Distributor.sol:293` (`remaining` recomputed as a floor of
`remainingTime * streamRate / MAGNITUDE`, strictly below the true unvested balance, with the
difference not carried) plus the `_checkpoint` residue from R2-03.

**Status: REPRODUCED** — `test_R2_02_eachFlushBurnsAboutOneWeiOfOtherPeoplesDividends`.

The `dust` carry on line 303 covers only the third truncation (`rate * window`), not these two.
Measured: 3,000 `flush()` calls against a 1e18 stream burn **2,200 wei** versus a control on the
same timeline — 0.73 wei per call, and asserted bounded by ≤ 1 wei per `_arm`. The griefer receives
none of it; it is stranded on the contract outside `pendingPayouts`.

At ~25k gas to destroy 0.73 wei this is never economic, and under normal operation `_arm` runs once
per sweep, so the lifetime cost of a token is measured in hundreds of wei. Reported for completeness
because it is unbounded in principle and shares a root cause with R2-03.

---

## Checked and found sound — with the inputs I tried

**Instant capture is dead.**
- `testFuzz_R2_04_sound_zeroBlockCaptureIsExactlyZero`, 1,001 runs. Buy → sweep → `flush` → `flush`
  → read → sell, all in one block. Amounts `1 … 1e24`, attacker shares `1e18 … 1e27`, honest shares
  `1e18 … 1e27`, pre-elapsed `0 … 2×STREAM_WINDOW`. Captured is **exactly 0** every run, and the
  claim is still 0 after the sell.
- `test_R2_04b_sound_aWhaleCannotBuyIntoAQuietTokensBacklog`. The residual I most expected to
  survive: `lastCheckpoint` lags whenever the token is quiet, so one `_checkpoint` folds in many
  hours at once. Set up with 20 hours of total silence (asserted stale) and >80e18 of backlog, then
  a whale takes 99.9% of the register and leaves in the same block — whale gets 0, and alice's
  backlog is not diluted. `setBalance` checkpointing before `_setShares` (line 372) is doing exactly
  what its docstring claims.
- `test_R2_04c_sound_unExcludingMidStreamGrantsNoBacklog`. Same via `setExcluded(false)` — 0.
- `test_R2_08f_sound_holdingIsTheOnlyWayToBePaid`. In-and-out around the sweep gets 0; the holder
  across the window gets the pot.

**The weighted-average window holds.**
- `invariant_stream_finishNeverMoreThanOneWindowAhead`, 16,384 calls including `flush`, `distribute`,
  `setExcluded`, warps of 1s to 48h. `streamFinish ≤ now + STREAM_WINDOW` always. This is the
  Synthetix S-1 defence and it survives a permissionless notifier.
- `testFuzz_R2_06_sound_finishNeverExceedsOneWindowAhead`, 1,000 runs across four sequential arms.
- `testFuzz_R2_06b_sound_theRateIsSubAdditive`, 1,000 runs. A top-up never makes the stream pay
  faster than the old rate plus the new money's own full-window rate. In exact arithmetic the
  margin is `a·r·(W−T)²/W ≥ 0`; the only slack needed is `window` truncation, bounded by one part in
  `window`. **This is what makes a "collapse the window and take the pot" attack impossible.**
- `test_R2_08b_sound_sameBlockFlushSpamIsANoOp`. 200 `flush()` calls in one block move
  `streamFinish`, `streamRate`, `totalDistributed` and `withdrawableOf` by exactly zero.

**`_perShareNow` and `_checkpoint` round identically.**
- `testFuzz_R2_05_sound_theViewNeverPromisesMoreThanTheWithdrawPays`, 1,000 runs at 2-18 decimals.
  `withdrawableOf` is asserted `==` (not `≥`) the return of `withdraw()` and `==` the actual token
  balance delta, with zero residue afterwards.
- `testFuzz_R2_05b_sound_pushPaysExactlyWhatTheViewPromised`, 1,000 runs. `processBatch`'s
  `sentTotal` equals the sum of the pre-call views, and each holder's balance matches their own.
- I could not construct an input where the view promises more than a same-block withdraw pays. The
  two functions order their guards differently (`_checkpoint` tests `vested == 0` before the share
  floor, `_perShareNow` after) but the results are identical in every branch.

**Value conservation.**
- `invariant_stream_solventIncludingUnvested` and `invariant_stream_neverOwesMoreThanWasGiven`,
  16,384 calls each. Note these are strictly stronger than the existing
  `invariant_neverOwesMoreThanItHolds`, which sums only `withdrawableOf + pendingPayouts` and so
  **cannot see money that `_arm` has scheduled but not yet vested**. Mine adds the unvested term.
- `testFuzz_R2_03_neverOwesMoreThanItHolds` and `testFuzz_R2_03b_neverSchedulesMoreThanWasGiven`,
  1,000 runs each, with up to 20 interleaved `flush()` calls.
- `test_R2_08d_sound_aMassiveMidStreamShareSwingIsNeutral`. A 1e6× register swing mid-stream
  neither creates nor destroys value; the total is `≤ 100e18` and within 1e-6 of it.

**The `vested == 0` branch self-heals when nobody is arming.**
- `test_R2_08_sound_theSubUnitBranchSelfHealsWhenNobodyArms`. `setBalance` every block for 500
  blocks on a 3,600-unit stream: `lastCheckpoint` stays put across sub-unit intervals, the fraction
  accumulates, and value does vest. It is only the `_arm` reset (R2-01) that breaks this.

**`streamRate` can never be driven to zero while value is scheduled.**
- `testFuzz_R2_08c_sound_streamRateIsNeverZeroWhileValueIsScheduled`, 1,000 runs on a 6-decimal
  pair with up to 30 grinding flushes. `rate = total·MAGNITUDE/window` with `window ≤ 86,400`, so
  the floor is `MAGNITUDE/86400 > 0`. The pre-magnification does its job here.

**Overflow.**
- `test_R2_08e_sound_theArmOverflowBoundaryIsAtTwoToThe128`. `total * MAGNITUDE` (line 300) is the
  binding constraint: `2**128 - 1` arms fine, `2**128` reverts. That is 3.4e20 tokens on an
  18-decimal pair, and it sits **above** the `accumulativeOf` cliff round 1 already documented
  (D-07, ~3.40e32 cumulative), so streaming did not introduce a new cliff.
- `elapsed * streamRate` (line 238) cannot overflow independently, because sub-additivity bounds
  `streamRate ≤ cumulative · MAGNITUDE / STREAM_WINDOW` and `elapsed ≤ window ≤ STREAM_WINDOW`.
- `remaining * remainingTime` and `addition * STREAM_WINDOW` (line 297) bind at ~1.3e72, far past
  line 300.

**Also checked, nothing found:**
- `flush()` cannot be used to time anything: what it arms vests over a fresh weighted window, and
  same-block repetition is a fixed point.
- Re-entering `flush()` from inside a converter during `processBatch` cannot desynchronise the loop:
  `_arm` sets `lastCheckpoint = now`, so `_perShareNow` returns the stored accumulator unchanged for
  every subsequent account in the batch.
- `_setShares` is reachable only from `setBalance` and `setExcluded`, both of which `_checkpoint`
  first, so `_corrections` is never booked against a stale accumulator.
- `pendingPayouts` is never double-counted across `_checkpoint` → `distribute` → `_arm` →
  `flush`.

---

## Reasoned only — NOT reproduced

- **`processBatch` reads `len` once (line 468) and indexes `_queue[i]` after re-entrant calls.** If
  the queue could shrink mid-batch the index would panic and take the whole batch down. I could not
  reach it: `_dequeue` fires only from `_setShares`, which is `onlyShareToken`, and the converter is
  not the share token. Flagged as a latent sharp edge, not a finding.
- **`total * MAGNITUDE` reverting inside `distribute` would revert `FeeHook._routeFee` and therefore
  the swap**, bricking the pool rather than just the dividend. Only reachable above 2^128 base units
  of pair currency in one arm, which is not a realistic pot. Noted because the blast radius is
  larger than it looks.

## Explicitly not re-reported (already found and already regression-tested)

D-01 (converter double-payment), D-02 (`setExcluded` unreachable from the hook), D-03/D-05b (the
carry is credited to whoever holds at flush time, and the window reopens when the holder base
shrinks — still true under streaming, and streaming makes the re-arm a fresh 24h window rather than
an instant credit), D-04 (`minShareForQueue == 0` makes `_dequeue` unreachable), D-06
(`minPushPayout == 0`), D-07 (the `accumulativeOf` overflow cliff, and the converter-donation
underflow panic), D-08 (`processBatch` is never called by the system).

## Do the fixes hold?

Yes, on the thing they were built for. The driver swap from event to clock is correct, the ordering
of `_checkpoint` before every share write is correct and load-bearing, the Yearn weighted average
genuinely closes Synthetix's S-1 with a permissionless notifier, and the pre-magnified rate stops
`streamRate` collapsing on low-decimal pairs.

Three of the four findings share one root cause the migration did not finish: **the code magnifies
the rate but not the accrual.** `_checkpoint` and `_arm` both divide the magnitude back out and
throw the remainder away, and `_arm` then resets the clock unconditionally on top. Fixing that one
thing — advance `lastCheckpoint` only by the time actually paid for, and add the `minStreamNotify`
floor that `audit/08` already specified — removes R2-01, R2-02 and R2-03 together. R2-04 is
independent and wants the allowance-delta measurement instead of the balance-delta one.
