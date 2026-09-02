# Audit 03 — Access control and privileged paths, across all of `src/`

**Scope:** every `external` and `public` function in `src/` — `FeeHook`, `Launcher`,
`PairRegistry`, `ReferralVault`, `VestingVault`, `Distributor`, `LaunchToken`, `HookBase` — asked
two questions: **who may call it**, and **what happens if the wrong person does**. Constructor
wiring, immutables that are not really immutable, one-shot initializers, missing zero-address
checks that matter, and functions that are `external` when they should be `internal`.
`script/DeployTestnet.s.sol` was read because it is the only place the real wiring order exists.
**Nothing under `src/` was modified.**

**Evidence:** `test/audit/AccessAudit.t.sol` — 25 tests across 3 harnesses, all passing. Every
finding marked REPRODUCED has a named test in that file. Full suite after this work:
`forge test --no-match-contract Fork` → **494 passed, 0 failed** (469 before).

**Result: 1 high, 5 medium, 3 low, 3 informational.**

**Something here is exploitable.** The high finding is a permanent, zero-cost, permissionless
destruction of a creator's dividend stream, and it fires on the *normal* path — no attacker
required, an honest keeper bot does it. Two of the mediums let a launcher's own two wallets take
40% of the platform's referral cut and let an unrelated launch parameter silently zero out a
referrer's entire claim.

Not exploitable, and checked hard: nobody can call `configurePool*`, `configureGraduation`,
`autoRedeem`, either `unlockCallback`, `distribute`, `setBalance` or `setExcluded` who is not
supposed to; the `LaunchToken` implementation is sealed and no clone can be re-initialised;
`PairRegistry` ownership cannot be *stolen*; and neither `Launcher` initializer can be
front-run, re-run, or squatted.

---

## The table — every external/public function in `src/`

Sorted by contract. "Guard" is the literal mechanism in the code.

### `src/FeeHook.sol`

| Function | Who may call | Guard | Verdict |
|---|---|---|---|
| `getHookPermissions()` | anyone | none (pure) | Sound. Constant. |
| `configurePool(key,…)` | Launcher only | delegates to `configurePoolFull` (internal call, `msg.sender` preserved) | Sound. Covered by `HookAttack.t.sol`. |
| `configurePoolFull(key,s)` `:326` | Launcher only | `msg.sender != launcher` → `OnlyLauncher`; `AlreadyConfigured` makes it once-per-pool | Sound. `launcher` is immutable. See I-3 for a missing internal consistency check. |
| `configureGraduation(key,…)` `:406` | Launcher only | `OnlyLauncher` + `GraduationAlreadyConfigured` | Sound. |
| `checkGraduation(id)` `:456` | **anyone** | none — permissionless by design | Sound. One-way latch, needs `mcap >= threshold`, gates nothing of value. Reverts `GraduationNotConfigured` on unknown ids. |
| `marketCapOf` / `graduationProgressBps` / `hasGraduated` | anyone | view | Sound. |
| `autoRedeem(id,key,cfg)` `:680` | **the hook itself only** | `msg.sender != address(this)` → `NotPoolManager` | Sound. Covered by `HookAttack.t.sol`. `external` is correct here — the `try/catch` in `_tryAutoSweep` needs a real revert boundary. |
| `sweep(key)` `:745` | **anyone** | `NotConfigured` on unknown pools; all amounts and recipients come from storage | Sound. Caller earns `SWEEP_BOUNTY_BPS` and nothing else. REPRODUCED as sound. |
| `unlockCallback(bytes)` `:772` | **PoolManager only** | `msg.sender != address(poolManager)` → `NotPoolManager` | Sound, and this is the one that mattered. See the note below the table. |
| `beforeInitialize` / `beforeSwap` / `afterSwap` (via `HookBase`) | PoolManager only | `onlyPoolManager` | Sound. Every unimplemented callback reverts `HookNotImplemented`. |
| `poolConfig` / `totalFeesTaken` / `pendingFees` / `pendingTokenFees` / `totalBurned` / `autoSweepThreshold` / `graduation` / `launcher` / `platformRecipient` / constants | anyone | auto-getters | Sound. |

**On `unlockCallback` being "a withdrawal function for every fee in the system".** It is not, and
the reason is worth stating precisely rather than assuming. `PoolManager.unlock(data)` calls
`IUnlockCallback(msg.sender).unlockCallback(data)` — it calls back **the address that called
`unlock`**, never an arbitrary one. So the only way to reach `FeeHook.unlockCallback` past the
guard is for the FeeHook itself to call `poolManager.unlock`, and the only place it does that is
`sweep`, where the payload is `abi.encode(key, pendingFees[id], pendingTokenFees[id], msg.sender)`.
An attacker therefore controls exactly two fields: which **configured** pool is swept, and who
receives the bounty (themselves). Both amounts are read from storage inside `sweep`, and
`unlockCallback` re-reads `cfg` from `poolConfig[key.toId()]` rather than trusting the payload. The
attacker-supplied `bytes` are structurally inert. Verified by exhaustion of the call graph, and the
caller guard itself is already covered by `HookAttack.t.sol`.

### `src/Launcher.sol`

