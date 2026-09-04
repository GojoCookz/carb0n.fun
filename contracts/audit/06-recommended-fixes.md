# Recommended fixes, informed by how Flap actually does it

## What Flap does, read from a live contract

`MarsCoin` on BSC, `0xFe189E97832DA1573e4e4Ff034F4fFC3a15c7777`. It is an EIP-1167 clone of
`FlapTaxTokenV3` at `0x024f18294970b5c76c0691b87f138a0317156422`. Live values, read on chain
rather than taken from a listing:

```
buyTaxRate                     300     (3%)
sellTaxRate                    300     (3%)
antiFarmerDuration           2592000   (30 DAYS)
antiFarmerExpirationTime    1787750591 (expired - this launch is past its window)
taxExpirationTime           4938758591 (effectively permanent)
liquidationThreshold        400_000e18 (tokens, before tax is converted)
liqExpectedOutputAmount         100e18 (MINIMUM OUTPUT - slippage protection)
MIN_LIQ_THRESHOLD            50_000e18
START_LIQ_THRESHOLD         400_000e18
dividendContract            0xBBA9d212...  (separate clone)
taxProcessor                0xeCaeDd9A...  (separate contract)
```

Four design decisions worth stealing, each of which maps onto a finding from the audit:

### 1. Conversion is BATCHED behind a threshold, and the threshold ADAPTS
Tax accumulates as tokens and is only converted when it crosses `liquidationThreshold`. The
threshold starts at `START_LIQ_THRESHOLD` and can fall to `MIN_LIQ_THRESHOLD` — an
`_adjustLiquidationThreshold` walks it down when liquidation fails, so a pool that cannot absorb
400k tokens tries 50k instead.

**Our equivalent is broken.** `FeeHook.unlockCallback` burns the ENTIRE `pendingTokenFees` claim
and sells it in one swap, with no threshold and no retry. That is audit 01's HIGH: once the pile
outgrows the pool's pair reserve, the swap cannot fill, the call reverts, and `sweep` is the only
thing that clears the pile — so it reverts forever.

### 2. The conversion swap has a MINIMUM OUTPUT
`liqExpectedOutputAmount = 100e18`. If the swap cannot return that, it does not happen.

**We have no slippage protection at all** on either the sell-fee conversion or the buyback. That
is audit 05's E-05: both swaps are predictable, on-chain and sandwichable.

### 3. Liquidation is triggered INSIDE A TRANSFER, not by a callable function
There is no `liquidate()` an attacker can call. It fires as a side effect of a transfer that
crosses the threshold, so to control the timing you must BE that transfer, and you pay tax to be
it.

**This is the root of our CRITICAL.** `sweep()` is a standalone permissionless function paying a
bounty. Anyone can call it at any instant, for a few hundred thousand gas, and `distribute` splits
against the share register at exactly that instant. The attacker does not have to guess the
moment — they choose it.

### 4. An anti-farming window exists at all
`antiFarmerDuration = 30 days`. Whatever it does precisely, they thought farming was worth a
dedicated mechanism and a stored expiry.

---

## The fixes, in the order they should be done

### FIX 1 — CRITICAL: dividend entitlement must not be instantaneous

The attack is `buy -> sweep -> sell -> withdraw` in ONE transaction: +4.87 pair on 40 in, zero
blocks held, honest holders lose 83%. Measured in `test/audit/EconAudit.t.sol`.

Rate-limiting `sweep` does not fix it. Making `sweep` permissioned does not fix it either — it
just moves the timing power to whoever holds the permission, and a keeper's transaction is public
in the mempool anyway.

**The fix is to stop distributing in a single instant. Stream it.**

Keep the magnified accumulator exactly as it is, but have `distribute` add to a `streamed` pot
that releases linearly over a window (a few hours of blocks), rather than crediting
`_magnifiedPayoutPerShare` all at once. Anyone touching the accumulator first releases whatever
has vested since the last touch.

Why this works and the alternatives do not:
- An attacker who buys, triggers a release and sells in one transaction captures only the sliver
  that vested in that block — a rounding error, against the buy and sell tax they just paid.
- To capture a meaningful share they must HOLD across the window, which is price risk. That is
  the same thing an honest holder does, which is the point: the exploit becomes indistinguishable
  from investing.
- It needs no new trust, no keeper, no permission, and no snapshot bookkeeping.
- It is compatible with everything already built. `distribute` keeps its signature.

Secondary, cheap, and worth adding alongside: **new shares should not accrue immediately.** A
balance increase starts earning after a short delay. This kills the same-block case outright even
before the stream matters.

### FIX 2 — HIGH: stop `sweep()` from bricking

Adopt Flap's threshold-and-retry directly:
- Convert at most `min(pendingTokenFees, liquidationThreshold)` per sweep instead of all of it.
- If the swap cannot fill, halve and retry, down to a floor — the halve-and-retry pattern already
  documented in `tasks/basestonk-port.md` but never implemented on this path.
- Never let the conversion leg revert the whole sweep. Wrap it so the pair-currency fees queued in
  the same call still pay out.

### FIX 3 — HIGH: the converter double-payment

`Distributor._trySend` decides success from the converter's return value alone and never checks
the allowance was consumed, so an honest converter that pulls its input and returns `0` gets paid
AND the fallback pays again. Check the allowance delta, not the return value. Zero the allowance
before the fallback branch.

### FIX 4 — HIGH: dividends pushed to a VestingVault are unrecoverable

`processBatch` is permissionless and the vault's claim reverts when nothing is withdrawable, so a
pushed payout is stranded permanently. Either exclude vaults from the push queue, or give the
vault a sweep that forwards its whole `payoutToken` balance rather than a delta.

### FIX 5 — MEDIUM: slippage protection on both internal swaps

Give the sell-fee conversion and the buyback a minimum output, like `liqExpectedOutputAmount`.
Without it both are free sandwiches, and the burn wedge can be starved by 14.92% as a side effect
of somebody else's attack (E-05).

### FIX 6 — deployment, not code

The Sepolia `ReferralVault` is orphaned: `platformRecipient` is immutable on the hook and was set
to the deployer before the vault existed, so `credit()` is unreachable for that hook's life. The
hook address is MINED, so the deploy order can be fixed — deploy the vault against the predicted
hook address first. Requires a redeploy, not a code change.

---

## What NOT to copy from Flap

- **Their tax is mutable and owner-controlled** (`taxExpirationTime`, an owner, an upgradeable
  proxy). Ours is immutable at launch, which is a stronger promise to buyers. Keep it.
- **`antiFarmerDuration` as a launch-window timer** does not solve continuous front-running, only
  the opening. The streaming fix above is strictly better and covers the whole life of the token.
