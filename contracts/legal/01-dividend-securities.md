> ## STATUS: COUNSEL HAS WEIGHED IN. READ THIS BEFORE THE ANALYSIS BELOW.
>
> The position relayed from counsel, recorded here as it was given:
>
> **Revenue sharing on its own is not the issue. Tokenised STOCKS are.**
>
> The product decision that follows: **this pad does not touch tokenised equities on Ethereum.**
> Pair currencies are crypto assets and commodities. Holders receive a share of trading fees in
> whichever of those the creator picked. No tokenised share, note or other claim on an issuer ever
> enters the allowlist.
>
> **The test any new pair currency must pass**, now written into `app/src/lib/pairs.ts` beside the
> list itself: *does this token represent a claim on an issuer's cash flows, debt or equity?* If
> yes, it does not go in. Gold (PAXG, XAUT) is a commodity claim and stays. A tokenised Treasury
> note is not, and **USDY has been removed** for exactly that reason — it is Reg S, restricted from
> US persons by its own issuer.
>
> **What this does NOT mean.** It does not mean the analysis below is void; it means the branch it
> was most worried about is closed by a product decision rather than an argument. The memo is kept
> because the reasoning about the dividend mechanism is still the reasoning, and because a future
> version that adds a yield-bearing or equity-shaped pair reopens every word of it.
>
> Everything under this line was written BEFORE counsel's position and is unchanged. It remains
> research by an AI, not advice, and four of its citations are flagged unverified.

---
# 01 — Is the launched token a security? The dividend mechanism under Howey

**Status:** research memo. Read-only pass over `contracts/src/` and `app/src/`. No source file was
edited to produce this.

**I AM NOT A LAWYER. THIS IS NOT LEGAL ADVICE.** Nothing here is a legal opinion and nothing here
may be relied on. It is a structured research brief written so that a securities lawyer can be
asked the right questions in one meeting instead of five. Every case, release and docket below was
checked against a primary source during this pass, or is explicitly flagged as unverified.

Throughout, three verbs are kept distinct and are never blurred:

- **"the SEC alleged"** — a litigating position in a complaint. Proves nothing.
- **"a court held"** — a ruling, with its procedural posture stated (motion to dismiss, summary
  judgment, Rule 29) because posture is most of the meaning.
- **"the Commission/staff stated"** — an interpretive or staff release. Not law, expressly
  non-binding on courts, and revocable by the next Commission.

---

## 1. The mechanism, stated precisely and neutrally

This section describes the deployed Solidity. It does not describe the pitch.

### 1.1 Who creates what

`Launcher.launch` (`src/Launcher.sol:321`) is **permissionless** — there is no access control on it
at all. In one transaction it:

1. clones an ERC-20 (`Launcher.sol:413-432`, `Clones.cloneDeterministic`) and calls
   `LaunchToken.initialize`;
2. `LaunchToken.initialize` deploys a **`Distributor`** for that token
   (`src/LaunchToken.sol:129-140`) and mints the **entire fixed supply to the Launcher**
   (`LaunchToken.sol:151`). There is no mint function and no burn function after this;
3. registers a fee configuration on the shared hook (`Launcher.sol:437-452` →
   `FeeHook.configurePoolFull`, `src/FeeHook.sol:330`);
4. opens a Uniswap v4 pool with `fee: 0` and `hooks: feeHook` (`Launcher.sol:345-353`) against a
   "pair currency" that must be on an owner-curated address allowlist
   (`Launcher.sol:467`, `PairRegistry.isApproved`);
5. seeds the **whole supply single-sided** into a locked position owned by the Launcher
   (`Launcher.sol:599-632`). The lock is structural: the Launcher contains no code path that passes
   a negative `liquidityDelta`, no admin, no owner, no upgrade (`Launcher.sol:34-40`, `620-621`);
6. optionally performs a "dev buy" for the creator, straight into a `VestingVault` if a vest was
   requested (`Launcher.sol:636-668`);
7. asserts it retains nothing (`Launcher.sol:698-702`).

**The creator never sells a token to anybody.** They do not hand tokens to buyers; the supply goes
into an AMM position that nobody can withdraw. Every buyer buys from the pool. This fact matters a
great deal in §4 below.

### 1.2 The fee is involuntary and is taken inside the swap

`FeeHook` is registered with flags `0x20CC` (`FeeHook.sol:262-279`), which includes
`beforeSwap`/`afterSwap` **with return-delta permissions**. On a buy:

- exact-input buys are charged in `_beforeSwap`: `fee = (amountIn * rate) / BPS`
  (`FeeHook.sol:596`), returned as a positive specified-delta (`FeeHook.sol:605`). The core curve
  then swaps `amountIn - fee`. The trader pays the full `amountIn`; the fee never reaches the pool.
- exact-output buys are charged in `_afterSwap` on the unspecified currency
  (`FeeHook.sol:648, 656`).
- optional sell tax (`sellFeeBps`) is charged in the **launch token** on the sell leg
  (`FeeHook.sol:592, 599-601`) and converted to pair currency later.

There is **no fee in the ERC-20 itself** — `LaunchToken._update` takes nothing
(`LaunchToken.sol:36-39, 170-183`). The fee is a property of the venue, not of the token. A buyer
cannot decline it, cannot route around it while trading that pool, and is not asked to consent to
it separately from the trade. Cap is 10% (`MAX_FEE_BPS = 1000`, `FeeHook.sol:143`).

### 1.3 The split

`FeeHook._routeFee` (`FeeHook.sol:915-954`) divides a swept fee, in this order:

```
toPlatform = fee * platformShareBps / BPS        // FeeHook.sol:916
rest       = fee - toPlatform                    // FeeHook.sol:917
toCreator  = rest * creatorBps / BPS             // FeeHook.sol:919
toHolders  = rest - toCreator                    // FeeHook.sol:920
```

`platformShareBps` is derived once at configuration as `PLATFORM_VOLUME_BPS * BPS / feeBps`
(`FeeHook.sol:349`), where `PLATFORM_VOLUME_BPS = 100` (`FeeHook.sol:175`). The economic effect is
that **the platform takes a flat 1% of traded volume**, not a share of the creator's fee. It is a
compile-time constant, and `platformRecipient` is `immutable` (`FeeHook.sol:181`) — the operator
cannot raise its own take after people have launched. A burn wedge (`burnBps`) is spent before
`_routeFee` sees the money (`FeeHook.sol:858-880`), and a manual sweep pays a 0.5% bounty to
whoever called it (`SWEEP_BOUNTY_BPS = 50`, `FeeHook.sol:154`; `FeeHook.sol:887-896`).

**Holder dividends are structurally optional.** `configurePoolFull` accepts `creatorBps` up to
`BPS` (`FeeHook.sol:334`, bounded only by `creatorBps + burnBps <= BPS` at `:336`). At
`creatorBps = 10000`, line 920 computes `toHolders = 0`. Nothing in the contracts requires a launch
to pay holders anything. This is the single most important engineering fact in this memo and it
drives the recommendation in §6.

### 1.4 Distribution is pro-rata by balance, in an asset the holder did not buy

`FeeHook._routeFee:947-951` transfers `toHolders` in the **pair currency** to that launch's
`Distributor` and calls `Distributor.distribute` (`FeeHook.sol:949`).

`Distributor` (`src/Distributor.sol`) is a Synthetix-shaped magnified-accumulator:

- `distribute` is `onlyController` (the hook) and does not credit anybody instantly — it arms a
  **linear vest over `STREAM_WINDOW = 24 hours`** (`Distributor.sol:92, 355-377, 304-325`);
- `_checkpoint` folds vested value into a single global accumulator by dividing it by the whole
  share register: `_magnifiedPayoutPerShare += (vested * MAGNITUDE) / shares`
  (`Distributor.sol:272`). That one line is the entire distribution rule: **strict pro-rata by
  token balance, out of one common pot**;
- the share register is written by the token itself on every balance change:
  `LaunchToken._update` calls `Distributor.setBalance` for both sides of every transfer
  (`LaunchToken.sol:181-182`; `Distributor.sol:387`). **The holder takes no action to accrue.**
  Holding is the whole qualification;
- infrastructure addresses are excluded at construction — PoolManager, launcher, `0xdEaD`, the
  contract itself (`Distributor.sol:215-219`) — so accrual runs to real holders only;
- payment is offered two ways: **pull** `withdraw()` (`Distributor.sol:460`), always available; and
  **push** `processBatch(n)` (`Distributor.sol:482`), permissionless, which walks a queue and sends
  money to holders **who never asked for it**. `flush()` (`Distributor.sol:342`) is also
  permissionless;
- the asset paid is `payoutToken`, which is the pair currency — WETH, PAXG, PEPE, LINK, whatever
  the token trades against (`Distributor.sol:6-8, 48-51`). A launch may nominate a different
  `rewardToken`, converted at withdrawal time through a platform-set singleton converter
  (`Distributor.sol:53-66, 526-568`; converter wired by `Launcher.initRewardConverter`,
  `Launcher.sol:306`).

So the four facts that matter, stated plainly:

| | |
|---|---|
| The fee is **involuntary** | charged inside the swap by the hook, not by the token; no opt-out |
| Distribution is **pro-rata by balance** | `Distributor.sol:272` divides a common pot by `totalShares` |
| Payment is in an asset **the holder did not buy** | pair currency, not the launch token |
| **No holder action is required to accrue** | the token writes the register on every transfer |

### 1.5 What the product says about it

The launch form contains a panel titled **"What holders actually earn"**
(`app/src/pages/Launch.tsx:474-560`). It renders two figures: *"Paid to holders / year"* in pair
units with a USD conversion, and an *"Against opening cap"* **percentage** — an annualised yield
(`Launch.tsx:533-542`), computed from `annualYieldPct` on a user-set volume assumption. The panel's
own source comment calls this "the number this whole product is actually about" and "the entire
pitch" (`Launch.tsx:461-473`). It does carry an honesty disclaimer — the volume is labelled *"your
guess"*, an implausible slider position triggers a warning, and the footer says *"It is not a
promise: a token that stops trading stops paying"* (`Launch.tsx:511-513, 545-551, 553-557`).

The token page says *"**Paid in {pair}**, never in {symbol}. X of every buy is split across holders
pro rata"* and renders a **"Claim {pair}"** button (`app/src/pages/TokenPage.tsx:142-162`). The
About page frames it as *"Holders are paid in that same currency"* (`About.tsx:43`), the docs as
*"Get paid in other chains"* (`Docs.tsx:45-48`).

The pair list in `app/src/lib/pairs.ts` contains 39 `symbol:` entries. (The brief for this memo said
38 and the project memory says 25; I did not reconcile the discrepancy and it does not affect the
analysis. On Sepolia the on-chain allowlist is exactly two assets.)

---

## 2. Howey, prong by prong

The test: *SEC v. W.J. Howey Co.*, 328 U.S. 293 (1946) — a contract, transaction or scheme whereby
a person (1) invests money (2) in a common enterprise (3) with a reasonable expectation of profits
(4) derived from the efforts of others. The Commission's own March 2026 release recites it as
three elements with "efforts of others" folded into the third
(91 Fed. Reg. 13714, 13716 & n.7 (Mar. 23, 2026)); I keep them separate because the last two fail
and succeed for different reasons here.

Two framings must be kept apart, because courts keep them apart:

- **Is the token itself a security?** Almost certainly not, and nobody serious argues otherwise.
  *SEC v. Ripple Labs*, 20 Civ. 10832 (AT) (S.D.N.Y. July 13, 2023) held XRP "is not in and of
  itself a contract, transaction[,] or scheme." *SEC v. LBRY*'s final judgment expressly recorded
  that the court "did not find that LBC tokens were 'securities' in and of themselves"
  (D.N.H. No. 21-cv-260, final judgment). The Commission's 2026 Interpretation says the same for
  four of its five categories.
- **Was it offered or sold as part of an investment contract?** That is the live question, and it
  is transaction-specific.

### Prong 1 — investment of money

**For:** a buyer hands over WETH/PAXG/whatever and receives tokens. Consideration is plainly given.
"Money" is not limited to cash (*Uselton v. Commercial Lovelace Motor Freight*, 940 F.2d 564, 574
(10th Cir. 1991), cited approvingly in the 2026 Interpretation at n.143). Every crypto court to
reach the question has found this prong met on a purchase.

**Against:** essentially nothing. The one carve-out the Commission has recognised — airdrops, where
no consideration passes (2026 Interpretation §VII) — does not apply: nobody gets these tokens for
free.

**Winner: satisfied.** Not close. Note that the money going to the AMM pool rather than to the
issuer does not defeat this prong (*SEC v. SG Ltd.*, 265 F.3d 42, 47 (1st Cir. 2001) frames it as
whether the investor "gave up specific consideration in return for a separable financial interest").
Where the money went matters at prong 4, not here.

### Prong 2 — common enterprise

This is the prong the dividend mechanism changes, and the change is not marginal.

The Second Circuit requires **horizontal commonality**: "the tying of each individual investor's
fortunes to the fortunes of the other investors by the pooling of assets, usually combined with the
pro-rata distribution of profits" (*Revak v. SEC Realty Corp.*, 18 F.3d 81, 87-88 (2d Cir. 1994)).
The 2026 Interpretation now states flatly that the common-enterprise element **is** a requirement,
expressly disclaiming the contrary suggestion in *In re Barkate* (91 Fed. Reg. at 13716 n.7). So
this prong is a real gate, not a formality — which cuts both ways.

**Argument FOR satisfaction (strong):**

- `Distributor.sol:272` is a pro-rata distribution of a pooled fund, expressed as one line of
  arithmetic. The `Distributor` **holds real assets** belonging collectively to holders between
  sweep and withdrawal. This is not metaphorical pooling. It is a contract address with other
  people's money in it, divided by balance.
- Every holder's dividend is mechanically a function of every other holder's balance: the
  denominator is `totalShares`. One holder's exit raises everyone else's share. That is the literal
  definition of tying fortunes together.
- The SEC pleaded exactly this against a reflection token: SafeMoon holders "received a pro rata
  distribution of profits... redistributed to existing holders as a 'static reward' or 'reflection,'
  which were **dividend-like payments** that benefited investors directly in proportion to their
  ownership" (Complaint ¶43, *SEC v. SafeMoon LLC*, No. 1:23-cv-08138 (E.D.N.Y. Nov. 1, 2023)).
- A court accepted a version of it. In the parallel criminal case, *United States v. Karony*,
  No. 1:23-cr-00433 (E.D.N.Y.), the district court denied Rule 29/33 relief and held the evidence
  was "more than sufficient for the jury to find the Howey test satisfied," reasoning on common
  enterprise that "each investor's fortune was tied to others' fortunes, *see Revak*... because
  (among other things) half of the 10% tax went to the liquidity pool, which was intended to benefit
  all token holders." Note what the court leaned on: the *liquidity* half of the tax, not the
  reflection half. Still, hoodstonk's holder wedge is a closer fit to *Revak* than either.
- Notably, hoodstonk's version is **stronger for the SEC than SafeMoon's** on one axis: SafeMoon
  reflections were same-token rebasing (a supply mechanic). Hoodstonk pays a **different, liquid
  asset out of a segregated pot**. That is a distribution, not a dilution.

**Argument AGAINST satisfaction (real, but weaker):**

- *Revak* pooling means pooling of **the investors' invested capital** into a venture. Here the
  buyer's money goes into the AMM as pool reserves against which they hold a claim only by selling.
  Nobody pools capital for deployment. What is "pooled" is a **toll on future strangers' trades** —
  a stream that did not exist at the time of anyone's investment and is not their money.
- There is no enterprise. There is no business, no revenue line, no assets, no operations. A
  defendant will say *Revak* requires an enterprise whose profits are shared, and a fee on trading
  is not profits of an enterprise.
- Holders' *principal* outcomes are not shared at all — they depend entirely on each holder's own
  entry and exit price. Only the dividend sliver is common. A defendant will argue commonality must
  attach to the investment, not to a rebate.
- Vertical commonality (whether required in other circuits) is weak here. The platform's revenue is
  1% **of volume**, which correlates with activity, not with holder profit or loss. A wash-trading
  bloodbath pays the platform handsomely while every holder is destroyed. That is the opposite of
  interwoven fortunes. (Caveat: a creator with a large vested dev buy — and vesting **removes** the
  10% dev-buy cap, `Launcher.sol:503-510` — *does* have fortunes tied to price. For those launches
  vertical commonality gets much better for a plaintiff.)

**Which wins, and why:** I think **horizontal commonality is satisfied**, and this is where the
product is worst-positioned. The counterargument is intellectually respectable but it asks a court
to look past a contract that literally divides a common pot of third-party assets by an ownership
register. *Revak*'s language — "pooling of assets, usually combined with the pro-rata distribution
of profits" — describes `Distributor.sol:272` almost word for word. Confidence: moderate-high. A
plain memecoin with no dividend probably fails this prong; this token probably does not.

### Prong 3 — expectation of profits

**For:**

- *Forman* defines profits as "capital appreciation resulting from the development of the initial
  investment, or a **participation in earnings**" (*United Housing Foundation v. Forman*, 421 U.S.
  837, 852 (1975)). A recurring pro-rata payment in a liquid third asset is a participation in
  earnings on any ordinary reading.
- *SEC v. Edwards*, 540 U.S. 389 (2004) forecloses the argument that a contractual or fixed-rate
  return is somehow *less* like a security than a speculative one.
- The product **quantifies the return as an annual percentage** on the launch form
  (`Launch.tsx:533-542`). On the offer side that is close to dispositive: Securities Act §5 reaches
  *offers*, and the offer document here contains a yield figure.
