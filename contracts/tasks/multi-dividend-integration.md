# TASK — integrate MultiRewardDistributor and trial it on a testnet

**This brief is self-contained.** It assumes no prior context. Read it fully before touching code.

**Owner:** a separate agent session, running in parallel with UI work on `app/`. Do not edit
anything under `app/` — another session is actively changing `src/lib/`, `src/pages/Launch.tsx`
and `src/index.css`, and you will collide.

---

## 1. What exists, and what does not

`src/MultiRewardDistributor.sol` — **773 lines, complete, 18/18 tests passing** in
`test/MultiRewardDistributor.t.sol`, including reentrancy from a registry-approved hostile token
and a 1,000-run solvency fuzz.

```
$ grep -r MultiRewardDistributor src/ script/
-> matches ONLY inside MultiRewardDistributor.sol itself
```

**It is wired to nothing.** No `Launcher`, no `FeeHook`, no `LaunchToken`, no deploy script
references it. It has never been deployed and cannot be reached from a launch. That is the entire
job: make it reachable, prove it works on a testnet, and do not break the single-reward path that
is live on Robinhood Chain today.

## 2. What it does that `Distributor` does not

`src/Distributor.sol` is the deployed one. It pays every holder in **one** asset: the pair
currency, with an optional platform-wide converter.

`MultiRewardDistributor` adds:

- **N creator-weighted slots.** `setBasket(address[] tokens, uint16[] weightsBps, uint16 holderSlotBps)`.
  Weights must sum to `BPS`, no zero-weight slots, every token must pass `PairRegistry.isApproved`.
- **One holder-elected slot.** `setMyReward(address token)` lets an individual holder choose what
  their share converts into, gated on `isApproved`.
- **BaseStonk seat semantics** for the basket controller: two-step transfer
  (`transferBasketController` / `acceptBasketController`), one-way `renounceBasket`, and the
  controller **cannot change the total percentage** — only its composition.
- **Per-slot failure falls back to the pair currency.** A conversion that reverts emits
  `RewardConversionFailed` and pays in pair rather than reverting the withdrawal.

Accounting stays denominated in `payoutToken` throughout. Conversion happens at the edge, on
withdrawal.

## 3. The hard constraints

<!-- These are not preferences. Violating any one of them invalidates the work. -->

1. **The live contracts are immutable.** `Launcher`, `FeeHook`, `PairRegistry`, `LaunchToken` and
   `Distributor` are deployed on Robinhood Chain 4663 with no owner, no upgrade path and no admin.
   Integration is a **redeploy of the stack**, not a migration. Nothing you write can alter a
   launch that already exists.
2. **Do not touch the deployed addresses.** They are recorded in `script/Addresses.sol` and
   `app/src/lib/networks.ts`. Leave both alone.
3. **Do not make multi-reward mandatory.** A launch that wants one payout asset must keep working
   exactly as it does now, at the same gas. The single-asset path is the live product.
4. **`creatorBps + burnBps <= BPS` and the `MAX_FEE_BPS = 1000` cap still hold.**
5. **No new admin surface.** `audit/12` and `legal/01` both turn on the fact that nothing is
   manageable post-launch. Every new setter must be either creator-scoped-and-renounceable or
   absent. If you find yourself adding an owner, stop and write down why.

## 4. The integration decision you must make first

`LaunchToken.initialize` currently does this (`src/LaunchToken.sol:140`):

```solidity
distributor = new Distributor(...);   // a real deployment, not a clone
```

`Distributor.shareToken` is `address(this)` by construction, and `LaunchToken._update` calls
`distributor.setBalance()` on both sides of every transfer. Whatever you do must preserve that
invariant.

**Pick one and justify it in the PR:**

- **(a) Swap the type.** `LaunchToken` always deploys a `MultiRewardDistributor`, configured with a
  single 100% slot when the creator wants one asset. Simplest surface, one code path, but every
  launch pays the larger contract's deploy gas and the live behaviour must be proven identical.
- **(b) Branch on a launch parameter.** `LaunchParams` gains a flag; `initialize` deploys one or
  the other behind a shared interface. Cheapest for simple launches, but two code paths forever
  and every downstream reader needs the interface.

**Measure (a)'s gas before choosing.** `forge test --gas-report` on a launch test, both ways. If
the delta is small, (a) is better — one path is worth real money in avoided bugs.

