# Audit 09 — Remediation

Fixes for the findings left open by audits 01–05 and round 2, with the measured before/after number
for each one and the tradeoff where there is one.

**Method.** The pre-fix `forge test --no-match-contract Fork` output was captured *before* `src/`
was touched (914 passing, 0 failing at `e5e1bdd`) and is the negative control for every inversion
below — the failure messages name the exact flipped quantity. Every test that documented a
vulnerability was **inverted**, not deleted: the same scenario, the same setup, the assertion turned
around, the measured before/after numbers written into the docstring.

**Suite:** 914 → **919 passing, 0 failing.**

---

## 0. Findings the brief listed as open that were ALREADY CLOSED at `e5e1bdd`

Commit `5e0b755` ("fix(dividends): round 2 findings — allowance check, carried remainder, grind")
is an ancestor of `e5e1bdd` and had already landed three of the four round-2 fixes. Verified by
reading `src/Distributor.sol` and by the inverted test names already in the tree.

| Finding | Status at `e5e1bdd` | Evidence |
|---|---|---|
| **R2-03** `_checkpoint` truncation | **FIXED.** `streamRemainderMag` carries the sub-unit remainder in MAGNIFIED units across checkpoints, which is stronger than the audit's suggested `lastCheckpoint = from + vested*MAGNITUDE/streamRate` — it is lossless rather than merely less lossy. | `test_R2_03_frequentCheckpointsNoLongerDestroyValue`, `test_R2_03c_lowDecimalPairsNoLongerLoseAFraction` |
| **R2-01** flush-grind clock reset | **FIXED, by a different mechanism than the brief expected.** `minStreamNotify` was never implemented and still is not (0 occurrences in `src/`). It did not need to be: once advancing the clock is lossless, the `vested == 0` early-return that `_arm`'s unconditional reset used to defeat no longer exists, so there is nothing left to grind. | `test_R2_01c_noStreamSizeStallsAnyMore`, `test_R2_01d_sound_aLargeStreamShrugsOffTheSameGrind` |
| **R2-02** `_arm` strands 1–2 base units | **FIXED** by the same change. | `test_R2_02_flushNoLongerBurnsOtherPeoplesDividends` |
| **D-07** donation underflow panic 0x11 | **FIXED.** The `heldBefore - balanceOf(this)` subtraction is gone entirely, so a converter that donates payout currency back is just somebody giving the pool money. | `test_D07_aConverterThatDonatesPayoutCurrencyBackNoLongerPanics` |
| **R2-04** re-entrant converter | **NOT fixed.** See §1 — the allowance measurement landed and is *still bypassable*, by a route the round-2 audit did not describe. |

---

## 1. R2-04 (MEDIUM) — a re-entrant converter settles a claim and pays nothing

`src/Distributor.sol`, `_trySend` / `withdraw` / `processBatch`.

### What it was, and why the shipped fix was not enough

Round 1 judged conversion success by the distributor's **balance delta**, which a re-entrant
converter can move without taking anything. Round 2 replaced that with **allowance consumption**:

```solidity
uint256 taken = amount - IERC20(payoutToken).allowance(address(this), converter);
```

That is the right quantity. It is also stored in **one shared slot**, keyed `(distributor,
converter)`, and every concurrent `_trySend` writes it. The attack survives the fix by one extra
hop:

1. alice calls `withdraw()`. `_withdrawn[alice]` is incremented, then `approve(converter, A)`.
2. `convert` re-enters `processBatch`.
3. The nested `_trySend` for bob runs to completion: `approve(converter, B)` → `convert` (takes
   nothing) → `taken = B - B = 0` → **`_clearAllowance()`** → bob is paid the fallback.
4. The outer frame resumes and reads `allowance == 0`, so `taken = A - 0 = A ≠ 0`, and returns
   `true`. alice's claim is settled and she is paid nothing.

**MEASURED BEFORE** (`test_R2_07`, 18-decimal pair, 200e18 pot, two equal holders):

```
alice debited                       : 99999999999999999999 wei
alice received, pair currency       : 0
alice received, reward currency     : 0
withdrawableOf(alice) afterwards    : 0
PayoutSent(alice, 99999999999999999999) emitted
```

and on the push path (`test_R2_07c`, three holders, 300e18):

```
processBatch sentTotal reported     :  99999999999999999999
actually left the contract          : 199999999999999999998
```

### What I changed

`Distributor` now inherits `ReentrancyGuardTransient` and `withdraw()` / `processBatch()` are
`nonReentrant`. The allowance measurement is correct and stays; the guard is what makes it
*meaningful*, because a measurement over a shared slot only means anything if nothing else touches
the slot in between.

`flush`, `setBalance`, `setExcluded` and `distribute` are deliberately **not** guarded: none of them
touches an allowance, and `setBalance` sits on `LaunchToken._update`'s hot path where a nested call
is normal traffic, not an attack.

**MEASURED AFTER:**

