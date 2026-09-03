# Round 2 — the v4 hook and the sweep fix

22 tests in `test/audit/round2/HookAudit2.t.sol`, both currency orderings, against pools seeded
the way `Launcher` actually seeds them (single-sided) rather than the symmetric full-range pool
the older `FeeHookHarness` builds. All pass. Suite went 634 → 668, 0 failing.

## Verdict

**The sweep-brick fix holds, and the brick is dead.** No severity above INFORMATIONAL was found on
this surface.

## The finding that matters most is that the branch is nearly unreachable

`test_R2H_01_aLauncherPoolOnlyEverDefersRoundingDust` establishes something stronger than the fix
was designed for:

> On a pool seeded by `Launcher`, the tokens that become `pendingTokenFees` are tokens a BUY
> previously pulled out of the range. The amount the range can reabsorb walking spot back to the
> opening tick is exactly the amount it has given out — same `L`, same integral. So
> `pile <= reabsorbable` always. The conversion swap can at worst walk spot back to the opening
> tick; it can never walk THROUGH it, which is the only way to run out of liquidity or to reach
> the price limit.

The one thing that does leak is ROUNDING. `SwapMath.computeSwapStep` rounds the input a swap needs
UP and the output it delivers DOWN — in the pool's favour both directions — so putting the pile
back costs a few wei more than taking it out returned. **Measured in the low hundreds of wei
against a pile of 5.0e25.** That residue is the only thing that reaches the re-mint branch on a
real launch.

So the round-1 HIGH was real as written, but it required a pool shape the launcher cannot
produce. The fix is now defence-in-depth rather than a live patch — and `test_R2H_04` confirms a
carried residue keeps `sweep` permanently live rather than accumulating into a new brick.

## What was verified sound, with the inputs

- **The re-mint closes the delta to the wei** (`R2H_10`), with a NEGATIVE CONTROL (`R2H_10b`)
  showing that reading `spent` off the PAIR side instead of the token side fails to settle. That
  control is what proves the sign convention is actually load-bearing rather than incidentally
  correct in one ordering.
- **The skip branch is an exact idempotent no-op** (`R2H_11`) — nothing burned, no delta opened,
  and the pair-currency leg still pays out.
- **`pendingTokenFees` is always backed by a real ERC-6909 claim** (`R2H_12`), so the re-mint can
  never conjure a claim from nothing, and a carry on one pool never touches another's claims
  (`R2H_16`) despite the PoolManager being a singleton.
- **A carried pile converts in full once buying rebuilds the pair side** (`R2H_13`), and
  **repeated sweeps on a carried pile cannot out-earn one sweep** (`R2H_14`) — no bounty farming.
- **Fuzzed conservation** (`testFuzz_R2H_15`): over random trade sequences every sell fee is
  either converted or still queued, never lost. `testFuzz_R2H_01b` confirms no trade sequence
  defers more than dust.
- **Front-running the conversion costs the attacker more than it moves** (`R2H_19`), and a carried
  pile converts new buying rather than letting it lift the price (`R2H_20`).
- **The hook never assumes instant holder credit** (`R2H_03`) — it is unaffected by the switch to
  streamed distributions.

## INFORMATIONAL — a pool property worth documenting in the UI

`test_R2H_17_aPinnedPoolRejectsEverySellUntilSomebodyBuys`.

Once spot sits at `MIN_SQRT_PRICE + 1` (or `MAX_SQRT_PRICE - 1`), `Pool.swap` reverts
`PriceLimitAlreadyExceeded` for any caller whose limit is that same extreme — which is what every
router sends by default, and the only limit that can legally be passed in that direction, since a
valid limit must be strictly beyond spot and there is nothing beyond it.

**The token cannot be sold at all in that state. Buys still work, and a buy is what lifts spot
back off the pin.** This is a Uniswap v4 pool property, not a hook bug, and it is exactly the
state the skip branch exists to keep `sweep` alive through. Worth saying on the token page rather
than letting a holder discover it as "my sell keeps failing".

## Not re-examined

The round-1 economic findings on this surface (E-01 block-0 snipe, E-02 forgeable graduation) are
unchanged by the sweep fix and remain open design decisions, not bugs.
