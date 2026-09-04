# Audit 10 — `ZapRouter`

**Surface:** `src/ZapRouter.sol`, in full, and every intersection it has with the `src/` changes
that landed in `audit/09-remediation.md` on the same day.

**Scope:** native-ether custody, settlement out of `TransientStateLibrary.currencyDelta`, the wrap
shortcut, direction derivation from caller-supplied `PoolKey`s, the revert-based quote channel, the
`IntermediateLegDidNotNet` netting claim, the deadline, MEV shape, and griefing.
Fee *economics* were audits 01/05, dividends 02, access control 03, v4 hook correctness 04 and
round-2 04. Anything already reported there is cross-referenced, not re-counted.

**No file under `src/` was modified.** `git status --porcelain src/` shows only the pre-existing
audit-09 remediation diffs, none of them mine.

---

## Which v4 I read

`ZapRouter` is 424 lines of v4 delta arithmetic, so nothing below is from memory. The remapping
that actually compiles is `v4-core/ = lib/v4-periphery/lib/v4-core/src/` — **not** the top-level
`lib/v4-core`, which is a second checkout. Both are byte-identical for the files below (verified by
hash), and the compiled one is:

```
lib/v4-periphery/lib/v4-core   @uniswap/v4-core 1.0.2   59d3ecf ("bump to 1.0.2")
```

| File | Lines that settled a question |
|---|---|
| `src/PoolManager.sol` | `onlyWhenUnlocked` :96-99, `unlock` :104-114, `swap` :189-193, `take` :291-295, `settle` :300-302, `_settle` :349-360, `_accountDelta` :374-376 |
| `src/libraries/Hooks.sol` | flags :29-47, `isValidHookAddress` :109-127, `callHookWithReturnDelta` :159-168, `noSelfCall` :171-175, `beforeSwap` :248-282 (esp. `amountToSwap += hookDeltaSpecified` :275 and the sign-flip guard :276), `afterSwap` :285-315 (esp. `swapDelta = swapDelta - hookDelta` :312) |
| `src/types/Currency.sol` | `transfer` :40-53 — native transfer is `call(gas(), to, amount, 0,0,0,0)` at **:48**, the FULL gas allowance, not a 2300 stipend |
| `src/types/BeforeSwapDelta.sol` | `toBeforeSwapDelta(deltaSpecified, deltaUnspecified)` |
| `src/libraries/TransientStateLibrary.sol` | `currencyDelta`, `isUnlocked` |

Three facts from that reading do the heavy lifting and each is asserted somewhere below rather than
assumed:

1. **`Lock` is ONE global transient flag** (`PoolManager.sol:105`), not a per-caller one. Anything
   running inside an open unlock is locked out of `unlock` entirely, whoever it is.
2. **`_settle` short-circuits to `paid = msg.value` for native ether** (`:353-354`) and never reads
   a balance. That is what makes the ETH leg immune to the audit-04 8.5x and the pair leg not.
3. **`beforeSwap`'s specified delta cannot make a swapper overpay.** `:275` adds it to the amount
   handed to the curve and `:312` subtracts the identical number back off the swapper, so an
   exact-input hop debits exactly `amountSpecified` for any hook. **`afterSwap`'s UNSPECIFIED delta
   has no such cancelling term** — only `:312` applies — so it can drive the swapper's output
   negative. That asymmetry is Z-15 and Z-15b.

---

## What I exercised

Extended file: **`test/audit/10-zap/ZapAudit.t.sol`**.

```
forge test --match-path test/audit/10-zap/ZapAudit.t.sol   →  320 passed, 0 failed
forge test --no-match-contract Fork                        →  1319 passed, 0 failed
```

Baseline before this surface was **999**. Eight suites, four paired families, every case in **both
currency orderings**, because every delta sign in `unlockCallback` flips with the ordering and a
one-sided proof is half a proof:

| Family | Shape | Why it exists |
|---|---|---|
| `ZapAuditTokenIsCurrency{0,1}Test` | deep hop 1, default fee | the main body |
| `ZapAuditWrapTokenIsCurrency{0,1}Test` | `weth != 0`, pair's code replaced by `MockWETH9` | the wrap shortcut |
| `ZapAuditWedgeTokenIsCurrency{0,1}Test` | `sellFeeBps = 1000`, `burnBps = 3000` | the netting claim under every config the **remediated** hook can produce |
| `ZapAuditThinTokenIsCurrency{0,1}Test` | hop 1 banded ±600 on `L = 2000e18` | truncation and the pin |

Five probe contracts: `ReentrantRecipient` (what an arbitrary `take` recipient can do mid-unlock),
`EvilHook` (an arbitrary hook on a caller-supplied key), `ReenteringSellRecipient` (the wrap path's
post-unlock payout), `NativeSettleProbe` (what `settle{value:}` really credits), `NoReceiveBuyer`
and `WeirdERC20` (fee-on-transfer / reflecting).

**The methodological point, and it is the one that produced half the findings:** the shipped suite
proves that the router *works*. It never asks **whose money the router is holding**, whether the
guards it advertises are **reachable**, what an **out-of-range** caller-supplied number does, or
what a **caller-supplied hook** can do — and both `PoolKey`s are caller-supplied. It also never
arms `maxWallet`: `FeeHookHarness` initialises every launch token with `maxWallet_: 0`, so before
this file the audit-09 inbound cap and all 250 shipped ZapRouter tests had never met.

---

## Findings

**0 critical / 0 high / 5 medium / 5 low / 6 info.**

Nothing here lets an attacker take value that a user correctly sent. The medium band is three
things: value that reaches the router *by accident or by force* is paid to the next caller, a
one-wei denial of service against contract integrators, and a **complete sell-side outage** that a
stranger can arm for a fraction of a pair unit.

