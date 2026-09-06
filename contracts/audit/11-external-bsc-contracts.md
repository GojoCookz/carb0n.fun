# 11 — External contracts offered as "battle tested"

Six Solidity files received via Telegram, described as battle-tested work from a BSC developer and
proposed as components we could adopt: `DividendDistributor.sol`, `MultiRewardToken.sol`,
`Protect.sol`, `Retirement.sol`, `Pipi.sol`, `Helper_BNB.sol`.

**Verdict: do not adopt.** Two of the six were read line by line; the other four are the same V2
transfer-tax lineage and share its shape. The reasoning below is recorded so this does not get
re-litigated the next time a dividend tracker arrives over Telegram.

This is not a rejection of the author. The instant-credit bug in these files has been copy-pasted
across hundreds of live BSC and Polygon tokens for years, which is exactly why it deserves a
written answer rather than a shrug.

---

## 0. "Battle tested" is a claim about deployment, not about safety

Wide deployment is how this bug family SPREAD. It is not evidence against the bug. Our own
`07-dividend-tracker-lineage.md` exists because this code is everywhere; being everywhere is the
observation that started the audit, not the thing that closes it.

---

## 1. It targets a different chain than advertised

Described as BSC. Every hardcoded address is **Polygon**. Verified on-chain against
`polygon-bor-rpc.publicnode.com`:

| Address in `DividendDistributor` constructor | Comment says | `name()` actually returns |
|---|---|---|
| `0xc2132D05D31c914a87C6611C10748AEb04B58e8F` | `// USDT` | `USDT0` |
| `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` | `// USDC` | USD Coin (PoS) |
| `0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6` | `// WBTC` | (PoS) Wrapped BTC |
| `0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619` | `// WETH` | Wrapped Ether |
| `0x7f6a281AB0a6B1C64fC7B8d413b3F551cfE436BC` | `// SPX500` | **"S&P 500"** — see §2 |

On Ethereum these addresses resolve to different tokens or to nothing. The code has never run on
the chain we deploy to.

---

## 2. The hardcoded reward is a lookalike, not the coin it names

`rewards_2` is fixed in the constructor and pays **one third of every holder's dividend**. It is not
configurable per launch. The comment labels it SPX500.

SPX6900 is a legitimate memecoin and is in our pair roster on purpose. The hardcoded token is
**not SPX6900**:

| | SPX6900 — in our roster | Hardcoded in `DividendDistributor` |
|---|---|---|
| chain | Ethereum | Polygon |
| address | `0xE0f63A424a4439cBE457D80E4f4b51aD25b2c56C` | `0x7f6a281AB0a6B1C64fC7B8d413b3F551cfE436BC` |
| `name()` | `SPX6900` | `S&P 500` |
| decimals | 8 | 9 |
| totalSupply | 1,000,000,000 | 2,981,058 |
| `owner()` | `0x0` — **renounced** | `0x5a58505a96D1dbf8dF91cB21B54419FC36e93fdE` — **live** |

Different name, different decimals, 0.3% of the supply, and an owner key that can still act. A
token nobody verified, wearing a famous ticker, paid to every holder with no opt-out.

The lesson generalises past this one address: **a comment naming a token is not a verification of
that token.** Resolve `name()`, `decimals()`, `totalSupply()` and `owner()` on the target chain
before any address is hardcoded as a reward.

---

## 3. Reentrancy — and an unguarded setter that makes it reachable

Two findings that are individually bad and together are a drain.

**3a. `setPersonalReward` (line 92) has no access control and no validation.**

```solidity
function setPersonalReward(address reward) external {
    rewards_3[msg.sender] = reward;      // any caller, any address, no checks
}
```

**3b. `distributeDividend` (line 258) writes its guards after the external call.**

```solidity
totalDistributed += amount;
swapUSDTForRewards(address(rewardToken), shareholder, amount);  // tokens leave, to the user
shareholderClaims[shareholder]    = block.timestamp;            // <- guard, set AFTER
shares[shareholder].totalRealised += amount;
shares[shareholder].totalExcluded = getCumulativeDividends(...); // <- accounting, set AFTER
```

`totalExcluded` is the value `getUnpaidEarnings` subtracts. `shareholderClaims` is the value
`shouldDistribute` gates on, and `claimDividend` requires `shouldDistribute`. **Both are written
after the tokens go out.**

The chain:

