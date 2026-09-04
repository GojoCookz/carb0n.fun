---
title: FeeHook test suite, then the clone-based Launcher
description: >
  Handoff brief written from the previous session's closing state. Job 1 proves
  the hook works. Job 2 builds the Launcher on top of a proven hook.
---

# Where this started

Previous session ended with:

```
DEPLOYED + VERIFIED          BUILT, UNPROVEN         NOT BUILT
  PairRegistry (Sepolia)       FeeHook  (0 tests)      Launcher
  tWETH + mock feed
  tWXMR (no oracle)
  tHOSTILE
```

`FeeHook` compiles and is deployed nowhere. Until a swap runs through it and a
holder's balance actually goes up, there is no launchpad — only plumbing.

# Job 1 — FeeHook test suite

Prove two things, in this order:

1. **A swap through the pool does not revert.** The `CurrencyNotSettled` trap:
   `afterSwap` returns a positive `int128` on the unspecified currency, which
   gives the hook a positive delta. If the hook does not also `take()` that
   exact amount, the unlock cycle ends non-zero and *every swap in the pool
   reverts*. This is unproven.
2. **`Distributor.withdrawableOf(holder)` goes up after a swap.** Fees must
   land in the pair currency and reach a real holder.

Constraints:

- Use `deployCodeTo` to place the hook at a `0x2044` address. Do **not** mine a
  salt in tests — it burns minutes per run.
- Mine the `LaunchToken` CREATE2 salt for currency ordering. This is what real
  launchpads do and it lets the suite cover both orientations.
- Cover all four swap shapes: exact-in buy, exact-out buy, exact-in sell,
  exact-out sell, in **both** currency orientations. Eight cases.
- Assert against observed on-chain behaviour, not against the docstring. If the
  code and its comment disagree, the comment is the bug report.

# Job 2 — clone-based Launcher

Only after job 1 is green.

- Deploy launch tokens as **EIP-1167 minimal proxy clones** via OpenZeppelin
  `Clones`, not full deployments. Cuts per-launch gas and keeps the token
  bytecode out of the Launcher, which is the contract most at risk of EIP-170.
- One transaction: token deploy, pool init, LP seed, optional dev buy, LP burn.
- Metadata designed in from the start: image required, banner 1500x500 optional,
  IPFS CID on-chain, never a full URL.
- Tax and dividend split configured at launch and **immutable afterwards**. A
  split that can change after people buy is a rug with extra steps.
- Invariant: the launcher holds zero of everything after a launch.

Target: EIP-170's 24,576 byte runtime limit. EIP-7907 was removed from Fusaka,
so the limit stands.

# Done means

`forge fmt --check`, `forge build --sizes`, `forge test -vv`, `forge coverage`
— actual output pasted, not a claim that it passes.

---

# OUTCOME — both jobs complete

`forge test`: **136 passed, 0 failed** across 6 suites. `forge fmt --check` clean.
Coverage 85.03% lines overall (FeeHook 100%, Launcher 97.75%).

## Four defects the suite found, all fixed

1. **Exact-input buys collected zero fees.** `afterSwap` can only move the
   UNSPECIFIED currency; on an exact-input buy the pair currency is the SPECIFIED
   side, so the hook charged nothing on the shape every router sends by default.
   The pool worked and the revenue silently did not. Fixed by adding a
   `beforeSwap` leg — hook flags moved **0x2044 -> 0x20CC**.

2. **The PoolManager accrued dividends and could not be excluded.** In v4 the
   pool's reserves are an ERC-20 balance on the singleton, so the manager was the
   largest holder in the book. `setExcluded` is `onlyController`, the controller
   is the hook, and the hook has no function that calls it — unreachable. Now
   excluded in the Distributor's constructor.

3. **`distribute` dropped fees instead of carrying them.** The docstring promised
   they were "folded into the next distribution"; the code returned early and
   stranded them. Reachable on the normal path, because the dev buy is the first
   trade and happens with `totalShares == 0`. Added `pendingPayouts`.

4. **A one-wei first holder could brick the token permanently.** Dividing a fee
   by dust inflates `_magnifiedPayoutPerShare` until `_magnifiedPayoutPerShare *
   delta` overflows inside `_update`, reverting **every transfer for everyone**.
   Observed as a live panic 0x11 before the fix. Added `minSharesForDistribution`
   (supply / 1e6) so dust-era distributions carry.

## Deliberate deviations from the brief

- **Solc pinned to 0.8.26, not 0.8.30.** `v4-core/src/PoolManager.sol` declares an
  exact `pragma solidity 0.8.26`, so any test deploying the real PoolManager
  shares a compilation unit with it and no version satisfies both. Our sources
  now declare `^0.8.26`.
- **Only the token is cloned; the Distributor stays a real deployment.** Its
  `setBalance` runs twice per transfer forever — trading a one-time deploy cost
  for two permanent SLOADs on the hottest path is the wrong way round.

## Known gaps

- Sells are free by design (the fee must be paid in the pair currency). Worth a
  product decision, not a bug.
- `beforeSwap` charges the REQUESTED input, so a swap stopped early by
  `sqrtPriceLimitX96` is overcharged, bounded by `feeBps`.
- A dev buy reaches the creator via a wallet-to-wallet transfer, so it bypasses
  `maxWallet`. It is bounded separately by `MAX_DEV_BUY_BPS` (10%).
- `HookBase` sits at 20% coverage: it is mostly unimplemented callbacks that
  revert.
- Nothing here is deployed. `script/DeployTestnet.s.sol` predates the Launcher.