---

### Z-14 — MEDIUM — A stranger can pin hop 1 and take EVERY zap sell offline

`src/ZapRouter.sol:405-413` (`_requireNotPinned`), reached from `:294`
**REPRODUCED**, both orderings — `test_Z14_griefing_aStrangerCanPinHopOneAndTakeEverySellOffline`,
`test_Z14c_theOutageEndsAsSoonAsAnybodyBuysThePriceBackDown`,
`test_Z14b_control_theSameAttackDoesNothingToASingleHopSell`

Hop 1 on a sell is `pair -> ETH` with `sqrtPriceLimitX96 = MAX_SQRT_PRICE - 1`. Exhaust the ether
side of that pool's liquidity and the price does **not** stop at the top of the band: with no
liquidity above it, `Pool.swap` walks the remaining distance to the limit for free and parks there.
`_requireNotPinned` then refuses **every** sell through that ETH pool, by name, for everybody.

Round-2 `04-hook.md` records the pin as an *informational* property of a launch pool, where reaching
it means selling the whole float back through a single-sided seed. **Hop 1 is an ordinary two-sided
pool that nobody in this system owns, and reaching its pin is one exact-input swap.**

Measured (`ZapAuditThinTokenIsCurrency0Test`, identical in both orderings):

```
pair consumed to place the pin              61.0892 pair
ether the pin handed the attacker           59.1060 ether
attacker NET pair cost of the round trip     0.4220 pair    (0.69% of the size pushed)
victim's sell, unattacked                   37.9496 ether   -> reverts PoolIsPinnedAtItsPriceLimit(false)
```

Both a full-position sell and a 0.1%-of-position sell revert. **Buys still work**, so it is a
one-way valve rather than an outage: holders cannot leave and newcomers can still arrive, which is
strictly the worse shape. Any buy walks the price back off the pin (`Z-14c`), which is what makes it
a cheap repeatable bundle rather than a brick — the attacker re-arms it every block for 0.42 pair.

`TradeRouter` has no equivalent: a single-hop seller receives the pair currency and is unaffected by
the identical attack (`Z-14b`, the control).

**Bounded by hop-1 shape, and this matters.** The 0.4220 figure is against a ±600-tick band with
nothing above it. Against a hop-1 pool with genuine full-range liquidity the pin costs the whole
ether side, which is not cheap. And a **WETH-paired launch has no hop 1 at all** — it takes the wrap
path — so this is a risk on exactly the non-WETH pairs the product exists to support, and it is
worst on a thin new one. Hop-1 depth is therefore a per-pair property the UI has to surface, in the
same way `project_hoodstonk.md` already records shallow pair depth as per-pair and not a platform
ceiling. I did **not** measure the live Sepolia ETH/tPAXG pool's band, so no claim is made about it.

**Fix.** Do not derive "can I sell" from an extreme price limit. Either (a) pass hop 1 a limit
derived from the caller's `minAmountOut` rather than `MAX_SQRT_PRICE - 1`, so a pinned pool produces
`TooLittleReceived` instead of a blanket refusal and the trade still executes when it can; or (b)
allow the caller to supply an alternative `ethKey` list and try them in order. `_requireNotPinned`
is a good error message attached to the wrong policy — it converts "this specific pool is exhausted"
into "you may not sell".

---

### Z-01 — MEDIUM — `_refundEth` pays the router's whole balance to whoever called last

`src/ZapRouter.sol:418-423`, with the false justification at `:139-141`
**REPRODUCED**, both orderings — `test_Z01_forcedEtherIsPaidToWhoeverCallsZapBuyNext`,
`test_Z01c_theSweepFollowsMsgSenderNotTheRecipient`, `test_Z01d_aSellLeavesTheDonationWhereItIs`
**Negative control:** `test_Z01b_control_withoutTheDonationTheBuyerPaysExactlyMsgValue`

```solidity
function _refundEth() internal {
    uint256 left = address(this).balance;     // :419  — ALL of it
    if (left == 0) return;
    (bool ok,) = msg.sender.call{value: left}("");
}
```

The docstring on `receive()` argues this is safe:

> "Ether may arrive here from exactly two places … Anything else is refused, so `_refundEth`'s
> 'send whatever is left to the caller' can never be pointed at somebody else's money."

**That claim is false.** `receive()` is not on the path for `SELFDESTRUCT`, for a block reward paid
to `block.coinbase`, or for a balance pre-funded at a counterfactual CREATE2 address. None of those
execute code at the recipient. `vm.deal` models exactly that class, and the test asserts the guarded
path really is guarded first, so the finding is not "a stranger can send ether" — it is that the
guard covers only the door that was already locked.

Measured: 5 ether forced into the router, alice calls `zapBuy{value: 1 ether}`, **alice ends up
4 ether richer** and the router ends at zero. The sweep follows `msg.sender`, not `recipient`, so a
relayer or aggregator forwarding a user's zap collects it and the user does not (`Z-01c`). A SELL
never sweeps (`Z-01d`), so the value waits for the cheaper and more frequent call.

**Fix.** Refund `msg.value - spent`, not `address(this).balance`. `spent` is already known: it is
`uint256(-ethDelta)`, which the callback computes at `:340`. Return it alongside `amountOut` and
refund the difference. That is a two-line change and it makes the `receive()` docstring true.

---

### Z-01e — MEDIUM — One wei of forced ether bricks `zapBuy` for every contract integrator

`src/ZapRouter.sol:422` (`if (!ok) revert EthRefundFailed()`), on the exit path of every `zapBuy`
**REPRODUCED**, both orderings —
`test_Z01e_aOneWeiForcedDonationBricksZapBuyForEveryContractCallerThatCannotTakeARefund`

