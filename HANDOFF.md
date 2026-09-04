# Handoff

Written for whoever picks this up next. It is deliberately blunt about what does not work.

**Read `contracts/audit/` before you change anything in `contracts/src/`.** Ten audit surfaces
found real defects with measured numbers; several are documented and NOT fixed, and the tests
that cover them assert the vulnerable behaviour on purpose. A green suite here means "the known
bugs still behave as recorded", not "there are no known bugs."

---

## What this is

A Uniswap v4 token launchpad on Ethereum. Anyone can launch an ERC-20 that opens a v4 pool
against a chosen "pair currency" (WETH, WBTC, PAXG, LINK, ...). A hook charges a fee inside the
swap and splits it four ways.

**The thing that makes it different: holders are paid dividends in the PAIR CURRENCY, not in more
of the memecoin.** Hold `$GOLDFISH`, get paid in PAXG. Every hard design decision downstream falls
out of that one constraint.

- `contracts/` — Foundry. **1,319 tests, 0 failing** (`forge test --no-match-contract Fork`).
- `app/` — Vite + React + viem, no wagmi.

## Current state

**Sepolia only. Nothing is on mainnet and nothing may go to mainnet yet** — see Blockers.

```
PairRegistry   0xd2Ed630c334355e8A38f06FddF9F2C72bf776340
Launcher       0x01Bb4b4f8f70DF56A3F3C754BFFd618D9f9f2Dc6
FeeHook        0xAE97429E14Ee64d9A57b059d1D1d8700fdF060cC   low14 = 0x20CC
ReferralVault  0xc1B8E7cc08826E1460f0895281631F86b0e75449
TradeRouter    0xdd48D62D1127f12838a5672B457843B81844E62F
ZapRouter      0xe4683175B4Bd69C62F073b0F9fAC5f29b181AB52
tWETH / tWXMR / tPAXG   see app/src/lib/chain.ts
```

Working end to end on Sepolia: launch, buy, sell, ETH-in/ETH-out zap, fee collection, sweep,
dividend payout. Real transaction hashes are in the commit messages.

**The deployed contracts have DRIFTED from `src/`.** The live `Distributor` predates several
additions and `streamFinish` reverts against it. `app/src/lib/useTokenDetail.ts` reads with
`allowFailure: true` for exactly this reason. Redeploy before trusting any live read.

---

## BLOCKERS — do not ship past these

### 1. The open audit findings are documented, not fixed

`contracts/audit/09-remediation.md` closed a batch. These are still open and still exploitable:

- **E-01 — the block-0 snipe is a 50:1 free option.** Downside capped at `feeBps` by the opening
  tick floor (-3.00 pair); upside measured **+157.21**. Organic buyers lost 154.82 of 200. The dev
  buy does not defend the open. Inherent to opening single-sided at a creator-chosen price; four
  options are costed in `audit/09-remediation.md` and none were taken.
- **V-01 / V-02 — the auto-sweep is unreachable from exact-input swaps**, so on all real router
  traffic the dividend pot grows unpaid until a volunteer sweeps. Making it reachable would take
  the measured **8.5x** sync-first settlement overcharge from latent to live. The standing
  recommendation is to **delete the auto path entirely**; it was not done because the app copy
  advertises it.
- **Z-14 — a stranger can take every zap SELL offline** for `0.4220 pair` on 61.0892 pushed
  through (0.69%), by parking hop 1 on its price limit. Re-arms every block. Pure grief, earns
  nothing, bounded by hop-1 depth. `contracts/audit/10-zap-router.md`.
- **`processBatch` is called NOWHERE in `src/`.** The push cursor never advances. The pull path
  (`withdraw()`) is the only one that pays anyone. `Distributor`'s own docblock claims the hook
  calls it opportunistically. It does not.
- `contracts/audit/10-zap-router.md` also lists 4 more LOW and 6 INFO findings that are open.

### 2. The securities question is unanswered

`contracts/legal/01-dividend-securities.md`. **Not legal advice, written by an AI, four citations
in it are flagged unverified.** Read it anyway.

