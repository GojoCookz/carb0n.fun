# Audit 02 — Dividend accounting in `src/Distributor.sol` and `src/LaunchToken.sol`

**Scope:** `src/Distributor.sol` and `src/LaunchToken.sol` in full — the magnified accumulator
(`_magnifiedPayoutPerShare`, `_corrections`, `accumulativeOf`, `withdrawableOf`), `distribute` /
`pendingPayouts`, `minSharesForDistribution`, `setBalance` / `setExcluded`, the push (`processBatch`)
and pull (`withdraw`) paths, `_trySend` and the reward-conversion route, and `LaunchToken._update`.
`src/Launcher.sol::_validate` and `_cloneAndInit`, `src/FeeHook.sol::_routeFee` and
`src/VestingVault.sol` were read for how this surface is driven and consumed. **Nothing under
`src/` was modified.**

**Evidence:** `test/audit/DividendAudit.t.sol`, 33 tests, all passing. Every finding marked
REPRODUCED has a named test in that file. Full suite after the additions:
`forge test --no-match-contract Fork` → **469 passed, 0 failed** (was 436).

---

## What was actually exercised

I drove the `Distributor` directly with the test contract as both `shareToken` and `controller`
(the `Adversarial.t.sol` shape) so every privileged entry point is reachable, and separately drove
it through a real cloned `LaunchToken` for the `_update` edge shapes. Specifically: five converter
behaviours the existing `RewardCurrency.t.sol` does not model — one that **spends its allowance and
then returns zero** (its `ZeroConverter` is `pure` and never touches the allowance), one that reaches
for double the allowance, one that pulls half, one that reverts, and one that reenters both
`withdraw()` and `processBatch()` from inside `convert`; the carry lifecycle across repeated
re-carries and a holder base that drops back below the floor; queue enqueue/dequeue at
`minShareForQueue == 0` and at a positive threshold with dust left behind; cursor behaviour across
a full lap, a partial lap and a swap-and-pop that moves an entry behind the cursor; exclusion under
every `setBalance` shape an excluded account can receive, plus exclude → un-exclude → re-entry; the
`VestingVault.renounceAccrual` path against a live vault; self-transfers, zero-value transfers and
transfers to and from excluded accounts through the real token; a 1,000-run solvency fuzz with
exclusion and balance churn interleaved with `processBatch`; and a **located** overflow boundary for
`minSharesForDistribution`, probed from both sides at three supplies spanning 15 orders of magnitude
(`1e18`, `1e27`, `1e33`).

**Result: 1 high, 2 medium, 3 low, 2 informational.** The high one drains the contract at 2× per
withdrawal and leaves the remaining holders permanently unpayable.

---

## Findings

### D-01 — A converter that spends its allowance and returns zero is paid, and then the holder is paid again out of everyone else's money

- **SEVERITY: HIGH**
- **Location:** `src/Distributor.sol:339-371`. Specifically the success test at `:354`
  (`if (out != 0)`) paired with the unconditional fallback at `:368-370`.
- **REPRODUCED** — `test_D01_converterThatSpendsTheAllowanceAndReturnsZeroIsPaidTwice`,
  `test_D01b_theSecondPaymentLeavesEveryOtherHolderUnableToClaim`,
  `test_D01c_onePushBatchEmptiesTheContractAndStrandsTheSecondHolder`, with
  `test_D01d_control_anHonestConverterPaysExactlyOnce` as the negative control.

`_trySend` approves the converter for exactly `amount`, calls `convert`, and treats a **zero return
value** as "could not route". But it only checks the return value. It never checks whether the
allowance was actually spent. A converter that pulls `amount` and returns `0` therefore falls
straight through to the pair-currency fallback at `:368`, and the contract pays the same claim
twice:

```
200e18 distributed, alice and bob owed ~100e18 each
alice calls withdraw()
  -> converter holds  99.999999999999999999e18   (the allowance, spent)
  -> alice holds      99.999999999999999999e18   (the fallback, on top)
  -> distributor holds                        2  (truncation dust)
  -> _withdrawn[alice] recorded ONE payment
```

The existing invariant does not see this. `totalWithdrawn <= totalDistributed` still holds — the
ledger only ever recorded one payment — which is asserted in the test.

