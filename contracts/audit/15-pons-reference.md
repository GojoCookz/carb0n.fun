# 15 — Pons: the incumbent on the home chain, and the product it is not

`pools.trade` (ponsfamily). The dominant launchpad on Robinhood Chain, examined because we deploy
into its market. Its platform token PONS is the deepest pair on the chain — the PONS/WETH V3 pool
alone shows ~$6.9M liquidity and ~$9.2M 24h volume, with a second V4 pool at ~$4.2M/$36.7M
(DexScreener, at the time of writing; treat as indicative, not verified).

Two findings frame everything below:

1. **Pons shipped a v1 and a v2 that are different protocols.** v1 is a Uniswap **V3** instant-pool
   launcher; v2 is a Uniswap **v4** bonding-curve launchpad with graduation, a fee hook, and a
   buyback vault. The v1→v2 diff is a confession list, and it is long.
2. **Nothing in Pons pays holders.** Every fee stream — curve fee, hook fee, creator tax, snipe
   tax — resolves to the *protocol* and the *creator*. There is no distributor, no dividend, no
   holder-facing payout anywhere in the verified source. The component this repo is built around
   simply does not exist there. That is the gap we occupy, on their chain.

Read alongside `13-marscoin-reference.md` (the O(1) property) and `14-basestonk-reference.md`
(the v4 mirror). Pons is the third leg: same chain, adjacent product, different promise.

---

## 1. Platform map

All addresses Robinhood Chain (4663). "cast" = read live via `cast call` against
`rpc.mainnet.chain.robinhood.com`; "source" = verified Solidity pulled from Blockscout's
`/api/v2/smart-contracts/` endpoint; "bytecode" = unverified, runtime bytes only.

**v1 (live since 2026-07-13, block 8,600,612 — creation tx `0xec8a7f6d…`, deployer EOA `0xda4bCee7…2043968`):**

| Contract | Address | Size | Evidence |
|---|---|---|---|
| `PonsLaunchFactory` | `0x0c37a24F5D23A486FA692d1500881d698B1F77a4` | 24,192 B | **bytecode only, unverified**; `owner()`, `locker()`, `launchFee()` = 0.0005 ETH, `getLaunchedToken()` probed via cast |
| `PonsLaunchLocker` (v1) | `0x31CA5E101941a93a7dd6D0497928700625cf54B5` | 4,861 B | **bytecode only, unverified**; `factory()`, `protocolFeeRecipient()` via cast; interface known from v1 token's `ILaunchpad.sol` |
| `PonsLauncherToken` (PONS itself) | `0x39dBED3a2bd333467115dE45665cC57F813C4571` | 5,274 B | **source** (solc 0.8.30); full deployment, not a clone |
| Uniswap V3 factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` | 24,535 B | cast via token's `dexFactory()` |
| V3 `NonfungiblePositionManager` | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` | 24,384 B | cast via token's `positionManager()` |
| PONS/WETH 1% V3 pool | `0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA` | 22,142 B | cast via token's `liquidityPool()` |

**v2 (live since 2026-08-03, block 26,841,846 — creation tx `0x3817f297…`):**

| Contract | Address | Evidence |
|---|---|---|
| `PonsV2LaunchFactory` | `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e` | **source** (72,767 chars, solc 0.8.35), shipped inside every verified V2 token bundle |
| `PonsV2MemeHook` | `0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044` (15,167 B) | **source**; address low bits `0x2044` match `getHookPermissions()` |
| `PonsV2FeeEscrow` | `0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e` | **source** (verified directly) |
| `PonsV2BuybackVault` | `0x42df2a798f82289E177311362e8f5ccC45c1219c` | **source** |
| `PonsV2LaunchLocker` | `0x267444D099b10fB5Ed7c3Cc7B7c767AdcA574952` | **source** |
| `PonsV2GraduationGuard` | `0xf5695117b99B6f6401e67d4195BD653628176C6C` | **source**; wiring via `factory.graduationGuard()` |
| v4 `PoolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | cast via `factory.poolManager()` |
| v4 `PositionManager` | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` | cast via `factory.positionManager()` |
| `PonsV2BondingCurve` (one per launch) | e.g. `0x423f79856A743e090dCcFf11B835b64a022e3257` | **source**; ≥17 verified instances |
| `PonsV2LauncherToken` (one per launch) | e.g. `0x7643470c8D719303f201A1744bFB67FC78F438fa` | **source**; ≥521 verified instances |