- The **decisive doctrinal fact of 2025-26**: every non-security bucket the SEC has drawn is
  defined by the *absence* of exactly this feature.
  - Division of Corporation Finance, *Staff Statement on Meme Coins* (Feb. 27, 2025): a meme coin
    "does not constitute any of the common financial instruments specifically enumerated in the
    definition of 'security' because, among other things, **it does not generate a yield or convey
    rights to future income, profits, or assets of a business**."
  - The Commission's *Application of the Federal Securities Laws to Certain Types of Crypto Assets*
    (Release Nos. 33-11412; 34-105020, Mar. 17, 2026, 91 Fed. Reg. 13714) repeats the identical
    limiting clause **three times**, once for each non-security category. A digital commodity, a
    digital collectible and a digital tool each "**does not have intrinsic economic properties or
    rights, such as generating a passive yield or conveying rights to future income, profits, or
    assets of a business enterprise or other entity, promisor, or obligor**" (91 Fed. Reg. at
    13718-19).

  A hoodstonk launch token with the dividend on has an intrinsic economic property that generates a
  passive yield. **By the express terms of the Commission's own taxonomy it is not a digital
  commodity, not a digital collectible, not a digital tool, and not a stablecoin.** That does not
  make it a security — the Commission did not say "everything with a yield is a security," and the
  fifth bucket (digital securities) is defined as tokenized versions of enumerated instruments. But
  it removes every safe harbour the current, maximally crypto-friendly Commission has built, by that
  Commission's own words, and it puts the token in the residual "hybrid or uncategorised" space the
  release acknowledges at 13718.
- Worse, the release's description of the one bucket that *is* a security includes: "Some digital
  securities do not convey the same legal rights as offchain securities but instead **entitle the
  holder to receive economic distributions** from a central party that manages a business enterprise
  or other entity... on behalf of digital security holders" (91 Fed. Reg. at 13721). The daylight
  hoodstonk has here is "central party that manages a business enterprise" — see prong 4.

**Against:**

- Real buyers of these tokens are buying a memecoin. The dividend on a small launch is dust against
  a ±90% daily price range. Economic reality is that nobody is buying for the yield, and *Howey*
  is an economic-reality test. `Launch.tsx` itself concedes the yield is arithmetic on an
  assumption the user invented.
- The payment is arguably a **rebate on a toll**, not earnings of an enterprise: buyers collectively
  pay the fee, and holders collectively receive part of it back. Circular, not productive.
- The Ripple court accepted that "a speculative motive on the part of the purchaser or seller does
  not evidence the existence of an 'investment contract'."

**Which wins:** **satisfied**, and comfortably so on the *offer*, because the platform publishes a
yield number. The "it's really a rebate" argument is genuine and may matter for the size of the
problem, but it does not survive contact with a UI panel headed "What holders actually earn" that
prints a percentage.

### Prong 4 — derived from the efforts of others

This is where hoodstonk is genuinely strong, and it is why my overall verdict is not "this is
obviously a security."

The standard: "the efforts made by those other than the investor are the undeniably significant
ones, those **essential managerial efforts** which affect the failure or success of the enterprise"
(*SEC v. Glenn W. Turner Enterprises*, 474 F.2d 476, 482 (9th Cir. 1973)). Administrative and
ministerial acts do not count (2026 Interpretation n.42, collecting *First Financial Federal Savings
v. E.F. Hutton Mortgage*, 834 F.2d 685 (8th Cir. 1987), and *Donovan v. GMO-Z.com Trust Co.*,
779 F. Supp. 3d 372, 388 (S.D.N.Y. 2025)).

**Against satisfaction (i.e. good for the product) — and this is a strong case:**

- **Nothing is manageable after launch.** `configurePool` reverts on a second call
  (`FeeHook.sol:344`). There is no setter for `feeBps`, `creatorBps`, `distributor`, `pairCurrency`
  or `rewardCurrency`. Graduation is write-once (`FeeHook.sol:420`). `LaunchToken` has no owner, no
  mint, no burn. The LP is unremovable because no code path exists to remove it
  (`Launcher.sol:34-40`). `PairRegistry` is not read after launch by anything.
- **The platform cannot raise its own take.** `PLATFORM_VOLUME_BPS` is a constant and
  `platformRecipient` is `immutable` (`FeeHook.sol:175, 181`). The docstring at `:164-167` says
  this in terms. This is the single best fact the product has, and it is unusual — most launchpads
  keep a settable fee.
- **The yield is produced by strangers, not by the promoter.** Holder income is a deterministic
  function of trading volume generated by third parties. Under *Ripple*, an expectation derived from
  "general cryptocurrency market trends" rather than the promoter's efforts does not satisfy this
  prong. Under the 2026 Interpretation, the whole inquiry is anchored to "**the issuer's
  representations or promises to undertake essential managerial efforts**" (91 Fed. Reg. at 13721).
  Here there is essentially no promise of future effort to make: the mechanism runs or it doesn't.
- Judge Torres's programmatic-sales holding maps well onto the buy side: buyers acquire from an AMM
  in blind transactions, do not know their counterparty, and the great majority will never have
  interacted with the creator or the platform.

**For satisfaction (bad for the product):**

- **The money does not move unless someone runs the crank.** `sweep()` is what converts accrual into
  payment (`FeeHook.sol:749`), and this repo's own audit 04 found the auto-sweep path is
  **unreachable from an exact-input swap** — i.e. from ordinary router traffic. In practice a
  keeper must call `sweep()` and, under streaming, `processBatch`/`flush` for the push path to do
  anything. If the platform runs that bot — or if the UI implies it does — then an identifiable
  party is performing the recurring act without which the advertised return does not arrive. That is
  not obviously "ministerial." **This is the fact I would most want a lawyer to look at.**
- **The reward-currency route is a live platform decision.** `rewardConverter` is a platform-wide
  singleton wired by the deployer (`Launcher.sol:306`) and consulted per withdrawal
  (`Distributor.sol:527-563`). If a launch advertises payment in a nominated reward currency, the
  platform's ongoing choice of routing determines whether the holder receives what was advertised or
  a fallback. That is a managerial function over the payout.
- **`PairRegistry` is an owner-controlled allowlist.** It is curated by the operator, and
  `Launcher.initReferralVault`/`initRewardConverter` are deployer-only. "Fully decentralised" is
  not an accurate description of the system as a whole, only of an individual launched pool.
- The 2026 Interpretation's premise for the digital-commodity bucket is that a functional crypto
  system "does not have a central party that oversees participation or **distributes rewards to
  users**" (91 Fed. Reg. at 13718). The `Distributor` distributes rewards to users.

**Which wins:** **not satisfied, probably** — but by less margin than the team likely assumes, and
the margin is entirely a function of who runs the sweep keeper and what the UI says about it. If
nobody at the platform ever touches a live pool and the UI never implies otherwise, this prong is a
genuine defence. If a platform bot is what makes dividends actually arrive, and the marketing leans
on that, the defence gets much weaker.

### Prong-by-prong summary

| Prong | Verdict | Confidence |
|---|---|---|
| Investment of money | Satisfied | High |
| Common enterprise (horizontal) | **Satisfied** — `Distributor.sol:272` is the problem | Moderate-high |
| Expectation of profits | **Satisfied** — the UI prints a yield percentage | High on the offer |
| Efforts of others | **Probably not satisfied** — nothing is manageable post-launch | Moderate, and keeper-dependent |

*Howey* is conjunctive (2026 Interpretation n.144, citing *Revak*, 18 F.3d at 87). One failed prong
defeats the claim. So the honest bottom line is: **the dividend converts a comfortable three-prong
failure into a one-prong hold, and the one prong holding it up is the one most sensitive to
operational facts the team controls but has not yet decided.**

### A trap worth not falling into

The statutory definition of "security" includes "certificate of interest or participation in any
profit-sharing agreement," and a pro-rata dividend contract sounds exactly like that. **Do not run
that argument, and do not fear it.** The 2026 Interpretation (n.45) confirms the settled rule from
*International Brotherhood of Teamsters v. Daniel*, 439 U.S. 551, 558 n.11 (1979): that phrase "does
not have any broader meaning under the Securities Acts than an 'investment contract'." An instrument
that is not an investment contract cannot be a profit-sharing certificate. Everything routes back
through *Howey*.

Similarly, *Landreth Timber Co. v. Landreth*, 471 U.S. 681, 686 (1985) lists stock characteristics —
"the right to receive dividends contingent upon an apportionment of profits; negotiability; the
ability to be pledged; voting rights in proportion to shares; capacity to appreciate." A launch
token has four of the five (no voting). But *Landreth* applies to instruments **called** stock;
*Forman* holds the label is neither necessary nor sufficient the other way. A token is not called
stock, so *Landreth* does not independently capture it. The four-of-five resemblance is worth
knowing only because it is the kind of thing that reads badly in a complaint.

---

## 3. The closest real precedents

Ordered by how much they actually matter to this product.

### 3.1 Reflection / dividend tokens — the only line directly on point

**SafeMoon.** Three separate proceedings; keep them apart.

1. **SEC civil.** *SEC v. SafeMoon LLC, SafeMoon US LLC, Kyle Nagy, Braden John Karony and Thomas
   Glenn Smith*, No. 1:23-cv-08138 (E.D.N.Y., filed Nov. 1, 2023); SEC Litigation Release No. 25888;
   Press Release 2023-229. Charges: Securities Act §§5 and 17(a), Exchange Act §10(b)/Rule 10b-5,
   §9(a)(2). The registration count is the relevant one. The SEC **alleged** that the token was
   offered and sold as an investment contract and rested its common-enterprise allegation squarely
   on the reflection mechanic (¶43: pro-rata "dividend-like payments... in proportion to their
   ownership"). *(The SEC's litigation release oddly styles the venue "S.D.N.Y." in its header while
   the press release and docket number are E.D.N.Y.; the docket is E.D.N.Y.)* **I could not confirm
   in this pass whether the SEC civil case has been dismissed, stayed or is still live in 2026.** A
   June 2026 order in the Utah class action refers in passing to "the SEC civil case in New York" as
   an existing parallel proceeding, which suggests it had not been dismissed as of mid-2026, but
   that is an inference from a third-party docket, not a verified status. **Do not state its status
   as fact without pulling the docket.**
