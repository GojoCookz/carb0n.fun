# EVM launchpad playbook

Everything learned building this pad, written so the next one takes days instead of weeks.

Every claim here was verified against the **installed** `lib/v4-core` source or measured in a test.
Where a number appears, it came from a test that was actually run. Where something is uncertain it
says so.

---

## 1. The Uniswap v4 mental model

v4 is not v3 with hooks bolted on. Three things are different and all three change your design.

### One contract holds everything

`PoolManager` is a **singleton**. Every pool on the chain lives in it, and its ERC-20 balance is
every pool's reserves combined.

> **Never read an absolute balance off the PoolManager.** Always measure deltas. Its `balanceOf` is
> a number about the whole chain, not about your pool.

### Flash accounting: unlock, then settle to zero

You cannot call `swap` directly. You call `unlock`, the manager calls **you** back at
`unlockCallback`, and inside that window every operation writes a signed **delta** to transient
storage keyed by `(address, currency)`. When the callback returns, the manager checks
`NonzeroDeltaCount != 0` and reverts if anything is open.

```
unlock()
  └─ your unlockCallback()
       ├─ swap()            → writes deltas
       ├─ settle()          → you paid what you owed        (negative delta → 0)
       ├─ take()            → you collected what you're owed (positive delta → 0)
       └─ return            → manager asserts every delta is 0
```

**`NonzeroDeltaCount` is sign-agnostic.** A leftover *credit* reverts exactly like a leftover
*debt*. Forgetting to `take` a dust amount you're owed is the same failure as not paying.

### Deltas are signed, and the sign convention will bite you

- **negative** = you owe the manager → `settle()`
- **positive** = the manager owes you → `take()`

`amountSpecified` on a swap is **inverted from v3**: **negative is exact-INPUT**, positive is
exact-output. Read that twice.

### Settling: two completely different mechanisms

```solidity
// ERC-20 — credited by BALANCE DIFFERENCE
poolManager.sync(currency);                       // snapshot balance
IERC20(token).transfer(address(poolManager), n);  // move the money
uint256 credited = poolManager.settle();          // credits balanceOfSelf() - syncedReserves

// Native ether — credited by msg.value, no balance read at all
poolManager.sync(CurrencyLibrary.ADDRESS_ZERO);   // only RESETS the synced-currency slot
poolManager.settle{value: n}();                   // paid = msg.value
```

That asymmetry is not trivia — it is the root of the worst bug in this codebase. See §4.

---

## 2. Hook flags: the address IS the permission set

A hook's permissions are encoded in the **low 14 bits of its own address**. You mine a CREATE2 salt
until the address has the right bits. `HookBase`'s constructor asserts the deployed address matches
`getHookPermissions()`, so a wrong salt fails loudly at deploy.

| flag | bit |
|---|---|
| `BEFORE_INITIALIZE` | `0x2000` |
| `AFTER_INITIALIZE` | `0x1000` |
| `BEFORE_ADD_LIQUIDITY` | `0x0800` |
| `BEFORE_SWAP` | `0x0080` |
| `AFTER_SWAP` | `0x0040` |
| `BEFORE_SWAP_RETURNS_DELTA` | `0x0008` |
| `AFTER_SWAP_RETURNS_DELTA` | `0x0004` |

### Choosing flags is a consequence of your fee design, not a free choice

Almost every production launchpad hook is **`0x2044`** — `BEFORE_INITIALIZE + AFTER_SWAP +
AFTER_SWAP_RETURNS_DELTA`. That works when you don't care which currency the fee lands in, because
`afterSwap` can only move the **UNSPECIFIED** currency.

This pad is **`0x20CC`**, and here is the reasoning, because it generalises:

> Pay holders strictly in the **pair currency**. On an exact-input BUY the pair currency is the
> **SPECIFIED** side. `afterSwap` cannot touch the specified side. Therefore you need
> `BEFORE_SWAP + BEFORE_SWAP_RETURNS_DELTA` as well — `beforeSwap` is the only place a hook can
> take the specified currency.

**Decide what currency the fee must land in FIRST. The flags fall out of that.** Getting this
backwards means a rewrite, not a patch.

### The `beforeSwap` delta arithmetic

`Hooks.sol:275` does `amountToSwap += hookDeltaSpecified`. With `amountSpecified = -1000` and a
hook return of `+30`, the curve swaps 970 and the trader still pays 1000. The 30 never reaches the
pool. So a positive specified-delta takes the fee **out of** the input.

`afterSwap`'s `int128` lands in the **unspecified** slot and is charged **on top**
(`paid == consumed + fee`). Two different economics from the same-looking number.

