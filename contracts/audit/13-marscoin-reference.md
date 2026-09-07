# 13 — MarsCoin, and the one property that decides whether a dividend token survives

A live reference point for the architecture in this repo, examined because it is the largest
dividend-paying token currently running and because it has **not** failed under load.

`0xFe189E97832DA1573e4e4Ff034F4fFC3a15c7777` on BNB Smart Chain. Binance spot listing on
2026-09-04 (MARSCOIN/USDT, /USDC, /TRY), Seed Tag, roughly $159M 24h volume and 41,210 holders at
the time of writing. Binance's first new memecoin spot listing in about a year.

It matters here for one reason: it does the same job as `FeeHook` + `Distributor`, at scale, and
the reason it works is a single structural property that `11-external-bsc-contracts.md` shows the
copy-paste lineage does not have.

---

## 1. The property: O(1) per transfer, not O(holders)

This is the whole finding. Everything else is detail.

| per transfer | Whiz's `MultiRewardToken` | MarsCoin | this repo |
|---|---|---|---|
| share updates | `setShare(from)`, `setShare(to)` | `setShare(from)`, `setShare(to)` | O(1) hook accounting |
| **holder iteration** | **`process(1_000_000 gas)` — walks an unbounded array** | **none** | **none** |
| cost as holders grow | grows without bound | flat | flat |

MarsCoin's ABI contains no `process`, no `shareholders`, no `claimDividend`, no
`setDistributorGas` — nothing that iterates. Its entire per-trade dividend coupling is two
`setShare(address,uint256)` calls (selector `0x14b6ca96`) against `dividendContract()`.

At 41,210 holders the lineage in `audit/11` would already be dead: its array only ever grows,
because the `uint256 >= 0` / `uint256 < 0` guards make `removeShareholder` unreachable (see
`11` §12). MarsCoin never iterates, so holder count simply does not enter the gas cost.

**This is the property to protect in our own code.** It is structural and very hard to retrofit
once an iteration has been introduced into a hot path.

---

## 2. Three supporting choices, each of which we also make

**Pools are excluded from the share register.** Decoded from the runtime bytecode, the `setShare`
call is skipped when the counterparty is `address(this)`, `address(0)`, `0xdead`, the
`dividendContract`, or `pools[addr] == true`. The AMM pool never becomes a shareholder. The
lineage in `11` has no such guard, so every router and pool address accumulates into the array it
then has to walk.

**Distribution happens off the transfer path.** The token never converts or distributes during a
trade. That work lives in the vault and in manual claims. `11`'s `swapForRewards` runs inside
`_transfer`, `require`-wrapped around an external helper, which is what makes a helper failure a
token-wide brick.

**It reverts instead of swallowing.** `DividendShareUpdateFailed(address account, bytes reason)` is
declared as an **`error`**, not an event. A failed share update reverts the transfer.

That last one is worth sitting with, because it looks backwards. MarsCoin is *stricter* than the
lineage that bricks, and that strictness is affordable **because** the call is O(1) and cannot run
out of gas. `11`'s code wraps everything in `try { ... } catch {}` precisely because its call
genuinely might fail — so it converts a brick into permanently wrong accounting instead of fixing
the cause. Swallowing errors is what you do when you have not fixed the thing that fails.

---

## 3. What this says about our design, stated carefully

Our contracts have the same property, verified against our own source rather than by analogy:

- no `process`-style holder walk anywhere in `src/`
- no division by `totalShares` or any supply figure (the zero-holder brick cannot occur)
- the only loops are over a `ReferralVault` config schedule and at most four `PoolKey` candidates
- `beforeAddLiquidity` through `afterRemoveLiquidityReturnDelta` are all `false`, so there is no
  hook code in the liquidity path to grief
- claims are pull-based and `sweep` is a separate external function, so a failed conversion cannot
  stop trading and cannot destroy accrued claims

**This does not mean our contracts are correct.** It means one failure class — the one that kills
this entire category of product — is structurally absent. Architecture being right is necessary and
not sufficient. The files in `audit/11` had the right *idea* too (separate distributor contract,
configurable reward asset); they fail on reentrancy, an unguarded setter, and `amountOutMin = 0`.
Those are implementation bugs, and implementation bugs do not care what shape the architecture is.

The blockers in `12-pre-mainnet-concerns.md` are unchanged by anything in this file.

---

## 4. The part we deliberately do not copy

`quoteToken()` resolves to `0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1` — `name()` returns
**"SpaceX"**, symbol `SPCXB`. MarsCoin is paired against a tokenized stock and pays holders in it.

That is the exact thing `app/src/lib/pairs.ts` and `app/pairPolicy.ts` exist to prevent here, and
the exact thing counsel identified as the risk. It is also, judging by the coverage, a large part
of why the token got attention.

So: same engine, different fuel. The engineering is worth copying. The asset choice is not.

---

## 5. Method, and its limits

On-chain reads against `bsc-rpc.publicnode.com`. Both the token and its `dividendContract` are
**EIP-1167 minimal proxies**:

| | proxy | implementation | size |
|---|---|---|---|
| token | `0xFe189E97…c7777` | `0x024f1829…156422` | 19,331 bytes |
| distributor | `0xBBA9d212…Ace819` | `0xde658c0a…9654d8` | 9,843 bytes |

Factory-produced clones off a shared implementation (Flap, `IFlapTaxTokenV3`), which is the same
pattern as `Launcher` here.

**BscScan served only the header of the Solidity plus the ABI and runtime bytecode.** The claims
above about absent iteration come from the ABI containing no such functions, and the claims about
pool exclusion come from decoding the branch in the runtime bytecode. That is good evidence and it
is not the same as having read the source line by line. If a decision ever depends on the exact
semantics of MarsCoin's distributor, pull the multi-file source properly first.