2. **DOJ criminal.** *United States v. Karony*, No. 1:23-cr-00433 (EK) (E.D.N.Y.). Convicted by
   jury on May 21, 2025 of conspiracy to commit securities fraud, wire fraud conspiracy and money
   laundering conspiracy. **Sentenced Feb. 10, 2026 to 100 months**, $7.5M forfeiture (DOJ EDNY
   press release; IRS-CI release). Smith pleaded guilty Feb. 2025; Nagy remains at large.
   - The load-bearing document for us is the court's post-trial **Memorandum & Order** denying Rule
     29/33 relief, which contains an actual judicial *Howey* analysis of a reflection token: the
     court **held** the evidence sufficient on all prongs, rejecting Karony's arguments that SFM
     came with no "contractually-grounded expectation of future value" and that because "tokenomics
     was automated," investors could not expect profits from the defendants' efforts. On efforts of
     others the court pointed to investor testimony that they expected appreciation "because of the
     LP and reflection payments, which the co-conspirators **managed on an ongoing basis**."
   - **The crucial limiting fact.** SafeMoon's defendants *could and did* touch the LP. The whole
     case is that the lock was a lie and they drained it. The "ongoing management" the court relied
     on is exactly what hoodstonk's architecture removes: the Launcher has no withdrawal path.
     SafeMoon is therefore the closest precedent *and* the one whose worst fact does not transfer.
     Anyone citing SafeMoon at you is citing a fraud case; anyone (including me) citing it for you
     must concede its Howey holding rested partly on managerial conduct that cannot occur here.
3. **Private class action.** *Combs v. SafeMoon LLC*, No. 2:22-cv-00642-DBB-JCB (D. Utah). On
   March 29, 2024 the court granted in part and denied in part motions to dismiss; **the only claim
   left standing against the SafeMoon entities was a Securities Act §12(a)(1) claim for selling an
   unregistered security.** Settlements with the bankruptcy trustee and with promoter defendants
   Jake Paul ($200,000) and Daniel Keem ($90,000) received preliminary approval on June 22, 2026;
   fairness hearing set for Oct. 22, 2026. **This is the most under-appreciated data point in the
   memo**: even after the fraud theories were pared back, an unregistered-offering claim over a
   reflection token survived a motion to dismiss and was worth settling.

**Other BSC "rewards token" actions.** I looked for a second SEC or state action squarely against a
reflection/rewards-token *design* (as opposed to a fraud that happened to involve one) and
**could not verify one.** I am not going to invent a citation. Adjacent verified items:
*SEC v. Rari Capital, Inc.* (settled Sept. 18, 2024; complaint at sec.gov/files/litigation/
complaints/2024/comp-pr2024-138.pdf) charged a DeFi yield product with unregistered offering under
§§5(a)/5(c) **and unregistered broker activity under Exchange Act §15(a)** for operating pools whose
smart contracts the founders "developed and controlled," taking "a performance-based fee of
approximately 10 percent." The fee-for-yield-plumbing shape is close enough to be worth reading
in full.

### 3.2 Howey and the token-vs-transaction distinction

- ***SEC v. W.J. Howey Co.*, 328 U.S. 293 (1946).** Land sale plus a service contract giving the
  promoter exclusive management and the purchaser a share of profits. The 2026 Interpretation (n.67)
  reads it as: selling the whole grove to one active owner would have been real estate; subdividing
  it and adding centralised management plus profit-sharing made it a security. **The subdivision +
  profit-share pattern is worth staring at.** A launch splits one supply among many passive holders
  and gives each a pro-rata share of a common income stream.
- **The DAO Report**, Exchange Act §21(a) Report of Investigation, Release No. 34-81207 (July 25,
  2017). The Commission **stated** that DAO tokens were offered and sold as investment contracts.
  Its relevance is narrower than it is usually given credit for: The DAO pooled investor capital and
  deployed it into *other businesses* with expected profit-sharing — a fund. hoodstonk pools no
  capital. Cite it for the proposition that automation does not defeat *Howey*, not for more.
- ***SEC v. Ripple Labs***, No. 20 Civ. 10832 (AT) (S.D.N.Y. July 13, 2023) (Torres, J.), summary
  judgment. **Held:** institutional sales under written contracts were investment contracts;
  **programmatic sales on exchanges were not**, because "Programmatic Sales were blind bid/ask
  transactions, and Programmatic Buyers could not have known if their payments of money went to
  Ripple, or any other seller" — so the third prong failed. Also held XRP is not itself a security.
  The court **expressly declined** to decide the status of secondary-market sales generally.
  This is the best case for hoodstonk buyers on prong 4 and the reason the AMM-only distribution
  model (no creator sale, ever) is worth preserving.
- ***SEC v. LBRY, Inc.***, 2022 DNH 138, 2022 WL 16744741 (D.N.H. Nov. 7, 2022) (Barbadoro, J.),
  summary judgment for the SEC; remedies order and final judgment thereafter ($111,614 penalty,
  injunction). **Held:** LBRY offered LBC as a security given its own repeated statements that LBC
  would appreciate through LBRY's efforts, and rejected the fair-notice defence. The court
  **declined** to rule on secondary-market sales and recorded in the final judgment that LBC was not
  held to be a security in itself. Postscript worth noting: the 2026 Interpretation lists **LBC as
  an example of a digital commodity** (91 Fed. Reg. at 13718 n.51) — a striking illustration of how
  far the Commission's posture has moved from a case it won.

### 3.3 "Staking as a security" — the theory nearest to a dividend

- ***SEC v. Payward Ventures (Kraken)***, settled Feb. 9, 2023, $30M. The SEC **alleged** the
  staking-as-a-service program was an investment contract; Kraken consented to an injunction. Note
  the facts driving it: Kraken took **custody**, pooled assets, chose whether and how to stake, and
  "retained the right to pay them no returns at all." None of those are true here — the Distributor
  has no discretion whatsoever.
- ***SEC v. Coinbase, Inc.***, 726 F. Supp. 3d 260 (S.D.N.Y. Mar. 27, 2024) (Failla, J.), Rule 12(c).
  **Held:** the SEC had *adequately pleaded* that Coinbase operated as an unregistered exchange,
  broker and clearing agency, and that its Staking Program was an unregistered offer and sale of
  securities; dismissed only the Wallet-as-broker claim. Custodial facts again: assets "transferred
  (without loss of ownership), **pooled by Coinbase**, and subsequently staked by Coinbase," with
  Coinbase taking a 25-35% commission. Also worth quoting for the other side: the SEC conceded at
  argument that the blind bid/ask transactions at issue "involve no continuing promises from the
  issuer... impose no post-sale obligations... and involve no profit-sharing between the issuer or
  developer and the holders." **hoodstonk's dividend supplies exactly the profit-sharing element the
  SEC had to concede was missing in Coinbase.** That is the sentence to be uncomfortable about.
- ***SEC v. Binance Holdings Ltd.***, No. 1:23-cv-01599 (D.D.C., filed June 5, 2023). The SEC
  **alleged** unregistered offerings via "BNB Vault" and "Simple Earn" profit-generating programs
  plus a staking scheme, alongside exchange/broker/clearing counts. I did **not** verify the
  dismissal date or terms in this pass; secondary sources (Skadden, Aug. 2025) list Binance among
  the matters the SEC voluntarily dismissed or terminated in 2025. Treat the dismissal as reported,
  not verified.
- **Coinbase resolution:** joint stipulation of dismissal **with prejudice** filed Feb. 25, 2025
  (sec.gov/files/litigation/complaints/2025/stipulation-pr2025-47.pdf), stating the Commission
  sought dismissal "in the exercise of its discretion and as a policy matter" and that the decision
  "does not necessarily reflect the Commission's position on any other case." **Judge Failla's
  March 2024 ruling was never vacated.** It remains on the books as a district-court holding that
  these theories are adequately pleadable. A future Commission can pick it back up.

### 3.4 The platform-side precedents

- **Uniswap Labs Wells notice.** In April 2024 Uniswap disclosed a Wells notice alleging it
  "operated an unregistered securities exchange, engaged in unregistered broker or clearing firm
  activity, or issued an unregistered security." On **Feb. 25, 2025** Uniswap announced the SEC had
  **closed the investigation with no enforcement action** (blog.uniswap.org/a-win-for-defi;
  contemporaneous Bloomberg/CoinDesk/Law.com coverage). Same week as OpenSea, Robinhood Crypto and
  the Coinbase stipulation. **This is the single most favourable development for the platform-side
  theories, and it is a non-decision by an agency, not a holding by a court.** It binds nobody and
  survives only as long as the current Commission does.
