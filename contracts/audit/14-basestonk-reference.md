# 14 — BaseStonk: the closest thing to a mirror of this repo

`basestonk.io`. A Uniswap v4 launchpad on Base (8453) and Robinhood Chain (4663), paying holders a
share of trading volume. It is the nearest live analogue to what this repo builds — same chain
family, same protocol version, same product — and it is further along.

Read alongside `13-marscoin-reference.md`. MarsCoin proved the O(1) property matters at scale on a
V2 tax-token design. BaseStonk is the V4 hook version of the same argument, and it has the
component we do not.

**Verified addresses (Base, V6):**

| Contract | Address |
|---|---|
| `AdvancedLauncherV6` | `0x80459E17eC8269f058152169e58022a70ed9F1fa` (23,525 bytes) |
| `AdvancedFeeHookV6` | `0x7C672F3850afadCb8f83478E0A2a90D109fA6044` (16,640 bytes) |
| `HolderRewardsFactory` | `0x029c3CC99eCBA10Fc1616773be37FF86ffe5C395` |
| `BasketVaultV2` | `0x99FeB612f130c5e981dbC0a96c436bC06ca0fE9E` (13,715 bytes) |
| `$BSTONK` | `0x0F61Edbfe6Cd86024C0f210c0695B08df55fdfc9` |

---

## 1. Where we are the same, and it is not a small list

Read from chain state and their published docs:

- **The token is dumb.** `$BSTONK` is 3,545 bytes and answers none of `owner()`, `hook()`,
  `distributor()`. Their launched tokens are a uniform 3,658 bytes. All logic lives in the hook,
  exactly as `LaunchToken` + `FeeHook` do here.
- **Live v4 pool from block one.** No bonding curve, no graduation, no migration.
- **The launcher must end holding nothing or the transaction reverts.** That is
  `test_fork_launcherRetainsNothing` almost word for word.
- **Single-sided liquidity; the launch price is a floor.** Same construction, same reason.
- **Entitlement is integrated over time, not snapshotted.** Their own wording: *"balance
  **integrated over time**, not a snapshot — a snapshot is trivially sniped"*, with payouts in
  rolling tranches so *"no round is worth timing"*.

That last one is the streaming migration that killed **E-03** here, described in different words by
people who have never seen this code. Third independent convergence on the same design in one
review pass, after MarsCoin's O(1) property and its exclusion of pools from the share register.

**Convergence is evidence the design is right. It is not evidence our implementation is correct.**

---

## 2. The one architectural divergence: hook permissions

```
AdvancedFeeHookV6   0x2044   beforeInitialize | afterSwap | afterSwapReturnDelta
FeeHook (this repo) 0x20CC   beforeInitialize | beforeSwap | afterSwap | both return deltas
```

**They have no `beforeSwap`.** `FeeHook`'s own comments say moving the charge to `afterSwap` would
reintroduce a zero-fee hole, so the absence deserves an explanation rather than an accusation.

`afterSwap` can only adjust the UNSPECIFIED currency:

| shape | specified | unspecified | where their fee lands |
|---|---|---|---|
| exact-input buy | pair | token | **the launch token** |
| exact-output buy | token | pair | **the pair** |

They accept the fee landing in **whichever currency the swap outputs**, and convert afterwards
through their basket machinery. That is self-consistent and needs no `beforeSwap`.

We require the fee to be denominated in the **pair currency** in every shape. On an exact-input buy
the pair is the specified side and is unreachable from `afterSwap`, which is precisely why
`beforeSwap` exists here.

**Neither is wrong. Theirs is simpler; ours is more predictable.** Worth knowing that is the trade
that bought us two extra permission bits and the `_beforeSwap` charge path.

---

## 3. What they have that we do not

### 3a. Dividend baskets — up to ten assets

`BasketVaultV2`. A creator picks up to ten payout assets with weights; a share of every trade is
converted into them on-chain as people trade. We support exactly one `rewardCurrency`.

This is the per-holder reward election idea recorded in `11-external-bsc-contracts.md` §7, done at
the CREATOR level and shipped. It is the single largest product gap between us.

The seat that controls it is bounded in exactly the way ours should be if we build it:

| The basket controller can | cannot |
|---|---|
| re-weight or swap the basket's assets | **change the rewards percentage** — fixed at launch |
| hand the seat to another address | touch dividends already paid |
| renounce it, one way, not even reversible by the platform | |

### 3b. Graceful degradation on conversion

Their stated behaviour:

| condition | result |
|---|---|
| an asset cannot be bought at fair price right now | that share **pays in the pair, visibly, never lost** |
| a conversion would land below fair value | **refused and retried smaller** |
| basket empty | dividends in the pair |

**"Refused and retried smaller" is worth studying before the next pass at E-05.** We bound the
buyback as a price limit and deliberately left the sell-conversion leg unbounded, because bounding
it made the bounty farmable by fragmentation (145.98 vs 42.43, see `09-remediation.md`). Retrying
smaller is a third option we did not evaluate. It may fail for the same reason; it may not.

### 3c. Renounceable fees, and payees

`renounceFees(PoolKey)`, `renouncedBps`, and a `RenouncedShareShorted` error that enforces the
renounced portion is never quietly reassigned. Plus `setPayees` / `transferPayeeSlot` with
`MAX_PAYEES`, `TooManyPayees` and `SharesMustSumToBps`.

A creator can **permanently** give up their cut, and the contract proves it. That is a trust signal
we cannot currently offer.

### 3d. Versioned hooks

**Six generations.** Their own integration warning: *"A pool's identity includes its hook, and there
are six generations of them. Assume one hook for every pool."* New pools get new logic; old pools
keep trading untouched.

