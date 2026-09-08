# 17 — A platform token, and the automated sweeper

Two ideas raised from outside the project, recorded before they get lost. Neither is built. The
first needs no contract change to start; the second is now partly closed.

---

## 1. "What if the coins had an automated sweeper?"

**Closed in part, by `e73fcd4`.** The observation was correct: `sweep` is permissionless and
somebody has to call it, and the docstring said so without saying what happens when nobody does.

That was finding **C-2**. The bounty was a flat 0.5% of the pot denominated in the pair currency,
while the caller's cost is denominated in ETH and moves with `block.basefee`. Unrelated numbers, so
a gas spike could leave the reward below the cost, nobody sweeps, and holders quietly stop being
paid. The bounty is now indexed to `block.basefee` above a 1 gwei reference and capped at 5% of the
pot, so the incentive follows the cost instead of ignoring it.

**What is still open: nobody runs a keeper.** The economics are fixed; the process is not. A keeper
is a small always-on job that calls `sweep` when it is profitable, and `previewSweepBounty` was made
public in the same commit precisely so one can price a sweep before spending gas to discover it.

Why this stays off-chain and permissionless rather than becoming automatic:

| | conversion inside every swap | separate `sweep` (ours) |
|---|---|---|
| does anyone need to call? | no | **yes** |
| can a bad conversion break a *trade*? | **yes** | no |
| gas spike stalls payouts | no | **yes, until swept** |

Putting conversion in the hot path means a thin pool or a reverting token bricks trading itself.
Ours cannot: a failed conversion never touches a swap. That trade is deliberate and documented in
`14-basestonk-reference.md` §4, where the same comparison is drawn against a live competitor who
chose the other side.

**Next step, when someone wants it:** a keeper service, not a contract change. Poll configured
pools, call `previewSweepBounty`, sweep where the bounty clears gas. It is the standard answer and
it is also the thing that makes the "somebody has to call sweep" objection disappear in practice.

---

## 2. "Release a token for the platform, and let memes pair against it"

Not built, and worth building. This is the strongest mechanic in BaseStonk's design, recorded in
`14-basestonk-reference.md`: `$BSTONK` is a registered launch pair, so tokens price in it, pay fees
in it, and pay dividends in it — and **platform revenue becomes a standing bid on the platform's own
token, with everything it buys destroyed.** A launch with nothing to do with `$BSTONK` still burns
`$BSTONK` merely by trading.

### What already works, with no contract change

`PairRegistry` is an address allowlist. Approving a platform token makes it immediately available
as **both** a pair currency and a reward currency — the same single call used to admit all thirty
pairs on Robinhood Chain. So "launch a meme paired against $CARBON" and "pay holders in $CARBON"
are available the day the token exists.

### What does NOT exist

The buyback. Platform fees currently accrue to `ReferralVault` and settle to the treasury in
whatever currency they arrived in. Routing a share of that into buying and burning a platform token
is a new contract, and it is the part that carries risk:

- it spends platform revenue automatically, so a bug spends real money
- it needs a conversion route per fee currency, with the same **E-05** price-limit treatment the
  sweep leg already has — and `09-remediation.md` records that a naive `minOut` there made the
  bounty farmable by fragmentation
- burn-and-buyback interacts with the referral wedge: both are paid from the platform's cut, and
  the split between them has to be fixed somewhere

### The honest case against doing it soon

A platform token is a second thing to be wrong about, launched by a project whose contracts are
**unaudited** (blocker B-1 in `12-pre-mainnet-concerns.md`). It also changes what the product is:
today a creator's launch is priced against assets that exist independently of us, and a platform
token makes some of that flow depend on our own asset. That is the flywheel and the risk in the
same sentence.

**Recommended sequencing:** admit the token as a pair first, which costs one registry call and
requires no new code. Add the buyback later, after the adversarial pass, as its own contract with
its own tests.