```
attacker calls setPersonalReward(attackerToken)        <- 3a, no guard stops this
attacker calls claimDividend()
  -> shouldDistribute passes
  -> swapUSDTForRewards: third swap path[2] = attackerToken, recipient = attacker
     -> router calls transfer on attackerToken
        -> attackerToken re-enters claimDividend()
           -> shareholderClaims still stale -> shouldDistribute passes
           -> totalExcluded still stale     -> getUnpaidEarnings returns FULL amount again
           -> paid again ... loop until the distributor's balance is gone
```

3a is the gadget that makes 3b reachable, because the attacker supplies the callback token
themselves. Neither finding needs a hostile reward token to pre-exist.

---

## 4. Instant credit — the CRITICAL we already fixed

`deposit()` raises `dividendsPerShare` immediately, and `getUnpaidEarnings` reads the holder's
balance at call time. Buy, trigger the deposit, claim, sell — atomically, in one transaction, with
no holding period.

This is **E-03**, the critical finding our streaming migration was written to kill. It is present
here in full. Adopting this code would reintroduce the single worst bug we have fixed.

---

## 5. Everything else found in the two files read closely

| # | Where | Finding |
|---|---|---|
| 5a | `DividendDistributor.deposit` | `dividendsPerShare += factor * amount / totalShares` with no zero guard. Reverts when there are no holders; `MultiRewardToken` wraps the call in `try/catch {}` so fees silently accumulate with no event. |
| 5b | `swapUSDTForRewards`, ×3 | Every swap passes `amountOutMin = 0`. Three sandwichable swaps on every single claim. |
| 5c | `swapTokensForEth` | `amountOutMin = 0` again, on the token side. |
| 5d | `setRewardToken` | Owner can change the denomination while dividends are already owed and accounted in the old one. |
| 5e | `claimETH` (both files) | Owner drains ETH from the contract at will. |
| 5f | `getCurrentRewardAddress` | `block.timestamp / 1 days % 5` — fully deterministic, so a holder can time claims to select the reward they want. |
| 5g | `MultiRewardToken._update` | Two `setShare` calls plus `process(distributorGas)` with up to **1,000,000 gas on every transfer**. |
| 5h | `MultiRewardToken` | `setTradingEnabled(false)` plus `setRouter`, `claimTokens`, `claimETH`, `setMaxWalletAmount` is a rug-capable admin surface. |
| 5i | both | `try { ... } catch {}` around nearly every external call. A holder can silently stop accruing (`SetDividendShareFailed`) with no revert anyone will notice. |

---

## 6. It is architecturally moot anyway

These are Uniswap **V2**, push-based, driven from an ERC-20 `_update` transfer hook.

We are on Uniswap **V4**: PoolManager is a singleton, swaps do not pass through the token's
transfer path, and `swapExactTokensForTokensSupportingFeeOnTransferTokens` does not exist. There is
no `_update` seam to attach a transfer-tax dividend tracker to. This is not a porting job — it is a
different architecture solving the same problem with weaker guarantees.

`FeeHook` already sits at the correct layer, is pull-based, streams rather than instant-credits, and
carries 1506 passing tests and ten audit surfaces.

---

## 7. The one idea worth taking

**Per-holder reward election.** `rewards_3[msg.sender]` lets each holder choose the asset they are
paid in. We support a creator-chosen reward asset; letting each HOLDER choose their own is a real
product idea we do not have.

The implementation here is the attack gadget in §3a. The concept is still sound. Built safely it
would need:

- election validated against the `pairs.ts` roster, so it inherits the no-securities policy and
  cannot point at an arbitrary attacker-controlled contract;
- settlement through the existing pull-based claim path, with state written **before** any transfer;
- a bounded, non-zero slippage limit on the conversion leg — noting that
  `09-remediation.md` records that bounding the sell-conversion leg made the bounty farmable by
  fragmentation, so this needs the E-05 price-limit treatment, not a `minOut` revert;
- a default when unset, and no forced third-party token.

---

---

# Part 2 — the other four files

`Protect.sol`, `Pipi.sol`, `Retirement.sol`, `Helper_BNB.sol`. Authored by **MrGreenCrypto,
CodeCraftrs.com**. These three tokens genuinely are BSC — PancakeSwap V2 router
`0x10ED43C7...`, WBNB `0xbb4CdB9C...` — so the earlier chain mismatch applies only to the Polygon
pair in Part 1. Different codebase, different problems.