The short version: the SEC's 2026 interpretive release defines all three of its non-security
buckets with the same words — a thing is not a security partly because it *"does not have
intrinsic economic properties or rights, such as generating a passive yield or conveying rights to
future income."* A token here generates a passive yield, in a third asset, pro-rata by balance,
with no holder action. Footnote 60 of that release blesses an automatic creator royalty
specifically because *"the holder does not receive any share of the creator royalty."*

The cheapest structural mitigation is `creatorBps = BPS`, which makes `toHolders = 0` at
`FeeHook._routeFee` — zero contract changes, the capability is already legal. That deletes the
product thesis, so it is a business decision and not a code one. **A securities lawyer needs to
see this before mainnet.**

### 3. Operational

- **The Sepolia deployer key is permanently public** — it was pasted into a chat. Sepolia only,
  never mainnet value. Mainnet needs a fresh key and realistically a multisig on `PairRegistry`.
- `DeployTestnet.s.sol` deploys `ReferralVault` AFTER the hook and `platformRecipient` is
  immutable, so the vault is **orphaned** and `credit` is unreachable. The hook address is MINED,
  so the mainnet deploy order must create the vault FIRST and mine against it.
- `LiveTest.s.sol` / `RouteTest.s.sol` / `VestTest.s.sol` hardcode stale addresses.

---

## Known gaps (not blockers, but real)

- **Referrals cannot pay anyone.** `FeeHook._routeFee` splits creator/burn/platform/holders and
  there is no wedge to pay a referrer from. Needs a contract change. `/rewards` says so.
- **No indexer.** The board loops `launchCount()` / `launches(i)`. No trades feed, no chart, no
  momentum panel. This is the single biggest UI gap — see the teardown notes below.
- **Dividend baskets** (multiple reward assets, weighted) are not built. Competitors ship it.
- **Nobody has signed a launch from a browser.** The encoding is proven against the live chain by
  script; the click-through is not.
- `HookBase` is ~20% covered — mostly unimplemented callbacks that revert.
- A dev buy reaches the creator wallet-to-wallet, so it bypasses `maxWallet`.

---

## The ETH zap, since it is the newest thing

`contracts/src/ZapRouter.sol`. `ETH -> PAIR -> TOKEN` and back, both hops in one
`PoolManager.unlock`. Holders are still paid in the pair currency; what was removed is the
requirement that the BUYER sources it.

**Three things about it that are load-bearing and easy to break:**

1. **Swap first, settle from the manager's own transient deltas.** A router that does
   `sync -> transfer -> swap -> settle` is overcharged **8.5x** by our own hook, silently, because
   `FeeHook` moves ERC-20 out of the singleton during `afterSwap` and `PoolManager._settle` credits
   `balanceOfSelf() - syncedReserves`. It is an overcharge, not a revert. `settle()`'s return value
   is now checked against what was handed over so a future refactor reverts instead.
2. **The pair leg is measured, not assumed.** It nets in the ordinary case and stops netting when
   a hop is cut short by its price limit.
3. **Quoting is done by REVERTING** (`ZapQuote(amount)`) after the swaps and before settlement. A
   quote therefore needs no balance and no approval, and a zero-slippage-floor swap is structurally
   unreachable.

**Only 11 of 38 pair currencies can actually take an ETH buyer.** Measured against the mainnet v4
singleton — `app/pairDepth.ts`, and re-run it, liquidity moves. v2/v3 depth is unreachable from
the v4 singleton, so "PAXG has $17.2M across v2+v3" says nothing about whether the zap can use it.
24 are UNUSABLE, including SHIB, WXMR and ANIME. `app/src/lib/ethRoute.ts` holds the table.

**On Sepolia the ETH/tPAXG hop-1 pool was seeded by us at a price we invented, and its liquidity
is not locked.** It proves the routing. It is not evidence about the economics.

---

## Environment gotchas that will cost you a day