The composition, and the reason Z-01 is not merely untidy. `_refundEth` reverts when the refund call
fails, and it runs on **every** `zapBuy` — including one that needed no refund at all. So one wei of
forced ether, the cheapest write in the EVM, makes `zapBuy` revert for **every contract caller
without a payable fallback**: an aggregator, a vault, a smart account, any integrator that never
intended to hold ether.

The victim cannot fix it from their side: `receive()` refuses the ether, there is no rescue
function, and the only thing that clears it is somebody else's buy. Measured: the same contract
buyer succeeds on an empty router, then fails `EthRefundFailed` twice in a row at 1 wei, then works
again the instant an EOA sweeps.

**Fix.** The Z-01 fix removes this for free — with nothing to refund there is no call to fail. If
`_refundEth` is kept as-is, at minimum make a zero-difference refund a no-op rather than a call.

---

### Z-01f — MEDIUM — On the wrap path the same sweep exists for WETH, and needs no forced ether

`src/ZapRouter.sol:187-190` (`balanceOf(address(this))`, not the dust this call created)
**REPRODUCED**, both orderings — `test_Z01f_donatedWrappedEtherIsUnwrappedAndPaidToTheNextBuyer`,
`test_Z01h_aWrappedSellLeavesTheDonationWhereItIs`
**Negative control:** `test_Z01g_control_withoutTheDonationTheWrappedBuyCostsExactlyMsgValue`

```solidity
if (_isWrapPair(pair)) {
    uint256 dust = IERC20(weth).balanceOf(address(this));   // :188 — the ENTIRE balance
    if (dust != 0) IWETH9(weth).withdraw(dust);
}
_refundEth();
```

Getting wrapped ether into the router needs no forced-ether trick and no callback: a plain ERC-20
`transfer` does it. A mis-typed address, a bot's misrouted rebalance, or anybody who names the
router as `recipient` on a WETH-output route all land here — and the next WETH-paired buyer
collects the lot **as native ether**. Measured: 3 ether of WETH donated, alice buys with 1 ether,
alice ends 2 ether richer, router at zero.

I checked the happy path for cross-transaction residue and there is none: a wrap buy settles exactly
what it wrapped and a wrap sell withdraws exactly `amountOut`, so this only fires on value that
arrived by mistake.

**Live today?** No. `script/DeployZap.s.sol:71` deploys with `weth = address(0)`, deliberately,
because Sepolia's `tWETH` has no `deposit()`. **This arms itself on the mainnet deploy**, where WETH
is `DEFAULT_PAIR` and therefore the most common launch.

**Fix.** Unwrap the amount this call is owed, not the balance: `msg.value - owed`, computed from the
same returned `spent` the Z-01 fix needs.

---

### Z-04 — MEDIUM — `-int256(amountIn)` silently inverts an exact-input sell into exact-output

`src/ZapRouter.sol:388`
**REPRODUCED**, both orderings — `test_Z04_anAmountInAbove2Pow255SellsAnAmountThePoolChoosesNotTheCaller`,
`test_Z04b_theSellEverythingIdiomBecomesAOneUnitExactOutputSwap`,
`test_Z04c_exactly2Pow255PanicsRatherThanNamingAnything`

```solidity
amountSpecified: -int256(amountIn), // negative = exact input
```

`int256(uint256)` is an unchecked wrapping conversion. Above `2**255` it produces a negative
`int256`, and negating that gives a **positive** `amountSpecified` — which in v4 means **exact
output**, the opposite of what the comment on that line promises. `zapSell`'s `amountIn` is
caller-supplied and unbounded.

**`minAmountOut` is no defence.** The floor bounds the output from below and the flipped shape
produces *more* output. Measured, with the floor set to what an honest 1% sell delivers:

```
amountIn the caller passed   2**256 - 5e18   (i.e. "exact output: 5e18 of the pair currency")
tokens actually sold          4.99999645e18  — the POOL chose this, not the caller
ether delivered               5.1726 ether
honest 1% sell delivered      0.3933 ether   — the floor the call cleared
```

The two ends of the range land on opposite sides of the guard, which is worth recording. At the
other end, `type(uint256).max` — the "sell everything" idiom every frontend reaches for — becomes
`amountSpecified = 1`, an exact-output swap for one unit; the quote channel prices it at **0 wei**
and it fails closed on `TooLittleReceived`. Exactly `2**255` reverts on a bare arithmetic panic
rather than by name.

This is caller-supplied, so it is not an attack on a third party. It is a router accepting a number
whose documented meaning silently inverts, in the one direction where the slippage guard points the
wrong way.

**Fix.** `if (amountIn > uint256(type(int256).max)) revert ZeroAmount();` — or better, a named
`AmountOutOfRange`. One line, at the top of `_hop`, beside the existing `if (amountIn == 0)`.

---

### Z-03b — LOW — A settlement SURPLUS reverts through `SettlementShortfall`, fields reversed

`src/ZapRouter.sol:336-337` (`credited != owed`, not `credited < owed`)
**REPRODUCED**, both orderings — `test_Z03b_aSurplusRevertsThroughTheSameErrorWithTheFieldsReadingBackwards`
**Positive control inside the test:** with the token's quirk switched off the identical sell settles.

The good news first, because it has never been shown before: **`SettlementShortfall` is reachable
and it works.** `tokenKey` is entirely caller-supplied, so the router will route through a pool
whose "launch token" is fee-on-transfer, and `test_Z03` measures the guard firing on exactly that —
handed 100e18, credited 99e18, and the shortfall equals the transfer fee to the wei. The project
notes single this guard out as "do this in every router from now on"; it is now demonstrated, not
asserted.