**Verdict: same. Do not adopt.** For a reason that has nothing to do with code quality.

---

## 8. Every sell pays two wallets belonging to the original author

All three tokens route their tax through a helper contract at a **hardcoded `constant` address**:

```solidity
IHelper private constant helper = IHelper(0x37AA8EC8382CCC16cD53d2500eBbe5C64Ee25268);
```

`swapForRewards()` sells the accumulated tax tokens and sends the BNB **to the helper, not to
itself** (`Protect.sol:324`), then calls back for it:

```solidity
ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(..., address(helper), block.timestamp);
require(helper.giveMeMyMoneyBack(rewards + outreach + ecosystem + estate), "Something went wrong");
```

`Helper_BNB.sol` is the source for that address, and **it is genuinely the deployed code** —
verified, not assumed:

- storage slot 0 = `0xa278f745...af5ba` — matches `whizard2` in the source exactly
- storage slot 1 = `0x1c8a674d...9ea80` — matches `whizard` exactly
- selector `0x4f6f4524` = `giveMeMyMoneyBack(uint256)`, present in the runtime bytecode
- metadata reports solc `0.8.19`, matching the pragma
- 397 bytes, one external function

What it does:

```solidity
uint256 share = address(this).balance / tax;
payable(whizard2).transfer(share);      // hardcoded, no setter
payable(whizard).transfer(share);       // hardcoded, no setter
payable(msg.sender).transfer(address(this).balance);
```

At `Protect.sol` defaults — `tax = 8`, `rewards = 4`, `liq = 2`, `outreach = 1`, `ecosystem = 1`,
`estate = 1` — the divisor is `4 + 1 + 1 + 1 = 7`, so each wallet takes `balance / 7` and the pair
of them take **2/7, about 28.6% of every BNB the token ever swaps.** That is 2 of the 8 tax points,
i.e. **a quarter of all tax revenue, permanently, to the contract author.**

To be fair to the design: at defaults this is internally consistent. `ecosystem` and `estate` are
plainly meant to be the author's fee, and 2 points of an 8 point tax is what the numbers say. It is
a business arrangement, not a hidden backdoor.

The problem is that it is invisible at the point of reading. Nothing in the token contract says
where `ecosystem` and `estate` go. You find it only by resolving a `constant` address on BSC and
reading a second contract. Anyone deploying this believing they control their own tax schedule is
wrong.

---

## 9. The two halves disagree, and turning the fee DOWN turns it UP

This is the actual bug, and it is not subtle once the two contracts are read together.

The helper hardcodes **two transfers of exactly one share**. The token lets the CEO change
`ecosystem` and `estate` freely via `setTaxes`. The helper has no setter, no owner, and receives
only the divisor — it can never learn that the split changed.

| CEO sets | divisor sent to helper | what the two wallets actually take |
|---|---|---|
| defaults (`ecosystem 1`, `estate 1`) | `4+1+1+1 = 7` | 2/7 = **28.6%** |
| **`ecosystem 0`, `estate 0`** — trying to remove the author's cut | `4+1+0+0 = 5` | 2/5 = **40%** |
| `ecosystem 5`, `estate 5` — trying to raise it | `4+1+5+5 = 15` | 2/15 = **13.3%** |

**Setting the author's fee to zero raises it from 28.6% to 40%.** The one action an owner would
take to remove the cut is the action that maximises it. There is no value of `ecosystem` and
`estate` that turns it off, because the helper never reads them.

The reverse case is just as broken: raising them to 5 and 5 makes the token believe it allocated
10/15 to the author while the helper hands back 13/15, and the surplus is then distributed through
`rewardsPerShare` as if it were reward tax. The two contracts' books never reconcile.

---

## 10. The helper is an unfixable single point of failure

`helper` is `constant`. There is no setter in any of the three tokens. The call is wrapped in
`require(...)`, and it sits in the sell path.

If the helper ever reverts — a `transfer()` failing on its 2300 gas stipend, a beneficiary address
changing behaviour, a zero divisor — **every sell reverts, permanently, for every token built on
this code, and no owner action can repair it.** The only recovery is redeploying the token and
migrating holders.

For a contract family whose selling point is safety, an unpatchable third-party dependency in the
sell path is the wrong shape.

---

## 11. Retirement.sol depends on a second helper whose source we were not given

The drop contains one helper source. The code references **two different helper contracts**.

