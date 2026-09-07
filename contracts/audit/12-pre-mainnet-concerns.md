# 12 — Everything I would want fixed before mainnet

Written by the agent that did the remediation work in `09-remediation.md`, `10-zap-router.md` and
`11-external-bsc-contracts.md`. It is a list of what is NOT settled, deliberately biased toward
things that would cost real money rather than things that are merely untidy.

**Read the first section before the rest.** The blockers are not code.

---

# BLOCKERS — do not deploy to mainnet until these are cleared

## B-1. There has been no third-party audit

Two reviews exist. Synergy's, and mine. Both were done by parties close to the code, and mine
covers code I also modified.

> An audit of code you also wrote is a review, not an audit.

Everything in `audit/01` through `audit/11` should be read as *findings from the people who built
it*. That is worth something — 1506 tests and eleven surfaces is not nothing — but it does not
substitute for someone whose incentive is to make us look wrong. Every serious loss in this
category of product was in code its authors believed was finished.

**Clear it by:** commissioning an external review before any mainnet deployment holds user funds.

## B-2. The deploy key is the compromised one

The deployer at `0xc286b1956c7691d678520e370727D8aB57328556` has a **permanently public private
key**. It holds the Sepolia deployments and is still the key in use.

The decision to move to a fresh key was taken and has not been executed.

**Clear it by:** generating a fresh key, funding it, and deploying mainnet from it. The Sepolia
addresses stay where they are; nothing needs migrating. A hardware wallet or multisig is better
than a fresh EOA for anything holding a privileged role, but a fresh EOA is the minimum and the
current state is below the minimum.

## B-3. Nobody has ever launched a token from a browser wallet

`app/e2e.ts` passes 12/13 and `tradeTest.ts` passes 6/6, but both drive transactions from a script
holding a raw private key. That proves the ABI encoding and the contract logic. It proves nothing
about the wallet path: chain-switch prompts, `eth_sendTransaction` shape, gas estimation through a
provider, EIP-1559 fields, rejection handling, or what the UI does while a transaction is pending.

Rule 2 of the house rules applies exactly: **a rendered screen with dead buttons is not a feature.**
Nobody has clicked launch and watched a wallet popup appear.

**Clear it by:** one human, one browser, one wallet, one launch on Sepolia, end to end, before the
same flow is pointed at mainnet.

---

# CHAIN — mainnet is not a config change

## C-1. Everything that exists is Sepolia

Verified four independent ways: the only chain id in `broadcast/` is `11155111`; there is no code
at any of our addresses on mainnet; `DEPLOYMENTS.mainnet` is `null` throughout; and
`LAUNCH_CHAIN = sepolia`.

The mainnet addresses in `ADDRESSES.mainnet` are **read-only** — price display and `pairDepth.ts`.
Nothing has ever been deployed to mainnet.

## C-2. Sweep economics were measured under testnet assumptions

> **MEASURED UPDATE.** At the time of writing, Ethereum mainnet `baseFeePerGas` read **0.040 gwei**
> from the block header at block 25,920,987 — **500x below the 20 gwei these figures assume.** At
> that price the break-even is trivially cleared, a full deployment (hook, launcher, vault, a
> launch, a buy and a sweep) costs on the order of **0.0005 ETH**, and this concern is close to
> inert *today*.
>
> **The risk was never the median, it is the tail.** Gas is volatile; the failure mode is that
> during a busy period the bounty stops covering the caller's gas, nobody sweeps, and holders
> silently stop being paid until it clears. The mitigation to consider is still the same — scale
> the bounty with `block.basefee` rather than fixing it — but the urgency is much lower than the
> original wording implied, and a mainnet test launch is now cheap enough that it should not be
> gated on this.

`SweepEconomics.t.sol` establishes break-even at **0.339 pair warm, 0.814 fresh, 1.451 with a 30%
burn, at 20 gwei.** Those numbers are a function of gas price, and mainnet gas is neither 20 gwei
nor stable.

Consequence if ignored: below break-even the sweep bounty does not cover the caller's gas, nobody
sweeps, and fees accrue as claims that never convert. That is not a loss of funds — the accounting
is pull-based and nothing is destroyed — but the product silently stops paying holders.

**Do:** re-derive break-even at realistic mainnet gas before launch, and decide whether the bounty
needs to scale with `block.basefee` rather than being a fixed share.

## C-3. Real pair liquidity is thinner than the roster suggests

`app/src/lib/ethRoute.ts` holds measured v4 ETH depth per pair: **11 GOOD, 3 THIN, 24 UNUSABLE**
out of 36. Two-thirds of the roster cannot currently be zapped into on mainnet v4.

This is not a bug — the Z-14 fallback exists precisely because hop-1 pools are somebody else's and
can be thin or exhausted. But a creator choosing an UNUSABLE pair gets a token nobody can zap into,
and the UI should say so at selection time rather than at first failed trade.

---

# DESIGN DECISIONS THAT ARE OPEN, NOT WRONG