```
alice debited                       : 99999999999999999999 wei
alice received                      : 99999999999999999999 wei   (pair currency, the fallback)
conv.hits()                         : > 0   (the converter really was called)
processBatch sentTotal              : == what actually left the contract, to the wei
```

The converter's `processBatch` re-entry reverts, `convert` reverts with it, the existing `catch`
runs `_clearAllowance()`, and the holder is paid the pair currency — which is the contract's
documented "could not route" degradation.

### Tradeoff

A converter that *catches* the nested revert itself and returns normally is also handled: the
allowance is then untouched, `taken == 0`, and the fallback pays. Either path is safe.

Cost: one `TSTORE`/`TLOAD` pair per withdrawal and per batch. `evm_version = "cancun"` is already
required by v4, and `Launcher` already uses the same guard.

---

## 2. D-02 / D-02b — exclusion was frozen at construction, and `renounceAccrual` did the opposite of its docstring

`src/Distributor.sol`, `src/VestingVault.sol`.

### What it was

`setExcluded` is `onlyController`, the controller is `FeeHook`, and `FeeHook` contains no call to it
(verified: 0 call sites in `src/`). The excluded set was therefore frozen at construction — pool,
launcher, distributor, `0x0`, `0xdEaD` — for the life of every launch.

The in-repo consequence is `VestingVault.renounceAccrual`, documented as *"the locked supply's
dividend claim belongs to the other holders, forever"*. It set a flag on the vault and nothing else.

**MEASURED BEFORE** (`test_D02b`, vault and alice each holding 1,000e18, two 200e18 distributions):

```
shareOf(vault) after renouncing     : 1000e18     (unchanged)
totalShares after renouncing        : 2000e18     (unchanged)
alice's second slice                : 100e18      (unchanged — she gained NOTHING)
vault accrued a second              : 100e18      it could never claim
processBatch pushed real pair currency into a vault whose only exit now reverts AlreadyRenounced
```

### What I changed, and the authority model I chose

**I changed the authority model rather than giving the hook a path, and here is the justification.**
Excluding an account deletes its future entitlement and hands it to everybody else. There is no
address in this system that can be trusted with that over somebody else's balance: not the creator,
who competes with holders for the same fee stream; not a platform admin, which this codebase
deliberately does not have and which would be a new rug surface on a contract whose selling point
is that it has none. Keyed on `msg.sender`, the authority is exactly the person whose money it is.

`Distributor.renounceAccrual()` — permissionless, self-only, **one way**. One-way because a
reversible toggle is a lever on the denominator (exclude before a checkpoint, re-enter after).
Round 2 already proved re-entry grants no backlog (`test_R2_04c`), so a toggle would only ever be
self-harming *today* — but the guarantee costs one comparison and means the property does not have
to be re-proved every time the accrual maths changes.

`VestingVault.renounceAccrual()` now calls through to it, and **settles what has already been earned
on the way out**. That is not generosity: renouncing removes the shares but not the outstanding
claim, and afterwards `claimDividends` reverts `AlreadyRenounced` forever, so anything owed at that
instant would have been stranded. The signal is about the future; the past is paid.

**MEASURED AFTER:**

```
shareOf(vault) after renouncing     : 0
totalShares after renouncing        : 1000e18
alice's second slice                : 200e18      (doubled — the value was REDISTRIBUTED)
already-earned claim                : forwarded to the beneficiary in the same call
processBatch pushes into the vault  : 0           (it is dequeued and owed nothing)
```

### The residue, stated plainly

A contract that cannot make an external call at all is still beyond help, and
`test_D02_fixed_aContractHolderCanRenounceSoItsShareIsRedistributed` asserts that rather than
glossing it. Nothing on chain can distinguish an inert contract from a cold wallet. That is a
property of the holder, not of this ledger.

`setExcluded` is left `onlyController` and still has no call site. It is the constructor-time
mechanism plus a hook-side hook for a future controller; adding a live third-party path is the thing
I explicitly decided against above.

---

## 3. D-03c — `processBatch` is called nowhere, while the docblock said the hook calls it

`src/Distributor.sol` lines 13–15.

### What it was

The docblock claimed `processBatch` was something *"the hook calls opportunistically after a swap"*.
Nothing in `src/` has ever called it. This is a **documentation defect with a real consequence**: an
integrator builds on a push that does not exist, and a keeper operator does not learn the job is
theirs.

### What I changed, and why not the other way

I corrected the docstring. **Wiring it in would have been worse than leaving it wrong.** `distribute`
has exactly one call site — inside `sweep` — and `distribute` arms a 24-hour linear vest. A push in
that same transaction finds `withdrawableOf == 0` for *every* holder in the queue, walks the whole
thing, pays nobody, and charges the swapper for the walk. The new docblock says so explicitly, so
the next person to reach for the obvious fix reads why it is not one.

**MEASURED, and now asserted in `test_D03c_fixed_thePushPathIsKeeperDrivenAndAKeeperCanActuallyPay`:**