The finding is the comparison operator. A token that credits the singleton **more** than it was
handed takes the identical branch: measured handed 100e18, credited 101e18, reverting through
`SettlementShortfall(handedOver, credited)` with `credited > handedOver`. Refusing is the right
call — a surplus leaves an unclosed positive delta and `unlock`'s `NonzeroDeltaCount` check is
sign-agnostic — but on a router the error text is the entire diagnostic an integrator gets, and this
one reads backwards.

**Fix.** Split it: keep `SettlementShortfall` for `credited < owed` and add
`SettlementSurplus(uint256 handedOver, uint256 credited)`.

---

### Z-15 — LOW — A caller-supplied hop-2 hook turns a "buy" into a debit of the buyer's tokens

`src/ZapRouter.sol:311` and `:314` (unchecked `uint256(int256)`), `:329` (no direction assertion)
**REPRODUCED**, both orderings — `test_Z15_aCallerSuppliedHopTwoHookTurnsABuyIntoADebitOfTheBuyersTokens`

Neither `PoolKey` is checked against `PairRegistry`, `FeeHook`, or anything else, so a caller can
point hop 2 at a pool carrying a hook they wrote. `Hooks.afterSwap` adds the hook's returned int128
to `hookDeltaUnspecified` and then does `swapDelta = swapDelta - hookDelta` (`Hooks.sol:299-312`)
with **nothing on the other side to cancel it**, so a hook that claims more of the output than the
curve produced drives the swapper's delta on the output currency negative.

`ZapRouter` defends neither end:

1. `:311`/`:314` do `uint256(tokenDelta)` on a raw `int256`. A negative delta wraps to a number
   above `2**255`, which sails past every `minAmountOut` a caller can express.
2. `:329` then treats it as a debt and pays with `safeTransferFrom(d.payer, …)` — on a **BUY**,
   against the `type(uint256).max` approval every frontend sets. There is no "a buy must never
   settle the launch token" assertion anywhere in the contract.

Measured, on a hook armed to claim twice what the curve produced:

```
ether taken FROM the buyer               1.000000000000000000
launch tokens taken FROM the buyer       0.966874905794277511
launch tokens delivered                  0
amountOut the router reported            115792089237316195423570985008687907853269984665640564039456617133007335362425
```

A call named `zapBuy` took the caller's ether **and** their launch tokens, delivered nothing, and
returned a success value of roughly **1.1579e77**.

Graded LOW because the route is the caller's own choice — this is the standard risk of any router
that takes a path as a parameter, and `TradeRouter` shares it. It is listed because both guards are
one-liners and because the reported `amountOut` is the number a frontend displays and an integrator
branches on.

**Fix.** `if (tokenDelta < 0) revert …` on the buy branch and `if (ethDelta < 0) revert …` on the
sell branch before the cast, or use `SafeCast.toUint256(int256)`. Guarding the direction is
strictly better than guarding the cast: a buy that ends owing the launch token is never correct.

---

### Z-16 — LOW — The quote channel does not model the audit-09 max-wallet cap

`src/ZapRouter.sol:316` (`ZapQuote` reverts) vs `:350` (`take`), against `src/LaunchToken.sol:198`
**REPRODUCED**, both orderings — `test_Z16_theQuoteChannelDoesNotModelTheMaxWalletCap`
**Positive control:** `test_Z16b_control_theSameBuyUnderTheCapStillExecutes`

Audit 09 changed `LaunchToken._update` from "cap the pool's outbound transfer" to "cap **every**
inbound transfer to a non-exempt address". A zap buy delivers with
`poolManager.take(launchToken, recipient, …)`, which is an inbound ERC-20 transfer to a non-exempt
address, so it is capped — correctly, and the router is right not to special-case it.

**The quote is not.** `unlockCallback` reverts `ZapQuote` at `:316`, which is *before* the `take` at
`:350`. So `quoteZapBuy` returns a healthy number for a trade that can never execute. Measured: with
the cap set to exactly half of what a 10-ether buy delivers, the quote returns the **full uncapped**
figure — twice the cap — and the execution then fails with a `MaxWalletExceeded` bubbled out of an
ERC-7751 `WrappedError` three frames down, naming neither the router nor the amount the caller
could have bought.

**This intersection had never been exercised anywhere.** `FeeHookHarness._deployLaunchTokenSorted`
initialises every launch token with `maxWallet_: 0`, and all 250 shipped ZapRouter tests inherit it. The
audit tests write the slot directly (`_armMaxWallet`), which is faithful because `maxWallet` is set
once in `initialize` and has no setter — and the write is asserted, so a silent failure cannot make
the cap tests vacuously green.

**Fix.** Two options and they are not exclusive. (a) Cheap: have `quoteZapBuy` read
`LaunchToken.maxWallet()` and `balanceOf(recipient)` and revert with a distinct
`ZapQuoteCapped(uint256 quoted, uint256 headroom)` so a frontend can size the trade down. (b) Free:
the router already knows `tokenDelta` and `d.recipient` at `:350`; a `try/catch` there converting
the wrapped ERC-20 failure into a named router error costs one branch and makes the failure legible.

---

### Z-11 — LOW — The two-hop shape is measurably worse to be sandwiched in

`src/ZapRouter.sol:163-192`, `:197-220` — `minAmountOut` is end-to-end only
**REPRODUCED**, both orderings — `test_Z11_sandwichingAZapCostsTheVictimMoreThanSandwichingTheSingleHop`

`TradeRouter` exposes a buyer to one pool. `ZapRouter` exposes them to two, and there is no per-hop
floor — unlike the installed periphery's `IV4Router.ExactInputParams.minHopPriceX36`, which this
repo's own notes flag as mandatory for the frontend to populate.

End-to-end **is** sufficient for correctness: the route is atomic, so bounding the final output
bounds everything. What it is not is neutral for MEV. Measured as the victim's loss in their own
output units, sandwiched versus not, from the same starting state at equal attacker size:

```
victim loss, single hop      0 bps    (under 1 bp — the launch pool is deep)
victim loss, zap           195 bps
```

Practically all of the difference is hop 1, a pool nobody in this system chose, seeded, or can
defend.

**Fix.** Not a bug, a disclosure and a parameter. Add an optional `minIntermediateOut` on hop 1 so a
frontend can bound each leg, and say on the trade UI that an ETH zap crosses two markets.

---

### Z-02 — LOW — Anything sent to the router as `recipient` is stranded forever

`src/ZapRouter.sol:259` (`recipient` is never compared against `address(this)`), `:350`
**REPRODUCED**, both orderings — `test_Z02_launchTokensTakenToTheRouterAreStrandedForever`

A zap that names the router as its own recipient succeeds, reports a non-zero `amountOut`, clears
the slippage floor, and leaves launch tokens in a contract with no rescue function, no owner, and no
code path that ever moves a launch token out. Later traffic by anybody — a buy and a sell — leaves
them exactly where they are. The ether sweep of Z-01 has no ERC-20 twin except for `weth`.

**Fix.** `if (recipient == address(this)) revert …`, or resolve `address(this)` to `msg.sender` the
way `address(0)` already is at `:259`.

---

### Z-10 — INFO — The remediation moved ownership of the truncated-buy refusal

`src/FeeHook.sol:732-757` (`_assertExactInputBuyFilled`, new) vs `src/ZapRouter.sol:313`
**REPRODUCED**, both orderings — `test_Z10_aTruncatedHopTwoBuyIsNowRefusedByTheHookNotByTheRouter`,
`test_Z10b_theSameShapeOnAnUnhookedHopTwoStillHitsTheRoutersOwnGuard`
**Soundness control:** `test_Z10c_sound_anOrdinaryZapIsUnaffectedByTheNewHookRevert`

`ZapRouter` was written against the pre-remediation `FeeHook`. Audit 09 §11 added
`PriceLimitedBuyWouldOvercharge`, which refuses an exact-input BUY whose curve did not consume
`requested - fee`. **A zap's hop 2 is exactly that shape**, so on any pool carrying `FeeHook` the
hook now refuses a truncated hop 2 *before* `ZapRouter`'s own `IntermediateLegDidNotNet` can read
the residual. The BUY half of that guard is dead code on precisely the pools this product ships.

Both refuse and nothing is lost, but it changes which contract owns the failure and which error a
trader sees, and the router's docstring at `:49-57` still claims ownership. The same shape through
an **unhooked** hop 2 still reaches the router's guard with a positive residual — measured at
**120.39 pair** of unspendable intermediate currency — which is the case `ZapRouter` was built for
and the reason to keep the guard.

**Does the remediation change the netting?** No. `_beforeSwap` still returns
`toBeforeSwapDelta(+fee, 0)` and `Hooks.sol:275`+`:312` still cancel, so hop 2 debits exactly what
hop 1 produced. Verified in the configuration the remediation actually touches — `sellFeeBps = 1000`
(the ceiling) and `burnBps = 3000` — where a round trip settles in both directions, the pair nets to
exactly zero on both legs, the router keeps nothing, and a later `sweep` on zap-only traffic still
converts and burns (`Z-13`, `Z-13b`). The new revert is correctly scoped to buys: a full-position
sell that partially fills at the opening-tick floor is still allowed (`Z-13c`), which F-05's
self-healing deferral depends on.

**Fix.** Documentation. Amend `:49-57` to say the hook refuses first on hooked pools and the
router's guard covers unhooked hop-2 routes and the whole SELL direction.

---

### Z-09 — INFO — The native-leg `SettlementShortfall` guard cannot fire

`src/ZapRouter.sol:344-346`
**REPRODUCED**, both orderings — `test_Z09_nativeSettleAlwaysCreditsMsgValueSoTheGuardIsUnreachable`

`PoolManager._settle` short-circuits to `paid = msg.value` for the native currency (`:353-354`) and
never reads a balance. `msg.value` here **is** `owed`, so `credited == owed` by construction.
Measured rather than argued: a probe settles 1 wei, 1 ether, 3 ether and 7 wei — amounts bearing no
relation to any delta — and is credited exactly what it sent, every time.

Harmless, and the docstring three lines above says exactly why the native leg is structurally
immune. But the guard beside it reads as a live defence and is not one; the ERC-20 guards at
`:327`/`:337` are the real ones.

**Fix.** Replace with a comment, or leave it and note "unreachable by construction, kept so a
refactor to `settleFor` does not silently lose the check".

---

### Z-08 — INFO — A self-routed key makes the launch token native ether

`src/ZapRouter.sol:275-277` — no check that the derived `launchToken` is not `address(0)`
**REPRODUCED**, both orderings — `test_Z08_aSelfRoutedKeyMakesTheLaunchTokenNativeEtherAndFailsOpaquely`

Passing the same key for both hops makes `launchToken == address(0)`. The callback's three delta
reads collapse to two — `tokenDelta` and `ethDelta` become the same number — and both settle
branches plus both `take` branches key off it. It fails closed, because `safeTransferFrom` against
`address(0)` is refused by `SafeERC20` (no code there), and the router keeps nothing. But the caller
gets an OpenZeppelin ERC-20 error about a call they never made, and the contract is one sign-flip
away from double-`take`ing the same delta.

**Fix.** `if (launchToken.isAddressZero()) revert PairIsNotInTheLaunchPool();` beside the existing
derivation.

---

### Z-06 — INFO — `take(ADDRESS_ZERO, recipient, …)` hands an arbitrary address a full-gas callback mid-unlock

