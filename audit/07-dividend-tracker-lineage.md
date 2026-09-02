# 07 — The BSC/ETH `DividendPayingToken` + `DividendTracker` lineage: does it stop instant dividend capture?

Read-only research. **No file under `src/` or `test/` was touched.** This document exists to answer
one question raised by audit `05-economics.md` finding **E-03 (CRITICAL)**: our permissionless
`sweep()` lets an attacker run `buy -> trigger -> sell -> withdraw` in a single transaction for
+12.18% ROI while an honest resting holder loses 83.28% of her dividend. The question was whether
the thousands-strong reflection/dividend-token lineage that uses the *same* accumulator
(`magnifiedDividendPerShare` / `magnifiedDividendCorrections` / `accumulativeDividendOf`) already
solved this, so that we could copy a proven defence instead of inventing one.

---

## 0. The answer, up front

> **Can an attacker buy immediately before a distribution and sell immediately after, capturing
> dividends they did not earn?**
>
> ### YES. In the classic lineage it works, and in the canonical BSC implementation the attacker is
> ### *paid out in the very same transaction as the sell*, with zero blocks held.
>
> **Does any mechanism in that lineage prevent it?**
>
> ### NO. Not one. `claimWait`, `lastClaimTimes`, `canAutoClaim`, `minimumTokenBalanceForDividends`,
> ### `gasForProcessing` and `process(gas)` are, without exception, **gas-budget and push-cadence
> ### devices**. Every one of them governs *when the contract pushes money at you*. Not one of them
> ### touches *whether you are owed money*. Entitlement is a pure function of your balance at the
> ### instant `magnifiedDividendPerShare` moves, and that instant can be chosen by a trader.

**The lineage does not solve instant capture. It has never solved it. There is nothing here to
copy as a fix.** That is a valid and useful answer: it means E-03 must be fixed with a mechanism
that this family of contracts does not contain, and we should stop looking for a battle-tested
drop-in.

---

## 1. What I read, where it came from, and how I got it

Five artefacts. Two are the actual code of the lineage; two are live production deployments read
out of a block explorer and confirmed against chain state; one is a modern 2024/2025 descendant.

### 1.1 The root of the lineage — EIP-1726 draft reference implementation

| | |
|---|---|
| Contract | `DividendPayingToken` (Solidity `^0.5.0`) |
| Author | Roger Wu — the implementation every fork cites in its own comments |
| Source | `https://raw.githubusercontent.com/Roger-Wu/erc1726-dividend-paying-token/master/contracts/DividendPayingToken.sol` |
| Method | direct HTTPS fetch of the raw blob (no explorer needed) |
| Provenance note | its own header cites PoWH3D `0xB3775fB83F7D12A36E0475aBdD1FCA35c091efBe` as *its* reference |

This is the ancestor. The `magnifiedDividendCorrections` comment block in this file is reproduced
**verbatim, whitespace and all**, in every fork I pulled below — that is how the lineage is
identified.

### 1.2 The canonical live BSC deployment (classic `DividendTracker`)

| | |
|---|---|
| Token | **`0x0938a5d325A8496c186Cf122946e9dD22f8a625b`** — "Digital Files", contract name `DividentToken` |
| Explorer | `https://bscscan.com/address/0x0938a5d325a8496c186cf122946e9dd22f8a625b#code` |
| Compiler | `v0.8.17+commit.8df45f5f`, optimizer on, 200 runs, "Source Code Verified — Exact Match" |
| Tracker | **`0x6B1b15448af5F5ed253259bA9D94Fd5243Bd0DFA`** (EIP-1167 clone, `owner()` == the token) |
| Reward token | `0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56` (BUSD) |
| Size pulled | 109,552 chars / 3,397 lines, full flattened source |

This is a PinkSale-family "BABYTOKEN" factory deployment — i.e. the exact template that thousands
of BSC/ETH dividend tokens were minted from. It contains `DividendPayingToken`, `IterableMapping`,
`DividendTracker` and the taxed `_transfer` hook, all in one file. **All line numbers quoted in
this document refer to this file** unless stated otherwise.