**`Hooks.noSelfCall` really does skip a hook's own callbacks** (`Hooks.sol:253`, `:293`), so a hook
swapping its own pool is untaxed and cannot recurse. Verified in the installed source.

---

## 3. Fee in the hook vs fee in the token

| | fee in the token (`_transfer` tax) | fee in the hook |
|---|---|---|
| wallet-to-wallet transfers | taxed, which users hate | untaxed — only swaps pay |
| DEX aggregator compatibility | frequently breaks | fine |
| what `PoolKey.fee` reports | n/a | **`0`** |
| LP incentive | LPs earn the pool fee | **LPs earn nothing** |

**Two consequences that catch everyone:**

1. **Every indexer will report your trading fee as 0%.** Dexscreener, DeFiLlama, everything reads
   `PoolKey.fee`. Emit a `PoolConfigured` event with the real rate and make your own UI read that,
   never the pool. Plan for third-party sites being wrong about you, permanently.
2. **Fee-in-hook kills JIT-liquidity MEV for free.** With `PoolKey.fee = 0` and the hook taking
   everything, an LP earns nothing, so there is no JIT sandwich to run. Underrated benefit.

**Do not make the platform's cut a share of the fee. Make it a flat share of VOLUME.** That single
choice is what makes wash trading provably lossy — measured at **-4.9750 pair on 500** even for a
creator who is also the sole holder at the maximum fee rate. Share-of-fee lets an attacker recycle
their own fee back to themselves.

> **The trap it creates:** if `platformShareBps` is derived as `PLATFORM_VOLUME_BPS * BPS / feeBps`,
> then at `feeBps == PLATFORM_VOLUME_BPS` the platform takes **100%** and creator + holders get
> exactly zero, silently. Reject `feeBps <= PLATFORM_VOLUME_BPS` at configure time.

---

## 4. THE 8.5x — settlement ordering is load-bearing

**The single most expensive lesson in this repo.**

If a hook moves real ERC-20 out of the singleton during `afterSwap` (e.g. `take()` for an
auto-sweep), and a router does this:

```solidity
poolManager.sync(currency);              // snapshot
token.transferFrom(payer, manager, n);   // prepay
poolManager.swap(...);                   // ← hook takes ERC-20 out HERE
poolManager.settle();                    // credits balanceOfSelf() - syncedReserves
```

…then everything the hook removed between `sync` and `settle` is **silently deducted from what the
payer is credited**. Measured on an identical trade: true cost **0.4005 pair**, sync-first cost
**3.4122 pair** — **8.5x**. When the hook's backlog exceeds the prepay it instead underflows to a
bare panic `0x11`.

`sync -> transfer -> swap -> settle` is perfectly legal v4 and is exactly what you write if you
want to "pay once up front."

### The rules

1. **Swap FIRST. Settle afterwards, from the resulting deltas.** This is what Uniswap's own routers
   do and it is the only ordering safe against a hook like this.
2. **Read the deltas from the manager, not from the returned `BalanceDelta`.** Use
   `TransientStateLibrary.currencyDelta(manager, address(this), currency)`. Those three numbers
   *are* the settlement; anything you infer is an assumption.
3. **Check `settle()`'s return value.** It returns what it credited:
   ```solidity
   uint256 credited = poolManager.settle();
   if (credited != owed) revert SettlementShortfall(owed, credited);
   ```
   Three lines. Converts the entire failure class from a silent overcharge into a named revert,
   forever. **Do this in every router you ever write.**
4. **Keep each `sync → transfer → settle` contiguous.** Nothing between them.
5. **Native ether is immune** — `_settle` reads `msg.value` and never touches `balanceOfSelf`. Only
   the ERC-20 path is exposed.

### The design conclusion

If a hook never moves ERC-20 mid-swap, the bug cannot exist for anyone. **Take fees as ERC-6909
claims (`mint`) inside the swap and redeem them later in a separate transaction (`burn` + `take`).**
That is strictly safer than `take()`-ing during `afterSwap`, and on a single-sided pool it is
mandatory anyway — see §5.

---

## 5. Single-sided seeding

Seed the entire supply in ONE position starting at the opening tick, with zero pair currency.

**Why it costs exactly zero pair currency**, verified over a 1,000-run unconditional fuzz across
supplies, market caps, six tick spacings and both orderings: `_openingTick` rounds **UP** for
currency0 and **DOWN** for currency1, so the initial tick IS the position boundary, and at
`tick == tickLower` the amount math computes with two identical prices — exactly zero, not
"rounds to zero."