`Retirement.sol:69` points at `0xc8a0Eb0cda131E9B227bc1AfF3eFd3be8F045e96`, and it is not the same
contract:

| | `0x37AA8EC8…` (source provided) | `0xc8a0Eb0c…` (**no source provided**) |
|---|---|---|
| size | 397 bytes | **1091 bytes** |
| `giveMeMyMoneyBack(uint256)` | present | absent |
| `giveMeMyMoneyBack(address)` | absent | **present** |
| `setShare(uint256)` | absent | **present** |
| beneficiary slot 0 | `0xa278f745…` | **`0xc604f37b…`** |
| beneficiary slot 1 | `0x1c8a674d…` | **`0xda128b1b…`** |

Different beneficiaries, nearly three times the code, and a **mutable `setShare(uint256)`** that
`Retirement.sol` calls at lines 165 and 188. So the divisor governing the payout split is live
state on an unsourced contract sitting in the sell path as an unchangeable `constant`.

We cannot tell whether `setShare` on that helper is access-controlled, because we were not given
the source. If it is not, anyone can set the divisor to 1 and direct the entire swap balance to
those two wallets.

Slots 2 and 3 currently read zero. If slot 2 is the divisor, the helper is in a
division-by-zero state right now and `Retirement` sells would revert until `setShare` is called.

**Six files were offered as a complete set. They are not self-contained.** One of the three tokens
cannot be reviewed at all without code that was not included.

---

## 12. A dead comparison in all three tokens makes the shareholder list grow forever

Identical in `Protect.sol:340-342`, `Pipi.sol:371-373`, `Retirement.sol:300-302`:

```solidity
if(shares[shareholder].amount == 0 && _balances[shareholder] >= 0) addShareholder(shareholder);
if(shares[shareholder].amount > 0  && _balances[shareholder] < 0){ ... removeShareholder ... }
```

`_balances` is `uint256`. **`>= 0` is always true and `< 0` is always false.**

Consequences:

- the first condition degrades to `if (shares.amount == 0)`, so any address with no shares is
  pushed onto `shareholders` **every time `setShare` touches it** — duplicates accumulate without
  limit, and every wallet that sold to zero keeps being re-added;
- `shareholderIndexes[shareholder]` is overwritten on each duplicate push, corrupting the index
  even if removal worked;
- the second branch is unreachable, so **`removeShareholder` is dead code and the array never
  shrinks.**

The reward distribution loop walks that array. Its gas cost rises monotonically and never
recovers. This is the same unbounded-iteration failure mode described in
`07-dividend-tracker-lineage.md`, reached by a different route.

---

## 13. "Renounced" does not mean renounced

`renounced` is a `bool` the CEO sets, and most privileged functions either ignore it or merely
constrain it. After renouncing, the CEO can still call `rescueBnb` to withdraw BNB,
`setNameAndSymbol` to **rename the token and change its ticker**, `changeOutreachWallet`,
`changeMainRewards`, and `excludeFromRewards`.

`setTaxes` remains callable, limited to lowering the total — which, per §9, is the operation that
increases the author's actual cut.

A token advertised as renounced that can still be renamed is a rug primitive, not a safety feature.

---

## 14. What Part 2 changes about the conclusion

Nothing in these four files is adoptable, and the reason is structural rather than stylistic:
**they are not standalone contracts.** They are clients of infrastructure the author controls, at
addresses that cannot be changed, taking a fee that cannot be switched off, one of which has no
published source.

That is a reasonable commercial model for the author. It is not something to build a launchpad on,
and it is the opposite of what our deployment needs to be — every address we depend on is either
ours, immutable, or in `pairs.ts` where the policy check can see it.

The §7 idea still stands and is still the only thing worth carrying across.

---

## Provenance

Files at `~/Downloads/Telegram Desktop/`, dated 2025-09-05, pragmas `0.8.19` and `0.8.25`.
Part 1 covers `DividendDistributor.sol` and `MultiRewardToken.sol` (Polygon). Part 2 covers
`Protect.sol`, `Pipi.sol`, `Retirement.sol` and `Helper_BNB.sol` (BSC, CodeCraftrs).

On-chain reads against `ethereum-rpc.publicnode.com`, `polygon-bor-rpc.publicnode.com` and
`bsc-rpc.publicnode.com` at BSC block 120221746. Helper bytecode, storage slots and function
selectors were read from the live chain rather than inferred from the supplied source.

Nothing from these files has been merged.