```
same-block processBatch(10)         : sentCount 0, sentTotal 0   (a guaranteed no-op walk)
one STREAM_WINDOW later, from any address:
  sentCount                         : 1
  sentTotal                         : == withdrawableOf(alice), to the wei
  holder's balance delta            : == the same number
```

The test previously stopped at "and still nothing on chain will move it". It now proves the keeper
model actually works, which is the claim the corrected docstring makes.

---

## 4. E-09 / A-9 — at `feeBps == 100` the platform takes 100% and the creator and holders get zero

`src/FeeHook.sol`.

### What it was

`platformShareBps = PLATFORM_VOLUME_BPS * BPS / feeBps`, and the floor check was
`feeBps < PLATFORM_VOLUME_BPS` — so `feeBps == 100` was accepted and the expression evaluated to
exactly `BPS`. `_routeFee` sent the whole fee to the platform and `rest` was zero.

**MEASURED BEFORE**, 100-pair buy, creator advertising `creatorBps = 8000`:

```
feeBps | platform | creator | holders
   100 |   0.9950 |  0.0000 |  0.0000     <- nothing, no revert, no warning, forever
   110 |   0.9949 |  0.0796 |  0.0199
   150 |   0.9949 |  0.3980 |  0.0995
   200 |   0.9950 |  0.7960 |  0.1990
   300 |   0.9949 |  1.5920 |  0.3980
```

### What I changed

One character: `feeBps <= PLATFORM_VOLUME_BPS` now reverts `FeeBelowPlatformFloor`. Plus a new view,
`FeeHook.effectiveSplitBps(PoolId)`, returning `(platformBps, creatorBps, holderBps)` **of the fee**,
so a front end can render the real number before anybody signs.

**MEASURED AFTER:** `feeBps = 100` reverts `FeeBelowPlatformFloor(100)` out of `configurePoolFull`,
so the launch never happens. Every rate that *is* legal pays all three recipients something —
asserted at 101, 110, 200 and 300 bps in
`test_E09_fixed_theMinimumFeeIsRejectedInsteadOfPayingHoldersNothing`. At 200 bps
`effectiveSplitBps` returns `(5000, 4000, 1000)`, which is what "80% to the creator" really means on
a 2% launch.

### Tradeoff, flagged

The audit's stronger suggestion was to *raise* the floor to somewhere the split is meaningful (say
200 bps, where the platform never takes more than half the fee). **I did not do that**, because
101–199 bps is correct arithmetic — steep, but not a defect — and raising the floor deletes legal
launches on a judgement call about what "meaningful" means. `effectiveSplitBps` is the honest
alternative: make the steepness visible instead of illegal. If you want the higher floor, it is one
constant.

**F-02 is untouched and still open:** `platformShareBps` is derived from the *buy* rate and applied
to converted *sell* fees. `test_F02` was re-parameterised from `feeBps = 100` (now illegal) to
`feeBps = 101` and still demonstrates it — the platform takes 99% of a 10% sell tax.

---

## 5. A-3 — a two-wallet referral cycle credits a creator the whole 40% schedule

`src/ReferralVault.sol`.

### What it was

`credit` claimed *"Cycles are impossible because `referrerOf` is write-once and a referrer must
already exist when they refer someone"*. Only the write-once half was ever enforced — and the other
half **cannot** be enforced in `setReferrer`, because the first referrer of all has no referrer and
requiring one makes the graph unbootstrappable. So `A → B` then `B → A` is two ordinary legal
launches and the tier walk alternated `B, A, B, A, B` through the whole 20/10/5/3/2 schedule.

**MEASURED BEFORE:** on a real launch with real trading and a real sweep, **4,000 of 10,000 bps** of
the platform's cut landed on the launcher's own two wallets and was claimed out. The treasury got
6,000 instead of 10,000. An honest single referrer earns 2,000, so the cycle **doubled** it.

### What I changed

The fix is in the walk, not in `setReferrer`. A fixed `address[MAX_TIERS + 1]` seen-set, seeded with
the creator, and the walk breaks at the first repeat. At most 21 comparisons, all in memory, and it
cannot be grown by attacker-shaped data.

**MEASURED AFTER:** **2,000 bps** — exactly what one honest referrer earns — and the creator's own
wallet earns **0** from their own launch. `test_fixed_aTwoWalletCycleEarnsNoMoreThanOneHonestReferrer`
carries a control launch with an ordinary unrelated referrer, which earns the same 2,000, so the
assertion cannot pass on a build that had simply stopped paying referrers.

### What this does NOT close

**E-08 stands.** A chain of five *distinct* sybil wallets still refunds 40% of the platform cut,
because every wallet in it is a different address and the walk has no way to know they are one
person. That is a bounded, known haircut (`sum(schedule)` and `MAX_TIERS` are both fixed in the
bytecode) and it is a schedule-design question, not a correctness one. Deleting tiers 2–5 cuts it
from 40% to 20% with no loss of the legitimate use case — a product call, not made here.

---

## 6. A-4 — setting `feeRecipient` silently zeroes the referrer's entire claim

`src/Launcher.sol`.

### What it was