### The closed form, and it drives all your economics

With `L * sqrt(P_a) == M` (M = opening market cap in pair units):

| quantity | formula |
|---|---|
| pair cost of a fraction `f` of supply | `M*f / (1-f)` |
| spot market cap after buying `f` | `M / (1-f)²` |
| **opening market cap in pair units** | **exactly `pairSeed`** |
| **cost of half the supply** | **exactly the opening market cap** |
| round trip | returns the input **to the wei** |

**The only unrecoverable cost of any round trip is `feeBps`.** The opening tick is a hard floor
with nothing below it, so a buy-then-sell recovers everything else.

### Two consequences you must design for

1. **`poolManager.take()` needs the singleton to actually hold the ERC-20.** A single-sided pool
   holds no pair currency until someone buys. So fees **must** accrue as ERC-6909 claims and be
   redeemed later. This is not an optimisation; `take` reverts otherwise.
2. **The open is a free option, and this is inherent.** Downside capped at `feeBps` by the floor,
   upside unbounded. Measured here: **-3.00 downside, +157.21 upside**, a 50:1 option, with organic
   buyers losing **154.82 of 200**. A dev buy does **not** defend it — the sniper pays 196.71% of
   the creator's average price.

> **Framing worth reusing:** the opening market cap is the strike price of a call option on the
> entire supply, exercisable by the first transaction, with a premium equal to the trading fee.
>
> If you don't want that, you cannot open single-sided at a creator-chosen tick. Options are a
> decaying opening fee, a first-block buy cap, or a real bonding curve. Pick deliberately; there is
> no version where it is free.

---

## 6. Dividends: paying holders in a foreign asset

### The accumulator

`magnifiedPayoutPerShare` **is** the Synthetix `StakingRewards` accumulator. `_corrections` ==
`userRewardPerTokenPaid`, `withdrawableOf` == `earned`. Do not invent one.

The only real choice is what advances it:
- advanced by an **EVENT** (a lump credited on distribute) → instantly claimable
- advanced by the **CLOCK** (`rewardPerTokenStored += elapsed * rate / totalSupply`) → streams

### Stream it. This is not optional.

**Instant credit is exploitable and it is not subtle.** `buy → trigger distribution → sell →
withdraw` in one transaction. Measured before the fix: **+4.8738 pair (+12.18% ROI), 40.11% of the
pot, honest resting holder lost 83.28%**. It works because a memecoin pot is built by TURNOVER
while the register holds only the resting float.

After a 24h linear stream: **-1.1332 pair**, and the honest holder ends **9.88% ahead** — the
attacker's own buy fee vests to her, so the attack becomes a donation.

### Streaming implementation notes

- **Pre-magnify the rate.** Store `rateMagnifiedPerSecond`, not `total / window`. Unmagnified, a
  `distribute(50_000)` on a 6-decimal pair gives `rate == 0` and nothing ever vests.
- **Advance the accrual losslessly too.** Magnifying the rate but re-truncating in `_checkpoint`
  loses **28%** of a small stream on a 6-decimal pair, because a token calling `setBalance` twice
  per transfer produces ~7,200 checkpoints per window. Carry the sub-unit remainder.
- **Pause the clock when `totalShares == 0`**, don't advance `lastUpdateTime` regardless — that is
  a known Synthetix defect that strands rewards.
- **Weighted-average re-lock on top-up** (Yearn v3 style) so a dust `distribute` can't extend the
  window. Verified: 200 repeated 1-wei distributions moved `streamFinish` by **0 seconds**.
- **Keep a minimum-shares guard.** Dividing a fee by a 1-wei holder inflates the accumulator until
  `mps * delta` overflows and **every transfer reverts for everyone** — observed as a live panic
  `0x11`. Yearn v3.1.0 independently rediscovered the same guard as `MINIMUM_SUPPLY = 1e3`.

### Push vs pull

Support both, but **the pull path is the one that has to work**. A push queue that walks holders
will, eventually:
- be called by nobody (if nothing in `src/` calls it, it never advances — check this, it is easy
  to ship a queue that is decorative);
- hit an address that reverts. Read entitlement *inside* the per-holder `try/catch`, never before
  the loop, or one bad holder takes the whole batch down.

**Reward != payout.** If you let a creator choose a reward asset different from the pair currency,
you need a converter, and the converter is the sharpest edge in the whole system. Two separate
bugs were found there:
1. treating a **zero return** as failure and paying the fallback too → **double pay**, one
   withdrawal drains the contract;