`src/ZapRouter.sol:351`, via `Currency.sol:48`
**REPRODUCED**, both orderings — `test_Z06b_theRecipientCanFlashLoanTheSingletonFromInsideTheZapsUnlock`

On a sell, native ether is delivered with `call(gas(), to, amount, 0,0,0,0)` — the full gas
allowance, arbitrary code — to a caller-chosen address, while `Lock.isUnlocked()` is still true and
`unlockCallback` is mid-frame. That is a real capability and it is documented nowhere in the
contract. What it buys, measured: a **fee-free flash loan out of the singleton without ever
implementing `IUnlockCallback`** — the probe takes 1,000 pair, holds it, repays it, and the
singleton ends whole. Not a new primitive (anyone can `unlock` for themselves) but the router hands
it to an address of the caller's choosing.

What it does **not** buy is anything against this router — see the SOUND section.

**Fix.** None required. Worth one sentence in the docstring so it is written down rather than
discovered.

---

### Z-17 — INFO — The wrap path is the one place `ZapRouter` is re-enterable

`src/ZapRouter.sol:215-219`
**REPRODUCED**, both orderings — `test_Z17_theWrappedSellPaysOutAfterTheUnlockSoTheRecipientCanReenter`

On the pool path the seller's ether leaves at `:351`, inside the still-open unlock, where the global
`Lock` closes every door (Z-06). The wrap path cannot do that — `WETH.withdraw` is illegal inside an
unlock — so `zapSell` calls the recipient at `:217`, **after** the cycle has closed. The manager is
free at that instant and the recipient can drive a whole second zap.

The router is stateless, so nothing is corrupted. What the recipient does get is Z-01's donation
sweep pulled forward into the seller's own transaction and pointed at an address the seller named:
the nested `zapBuy` ends in `_refundEth`, which hands `address(this).balance` to `msg.sender` — the
recipient. Asserted to the wei: the recipient's balance ends at `before + out - 1 ether + 4 ether`
(sale proceeds, minus the nested buy, plus the whole 4-ether donation), and the manager is confirmed
**locked** during the callback so the test is measuring the wrap path and not the pool path.

**Fix.** Subsumed by the Z-01 fix — with nothing to sweep the re-entry gains nothing. A
`ReentrancyGuardTransient` on the two entry points would also close it and costs one transient slot.

---

### Z-11b — INFO — The extra hop taxes the attacker too

**REPRODUCED**, both orderings — `test_Z11b_aZapRoundTripIsStrictlyMoreLossyThanTheSingleHopRoundTrip`

The other half of Z-11, and the answer to "does the zap create a new MEV surface a bot wants". A
sandwicher has to round-trip through hop 1 as well, paying that pool's fee twice and its impact
twice. Measured as dimensionless loss fractions, which is the only way to compare an
ether-denominated round trip against a pair-denominated one:

```
round-trip loss, single hop    300 bps
round-trip loss, zap           356 bps
```

So the zap is a worse route to be sandwiched *in* (Z-11) and a worse route to sandwich *from*. Both
statements are true and the second is why Z-11 is LOW rather than MEDIUM.

---

## Verified SOUND

Every claim below is a test that passes **and** a stated control that makes the passing meaningful.
Anything without a control is not in this list.