**What an attacker gains.** Two full claims per withdrawal, capped only by the contract's balance.
After one withdrawal the distributor is short by exactly one holder's claim; every other holder is
then permanently stuck (asserted in D-01b): the pull path reverts `NothingToWithdraw`, and the push
path fails, restores the claim, and moves on — so they are not paid late, they are not paid at all.
The push path is drained the same way, one batch emptying the whole contract (D-01c).

**On trust.** `Launcher.initRewardConverter` (`src/Launcher.sol:305-317`) is deployer-only and
one-shot, so in the deployed configuration the converter is protocol-controlled. Three reasons this
is still HIGH:

1. The code's own comment at `:341-342` states the threat model explicitly — *"this contract holds
   every holder's money and the converter is a separate deployment"* — and the defence it builds
   (an exact, non-unbounded allowance) is bypassed by the very next branch.
2. **The shape does not require malice.** A converter that pulls its input, routes it, and returns
   `amountOut` returns zero whenever the route produced nothing: dust input, a pool that moved, a
   hop that no-opped. `RewardCurrency.t.sol`'s `ZeroConverter` models "cannot route" as a `pure`
   function that never touches the allowance, so the honest-but-failed shape is untested.
3. `Distributor` is constructible directly with an arbitrary converter, and is not `Launcher`-only.

**The one-line shape of the fix** (not applied): treat a spent allowance as a completed payment —
compare `payoutToken.balanceOf(address(this))` before and after, or require the residual allowance
to be `amount` before falling through.

---

### D-02 — Exclusion is frozen at construction, so a claim held by an address that cannot pull is destroyed rather than redistributed

- **SEVERITY: MEDIUM**
- **Location:** `src/Distributor.sol:216-220` (`setExcluded`, `onlyController`) — the controller is
  `FeeHook`, and `FeeHook` contains no call to it (`grep -rn setExcluded src/` returns only the
  definition and the docstring at `:140`). Consequences at `src/Distributor.sol:248-258` and
  `src/VestingVault.sol:206-212`.
- **REPRODUCED** — `test_D02_aContractHolderThatCannotPullLocksItsDividendsForever`,
  `test_D02b_vestingVaultRenounceDestroysTheStreamInsteadOfRedistributingIt`

The excluded set is exactly what the constructor writes at `:169-173`: `0x0`, `0xdEaD`, the
distributor itself, the PoolManager and the launcher. It can never be changed afterwards, because
the only mutator is `onlyController` and the controller has no function that reaches it. This is
the same defect recorded as "the PoolManager accrued dividends with no reachable way to exclude it"
— the constructor exclusions fixed the two known cases, not the mechanism.

Two live consequences:

**(a) Any contract that holds the launch token and cannot call `withdraw()` burns its dividends.**
Reproduced with a bare `DumbHolder`: it accrues half a distribution, `processBatch` cheerfully
delivers the pair currency into it, and it is unrecoverable. Nothing about that is exotic — a
liquidity locker, a second pool, a bridge escrow, an airdrop contract or the token address itself
all qualify. Note the asymmetry: `LaunchToken` marks `exemptFromMaxWallet[address(this)]`
(`src/LaunchToken.sol:148`) but `Distributor` excludes `address(this)` meaning the *distributor*
(`src/Distributor.sol:171`), so the **token address is not excluded**
(`test_sound_whichAddressesAreActuallyExcluded`). The `FeeHook` is not excluded either.

**(b) `VestingVault.renounceAccrual()` does the opposite of what it documents.** It is described at
`src/VestingVault.sol:66` as *"Once true the locked supply's dividend claim belongs to the other
holders, forever"* and at `:206-208` as *"Give the locked supply's dividend claim to the other
holders."* It sets one boolean on the vault. The vault's shares stay in `totalShares`, so:

```
after renounceAccrual():
  shareOf(vault)   1000e18   unchanged
  totalShares      2000e18   unchanged
  next 200e18 distribution -> alice gains exactly 100e18, not 200e18
  withdrawableOf(vault) keeps growing
  claimDividends() now reverts AlreadyRenounced -> the vault's only exit is closed
  processBatch() still pushes real pair currency INTO the sealed vault
```