Two different keys for the same person. The referral was **recorded** under `msg.sender` and
**looked up** under `cfg.creator`, which is `feeRecipient` when one is set. `feeRecipient` exists
precisely so a creator can route revenue to "a team splitter, a multisig or a cold wallet" — and any
creator who did so unknowingly zeroed out whoever referred them. `referrerOf[multisig]` was empty,
the walk terminated immediately, and 100% of the platform cut went to the treasury. No revert, no
event, no view showed the mismatch.

**MEASURED BEFORE:** side by side in one world — control launch, referrer earns tier 0; same
referrer with `feeRecipient` set, the referrer's balance does not move by one wei and the treasury's
does.

### What I changed

`_configureHook` hoists `feeRecipient` into a local and records the referral under it, so both sides
agree on one key. One line.

**MEASURED AFTER:** `referrerOf[multisig] == referrer`, and the referrer's *share* of the platform
cut is identical on both launches (asserted as a ratio, because the two launches are separate pools
with separate price impact and equal absolutes would be a coincidence).

---

## 7. A-6 — `VestingVault.addSchedule` is permissionless with an unbounded caller-chosen `start`

`src/VestingVault.sol`.

### What it was

The docstring justified the missing guard with "the launcher calls it during the launch transaction,
before a beneficiary could possibly front-run anything". True of the launch and of nothing else: the
contract also advertises top-ups, and every top-up is a two-step transfer-then-schedule with an open
window in between.

**MEASURED BEFORE:**

- a stranger front-ran a 1,000e18 top-up with `start = now + 100 years`. **Fifty years later**
  `release()` moved none of it, and `extend(1, 0, 1 days)` reverted `CannotShorten` — `extend` takes
  only `cliff` and `duration`, so `start` is unreachable once written. Permanent, for gas.
- 31 schedules over **1 wei** each filled `MAX_SCHEDULES = 32`, and the beneficiary's own 500e18
  top-up then reverted `TooManySchedules`, forever.
- (I-4) `addSchedule(type(uint128).max, …)` against a 100e18 balance silently produced a **100e18**
  schedule. Silent trimming is banned everywhere else in this codebase.

### What I changed

- `msg.sender` must be the `launcher` (captured from `msg.sender` in the constructor, which is the
  `Launcher` in every real launch) or the current `beneficiary`.
- `start > block.timestamp` reverts `StartInTheFuture`. **A lock that should begin later is a
  CLIFF**, which `extend` can lengthen and which is visible in `scheduleAt` — not a start date
  nothing can ever move.
- `amount > unscheduled` reverts `AmountExceedsUnscheduled` instead of clamping.

**MEASURED AFTER:** the stranger's call reverts `OnlyLauncherOrBeneficiary`; the beneficiary's own
far-future start reverts `StartInTheFuture`; the beneficiary's legitimate top-up still works and
fully vests over its own 30-day schedule; the over-large amount reverts and the exact amount is
accepted. `Launcher._devBuy` passes `uint64(block.timestamp)` and an amount equal to the vault's
whole balance, so the launch path is unaffected by both new checks.

---

## 8. A-5 — `PairRegistry` ownership dies in one unconfirmed call

`src/PairRegistry.sol`.

`Ownable2Step` guards `transferOwnership` with a handshake and leaves `renounceOwnership` exactly as
`Ownable` defines it: one call, no confirmation.

**MEASURED BEFORE:** one call set `owner()` to `address(0)`, after which `approvePairWithoutOracle`
*and* `revokePair` both reverted `OwnableUnauthorizedAccount` forever. The second is the one that
matters — this registry is the only gate on which currencies may be launched or paid against, so a
pair currency that later paused, blacklisted or got exploited would have stayed launchable for the
life of the deployment.

**AFTER:** `renounceOwnership()` is overridden `public pure` and reverts `OwnershipCannotBeRenounced`.
Ownership survives, both admin paths still work, and a non-owner still cannot reach them. An operator
who genuinely wants to walk away transfers to a burn-controlled multisig — same outcome, with a
second step in front of it.

---

## 9. E-06 (Tier 2) — `maxWallet` bounded a purchase, not a holding

`src/LaunchToken.sol`. **DESIGN DECISION — overrule me here if you disagree.**

### What it was

`_update` checked the cap only when `from == poolManager`. Wallet-to-wallet transfers were uncapped,
so the cap did not bound the final holding at all.

**MEASURED BEFORE:**

```
advertised cap                : 200 bps of supply   ("2% max wallet")
wallets used                  : 12
final SINGLE-wallet holding   : 2,376 bps of supply  (23.76% — 11.9x the cap)
gas per extra wallet          : 243,636   (~$17 at 20 gwei; ~$200 for 24% of the token)
```

### What I changed

The check now fires on **every inbound transfer to a non-exempt address**, not only the pool's.

**The property that must not break is that a SELL can never be blocked** — a cap that can block a
sell is a honeypot, and that was the whole reason the check was narrow. It is preserved
*structurally*: a sell moves tokens **into** the PoolManager, which is exempt. Asserted, not argued,
in both `test_E06_fixed_…` (every capped wallet and the over-cap attacker sell their entire
positions) and `test_sellIsNeverBlocked`.

