# Audit 04 — Uniswap v4 integration correctness

**Surface:** `src/FeeHook.sol`, `src/base/HookBase.sol`, `src/Launcher.sol`
(`_seedLiquidity`, `_openingTick`, `_openingSqrtPrice`, `unlockCallback`).

**Scope:** delta settlement, sign conventions, single-sided seeding, re-entrancy through the
PoolManager, `Hooks.noSelfCall`, `beforeInitialize`, ERC-6909 claim accounting.
Fee *economics* were audit 01, dividends audit 02, access control audit 03. Anything already
reported there is cross-referenced, not re-counted.

**No file under `src/` was modified.**

---

## Which v4 I read

Everything below was checked against the **installed** sources, not from memory:

```
lib/v4-periphery/lib/v4-core   @uniswap/v4-core 1.0.2   59d3ecf ("bump to 1.0.2", 2025-05-13)
lib/v4-periphery                                        07336f2 (2026-08-10)
```

Files read line by line:

| File | What it settled |
|---|---|
| `src/PoolManager.sol` | `unlock` :104-114, `swap` :187-227, `take` :291, `mint` :322, `burn` :332, `_settle` :349-365, `_accountDelta` :368 |
| `src/libraries/Hooks.sol` | `noSelfCall` :171-175, `beforeSwap` :248-282, `afterSwap` :285-315, `validateHookPermissions` :83, flag constants :29-47 |
| `src/types/BeforeSwapDelta.sol` | `toBeforeSwapDelta(deltaSpecified, deltaUnspecified)` — specified is the **upper** 128 bits |
| `src/libraries/Pool.sol` | `modifyLiquidity` branch boundaries :209 / :218 / :230 |
| `src/libraries/SafeCast.sol` | `toInt128(uint256)` :56-59 |
| `src/libraries/TransientStateLibrary.sol` | `currencyDelta`, `getSyncedReserves` |
| `src/test/PoolSwapTest.sol` | settle ordering (sync happens **after** the swap) |

There is no `CurrencySettler` in v4-core `src/`; it lives at `test/utils/CurrencySettler.sol` and is
test-only. The hook does not use it.

---

## What I exercised

New file: **`test/audit/HookAudit.t.sol`** — 51 tests, all green.
Suite total went **494 → 545 passed, 0 failed** (`forge test --no-match-contract Fork`).

The important methodological point, and it is the same one that paid off in audit 01:

> `test/FeeHook.t.sol` seeds a **symmetric full-range pool at 1:1 with liquidity on both sides**.
> Production never has that. `test/audit/FeeAudit.t.sol` added a hand-built single-sided pool.
> **This file goes one step further and drives the real `Launcher`**, so every pool under test was
> opened by `_openingTick` and seeded by `_seedLiquidity` exactly as a live launch would be — one
> position, whole supply, zero pair currency, starting at the snapped opening tick.
> Three of the four findings below only exist in that shape.

Structure:

- `HookAuditWorld` — real `PoolManager`, `PairRegistry`, `FeeHook` at `…20CC`, `Launcher` deployed
  into its reserved CREATE slot (the circular-immutable dance), `LaunchToken` implementation, salt
  mined per launch so the token lands on the requested side.
- `HookAuditCases` — 23 tests, run **twice**: `HookAuditTokenIsCurrency0Test` and
  `HookAuditTokenIsCurrency1Test`. Every delta sign in the hook flips with the ordering.
- `HookAuditSeedingTest` — 5 tests, `_openingTick`/`_seedLiquidity` across the legal band,
  including a **1,000-run fuzz over (supply, openingMarketCap, tickSpacing, ordering)**.
- Two probes: `SyncFirstRouter` (pays before swapping) and `UnlockReentrantSweeper` (calls `sweep`
  from inside an open unlock cycle).

Swap shapes traced by hand against the installed source **and** executed in both orderings:

```
                  specified   unspecified   charged where   hook return                verified
buy  exact-in     pair        token         _beforeSwap     toBeforeSwapDelta(+fee,0)  yes
buy  exact-out    token       pair          _afterSwap      int128 +fee                yes
sell exact-in     token       pair          _beforeSwap     toBeforeSwapDelta(+fee,0)  yes
sell exact-out    pair        token         _afterSwap      int128 +fee                yes
```

---

## Findings