| Claim | Test | Negative / positive control |
|---|---|---|
| The router only ever pulls from `msg.sender`. `d.payer` is hardcoded at `:258`; bob's unlimited approval and real position cannot be spent by alice. | `test_Z05_sound_noCallerCanMakeTheRouterPullFromSomebodyElse` | **Positive control in the same test:** the identical sell from bob succeeds. Preconditions assert bob's allowance is `type(uint256).max` and alice holds zero, so the revert is the payer binding and not an empty wallet. |
| An arbitrary `take` recipient cannot re-enter the router. `unlock` gives `AlreadyUnlocked`; `zapBuy` reverts. | `test_Z06_sound_theRecipientCallbackCannotReenterTheRouter` | `assertTrue(r.sawManagerUnlocked())` — if the callback had run with the manager *locked* the whole proof would be vacuous. Plus `assertEq(r.hits(), 1)` (it ran at all) and an assertion on the exact selector, so "it reverted" cannot be a different failure. |
| A flash-loan recipient that walks away takes the whole transaction down. | `test_Z06c_sound_aRecipientThatDoesNotRepayRevertsTheWholeZap` | **Z-06b is the control:** the same probe *repaying* completes, and the singleton ends whole. So the revert is non-repayment, not the probe. |
| A caught quote changes nothing: no tokens, no ether, no lock left standing, no fee, neither pool's price moved, no ether or launch tokens into the singleton. | `test_Z07_sound_aCaughtQuoteChangesNothingAtAll` | **`test_Z07b_control_theSameTradeExecutedMovesEveryQuantityTheQuoteDidNot`** — the identical trade, executed, moves all five. Without it the SOUND test would pass on a build whose quote executed nothing at all. Plus `test_Z07c` asserts the caught number equals what the zap delivers. |
| An ordinary zap is unaffected by the new `PriceLimitedBuyWouldOvercharge`. | `test_Z10c_sound_anOrdinaryZapIsUnaffectedByTheNewHookRevert` | **Z-10 and Z-10b are the controls:** the truncated shapes *do* revert, one through the hook and one through the router. |
| The wrap path ignores `ethKey` entirely — proven with a key carrying the dynamic-fee sentinel, tick spacing 1, and the live `FeeHook`, i.e. a pool that could not legally exist. | `test_Z12_sound_theWrapPathIgnoresTheEthKeyEntirely` | Three assertions make it a proof: the garbage pool is still uninitialised afterwards, the hook accrued nothing against its id, and the launch-pool fee is the advertised rate on the **full** `msg.value` — only true if hop 1 was a 1:1 wrap. **`test_Z12b_control_theSameGarbageKeyIsFatalOnThePoolRoutingPath`** shows the identical key is fatal on the shipped `weth == 0` router. |
| A 10% sell tax and a 30% burn wedge do not break the intermediate netting; the pair still cancels to exactly zero in both directions and the router keeps nothing. | `test_Z13_sound_aSellTaxAndABurnWedgeDoNotBreakTheIntermediateNetting` | Non-vacuity: `pendingTokenFees` must have **moved**, or this is the default configuration under another name. `test_Z13b` further requires the later `sweep` to actually burn and actually pay the distributor. |
| The new hook revert is scoped to buys and does not touch the zap's sell leg. | `test_Z13c_sound_theNewHookRevertIsScopedToBuysAndDoesNotTouchTheZapsSellLeg` | **Z-10 is the control:** the same revert fires on a buy, in the same file, so "it did not fire" is a property of the direction and not of the harness. |
| **An exact-input hop debits exactly `amountIn` whatever the hook charges** — the invariant `IntermediateLegDidNotNet` actually rests on. Proven against an arbitrary hook charging a quarter of the input, four times `FeeHook`'s rate. | `test_Z15b_sound_anExactInputHopDebitsExactlyAmountInWhateverTheHookCharges` | **`test_Z15c_control_aSpecifiedChargeLargerThanTheInputIsRefusedByV4Itself`** — push the charge past the whole input and `Hooks.sol:276` refuses with `HookDeltaExceedsSwapAmount`, naming the exact line the bound lives on. Plus non-vacuity: the hook must be holding the `grab` afterwards. And **Z-15 is the standing counter-example** showing the measurement is sensitive — the *unspecified* side does change what the payer pays. |
| A malicious hook on a caller-supplied hop-2 key cannot re-enter the router. | `test_Z15d_sound_aMaliciousHopTwoHookCannotReenterTheRouter` | `evil.hits() > 0` and `sawManagerUnlocked()` true, so the probe genuinely ran mid-cycle; the two selectors are asserted exactly (`AlreadyUnlocked`, `NotPoolManager`) rather than "it reverted". |
| **No max-wallet value can block a sell through the zap** — the property that keeps the cap from being a honeypot survives the two-hop route, because a sell moves tokens into the exempt PoolManager. Checked at a cap of **one wei**. | `test_Z16c_sound_noCapValueCanBlockASellThroughTheZap` | Non-vacuity: at that same one-wei cap a **buy** is refused with `MaxWalletExceeded`, so the sell is running against an armed cap and not a dormant one. `test_Z16b` is the paired positive control for Z-16. |
| `PoolIsPinnedAtItsPriceLimit` is a hop-1 property, not a launch-pool one. | `test_Z14b_control_theSameAttackDoesNothingToASingleHopSell` | Z-14 itself carries a positive control: the victim's sell is measured working (37.9496 ether) *before* the attack, from a snapshot. |

Two further things I chased and could not turn into findings, recorded so nobody re-spends the time:

- **The wrap path has no cross-transaction WETH residue on the happy path.** A wrap buy settles
  exactly what it wrapped (`owed == msg.value` on a `FeeHook` pool, because `Hooks.sol:275`+`:312`
  cancel); a wrap sell `take`s `pairDelta` to the router and withdraws exactly `amountOut`, which is
  the same number. Z-01f only fires on value that arrived by mistake.
- **The router issues no zero-value ERC-20 transfer and no zero-amount `take`.** Every settle and
  take branch at `:320`, `:329`, `:339`, `:350`, `:351`, `:354` is strictly signed, and `_hop`
  refuses `amountIn == 0` at `:380`. *This one is argued from the guards, not measured* — I did not
  build a revert-on-zero-transfer token, so it is not in the table above.

---

## Method notes

1. **Both currency orderings, always.** Eight suites, four paired families. Every delta sign in
   `unlockCallback` flips with the ordering, and Z-14's `PoolIsPinnedAtItsPriceLimit(false)`
   argument would have looked correct in one ordering and been wrong in the other.

2. **The thing the shipped suite does not ask is "whose money is this".** `test_theRouterRetainsNothing`
   proves the router ends a *happy* transaction empty. It never starts one non-empty. Three of the
   five mediums come from `vm.deal(address(zap), …)` and `pair.mint(address(zap), …)` — two lines
   that model forced ether and a mis-sent ERC-20, neither of which `receive()` sees.

3. **`FeeHookHarness` initialises every launch token with `maxWallet_: 0`.** All 250 shipped ZapRouter tests
   inherit it, so the audit-09 inbound cap and this router had never met. Check what a harness
   *disables* before concluding an intersection is covered — this is the same lesson as audit 01's
   "check what a fuzz bound is excluding".

4. **`vm.expectRevert` and `vm.expectPartialRevert` both fail against an ERC-7751 `WrappedError`.**
   `Currency.transfer` and `Hooks.callHook` both bubble through `CustomRevert.bubbleUpAndRevertWith`,
   which wraps the inner payload. `test_Z16c` failed once on
   `WrappedError(token, 0xa9059cbb, 0x9487d160…, 0xf27f64e4) != custom error 0x9487d160` with the
   correct selector plainly visible inside. The fix is a `_contains(err, selector)` byte scan, which
   this file already had for hook reverts and which now covers token reverts too.

5. **A hook that inflates the swapper's delta must collect physically *inside* `afterSwap`.** The
   credit `Hooks.sol:299-312` creates is only accounted *after* the call returns, so a hook that
   returns a delta and does nothing else leaves itself an unclosed delta and takes the whole
   transaction down on `CurrencyNotSettled`. `EvilHook` `take`s first and lets the credit cancel the
   debt — the same shape `FeeHook` uses with `mint`. Without that the probe reverts and reads as
   "the router is safe", which is a false negative.