Two exemptions were required and both are load-bearing:

- **`0xdEaD` is now exempt.** The buyback `take`s bought-back supply to the dead address. Left
  capped, a launch with both a burn wedge and a max wallet would have bricked its own `sweep` the
  moment cumulative burns crossed the cap. That would have been a *new* permanent brick introduced
  by this fix.
- **Deliveries out of the launcher are exempt** (`launchConduit`, one storage slot, read only when
  `maxWallet != 0` and the recipient is not already exempt). The dev buy reaches the creator or
  their vesting vault as a wallet-to-wallet transfer inside the launch transaction, and it is
  bounded by its own stricter rules — `MAX_DEV_BUY_BPS` on the unvested path, a published schedule
  on the vested one. Without this exemption a legal dev buy would simply revert the launch.

**MEASURED AFTER:** the twelve spread buys still succeed (each is legal and the cap is unchanged);
the first consolidating transfer that would cross the cap reverts
`MaxWalletExceeded(attacker, 3.96e25, 2e25)`; the attacker's final holding is `<= cap`.

### Tradeoff

This makes `maxWallet` a genuine constraint on holdings rather than "theatre", which is what the
token page implies it is. The cost is that airdrops, OTC deals and any wallet migration by a large
holder now hit the cap on a launch that sets one. That is the point of a cap, but it is a real
behaviour change for creators who used one as decoration. Sybil evasion is not eliminated —
twelve wallets can still *hold* 24% between them — but consolidating into one address, which is what
makes the position tradeable and dumpable as a block, is now blocked.

---

## 10. E-07 (Tier 2) — `_validate` compares the graduation bar against the wrong number

`src/Launcher.sol`. **DESIGN DECISION — overrule me here if you disagree.**

### What it was

`_validate` requires `graduationThreshold > openingMarketCap`, and that is the wrong quantity in two
independent ways:

1. the opening price is **snapped** to a usable tick, so the pool can open above the requested cap;
2. the dev buy is the first swap **in the same transaction**, so it moves the price before anybody
   else can trade. On a single-sided seed the spot cap after a dev buy of `D` pair is `(M + D)² / M`.

**MEASURED BEFORE:**

```
"the worst honest-looking launch" (78% supply vested, 10% fee, 100% to creator, "5x to graduate"):
  graduation bar                : 500.0000 pair
  spot mcap in the launch block : 2,112.5357 pair   (4.2x the bar)
  graduationProgressBps         : 10,000            (UI bar full before the first buyer)
  checkGraduation               : succeeds in the launch block

a bar one wei above openingMarketCap:
  real opening mcap after the tick snap : 100.290561036899339019 pair
  bar                                   : 100.000000000000000001 pair
  cost to latch it                      : -0.0003 pair (0.03 bps of the opening cap)
```

### What I changed

`Launcher._assertNotBornGraduated(poolId, threshold)` runs after the unlock cycle — after the seed
*and* the dev buy — and reverts `BornGraduated(threshold, marketCapAtLaunch)` if
`feeHook.marketCapOf(poolId) >= threshold`.

**I measured rather than modelled**, deliberately. The closed form `(M + D)² / M` is right but would
be a second model of the price that has to be kept in sync with `_marketCap` and with `_openingTick`'s
snapping forever. Reading `marketCapOf` uses the *same function the latch itself uses*, so the check
and the thing it is protecting can never disagree. Cost is one `getSlot0` staticcall per launch, on
a path that already does an unlock cycle.

Reverting rather than adjusting the threshold is the house rule: silent trimming is banned.

**MEASURED AFTER:** the 78%-supply launch reverts `BornGraduated(500e18, 2112535799871658722160)`;
the one-wei bar reverts `BornGraduated(100000000000000000001, 100290561036899339019)`. A bar one
percent above the requested open is accepted, opens below itself, and `checkGraduation` returns
false in the launch block.

### Tradeoff

**This tightens the legal parameter space and it will reject launches that used to work.** A creator
who wants a bar very close to the open must now clear the *snapped* opening price plus whatever their
own dev buy does to it — which is a number they cannot compute by hand and the UI will have to
compute for them. Three tests in the existing suite had to be re-parameterised for exactly this
reason (`test_E02b`, `test_E07`, `test_E07b`, `test_sound_aFailedAutoSweepNeverBreaksTheTrade`), and
each carries a comment saying so.

The alternative — validating against the closed form in `_validate`, so the revert arrives before any
state is written — is cheaper for the caller and gives a better error message. I rejected it because
it duplicates the price model. If you would rather have the early revert, the closed form is
`FullMath.mulDiv(M + D, M + D, M)` with `D = devBuyPairAmount * (BPS - feeBps) / BPS`, and it should
be *added alongside* this check, not instead of it.