**How I got the source (BscScan's viewer is virtualised — this is the workaround that works):**
BscScan renders verified source in a **Monaco** editor. `innerText` on the visible pane returns
only the ~26 rendered lines, and scrolling is unreliable. But Monaco keeps the *entire* file in an
in-memory text model. So, driving the user's real Chrome through `playwriter`:

```js
// after page.goto('https://bscscan.com/address/<addr>#code') and a settle wait
const sources = await page.evaluate(() =>
  window.monaco.editor.getModels().map(m => m.getValue())
);
```

That returns every byte of the file regardless of what is painted. For **multi-file** verifications
only the *active* file has a model, so each entry in the EXPLORER pane must be clicked first —
clicking by text from inside `page.evaluate` (element handles go stale after the first click):

```js
await page.evaluate((name) => {
  const el = Array.from(document.querySelectorAll('span,a,li,div'))
    .find(e => e.children.length === 0 && e.textContent.trim() === name);
  (el.closest('a,li,button,div[role]') || el).click();
}, 'TokenDividendTracker.sol');
```

**Routes that did NOT work, so nobody re-tries them:** `api.bscscan.com` V1 is retired ("You are
using a deprecated V1 endpoint"); Etherscan V2 `getsourcecode` requires a key and we have none
(`contracts/.env` holds only a private key and two RPC URLs); `sourcify.dev/server` 403s;
there is no public Blockscout instance for BSC (`bsc.blockscout.com` 404s);
`tintinweb/smart-contract-sanctuary-bsc` exists but does not contain these addresses, and its
per-prefix directories are capped at 1,000 entries by the GitHub contents API while the trees API
route burns the 60/hour unauthenticated rate limit.

**Live state, read with `cast` against `https://bsc-dataseed.binance.org` — measured, not assumed:**

```
name()                              "Digital Files"
getClaimWait()                      3600            (1 hour)
dividendTracker()                   0x6B1b15448af5F5ed253259bA9D94Fd5243Bd0DFA
gasForProcessing()                  300000
rewardToken()                       0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56  (BUSD)
swapTokensAtAmount()                2000e18
balanceOf(token)                    324.291e18      (currently below the trigger)
tracker.claimWait()                 3600
tracker.minimumTokenBalanceForDividends()   5000e18
tracker.owner()                     0x0938a5d3...  == the token
```

### 1.3 The second major family — `DividendDistributor` (live BSC)

| | |
|---|---|
| Token | **`0xC001BBe2B87079294C63EcE98BdD0a88D761434e`** — EverGrow Coin (EGC) |
| Explorer | `https://bscscan.com/address/0xC001BBe2B87079294C63EcE98BdD0a88D761434e#code` |
| Compiler | `v0.8.0+commit.c7dfd78e`, "Source Code Verified", submitted 2021-09-16 |
| Size pulled | 27,739 chars / 782 lines |

Different names (`setShare` / `deposit` / `shouldDistribute` / `minPeriod` / `minDistribution`),
**identical mathematics** (`dividendsPerShare += ACCURACY * amount / totalShares`). Included
because if either family had solved the problem it would be this one — it is the family that
actually has a variable literally named `minPeriod`. It has not solved it either.

### 1.4 A 2024/2025 descendant — has the lineage improved?

| | |
|---|---|
| Contract | **`0x33dac2f91d5872f4e3802053b1d802f41fda54ef`** on Base, `DividendTracker` |
| Explorer | `https://basescan.org/address/0x33dac2f91d5872f4e3802053b1d802f41fda54ef#code` |
| Compiler | `v0.8.25+commit.b61c2a91`, paris EVM, multi-file (`TokenDividendTracker.sol` pulled) |
| Size pulled | 19,248 chars / 633 lines |

Modernised: custom errors, `Ownable2Step`, `SafeERC20`, no SafeMath. Same accumulator. Its
verdict is in §6 and it is **worse than the 2021 original in the way that matters to us.**

### 1.5 Secondary — incident reports (clearly labelled as such)

- `https://anomly.rs/lista-flap-dividend-drain` and `/poc` — a writeup of a BSC drain of the
  Flap/ListaDAO dividend contract `0x500c66c836e7D5dd071234c1445A02F5A8304a95`, which uses this
  exact accumulator behind a **permissionless `deposit()`**. Includes a Foundry PoC.
- `https://blocksec.com/blog/reflecting-on-reflection-tokens-a-security-perspective` — BlockSec's
  survey of rekt reflection tokens.

**Caveat I am holding to:** I read these reports; I did **not** independently replay the
transaction on a fork in this session. The *code pattern* they quote I did verify against source I
pulled myself. Treat their numbers as reported, not as measured by me.

---

## 2. The proof, traced line by line

### Step 0 — entitlement contains no time term at all

```solidity
// DividendTracker (BSC 0x0938a5d3), lines 2380-2389
function accumulativeDividendOf(address _owner) public view override returns (uint256) {
    return magnifiedDividendPerShare
        .mul(balanceOf(_owner))            // <-- balance NOW. no timestamp. no snapshot.
        .toInt256Safe()
        .add(magnifiedDividendCorrections[_owner])
        .toUint256Safe() / magnitude;
}
```

Identical to Roger Wu's 2019 original. There is **no `block.timestamp`, no `block.number`, no
snapshot id, no accrual duration** anywhere in the accumulator, in any of the four contracts I
read. The whole entitlement is `perShare * balanceNow + correction`.

```solidity
// lines 2302-2313 — the distribution
function distributeCAKEDividends(uint256 amount) public onlyOwner {
    require(totalSupply() > 0);
    if (amount > 0) {
        magnifiedDividendPerShare = magnifiedDividendPerShare.add(
            (amount).mul(magnitude) / totalSupply()      // <-- pro-rata against the register AT THIS INSTANT
        );
        ...
    }
}
```

Note `totalSupply()` here is the **tracker's** supply — the sum of registered holder balances, not
the token's supply. That is the resting-float denominator. It is exactly the shape that makes our
own E-03 measurement (attacker takes 40.11% of the pot; honest holder loses 83.28%) possible: a
memecoin's pot is built by turnover, but it is divided among whoever is resting.

### Step 1 — the buy makes you a full-weight shareholder in the same transaction

```solidity
// DividentToken._transfer, lines 3200-3205
super._transfer(from, to, amount);

try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {}
try dividendTracker.setBalance(payable(to),   balanceOf(to))   {} catch {}
```

```solidity
// DividendTracker.setBalance, lines 2622-2637
function setBalance(address payable account, uint256 newBalance) external onlyOwner {
    if (excludedFromDividends[account]) { return; }
    if (newBalance >= minimumTokenBalanceForDividends) {
        _setBalance(account, newBalance);          // mint tracker shares
        tokenHoldersMap.set(account, newBalance);  // enter the round-robin register
    } else {
        _setBalance(account, 0);
        tokenHoldersMap.remove(account);
    }
    processAccount(account, true);                 // <-- see Step 3
}
```

A buyer who clears `minimumTokenBalanceForDividends` (live: 5,000e18) is a full-weight shareholder
**in the transaction that bought**. There is no queue, no waiting period, no partial weighting.
The AMM pair itself is `excludedFromDividends`, so tokens leaving the pool go from
non-participating to fully participating in one hop.

### Step 2 — the sell fires the distribution BEFORE it reduces the seller's balance

This is the load-bearing ordering bug, and it is right there in `_transfer`:

```solidity
// DividentToken._transfer, lines 3147-3205, in execution order
3147:  uint256 contractTokenBalance = balanceOf(address(this));
3149:  bool canSwap = contractTokenBalance >= swapTokensAtAmount;
3151:  if (canSwap && !swapping
3154:      && !automatedMarketMakerPairs[from]        // <-- a BUY can never trigger this
3155:      && from != owner() && to != owner() && totalFees > 0) {
3159:      swapping = true;
...
3177:      if (sellTokens > 0) { swapAndSendDividends(sellTokens); }   // ==> distributeCAKEDividends
3180:      swapping = false;
3181:  }
...
3197:  super._transfer(from, address(this), fees);   // fee leg
3200:  super._transfer(from, to, amount);            // <-- the seller's balance drops HERE
3203:  dividendTracker.setBalance(from, balanceOf(from));   // <-- register updated HERE
```

```solidity
// lines 3384-3395
function swapAndSendDividends(uint256 tokens) private {
    swapTokensForCake(tokens);
    uint256 dividends = IERC20(rewardToken).balanceOf(address(this));
    bool success = IERC20(rewardToken).transfer(address(dividendTracker), dividends);
    if (success) {
        dividendTracker.distributeCAKEDividends(dividends);   // perShare += ...
        emit SendDividends(tokens, dividends);
    }
}
```

`magnifiedDividendPerShare` is bumped at line 3177. The seller's tokens do not move until line
3200 and the register is not updated until line 3203. **The attacker is credited pro-rata for the
entire pot while still holding the position they are in the act of selling.** And when line 3203
does zero them out, `_setBalance -> _burn` writes a *matching positive correction* into
`magnifiedDividendCorrections` (lines 2429-2435) — which is the whole point of the correction term:
it deliberately preserves the entitlement across the balance change. Selling does not forfeit it.
Selling *locks it in*.

### Step 3 — and then the same call pays them, immediately

```solidity
// line 2636, the last statement of setBalance:
    processAccount(account, true);
```

```solidity
// lines 2686-2699
function processAccount(address payable account, bool automatic) public onlyOwner returns (bool) {
    uint256 amount = _withdrawDividendOfUser(account);      // <-- sends the reward token NOW
    if (amount > 0) {
        lastClaimTimes[account] = block.timestamp;
        emit Claim(account, amount, automatic);
        return true;
    }
    return false;
}
```

**`canAutoClaim` is not consulted here.** `setBalance` force-claims unconditionally. So the
attacker's *sell transaction* mints the distribution, credits them for it, zeroes their shares,
and wires them the BUSD — in that order, in one call, in one block.

Exhaustive grep of the 3,397-line file, so this is not an inference:

```
canAutoClaim   ->  2614 (definition), 2664 (the ONLY call site: inside process())
processAccount ->  2636 (setBalance, UNGATED)
                   2665 (process(), the one gated site)
                   2686 (definition)
                   3123 (token.claim(), UNGATED)
lastClaimTimes ->  2460 (declaration), 2580 (a view), 2664 (read by process), 2693 (written)
```

Two of the three ways to get paid do not look at `claimWait` at all:

```solidity
// DividentToken, lines 3122-3124 — a public, permissionless, ungated claim
function claim() external {
    dividendTracker.processAccount(payable(msg.sender), false);
}
```

### Step 4 — the whole attack, in one transaction

An attacker contract, in a single `tx`:

1. Read `balanceOf(token)` and `swapTokensAtAmount` — both public. Wait until the fee accumulator
   is over the line (or trade it over yourself).
2. **Buy** through the router. `from` is the pair, so the swap block at 3151 is skipped and no
   distribution happens. Line 3205 registers the attacker as a shareholder. `processAccount`
   returns false (nothing owed yet), so `lastClaimTimes[attacker]` **stays 0**.
3. **Sell** through the router. `from` is the attacker, not a pair, so the swap block fires:
   `swapAndSendDividends` -> `distributeCAKEDividends` -> attacker credited at full weight
   (line 3177) -> attacker's tokens move (3200) -> `setBalance(attacker, 0)` (3203) -> shares burned,
   correction written, **`processAccount` pays out** (2636).
4. Done. Cost: the buy fee, the sell fee, slippage on a fully-recoverable round trip. Blocks held:
   zero.

Honest holders resting in `tokenHoldersMap` split whatever is left, exactly as our own E-03
harness measured.

---

## 3. So what does each knob *actually* do?

| Knob | Live value | What it gates | What it does **not** gate |
|---|---|---|---|
| `claimWait` | 3600 s | Appears in exactly 3 places: `updateClaimWait` (2511), the `getAccount` view (2582), and `canAutoClaim` (2619). `canAutoClaim` has **one** call site: line 2664, inside `process()`. So `claimWait` decides **only whether the round-robin push loop bothers to push to you this pass.** It is a re-push cadence limiter, i.e. a gas-waste guard. | Accrual. `claim()` (3123). The `setBalance` force-claim (2636). Anything to do with entitlement. |
| `lastClaimTimes` | mapping | Written at 2693, and **only when `amount > 0`**. Read at 2664 and in a view. | A brand-new holder has `lastClaimTimes == 0`, so `canAutoClaim(0)` evaluates `block.timestamp - 0 >= 3600`, which is TRUE on any live chain. **A first-time buyer is auto-claim-eligible on their first block.** `claimWait` does not even delay the *push* for a new entrant — only for someone already paid once. |
| `minimumTokenBalanceForDividends` | 5,000e18 | A **size** floor, evaluated at the instant `setBalance` runs (2629). Its purpose is to keep dust out of `tokenHoldersMap` so `process()` does not burn gas iterating worthless entries. | Time, in any form. Buying past the floor in one transaction clears it in that transaction. Worse: because dust is *excluded from the denominator*, raising it **concentrates** the pot on whoever is registered — it improves the attacker's take. |
| `gasForProcessing` / `process(gas)` | 300,000 | A bounded round-robin push cursor (2639-2684): advance `lastProcessedIndex`, push to anyone `canAutoClaim`, stop when the gas budget is spent. Pure unbounded-iteration / DoS mitigation. Decides **who gets pushed, and where the cursor stops.** | Who is **owed**. `process` cannot create or destroy an entitlement; it only settles ones that already exist. |
| `excludedFromDividends` | — | Removes an address from the register and burns its shares (2495-2503). Used for the pair, the router, the token itself, the owner. | Nothing time-related. It is a correctness device (stop the pool from earning its own fees) — the same job as our Distributor's `setExcluded`. |

**Summary in one line: the entire "protection" surface of this lineage is a gas budget.** Someone
wrote a `while` loop that could run out of gas, and everything named `claimWait` /
`gasForProcessing` / `minimumTokenBalanceForDividends` exists to bound that loop. None of it was
ever an economic control, and reading `getAccount`'s friendly `secondsUntilAutoClaimAvailable`
field is what makes people believe otherwise.

---

## 4. Is distribution caller-timeable in that lineage? — the key difference from us

**In the 2021 classic: yes, but it is coupled to a real trade rather than exposed as a bare
function.** This is the single genuine structural difference between the lineage and hoodstonk.

There is no `sweep()`. Distribution is a **side effect of `_transfer` crossing a threshold**, and
that path is guarded at lines 3151-3158 by:

```
canSwap                              balanceOf(token) >= swapTokensAtAmount    (public state)
&& !swapping                         reentrancy latch
&& !automatedMarketMakerPairs[from]  a BUY can never trigger it
&& from != owner() && to != owner()
&& totalFees > 0
```

EverGrow's family has the mirror condition:

```solidity
// EverGrow 0xC001BBe2, lines 594-599
function shouldSwapBack() internal view returns (bool) {
    return msg.sender != pair            // <-- same idea: a buy leg cannot fire it
        && !inSwap && swapEnabled
        && _balances[address(this)] >= swapThreshold;
}
```

What this buys them, and what it does not:

- **It does not stop the attacker from choosing the instant.** Every input is public. The attacker
  reads the accumulator, waits for (or forces) the threshold, then buys and sells. Their own sell
  *is* the trigger.
- **It does remove the free option.** They cannot fire a distribution without holding a real
  position and paying real trading fees and slippage on a real round trip. There is no way to poke
  the contract from the outside for free.
- **Because buys cannot trigger it, the attacker must already be holding when they fire.** That is
  not a defence — it is precisely the condition that makes the attack work.

**Our `sweep()` is strictly worse than the classic**, on two counts: it is callable with no
position at all, and `SWEEP_BOUNTY_BPS = 50` pays the caller *for triggering it*. We have taken a
mechanism that at least cost the attacker a fee and turned triggering into a subsidised action.

**And the modern fork is worse than both, i.e. it is exactly our shape.** On the 2024 Base
descendant:

```solidity
// TokenDividendTracker.sol (Base 0x33dac2f9), lines 220-236
function distributeDividends(uint256 amount) public {          // <-- public. NO onlyOwner. NO modifier.
    if (totalSupply() == 0) revert DividendTrackerNoEligibleAddresses();
    uint256 balBefore = IERC20(rewardToken).balanceOf(address(this));
    IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
    uint256 received = IERC20(rewardToken).balanceOf(address(this)) - balBefore;
    if (received > 0) {
        magnifiedDividendPerShare = magnifiedDividendPerShare + (received * magnitude / totalSupply());
        ...
    }
}
```

Anyone, at any instant, for any amount. A bare permissionless distribution trigger, shipped in
production in 2024/2025. This is the shape that got the Flap/Lista dividend contract drained
(§1.5): buy the token (pool excluded, so you are instantly a shareholder), call the permissionless
`deposit()`/`distributeDividends()` yourself, convert the manufactured entitlement, sell back.

---

## 5. Cross-check: the second family fails the same way

EverGrow's `DividendDistributor` is a fully independent implementation. Same outcome:

```solidity
// lines 290-304
function setShare(address shareholder, uint256 amount) external override onlyToken {
    if (shares[shareholder].amount > 0) {
        distributeDividend(shareholder);        // <-- pays FIRST, ungated by minPeriod
    }
    ...
    totalShares = totalShares.sub(shares[shareholder].amount).add(amount);
    shares[shareholder].amount = amount;
    shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
}

// lines 352-355 — minPeriod lives HERE and only here
function shouldDistribute(address shareholder) internal view returns (bool) {
    return shareholderClaims[shareholder] + minPeriod < block.timestamp
        && getUnpaidEarnings(shareholder) > minDistribution;
}
```

`shouldDistribute` (with `minPeriod`, live default 1 hour) is called from exactly one place:
`process()` line 341. `distributeDividend` is reachable ungated from `setShare` (292) and from the
**public `claimDividend()`** (370-372). `minPeriod` is the same push-cadence limiter as `claimWait`,
wearing a more convincing name.

One accidental half-mitigation worth noting because it is *not* one: `getUnpaidEarnings` returns 0
when `shares[shareholder].amount == 0` (375), so entitlement is destroyed on a full exit. But
`setShare` pre-pays at line 292 *before* zeroing the amount, so the attacker is paid on the way
out anyway. Losing the entitlement only bites honest holders who exit without a `setShare` pass.

---

## 6. Did anyone in the lineage ever fix it? — the 2024 fork, judged

The Base 2024 descendant made exactly one relevant change:

```solidity
// TokenDividendTracker.sol lines 476-488 — note what is MISSING at the end
function setBalance(address account, uint256 newBalance) public onlyOwner {
    if (!isExcludedFromDividends[account]) {
        if (newBalance >= minimumTokenBalanceForDividends) {
            _setBalance(account, newBalance);
            tokenHoldersMap.set(account, newBalance);
        } else {
            _setBalance(account, 0);
            tokenHoldersMap.remove(account);
        }
    }
    // <-- no processAccount(). The 2021 force-claim is gone.
}
```

That removes the automatic same-call payout of Step 3. It does **not** fix the attack:
`magnifiedDividendCorrections` still preserves the entitlement through the sell, and the token's
own claim path is still ungated —

```solidity
// same file, line 572
function claim() external returns (bool) { return dividendTracker.claim(msg.sender); }

// line 460 — no claimWait check anywhere in it
function claim(address account) public onlyOwner returns (bool) {
    uint256 amount = _withdrawDividend(account);
    if (amount > 0) { lastClaimTimes[account] = block.timestamp; return true; }
    return false;
}
```

— so the attack goes from **one call** to **two calls in the same transaction**. Meanwhile the same
fork *added* a fully permissionless `distributeDividends` (§4), which is a large step backwards.

**Across four implementations spanning 2019 → 2025 I found no time-weighted balance, no snapshot,
no epoch, no record date, no minimum holding period, no eligibility delay, no cooldown on newly
acquired shares, and no cap on a single-transaction claim.** The lineage does not contain a defence
to copy, because it never had one.

The mitigations that *are* known for this problem come from outside this family — snapshot/epoch
eligibility where the snapshot instant is not chosen by the caller, time-weighted accrual, or a
cooldown before newly acquired balance becomes reward-eligible. Those are the fixes the Flap/Lista
writeup recommends, and none of them appear in any dividend-tracker fork I read.

---

## 7. What we should actually take from this

### Do NOT copy

1. **`claimWait` / `lastClaimTimes` / `canAutoClaim`.** They defend nothing. Bolting a claim delay
   onto our Distributor would make E-03 *worse*: the attacker is paid through the pull path
   regardless of any push cadence, while honest holders wait for a keeper. It would look like a fix
   in the UI and change nothing on chain. If we ever ship a claim delay, it must be justified as a
   gas-budget device and the copy must say so.
2. **A minimum balance as a security control.** `minimumTokenBalanceForDividends` shrinks the
   denominator, which *raises* the attacker's share of the pot. Our `minSharesForQueue` is the same
   shape and should carry the same caveat (audit `02-dividends.md` already found it does nothing at
   0 and never dequeues dust because the check is `== 0`).

### DO copy — and these two are real

3. **`try`/`catch` around every push-side call in the hot path.**
   ```solidity
   // lines 3202-3208
   try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {}
   try dividendTracker.setBalance(payable(to),   balanceOf(to))   {} catch {}
   if (!swapping) { try dividendTracker.process(gasForProcessing) returns (...) { ... } catch {} }
   ```
   One broken holder can never brick a transfer for everyone else. Audit `02-dividends.md` found we
   get this **wrong**: `processBatch` reads `withdrawableOf` *before* `_trySend`, so a
   `mps * balance` panic in one holder takes the whole batch down, outside the guarded region. The
   lineage got this right and we did not.
4. **Judge a transfer by its own success flag, never by a returned amount.**
   ```solidity
   // lines 2332-2342
   bool success = IERC20(rewardToken).transfer(user, _withdrawableDividend);
   if (!success) {
       withdrawnDividends[user] = withdrawnDividends[user].sub(_withdrawableDividend);  // roll back
       return 0;
   }
   ```
   This is the correct version of the pattern our `Distributor._trySend` gets wrong (audit
   `02-dividends.md` D-01, the double-pay): we infer "did not route" from a **zero return value**
   and fall through to a second payment without checking whether the allowance was spent. The
   lineage checks the boolean from the transfer itself, and it rolls back before returning. Copy
   that discipline.

### The structural lesson for E-03

5. **Coupling the trigger to a trade is a *cost*, not a *defence* — but it is a cost we currently
   do not impose.** The lineage's attacker must hold a real position and eat a real round trip to
   fire a distribution. Ours can fire it with no position at all **and gets paid 50 bps for doing
   so.** Whatever the eventual fix, `SWEEP_BOUNTY_BPS` on a caller-chosen instant is a subsidy on
   the attack and should be re-examined on its own. (Related: audit `04-v4-hook.md` V-01 found our
   auto-sweep is unreachable on exact-input traffic, so the pot always grows unpaid and waits for
   exactly this — the two findings compound.)
6. **E-03's own conclusion is confirmed by every contract in this family: entitlement must not be a
   single-instant read of the share register.** Four implementations, six years, thousands of
   forks, one shared accumulator — and the attack works against all of them. There is no proven
   drop-in to copy. The fix has to be built, and it has to change *when entitlement accrues*, not
   *when claiming is allowed*.

---

## 8. Files pulled during this research

Kept outside the repo, in `C:\Users\shies\AppData\Local\Temp\opencode\divtracker\`:

```
babytoken_bsc_0x0938a5d3.sol           109,552 chars  BSC "Digital Files" / DividentToken (classic)
evergrow_EGC_bsc_0xC001BBe2.sol         27,739 chars  BSC EverGrow Coin (DividendDistributor family)
base_2024_TokenDividendTracker.sol      19,248 chars  Base 2024 descendant
pw*.js                                                the playwriter extraction scripts
```

Roger Wu's `DividendPayingToken.sol` was read directly from raw.githubusercontent.com and not
saved. Nothing was written into `hoodstonk/contracts/` except this document.