**1 medium ×3, 1 low, 3 info. Nothing here lets an attacker take value out of the system.**
Two of the three mediums cost a *counterparty* money; the third is a feature that silently does
nothing. The one genuinely dangerous defect on this surface — a permanent `CurrencyNotSettled`
brick — was already found and reported as audit 01 F-05 (see cross-reference at the end).

---

### V-01 — MEDIUM — The automatic sweep is unreachable from an exact-input swap

`src/FeeHook.sol:631` (early return) vs `src/FeeHook.sol:650` (`_tryAutoSweep`)
**REPRODUCED**, both orderings — `test_V01_autoSweepIsUnreachableFromExactInputSwaps`,
`test_V01b_routerOnlyTrafficLeavesHoldersUnpaidIndefinitely`

`_afterSwap` returns at

```solidity
bool exactInput = params.amountSpecified < 0;
if (exactInput) return (IHooks.afterSwap.selector, 0);   // :630-631
```

which is **before** `_tryAutoSweep(id, key, cfg)` at `:650`. Exact input is the shape every router,
aggregator and swap UI sends by default. Two further early returns narrow it more: `rate == 0` at
`:636` kills it for exact-output *sells* on the default launch (`sellFeeBps = 0`), and
`inDelta >= 0` at `:641`. **The only swap shape that can reach the automatic payout is an
exact-output BUY.**

Measured: twenty ordinary exact-input buys build a backlog more than five times
`autoSweepThreshold`, and the distributor, the creator and the platform all receive exactly zero.
One exact-output buy on the same pool immediately pays all three.

Impact. Nothing is lost — the fees are correct ERC-6909 claims and `sweep` still redeems them —
but the feature `Launcher` arms on **every** launch (`configureGraduation` sets
`autoSweepThreshold = threshold / 1000`, `FeeHook.sol:437`) does not fire on ordinary traffic. A
holder's `withdrawableOf` stays at zero until a human or a bot pays gas for `sweep`. The docstring
at `FeeHook.sol:655-666` describes it as "an opportunistic payout … once the backlog is worth the
gas" with no exactness qualifier, and `test_autoSweepFiresOnceTheBacklogIsWorthIt` in the existing
suite passes only because it deliberately sends an exact-output buy.

This is the payout-side twin of the original defect this hook exists to fix: *the pool works and
the thing that was supposed to happen silently does not, on exactly the shape real routers send.*

Not fixed here. Worth noting that moving the call is not free — `_tryAutoSweep` needs a settled
`cfg` and a currency the singleton actually holds, and calling it from `_beforeSwap` would take
from a reserve the current trader has not funded yet. **See V-02: the auto path taking mid-swap is
itself a defect, so the honest options are "make it reachable and accept V-02 more often" or
"delete the auto path and lean on the `sweep` bounty".**

---

### V-02 — MEDIUM — `take()` inside `afterSwap` corrupts settlement for any caller that syncs first