**E-02 is untouched and still open.** The bar may still sit just above the real opening price, and
latching it is still a spot-price push that costs only the buy fee. Graduation is a `slot0` read;
only a TWAP or a cumulative-volume measure changes that. `test_E02b` now measures the residue.

---

## 11. V-03 (Tier 2) — a price-limited exact-input buy pays the fee on input it never spent

`src/FeeHook.sol`. **DESIGN DECISION — overrule me here if you disagree.**

### What it was

`_beforeSwap` charges `feeBps` of the amount **requested**, computed before the curve runs, because
on an exact-input buy the pair currency is the SPECIFIED side and `beforeSwap` is the only place a
hook can touch it. If `sqrtPriceLimitX96` stopped the swap early, the unspent input came back and the
fee on it did not.

**MEASURED BEFORE**, on a live `Launcher`-seeded pool at the configured 3%, both currency orderings:

```
requested input   : 100.000000000000000000 pair
actually debited  :   3.301308354505875602 pair
fee charged       :   3.000000000000000000 pair
effective rate    : 9,087 bps   (90.87% — 30x the advertised 300)
```

And it is forceable, not only self-inflicted: a sandwicher pushes the price to one tick short of the
victim's own limit and the victim fills for almost nothing while paying the full notional's fee.

### What I changed, and why it is a refusal rather than a refund

`_afterSwap` now calls `_assertExactInputBuyFilled`, which reverts
`PriceLimitedBuyWouldOvercharge(requested, consumed, fee)` when `consumed + fee < requested`.

**The audit's suggested fix — "refund the unused portion in `_afterSwap` using the
unspecified-currency return" — is not implementable, and that is structural.** A hook's `afterSwap`
return can only move the UNSPECIFIED currency, which on an exact-input buy is the **launch token**.
Handing back launch tokens is not a refund of a pair-currency fee. There is no refund available at
all, so the only honest options are "overcharge silently" or "refuse", and this codebase has already
settled that question elsewhere (`ZapRouter.IntermediateLegDidNotNet`: a named revert beats a silent
half-fill in an asset the caller cannot use).

**Scoped to BUYS.** A sell is charged in the launch token, and a sell hitting the opening-tick floor
and partially filling is a normal, documented consequence of single-sided seeding — `sweep`'s
sell-fee conversion and the F-05 self-healing deferral both depend on that partial fill being
allowed. On a `Launcher`-seeded pool the position runs to `maxUsableTick`, so the only thing that can
cut a BUY short is a limit the trader set themselves.

**MEASURED AFTER:** the same call reverts, `pair.balanceOf(alice)` is unchanged and `pendingFees`
does not move. The positive control in the same test — the same size with a wide limit — fills
completely and is charged `(fee * 10_000) / spent == 300`, exactly the advertised rate.
`test_V03b_sound_aPriceLimitedSellStillPartiallyFills` pins the sell side.

### Tradeoff

A trader who deliberately wanted a partial fill up to a price limit now gets a revert. That is what
slippage protection means, and it is how every mainstream router already behaves (they set the limit
to the extreme and use `amountOutMinimum`), but it is a behaviour change: a very large buy that
would exhaust the seeded range all the way to `maxUsableTick` now reverts instead of partially
filling. Reaching that requires buying essentially the entire supply.

---

## What I did NOT fix, and why

### V-01 / V-02 — the auto-sweep is unreachable, and making it reachable makes V-02 live

**NOT FIXED. This one needs your decision and I am not willing to guess it.**

`_afterSwap` returns at the `exactInput` guard before `_tryAutoSweep`, and `rate == 0` kills
exact-output sells, so the *only* shape that reaches the automatic payout is an exact-output BUY —
i.e. never, on router traffic. `Launcher` arms it on every launch and it does not fire.

The obvious fix is to move the call above the `exactInput` return. **I did not, because it would make
V-02 live.** `autoRedeem` is the only thing in the system that moves real ERC-20 out of the singleton
mid-swap, and `PoolManager._settle` credits `balanceOfSelf() - syncedReserves` — so anything that
leaves between a payer's `sync` and their `settle` is silently deducted from what they are credited.
Measured against a control run of the identical trade: true cost 0.4005 pair, sync-first cost 3.4122
pair, **8.5x**, and when the backlog exceeds the prepay it underflows to a bare panic `0x11` instead.

Today that is latent — nobody's router syncs first, and the project notes record that the 8.5x is
latent *specifically because* `autoRedeem` is only reachable from an exact-output buy while
`ZapRouter` is exact-input only. Making the auto path reachable on exact-input traffic would take a
measured 8.5x overcharge from "latent" to "live for any custom router or solver", including code
another agent owns. That is a regression, not a fix.

The two honest options are the audit's own:

1. **Make it reachable and accept V-02 more often.** Cheap (move one line). Ships a known 8.5x
   overcharge against a legal v4 settlement pattern.
2. **Delete the auto path entirely and lean on the `sweep` bounty.** Closes V-01 (no more silently
   armed dead feature) *and* V-02 (no mid-swap ERC-20 movement anywhere in the system) in one
   deletion. Costs a shipped, advertised feature and roughly ten tests that exercise `autoRedeem`.