2. judging success by the distributor's **balance delta**, which a re-entrant converter can cause
   without taking anything → holder debited, paid nothing.

**Judge conversion success by ALLOWANCE CONSUMPTION** (`amount - allowance(this, converter)`), and
put a reentrancy guard on the withdrawal paths.

---

## 7. Deploy choreography

### Circular immutables

`Hook.launcher` and `Launcher.hook` are both immutable and each needs the other, and the hook's
address is **mined** with a salt that depends on its constructor args. Order:

```
1. predict the Launcher's CREATE address (deployer + nonce)
2. mine the hook salt against that predicted address
3. deploy the hook
4. deploy the Launcher into the reserved slot   ← nonce must not have moved
```

Anything that consumes a nonce between 1 and 4 breaks it.

### Deploy dependents BEFORE the thing that points at them

If the hook takes `platformRecipient` as an immutable and you deploy the recipient vault *after*
the hook, the vault is **orphaned for that hook's entire life** and can never be paid. Since the
hook address is mined anyway, deploy the vault first and mine against it.

**General rule: any address stored as `immutable` must exist before the contract storing it.**

### Verify after deploying

- `eth_getCode` at every address. A deploy log says a transaction was sent, not that code is there.
- Call one read on each and check the answer (`poolManager()`, `isApproved()`).
- Include a **negative control** — assert that something which should be rejected *is* rejected.
  "Registry returns true for our token" is much weaker than that plus "returns false for a token
  we never added."
- Diff the deployed bytecode against the current `src/`. Deployments drift; this repo had a live
  `Distributor` whose `streamFinish` getter didn't exist.

---

## 8. Foundry setup

```toml
solc_version = "0.8.26"   # pinned: v4-core declares an EXACT pragma, not a caret range
via_ir = true             # hooks + launchers are stack-too-deep without it
optimizer_runs = 200      # LOW on L1: EIP-170's 24,576-byte limit stands. Low runs = smaller code
evm_version = "cancun"    # v4 needs EIP-1153 transient storage; nothing needs more
bytecode_hash = "none"    # deterministic CREATE2: a comment change must not move a mined salt
cbor_metadata = false
```

- `forge coverage` needs `--ir-minimum` (the launcher is stack-too-deep otherwise).
- Launch params must be `memory`, not `calldata`, at the stack ceiling. `yulDetails.stackAllocation`
  does **not** help, and adding its TOML section silently swallowed `remappings`.
- A clean `via_ir` build is **5-25 minutes**. Batch edits. Piping `forge build` to a pager can hang.

---

## 9. Testing discipline

**These are the rules that actually caught bugs.**

1. **Run every suite in BOTH currency orderings.** Which side the launch token sorts onto flips the
   sign of every delta and the direction of every swap. A hook that works in one and silently
   no-ops in the other is the most expensive kind of passing suite. Use paired concrete subclasses
   over one abstract harness.
2. **Test all four swap shapes.** exact-in/exact-out × buy/sell. The very first bug found here was
   *exact-input buys collected zero fees* — the shape every router sends by default. The pool
   worked; revenue silently didn't.
3. **`vm.warp(block.timestamp + n)` chained or in a loop is a NO-OP under `via_ir`.** solc hoists
   `TIMESTAMP` as loop-invariant within a call frame. This produced two completely fabricated
   findings, one of which read as "value creation, 101x the pot, catastrophically insolvent." Use
   forge-std `skip(n)` or `vm.getBlockTimestamp()`. Handler-based invariant warps are safe (separate
   frame).
4. **Hunt vacuous passes.** `assertGt(x.balanceOf(a), 0)` is a trap in any harness that funds actors
   in `setUp` — **measure deltas**. Every `expectRevert` needs a positive precondition beside it
   (`assertGt(owed, 0)`). Eight vacuous passes were found here; each was proved with a **negative
   control** — deliberately break the property, confirm the test goes red.
5. **Build the production pool shape in tests.** A symmetric full-range 1:1 pool hides everything.
   Adding a single-sided builder is what exposed the highest-severity finding in two separate
   audits. Better still, drive the **real launcher**.
6. **Check what a fuzz bound EXCLUDES.** A burn fuzz bounded to 5000 is exactly why `burnBps=10000`
   was never reached — and at 10000 the pool pays creator, platform and holders all zero.
7. **When you fix a finding, INVERT its test** to `test_fixed_*` with the measured before/after in
   the docstring. Never delete it. Capture the pre-fix failure output first — it is your negative
   control and you cannot re-derive it afterwards.
8. `vm.expectRevert(X.selector)` does not selector-only match against a wrapped/bubbled error — use
   `vm.expectPartialRevert`. ERC-7751 `WrappedError` defeats both.