## D-1. `ZapRouter` does not pin `tokenKey.hooks`

`_run` validates that the pair currency appears in `tokenKey` (`PairIsNotInTheLaunchPool`). It
never checks that `tokenKey.hooks` is our `FeeHook`.

In v4 anyone can initialise a hookless pool for the same pair. Our router will route a buy through
it and collect nothing. `test_negativeControl_aRouteWithNoHookOnItChargesNothingAndStillSucceeds`
in `ZapRouter.t.sol` already documents this, deliberately, as the control that stops the fee
assertions passing vacuously.

**Why it may be fine:** they could trade that pool directly without our router, so pinning does not
prevent fee-free trading. It only stops our router being the instrument.

**Why it may not be:** aggregators and searchers find the cheapest route by construction. If the
hookless pool is cheaper, our own router becomes the path of least resistance to zero fees.

**Investigated and found NOT to be an issue on the sell side:** sells are not charged at all
(`test_everyBuyShapeIsChargedAndNoSellIs`), so there is no sell-side fee to bypass. A test written
to prove otherwise failed its own negative control — the canonical sell accrued exactly as much as
the hookless one, which is zero. Recorded so nobody re-derives it.

**Decide explicitly, either way, and write the decision down.**

## D-2. `beforeInitialize` guards our hook, not our token

`FeeHook.beforeInitialize` reverts `NotConfigured` for pools the Launcher did not configure, and
`test_strangerCannotOpenAPoolAgainstThisHook` holds. But it only runs for pools that name
`FeeHook`. A pool naming `address(0)` never calls us, so a second market for any launched token can
always exist.

This is inherent to v4 and not fixable at the hook. The mitigation is that the canonical pool holds
the liquidity. Worth stating out loud to creators rather than implying exclusivity.

---

# SMALLER THINGS, RANKED

| # | Concern | Why it matters |
|---|---|---|
| S-1 | Opening fee is **off by default** | `MAX_OPENING_WINDOW=300s`, `MAX_OPENING_FEE_BPS=9900`, measured 32x snipe cost. Excess routes to the platform via `pendingOpeningFees` so creators cannot self-snipe. Defaulting it off is a choice; a launch sniped in block 1 will ask why. |
| S-2 | The repo is **public** | It contains the securities memo, the full findings list, and this file. That is a deliberate transparency posture, but it also hands an attacker the map. Confirm it is intended. |
| S-3 | No fee on sells | Deliberate, and `sellPlatformShareBps` derives the platform's take from the sell rate (F-02 took it from 1052 bps to 52 bps). Confirm the mainnet economics still work with buy-side-only fees. |
| S-4 | `E-05` bounds the buyback but **not** the sell-conversion leg | Bounding the sell leg was tried and REVERTED: it made the bounty farmable by fragmentation (145.98 vs 42.43) and broke `R2H-14` and F-05. The asymmetry is intentional. Do not "fix" it without reading `09-remediation.md`. |
| S-5 | Fork tests are excluded from the green run | The suite is green under `--no-match-contract Fork`. Fork tests exercise real mainnet pool state and are the closest thing we have to a mainnet rehearsal. Run them against a mainnet fork before launch. |

---

# WHAT IS ACTUALLY SOLID

Stated so the list above is read in proportion.

- **V-01/V-02** — the auto-sweep 8.5x overcharge class is dead, with a structural guard
  (`test_V02d_fixed_noErc20LeavesTheSingletonDuringASwap`) rather than a spot check.
- **E-03** — instant-credit buy-claim-sell is gone; the migration to streaming killed it. This is
  the bug that is still live in most of the copy-pasted dividend trackers in the wild, including
  every file reviewed in `11-external-bsc-contracts.md`.
- **Z-14** — a single exhausted ETH pool no longer refuses every zap; candidates are validated
  up front and the first unpinned one is taken.
- **A-8** — the three-way deploy circularity is asserted at deploy time, not hoped for.
- **No LP hooks at all.** `beforeAddLiquidity` through `afterRemoveLiquidityReturnDelta` are all
  `false`, so there is no hook code in the liquidity path to grief, and no `totalShares == 0`
  division anywhere in `src/` to brick on.
- **No unbounded holder loop.** The only loops are over a config schedule and at most four pool
  keys. The shareholder-array growth failure in `07-dividend-tracker-lineage.md` and
  `11-external-bsc-contracts.md` §12 cannot happen here.
- **Pull-based claims.** Dividend accounting does not sit in the token's transfer path, so a failed
  conversion cannot stop trading and cannot destroy accrued claims.
- **1506 tests passing**, both currency orderings throughout, with negative controls used
  systematically to catch vacuous passes — including one in this session that correctly killed a
  test of mine that was measuring nothing.

---

## One honest note on method

Several conclusions in this file and in `11` came from reading deployed bytecode and on-chain
storage rather than the source in front of me, and in two cases the source and the chain disagreed
in ways that mattered. Assume the same discipline is required for anything mainnet: **resolve the
address, do not trust the comment.**