**My recommendation is (2).** The auto path already cannot swap (so it cannot convert sell fees or
run the buyback), it already reserves the burn share for a later manual sweep, and it demonstrably
never fires on real traffic — so what is being deleted is a feature that costs a real settlement
defect and delivers nothing on the shapes routers actually send. `sweep()` is permissionless and pays
`SWEEP_BOUNTY_BPS`, which is the mechanism that actually turns accrual into payment.

I did not do it unilaterally because it removes a feature the app's copy advertises and because the
test churn (`test_autoSweepFiresOnceTheBacklogIsWorthIt`, `test_sound_autoRedeemRejectsEveryOutsideCaller`,
`test_sound_autoRedeemUsesBurnAndTakeRatherThanANestedUnlock`, `test_sound_aFailedAutoSweepNeverBreaksTheTrade`,
`test_F04`, the three `V-02` probes) would delete tests rather than invert them, which is the one
thing the brief forbids.

### E-01 — the block-0 snipe is a 50:1 free option

**NOT FIXED. Proposal below; this is a product decision.**

The first buyer gets the whole float for the opening market cap, and the opening tick is a hard floor
with no liquidity below it, so a sniper who sells straight back recovers everything except the buy
fee.

**MEASURED:**

```
sniper stake                        : 100.0000 pair
supply sniped                       :  49.16%
P/L if nobody ever shows up         :  -3.0000 pair    <- the ENTIRE downside, = feeBps
P/L after 200 pair of organic volume: +157.2064 pair
organic buyers paid in              : 200.0000 pair
organic bags now worth              :  45.1804 pair
ORGANIC LOSS                        : -154.8195 pair   (77% of everything they put in)
```

A 3-pair premium on a 157-pair payoff. This is **inherent to opening single-sided at a price the
creator picks** — the opening market cap is the strike price of a call option on the entire supply,
exercisable by the first transaction, with a premium equal to the trading fee. It is not a coding
error and there is no version of "fix it" that does not change what the product is.

Options, least invasive first:

1. **Do nothing and say it on the token page.** Zero code. The framing above is already written and
   is honest. This is what I would ship today.
2. **A first-block buy cap.** `LaunchToken` records `launchBlock` and applies a tighter cap
   (`maxWallet / N`, or a fixed share of supply) while `block.number == launchBlock`. Two storage
   reads on the hot path for one block of protection; a sniper simply buys in block 1 instead, or
   across N addresses in block 0. **Cheap and close to useless.**
3. **A decaying opening fee.** `feeBps` starts at, say, 3x and decays linearly to the configured rate
   over the first hour. This is the only option that actually changes the option premium: it raises
   the sniper's downside from `feeBps` to `3 × feeBps` without changing anything for a holder who
   arrives later. It is also a change to the fee promise — "the terms a creator agreed to must be the
   terms forever" — so it would have to be a launch parameter, disclosed, and immutable.
4. **A launch cooldown** (no trading for N blocks). Removes the block-0 race and replaces it with a
   block-N race, and it makes the pool look broken to every aggregator for the cooldown.

**Note that E-06's fix above already helps a little and was not designed to:** a launch that sets a
max wallet now genuinely bounds what one address can end up holding, so the 49%-of-supply single-
wallet snipe is no longer available on a capped launch. It does not stop a twelve-address snipe.

### F-02, E-02, E-05, E-08, V-04, V-05, D-03/D-04/D-05, A-1, F-04, F-07, I-2, I-5

Out of scope for this pass and unchanged. `test_F02` was re-parameterised (see §4) but the finding is
untouched. Each still passes while asserting the vulnerable behaviour, which is the correct treatment
until somebody decides on them.

---

## Numbers

| | before | after |
|---|---|---|
| `forge test --no-match-contract Fork` | 914 passed / 0 failed | **919 passed / 0 failed** |
| tests inverted from "asserts the bug" to "guards the fix" | — | 19 (counting per source function; several run in both currency orderings) |
| tests added (controls and companions) | — | 5 |
| tests deleted | — | **0** |
| `src/` files changed | — | 7 (`Distributor`, `FeeHook`, `Launcher`, `LaunchToken`, `PairRegistry`, `ReferralVault`, `VestingVault`) |
| `src/ZapRouter.sol`, `test/ZapRouter.t.sol`, `script/DeployZap.s.sol` | untouched | untouched |

### Inversions, and the pre-fix failure message that is each one's negative control

Every one of these was run against `src/` at `e5e1bdd` first. The messages below are verbatim from
that run and name the exact quantity that flipped.