**What an attacker gains.** Nothing directly — this is value destruction, not theft. What is wrong
is that a founder who uses the advertised "give my locked bag's yield back to holders" signal
instead **destroys** that yield: holders receive not one wei more, and the pair currency is either
locked in the distributor against an unclaimable ledger entry or physically pushed into a vault
that has no code path to move it. A signal that does not do what it says is a disclosure problem as
much as an accounting one. Correct behaviour requires removing the vault's shares from
`totalShares`, which needs a reachable `setExcluded` — which does not exist.

---

### D-03 — Carried payouts are credited to whoever holds shares at flush time, not to whoever held while they accrued

- **SEVERITY: MEDIUM**
- **Location:** `src/Distributor.sol:189-205`, specifically the carry at `:196-199` and the
  unconditional division across the *current* `totalShares` at `:202`
- **REPRODUCED** — `test_D05_theCarryIsTakenByWhoeverHoldsSharesWhenItIsFlushed`,
  `test_D05b_theCarryWindowReopensWheneverTheHolderBaseShrinks`

`pendingPayouts` accumulates fees earned over a period and nothing records who held during it. When
the floor is finally cleared, the whole pile is divided by `totalShares` as it stands at that
instant. Measured:

```
alice holds FLOOR-1 for the entire accrual window and is the ONLY holder
5 x 100e18 of fees arrive -> all carried, alice owed 0
bob buys in AFTER every one of those fees was earned
one more 1e18 fee flushes the pile:
  bob    501.000...e18    (>99.8%)
  alice    0.500...e18    (~0.1%)
bob then sells to zero and withdraws the full 501e18 - the correction freezes the
claim on exit, it does not forfeit it
```

**What an attacker gains.** Buy the minimum qualifying position (`supply / 1e6`, i.e. 0.0001% of
supply) immediately before any trade flushes the carry, take the whole pending pile pro-rata, sell.
Cost is the round-trip fee on a floor-sized position. This is not a launch-only window:
`test_D05b` shows the carry reopens **every time the holder base falls back below
`minSharesForDistribution`**, which on a thin or dying token is routine. The larger the pile that
accumulated, the larger the prize.

Ordering note: the hook distributes a swap's fee *before* the buyer's tokens are delivered
(`src/Distributor.sol:182-188`), so the attacker's own buy does not flush their own capture — they
need any subsequent trade, which is one more transaction or one more block.

This is not the same thing as `test_carriedPayoutsAreReleasedToTheFirstRealHolders`
(`test/LaunchToken.t.sol:301`), which asserts the carry is *released*. It is; the question is to
whom.

---

### D-04 — The push queue only ever grows: `_dequeue` is unreachable at `minShareForQueue == 0` and never fires for a dust balance

- **SEVERITY: LOW**
- **Location:** `src/Distributor.sol:237-241`. At `minShareForQueue == 0` the guard
  `newShares >= minShareForQueue` is `0 >= 0`, so the `else if (newShares == 0)` dequeue branch at
  `:239` is dead code. `src/Launcher.sol:466-513` validates supply, max wallet, opening market cap,
  graduation threshold, dev buy and vest — and does not look at `minShareForQueue` or
  `minPushPayout` at all, passing both straight through at `:427-428`.
- **REPRODUCED** — `test_D03_zeroMinShareForQueueMakesDequeueUnreachable`,
  `test_D03b_dustHoldersAreNeverDequeuedEvenWithAPositiveThreshold`

With `minShareForQueue == 0`, selling out enqueues you: 41 accounts cycled in and out leave 41
permanent queue entries against a `totalShares` of zero. With any positive threshold the dequeue is
still wired to *exactly* zero, so a holder who leaves one wei behind is a permanent entry — 40
addresses holding 40 wei between them occupy 40 slots, and a real holder arriving afterwards gets
nothing from a full 40-wide batch.

**What an attacker gains.** Nothing takeable. The pull path is unaffected and is asserted to still
work in the same test, which is why this is LOW rather than MEDIUM. What it buys is push starvation
and wasted gas for whoever calls `processBatch`, at a cost of one transfer per address, with **no
position retained afterwards** — the griefer keeps one wei. Practical impact is further limited by
D-08 (nothing in the system calls `processBatch`).

---

### D-05 — `minPushPayout == 0` makes every batch a run of zero-value payouts