Control everywhere resolves to one EOA: `0x263ed295dAFaE1d9AAdD6E56c4B6F9f38eE019Dd` is the owner
of the v1 factory, the v1 locker's `protocolFeeRecipient`, the v2 factory, the hook, and the hook's
`protocolFeeRecipient`. The `feeSweepOperator` is `0x49BbF2b70955Fb3a106e084D4BFDa92d334573d2`.
Tokens are **full deployments via CREATE2, not EIP-1167 clones** — the starting assumption of a
shared clone implementation was wrong, and the launch `salt` doubling as a vanity-address miner is
the reason they chose it.

---

## 2. v1 → v2: what the diff confesses

Three weeks separate the two systems. What they changed is what broke.

### 2a. V3 LP-fee economics → v4 hook economics, via a bonding curve

v1 launches straight into a V3 pool at a 1% fee tier (`poolFee() = 10000` on PONS), locks the LP
NFT in the v1 locker, and the platform's entire revenue is **LP fees**, collected through the
locker (`IPonsLaunchLocker.setFeeRedirect` lets the creator redirect their share). Fee rate frozen
by the tier; split machinery welded to an NFT; nothing per-launch configurable.

v2 inverts all of it: a constant-product bonding curve (phantom quote reserve 1.68 ETH, graduation
at 4.2 ETH real quote, config 0 live via cast) graduates into a v4 pool whose **core LP fee must be
zero** (`CoreLpFeeMustBeZero` is a factory error; config 0 has `poolFee = 0`) and every basis point
flows through `PonsV2MemeHook.afterSwap` instead. The LP position earns nothing; the hook earns
everything. That is a complete rejection of LP-fee-tier economics in favour of exactly the
hook-collected model this repo uses.

The hook's permissions are `beforeInitialize | afterSwap | afterSwapReturnDelta` = `0x2044` —
**bit-for-bit identical to BaseStonk's `AdvancedFeeHookV6`** (see `14` §2), fee taken from the
unspecified currency, selected by the sign of `amountSpecified`. Two independent teams on two
chains landed on the same flag set; our `0x20CC` with `beforeSwap` remains the deliberate outlier,
for the pair-denominated-fee reason documented in `FeeHook` itself.

### 2b. Transfer-hook policing → priced sniping

The v1 token polices its own `_update`: buys from the canonical pool revert in the launch block
(`LaunchBlockBuyBlocked`), then for 366 blocks enforce a 2% max wallet and a **cumulative**
per-recipient 2.2% buy cap (PONS live values via cast), with a factory-opened one-recipient
exemption for the atomic dev buy.

The v2 token contains **none of that** — it is a dumb ERC20+Burnable, 106 lines, whose whole job
is minting supply to the curve. Anti-snipe moved into the curve as a **tax, not a block**: 9,900
bps in the launch second decaying exponentially to zero over 3 seconds (live via cast; caps
`MAX_SNIPE_TAX_START_BPS = 9_900`, `MAX_SNIPE_TAX_SECONDS = 60`, ≤32 exemptions), and the proceeds
**join the ordinary fee split**. The comment in `buy()` is explicit: *"a 99% take in the launch
second is the entire point."*

What this confesses: block-window wallet caps are sybil-trivial and punish honest buyers, and a
token that reverts transfers is a token integrators hate. v2 prices sniping instead of forbidding
it, and monetizes the sniper. Note the number: **9,900 bps is the same ceiling as our
`MAX_OPENING_FEE_BPS` and BaseStonk's `SNIPER_MAX_BPS`** — third independent convergence on the
exact constant. Our opening-fee window (`MAX_OPENING_WINDOW = 300s`) is the same mechanism with a
longer decay.

### 2c. Owner-trust patched with freezes, timelocks, and pins

v1's fee routing was owner-mutable (locker redirect, unverified factory). v2 is saturated with
machinery whose only purpose is bounding their own owner:

- **`FeePolicySnapshot` frozen per launch** — a policy retune only governs later launches; an open
  launch keeps the terms it sold under. Same for snipe-tax terms.
- **`expectedEconomics`** — the creator may pin a keccak digest over all ten owner-controlled
  economic terms (supply, curve fee, phantom reserve, threshold, pool fee, tick spacing, the four
  policy bps) so an owner re-peg "can never land underneath an in-flight launch."
- **Creator-fee-recipient override is timelocked**: 3-day delay, 3-day execution window,
  cancellable, and the source documents the honest-recipient race in detail.
- **`renounceOwnership()` reverts** on factory, hook, vault, locker — but every owner power is
  capped in constants: hook fee ≤ 10%, total trade fee ≤ 20%, protocol share ≤ 50%, graduation
  rescue only after 7 days in `Swept`.