We have one shared `FeeHook`. A bug reaches every pool at once, and upgrading means migrating
everything. Their approach costs address mining per generation and buys the ability to ship.

---

## 4. Where we are stricter, and it is deliberate

**Their payouts run inside the swap, gas-bounded.** `AdvancedFeeHookV6` exposes `PAYOUT_GAS` and no
`sweep`. The vault carries a per-token gas cap — default 400,000, bounded roughly 21,000 to
2,000,000 — and `MAX_PAYEES` caps the payee list. Same anti-unbounded-iteration discipline as
MarsCoin, enforced with an explicit gas ceiling instead of by having no loop at all.

Ours converts in a **separate external `sweep()`**.

The trade cuts both ways and it maps onto a live concern:

| | BaseStonk (inline, gas-capped) | this repo (external sweep) |
|---|---|---|
| does anyone need to call anything? | no | **yes** |
| can a bad conversion affect a trade? | **yes** | no |
| `12-pre-mainnet-concerns.md` C-2 — below break-even nobody sweeps and holders silently stop being paid | **does not apply** | **applies** |

C-2 is our risk and it is real: the sweep bounty was measured at 20 gwei, and mainnet gas is
neither 20 nor stable. BaseStonk does not have that failure mode because nobody has to press
anything. They pay for it by putting conversion in the hot path.

**Do not "fix" C-2 by moving conversion inline without re-reading this table.** Our shape is safer
per-trade; theirs is safer per-week.

### One centralisation they accept

`BasketVaultV2` is **operator-gated** — a single `operator_` (`0x1Be69223CA8feF61b0D0F7AE05904bb47cda1681`)
is checked on nearly every state-changing path. It does carry a reentrancy guard. Their marketing
says the platform cannot pause pools, change fees or hold funds, and the hook appears to bear that
out; the *vault* is a different matter and is worth reading closely before copying its design.

---

## 5. What they pair against

Base: USDC, WETH, cbBTC, **tokenized stocks and ETFs**, ecosystem tokens, `$BSTONK`.
Robinhood Chain: **194 Robinhood stocks**, USDG, WETH.

Dividends are paid in those assets directly — *"real tokenized stock, not more of the token."*

This is the third live system in one review pass (with MarsCoin and the Robinhood Chain launches)
whose headline feature is the asset class `app/pairPolicy.ts` exists to exclude. The engineering
here is worth copying. The pair roster is not, and that decision is recorded in
`legal/01-dividend-securities.md`.

---

## 6. Source-verified: what the real code says

An earlier draft of this file said Basescan "served the ABI and runtime bytecode but not the
Solidity." **That was wrong, and the correction is worth recording because it is a reusable
mistake.** Everything BaseStonk ships is source-verified and publicly readable. Basescan renders
verified sources in a **Monaco editor**, which virtualises its viewport — `innerText` returns only
the lines currently painted, about 2,400 characters, no matter how large the file is. The full
24,187-character source came back immediately from `monaco.editor.getModels()[0].getValue()`.

**Nothing was hidden. The extraction was broken.** On a public EVM chain with a verified contract,
"I could not get the source" should always be read as a tooling failure first.

`AdvancedFeeHookV6` read directly, confirming and sharpening §2:

```solidity
function afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params,
                   BalanceDelta delta, bytes calldata)
    external onlyPoolManager returns (bytes4, int128)
{
    if (sender == launcher) return (IHooks.afterSwap.selector, 0);   // launcher swaps are untaxed
    ...
    (Currency feeCurrency, uint256 magnitude) = _unspecified(key, params, delta);
    uint256 fee = (magnitude * rate) / BPS;
    ...
    return (IHooks.afterSwap.selector, fee.toInt128());
}
```

`_unspecified` selects the currency purely from the sign of `amountSpecified`, so the fee lands on
whichever side the swap did not specify. §2 is confirmed from source, not inferred from flags.
`beforeSwap` exists only as the `IHooks` stub and reverts `HookNotImplemented`, matching `0x2044`.

### Two details only the source shows

**`sniperExempt` is keyed on `sender`, which is the caller of `PoolManager` — the router, not the
trader.** Every ordinary trade arrives via their `SwapRouter`, so exemption is granted per
integrating router and an individual wallet can never hold it. Read on-chain, `sniperExempt` is
currently `false` for both their `SwapRouter` and their launcher, so the mechanism is inert today;
it is a lever for whitelisting integrator routers, not users. If we ever add an exemption of our
own, key it on the resolved trader, not on `msg.sender`.

**`if (sender == launcher) return 0`** makes the launcher's own swaps fee-free. That is how an
untaxed dev buy works, and it means anything that can induce the launcher to swap is a fee-free
path. Worth remembering if `Launcher` here ever gains a swap.

### Live constants, read from chain

| | BaseStonk | this repo |
|---|---|---|
| anti-snipe max rate | `SNIPER_MAX_BPS` = **9900** | `MAX_OPENING_FEE_BPS` = **9900** |
| anti-snipe min window | `SNIPER_MIN_WINDOW` = 10s | — |
| opening window cap | — | `MAX_OPENING_WINDOW` = 300s |
| payout gas ceiling | `PAYOUT_GAS` = 500,000 | n/a (external `sweep`) |
| max payees | `MAX_PAYEES` = 8 | n/a |

**The 9900 is an exact match**, arrived at independently. That is the fourth convergence in this
review pass, after the dumb token, the O(1) property and time-integrated entitlement.

### Still not source-verified

`BasketVaultV2` was read only as runtime bytecode, from which its operator gate, reentrancy guard
and per-token gas ceiling (default 400,000, bounded roughly 21,000–2,000,000) are visible. The
basket mechanics in §3a and the conversion fallback in §3b remain **documentation claims**. Pull
its source the same way — Monaco model, not `innerText` — before implementing either.