- **SEVERITY: LOW**
- **Location:** `src/Distributor.sol:307` (`amount >= minPushPayout`), reachable because
  `src/Launcher.sol` never validates `minPushPayout` (`:427`)
- **REPRODUCED** — `test_D04_zeroMinPushPayoutPaysHoldersWhoAreOwedNothing`,
  `test_D04b_zeroMinPushPayoutCallsTheConverterWithZero`

The dust guard is `>=`, so at zero it matches holders owed exactly zero. `processBatch(10)` over two
holders with no distribution at all returns `sentCount == 2, sentTotal == 0`, emits `PayoutSent`
twice, and performs two token transfers. With a converter configured it also makes one external
`convert(..., 0, ...)` call per holder and counts the result as a successful payout.

**What an attacker gains.** Nothing. The cost is misleading events (`PayoutSent` for a payment of
zero, and a non-zero `sentCount` return that a caller may reasonably read as "work was done") and
gas burned proportional to queue length. Reported because `sentCount` is the value a bounty or
keeper would key off.

---

### D-06 — An arithmetic panic in `accumulativeOf` takes the whole batch down, not one entry

- **SEVERITY: LOW**
- **Location:** `src/Distributor.sol:305` — `withdrawableOf(account)` is read *before* `_trySend`,
  so it sits outside the skip-a-bad-recipient protection described at `:21-23`. The underlying
  asymmetry is `:229`/`:233` (which bound `_magnifiedPayoutPerShare * DELTA`) versus `:249`
  (which multiplies `_magnifiedPayoutPerShare * BALANCE`).
- **REPRODUCED** — `test_D06c_aHolderWhoseAccumulatorPanicsBricksTheQueueForEveryoneElse`

`_setShares` checks the product of the accumulator and the *delta*. `accumulativeOf` computes the
product of the accumulator and the *balance*. A balance assembled from several deltas that each
passed the checked multiply can therefore exceed what any single delta could:

```
two ordinary setBalance calls, each product ~0.9 * 2**256  -> both pass
resulting BALANCE product ~1.8 * 2**256                    -> accumulativeOf panics
  withdrawableOf(alice)  reverts (panic 0x11)
  alice's withdraw()     reverts
  processBatch(10)       reverts - for carol too, who did nothing
```

This falsifies two stated invariants: *"One hostile or blocklisted receiver must never brick the
queue for everyone else"* (`:317-318`, and the header at `:21-23`) and *"Pull. Always available,
never gated on anyone else paying gas"* (`:276`). Both are true only for failures that happen
*inside* `_trySend`; an arithmetic failure happens before it.

**What an attacker gains.** Denial of service on both payout paths for every holder in the queue.
Rated LOW because reaching it needs a `minSharesForDistribution` far weaker than `supply / 1e6` —
see D-07 for the boundary under the real guard, which is unreachable. It is reachable for any
`Distributor` deployed directly rather than through `Launcher`, which is the same caveat
`DistributorInvariant.t.sol:154-156` already writes down for the transfer-bricking case.

---

### D-07 — `minSharesForDistribution` works, and the boundary is `~3.40e32` pair-wei of cumulative distribution, independent of supply

- **SEVERITY: INFORMATIONAL** (the guard holds; this locates where it stops)
- **Location:** `src/Distributor.sol:196` (the guard), `:202` (the accumulator),
  `:229`/`:233` (the checked multiply it protects), `src/LaunchToken.sol:137` (`supply / 1e6`)
- **REPRODUCED** — `test_D06_theGuardHoldsAndItsBoundaryIsSupplyIndependent`,
  `test_D06b_theBoundaryIsJustAbove3point40e32PairWei`

The guard does prevent the overflow it claims to. The worst legal squeeze it permits is a holder
base sitting at *exactly* the floor taking a distribution, followed by a holder arriving with the
rest of the supply. That product is

```
(total * 2**128 / (supply/1e6)) * (supply - supply/1e6)  ==  total * 2**128 * (1e6 - 1)
```

which **does not contain `supply`**. The guard is a ratio, so the binding quantity is the cumulative
amount of *pair currency* ever distributed, and the boundary is a constant:
`2**128 / (1e6 - 1)` ≈ **3.4028e32 wei**. Probed from both sides:

| cumulative distributed | supply `1e18` | supply `1e27` | supply `1e33` |
|---|---|---|---|
| `3.00e32` | sound | sound | sound |
| `3.40e32` | — | sound | — |
| `3.41e32` | — | **panic** | — |
| `3.60e32` | **panic** | **panic** | **panic** |

Below the boundary the accounting is not merely non-reverting but *correct*: the squeezed holder is
owed the whole distribution to within `1e-5` relative, and the late arrival is owed exactly zero.
That is asserted, not assumed.

Two things worth writing down:

- **This is a currency-side limit, not a token-side one.** `Launcher` bounds `supply >= 1e18`
  (`src/Launcher.sol:476`), which is what keeps `supply / 1e6` from collapsing to zero — but supply
  is otherwise irrelevant to the boundary. What must be checked per pair is whether ~`3.4e32` wei is
  a plausible *cumulative fee* volume for that currency's decimals and supply. At 18 decimals that
  is ~340 trillion whole tokens of fees; at 6 decimals (USDC) it is unreachable by many orders of
  magnitude. It is worth confirming for the highest-supply 18-decimal currencies on the allowlist
  rather than assuming.
- **The `int256` conversions at `:229`, `:233` and `:249` are unchecked**, so between `2**255` and
  `2**256` the products silently wrap. I tried to build a corruption out of that window and could
  not: both the correction and the accumulator wrap by the same `2**256` and cancel, so the results
  stay correct, and any sequence that puts two wrapped products into one `_corrections` entry needs
  `mps * supply >= 2**256` anyway — i.e. it is already past the hard boundary. Documented as a
  near-miss, not a finding.

---

### D-08 — `processBatch` is documented as hook-driven and nothing in the system calls it