A platform does not build a timelock against itself out of theory. This is the scar tissue of
being accused — fairly or not — of being able to rug terms mid-launch.

### 2d. Two smaller v2 admissions worth recording

- **Buyback-and-lock, not burn.** 50% of the creator's fee slice (live `buybackBurnBps = 5000`)
  market-buys the token and locks it in `PonsV2BuybackVault` under a **five-year weighted-average
  vest** whose releases split creator/protocol on the launch's frozen shares. The vault's own
  NatSpec admits the sleight: *"the creator funds the entire lock and then receives only their fee
  share of it back"* — enabling buyback moves value from creator to protocol.
- **A trusted operator sits in the sweep path.** Any sweep that must execute an internal swap
  (memecoin-denominated fees, or the buyback leg) requires `feeSweepOperator`. The creator may only
  distribute already-quote-denominated fees. Their answer to sweep MEV is a trusted keeper; ours is
  a permissionless `sweep()` with `SWEEP_BOUNTY_BPS = 50` and a price bound. Theirs cannot be
  griefed by a farmer and cannot run without them; ours is the reverse. This is `12` C-2's trade
  again, in a third costume.

---

## 3. Fee flow, theirs against ours

Live v2 values (cast against curve `0x423f7985…` and hook `0xE5e70264…`):

| | Pons v2 | this repo |
|---|---|---|
| base trade fee | 1% (`feeBps`/`hookFeeBps` = 100), both directions, quote leg | 3% configurable buy, capped `MAX_FEE_BPS` = 1000; derived sell platform share |
| creator surcharge | 0–10% `creatorTaxBps`, creator-chosen at launch, 100% to creator | — |
| combined cap | 20% (`MAX_TOTAL_TRADE_FEE_BPS`) | 10% |
| protocol share of base fee | 30% (`protocolFeeShareBps` = 3000) | platform share via `PLATFORM_VOLUME_BPS` + fee config |
| of the creator's 70% | 50% diverted to buyback-and-lock (5y vest) when enabled | n/a |
| **holders receive** | **nothing** | streamed dividends via `Distributor`, 24h `STREAM_WINDOW` |
| referral system | **none in any contract** | `ReferralVault`, 5 tiers, 3000/2000/1500/1000/500 bps |
| launch fee | 0.0005 ETH | — |
| payout mechanics | pull-based `PonsV2FeeEscrow.claim()` | pull-based claims |
| sweep trigger | creator, or trusted operator when swaps needed | permissionless + bounty |

Two things stand out. First, the escrow: Pons also refuses to push funds during swaps — every
payout is a `credit()` into a claimable ledger. Fourth system in this review pass to converge on
pull-based distribution. Second, the absence: no referral tree, no holder payout. Their growth
engine is the memecoin casino itself; their retention is the PONS token. **Our dividend + referral
stack has no incumbent competitor on this chain** — BaseStonk is the only adjacent player doing
holder payouts, and it launched there from outside.

---

## 4. UX flow, read from source and bundle

Creator-facing launch parameters (`TokenParams` + factory config, source-verified): name, symbol,
logo URI, description, five socials (twitter/telegram/discord/website/farcaster), fee recipient,
`creatorTaxBps` (0–10%), `buybackEnabled`, an optional `expectedEconomics` pin, and a CREATE2
`salt` — namespaced per launcher, explicitly documented as the vanity-address miner, with
`predictLaunchAddresses` for preflight. Launches may attach an initial buy (PONS itself recorded
`initialBuyAmount = 0.1 ETH` in the v1 factory record). Quote asset is native by default; the
owner can approve ERC-20 quote assets, each requiring its own `PairTokenEconomics` (≥6 decimals)
because "a wei-denominated phantom reserve applied to a 6-decimal stablecoin would misprice the
curve by twelve orders of magnitude."

The pools.trade frontend is built on **Uniswap's own interface stack**: Basel Grotesk fonts,
`app.uniswap.org` references, and Uniswap's `data.v1.DataApiService` Connect-RPC protos including
`CreatePendingTokenFactoryToken` (fields: request_id, token_address, chain_id, name, symbol,
image_url, decimals, description, website_url, x_url) and `SubmitTokenFactoryToken` — a
create-pending → submit two-step, with presigned-URL image upload and an image verification call
that can return `BLOCKED`. **No contract addresses appear anywhere in the fetched JS**; all config
is served from their backend. `/api/tokens`, `/api/launches`, `/api/v1/tokens` all 404.