9. **`runs: 0`** in fuzz output means a cached counterexample is replaying. Clear `cache/fuzz` and
   `cache/invariant`.

---

## 10. Frontend / EVM interaction

- **`PoolId` is `keccak256(abi.encode(poolKey))`.** Every field is static, so it encodes exactly.
- **The pool key must match EXACTLY** — every field including `fee` and `tickSpacing`. One wrong
  field gives `PoolNotInitialized` for a pool that is plainly trading. Build the key in **one**
  function and import it everywhere; a test that rebuilds it is testing itself.
- **`PoolKey.fee` is NOT the fee anybody pays on mainnet pools.** A protocol fee is switched on for
  several; the real rate is `pf + lp - pf*lp/1e6` read from `slot0` bits `[184,208)`. Using
  `PoolKey.fee` produced a systematic **1.2 bps** error on every pair, invisibly.
- **`allowFailure: true` on multicall, and type every field nullable.** Deployments drift from
  source; one missing getter must not blank a whole panel. A value that cannot be read renders `—`,
  **never `0`**.
- **Quote by reverting.** A `quoteX` that always `revert QuoteResult(amount)` after the swaps and
  before settlement needs no balance and no approval, and makes a zero-slippage-floor swap
  structurally unreachable. This is what Uniswap's own Quoter does.
- **Struct field order is load-bearing and the compiler cannot help you.** Solidity encodes
  positionally, so a wrong slot doesn't fail — it succeeds with `feeBps` read as `sellFeeBps`. The
  ABI must change in the same commit as the struct.
- **viem `parseAbi` tuple params need NAMED components** or you must pass an array. An unnamed
  signature turns an object into `Address "undefined" is invalid` at encode time.
- **v2/v3 liquidity is unreachable from the v4 singleton.** "This pair has $17M on v3" says nothing
  about whether a v4 route exists. Measure v4 depth directly — here only **11 of 38** pairs could
  actually take an ETH buyer.
- **Never put a secret in a `VITE_` variable.** They are inlined into the bundle at build time and
  ship to every visitor. Pin/upload keys belong on a server route.

---

## 11. Trap table

| Trap | Consequence |
|---|---|
| `sync → transfer → swap → settle` | **8.5x silent overcharge** |
| `take()` inside `afterSwap` | breaks settlement for every sync-first integrator |
| `take()` on a single-sided pool | reverts — the singleton holds none of that currency |
| instant dividend credit | buy/trigger/sell/withdraw drains ~40% of the pot |
| unmagnified stream rate | rate truncates to 0 on low-decimal pairs; nothing vests |
| `PoolKey.fee` as the trading fee | every indexer reports 0%; your own math is 1.2 bps off |
| `amountSpecified` sign | **inverted from v3** — negative is exact-input |
| `-int256(amountIn)` unbounded | ≥ 2²⁵⁵ flips exact-input into exact-**output** |
| leftover positive delta | `unlock` reverts — sign-agnostic |
| `vm.warp(block.timestamp + n)` in a loop | no-op under via-ir; fabricated test results |
| fuzz bound hiding an edge | the illegal config is never reached |
| immutable pointing at a later deploy | orphaned contract, unreachable for its whole life |
| refunding `address(this).balance` | pays out forced ether; one wei bricks contract callers |
| `<button>` inside `<label>` | click forwarded to the labelled control |
| `VITE_` secret | shipped to every visitor in the JS bundle |

---

## 12. If you build another one

**Do the same:** fee in the hook; platform cut as a flat share of volume; single-sided seed; LP
locked by having no removal path rather than by burning an NFT; ERC-6909 claims for fees; streamed
dividends; both currency orderings in every test; address-allowlist your pair currencies because
tickers are not identity.

**Do differently:**
- **Decide the opening mechanism before writing anything.** Single-sided at a chosen tick means a
  free option on block 0. Own it or choose another opening.
- **Never move ERC-20 out of the singleton mid-swap.** Claims in, redeem later, always.
- **Put `minOut` on every internal swap** the protocol makes on its own behalf. A sweep or buyback
  with a tick-extreme price limit is public, predictable and sandwichable.
- **Wire the push path or delete it.** A queue nothing calls is worse than no queue, because the
  docs claim it works.
- **Derive the platform's share of a SELL fee from the sell rate**, not the buy rate.
- **Answer the securities question before writing the dividend code**, not after. A token paying
  passive yield in a third asset is a different legal object from a memecoin, and no amount of
  Solidity changes that.