## 5. Testing requirements

Repo conventions, all enforced elsewhere in `test/`:

- **Both currency orderings.** Make the test contract `abstract` with
  `_tokenIsCurrency0()` and derive two concrete contracts. Which side the launch token sorts onto
  flips the sign of every delta; a bug that appears in one ordering only will otherwise ship. See
  `test/audit/11-sweep/SweepBountyGas.t.sol` for the pattern.
- **Negative controls.** For every "X is paid correctly", add a test that fails if the payout is
  silently zero. A passing suite that asserts nothing is worse than no suite.
- **`skip(n)`, never `vm.warp`.** Streaming uses relative time.
- **`vm.expectPartialRevert`** for custom errors with arguments.
- Name findings `test_finding_*` while reproducing, invert to `test_fixed_*` once repaired.

New coverage this work must add:

1. A basket whose weights sum to `BPS - 1` and `BPS + 1` both revert `WeightsMustSumToBps`.
2. A slot naming a token **not** in `PairRegistry` reverts `TokenNotApproved`.
3. A holder election for an unapproved token reverts; for an approved one, changes only that
   holder's payout and nobody else's.
4. A conversion that reverts pays that slot in pair currency, emits `RewardConversionFailed`, and
   **leaves total owed unchanged** — this is the solvency property, fuzz it.
5. The controller cannot raise `holderSlotBps` after `renounceBasket`.
6. Reentrancy from a hostile basket token during `withdraw` and during `processBatch`.
7. `processBatch` with a basket is bounded — a large basket must not make the push path
   ungriefable. Measure gas per account and record the safe batch size.

## 6. Testnet trial — and the trap waiting for you

**`audit/12` blocker: the deployed Sepolia contracts have DRIFTED from source.** `LaunchParams`
and the `ZapRouter` signatures changed after that deploy. Do not test against the existing Sepolia
addresses; they will fail in ways that look like your bug and are not.

**Redeploy the full stack to Sepolia first**, from current `main`, before integrating anything.
That gives you a known-good baseline to diff against.

Then:

1. Deploy the stack **with** `MultiRewardDistributor` to Sepolia.
2. Launch a token with a **single** 100% slot. Prove buy -> sweep -> claim is byte-identical in
   outcome to the current `Distributor`. This is the regression gate.
3. Launch a second token with a **three-slot basket plus a holder slot**. Prove each slot converts,
   and that a deliberately broken token in one slot degrades only that slot.
4. Record every address and tx hash in `contracts/audit/16-multireward-testnet.md`, in the style of
   `audit/14` and `audit/15` — every claim tied to the call or event it came from.

Sepolia has Chainlink feeds and Robinhood does not, so **do not build anything that depends on a
USD price**. `Addresses.hasUsdFeed(4663)` is false and must stay handled.

## 7. Practical notes

- Foundry is at `C:\Users\shies\.foundry\bin`. solc pinned **0.8.26**.
- **`via_ir` builds take 15-25 minutes.** Run them in the background
  (`Start-Process ... -RedirectStandardOutput`) and poll. Do not sit on a blocking 25-minute call.
- Full suite: `forge test --no-match-contract Fork`. It is **1,595 tests, 0 failing** right now.
  That number must not go down.
- Fork tests are excluded from the default run and rot silently. If you touch anything they cover,
  run `forge test --match-contract Fork` explicitly.
- PowerShell: no `&&`. Use `cmd1; if ($?) { cmd2 }`. Commit messages with quotes must go through
  `git commit -F <file>` — inline `-m` gets mangled by the shell.
- **Never `git add -A`.** Other sessions are working in this repo. Stage explicit paths.

## 8. Definition of done

- [ ] Integration decision made, with a gas measurement backing it
- [ ] Full suite still 1,595+ passing, 0 failing, both currency orderings
- [ ] The seven new test properties in §5 covered
- [ ] Sepolia redeployed from current `main`, drift cleared
- [ ] Single-slot launch proven outcome-identical to today's `Distributor`
- [ ] Multi-slot launch proven end to end, including a deliberately failing slot
- [ ] `audit/16-multireward-testnet.md` written, every claim sourced to a tx or a call
- [ ] Nothing under `app/` modified