---

## 5. Adopt / reject, per mechanic

| mechanic | verdict | reason |
|---|---|---|
| `expectedEconomics` digest pin | **adopt the idea** | We have owner-configurable fees; the same retune-under-an-in-flight-launch race exists here. A one-`bytes32` pin is cheap and is a trust artifact we can point at. |
| per-launch `FeePolicySnapshot` | **adopt the idea** | Same argument as BaseStonk's versioned hooks (`14` §3d): policy changes must not reach pools that already sold different terms. Ours reach every pool at once. |
| decaying snipe tax that joins the fee split | **already have the shape** | Our opening-fee window is this mechanism. Their 3-second exponential decay vs our 300s cap is a tuning difference; the shared 9,900 ceiling is now triple-confirmed. Their choice to *route snipe proceeds into the normal split* rather than a separate bucket is worth copying if we ever split opening-fee accounting. |
| price-bound partial fills (`spent * minTokensOut > received * tokensOut`) | **study before router work** | Elegant reinterpretation of slippage under clamping. Not currently needed — we have no curve — but `ZapRouter` follow-ups should read it. |
| bonding curve + graduation | **reject** | Deliberate divergence. The curve exists to solve seed capital; we solve it with single-sided liquidity and a live pool from block one (as does BaseStonk). The price of graduation is visible in their own code: a four-phase state machine, a `GraduationGuard`, a `Rescued` terminal state, a 7-day rescue delay, force-swept overrides, and an auto-graduation that must swallow its own failure inside `buy()`. |
| buyback-and-lock with 5-year vest | **reject** | It is value routing from creator to protocol dressed as tokenomics — their own comments say so. Not a dividend mechanism, and it drags a trusted operator into the sweep path. |
| trusted `feeSweepOperator` | **reject, but re-read at C-2 time** | If the bounty-sweep economics of `12` C-2 ever force a redesign, a rotatable operator with a creator fallback for swap-free sweeps is the middle ground they chose. Record it as an option, not a plan. |
| transfer-hook wallet/tx caps (their v1) | **reject** | They rejected it themselves within three weeks of launch. `LaunchToken` staying dumb is confirmed a third time. |
| creator-recipient timelock (3d + 3d window) | **adopt if we ever add an owner override** | The expiring execution window is the detail most implementations miss. |
| CREATE2 vanity salt for token addresses | **optional, cheap** | Pure UX sugar, zero protocol risk, creators demonstrably like it. |

---

## 6. Method, and its limits

**Source-verified** (Blockscout `/api/v2/smart-contracts/`, files on disk, read line by line where
cited): `PonsLauncherToken` v1 + its `ILaunchpad.sol`; the full v2 suite — `PonsV2LaunchFactory`,
`PonsV2BondingCurve`, `PonsV2MemeHook`, `PonsV2BuybackVault`, `PonsV2LaunchLocker`,
`PonsV2LauncherToken`, `PonsV2FeeEscrow` (verified directly), graduation/curve math libraries,
`ILaunchpadV2.sol`. The 72k-char factory was read targeted (structs, errors, function inventory,
launch/graduation paths), not exhaustively.

**Bytecode/cast-inferred only**: the v1 `PonsLaunchFactory` and v1 locker are **unverified**; their
roles come from probing guessed selectors against live state and from the v1 token's imported
interfaces. Claims about v1's LP-fee-collection internals are interface-plus-wiring inference, not
read source.

**Live values via cast**: every bps figure, threshold, address wiring, and owner identity quoted
above was read from chain state on the day of writing; all are owner-mutable within their caps and
can drift.

**Docs/bundle-claimed**: liquidity/volume from DexScreener; frontend flow from the shipped JS
bundle. Both unverifiable on-chain.

**Dead ends, so the next pass doesn't repeat them**: the legacy `?module=contract` Blockscout API
worked once then rate-limited into `"Something went wrong"` for the rest of the session — the
`/api/v2/` routes were the reliable path, contrary to the going-in notes; PowerShell 5.1's
`ConvertFrom-Json` chokes on Blockscout v2 responses (case-duplicate keys — parse with Node);
pools.trade exposes no public JSON API and its bundle leaks no addresses; the EIP-1167 assumption
was wrong (full CREATE2 deployments); the verified contract named `PonsToken`
(`0xBc9DFE28…`, 0.8.25) is a red herring — `name()` returns "LAPTOP", an unrelated squatter, as is
`PonsReinvestRouter` (`0x855283Dc…`), a third-party "SGAGE" LP tool that merely matched the name
search.