| Function | Who may call | Guard | Verdict |
|---|---|---|---|
| `initReferralVault(vault)` `:295` | deployer only, once | `msg.sender != _deployer` → `OnlyDeployer`; `referralVault != 0` → revert; zero rejected | Sound. REPRODUCED: cannot be called twice, cannot be squatted, cannot be front-run (guard is on the caller, not on emptiness). |
| `initRewardConverter(conv)` `:306` | deployer only, once | same shape | Sound as access control. **F-01 (MEDIUM)** is about the *state before* it is called. Wrong error name — see I-1. |
| `launch(params)` `:321` | **anyone** | `nonReentrant`; `_validate`; `PairRegistry` allowlist | Sound as access control. **F-04 (LOW)** — the caller-supplied `salt` is front-runnable. |
| `unlockCallback(bytes)` `:570` | **PoolManager only** | `msg.sender != address(poolManager)` → `OnlyPoolManager` | Sound. REPRODUCED — this was **not** covered anywhere (`HookAttack.t.sol` only attacks the hook's). It decodes caller-shaped `SeedData` and then `take`s and `safeTransfer`s, so it is the launcher's withdrawal-shaped surface. |
| `launchCount` / `isOurs` / `predictTokenAddress` / `launches` / `launchIndexPlusOne` / `vaultOf` / immutable getters | anyone | view | Sound. `predictTokenAddress` is what makes F-04 cheap to aim. |

There is **no** admin, owner, pause, upgrade or liquidity-removal function on `Launcher`. The
liquidity lock claim ("locked by having no way out") holds at the ABI level: no selector passes a
negative `liquidityDelta`.

### `src/PairRegistry.sol`

| Function | Who may call | Guard | Verdict |
|---|---|---|---|
| `approvePair(pair,feed,staleness,decimals)` `:103` | owner | `onlyOwner` | Guard sound. **F-06 (LOW)** — `tokenDecimals` is taken on trust; **I-2** — silently overwrites an existing entry. |
| `approvePairWithoutOracle(pair,decimals)` `:138` | owner | `onlyOwner` | Same. |
| `revokePair(pair)` `:151` | owner | `onlyOwner` | Sound. Stops new launches only; existing pools are untouchable, as documented. |
| `setSequencerFeed(feed,grace)` `:163` | owner | `onlyOwner` | Sound. No bounds on `gracePeriod`, but it is inert on L1 (`feed == 0` short-circuits). |
| `transferOwnership` / `acceptOwnership` (Ownable2Step) | owner / pending owner | two-step handshake | Sound. REPRODUCED: **ownership cannot be stolen.** |
| `renounceOwnership()` (inherited, not overridden) | owner | `onlyOwner`, **single step** | **F-05 (LOW)** — REPRODUCED. Ownership *can* be lost, in one unconfirmed call. |
| `isApproved` / `isPriceable` / `pairConfig` / `pairCount` / `pairAt` / `priceUsd` / constants | anyone | view | Sound. `priceUsd` reverts rather than fabricating. |

**Can a non-owner allowlist a currency? No.** All three mutators are `onlyOwner` and that is
already covered by `PairRegistry.t.sol:311-329`.

### `src/ReferralVault.sol`

| Function | Who may call | Guard | Verdict |
|---|---|---|---|
| `setReferrer(user,referrer)` `:113` | Launcher only | `msg.sender != launcher` → `OnlyLauncher`; write-once; `SelfReferral` | **F-02 (MEDIUM)** — write-once is enforced, "referrer must already exist" is **not**, so A→B→A is legal and pays a creator's own two wallets the whole schedule. |
| `credit(currency,amount,creator)` `:134` | FeeHook only | `msg.sender != feeHook` → `OnlyFeeHook` | Guard sound, REPRODUCED live. But the key it looks up is `cfg.creator`, not the launching wallet — **F-03 (MEDIUM)**. And as deployed the function is **unreachable** — **F-07 (MEDIUM)**. |
| `claim(currency)` `:167` | anyone, for their own balance | keyed on `msg.sender`; zeroed before transfer; restored on failure | Sound. No way to claim someone else's. |
| `tiers()` / `referrerOf` / `owed` / `earned` / immutables | anyone | view | Sound. |

**Can the tier schedule be changed after deploy? No.** `_tierBps` is written only in the
constructor, `tierCount` is `immutable`, `MAX_TIERS` is a `constant`, and there is no setter. The
constructor caps `sum(schedule) <= BPS`. Verified by ABI exhaustion; `Referral.t.sol:219-233`
already covers the constructor bounds.

### `src/VestingVault.sol`

| Function | Who may call | Guard | Verdict |
|---|---|---|---|
| `addSchedule(amount,start,cliff,duration)` `:106` | **anyone** | `MIN_DURATION`, `cliff <= duration`, `MAX_SCHEDULES`, clamp to unscheduled balance | **F-08 (MEDIUM)** — permissionless *and* `start` is unbounded. Two abuses, both REPRODUCED. **I-4** — silently trims. |
| `extend(index,cliff,duration)` `:125` | beneficiary | `onlyBeneficiary` + `CannotShorten` | Sound. See the invariant analysis below. |
| `release()` `:143` | **anyone** | recipient is always `beneficiary` | Sound. |
| `claimDividends()` `:190` | beneficiary | `onlyBeneficiary` | **F-09 (HIGH)** — the guard is fine; the *mechanism* means a permissionless push permanently strands the money. |
| `renounceAccrual()` `:207` | beneficiary | `onlyBeneficiary`, one-way | Sound as access control. (Its *semantics* are already a finding in `audit/02-dividends.md` — not re-reported.) |
| `transferBeneficiary(to)` `:217` | beneficiary | `onlyBeneficiary`, zero rejected | **F-10 (LOW)** — single-step; a typo permanently loses the vest, the dividends, and `extend`. |
| `releasable` / `schedules` / `scheduleCount` / `scheduleAt` / `locked` / immutables | anyone | view | Sound. |

**Do "extend-never-shorten" and "add-never-subtract" hold under every ordering?**

*Extend-never-shorten: **holds**.* `extend` requires `newCliff >= s.cliff` and
`newDuration >= s.duration`, and `start` is not a parameter of it, so `_vestedAt` is monotonically
**non-increasing** under every legal call:
- before the cliff → `0` either way, and a larger cliff keeps it `0` longer;
- inside the ramp → `total * (t - start) / duration`, strictly non-increasing in `duration`;
- past the end → a larger `duration` moves `t` back into the ramp, which is `< total`.
`release` guards with `if (vested > s.released)`, so an extension that lowers the vested figure
below what has already been paid cannot underflow — it simply pays nothing until the curve catches
up. There is no ordering of `extend`/`release`/`addSchedule` that shortens a schedule.

*Add-never-subtract: **holds for the schedules, and that is not the whole promise**.* Nothing can
remove a schedule or lower a `total`. `unscheduled = balance - _totalUnreleased()` cannot underflow
because the vault's token balance falls only via `release`, which decrements
`_totalUnreleased` by exactly the same amount. **But "add" is a permissionless verb** (F-08): the
guarantee that nothing can be *subtracted* is bought at the price of anyone being able to *add* a
schedule over anyone else's top-up, with an arbitrary far-future `start`, irreversibly.

### `src/Distributor.sol`

| Function | Who may call | Guard | Verdict |
|---|---|---|---|
| `distribute(amount)` `:189` | FeeHook only | `onlyController` (immutable) | Sound. Covered by `Adversarial.t.sol:211`. Amount is unverified but the only caller transfers first. |
| `setBalance(account,bal)` `:208` | the launch token only | `onlyShareToken` (immutable) | Sound. Covered by `Adversarial.t.sol:221`. |
| `setExcluded(account,flag)` `:216` | FeeHook only | `onlyController` | Guard sound, function **dead** — `FeeHook` contains no call to it (grep: zero hits). Already reported in `audit/02-dividends.md`; cross-referenced only. |
| `withdraw()` `:277` | anyone, for themselves | keyed on `msg.sender`, rolls back on send failure | Sound. |
| `processBatch(n)` `:296` | **anyone** | permissionless by design, gas-bounded, failures skipped | Sound *for EOAs and normal holders*. It is the trigger half of **F-09**. |
| `accumulativeOf` / `withdrawableOf` / `withdrawnOf` / `queueLength` / `queueAt` / `shareOf` / `excluded` / totals / immutables | anyone | view | Sound. |

### `src/LaunchToken.sol`

| Function | Who may call | Guard | Verdict |
|---|---|---|---|
| `initialize(params)` `:111` | **anyone, once** | `_initialized` flag; the **implementation sets it in its constructor** | Sound. REPRODUCED from an attacker address: the implementation cannot be initialised, and a live clone cannot be re-initialised — not by an attacker, not by the launcher. |
| `name()` / `symbol()` | anyone | view | Sound. |
| ERC-20 surface (`transfer`, `approve`, …) | anyone | standard | Sound. No fee, no owner, no mint, no burn, no blacklist. |
| `distributor` / `poolManager` / `maxWallet` / `metadata` / `exemptFromMaxWallet` | anyone | auto-getters | Sound. |

The permissionless-initializer reasoning in the docstring (`:104-110`) is correct in this
deployment: `Launcher.launch` clones and initialises in one transaction, so there is no window,
and a clone at a salt the launcher did not use is worthless. The *related* risk is F-04, which is
about the salt colliding rather than the initializer being open.

### `src/base/HookBase.sol`

| Function | Who may call | Guard | Verdict |
|---|---|---|---|
| all ten `IHooks` callbacks | PoolManager only | `onlyPoolManager` | Sound. |
| `getHookPermissions()` | anyone | pure virtual | Sound. Enforced against the deployed address in the constructor via `Hooks.validateHookPermissions`. |

---

## Findings

### F-09 — Every dividend PUSHED to a `VestingVault` is permanently unrecoverable

- **SEVERITY: HIGH**
- **Location:** `src/VestingVault.sol:190-201` (`claimDividends`) against
  `src/Distributor.sol:296-329` (`processBatch`), specifically the
  `before = balanceOf(this)` / `d.withdraw()` / `amount = balanceOf(this) - before` sequence at
  `VestingVault.sol:196-198`
- **REPRODUCED** — `test_finding_pushedDividendsAreStrandedInAVestingVaultForever` and
  `test_finding_anHonestKeeperCausesTheSameLoss`

A vested dev buy makes the `VestingVault` an ordinary holder of the launch token, so it accrues
dividends and — because its balance is large — it is **enqueued** in the Distributor's push queue.
`processBatch` is permissionless, gas-bounded and explicitly advertised as the path a bot should
take. When it reaches the vault it does a raw ERC-20 `transfer` of the vault's entire withdrawable
balance into the vault. That transfer succeeds.

The vault's only exit for the payout currency is `claimDividends`, and it measures what to forward
as the **delta around `Distributor.withdraw()`**:

```solidity
uint256 before = IERC20(payout).balanceOf(address(this));
d.withdraw();                                   // reverts NothingToWithdraw after a push
amount = IERC20(payout).balanceOf(address(this)) - before;
```

So:

1. push → the vault holds `X` payout tokens and `withdrawableOf(vault) == 0`;
2. `claimDividends()` → `d.withdraw()` reverts `NothingToWithdraw`, the whole call reverts;
3. more trading → a later `claimDividends()` succeeds, but `before` already includes `X`, so it
   forwards only the **new** amount. `X` is skipped, permanently.

`VestingVault` has no rescue function, no owner, no `sweep`, and no other transfer of
`payoutToken` anywhere in its ABI. `X` is gone. The test asserts the vault's payout balance is
still exactly `X` after two subsequent successful claims.

**What an attacker gains:** nothing directly — this is *destruction*, not theft, which is why it
is graded HIGH on permanence and cost rather than on profit. One `processBatch(n)` call, from any
address, at the cost of gas, permanently deletes a creator's accrued dividends. It can be repeated
after every distribution, so a griefer can zero the creator's dividend income for the entire life
of the token for the price of one cheap call per cycle. Since a vested dev buy is deliberately
**uncapped** (`Launcher._validate:503-510`), the vault is frequently the largest non-excluded
holder in the book, so the sum at risk is the largest single holder's share of every distribution.

**It is not only an attack.** The second test uses `stranger` as a bounty bot, not an attacker,
and shows the vault sitting in `_queue` on a completely ordinary launch. The Distributor's own
docstring (`:14-17`) tells keepers to call this. The first honest keeper destroys the stream.

**Note on the existing invariant.** `totalWithdrawn <= totalDistributed` still holds throughout —
the accounting is correct, the *recipient* just cannot use what it received. The Distributor's
invariant suite is blind to this by construction.

**Relationship to `audit/02-dividends.md`.** That audit observed, as a consequence of
`renounceAccrual`'s broken semantics, that "`processBatch` then pushes real pair currency into a
vault whose only exit now reverts". This is the **general** case and it is strictly worse: it needs
no `renounceAccrual`, it fires on a completely default vested launch, and the loss survives every
subsequent successful `claimDividends` rather than being contingent on a permanently-reverting
exit. The two share a fix.

**Fix direction (not applied):** give `VestingVault` a permissionless
`forwardDividends()` that transfers `IERC20(payout).balanceOf(address(this))` to the beneficiary
without going through `withdraw()`, and make `claimDividends` tolerate a reverting `withdraw()`
(try/catch) instead of propagating it. Alternatively exclude vaults in the Distributor — but
`setExcluded` is `onlyController` and the controller never calls it, which is the finding in
`audit/02-dividends.md`.

---

### F-08 — `VestingVault.addSchedule` is permissionless *and* takes an unbounded caller-chosen `start`

- **SEVERITY: MEDIUM**
- **Location:** `src/VestingVault.sol:106-122`
- **REPRODUCED** — `test_finding_anyoneCanPermanentlyLockATopUpInSomeoneElsesVault` and
  `test_finding_anyoneCanFillMaxSchedulesAndBlockAllFutureLocks`

The docstring justifies the missing guard with "the launcher calls it during the launch
transaction, before a beneficiary could possibly front-run anything". That is true of the launch
and of nothing else. The contract also advertises top-ups ("**Add, never subtract.** More tokens
can be locked under new schedules"), and every top-up after the launch is a two-step sequence —
transfer, then schedule — with an open, front-runnable window between the steps.

**Abuse 1 — permanent lock.** Anyone may call `addSchedule` over whatever is unscheduled, with any
`start`. `start` is not bounded, not compared to `block.timestamp`, and cannot be changed
afterwards: `extend` takes only `cliff` and `duration` and refuses to shorten either. The test
front-runs a 1,000-token top-up with `start = now + 100 years`, warps **fifty years** forward,
releases everything releasable, and the top-up is still sitting in the vault untouched. The
beneficiary's attempt to undo it reverts `CannotShorten`.

**Abuse 2 — schedule-slot exhaustion.** `MAX_SCHEDULES = 32` and schedules can never be removed.
The test donates **1 wei** of the launch token to the vault and calls `addSchedule(1, …)`, 31
times, filling the array. The beneficiary's own legitimate 500-token top-up then reverts
`TooManySchedules`, forever. Cost: 31 wei plus gas.

**What an attacker gains:** griefing. No value moves to them; the target's tokens become
unreleasable or unlockable. Cheap, permanent, and aimed at a public address (`Launcher.vaultOf`).

**Fix direction:** gate `addSchedule` to `launcher || beneficiary`, and reject
`start > block.timestamp + someBound`.

---

### F-02 — A creator can credit *themselves* the whole referral schedule with two wallets

- **SEVERITY: MEDIUM**
- **Location:** `src/ReferralVault.sol:113-121` (`setReferrer`), against the claim at
  `src/ReferralVault.sol:130-133`
- **REPRODUCED** — `test_finding_aTwoWalletCycleLetsACreatorCreditThemselvesTheWholeSchedule`

`credit` states: *"**Cycles are impossible** because `referrerOf` is write-once and a referrer must
already exist when they refer someone."* `setReferrer` enforces the write-once half. It does **not**
enforce the second half — there is no check that `referrerOf[referrer] != 0`, and no check of any
kind that the referrer is already in the graph. So:

```
tx1: creator A launches, referrer = B   →  referrerOf[A] = B     (B is a fresh address)
tx2: creator B launches, referrer = A   →  referrerOf[B] = A     (legal: B had no referrer)
```

A cycle. The tier walk in `credit` then alternates:

| tier | walker | bps |
|---|---|---|
| 0 | B | 2000 |
| 1 | A | 1000 |
| 2 | B | 500 |
| 3 | A | 300 |
| 4 | B | 200 |

The test asserts that on a real launch, with real trading and a real sweep, **4000 bps of the
platform's cut — the entire schedule — lands on the launcher's own two wallets**, and then claims
it out to prove it is spendable rather than an accounting artefact. The treasury gets 6000 bps
instead of 10000.

**What an attacker gains:** 40% of the platform's revenue on their own launches, for the cost of
one extra wallet and one extra (otherwise ordinary) launch. Compare the honest single-sybil case,
which yields 20% — the cycle doubles it, and the loop is what makes the difference.

**Note.** `Referral.t.sol:202` (`test_aCycleCannotBeBuilt`) already builds this exact cycle. Its
comment says "A cycle cannot be created (write-once forbids it)" while the body creates one, and
it only asserts value conservation — which holds. The self-dealing is what was never asserted.

**Fix direction:** require `referrerOf[referrer] != address(0) || referrer == <root>` in
`setReferrer`, or skip an address already paid in the current walk.

---

### F-03 — Setting `feeRecipient` silently destroys the referrer's entire claim

- **SEVERITY: MEDIUM**
- **Location:** `src/Launcher.sol:448` (`creator: p.feeRecipient == address(0) ? msg.sender :
  p.feeRecipient`) against `src/Launcher.sol:462` (`setReferrer(msg.sender, p.referrer)`), resolved
  at `src/FeeHook.sol:893` (`credit(pairToken, toPlatform, cfg.creator)`)
- **REPRODUCED** — `test_finding_aFeeRecipientBreaksTheReferralChainSilently`

Two different keys are used for the same person:

- the referral is **recorded** under the launching wallet (`msg.sender`);
- the referral is **looked up** under `cfg.creator`, which is `feeRecipient` when the creator set
  one.

`feeRecipient` exists precisely so a creator can route revenue to "a team splitter, a multisig or a
cold wallet" (`Launcher.sol:161-166`). Any creator who does so unknowingly zeroes out whoever
referred them: `referrerOf[multisig]` is empty, the walk terminates immediately, and 100% of the
platform cut goes to the treasury.

The test runs the control (no `feeRecipient` → referrer earns) and the case (same referrer, fees to
a multisig → referrer's balance does not move by one wei, treasury's does) side by side in one
world.

**What an attacker gains:** the platform treasury quietly keeps money it owes an affiliate. There
is no revert, no event and no view that shows the mismatch, so the referrer's only symptom is a
number that never grows. It is equally a *self-inflicted* footgun for the platform: it produces a
class of unpaid affiliates and no way to see why.

**Fix direction:** pass the launching wallet through the config as a separate `referralKey`, or key
`setReferrer` on the fee recipient so both sides agree.

---

### F-01 — A reward currency chosen before `initRewardConverter` is silently dropped, forever

- **SEVERITY: MEDIUM**
- **Location:** `src/Launcher.sol:423` (`converter: rewardConverter`), `src/Launcher.sol:470`
  (validation that does not check for a converter), `src/Distributor.sol:340`
  (`converter != address(0)` gate)
- **REPRODUCED** — `test_finding_rewardCurrencyIsSilentlyDroppedWhenTheConverterIsUnset` and
  `test_finding_theSameLaunchAfterWiringGetsAConverter`

This is the *state between deploy and initialisation*, and it is not benign.

`_cloneAndInit` reads `rewardConverter` at launch time and bakes it into the Distributor as an
**immutable**. `_validate` checks that a non-zero `rewardCurrency` is on the `PairRegistry`
allowlist — and never checks that any route to it exists. `Distributor._trySend` then requires
`converter != address(0)` before it will even *attempt* a conversion, so with the converter unset:

- the creator's chosen reward currency is accepted and stored (`dist.rewardToken()` is correct);
- `dist.converter()` is `address(0)`, immutably, for the life of the token;
- every holder is paid the pair currency instead;
- and **`RewardConversionFailed` is never emitted**, because it lives inside the branch the zero
  converter skips.

That last point is the finding. `Distributor.sol:331-338` explicitly argues that a wrong-currency
payout "must be visible on chain rather than inferred from a balance". In this state it is not
visible at all. The test records logs across a real `withdraw()` and asserts no
`RewardConversionFailed` topic appears.

The companion test wires a converter first and launches an otherwise identical token: it gets a
converter. **The only difference between a launch that honours its advertised reward currency and
one that silently ignores it forever is what minute it was submitted in**, and the launcher offers
the creator no way to see or require it.

**What an attacker gains:** nothing — this is a broken promise to creators and holders, not a
theft. Graded MEDIUM because it is permanent, invisible, and lands on the exact feature the
`rewardCurrency` parameter exists to sell.

**Fix direction:** `revert` in `_validate` when `p.rewardCurrency != address(0) &&
rewardConverter == address(0)`. Fails closed, matches the project's own "silent trimming is
banned" rule.

---

### F-07 — As deployed, the `ReferralVault` can never pay anyone

- **SEVERITY: MEDIUM** (deployment / wiring; contract code is fine)
- **Location:** `script/DeployTestnet.s.sol:107` (`platformRecipient = deployer`), `:119-121` (hook
  deployed with it), `:140-142` (vault deployed *afterwards* and wired to the launcher only),
  against `src/FeeHook.sol:181` (`address public immutable platformRecipient`)
- **REPRODUCED** — `test_finding_theDeployedReferralVaultCanNeverPayAnyone`

`ReferralVault.credit` is `onlyFeeHook`, and the only call site is
`FeeHook._routeFee:893`, which calls it on `platformRecipient`. `platformRecipient` is
**immutable**. The deploy script sets it to the deployer EOA, then deploys the vault, then calls
`launcher.initReferralVault(vault)`. The result is a system that *looks* wired — referrals are
recorded, `launcher.referralVault()` returns the vault, the post-deploy assertions all pass — and
in which `credit` is unreachable for the life of that hook.

The test reproduces exactly that wiring and shows: referral recorded ✓, real trading ✓, platform
paid ✓, vault balance `0`, `owed[referrer] == 0`, `owed[treasury] == 0`, and `claim` reverting
`NothingOwed`.

This is resolvable and the harness proves it: the hook's address is **mined**, so it is known
before the hook exists, and the launcher's CREATE address can be reserved. `ReferralAccessAuditTest`
deploys `ReferralVault(predictedLauncher, HOOK_ADDR, treasury, tiers)` *before* the hook and passes
the vault in as `platformRecipient`. The script simply does it in the wrong order.

This corroborates the known gap already recorded as "Referrals cannot pay anyone" — but the cause
is not only the missing platform wedge in `_routeFee`; the wedge exists and is paid, it is
delivered to the wrong address.

**Fix direction:** deploy the vault against the mined hook address and pass it as
`platformRecipient`, or make `platformRecipient` a one-shot initializer like `referralVault`.

---

### F-04 — A launch salt is public, and colliding it reverts the victim's launch

- **SEVERITY: LOW**
- **Location:** `src/Launcher.sol:414` (`Clones.cloneDeterministic(tokenImplementation, p.salt)`)
  and `src/Launcher.sol:718` (`predictTokenAddress`)
- **REPRODUCED** — `test_finding_aLaunchSaltCanBeFrontRunToRevertSomeoneElsesLaunch`

The clone address depends only on `(implementation, salt, launcher)` — not on the caller, not on
any launch parameter. `salt` is user-supplied and sits in plain sight in the mempool, and
`predictTokenAddress` is a public view that resolves it. An attacker who submits their own `launch`
with the same salt takes the address; the victim's transaction then dies at **step 1**, on
`Errors.FailedDeployment`, before any of the validation they could have adjusted.

The test asserts the exact revert selector so the failure is provably the clone collision and not
`AlreadyConfigured` or a parameter check.

**What an attacker gains:** griefing only, and they pay a full launch to do it. It is graded LOW
for that reason, but it is not free of consequence: salts here are **mined off chain to control
currency ordering** (`Launcher.sol:131`), so a specific-orientation salt is not a fungible
resource, and the victim must re-mine.

**Fix direction:** mix `msg.sender` into the salt — `keccak256(abi.encode(msg.sender, p.salt))`.
This costs nothing and makes the address unstealable while keeping off-chain mining possible.

---

### F-05 — `PairRegistry` ownership can be destroyed in one unconfirmed call

- **SEVERITY: LOW**
- **Location:** `src/PairRegistry.sol:35` — `Ownable2Step` is inherited and
  `renounceOwnership()` is **not** overridden
- **REPRODUCED** — `test_finding_registryOwnershipCanBeRenouncedInOneCallAndFreezesTheAllowlist`

`Ownable2Step` protects `transferOwnership` with a handshake — and leaves `renounceOwnership`
exactly as `Ownable` defines it: one call, no confirmation, `_transferOwnership(address(0))`. Since
the registry is the *only* gate on which currencies may be launched or paid against
(`Launcher._validate:467-472`), renouncing freezes the allowlist permanently: no pair can ever be
added, and — worse — **no pair can ever be revoked**, so a pair currency that later pauses, gets
blacklisted or gets exploited stays launchable forever.

The test renounces and then shows both `approvePairWithoutOracle` and `revokePair` reverting
`OwnableUnauthorizedAccount`.

**So: can ownership be lost or stolen?** Lost — yes, in one call. Stolen — no.
`test_sound_registryOwnershipCannotBeStolen` shows the pending-owner handshake refusing an
attacker's `acceptOwnership` and correctly demoting the old owner once the real transfer completes.

**Fix direction:** `function renounceOwnership() public pure override { revert(); }`.

---

### F-06 — `tokenDecimals` is taken on trust, contradicting the docstring that says it is not

- **SEVERITY: LOW**
- **Location:** `src/PairRegistry.sol:103` and `:119`, `src/PairRegistry.sol:138` and `:142`,
  against the claim at `src/PairRegistry.sol:101-102`
- **REPRODUCED** — `test_finding_tokenDecimalsIsTakenOnTrustDespiteTheDocstring`

The docstring states: *"`feedDecimals` and `tokenDecimals` are read from the contracts, never
passed in, so a typo cannot misprice a pair by 1e12 (the USDG-is-6-decimals footgun)."*

`feedDecimals` is read (`IAggregatorV3(feed).decimals()`). `tokenDecimals` is a **function
parameter**, stored verbatim, on both approve paths. The exact footgun the comment claims is
impossible is one call away, and the test performs it in both directions: an 18-decimal token
registered as 6, and a 6-decimal token registered as 18. `IERC20Metadata.decimals()` is never
consulted.

**What an attacker gains:** nothing — it is `onlyOwner`. It is reported because a stated safety
property does not hold, and because a comment asserting a guard exists is exactly what stops the
next reviewer from checking for it.

**Fix direction:** read `IERC20Metadata(pair).decimals()` and drop the parameter, or keep the
parameter and require it to match.

---

### F-10 — `transferBeneficiary` is single-step

- **SEVERITY: LOW**
- **Location:** `src/VestingVault.sol:217-221`
- **Reasoned** (not separately reproduced; the happy path is covered by `Vesting.t.sol:260`)

One call moves the seat, with only a zero-address check. A mistyped address permanently loses the
locked principal, the dividend stream (`claimDividends`), the ability to `extend`, and
`renounceAccrual` — with no recovery path anywhere in the contract. The rest of this codebase uses
a two-step handshake for exactly this reason (`PairRegistry` is `Ownable2Step`); the vault, which
guards more value than the registry does, does not.

Secondary: `release()` is permissionless and always pays the *current* beneficiary, so a transfer
can be front-run by a `release()` that pays the outgoing address. Minor, since the outgoing address
was chosen by the beneficiary, but worth knowing.

**Fix direction:** two-step accept, matching `Ownable2Step`.

---

## Informational

### I-1 — `initRewardConverter` reverts with `ReferralVaultAlreadySet`

`src/Launcher.sol:308-309`. Both guards on the *converter* initializer revert with the *vault's*
error. An integrator decoding the revert gets a wrong and actively misleading answer about which
slot is occupied. Cosmetic, but it is on the deployment path where the operator is least likely to
have a trace open. Add `RewardConverterAlreadySet` and `ZeroAddress`.

### I-2 — Re-approving a pair silently overwrites its whole config

`src/PairRegistry.sol:114-120` and `:141-143` assign the struct wholesale with no "already listed"
guard, and `_list` is idempotent so `pairCount` does not move. A second `approvePair` can change
the feed, the staleness bound and the decimals of a live pair, and `approvePairWithoutOracle` on an
already-priceable pair silently drops its oracle — the very downgrade `approvePairWithoutOracle`'s
docstring says must be explicit (it is explicit as a *function choice*, not as a *state
transition*). `PairApproved` is emitted identically for a first listing and an in-place edit.
REPRODUCED as `test_info_reApprovalSilentlyOverwritesAnExistingPairConfig`. Owner-only, so
informational.

### I-3 — Missing internal-consistency checks on hook config

Two, both currently unreachable because `onlyLauncher` and the launcher builds them consistently,
both worth adding as defence in depth against a second launcher or a future migration:

- `FeeHook.configurePoolFull:326-364` never checks that `s.pairCurrency` is one of
  `key.currency0` / `key.currency1`. A config naming a currency the pool does not contain would
  make `unlockCallback` burn and take a currency with no pool delta.
- `FeeHook.autoRedeem:680` takes `id` **and** `key` and never checks `key.toId() == id`.

Neither is exploitable today. Both are the shape of bug that becomes exploitable the moment the
`onlyLauncher` assumption is relaxed.

### I-4 — `addSchedule` silently trims

`src/VestingVault.sol:113-114`: `if (amount > unscheduled) amount = uint128(unscheduled);`. The
project's stated rule is the opposite — `Launcher` reverts `DevBuyTooLarge` rather than trim, and
the design notes record "Silent trimming is banned" explicitly. A beneficiary asking to lock more
than is present gets a schedule for a different number, with no revert and only a well-formed event
to notice it by. REPRODUCED as `test_info_addScheduleSilentlyTrimsInsteadOfReverting`.

### I-5 — `Launcher._deployer` is private, unrotatable and has no getter

`src/Launcher.sol:91`. Three consequences, none currently a bug:

- there is **no way to read on chain** who holds the initializer rights;
- if the deployer key is lost before wiring, `initReferralVault` / `initRewardConverter` are
  permanently unusable and the referral system can never be attached to that launcher;
- if the launcher were ever deployed by a **factory contract** rather than an EOA, `_deployer`
  would be the factory and both initializers would be unreachable from birth. `DeployTestnet.s.sol`
  uses plain `new Launcher(...)` from a broadcasting EOA, so this is fine today — but the deploy
  order is already delicate (predicted CREATE address), and a CREATE2 factory is the obvious thing
  someone reaches for next.

Note also that the deployer key for the current Sepolia stack is **publicly known** (recorded in
the project notes as pasted into Discord). Since both initializers are one-shot and already used
for the vault, the residual exposure is `initRewardConverter` on the live launcher — anyone with
that key can set the reward converter for every future launch on it. Sepolia only, but it should
not be carried to mainnet.

---

## Checked and found sound

Each of these was actively attacked from an attacker address, not read and assumed. Where an
existing test already proves it, that test is named instead of duplicated.

**The `unlockCallback` question, answered.** `FeeHook.unlockCallback` is *not* a withdrawal
function for the system. The PoolManager calls back only the address that called `unlock`, and the
hook calls `unlock` only from `sweep`, where every amount and every recipient is read from storage
and `cfg` is re-derived from `key.toId()` inside the callback. The attacker-supplied `bytes`
control only which configured pool is swept and who gets the bounty. Guard covered by
`HookAttack.t.sol:34-57`; the call-graph reasoning is set out under the table above.

**`Launcher.unlockCallback` is guarded, and nothing covered it before.** REPRODUCED —
`test_sound_outsiderCannotDriveLauncherUnlockCallback` calls it from the attacker *and* from the
FeeHook with a payload naming `type(uint128).max` of a token that does not exist; both revert
`OnlyPoolManager`.

**Both `Launcher` initializers are genuinely one-shot and cannot be front-run.** REPRODUCED across
three tests: every non-deployer caller is rejected (attacker and creator); a second call reverts
and the first value survives; `address(0)` is rejected so the slot cannot be burned on nothing; and
an attacker's failed squat leaves the slot free for the deployer afterwards. The guard is on the
**caller**, not on the emptiness of the slot, which is what makes front-running impossible.

**A launch with both initializers unset behaves correctly.** REPRODUCED — a launch naming a
referrer with no vault set completes, produces a tradeable pool, and simply records no referrer.
(What is *not* correct in that state is the reward-currency path — F-01.)

**The `LaunchToken` implementation cannot be initialised or hijacked.** REPRODUCED — the
constructor sets `_initialized = true`, so an attacker calling `initialize` on the template gets
`AlreadyInitialized`; the template has no distributor and no supply.

**No live clone can be re-initialised.** REPRODUCED — from the attacker *and* from the launcher
itself. The distributor pointer, the max wallet and the metadata are write-once in practice, not
just in intent.

**`PairRegistry` ownership cannot be stolen.** REPRODUCED — `Ownable2Step`'s handshake refuses an
attacker's `acceptOwnership`, the transfer is not immediate, and the outgoing owner really is
demoted once the pending owner accepts.

**Non-owners cannot touch the allowlist.** `PairRegistry.t.sol:311-329` already covers
`approvePair`, `approvePairWithoutOracle`, `revokePair` and `setSequencerFeed`. Confirmed, not
duplicated.

**`sweep` is permissionless but routes only by stored config.** REPRODUCED — an attacker sweeping
someone else's pool earns the advertised 0.5% bounty and nothing more; the platform's share is
larger than the bounty and the creator is paid in the same call. There is no parameter through
which the caller can redirect anything.

**Permissionless entry points refuse unknown pools.** REPRODUCED — `sweep` on an unconfigured key
reverts `NotConfigured`; `checkGraduation` on an arbitrary `PoolId` reverts
`GraduationNotConfigured`. Neither can be pointed at a pool id the launcher never registered.

**`ReferralVault.credit` and `setReferrer` hold their guards under live conditions.** REPRODUCED in
the harness where the vault really is the hook's `platformRecipient` and real money flows through
it: the attacker is refused `OnlyFeeHook`, and so is the **launcher** — the one other privileged
contract in the system. `setReferrer` refuses the attacker with `OnlyLauncher`.

**The referral tier schedule cannot be changed after deploy.** `_tierBps` is constructor-only,
`tierCount` is `immutable`, `MAX_TIERS` is a `constant`, and no setter exists. Verified by ABI
exhaustion; the constructor's own bounds are covered by `Referral.t.sol:219-233`.

**`extend`-never-shorten holds under every ordering**, proved by monotonicity of `_vestedAt` in
both `cliff` and `duration` with `start` immutable, plus the `vested > released` guard in
`release`. **`add`-never-subtract holds for the schedule array** — nothing removes a schedule or
lowers a `total`, and `unscheduled` cannot underflow. The *permissionlessness* of "add" is F-08.

**`FeeHook` configuration guards.** `configurePool`, `configurePoolFull` and `configureGraduation`
are all `OnlyLauncher`, and a configured pool cannot be re-pointed even by the real launcher.
`HookAttack.t.sol:78-125`. `configurePool` having no guard of its own is correct — it makes an
internal Solidity call, so `msg.sender` is preserved into `configurePoolFull`.

**`Distributor` guards.** `distribute` / `setBalance` / `setExcluded` all refuse outsiders —
`Adversarial.t.sol:211-240`. `withdraw` is keyed on `msg.sender` with no delegation. `claim` on
`ReferralVault` likewise. Nobody can withdraw on anyone else's behalf.

**No function that should be `internal` is `external`.** The two that look wrong are both correct:
`FeeHook.autoRedeem` must be `external` so `_tryAutoSweep`'s `try/catch` gets a real revert
boundary (and it is gated to `address(this)`), and `configurePoolFull` is `public` because
`configurePool` calls it internally.

**No missing zero-address check that matters.** `FeeHook` rejects a zero launcher and zero platform
recipient; `Distributor` rejects a zero share token, payout token and controller; `LaunchToken`
rejects a zero recipient and pool manager; `ReferralVault` rejects all three constructor addresses;
`VestingVault` rejects a zero token and beneficiary; `PairRegistry` rejects a zero pair and feed.
`VestingVault._distributor` is *not* zero-checked — but a zero distributor only makes
`claimDividends` revert, and the launcher always passes a real one.

**Every constructor-set immutable really is immutable.** `FeeHook.launcher`,
`FeeHook.platformRecipient`, `HookBase.poolManager`, `Launcher.{poolManager,feeHook,pairRegistry,
tokenImplementation,_deployer}`, `Distributor.{shareToken,payoutToken,rewardToken,converter,
controller,minPushPayout,minShareForQueue,minSharesForDistribution}`,
`ReferralVault.{launcher,feeHook,treasury,tierCount}`, `VestingVault.{token,distributor}` — all
`immutable`, none shadowed, none re-assignable. The two mutable ones (`Launcher.referralVault`,
`Launcher.rewardConverter`) are mutable for a documented and genuine circularity, and are one-shot.

**`LaunchToken` has no owner, no mint, no burn, no pause and no blacklist**, so `graduation.supply`
being cached is still sound and there is no privileged token function to abuse. Confirmed by ABI
inspection, and `Graduation.t.sol`'s `test_cachedSupplyStaysTrue` is the standing regression marker.

---

## Method notes

**What made the difference was wiring the ReferralVault properly.** Every existing test either
exercises the vault in isolation with a mock hook (`Referral.t.sol`) or runs the launch stack with
an EOA as `platformRecipient` (everything else). Neither shape can see F-02, F-03 or F-07, because
in the first the launcher is a `vm.prank` and in the second `credit` is never called at all.
Resolving the three-way circularity — predict the launcher's CREATE address, deploy the vault
against the *mined* hook address, then place the hook with the vault as its platform sink — is what
turned three reasoned suspicions into three passing tests. It also produced F-07 for free, because
building the correct order is what showed the deploy script does not.

**The second one: launching with a vested dev buy and then calling the permissionless push.** The
existing `Vesting.t.sol` never calls `processBatch`, and the existing `Distributor` tests never have
a `VestingVault` in the queue. Both contracts are individually correct. F-09 lives only in the
intersection, and only shows up if you run the two permissionless paths in the order a real chain
will run them.

**On grading.** Nothing here lets an attacker take money out of the system that was not already
destined for them. F-09 is graded HIGH anyway because it is permanent, costs a griefer one cheap
call, hits the largest holder in the book on a deliberately-uncapped position, and — unlike every
other finding in this file — **happens by accident on the normal path**.