- ***Risley v. Universal Navigation Inc.***, 690 F. Supp. 3d 195 (S.D.N.Y. 2023) (Failla, J.),
  aff'd in part, vacated and remanded in part, 2025 WL 615185 (2d Cir. Feb. 26, 2025) (summary
  order). **Held on the federal claims:** DEX developers are **not statutory sellers** under
  *Pinter v. Dahl*, 486 U.S. 622, 642, 647 (1988), because they never held title to third parties'
  tokens, and their smart contracts were "collateral to the offer or sale"; holding otherwise "would
  be akin to holding the NASDAQ or the New York Stock Exchange liable as facilitators of any
  fraudulent stock purchase on their exchanges." **Also held:** promoting the platform on social
  media and selling their own UNI token was "too attenuated" to be solicitation. Exchange Act §29(b)
  rescission failed because the transaction contracts were between the plaintiff and the token
  issuer/liquidity provider, not the platform.
  - **But read the disposition.** The Second Circuit **vacated and remanded the state-law
    securities and common-law claims**, holding the district court had original CAFA jurisdiction
    over them. Idaho, North Carolina and New York blue-sky claims went back for decision on the
    merits. Federal safe harbours do not preempt state securities law, and no federal
    crypto-market-structure statute exists to do so.
- ***Aguilar v. Baton Corporation Ltd. (d/b/a Pump.fun)***, No. 1:25-cv-00880 (CM) (S.D.N.Y.), filed
  Jan. 30, 2025, consolidated with *Carnahan* June 25, 2025. The live test of "is a launchpad liable
  for the tokens launched on it." Count I is Securities Act §§5 and 12(a)(1) against the platform as
  a **statutory seller** — plaintiffs pleading that the platform "sold, promoted, or solicited the
  sale of the Pump Tokens and/or passed title." The defence briefing leans on the Feb. 2025 meme
  coin statement, on *Pinter*, on *Risley*, and on *Morrison*/*Absolute Activist* extraterritoriality
  (Baton is a UK company). Procedural posture as of this pass: leave to file a Second Amended
  Complaint granted Dec. 9, 2025; SAC due Dec. 19, 2025; MTDs due Jan. 23, 2026; **no merits ruling
  yet**. Docket last updated Sept. 2, 2026 per CourtListener. **Watch this case.** It is the closest
  factual analogue to hoodstonk's platform exposure that exists, with two differences that both cut
  against us: Baton is not US-based, and Baton's tokens pay holders nothing.
- ***In re Universal Navigation Inc. d/b/a Uniswap Labs***, CFTC Docket (Sept. 4, 2024), $175,000
  civil penalty, CFTC Release 8961-24. Settled order finding Uniswap Labs violated CEA §4(a) because
  third-party leveraged tokens were tradable through **its interface** to non-ECPs, and "the
  Interface did not restrict access." Not a securities case — but it is direct authority that
  **operating the frontend is the hook**, that decentralisation of the protocol did not immunise the
  interface operator, and that failure to geo/asset-restrict is itself the violation. It is the best
  answer to "the contracts are permissionless so it isn't our problem."

### 3.5 The 2025-2026 posture change, precisely

This is the part most likely to be stale in a training set, so it is stated with dates.

- **Jan. 21, 2025** — Acting Chairman Uyeda establishes the **Crypto Task Force** under
  Commissioner Peirce.
- **Feb. 25, 2025** — Coinbase stipulation of dismissal with prejudice; Uniswap investigation closed;
  OpenSea and Robinhood Crypto investigations closed.
- **Feb. 27, 2025** — Corp Fin **Staff Statement on Meme Coins**: transactions in meme coins as
  described "do not involve the offer and sale of securities." Expressly carves out anything
  "labeled 'meme coins' in an effort to evade... by disguising a product that otherwise would
  constitute a security," and footnote 4 says the view "is not dispositive." Commissioner Crenshaw
  dissented, calling it "an incomplete, unsupported view of the law."
- **Apr. 4, 2025** — Corp Fin statement on stablecoins. **Apr. 7, 2025** — DOJ Deputy AG Blanche
  memo, "Ending Regulation by Prosecution": DOJ "will no longer pursue litigation or enforcement
  actions that have the effect of superimposing regulatory frameworks on digital assets," and
  "prosecutors will not charge regulatory violations in cases involving digital assets — including
  but not limited to unlicensed money transmitting." *DOJ proceeded to trial against Karony anyway,
  after an internal review, and won.*
- **May 29, 2025** — Corp Fin statement that certain protocol staking activities are not securities
  transactions.
- **June 12/17, 2025** — SEC formally **withdraws 14 proposed rules** (Release 33-11377; 90 Fed.
  Reg., withdrawal effective June 17, 2025), including the **Rule 3b-16 "exchange" definition
  amendments** that had been drafted to sweep DeFi protocols and frontends into the exchange
  definition, and the qualified-custodian proposal.
- **July 30-31, 2025** — President's Working Group report; Chairman Atkins launches **Project
  Crypto**.
- **Aug. 6, 2025** — Roman Storm convicted (SDNY) on conspiracy to operate an unlicensed money
  transmitting business; hung jury on money laundering and sanctions conspiracies. See §4.3.
- **Nov. 12, 2025** — Atkins, *The SEC's Approach to Digital Assets: Inside "Project Crypto"*,
  previewing the taxonomy.
- **Jan. 29, 2026** — Project Crypto becomes a **joint SEC-CFTC** initiative (Atkins/Selig).
- **Mar. 17, 2026** — the big one. **Release Nos. 33-11412; 34-105020**, *Application of the Federal
  Securities Laws to Certain Types of Crypto Assets and Certain Transactions Involving Crypto
  Assets*, 91 Fed. Reg. 13714 (Mar. 23, 2026), effective Mar. 23, 2026. Five-category taxonomy;
  investment-contract "on-ramp" and "off-ramp"; mining, staking, wrapping and airdrops addressed.
  The Commission states it "will administer the Federal securities laws consistent with the
  interpretation, **including with respect to enforcement actions**," and that the release
  **supersedes the 2019 Framework for "Investment Contract" Analysis of Digital Assets** (n.21) and
  any prior staff statements on these topics (n.62). It does **not** supersede *Howey*, which it
  calls "binding legal precedent."
- **Aug. 18, 2026** — **Regulation Crypto Assets** proposed (Release 33-11434, 91 Fed. Reg. 13714 et
  seq. published Aug. 21, 2026; comments due Oct. 20, 2026): a $5M/4-year startup exemption, a
  $75M/12-month fundraising exemption modelled on Reg A, a **conditional safe harbour from the term
  "investment contract"**, and state blue-sky preemption via a "qualified purchaser" definition.
  **Proposed. Not adopted.** The tokenization "innovation exemption" has been repeatedly delayed and
  a scheduled Commission vote on the startup exemptions was cancelled in August 2026.
- **Legislation.** H.R. 3633, the **CLARITY Act**, passed the House 294-134 on July 17, 2025;
  reported out of Senate Banking 15-9 on May 14, 2026; merged Senate text released July 22, 2026
  (616 pages, adding an ethics title); cloture motion on the motion to proceed filed before the
  August recess and **ripening Sept. 15, 2026**. Prediction markets were pricing ~14% odds of 2026
  enactment in late August 2026, down from an 82% February peak. It introduces "ancillary asset" —
  a network token whose value depends on the entrepreneurial or managerial efforts of an originator,
  subject to tailored SEC disclosure rather than full securities treatment. **It is not law.**

**How to read all of this.** The direction of travel is unambiguously favourable. But: the shift is
built out of interpretive releases, staff statements, non-decisions and proposed rules — every one
of which the next Commission can reverse by the same means, and none of which binds a court, a state
regulator, or a private plaintiff. Atkins himself said the quiet part in November 2025: "there will
always be risk that a future Commission could reverse course. That is why fit-for-purpose
legislation is so vital." Meanwhile the SafeMoon criminal conviction and 100-month sentence happened
*during* this period, and *Risley*'s state-law claims were sent back to be litigated *during* this
period.

---

## 4. Three exposures, three different answers

These are routinely conflated and they have almost nothing to do with each other.

### 4.1 The LAUNCHED TOKEN being a security — mostly the creator's problem, but not only

**Whose problem primarily:** the creator's. They are the economic issuer. But look at what the
creator actually does in this architecture: they call a function, the contracts mint a supply, and
the supply goes into a pool nobody can withdraw from. **The creator never passes title to any
buyer.** Under *Pinter*, that removes the first branch of statutory-seller liability. Under *Ripple*,
every purchase is a blind AMM transaction. Under *Risley*, the smart contract executing the trade is
collateral to the sale. This architecture is, almost accidentally, the most defensible token
distribution shape available. **Do not lose it.**

Three creator-side residual risks:

1. **The dev buy is a purchase, not a sale — but the exit is a sale.** A creator who takes a large
   vested dev buy (vesting **removes** the 10% cap, `Launcher.sol:503-510`) and later sells into
   their own pool is an issuer/affiliate selling into the public market. Whether §4(a)(1) covers
   that is an underwriter-analysis question for a lawyer, and it is a real one.
2. **Creator statements are the on-ramp.** Under the 2026 Interpretation, a non-security crypto
   asset becomes subject to an investment contract when the issuer makes representations or promises
   of essential managerial efforts, conveyed to purchasers before or contemporaneously with the sale
   (91 Fed. Reg. at 13721-22). A creator with a roadmap, milestones and a team page manufactures the
   missing prong on their own. hoodstonk cannot stop this, but it can decline to provide the fields
   that invite it.
3. **The dividend is not a promise that can be discharged.** The Interpretation's off-ramp works by
   the issuer *fulfilling* its representations so purchasers no longer expect further effort. A yield
   built into immutable code is not a promise awaiting fulfilment; it is a permanent property of the
   instrument, sitting in §III of the release (what the asset *is*) rather than §IV (what the issuer
   *promised*). **Immutability makes the yield permanent, so decentralisation cannot cure it.** This
   is, I think, the most important structural observation in this memo and I have not seen it made
   elsewhere; it should be tested with counsel rather than trusted.

**Why it is also the platform's problem:** the platform writes the token contract, mints the supply,
sets the fee architecture that constitutes the alleged security, publishes the yield percentage, and
takes 1% of every trade. §12(a)(1) statutory-seller liability under *Pinter*'s **second** branch
reaches one who "successfully solicits the purchase, motivated at least in part by a desire to serve
his own financial interests." The 1% is that motive, in a constant, on-chain, forever. *Risley* found
solicitation absent where the only conduct was generic social-media promotion of the platform. A
per-launch, parameterised yield projection rendered on the buyer's own screen is a materially
different fact and I would not assume *Risley* covers it.

Also live for the SEC only: aiding-and-abetting under Exchange Act §20(e). Private plaintiffs cannot
plead it (*Central Bank of Denver v. First Interstate Bank*, 511 U.S. 164 (1994)), which is why
private suits are forced into the statutory-seller theory instead — exactly what *Aguilar* is doing.

### 4.2 The PLATFORM as unregistered exchange / broker / clearing agency

Three separate registration regimes; they fail and succeed differently.

**Exchange (Exchange Act §3(a)(1), Rule 3b-16).** Weakest theory against this product. The platform
does not bring together orders of multiple buyers and sellers using non-discretionary methods — the
v4 PoolManager does, and it is a third-party singleton the platform did not write. The proposed
3b-16 amendments that were drafted to capture protocols and frontends were **withdrawn on
June 17, 2025**. The Uniswap Wells notice pleaded this theory and was closed with no action.
*Coinbase* sustained it only against a custodial, order-matching venue. Risk: low, and lower than it
has been at any point since 2021.

**Broker (§15(a)).** The most serious of the three, and the reason is one word: **transaction-based
compensation**. The SEC's Coinbase complaint identified broker conduct as "soliciting potential
investors, handling customer funds and assets, and **charging transaction-based fees**." *Rari
Capital* charged §15(a) against DeFi founders whose smart contracts "received transaction
instructions from users... and carried out those instructions," while taking a percentage fee. The
hoodstonk platform: solicits (the board, the token page, the yield panel), operates the interface,
and takes 1% of every trade forever. It does **not** handle customer funds on the trading path —
`Launcher._assertHoldsNothing` (`Launcher.sol:698-702`), and the routers pass through. Risk:
moderate, entirely conditional on the tokens being securities. If they are not, §15(a) never
engages.

**Clearing agency (§17A) / transfer agent (§17A(c)).** Nominally weakest, but there is one fact
worth naming out loud that nobody in this repo has: **the `Distributor` holds other people's money.**
Between `_routeFee` funding it (`FeeHook.sol:948`) and a holder calling `withdraw()`
(`Distributor.sol:460`), the contract custodies pair currency owed to identified holders, maintains
the definitive register of who is owed what (`shareOf`, `_corrections`, `_withdrawn`), and
distributes it. Maintaining holder records and distributing payments to securityholders is the
functional description of a transfer agent. **I could not find any authority applying transfer-agent
registration to a dividend smart contract, and I am not going to assert one exists.** But it is a
question, it is cheap to ask, and it is the only place in the system with genuine custody.

### 4.3 The 1%-of-volume revenue — money transmission, or an issuer's promotional interest

Two entirely different theories.

**(a) Money transmission (18 U.S.C. §1960; 31 C.F.R. §1010.100(ff); state MTLs).**

The governing agency document is FinCEN's **FIN-2019-G001** (May 9, 2019), *Application of FinCEN's
Regulations to Certain Business Models Involving Convertible Virtual Currencies*. Two provisions
matter:

- §4.5.1(b): an **anonymizing software provider is not a money transmitter**, because FinCEN's
  regulations exempt "the delivery, communication, or network access services used by a money
  transmitter," and "suppliers of tools... are engaged in trade and not money transmission."
- The CVC-wallet rubric, which asks who owns the value, where it is stored, whether the owner
  interacts with the payment system directly, and whether the intermediary has **"total independent
  control"** over the value.

**For the trading path, hoodstonk looks clean.** The swap is atomic inside a third-party
PoolManager, the launcher provably retains nothing, the routers cannot divert. Nobody has total
independent control of a user's funds. On the classic reading, the platform ships software.

**For the dividend path, it is less clean, and this is the answer nobody has written down.** Value is
taken from person A (the trader, involuntarily, mid-swap) and delivered to persons B..N (holders),
by a contract the platform wrote, with the platform taking a cut in transit. `processBatch`
(`Distributor.sol:482`) **pushes** funds to third parties who took no action. That is the shape of
"acceptance and transmission of value from one person to another person." The mitigating facts are
that the Distributor is per-launch, unowned, and has zero discretion — it cannot pay anyone other
than the pro-rata amount to the recorded holder.

Why this is not academic: **on Aug. 6, 2025 a SDNY jury convicted Roman Storm of conspiracy to
operate an unlicensed money transmitting business** in connection with Tornado Cash — a
non-custodial protocol whose developers never held user funds — while deadlocking on money
laundering and sanctions conspiracy. Samourai Wallet's founders pleaded guilty to the same offence
on July 30, 2025. Countervailing: a Brady letter in the Storm case revealed that on Aug. 23, 2023
senior FinCEN officials told SDNY prosecutors that because Samourai "did not take 'custody' of the
cryptocurrency by possessing the private keys... that would strongly suggest that Samourai is **NOT**
(emphasis in original) acting as an MSB." And the April 2025 Blanche memo directs prosecutors not to
charge unlicensed money transmitting in digital asset cases. Both of those are helpful and neither is
binding on anyone. Storm's conviction is on appeal.

**State money transmitter licensing is a separate, 50-state problem** and the federal posture does
not touch it. Many states' definitions turn on "receiving money for transmission," some follow the
Money Transmission Modernization Act's exclusions, and a handful are broad enough to be genuinely
uncomfortable. A US-based operator running a contract that pushes value to strangers needs a
state-by-state answer, and I cannot give one.

**(b) Promotional interest / touting.**

- **Securities Act §17(b)** makes it unlawful to publish a description of a security for
  consideration received from an issuer or dealer without fully disclosing the consideration. The
  platform publishes descriptions of every launch (board, token page, yield panel) and receives 1%
  of that token's volume. **If the token is a security, §17(b) is squarely engaged, and the fix is a
  disclosure line.** It is strict about disclosure, not about intent. Cheapest exposure in this memo
  to close.
- **FTC 16 C.F.R. Part 255** (endorsements and testimonials) applies regardless of whether anything
  is a security. Material connections between a promoter and a promoted product must be disclosed.
  Any influencer/referral programme (`ReferralVault`, five-tier schedule) is squarely in scope, and
  the SafeMoon celebrity-promoter defendants — Jake Paul, Daniel Keem, and others named in *Combs* —
  are what that exposure looks like when it lands.
- **State blue sky.** *Risley*'s state claims were revived. Assume no federal safe harbour protects
  against a state securities regulator or a state-law class claim, because as of this writing none
  does.

---

## 5. What, if anything, survives

### 5.1 Remove the holder dividend, keep creator fees (the klik.finance shape). **Yes — this works, and it is nearly free.**

This is the answer, and the Commission has essentially written the safe harbour for it. 2026
Interpretation, **footnote 60** (91 Fed. Reg. at 13719 n.60), on NFT creator royalties:

> "Digital collectibles may be programmed to transmit automatically a portion of the sale price of
> the collectible to the creator as a royalty each time that it is resold... **The digital
> collectible holder does not receive any share of the creator royalty, and the digital collectible
> holder has no rights or interest in or with respect to a business enterprise or other entity,
> promisor, or obligor associated with the creator. Accordingly, the existence of a creator royalty
> does not change a digital collectible into a security.**"

Read the reasoning, not just the conclusion. An automatic, perpetual, on-chain percentage of every
resale paid to the creator is fine — **and the stated reason it is fine is that the holder gets
none of it.** That footnote blesses a creator-fee launchpad by name and, by its own logic, declines
to bless a holder-payout one. It is the single most useful sentence I found.

Effect of removing the dividend:
- prong 2 (common enterprise) loses the pooled pro-rata fund and probably fails;
- prong 3 loses the yield figure and the token returns to "digital collectible";
- the token re-enters the meme coin statement and the digital-collectible bucket on their express
  terms, since it then has no "intrinsic economic properties... such as generating a passive yield";
- the Distributor's custody of third-party funds disappears, taking most of §4.3(a) with it;
- §17(b) exposure collapses because there is probably no security to describe.

**Cost: approximately zero contract work.** `FeeHook._routeFee:919-920` already computes
`toHolders = 0` when `creatorBps = BPS`, and `configurePoolFull` already accepts that value
(`FeeHook.sol:334`). This is a UI decision — stop offering the switch — not a redeployment.
(Two known bugs interact here and must be fixed regardless: audit 01's `burnBps = 10000` case, which
pays everybody zero contrary to the docstring at `FeeHook.sol:869`, and audit 05's E-09, where at
`feeBps = 100` the platform's derived share computes to the whole fee.)

**The cost is that it deletes the product.** The dividend is the differentiator; the memory file says
so in terms ("that single constraint is what drives every hard design decision"). This memo cannot
resolve that tension. It can only be clear that the differentiator and the risk are the same object.

### 5.2 Pay in the launch token instead of the pair currency. **No. Worse in the ways that matter.**

- It moves *toward* SafeMoon, not away. SafeMoon's "reflections" were same-token, and same-token
  reflections are exactly what the SEC characterised as "dividend-like payments" satisfying pro-rata
  profit distribution (Complaint ¶43) and what the *Karony* court had before it when it held the
  *Howey* evidence sufficient. Switching to same-token payout adopts the fact pattern of the only
  reflection case that has produced a judicial *Howey* holding.
- The single argument *for* it: same-token distribution is arguably a supply mechanic — dilution
  rather than distribution — and the 2026 taxonomy tolerates value driven by "supply and demand
  dynamics." Paying a *different, liquid* asset is unambiguously an economic distribution and is
  harder to characterise as anything else. So it is a genuine, non-zero improvement on prong 3's
  "passive yield" framing.
- But it is a rhetorical improvement, not a structural one. Pro-rata is still pro-rata, the common
  pot is still a common pot, and `Distributor.sol:272` does not change. Net: not a fix, and it
  trades a defensible novelty for the fact pattern of a conviction.

### 5.3 Full decentralisation / immutability. **Real, substantial, and it does not reach the problem.**

What is genuinely immutable, and it is more than most: per-pool fee config written once
(`FeeHook.sol:344`), no setters, `PLATFORM_VOLUME_BPS` a constant and `platformRecipient`
`immutable` (`FeeHook.sol:175, 181`), graduation write-once, no token owner/mint/burn, LP
unremovable by absence of a code path. A launchpad that **cannot raise its own take** is unusual and
should be said out loud in any conversation with counsel — it is the best fact the platform has on
prong 4.

What is **not** immutable, and must not be described as such: `PairRegistry` is `Ownable` with
operator-curated `approvePair`; `Launcher.initReferralVault` and `initRewardConverter` are
deployer-only one-shots (`Launcher.sol:295-312`); the frontend, the yield panel and the board are
operated products; and — per this repo's own audits — the sweep keeper is a live operational role
without which dividends do not arrive.

**Why decentralisation cannot cure this particular problem.** The 2026 Interpretation's separation
doctrine discharges an investment contract when the issuer's *promises of managerial effort* are
fulfilled or abandoned. A dividend is not a promise of effort. It is an economic property of the
instrument, analysed in §III of the release, where decentralisation is irrelevant and the only
question is what the thing *is*. Immutability makes the yield permanent and therefore makes the
§III problem permanent. **Decentralisation defends prong 4 and is silent on prongs 2 and 3.**

**Does taking a cut destroy the defence?** Not destroy — degrade, in three specific places:
1. it falsifies the digital-commodity bucket's premise that there is no "central party that oversees
   participation or distributes rewards to users" (91 Fed. Reg. at 13718);
2. it supplies *Pinter*'s "motivated at least in part by a desire to serve his own financial
   interests," which is the element *Risley* found missing;
3. it is the classic broker hallmark of transaction-based compensation.

The mitigant — that the cut is a hardcoded constant to an immutable address that no one can raise —
is worth real weight, and it is worth preserving under pressure. Also worth preserving: the
economics finding in audit 05 that a flat cut **of volume** (rather than a share of the fee) is what
makes wash trading provably lossy. Changing it to a share-of-fee would be bad on two independent
axes.

### 5.4 Geo-blocking US persons. **Partially effective, and it does not help *this* operator much.**

What Uniswap and dYdX actually did:

- **Uniswap Labs**, July 2021: restricted roughly a hundred tokens — tokenized stocks, options,
  synthetics — from `app.uniswap.org`, days after Gensler and CFTC Commissioner Berkovitz speeches.
  The **protocol** stayed open; alternative frontends served the same pools. April 2022: began
  screening wallet addresses via TRM Labs at the frontend only, explicitly noting determinations
  were not reported to law enforcement.
- **dYdX**: blocks US and UK from its frontends, checks the connected address on page load and
  periodically, degrades a flagged wallet to close-only for 7 days, then to Blocked. *(A widely
  reported Sept. 2021 CFTC settlement with dYdX Trading over inadequate US blocking is consistent
  with this posture but **I did not pull that order in this pass — treat it as unverified.**)*
- **What it did not save them from:** on **Sept. 4, 2024** the CFTC entered a settled order against
  Uniswap Labs, $175,000, finding a CEA §4(a) violation because leveraged tokens issued by an
  unaffiliated third party were tradable through **its interface** to non-ECPs and "the Interface
  did not restrict access." Decentralisation of the protocol was not a defence for the operator of
  the frontend.

Applied here:
- Geoblocking the frontend **does** remove the US "offer," which matters because §5 reaches offers
  and because the yield panel is the offer. That is real.
- It does not un-deploy the contracts, which remain permissionlessly callable forever.
- **It does not help a US-based operator nearly as much as it helped a Cayman/UK one.** The
  extraterritoriality defence *Baton* is running in *Aguilar* — *Morrison v. National Australia
  Bank*, 561 U.S. 247 (2010) and the *Absolute Activist* irrevocable-liability test — depends on the
  defendant and the transactions being foreign. A US individual writing, deploying and monetising
  the contracts from the US is subject to US law regardless of where the users are. Geoblocking
  reduces the plaintiff pool and the "domestic transaction" surface; it does not change who the
  operator is.
- Partial or leaky geoblocking is materially worse than none, because inadequate restriction is
  itself the finding in the CFTC's Uniswap order.

---

## 6. Blunt recommendation

**Headline verdict.** The launch token *by itself* is very probably not a security. But **turning on
the holder dividend takes a token that comfortably fails three of four *Howey* prongs and leaves it
failing only one** — the "efforts of others" prong — and that prong's survival depends on
operational facts (who runs the sweep keeper, what the UI promises) that the team has not yet
decided and could easily decide the wrong way. In exchange for that, the dividend forfeits every
safe harbour the current, maximally favourable SEC has built, **by the express words of those safe
harbours**, since all three non-security categories in the March 2026 Interpretation are defined as
assets that do not generate a passive yield or convey rights to future income.

**Recommendation, in priority order:**

1. **Ship the launchpad with holder dividends OFF and no US-facing option to turn them on, until
   counsel signs off.** This costs no contract work: `creatorBps = BPS` already yields
   `toHolders = 0` at `FeeHook.sol:919-920`. Keep the creator fee and the burn — footnote 60 of the
   2026 Interpretation blesses the creator-royalty shape by name, and expressly on the ground that
   the *holder* gets none of it.
2. **Do not deploy to mainnet with the dividend on while the operator is a US individual.** The
   combination of (US person) × (transaction-based compensation) × (published yield projection) ×
   (custody of holder funds in the Distributor) is worse than any one of them.
3. **Decide and document who runs the sweep keeper**, because it is the hinge of the only prong
   currently protecting the product. If a platform bot is required for dividends to arrive, say so
   internally and assume prong 4 is contested.
4. **Add a §17(b)-style disclosure now, regardless.** One line on every token page and board card:
   the platform receives 1% of this token's trading volume. Costs nothing, closes the cheapest
   exposure in the memo, and is required by FTC rules whether or not anything is a security.
5. **Do not switch to same-token payouts thinking it helps.** It moves toward SafeMoon.
6. **Preserve the two structural facts that are genuinely good** and would be expensive to rebuild:
   the creator never sells anything (all supply goes to a locked AMM position), and the platform
   cannot raise its own take.
7. **Watch two dockets:** *Aguilar v. Baton Corp.*, No. 1:25-cv-00880 (CM) (S.D.N.Y.) — the launchpad
   statutory-seller theory, MTD briefing completed Feb. 2026, no merits ruling as of this pass; and
   the CLARITY Act cloture vote of Sept. 15, 2026.

**Confidence levels, stated separately because they differ a lot:**

| Proposition | Confidence |
|---|---|
| The dividend forfeits the 2025-26 SEC safe harbours by their own express terms | **High (~90%)** |
| The dividend materially increases securities risk vs. a creator-fee-only launchpad | **Moderate-high (~75%)** |
| Horizontal commonality is satisfied by `Distributor.sol:272` | Moderate-high |
| A court, today, would actually hold a hoodstonk token was sold as an investment contract | **Low (<50%)** — prong 4 is a real defence and this Commission is not looking for the case |
| The platform faces a *current-Commission* exchange/broker/clearing action | Low |
| The platform faces a **private** §12(a)(1) or state blue-sky claim if a launch goes badly wrong | Moderate — and this is the exposure that does not care who chairs the SEC |
| The 1% is federal money transmission on the trading path | Low |
| The Distributor's push payments raise a real §1960/state MTL question worth counsel | Moderate |

**The single strongest argument against the product as built**, stated as an adversary would:

> Every category of crypto asset the SEC has declared not to be a security — digital commodities,
> digital collectibles, digital tools — is defined by the Commission in the same words: it "does not
> have intrinsic economic properties or rights, **such as generating a passive yield or conveying
> rights to future income, profits, or assets** of a business enterprise or other entity." The
> February 2025 meme coin statement says a meme coin is not a security because, among other things,
> "**it does not generate a yield or convey rights to future income**." A hoodstonk token generates
> a passive yield, in a third asset, pro-rata by balance, with no action by the holder, out of a
> pooled fund held at a contract address, at a rate the platform publishes as an annual percentage
> on its own launch form. It is not any of the three non-security categories, by their terms. And
> the platform that wrote the mechanism, deployed it, published the yield figure and takes one
> percent of every trade forever is not a bystander to the offer.

**The shortest structural change that materially reduces exposure:** stop offering holder dividends —
set `creatorBps = BPS` so `FeeHook._routeFee:920` computes `toHolders = 0`. Zero contract changes,
zero redeployment, one UI switch removed. It is also, unavoidably, the change that deletes the thing
that makes hoodstonk hoodstonk.

---

## 7. What a lawyer needs to be asked

Bring the code. These questions are answerable in one meeting if the questions are this specific.

**Threshold**
1. Given `Distributor.sol:272` — a pro-rata division of a pooled fund of third-party assets, by
   token balance, with no holder action — is horizontal commonality under *Revak* satisfied? Is that
   different from a pure memecoin, and by how much?
2. Does an annualised yield percentage rendered on the launch form (`Launch.tsx:533-542`) constitute
   an *offer* of the launch token by the platform, and does that make the platform a *Pinter*
   solicitor notwithstanding *Risley*?
3. Is a permanent, immutable economic property of a token (passive yield) analysable under the 2026
   Interpretation's §IV separation doctrine at all, or does it sit permanently in §III? If §III,
   does decentralisation do anything for us?
4. Under the March 2026 taxonomy, what *is* a yield-bearing memecoin? A hybrid? An uncategorised
   residual? A digital security? Is there any category it lands in that is not adverse?

**Operational**
5. If the platform (or a platform-funded bot) calls `FeeHook.sweep()` so that dividends actually
   arrive, does that constitute "essential managerial efforts" under *Howey*'s fourth prong, or is it
   ministerial under *E.F. Hutton Mortgage* / *Donovan v. GMO-Z.com*?
6. Does the `Distributor` holding pair currency owed to identified holders between sweep and
   withdrawal (`Distributor.sol:460, 482`) create custody, transfer-agent (§17A(c)), or clearing-
   agency questions? **Is there any authority applying transfer-agent registration to a dividend
   smart contract?** (I could not find any.)
7. Does the permissionless push path `processBatch` — value taken from a trader mid-swap and
   delivered to third parties who took no action — constitute money transmission under §1960 or under
   any state MTL, given FIN-2019-G001's "total independent control" test and the Storm conviction?
   Which states need a specific answer?

**Structural / go-forward**
8. Confirm the reading of footnote 60 of Release 33-11412: does an automatic on-chain fee paid
   **only** to the creator leave the token inside the digital-collectible bucket, and is that
   reasoning transportable from NFT royalties to fungible-token trading fees?
9. Is `creatorBps = BPS` (holder wedge zero) sufficient to get there, or does the *presence of the
   capability* in deployed, permissionless code matter?
10. If the operator remains a US individual, is frontend geoblocking worth doing at all — and if it
    is done, must it be done to the CFTC-Uniswap standard or not at all?
11. What is the exposure of a creator who takes an uncapped vested dev buy (`Launcher.sol:503-510`)
    and later sells into the pool? Issuer/affiliate distribution? Underwriter?
12. Entity structure: what does a US individual need between themselves and the 1%? Does it help at
    all against §12(a)(1), §17(b), state blue sky, or a state MTL?
13. Is a §17(b)-style disclosure of the 1% required today on the board and token pages, and what
    exact language?

**Housekeeping to verify before anyone relies on this memo**
14. Current status of *SEC v. SafeMoon LLC*, No. 1:23-cv-08138 (E.D.N.Y.) — live, stayed, or
    dismissed? I could not confirm.
15. Date and terms of the dismissal of *SEC v. Binance Holdings Ltd.*, No. 1:23-cv-01599 (D.D.C.) —
    reported in secondary sources, not verified here.
16. The Sept. 2021 CFTC settlement with dYdX Trading Inc. regarding US access — recalled but **not
    verified in this pass**. Do not cite it without pulling the order.
17. Any *Aguilar v. Baton* ruling on the motions to dismiss filed Jan. 23, 2026.

---

## Appendix — sources actually consulted, with verification status

**Verified primary (retrieved and read in this pass)**
- *Application of the Federal Securities Laws to Certain Types of Crypto Assets and Certain
  Transactions Involving Crypto Assets*, Release Nos. 33-11412; 34-105020; File No. S7-2026-09,
  91 Fed. Reg. 13714 (Mar. 23, 2026), effective Mar. 23, 2026 — full Federal Register text.
- *Regulation Crypto Assets*, Release No. 33-11434; File No. S7-2026-27 (proposed Aug. 18, 2026;
  published 91 Fed. Reg., Aug. 21, 2026; comments due Oct. 20, 2026).
- SEC Division of Corporation Finance, *Staff Statement on Meme Coins* (Feb. 27, 2025).
- *SEC v. Ripple Labs*, No. 20 Civ. 10832 (AT), Order (S.D.N.Y. July 13, 2023).
- *SEC v. Coinbase, Inc.*, Opinion and Order (S.D.N.Y. Mar. 27, 2024) (Failla, J.); joint stipulation
  of dismissal with prejudice (Feb. 25, 2025).
- *Risley v. Universal Navigation Inc.*, 2025 WL 615185 (2d Cir. Feb. 26, 2025) (summary order).
- *SEC v. SafeMoon LLC*, Complaint, No. 1:23-cv-08138 (E.D.N.Y. Nov. 1, 2023); SEC Press Release
  2023-229; Litigation Release No. 25888.
- *United States v. Karony*, No. 1:23-cr-00433 (E.D.N.Y.), post-trial Memorandum & Order (Rule 29/33).
- DOJ EDNY / IRS-CI releases, Karony sentencing, Feb. 10, 2026 (100 months).
- *Combs v. SafeMoon LLC*, No. 2:22-cv-00642-DBB-JCB (D. Utah), order granting preliminary approval,
  June 22, 2026 (recording that only the §12(a)(1) claim survived the Mar. 29, 2024 MTD order).
- *SEC v. LBRY, Inc.*, No. 21-cv-260-PB (D.N.H.), summary judgment (Nov. 7, 2022), remedies
  memorandum, and final judgment.
- *SEC v. Payward Ventures (Kraken)*, Complaint and SEC Press Release 2023-25 (Feb. 9, 2023).
- *SEC v. Binance Holdings Ltd.*, Complaint, No. 1:23-cv-01599 (D.D.C. June 5, 2023).
- *SEC v. Rari Capital, Inc.*, Complaint (Sept. 18, 2024).
- *Aguilar v. Baton Corp. Ltd.*, No. 1:25-cv-00880 (CM) (S.D.N.Y.): consolidated amended complaint,
  Baton and officer motions to dismiss, and the Dec. 9, 2025 order granting leave to amend.
- SEC, *Notice of Withdrawal of Proposed Regulatory Actions*, Release 33-11377 (June 12, 2025;
  effective June 17, 2025) — including the Rule 3b-16 exchange-definition amendments.
- CFTC, *In re Universal Navigation Inc. d/b/a Uniswap Labs*, order and Release 8961-24
  (Sept. 4, 2024).
- FinCEN, FIN-2019-G001 (May 9, 2019), §§4.5.1(a)-(b) and the CVC-wallet control rubric.
- Blog post, *A Win for DeFi — SEC Closes Investigation into Uniswap Labs* (Feb. 25, 2025).
- Chairman Atkins, *The SEC's Approach to Digital Assets: Inside "Project Crypto"* (Nov. 12, 2025);
  *American Leadership in the Digital Finance Revolution* (July 31, 2025).
- H.R. 3633 (CLARITY Act) congressional record and Senate Banking materials.

**Secondary, used only for dates and procedural context** — Reuters, CoinDesk, Bloomberg, Law.com,
The Block, DL News; and law-firm client alerts from Davis Polk, Morrison Foerster, Greenberg Traurig,
Debevoise, Jones Day, Paul Weiss, Skadden, Sullivan & Cromwell, Mayer Brown, Venable, Cravath and
Ballard Spahr.

**Explicitly NOT verified — do not cite without checking**
- Current status of the SEC's civil SafeMoon case.
- Date and terms of the *SEC v. Binance* dismissal.
- The Sept. 2021 CFTC settlement with dYdX Trading Inc.
- Any second SEC or state enforcement action against a reflection/rewards-token *design*. I looked
  and could not find one. A gap I can name is worth more than a citation I invented.