`src/FeeHook.sol:698-699` (`autoRedeem`'s `burn` + `take`), reached from `:650`
**REPRODUCED**, both orderings — `test_V02_takeInsideAfterSwapCorruptsASyncFirstPayersSettlement`,
`test_V02c_aLargeBacklogMakesTheSyncFirstPayersSwapRevertOutright`,
control: `test_V02b_theSameProbeIsExactWhenTheAutoPathDoesNotFire`

`autoRedeem` runs **inside the PoolManager's swap**, and its second line moves real ERC-20 out of
the singleton:

```solidity
poolManager.burn(address(this), cfg.pairCurrency.toId(), payout);
poolManager.take(cfg.pairCurrency, address(this), payout);   // :699
```

`PoolManager._settle` (`PoolManager.sol:349-365`) credits a payer with

```solidity
uint256 reservesBefore = CurrencyReserves.getSyncedReserves();
uint256 reservesNow    = currency.balanceOfSelf();
paid = reservesNow - reservesBefore;
```

so **anything that leaves the singleton between a caller's `sync` and their `settle` is silently
deducted from what that caller is credited.** Uniswap's own routers sync *after* the swap
(`PoolSwapTest.sol:102-107`, `DeltaResolver._settle`), so they are unaffected. The
`sync → transfer → swap → settle` order is equally legal v4 and is what an integrator writes when
it wants to pay once up front, and that integrator is charged the hook's whole auto-swept amount on
top of its trade.

Measured with `SyncFirstRouter`, against a control run of the **identical** trade through
`PoolSwapTest` from the same state snapshot (token = currency0; the currency1 suite matches):

```
cost via the Uniswap-supplied router : 0.400539139623279432 pair
cost via the sync-first router       : 3.412205328155996308 pair
overcharge                           : 3.011666188532716876 pair   (8.5x the trade's true cost)
settle() shortfall (prepay-credited) : 3.011666188532716876 pair   (identical, to the wei)
```

The overcharge is not stolen — it is paid a second time to the distributor, the creator and the
platform. The payer simply funds someone else's dividend.

Harder branch, `V-02c`: when the unswept backlog exceeds what the payer handed over between the
`sync` and the `settle`, `reservesNow - reservesBefore` **underflows** and the whole transaction
reverts with a bare panic `0x11` carrying nothing an integrator can act on. Which branch a given
trade lands in depends on the pool's backlog at that block, so it is nondeterministic from the
caller's side.

Control (`V-02b`): the same probe against a pool where the auto path does not fire credits every
wei and charges exactly the standard cost. That pins the cause on the hook's mid-swap `take` and
not on the probe's ordering.

Today this is latent — no mainstream router uses that order. It becomes live the moment anyone
builds a custom router, an intent solver, or a batch executor against these pools.

---

### V-03 — MEDIUM — A price-limited exact-input buy pays the full fee on input it never spent

`src/FeeHook.sol:591-592`
**REPRODUCED**, both orderings — `test_V03_priceLimitedBuyPaysTheFullFeeOnUnspentInput`

```solidity
uint256 amountIn = uint256(-params.amountSpecified);
uint256 fee = (amountIn * rate) / BPS;
```

The fee is `feeBps` of the amount **requested**, computed before the curve runs. If
`sqrtPriceLimitX96` stops the swap early the unspent input is refunded but the fee on it is not.

The docstring at `FeeHook.sol:550-554` names this and calls the overcharge "bounded by `feeBps`".
That is true of the *notional* and false of the *rate*, and the rate is what a trader experiences.
On a live launcher-seeded pool at the configured 3%:

```
requested input   : 100.000000000000000000 pair
actually debited  :   3.301308354505875602 pair
fee charged       :   3.000000000000000000 pair
effective rate    : 9,087 bps  (90.87% — 30x the advertised 3%)
```

The trader paid three pair of fee for roughly 0.30 pair of execution.

It is not only self-inflicted. **A sandwicher can force it**: front-run a victim's exact-input buy
so the price sits one tick short of the victim's own `sqrtPriceLimitX96`, and the victim's swap
fills for almost nothing while still paying `feeBps` of the full notional. The attacker does not
capture the fee (it goes to holders/creator/platform), so this is griefing rather than extraction —
but the victim's loss is real and is capped only by their stated size.

Note that pushing the charge to `_afterSwap` — the obvious fix — reintroduces the zero-fee hole on
exact-input buys that this hook exists to close. The correct fix is to charge in `_beforeSwap` and
**refund the unused portion in `_afterSwap`** using the unspecified-currency return, which the hook
already has the flag for.

---

### V-04 — LOW — `unlockCallback`'s buyback can leave an unsettled pair credit

`src/FeeHook.sol:818-840`
**REASONED**, not reproduced

Step 3 deducts the burn wedge from `totalPair` *before* the swap:

```solidity
uint256 toBurn = (totalPair * cfg.burnBps) / BPS;
if (toBurn != 0) {
    totalPair -= toBurn;                                  // :820
    BalanceDelta d = poolManager.swap(key, SwapParams({
        amountSpecified: -int256(toBurn), … }), "");      // :821-832
```

and never checks that the swap actually consumed `toBurn`. If the buyback partially fills — the
price walks to `sqrtPriceLimitX96` with input remaining — the hook keeps a pair credit of
`toBurn - consumed` that is not in `totalPair`, `take` at `:845` closes only `totalPair`, and the
unlock cycle ends non-zero → `CurrencyNotSettled`.

This is the *same defect shape* as the reproduced sell-conversion brick (audit 01 F-05, same
function, `:798-810`) applied to the other swap. It is rated LOW only because it is not reachable
on a `Launcher`-seeded pool: the buyback pushes the price **upward** and `_seedLiquidity` runs the
position all the way to `TickMath.maxUsableTick`, so exhausting it means buying essentially the
entire supply. It becomes reachable if the seeding range is ever narrowed, or if a future pool is
seeded by anything other than `Launcher`. The fix is one line either way — clamp `toBurn` to what
the swap reported, exactly as `gained` is handled at `:811-812`.

---

### V-05 — INFO — Seeding dust reaches the creator on any launch with a dev buy

`src/Launcher.sol:656` vs the rule stated at `src/Launcher.sol:692`
**REPRODUCED** — `test_V04_seedDustReachesTheCreatorWheneverThereIsADevBuy`

`_refundResidual` burns unseeded launch-token dust to the dead address because giving it to the
creator "would be an unadvertised allocation". But `_devBuy` runs **first** and reads an absolute
balance:

```solidity
uint256 bought = IERC20(d.token).balanceOf(address(this));   // :656
```

which at that instant is the tokens the dev buy bought **plus** the seeding dust. So on any launch
with a dev buy the dust goes to the creator (or their vault) and the burn branch never sees it.

Measured dust on a 1e27-supply launch: **578 wei**. Economically nil — filed only because it is the
one place in the launch path that reads a balance instead of a delta, and because it silently
contradicts an explicitly stated rule fourteen lines below it.

---

### V-06 — INFO — The reciprocal opening price reverts inside `FullMath`, not by name

`src/Launcher.sol:540`
**REPRODUCED** — `test_INFO_theReciprocalCaseRevertsInsideFullMathWithNoNamedError`

`_openingTick` computes `FullMath.mulDiv(amount1, 2^192, amount0)` and that call overflows before
the `OpeningPriceOutOfRange` check at `:543` can run, whenever `amount1 / amount0 >= 2^64`. The
launch is correctly refused either way — nothing is clamped — but one direction reverts with the
named error and the other with empty revert data the UI cannot render. `test_openingPriceBelow
TheBandRevertsByName` pins the good direction.

---

### V-07 — INFO — `configurePoolFull` does not validate the key against the config

`src/FeeHook.sol:326-369`
**REASONED**

`configurePoolFull` never checks that `s.pairCurrency` is one of `key.currency0`/`key.currency1`,
that `key.hooks == address(this)`, or that `key.fee == 0`. If `pairCurrency` were not one of the
pool's currencies, `_beforeSwap` would mint a claim in a currency the manager credits it in a
different one, and **every swap in the pool would revert `CurrencyNotSettled` forever**.

Sound today only because the single caller is `Launcher._configureHook`, which builds the key from
`p.pair` five lines earlier and hardcodes `fee: 0` and `hooks: feeHook`. Three cheap `require`s
would make the hook's own invariant local instead of borrowed.

Related and equally borrowed: `_accrue` mints `fee` as a `uint256` (`PoolManager.mint` safe-casts
via `SafeCast.toInt128`, `SafeCast.sol:56-59`) but returns it through an **unchecked**
`int128(uint128(fee))` at `:601` and `:652`. A fee at or above `2^127` would return a *negative*
delta. It is unreachable only because the `mint` on the line before reverts first. The ordering is
load-bearing and undocumented.

---

## Checked and found sound

Each of these is an assertion in `test/audit/HookAudit.t.sol`, run in **both** currency orderings.

**Delta settlement**

- **All four swap shapes settle on a real single-sided pool**, with a sell tax and a burn wedge both
  armed so every path in `_beforeSwap`, `_afterSwap` and `unlockCallback` runs, followed by a clean
  `sweep`. No `CurrencyNotSettled`. `test_sound_allFourSwapShapesSettleOnASingleSidedPool`
- **No shape is charged by both legs.** The exactness guard at `:631` is what separates them; a buy
  is charged exactly once and never above `feeBps`. `test_sound_noSwapShapeIsChargedByBothLegs`
- **The hook retains nothing** — no ERC-20, no stray claims — after a full buy/sell/sweep cycle.
  `test_sound_hookRetainsNothingAfterAFullCycle`

**Sign conventions — verified against the installed `BeforeSwapDelta.sol` and `Hooks.sol`**

- `toBeforeSwapDelta(deltaSpecified, deltaUnspecified)` takes **specified first** (upper 128 bits).
  `FeeHook.sol:601` passes `(+fee, 0)`, which is correct: `Hooks.beforeSwap:275` does
  `amountToSwap += hookDeltaSpecified`, so `-1000` becomes `-970` at a 3% fee. **The trader is
  debited the full 1000 and the fee comes OUT of the input**, measured exactly.
  `test_sound_beforeSwapDeltaSignTakesTheFeeOutOfTheInput`
- `_afterSwap`'s `int128` return lands in the **unspecified** slot (`Hooks.afterSwap:299-302`). On
  an exact-output buy that is the input currency, so a positive value is charged **on top** of what
  the curve consumed — `paid == consumed + fee` and `fee == consumed * feeBps / BPS`, measured to
  within 2 wei. `test_sound_afterSwapDeltaSignAddsTheFeeOnTopOfTheInput`
- The specified/unspecified→currency0/currency1 mapping in `Hooks.afterSwap:307-309`
  (`amountSpecified < 0 == zeroForOne`) matches the hook's `isBuy`/`inputIsCurrency0` derivation in
  both orderings. Proven by the whole suite passing twice rather than by inspection alone.

**`Hooks.noSelfCall` — read, not assumed**

`Hooks.beforeSwap` returns early at `Hooks.sol:253` and `Hooks.afterSwap` at `:293` when
`msg.sender == address(self)`. `unlockCallback` calls `poolManager.swap` as the hook, so both
internal swaps skip the hook's own callbacks. **This does not recurse and is not taxed** — after a
sweep that runs both the sell-fee conversion (a sell) and the buyback (a buy),
`pendingTokenFees == 0`, `pendingFees == 0` and `totalFeesTaken` is unchanged, while
`totalBurned > 0` proves the buyback really ran.
`test_sound_noSelfCallMeansTheInternalSweepSwapsAreUntaxed`

**Re-entrancy through the manager**

- `sweep` calls `poolManager.unlock`, and v4's `Lock` is one global transient flag, so **`sweep` is
  unreachable from inside any open unlock cycle** — it reverts `AlreadyUnlocked` rather than
  silently re-entering. `test_sound_sweepCannotBeReenteredFromInsideAnUnlockCycle`
- The auto path correctly avoids that trap by using `burn` + `take` directly instead of a nested
  `unlock` (`FeeHook.sol:695-699`), proven by it completing inside a live swap. A nested `unlock`
  would revert and the `try/catch` would turn **every** auto sweep into a silent
  `AutoSweepSkipped`. `test_sound_autoRedeemUsesBurnAndTakeRatherThanANestedUnlock`
- `autoRedeem` is external for the `try/catch` boundary and rejects every outside caller.
  `test_sound_autoRedeemRejectsEveryOutsideCaller`
- **A failing auto sweep never breaks somebody's trade.** On the pool's very first trade the
  singleton holds zero pair currency, so the `take` cannot succeed; the swap completes anyway and
  the claim stays queued. `test_sound_aFailedAutoSweepNeverBreaksTheTrade`
- No path was found by which a re-entrant party can extract value during the hook's unlock cycle.
  `take` requires a positive delta and `NonzeroDeltaCount` is checked globally at `unlock`'s close,
  so a re-entrant delta either settles or reverts the whole transaction.

**Single-sided seeding**

- **The seed requires exactly ZERO pair currency**, which is what the whole "launching costs nothing
  but gas" claim rests on. `pair.balanceOf(poolManager)` is unchanged by a launch, the launcher
  retains nothing, and the opening tick is aligned to the spacing. Asserted **unconditionally**
  across a 1,000-run fuzz over `(supply ∈ [1e18, 1e27], openingMarketCap ∈ [supply/1e6, supply×1e6],
  tickSpacing ∈ {1, 10, 60, 100, 200, 2000}, ordering)`.
  `testFuzz_singleSidedSeedNeverNeedsPairCurrency`
- The mechanism, confirmed against `Pool.sol:209/218/230`: `_openingTick` rounds **up** for
  `tokenIsCurrency0` and **down** for `tokenIsCurrency1` (`Launcher.sol:553-555`, including the
  floor-for-negatives correction), so the pool's initial tick is exactly the position boundary. At
  `tick == tickLower` the `else if (tick < tickUpper)` branch computes
  `getAmount1Delta(sqrtPriceAtTick(tickLower), sqrtPriceX96, L)` with the two prices **identical** —
  exactly zero, not "rounds to zero". At `tick == tickUpper` the `else` branch is all-currency1.
- The explicit corner grid — deeply negative ticks, positive ticks, `tickSpacing = 1` where rounding
  has nowhere to go, `tickSpacing = 2000` where the snap moves the price visibly, and a prime market
  cap so the raw tick is never a multiple of the spacing — holds in both orderings with no
  swallowed reverts. `test_singleSidedSeedHoldsAtEveryCorner`
- **The snap direction is safe for the creator**: the pool never opens *cheaper* than requested, in
  either ordering. `test_theSnapNeverOpensTheTokenCheaperThanRequested`
- The opening price is a real floor — a full round trip cannot push the price back through the
  opening tick. `test_sound_thereIsNoLiquidityBelowTheOpeningTick`
- `OpeningPriceOutOfRange` is a refusal, not a clamp (see V-06 for the error-quality caveat).

**`beforeInitialize`**

`_beforeInitialize` requires `poolConfig[key.toId()].configured`, and `PoolId` hashes the **entire**
`PoolKey`, so no variation reaches a configured entry. Attacked with a different tick spacing, a
different static fee, and the dynamic-fee sentinel `0x800000` — all three revert. The launched pool
itself cannot be re-initialised. There is no window in `Launcher.launch` between `configurePoolFull`
(`:358`) and `initialize` (`:376`) that an untrusted party can reach; the only external call in
between is the `try IReferralVault(referralVault).setReferrer` at `:462`, and that target is
deployer-set and one-shot (audit 03). `test_sound_strangerCannotOpenASecondPoolAgainstThisHook`,
`test_sound_theLaunchedPoolCannotBeReinitialised`

**ERC-6909 claims on the singleton**

The PoolManager is a singleton, so the hook's claim balance in a currency is **shared across every
pool that uses it**. The invariant that matters is that the claim balance equals the sum of the
per-pool ledgers — never more (unredeemable) and never less (one sweep would spend another pool's
claims). Verified with two launches sharing the same pair currency, one of them charging a sell tax:
`balanceOf(hook, pairId) == pendingFees[A] + pendingFees[B]` exactly, `balanceOf(hook, tokenBId) ==
pendingTokenFees[B]` exactly, and sweeping A leaves B's claims untouched.
`test_sound_claimBalanceMatchesThePerPoolLedgersAcrossTwoLaunches`

`FeeHook` contains **no absolute-balance read at all** — no `balanceOf`, no
`address(this).balance`. Every quantity it moves comes from its own per-pool mappings or from a
delta the manager returned. The one absolute read in the launch path is `Launcher.sol:656`, which is
the launcher's own balance and is V-05.

---

## Cross-reference — not counted here, but it is a delta-settlement defect

**`sweep()` bricks permanently once the sell-fee pile outgrows the pool's pair reserve** —
`FeeHook.sol:798-810`, reported as **audit 01 F-05 (HIGH)** and reproduced in
`test/audit/FeeAudit.t.sol:test_F05_sweepBricksWhenTheSellPileExceedsThePoolsPairReserve`.

I re-derived it independently from the v4 side and confirm the mechanism: `unlockCallback` burns the
whole `pendingTokenFees` claim into a token credit and sells it in one exact-input swap without
checking consumption. On a single-sided pool there is no liquidity below the opening tick, so the
conversion either hits `Pool.PriceLimitAlreadyExceeded` (price pinned at the floor) or partially
fills and leaves a **positive** token credit. `PoolManager.unlock:112` checks
`NonzeroDeltaCount.read() != 0` — **sign-agnostic**, so a leftover credit reverts exactly like a
leftover debt. `sweep` is the only thing that clears `pendingTokenFees` and it reverts before
reaching the line that clears it, so the state is self-perpetuating.

It remains the most important defect on this surface. V-04 above is the same bug in the sibling
swap.

---

## Plainly

**Nothing on this surface is exploitable for profit.** No path lets a caller extract value from the
hook, the pool, another pool's reserves, or another pool's ERC-6909 claims. The delta signs are
right in all four swap shapes and both currency orderings, `noSelfCall` does what the code assumes
it does in the installed v4-core 1.0.2, the single-sided seed provably needs no pair currency across
a thousand fuzzed shapes, and `beforeInitialize` is airtight.

What is wrong is narrower and all of it is about *someone else's* money or *nobody's*:

- a payout feature that never fires on the swap shape real routers send (**V-01**),
- a mid-swap `take` that overcharges — measured at 8.5x the trade cost — or hard-reverts any
  integrator that pays before swapping (**V-02**),
- a fee charged on input the pool never spent, at up to a measured 90.87% effective rate, and
  forceable by a sandwicher (**V-03**).

V-02 and V-03 both cost a counterparty real money. Neither pays the attacker, so both are griefing
rather than theft — which makes them cheap to leave and cheap to fix.

The one thing that would take a live pool offline is audit 01 F-05, and it is still open.