6. **`assertGt(x.balanceOf(a), 0)` is banned in this file.** Every ownership claim is a delta and
   every `expectRevert` has a positive precondition beside it. `test_Z01e` asserts the contract buyer
   works on an empty router *before* the one-wei donation and again *after* the cure, from a
   snapshot, so "it reverted" cannot be "it never worked".

7. **Measurements come from snapshots, not from re-running the world.** Every "what would this have
   delivered" number in Z-04, Z-11, Z-11b, Z-14, Z-15 and Z-16 is taken with
   `vm.snapshotState`/`vm.revertToState`, so the control and the case start from bit-identical state.
   Z-11 in particular compares an ether-denominated route against a pair-denominated one, which is
   only legitimate as a **loss fraction**; Z-11b makes that explicit.

8. **No `vm.warp(block.timestamp + n)` anywhere.** The deadline tests in the shipped suite already
   use `skip()` and `vm.getBlockTimestamp()`, which is correct — `via_ir` hoists `TIMESTAMP` as
   loop-invariant within a call frame and has produced two fabricated findings in this repo. This
   surface adds no time-dependent tests, so the trap was avoided by not needing it.

9. **Build cost is the binding constraint, so batch.** A single edit to this file recompiles for
   **1,490 s** under `via_ir`. Both rounds of new tests went in as one edit each. `forge build`
   piped to `Select-Object` still hangs; `Start-Process -RedirectStandardOutput` and poll.

---

## Final report

**Severity counts: 0 CRITICAL, 0 HIGH, 5 MEDIUM, 5 LOW, 6 INFO.**

| | |
|---|---|
| MEDIUM | Z-14 sell-side outage · Z-01 refund sweep · Z-01e one-wei brick · Z-01f the WETH mouth · Z-04 the `int256` inversion |
| LOW | Z-03b surplus reads backwards · Z-15 hook-driven buy debit · Z-16 quote ignores the cap · Z-11 sandwich cost · Z-02 stranding |
| INFO | Z-10 remediation ownership · Z-09 unreachable guard · Z-08 self-routed key · Z-06 full-gas callback · Z-17 wrap re-entry · Z-11b attacker cost |

**The single most serious finding.** **Z-14.** A stranger pushes one exact-input swap into hop 1,
the price parks on `MAX_SQRT_PRICE - 1`, and `_requireNotPinned` then refuses **every** sell through
that ETH pool for **every** holder, by name, while buys keep working. Net cost of the round trip to
the attacker: **0.4220 pair** against the 61.0892 pair he pushed through — **0.69%** — and the
victim whose 37.9496-ether exit was measured working from the same snapshot is simply offline. It is
not permanent, which makes it cheap and repeatable rather than fatal, and it is bounded by hop-1
depth: a WETH-paired launch takes the wrap path and has no hop 1 to pin at all.

**Anything exploitable for profit?** **No direct profit path exists**, and I looked hard:

- Z-01 / Z-01f move value to the next caller, but only value that arrived by force or by mistake.
  Nobody can *cause* a victim to fund the router.
- Z-15 spends the caller's own tokens on the caller's own chosen route.
- Z-06b's flash loan is fee-free but is not new capability — anyone can `unlock` for themselves —
  and Z-06c shows walking away reverts the whole transaction.
- Sandwiching is 195 bps *more damaging to the victim* on the zap (Z-11), but Z-11b measures the
  attacker's own round trip at **356 bps vs 300 bps** single-hop, so the extra hop is not free for
  them either. The zap is a worse route to sandwich from as well as in.
- Z-14 is pure grief: it costs 0.42 pair and earns nothing unless bundled with a position taken
  elsewhere, which is outside this surface.

**Interactions with the just-landed remediation, specifically checked.**

| Remediation (audit 09) | Result |
|---|---|
| `FeeHook.PriceLimitedBuyWouldOvercharge` | **Changed behaviour.** The hook now refuses a truncated hop-2 buy *before* the router's `IntermediateLegDidNotNet` can read the residual, so the BUY half of that guard is dead code on `FeeHook` pools (Z-10). Both refuse, nothing is lost, the docstring is now wrong. Correctly scoped to buys, so the zap's sell leg is untouched (Z-13c). |
| `LaunchToken` inbound `maxWallet` | **Correct on execution, wrong on quote.** The cap binds a zapped buy, as it should. The quote channel reverts before the `take` and reports the uncapped number (Z-16). The honeypot property survives: no cap value, down to one wei, can block a zap sell (Z-16c). This intersection had zero prior coverage — the harness disables the cap. |
| `feeBps <= 100` now reverts | No interaction. The harness runs at 300 and every zap suite configures through `configurePoolFull` above the floor. |
| `ReentrancyGuardTransient` on `Distributor` | No interaction. A zap buy reaches `setBalance` through `LaunchToken._update`, which audit 09 deliberately left unguarded; `withdraw`/`processBatch` are not on any zap path. |
| `Distributor.renounceAccrual`, `VestingVault`, `PairRegistry`, `ReferralVault` | Not on any `ZapRouter` code path. Checked, no interaction. |
| Netting under the remediated wedge | **Unchanged and re-proved.** `sellFeeBps = 1000` + `burnBps = 3000`: the pair nets to exactly zero on both legs, the router keeps nothing, and a later `sweep` on zap-only traffic still converts and burns (Z-13, Z-13b). |

**Final test count.**

```
forge test --no-match-contract Fork
1319 passed, 0 failed, 0 skipped
```

Baseline was 999. This surface adds **320** (`test/audit/10-zap/ZapAudit.t.sol`, eight suites, four
paired families in both currency orderings). No fork tests were run. `src/` was not modified.