- **SEVERITY: INFORMATIONAL**
- **Location:** the docstring at `src/Distributor.sol:13-16` (*"Anyone may call it; the hook calls
  it opportunistically after a swap"*) versus `src/FeeHook.sol:909`, which is the only call from the
  hook into the distributor and calls `distribute`, not `processBatch`.
- **REASONED, with the consequence pinned** — `test_D03c_nothingInTheSystemEverCallsProcessBatch`

`grep -rn processBatch src/` returns only `Distributor.sol`'s own definition and docstring. The push
path is entirely volunteer-funded: a queued holder owed money stays owed until somebody pays gas to
walk the cursor. Not broken — `withdraw()` is the real path and it works — but the header describes
an automatic behaviour that does not exist, which is the same class of drift as F-06 in audit 01.

---

## Checked and found sound

Each has a passing test in `test/audit/DividendAudit.t.sol`. Do not re-audit these.

**Exclusion is airtight against `setBalance`.** An excluded account was fed every shape it can
receive — `0`, `supply`, `1`, `type(uint128).max` — and acquired no shares, entered no denominator
and entered no queue (`test_sound_excludedAccountsNeverAccrueAndCannotBeReAdded`). Excluding a
*live* holder removes their shares from `totalShares` exactly, freezes (does not confiscate) their
already-earned claim, and stops further accrual
(`test_sound_excludingAHolderFreezesTheirClaimAndRemovesTheirShares`). Un-excluding grants nothing
retroactive: shares stay zero until the next balance update, and that update re-enters the account
at the *current* accumulator, so they are owed zero for everything that happened while they were out
(`test_sound_unExcludingGrantsNoRetroactiveEntitlement`). The gap is who can *call* `setExcluded`
(D-02), not what it does.

**A transfer mid-distribution neither creates nor destroys entitlement.** Selling the whole position
after a distribution keeps the claim; buying it does not buy the seller's accrued claim; the two
together never exceed what was distributed
(`test_sound_aMidDistributionTransferNeitherCreatesNorDestroysEntitlement`). The `_corrections` sign
handling at `:229` and `:233` is correct in both directions.

**A claim cannot be taken twice, by either path or both.** Pull-then-pull reverts; pull-then-push
pays nothing; and interleaving `processBatch` / `withdraw` / `withdraw` / `processBatch` over two
holders never exceeds what arrived (`test_sound_aClaimCannotBeTakenTwice`,
`test_sound_pushAndPullCannotBothPayTheSameClaim`).

**The cursor does not skip and does not double-pay.** Five holders walked two at a time for more
than a full lap pays exactly five, each exactly once
(`test_sound_cursorWrapsWithoutSkippingOrDoublePaying`). The swap-and-pop in `_dequeue` can move an
entry behind the cursor, which *delays* that holder by up to one lap — pinned as deliberate, and
asserted to be a delay and not a stranding (`test_sound_swapAndPopDelaysButNeverStrandsAMovedHolder`).

**The carry is never double-counted or lost.** Six consecutive carries then a flush yields
`pendingPayouts == 0`, `totalDistributed == 700e18` exactly, an owed figure that never exceeds what
arrived, and a solvent contract (`test_sound_theCarryIsNeverDoubleCounted`). Who gets it is D-03;
that the arithmetic conserves is sound.

**The allowance bound holds and no allowance ever survives.** A converter reaching for `2 * amount`
reverts inside `transferFrom`, lands in the `catch`, receives nothing, and the holder is paid the
fallback with the contract left solvent (`test_sound_aConverterCannotTakeMoreThanItWasApprovedFor`).
The allowance is zero after all five converter outcomes — honest, thieving, partial, reverting,
greedy (`test_sound_noAllowanceSurvivesAnyConverterOutcome`). D-01 is not an allowance-bound failure;
it is a failure to notice the bound was consumed.

**A converter that reenters cannot double-pay.** `convert` reentering `withdraw()` and reentering
`processBatch(10)` were both exercised: state is written before the external call in both paths, so
the reentrant read sees a settled claim. Nobody receives more than they are owed in either currency,
`totalWithdrawn <= totalDistributed` holds, and the contract stays solvent
(`test_sound_aReentrantConverterCannotDoublePay`). Worth noting for anyone writing a converter: a
nested `_trySend` clears the outer call's allowance on its way out, so a converter that reenters
*before* spending its allowance will always end up in the `catch` and fall back to the pair currency.
That degrades correctly.

**`LaunchToken._update` edge shapes.** A self-transfer of 400e18 moves no balance, no shares, no
denominator, no entitlement and no queue entry (`test_sound_selfTransferChangesNothing`) — the
`newShares == old` early return at `:224` covers both `setBalance` calls. A zero-value transfer, to a
third party or to self, queues nobody and changes nothing, including from an account with no balance
(`test_sound_zeroValueTransferChangesNothingAndQueuesNobody`). Buys from the pool, sells to the pool
and transfers to `0xdEaD` all leave `totalShares` exactly equal to the sum of real holders'
balances, with the excluded counterparty at zero shares
(`test_sound_transfersToAndFromExcludedAccountsKeepTheDenominatorHonest`).

**Solvency under churn with exclusion in the mix.** 1,000 fuzz runs over six actors with one
randomly excluded, three distributions, and every balance halved and restored around a
`processBatch` on each round: the contract never owes more than it holds, `totalShares` never drifts
from the sum of shares, the excluded actor never holds shares, and payouts never exceed
distributions (`testFuzz_sound_neverOwesMoreThanItHolds`). This is the existing
`DistributorInvariant` property extended with the two actions that handler does not perform —
`setExcluded` and a realistic launcher-shaped `minSharesForDistribution` with a queue threshold.

---

## Answers to the four questions asked

- **Can the contract ever owe more than it holds?** Yes — D-01, and only D-01. Every other path
  tested truncates in the contract's favour, and the fuzz confirms it across 1,000 randomised
  sequences.
- **Can anyone extract more than they are owed?** Yes, twice over. D-01 extracts a second full copy
  of a claim through the converter. D-03 extracts fees earned entirely before the extractor held a
  single token. No rounding direction anywhere favours the caller.
- **Can a holder be permanently unable to claim?** Yes — three distinct ways. D-01 leaves the
  contract without the money. D-02 leaves the claim with an address that has no code path to pull
  it. D-06 makes the holder's own accumulator unreadable, which kills the pull path too.
- **Does `minSharesForDistribution` prevent the overflow it claims to?** Yes. Boundary located and
  asserted from both sides at three supplies: `~3.40e32` wei of *cumulative distributed pair
  currency*, independent of the launch token's supply (D-07).
