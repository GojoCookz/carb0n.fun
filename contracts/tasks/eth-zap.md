---
title: ETH zap - buy and sell any launch with ETH only
description: >
  Managed by kimaki. The buyer should never need to hold the pair currency.
  Do not move or delete this file without updating the task.
---

# Goal

**A buyer pays ETH and receives the launch token. A seller sells the token and receives ETH.**
The pair currency stays completely invisible to them.

Today `/t/:address` forces the buyer to already hold the pair currency. For `$GOLDFISH` that is
PAXG. Nobody has PAXG. The funnel dies at step one, and this is the single biggest product
problem in the app right now.

The pair currency is **not** the thing being removed. Holders still get paid in PAXG — that is
the entire thesis of the product and it must not change. What is being removed is the
requirement that the BUYER sources it. Those are two different concerns and the current build
conflates them.

This is what lunch.fun does — ETH-in / ETH-out routing that hides the pair asset entirely. See
`C:\Users\shies\.claude\projects\C--Users-shies\memory\reference_lunch_fun.md`.

# Shape

```
BUY   ETH --(hop 1: ETH/PAIR pool)--> PAIR --(hop 2: our hook pool)--> TOKEN
SELL  TOKEN --(hop 2 reversed)--> PAIR --(hop 1 reversed)--> ETH
```

Both hops inside ONE `PoolManager.unlock` callback, one signature, one transaction.

# Hard constraints - read these before writing any Solidity

These are all things this codebase has already been bitten by. They are in
`C:\Users\shies\.claude\projects\C--Users-shies\memory\project_hoodstonk.md` and the audit
folder.

1. **Swap FIRST, settle from the delta.** A router that does `sync -> transfer -> swap -> settle`
   is overcharged **8.5x** by our own hook, because `FeeHook` moves ERC-20 out of the singleton
   during `afterSwap` and `PoolManager._settle` credits `balanceOfSelf() - syncedReserves`. This
   is measured, not theoretical. `TradeRouter.sol` already gets this right — read it first and
   copy the ordering. `test_costsTheSameAsASettleAfterRouter` guards it, and the failure mode is
   a SILENT OVERCHARGE rather than a revert, so a test that only checks "did it succeed" will
   pass while users are being robbed.

2. **The intermediate leg does not simply net.** Because the hook moves ERC-20 mid-swap, you
   cannot assume the `+PAIR` delta from hop 1 cleanly cancels the `-PAIR` delta of hop 2. Settle
   and take each leg explicitly and assert the final accounting. Do not hand-wave this.

3. **Sell-side pin.** Once spot is at `MIN_SQRT_PRICE + 1` / `MAX_SQRT_PRICE - 1`, `Pool.swap`
   rejects EVERY sell in that direction. A fresh pool that has never been bought from cannot be
   sold into. Zap sells must surface this as a clear message, not a raw revert.

4. **viem enforces EIP-55.** Lowercase addresses on the way into the encoder or it throws before
   building the tx.

5. **Foundry:** chained `vm.warp(block.timestamp + X)` is a NO-OP under via-ir and inside loops.
   Use absolute warps from a stored `t0`. `runs: 0` in fuzz output means a cached counterexample
   is being replayed — clear `cache/fuzz` and `cache/invariant`.

6. **No `git add -A`.** `hoodstonk/app` lives inside the `CodeProjects` monorepo which has
   thousands of unrelated dirty files and other agent sessions working in it. Stage explicit
   paths only: `git commit -F <msgfile> -- hoodstonk/app/src`. `hoodstonk/contracts` is its own
   repo and is currently clean.

7. **PowerShell** mangles multi-line `-m` commit messages. Write the message to a file and use
   `-F`. Foundry is at `C:\Users\shies\.foundry\bin`. solc pinned 0.8.26.

# Testnet reality - state this honestly, do not paper over it

There is **no ETH/tPAXG pool on Sepolia**. tPAXG is a stand-in with no market at all. To demo
hop 1 you must seed a pool yourself, which means **its price is a number you invented**.

That is acceptable for proving the ROUTING works. It is NOT evidence the economics work, and the
UI must not imply otherwise. Say so plainly in the commit message and in any summary. Do not
show a working zap and let the reader assume it was validated against a real market.

On mainnet hop 1 would route through a genuinely deep pool (ETH/PAXG exists on v3 with real
liquidity — `app/measure.ts` measured PAXG at $17.2M across v2+v3).

# Plan

1. Read `src/TradeRouter.sol` and `test/TradeRouter.t.sol` FIRST. Copy the settle ordering.
2. Write `src/ZapRouter.sol`. Native ETH in, two hops in one unlock, exact-input with a
   `minAmountOut` floor that the caller supplies. Reject a zero floor — a swap with no floor is
   an instruction to be sandwiched.
3. Tests, and make them adversarial:
   - a **negative control** that proves the fee actually fired (a zap that charges nothing must
     FAIL the test, not pass it)
   - assert the zap costs the same as doing the two hops manually - that is the 8.5x guard
   - the sell-side pin path
   - a hop-1 pool with thin liquidity, so price impact is real
4. Deploy to Sepolia, seed an ETH/tPAXG pool, record the address in `app/src/lib/chain.ts`
   `DEPLOYMENTS` next to the other verified addresses.
5. Wire `app/src/lib/tradeTx.ts` + `app/src/components/TradePanel.tsx`: a currency selector on
   the "You pay" row offering **ETH** (default) or the pair. Default to ETH.
6. Prove it with `app/tradeTest.ts` — that script already runs real buys and sells against the
   app's own encoding by importing `poolKeyFor` from `tradeTx.ts` rather than restating it. Extend
   it to cover the zap the same way. **Import the app's real ABIs, never restate them** — the
   first version of that script hand-wrote the `launches` tuple in the wrong field order and
   called `symbol()` on a wallet.
7. Screenshot at 390x844 through `kimaki tunnel` + `playwriter` before claiming it works.

# Definition of done

- A real ETH-funded buy and an ETH-out sell, both executed on Sepolia, tx hashes reported.
- The fee still reaches the distributor — **verify this explicitly**, it is currently the least
  tested claim in the whole product and it is the one the product lives on.
- `forge test --no-match-contract Fork` still green (744 tests passing before this work).
- Screenshot of the panel with ETH selected.
- Commit with explicit paths. Show a `bunx critique --web` URL.

Mention the user via `<@1245076421861445704>` when it is ready for review.