| test (before → after) | pre-fix evidence |
|---|---|
| `test_R2_07_aReentrantConverterSettlesAClaimWithoutPayingIt` → `test_R2_07_fixed_aReentrantConverterCannotSettleAClaimWithoutPayingIt` | passed while asserting alice received 0 |
| `test_R2_07c_thePushPathAlsoSettlesAClaimItNeverPaid` → `test_R2_07c_fixed_thePushPathReportMatchesWhatActuallyLeft` | passed while asserting `sentTotal != reallyMoved` |
| `test_D02_aContractHolderThatCannotPullLocksItsDividendsForever` → `test_D02_fixed_aContractHolderCanRenounceSoItsShareIsRedistributed` | `renounceAccrual()` did not exist |
| `test_D02b_vestingVaultRenounceDestroysTheStreamInsteadOfRedistributingIt` → `test_D02b_fixed_vestingVaultRenounceRedistributesTheStream` | `renouncing removed no shares: 0 != 1000000000000000000000` |
| `test_D03c_nothingInTheSystemEverCallsProcessBatch` → `test_D03c_fixed_thePushPathIsKeeperDrivenAndAKeeperCanActuallyPay` | passed while asserting nothing on chain would push |
| `test_E09_atTheMinimumFeeTheHoldersAndCreatorGetNothing` → `test_E09_fixed_theMinimumFeeIsRejectedInsteadOfPayingHoldersNothing` | `FeeBelowPlatformFloor(100)` |
| `test_E06_maxWalletIsBypassedByBuyingWideAndConsolidating` → `test_E06_fixed_maxWalletNowBoundsTheFinalHoldingNotJustOneBuy` | `MaxWalletExceeded(0xbaDbad, 3.96e25, 2e25)` |
| `test_V03_priceLimitedBuyPaysTheFullFeeOnUnspentInput` → `test_V03_fixed_aPriceLimitedBuyIsRefusedRatherThanOvercharged` | `WrappedError(…0x20CC, …)` = `PriceLimitedBuyWouldOvercharge` |
| `test_finding_aTwoWalletCycleLetsACreatorCreditThemselvesTheWholeSchedule` → `test_fixed_aTwoWalletCycleEarnsNoMoreThanOneHonestReferrer` | `expected the whole schedule…: 2000 !~= 4000` |
| `test_finding_aFeeRecipientBreaksTheReferralChainSilently` → `test_fixed_aFeeRecipientNoLongerBreaksTheReferralChain` | `the referral WAS recorded: 0x0 != 0x8eef` |
| `test_finding_anyoneCanPermanentlyLockATopUpInSomeoneElsesVault` → `test_fixed_aStrangerCannotLockATopUpInSomeoneElsesVault` | `OnlyLauncherOrBeneficiary()` |
| `test_finding_anyoneCanFillMaxSchedulesAndBlockAllFutureLocks` → `test_fixed_aStrangerCannotFillMaxSchedules` | `OnlyLauncherOrBeneficiary()` |
| `test_info_addScheduleSilentlyTrimsInsteadOfReverting` → `test_fixed_addScheduleRevertsInsteadOfSilentlyTrimming` | `AmountExceedsUnscheduled(3.402e38, 1e20)` |
| `test_finding_registryOwnershipCanBeRenouncedInOneCallAndFreezesTheAllowlist` → `test_fixed_registryOwnershipCannotBeRenounced` | `OwnershipCannotBeRenounced()` |
| `test_aThresholdOneWeiAboveTheOpeningIsAccepted` → `test_aThresholdBelowTheRealOpeningPriceIsRefused` | `BornGraduated(1e20 + 1, 100290561036899339019)` |
| `test_walletToWalletIsNotCapped` → `test_walletToWalletIsCappedToo` | `MaxWalletExceeded(0xA11cE, 4e25, 2e25)` |
| `test_aFeeExactlyAtTheFloorIsAcceptedAndIsAllPlatform` → `test_fixed_aFeeExactlyAtTheFloorIsRejectedInsteadOfPayingHoldersNothing` | `FeeBelowPlatformFloor(100)` |
| `test_E02b_…OneWeiAboveTheOpen` → `test_E02b_…JustAboveTheRealOpen` (partial: E-07 half fixed, E-02 half open) | `BornGraduated(1e20 + 1, 100290561036899339019)` |
| `test_E07_theWorstHonestLookingLaunch` (name kept, half inverted) | `BornGraduated(5e20, 2112535799871658722160)` |

### A vacuous pass caught during this pass, and how

`test_R2_07_fixed` was first written asserting `assertGt(conv.hits(), 0, "the converter was never
called")`. It **failed** with `0 <= 0` — because the nested `processBatch` now reverts, `convert`
reverts with it, and the converter's own `hits++` is rolled back in the same frame. A counter inside
a reverting callee is worthless as evidence. The guard is now an assertion that the caller emitted
`RewardConversionFailed`, which is a log from the surviving frame and can only be reached by
approving the converter and attempting the conversion. Both R2-07 tests use it.

The four `ZapRouter` suites failed mid-pass on `test_configurePool_revertsOnReconfigure`, which they
inherit from `FeeHookHarness` in `test/FeeHook.t.sol`. It was passing `feeBps = 100` — now illegal —
so the reconfigure guard it exists to test was never being reached. Fixed in the harness, in
`test/FeeHook.t.sol`, which is a file this pass owns.