- **solc is pinned to 0.8.26 and must stay there.** `v4-core/src/PoolManager.sol` declares an exact
  `pragma solidity 0.8.26`, and any test deploying the real PoolManager shares a compilation unit
  with it.
- Foundry here was the **Windows** install, not WSL.
- A clean `via_ir` build is **~5-25 minutes**. Batch your edits.
- **`vm.warp(block.timestamp + n)` chained or in a loop is a NO-OP** under `via_ir` — solc hoists
  `TIMESTAMP` as loop-invariant within a call frame. This produced two completely fabricated
  findings in this repo before it was caught. Use forge-std `skip(n)` / `vm.getBlockTimestamp()`.
- `vm.expectRevert(X.selector)` does NOT do selector-only matching here. Use
  `vm.expectPartialRevert`.
- **Dividends stream over 24 hours.** `withdrawableOf` is 0 in the block a distribution lands, but
  `pair.balanceOf(distributor)` moves immediately. Money and entitlement are on different clocks.
- **`runs: 0`** in fuzz output means a cached counterexample is being replayed — clear
  `cache/fuzz` and `cache/invariant`.
- `forge coverage` needs `--ir-minimum` (`Launcher.launch` is stack-too-deep otherwise).
- Archive RPC for fork tests: `eth.drpc.org`. publicnode 403s archive reads.
- `PoolKey.fee` is **NOT** the fee anybody pays on mainnet pools — a protocol fee is switched on
  for several, and the real rate is `pf + lp - pf*lp/1e6` from `slot0` bits [184,208).

## Testing conventions

- **Every suite runs in BOTH currency orderings.** Which side the launch token sorts onto flips the
  sign of every delta; a hook that works in one and no-ops in the other is the most expensive kind
  of passing test.
- **A test named `test_finding_*` asserts a BUG on purpose.** When you fix it, INVERT it to
  `test_fixed_*` with the measured before/after in the docstring. Do not delete it.
- **Hunt vacuous passes.** `assertGt(x.balanceOf(a), 0)` is a trap in a harness that funds actors
  in `setUp` — measure deltas. Every `expectRevert` needs a positive precondition beside it. Eight
  vacuous passes have been found in this suite so far; each was proved with a negative control.

---

## Suggested next work, in order

1. **Fix E-01 and V-01**, or decide in writing not to. They are the two that cost users money.
2. **Get the securities memo in front of a lawyer.** Everything else is wasted if the answer is no.
3. **Redeploy.** The live contracts are behind `src/` and the deployer key is public.
4. **Build an indexer.** No chart, no trades feed and no momentum panel is the biggest UI gap, and
   all three need the same log-reading infrastructure.
5. **Holders table** with LP / Dev / Burned / Vault badges — the exclusion list already knows which
   is which.
6. **Mobile trade sheet.** The panel is inline and its primary action currently sits under the
   fixed bottom nav at 390x844.

Ideas 4-6 come from a teardown of `basestonk.io`'s token page, the closest live comparable. Their
best two details, both worth copying: the pay-with selector labels each currency `direct` or
`routed`, and the dividend panel shows your literal position in the payout queue
(`In line — 350 of 371 · ~349 trades away · or [Claim now]`). The first is already implemented
here; the second is partly implemented in `app/src/components/DividendPanel.tsx`.

---

## Rules this codebase is written to

They are not decoration; several were adopted after something broke.

1. **No fake or placeholder data rendered as fact.** Every number on screen traces to a chain read
   or a cited source. A value that cannot be read renders `—`, never `0`. This has been violated
   twice and caught twice — most recently the board advertising a 0% fee on a pool charging 3%.
2. **Silent trimming is banned.** A parameter out of range reverts. It is never clamped.
3. **Verify against the installed library version**, not from memory. `lib/v4-core` is the source
   of truth for v4 semantics, and this repo's notes record several places where memory was wrong.
4. **Comments state reasons, not restatements** — and a comment that turns out to be false is a
   defect. One in `ZapRouter` was the load-bearing justification for three audit findings.
