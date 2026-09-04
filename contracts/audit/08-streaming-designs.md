# 08 — Streaming and time-weighted distribution designs

Read-only research. Nothing in `src/` or `test/` was touched.

**Question:** what is the proven way to hand a pot of rewards to holders such that an attacker
who holds for zero or near-zero time captures nothing meaningful?

**Answer up front:** every design below solves it the same way — *the pot does not exist as a
claimable quantity at any single instant.* They differ only in how they spread it. Two spread it
over TIME against a live balance (Synthetix, MasterChef), one snapshots balances at week
boundaries (Curve), one hides the profit inside share price and lets it surface per second
(Yearn). Only the first shape survives contact with a freely-traded memecoin whose entitlement
changes on every ERC-20 transfer.

Prior work this builds on: `06-recommended-fixes.md` FIX 1 proposed streaming without naming a
reference implementation. `07-dividend-tracker-lineage.md` established the BSC dividend-tracker
family has nothing to offer here. This document gets the actual source for the four DeFi-grade
designs and picks one.

---

## 0. What we are retrofitting onto

`src/Distributor.sol`, current shape:

```solidity
uint256 internal constant MAGNITUDE = 2 ** 128;
uint256 internal _magnifiedPayoutPerShare;
mapping(address => int256)  internal _corrections;
mapping(address => uint256) internal _withdrawn;
mapping(address => uint256) public  shareOf;
uint256 public totalShares;
uint256 public pendingPayouts;
```

```solidity
// Distributor.sol:189
function distribute(uint256 amount) external onlyController {
    uint256 total = amount + pendingPayouts;
    if (total == 0) return;
    uint256 shares = totalShares;
    if (shares == 0 || shares < minSharesForDistribution) { pendingPayouts = total; return; }
    pendingPayouts = 0;
    _magnifiedPayoutPerShare += (total * MAGNITUDE) / shares;   // <-- ONE INSTANT
    totalDistributed += total;
}
```

```solidity
// Distributor.sol:222
function _setShares(address account, uint256 newShares) internal {
    uint256 old = shareOf[account];
    if (newShares == old) return;
    if (newShares > old) {
        uint256 d = newShares - old;
        totalShares += d;
        _corrections[account] -= int256(_magnifiedPayoutPerShare * d);
    } else { ... }
    ...
}
```

`LaunchToken._update` calls `distributor.setBalance` **twice on every transfer**
(`LaunchToken.sol:181-182`), so `_setShares` is the hottest path in the system and every wei of
gas added there is paid by every trade forever.

The CRITICAL from `05-economics.md` / `test/audit/EconAudit.t.sol::test_E03_buySweepSellCapturesTheHoldersPot`
is that `sweep()` is permissionless and `distribute` credits `_magnifiedPayoutPerShare` in the
same instant, so `buy -> sweep -> sell -> withdraw` in one transaction returns +12% on capital
(+4.87 pair on 40 in, per `06-recommended-fixes.md`) with zero blocks held, and honest holders
lose 83% of the pot. `SWEEP_BOUNTY_BPS = 50` (`FeeHook.sol:154`) means we pay the attacker 0.5%
of the pot to pull the trigger.

---

## 1. Synthetix `StakingRewards.sol`

Source: `Synthetixio/synthetix`, `contracts/StakingRewards.sol` (develop/master, unchanged since
SIP-77). Modern re-issue with the same math, unsigned and immutable:
`sky-ecosystem/endgame-toolkit`, `src/synthetix/StakingRewards.sol`.

### Mechanism

There is no "distribution event" that credits anybody. `notifyRewardAmount(reward)` converts a
lump into a **rate per second** and a **deadline**, and the per-share accumulator then advances
purely as a function of elapsed time. Any state-touching call runs `updateReward`, which brings
the global accumulator current *up to `min(now, periodFinish)`* and then checkpoints the caller
against it. A caller who enters and exits inside one block sees `lastTimeRewardApplicable() -
lastUpdateTime == 0` and earns exactly zero — not a sliver, zero.

### State

```solidity
uint256 public periodFinish = 0;
uint256 public rewardRate = 0;
uint256 public rewardsDuration = 7 days;
uint256 public lastUpdateTime;
uint256 public rewardPerTokenStored;
mapping(address => uint256) public userRewardPerTokenPaid;
mapping(address => uint256) public rewards;
```

### The four functions that matter

```solidity
function lastTimeRewardApplicable() public view returns (uint256) {
    return block.timestamp < periodFinish ? block.timestamp : periodFinish;
}

function rewardPerToken() public view returns (uint256) {
    if (_totalSupply == 0) { return rewardPerTokenStored; }
    return rewardPerTokenStored.add(
        lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
    );
}

function earned(address account) public view returns (uint256) {
    return _balances[account]
        .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
        .div(1e18)
        .add(rewards[account]);
}

modifier updateReward(address account) {
    rewardPerTokenStored = rewardPerToken();
    lastUpdateTime = lastTimeRewardApplicable();
    if (account != address(0)) {
        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }
    _;
}

function notifyRewardAmount(uint256 reward) external onlyRewardsDistribution updateReward(address(0)) {
    if (block.timestamp >= periodFinish) {
        rewardRate = reward.div(rewardsDuration);
    } else {
        uint256 remaining = periodFinish.sub(block.timestamp);
        uint256 leftover  = remaining.mul(rewardRate);
        rewardRate = reward.add(leftover).div(rewardsDuration);
    }
    uint balance = rewardsToken.balanceOf(address(this));
    require(rewardRate <= balance.div(rewardsDuration), "Provided reward too high");
    lastUpdateTime = block.timestamp;
    periodFinish   = block.timestamp.add(rewardsDuration);
    emit RewardAdded(reward);
}
```

### Why instant capture fails

`rewardPerToken()` is `rewardPerTokenStored + elapsed * rewardRate * 1e18 / totalSupply`. In a
single transaction `elapsed == 0` for every call after the first, so the accumulator is frozen
for the duration of the transaction. `notifyRewardAmount` *itself* moves nothing — it sets
`rewardRate` and `periodFinish` and calls `updateReward(address(0))`, which merely flushes the
accrual from before the notify. There is no line anywhere that adds `reward` to
`rewardPerTokenStored`. Buy, notify, sell, claim in one transaction yields zero.

**This is the single structural difference from our contract.** Our accumulator is advanced by
an EVENT; theirs is advanced by the CLOCK. Everything else — the correction/debt term, the
`accumulative - withdrawn` pull, the O(1) hot path — is algebraically identical. `userRewardPerTokenPaid`
is the per-share form of our `_corrections`; `earned()` is our `withdrawableOf()`.

### Residual attacks and known defects

| # | Issue | Real? |
|---|---|---|
| S-1 | **Period-reset griefing / rate dilution.** `periodFinish = now + rewardsDuration` on *every* notify. A caller who notifies dust every block re-spreads `remaining * rewardRate` over a fresh full window each time, so the payout horizon decays geometrically and never finishes. Nothing is stolen; everything is delayed indefinitely. | Yes. Contained upstream only because `notifyRewardAmount` is `onlyRewardsDistribution`. **Our `sweep()` is permissionless AND pays a bounty, so this is wide open for us.** |
| S-2 | **Rewards stranded while `_totalSupply == 0`.** `rewardPerToken()` returns `rewardPerTokenStored` unchanged when supply is zero, but `updateReward` still executes `lastUpdateTime = lastTimeRewardApplicable()`. Those seconds are billed against nobody and the corresponding reward is unreachable forever. | Yes, and documented in the wild. 0xmacro found the sibling case on Sommelier: any delay `Y` between `notifyRewardAmount` and the first `stake()` permanently strands `Y * rewardRate`, because `periodFinish` is `X + duration`, not `X + Y + duration`. Sommelier's fix was to defer `periodFinish` to the first stake (`_startProgram()`). |
| S-3 | **`notifyRewardAmount` overflow (SIP-77, reported by samczsun).** `elapsed.mul(rewardRate).mul(1e18)` overflows once `rewardRate >= 2^256 / (1e18 * elapsed)`, bricking `earned`, `stake`, `withdraw`, `getReward`, `exit` **and `notifyRewardAmount` itself** — unrecoverable. Fixed by `require(rewardRate <= balance / rewardsDuration)`. | Yes, historical, fixed. Note the shape is the same class as our own `minSharesForDistribution` guard: an accumulator divided by a too-small denominator becomes an unbounded multiplicand later. |
| S-4 | **`setRewardsDuration` could be changed mid-period** in the pre-SIP-77 version (`require(periodFinish == 0 \|\| now > periodFinish)`). Fixed to `require(now > periodFinish)`. The Sky re-issue goes further and recomputes `rewardRate` from `leftover` when the duration changes mid-period. | Yes, historical, fixed. |
| S-5 | **`stakingToken == rewardsToken` is fatal.** `notifyRewardAmount`'s solvency check reads `rewardsToken.balanceOf(address(this))`, which includes staked principal, so the rate can be set against other users' deposits and later stakers' principal is drained by earlier ones. The Sky re-issue hard-blocks it: `require(_rewardsToken != _stakingToken)`. | Yes, reproducible; a public Foundry PoC exists. **Not applicable to us** — our payout currency is the pair currency and the share token is the memecoin, never the same asset. |
| S-6 | **Front-running the notify.** Documented on Sherlock (MakerDAO endgame #40): stake large right before `notifyRewardAmount` lands. Judged **not a bug** — the attacker still has to hold through the window to collect, which is what a staker does. | Real behaviour, correctly considered acceptable. This is the residual we are deliberately choosing to accept. |
| S-7 | Truncation: `rewardRate = reward / rewardsDuration` loses up to `duration - 1` wei per notify. | Trivial; avoidable by storing a pre-magnified rate. |

### Retrofit difficulty onto our accumulator

**Low.** It is a driver swap on one variable. `_magnifiedPayoutPerShare` keeps its meaning, its
magnitude, its relationship to `_corrections`, and the entire `withdraw`/`processBatch`/queue
machinery. See §5.

---

## 2. Curve `FeeDistributor.vy`

Source: `curvefi/curve-dao-contracts`, `contracts/FeeDistributor.vy`, Vyper 0.2.7.

### Mechanism

The "record date" model. Time is chopped into fixed 7-day epochs aligned to the UNIX week.
Two independent checkpoint streams fill two arrays keyed by week boundary: `tokens_per_week[week]`
(how much fee revenue belongs to that week) and `ve_supply[week]` (total veCRV *at that exact
week boundary*). A user's claim then walks weeks and, for each, credits
`their_ve_balance_at_that_boundary * tokens_per_week[w] / ve_supply[w]`. Entitlement is
per-epoch and historical; the current balance is irrelevant.

### State

```vyper
WEEK: constant(uint256) = 7 * 86400
TOKEN_CHECKPOINT_DEADLINE: constant(uint256) = 86400

time_cursor: public(uint256)                       # global: next unfilled week for ve_supply
time_cursor_of: public(HashMap[address, uint256])  # per user: next unclaimed week
user_epoch_of: public(HashMap[address, uint256])
last_token_time: public(uint256)
tokens_per_week: public(uint256[1000000000000000])
ve_supply:       public(uint256[1000000000000000])
token_last_balance: public(uint256)
```

### The week-boundary logic

`_checkpoint_token` measures new revenue as a balance delta and **spreads it across the weeks it
actually spanned, pro rata by time**, rather than dumping it all into the current week:

```vyper
token_balance: uint256 = ERC20(self.token).balanceOf(self)
to_distribute: uint256 = token_balance - self.token_last_balance
self.token_last_balance = token_balance

t: uint256 = self.last_token_time
since_last: uint256 = block.timestamp - t
self.last_token_time = block.timestamp
this_week: uint256 = t / WEEK * WEEK

for i in range(20):
    next_week = this_week + WEEK
    if block.timestamp < next_week:
        ...
        self.tokens_per_week[this_week] += to_distribute * (block.timestamp - t) / since_last
        break
    else:
        self.tokens_per_week[this_week] += to_distribute * (next_week - t) / since_last
    t = next_week
    this_week = next_week
```

`_checkpoint_total_supply` fills `ve_supply[t]` for each week boundary by binary-searching the
VotingEscrow global point history and evaluating the decaying line at that exact timestamp:

```vyper
epoch: uint256 = self._find_timestamp_epoch(ve, t)
pt: Point = VotingEscrow(ve).point_history(epoch)
dt: int128 = 0
if t > pt.ts: dt = convert(t - pt.ts, int128)
self.ve_supply[t] = convert(max(pt.bias - pt.slope * dt, 0), uint256)
t += WEEK
```

`_claim` walks at most 50 weeks, reconstructing the user's veCRV at each boundary from their own
point history and dividing by the stored supply:

```vyper
dt: int128 = convert(week_cursor - old_user_point.ts, int128)
balance_of: uint256 = convert(max(old_user_point.bias - dt * old_user_point.slope, 0), uint256)
if balance_of > 0:
    to_distribute += balance_of * self.tokens_per_week[week_cursor] / self.ve_supply[week_cursor]
week_cursor += WEEK
```

### Why instant capture fails

Twice over. First, the entitlement key is a **past** week boundary, so acquiring balance now
cannot change what you were owed then. Second, veCRV is a *lock*: `bias - slope * dt` is a
balance that decays toward zero at unlock, so buying it is impossible and the only way to have
had a balance at a boundary is to have locked before it. Zero-hold capture is not mitigated, it
is not expressible.

### Residual attacks and known defects (all read directly out of the source above)

- **`for i in range(20)` in `_checkpoint_token`.** If more than 20 weeks pass with no checkpoint,
  the loop exits having only walked 20 weeks and the remaining revenue is mis-binned. Bounded in
  practice by `can_checkpoint_token` plus the daily deadline, but it is a hard cliff in the code.
- **`TOKEN_CHECKPOINT_DEADLINE = 86400`.** The permissionless checkpoint fires at most once per
  day, so up to 24h of arriving revenue is binned by an interpolation rather than by when it
  really landed, and the admin can always checkpoint at a moment of their choosing.
- **`for i in range(50)` in `_claim`.** An account with a busy lock history must call `claim`
  repeatedly; the `Claimed` event exposes `claim_epoch < max_epoch` as the "call again" signal.
- **Division by `ve_supply[week_cursor]`.** If `checkpoint_total_supply` has not covered that
  week the entry is `0` and Vyper reverts on the division. `claim` self-heals by calling
  `_checkpoint_total_supply` when `block.timestamp >= self.time_cursor`, but an integrator
  calling `_claim`-equivalent logic out of order does not.
- **`kill_me()` sends the entire token balance to `emergency_return` and permanently blocks
  `claim`.** A live admin key over everyone's undistributed fees. We would never ship this.
- **Nothing in the file is a same-block capture vector.** Correct on the headline question.

### Retrofit difficulty onto our accumulator

**Prohibitive.** The mechanism works only because a veCRV balance is a closed-form linear
function of time (`bias - slope * dt`) that can be evaluated at any past timestamp from three
stored numbers. A raw ERC-20 balance is an arbitrary step function with no closed form, so
"balance at week boundary" can only be answered by **storing every step**. That means every
`setBalance` becomes an append to a per-holder history array: a fresh non-zero SSTORE (~20,000
gas) per entry, ×2 per transfer, plus unbounded per-holder storage growth on a memecoin where
bots transfer thousands of times. Claims become O(weeks × points) loops with binary searches.
And a weekly record date on a token whose median holding period is measured in minutes pays
almost everyone zero.

Reject. Correct security property, wrong cost class by two orders of magnitude.

---

## 3. MasterChef / SushiSwap `accSushiPerShare`

Source: `sushiswap/masterchef`, `contracts/MasterChef.sol`, Solidity 0.6.12.

### Mechanism

**Structurally the same accumulator we already have.** The difference is entirely in the driver:
`accSushiPerShare` is advanced by *blocks elapsed against a constant emission rate*, never by a
deposited lump. There is no function anywhere that hands MasterChef a pot.

```solidity
struct PoolInfo {
    IERC20 lpToken;
    uint256 allocPoint;
    uint256 lastRewardBlock;
    uint256 accSushiPerShare;   // times 1e12
}
struct UserInfo {
    uint256 amount;
    uint256 rewardDebt;         // == our _corrections, unsigned form
}
// pending reward = (user.amount * pool.accSushiPerShare) - user.rewardDebt
```

```solidity
function updatePool(uint256 _pid) public {
    PoolInfo storage pool = poolInfo[_pid];
    if (block.number <= pool.lastRewardBlock) { return; }          // <-- the whole answer
    uint256 lpSupply = pool.lpToken.balanceOf(address(this));
    if (lpSupply == 0) { pool.lastRewardBlock = block.number; return; }
    uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
    uint256 sushiReward = multiplier.mul(sushiPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
    sushi.mint(devaddr, sushiReward.div(10));
    sushi.mint(address(this), sushiReward);
    pool.accSushiPerShare = pool.accSushiPerShare.add(sushiReward.mul(1e12).div(lpSupply));
    pool.lastRewardBlock = block.number;
}

function deposit(uint256 _pid, uint256 _amount) public {
    updatePool(_pid);
    if (user.amount > 0) {
        uint256 pending = user.amount.mul(pool.accSushiPerShare).div(1e12).sub(user.rewardDebt);
        safeSushiTransfer(msg.sender, pending);
    }
    ...
    user.rewardDebt = user.amount.mul(pool.accSushiPerShare).div(1e12);
}
```

### Why instant capture fails

`if (block.number <= pool.lastRewardBlock) return;` — inside one block the accumulator is frozen.
Deposit and withdraw in the same transaction, `pending` is `amount * acc / 1e12 - rewardDebt`
where `rewardDebt` was set from the *same* `acc` one line earlier, so `pending == 0` exactly.

Note the difference from a mitigation: nothing is being defended here. The reward for block N
does not exist until block N is mined and `sushiPerBlock` conjures it. There is no lump sitting
around that a well-timed transaction could point at. **That is the property we want, and it
tells us our accumulator is not the problem — its driver is.**

### Residual attacks and known defects

- **`lpSupply = pool.lpToken.balanceOf(address(this))`.** Reads a *foreign* balance at accrual
  time. Fee-on-transfer, rebasing and deflationary LP tokens desynchronise `user.amount` from
  the real balance and the pool under- or over-pays; donations inflate `lpSupply` and dilute
  everyone. **Our `totalShares` is our own bookkeeping and is strictly safer — keep it.**
- **`// XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.`**
  A literal comment in the shipped source. Two pools sharing an LP token each see the full
  `balanceOf` as their `lpSupply` and the same deposit farms twice. This is the most-forked bug
  in DeFi.
- **`add()` / `set()` with `_withUpdate = false`.** Changing `allocPoint` without
  `massUpdatePools()` retroactively re-prices every block since `lastRewardBlock` at the new
  weight. Real over/under-payment in many forks.
- **`migrate()`.** `lpToken.safeApprove(address(migrator), bal)` gives the owner-set migrator
  full allowance over every pool's principal. This is the "Chef Nomi" power — a live rug switch,
  not a bug.
- **`safeSushiTransfer` silently under-pays.** `if (_amount > sushiBal) sushi.transfer(_to, sushiBal)`.
  A fork whose reward token is not mintable on demand quietly pays less than owed and never
  reverts. We already do the opposite in `withdraw()` by rolling back on a failed send.
- **`massUpdatePools()` is an unbounded loop over all pools.** Self-DoS at scale; the same
  mistake we deliberately avoided with the `processBatch` cursor.

### Retrofit difficulty onto our accumulator

**Not applicable as-is.** MasterChef's rate is a governance constant funded by minting. Ours must
be derived from an irregular pot that already exists in the pair currency. The bridge from
"irregular lump" to "constant rate over a window" is exactly what Synthetix's
`notifyRewardAmount` does. MasterChef is the proof of the principle, not the implementation.

---

## 4. Yearn v3 profit unlocking (and its v2 ancestor)

Sources: `yearn/tokenized-strategy`, `src/TokenizedStrategy.sol` (API 3.1.0); ancestor
`yearn/yearn-vaults`, `contracts/Vault.vy`.

**This is our problem verbatim.** A `harvest`/`report` is our `sweep`. A depositor sandwiching a
harvest is our `buy -> sweep -> sell`. Yearn hit it in v1, and the fix landed in
`yearn-vaults` PR #167 with the stated purpose, in the author's own words:

> "This should stop the sandwich attack as the attacker would need to wait the full 6 hours
> before they can withdraw and get the profit share they are sandwiching."

and

> "User deposits go in at the 'full share price'. If they deposit in the period of profit lockup
> they need to wait until the period is over before they get all their money back. This works
> like a withdrawal fee that only lasts 6 hours."

### v2 mechanism (the scalar)

```vyper
lockedProfit: public(uint256)
lockedProfitDegradation: public(uint256)   # ~46 * 1e18 / 1e6 -> ~6 hours

@internal
def _calculateLockedProfit() -> uint256:
    lockedFundsRatio: uint256 = (block.timestamp - self.lastReport) * self.lockedProfitDegradation
    if lockedFundsRatio < DEGRADATION_COEFFICIENT:
        lockedProfit: uint256 = self.lockedProfit
        return lockedProfit - (lockedFundsRatio * lockedProfit / DEGRADATION_COEFFICIENT)
    else:
        return 0

# in report():
lockedProfitBeforeLoss: uint256 = self._calculateLockedProfit() + gain - totalFees
self.lockedProfit = lockedProfitBeforeLoss - loss if lockedProfitBeforeLoss > loss else 0
```

`_shareValue` uses `totalAssets - _calculateLockedProfit()`, so at the instant of `report()` the
whole gain is locked and price-per-share does not move at all; it rises linearly over the
following six hours.

### v3 mechanism (share-level, the better one)

Instead of a scalar, v3 **mints shares to the strategy itself** equal to the profit at the
pre-report price, then subtracts the still-locked portion from reported supply:

```solidity
uint256 profitUnlockingRate;    // MAX_BPS_EXTENDED-scaled shares per second
uint96  fullProfitUnlockDate;
uint32  profitMaxUnlockTime;    // default 10 days
uint96  lastReport;

function _totalSupply(StrategyData storage S) internal view returns (uint256) {
    return S.totalSupply - _unlockedShares(S);
}

function _unlockedShares(StrategyData storage S) internal view returns (uint256 unlocked) {
    uint96 _fullProfitUnlockDate = S.fullProfitUnlockDate;
    if (_fullProfitUnlockDate > block.timestamp) {
        unchecked {
            unlocked = (S.profitUnlockingRate * (block.timestamp - S.lastReport)) / MAX_BPS_EXTENDED;
        }
    } else if (_fullProfitUnlockDate != 0) {
        unlocked = S.balances[address(this)];
    }
}
```

and in `report()`:

```solidity
sharesToLock = _convertToShares(S, profit, Math.Rounding.Down);
...
sharesToLock -= totalFeeShares;
uint256 sharesToBurn = _unlockedShares(S);
if (sharesToBurn > sharesToLock)      _burn(S, address(this), sharesToBurn - sharesToLock);
else if (sharesToLock > sharesToBurn) _mint(S, address(this), sharesToLock - sharesToBurn);
```

### The idea worth stealing: the weighted-average re-lock

Yearn does **not** reset the clock to a full window on every report the way Synthetix does. It
computes a share-weighted average of the time remaining on already-locked shares and a full
window for the newly locked ones:

```solidity
uint256 totalLockedShares = S.balances[address(this)];
if (totalLockedShares != 0) {
    uint256 previouslyLockedTime;
    uint96 _fullProfitUnlockDate = S.fullProfitUnlockDate;
    if (_fullProfitUnlockDate > block.timestamp) {
        unchecked {
            previouslyLockedTime =
                (_fullProfitUnlockDate - block.timestamp) * (totalLockedShares - sharesToLock);
        }
    }
    uint256 newProfitLockingPeriod =
        (previouslyLockedTime + sharesToLock * _profitMaxUnlockTime) / totalLockedShares;

    S.profitUnlockingRate  = (totalLockedShares * MAX_BPS_EXTENDED) / newProfitLockingPeriod;
    S.fullProfitUnlockDate = uint96(block.timestamp + newProfitLockingPeriod);
} else {
    S.fullProfitUnlockDate = 0;
}
```

A dust report has `sharesToLock ≈ 0`, so `newProfitLockingPeriod ≈ fullProfitUnlockDate - now`
and the finish line barely moves. **This is the direct answer to Synthetix defect S-1**, and it
costs one multiply and one divide in the notify path.

### Why instant capture fails

At the instant of `report()` the newly minted locked shares dilute the profit away exactly, so
PPS is unchanged. `deposit -> report -> redeem` in one transaction sees `block.timestamp -
lastReport == 0`, so `_unlockedShares == 0`, so `_totalSupply` is the full inflated supply and
the depositor redeems at the same price they paid, minus rounding.

### Residual attacks and known defects

- **v2's `lockedProfit` is one scalar shared by all strategies and `report()` REPLACES it.**
  storming0x flagged this on PR #167 in 2020: strategy 1 reports 100 ETH at 1pm, strategy 2
  reports 50 ETH at 2pm, and the second report frees the first strategy's still-locked profit
  early. v3's share-level accounting plus the weighted average exists to fix exactly this.
- **v2 locks profit but not loss.** A reported loss cuts PPS immediately. v3 burns locked shares
  first (`_realizeLoss` / `_lossBurnState`) and only touches realized PPS once the buffer is
  gone.
- **v2's original `totalAssets()` read `token.balanceOf(self)`** — a donation inflated PPS.
  Fixed with internal `totalIdle` tracking from API 0.4.4. Same lesson as MasterChef's `lpSupply`.
- **v3 3.1.0 added `MINIMUM_SUPPLY = 1e3` and a dead-share mint** because profit accruing to a
  dust supply is a first-depositor inflation vector:

  ```solidity
  uint256 supply = _totalSupply(S);
  if (supply < MINIMUM_SUPPLY) { _mint(S, DEAD_ADDRESS, ...); }
  ```

  This is our `minSharesForDistribution` guard, independently rediscovered by Yearn. Good
  corroboration that the guard in `Distributor.sol:196` is not paranoia.
- **`report()` is `onlyKeepers`.** Yearn never made the trigger permissionless. Ours is. Under
  streaming that stops mattering, but it is worth noting nobody in this lineage ships a
  permissionless, bountied harvest.
- **Residual by construction:** a depositor who enters right after a report and holds the full
  unlock window captures the profit. Yearn considers this correct — it is what a depositor is.

### Retrofit difficulty onto our accumulator

**Mechanism: does not port. Scheduling rule: ports exactly and is the best part.**

Yearn's lock works by minting shares of the vault token to the vault. Our share token is a
freely-traded memecoin we do not mint into, our payout asset is a *different* currency (the pair
currency), and there is no price-per-share — holders are paid out, not marked up. There is
nothing for us to lock.

But `newProfitLockingPeriod` is pure arithmetic over `(amount, remaining, window)` and drops
straight into a Synthetix-shaped notify.

---

## 5. Comparison

| | Instant-capture resistance | Time-weighted? | Gas added per launch-token transfer | Retrofit onto `magnifiedPayoutPerShare` | Known exploits / defects |
|---|---|---|---|---|---|
| **Current `Distributor`** | **None.** `distribute` credits in one instant. +12% ROI on `buy→sweep→sell` with 0 blocks held; honest holders lose 83%; we pay a 0.5% bounty for the trigger. | No | 0 (baseline) | n/a | This audit's CRITICAL (E-03) |
| **Synthetix `StakingRewards`** | **Exact zero** same-block. `elapsed == 0` freezes `rewardPerToken()` for the whole transaction. | Yes, per-second, against live balance | **est. ~10–13k on the first transfer of a block, ~300 on subsequent ones in the same block** (see §6; NOT measured) | **Low.** Same algebra, different driver. `_corrections`, `withdraw()`, `processBatch`, the queue and the overflow guard are all untouched. | S-1 period-reset griefing (permissionless notify only); S-2 rewards stranded at zero supply (0xmacro / Sommelier); S-3 SIP-77 overflow, fixed; S-4 `setRewardsDuration`, fixed; S-5 `stakingToken == rewardsToken` drain (N/A to us) |
| **Curve `FeeDistributor`** | **Not expressible.** Entitlement keys off a past week boundary and a non-transferable decaying lock. | Yes, weekly record date + veCRV bias/slope | **est. +40k or worse** — a per-holder balance-history append per `setBalance`, ×2 per transfer, unbounded storage growth | **Prohibitive.** Needs a closed-form balance-at-time, which an ERC-20 balance does not have. Claims become O(weeks) loops. Weekly epochs pay a memecoin's holders nothing. | 20-week `_checkpoint_token` cliff; 50-week `_claim` cap; 24h `TOKEN_CHECKPOINT_DEADLINE`; revert on unfilled `ve_supply[week]`; `kill_me()` admin drain |
| **MasterChef `accSushiPerShare`** | **Exact zero.** `if (block.number <= lastRewardBlock) return;`. The reward for a block does not exist until the block is mined. | Yes, per-block, against live balance | Comparable to Synthetix (same accumulator shape) | **N/A as-is.** Rate is a minted governance constant; we have an irregular pre-existing pot. Proves the principle, not the implementation. | `lpSupply = balanceOf()` breaks on FoT/rebasing/donations; duplicate-LP double-count (in-source `XXX` warning); `_withUpdate=false` retroactive re-pricing; `migrate()` rug switch; `safeSushiTransfer` silent under-pay; unbounded `massUpdatePools` |
| **Yearn v3 profit unlocking** | **Exact zero.** `block.timestamp - lastReport == 0` ⇒ `_unlockedShares == 0` ⇒ PPS unchanged. | Yes, per-second, via locked shares | n/a (no per-transfer hook; the token IS the vault share) | **Mechanism no, scheduling rule yes.** Nothing to lock: different payout currency, no PPS, we do not mint. But `newProfitLockingPeriod` drops straight in. | v2 scalar `lockedProfit` freed early by a second report (flagged on PR #167); v2 locks profit but not loss; v2 donation-inflatable `totalAssets`; v3 needed `MINIMUM_SUPPLY` dead-share mint against dust-supply inflation |

---

## 6. RECOMMENDATION

**Adopt Synthetix's streaming accumulator as the skeleton, with Yearn v3's weighted-average
re-lock as the top-up rule, and fix Synthetix's zero-supply stranding bug on the way in.**

Nothing bespoke is required. The retrofit is small because our accumulator is already the
Synthetix accumulator — we are only changing what advances it.

Why this and not the others, in one line each:

- **Curve** is the only one that also defeats *slow* farming, but it needs a per-holder balance
  history and weekly record dates, which is the wrong cost class for a token whose `setBalance`
  runs twice on every transfer and whose holders trade in minutes.
- **MasterChef** is the same accumulator with the right driver, but its driver is a minted
  constant; it tells us what to build, not how to fund it.
- **Yearn** is our problem verbatim and its scheduling rule is the best in the set, but its
  locking mechanism needs a price-per-share we do not have.
- **Synthetix** is the only one that takes an *irregular arriving lump* and turns it into a rate,
  which is exactly the shape `sweep()` produces.

### The retrofit, concretely

#### New state — 2 slots

```solidity
/// Pair-wei per second, pre-magnified by MAGNITUDE. Pot-wide, not per-share:
/// dividing by `totalShares` happens at accrual time, exactly as `distribute` does today.
uint256 internal _rateMagnifiedPerSecond;

/// Packed into one slot. `pendingPayouts` can be demoted to uint128 and join them,
/// which makes this a net-zero slot addition.
uint64 internal _lastAccrual;
uint64 internal _streamFinish;

/// Immutable, set per launch. Floor it (>= 1 hour) so a creator cannot set 0 and reopen the hole,
/// and cap it (<= 30 days) to keep the weighted-average arithmetic bounded.
uint256 public immutable streamWindow;      // recommend 6 hours

/// Dust floor. Below this a distribution is CARRIED, not notified. This is the anti-grief lock.
uint256 public immutable minStreamNotify;
```

#### New internal `_accrue()`

```solidity
function _accrue() internal {
    uint256 last = _lastAccrual;
    uint256 fin  = _streamFinish;
    uint256 upTo = block.timestamp < fin ? block.timestamp : fin;
    if (upTo <= last) return;                        // same block, or stream already finished

    uint256 shares = totalShares;
    if (shares < minSharesForDistribution) return;   // PAUSE the clock — see note below
    _magnifiedPayoutPerShare += ((upTo - last) * _rateMagnifiedPerSecond) / shares;
    _lastAccrual = uint64(upTo);
}
```

**The `return` without advancing `_lastAccrual` is a deliberate divergence from Synthetix.**
Synthetix's `updateReward` sets `lastUpdateTime = lastTimeRewardApplicable()` even when
`_totalSupply == 0`, which permanently strands the reward for those seconds (defect S-2, and the
0xmacro/Sommelier finding). Ours pauses instead: time does not pass for the stream while there
is nobody to pay. This matters more for us than for Synthetix, because our own constructor docs
already record that `totalShares` is genuinely zero during the dev buy in `Launcher.launch`.

#### `distribute()` — the only real change

```solidity
function distribute(uint256 amount) external onlyController {
    _accrue();                                       // flush the old rate BEFORE changing it

    uint256 total = amount + pendingPayouts;
    if (total == 0) return;

    // Carry on a small holder base (unchanged, overflow guard) OR on a dust amount (new, anti-grief).
    if (totalShares < minSharesForDistribution || total < minStreamNotify) {
        pendingPayouts = total;
        return;
    }
    pendingPayouts = 0;

    uint256 nowTs     = block.timestamp;
    uint256 remaining = _streamFinish > nowTs ? _streamFinish - nowTs : 0;
    uint256 leftover  = remaining * _rateMagnifiedPerSecond;   // magnified pair-wei still owed
    uint256 addition  = total * MAGNITUDE;

    // Yearn's weighted average, NOT Synthetix's `periodFinish = now + duration`.
    uint256 window = (leftover * remaining + addition * streamWindow) / (leftover + addition);
    if (window == 0) window = streamWindow;

    _rateMagnifiedPerSecond = (leftover + addition) / window;
    _streamFinish = uint64(nowTs + window);
    _lastAccrual  = uint64(nowTs);

    totalDistributed += total;                       // now means "committed to the stream"
    emit PayoutsAdded(total, _rateMagnifiedPerSecond);
}
```

Storing the rate **pre-magnified** rather than as raw pair-wei per second removes Synthetix's
truncation (defect S-7) at no cost, because `MAGNITUDE = 2**128` gives ~38 decimal digits of
headroom. Overflow headroom, worked: a 1e27-wei pot gives `addition ≈ 3.4e65`;
`addition * streamWindow` at 6h is `≈ 7.3e69`, against a `uint256` ceiling of `1.15e77`.

#### `_setShares()` — one line, and it is a correctness requirement

```solidity
function _setShares(address account, uint256 newShares) internal {
    uint256 old = shareOf[account];
    if (newShares == old) return;
    _accrue();                                       // <-- MUST precede the totalShares/_corrections writes
    ...unchanged...
}
```

This is not an optimisation. `_corrections[account] ∓= _magnifiedPayoutPerShare * d` books the
correction against the accumulator's *current* value. Accruing after the correction would book
against a stale accumulator and let the account over-claim the interval it did not hold. Putting
it in `_setShares` rather than `setBalance` means `setExcluded` gets it too, since both route
through here.

**The lazy accrual is exact, not approximate.** `totalShares` can only change through
`_setShares`, which now accrues first, so `totalShares` is provably constant across every
un-accrued interval. There is no averaging error and no need for a keeper — the stream cranks
itself on any transfer, any distribute, any withdraw.

#### `withdrawableOf()` / `accumulativeOf()` — must simulate, like `rewardPerToken()`

```solidity
function _currentPerShare() internal view returns (uint256 mps) {
    mps = _magnifiedPayoutPerShare;
    uint256 last = _lastAccrual;
    uint256 fin  = _streamFinish;
    uint256 upTo = block.timestamp < fin ? block.timestamp : fin;
    uint256 shares = totalShares;
    if (upTo > last && shares >= minSharesForDistribution) {
        mps += ((upTo - last) * _rateMagnifiedPerSecond) / shares;
    }
}

function accumulativeOf(address account) public view returns (uint256) {
    int256 acc = int256(_currentPerShare() * shareOf[account]) + _corrections[account];
    if (acc <= 0) return 0;
    return uint256(acc) / MAGNITUDE;
}
```

`withdrawableOf` is unchanged and picks this up for free. Add `_accrue()` at the top of
`withdraw()` and `processBatch()` so the stored value is current when `_withdrawn` moves.
Everything else in the payout path — the queue, the cursor, the skip-on-failure semantics, the
converter, the rollback in `withdraw()` — is untouched.

#### Cost per transfer

Estimated from EIP-2929/3529 costs, **not measured**:

| | Cost |
|---|---|
| First `setBalance` in a block: cold SLOAD packed slot + cold SLOAD rate | ~4,200 |
| ...plus SSTORE `_magnifiedPayoutPerShare` (warm, non-zero → non-zero) | ~2,900 |
| ...plus SSTORE packed `_lastAccrual`/`_streamFinish` | ~2,900 |
| Second `setBalance` in the same `_update` (`upTo <= last`, early return) | ~200 |
| **Total added per transfer, worst case** | **~10,200** |
| **Total added per transfer, same block as a prior transfer** | **~400** |

Against a v4 swap routed through `FeeHook` (already 250k+) that is under 4%. Against a plain
wallet-to-wallet transfer it is nearer 10%. **This must be confirmed with `forge test --gas-report`
against the existing `LaunchToken.t.sol` transfer cases before it ships — treat the table as an
estimate to be falsified, not a result.**

#### Choosing `streamWindow`

Six hours. That is Yearn v2's `lockedProfitDegradation` default, chosen against observed MEV
arbitrage windows, and it is the only number in this set that was tuned for exactly this attack
rather than for an emissions schedule (Synthetix 7 days, Curve 7 days, Yearn v3 10 days are all
sized for slow capital, not for a memecoin). Six hours makes same-block capture exactly zero
while keeping the stream visible to a holder who checks twice a day.

### What this fixes, precisely

- `buy -> sweep -> sell -> withdraw` in one transaction now captures **exactly zero**, not "a
  sliver". `upTo == _lastAccrual` inside a single block, so `_accrue()` returns before touching
  the accumulator, and `distribute` no longer credits it at all.
- **The 0.5% sweep bounty becomes safe again.** It was only a subsidy because front-running the
  sweep was profitable. Once triggering a sweep credits nobody at that instant, the bounty
  reverts to being what it was designed as — payment for gas on a public good. `FeeHook.sol:154`
  can stay.
- **Making `sweep()` permissioned becomes unnecessary**, which is good, because as `06` already
  noted it would only have moved the timing power to the permission holder whose transaction is
  in the mempool anyway.
- Synthetix's own zero-supply stranding bug (S-2) is fixed rather than inherited.
- Synthetix's period-reset griefing (S-1) is closed twice over: by Yearn's weighted average, and
  by the `minStreamNotify` carry that stops a dust sweep from re-notifying at all.

### What this does NOT fix — say it plainly

- **A buyer who takes a large position right after a sweep and genuinely holds six hours captures
  the stream.** That is not an attack, it is a holder, and every design in this document accepts
  it (Sherlock explicitly judged the Synthetix version not-a-bug). The bound is real and
  quantifiable: they eat six hours of memecoin variance plus the ~2.5–3.5% fee round trip
  measured in `test_E01b`, so the pot must exceed roughly 3% of their position over the window
  for the trade to be worth making.
- **`sweep()` can still brick on an oversized pending pile** — `06` FIX 2, orthogonal, still open.
- **Both internal swaps are still sandwichable** — `06` FIX 5 / E-05, orthogonal, still open.
- **The converter double-payment** — `06` FIX 3, orthogonal, still open.
- **Dividends pushed to a `VestingVault` are still unrecoverable** — `06` FIX 4, orthogonal.

### One correction to `06-recommended-fixes.md`

`06` proposed, as a cheap secondary measure, that "new shares should not accrue immediately — a
balance increase starts earning after a short delay." **Drop it.** Under streaming it is
redundant (same-block capture is already exactly zero), and it is the single most expensive thing
that could be added to this contract: a per-account timestamp SSTORE on every balance increase,
i.e. up to 20,000 gas on the first buy of every new holder, on the hottest path in the system.
It also creates a new griefing surface — dust-transferring to someone resets their delay. Buy the
security from the stream, not from a per-account clock.

### Do we need anything bespoke?

**No.** The recommendation is two published, forked-to-death designs composed at their natural
seam: Synthetix supplies the lump→rate conversion and the time-driven accumulator, Yearn supplies
the re-lock rule that keeps a griefer from stretching the window. The one genuinely bespoke line
is `_accrue()`'s decision to pause rather than advance `_lastAccrual` below
`minSharesForDistribution`, and that is a *bug fix* to Synthetix, not an invention — the same
defect 0xmacro published against Sommelier and the same class of dust-supply hazard that forced
Yearn to add `MINIMUM_SUPPLY` in v3.1.0.

---

## Sources, all read as source rather than docs

- `Synthetixio/synthetix` — `contracts/StakingRewards.sol` (develop/master)
- `Synthetixio/SIPs` — `content/sips/sip-77.md` (the samczsun overflow, with the derivation)
- `sky-ecosystem/endgame-toolkit` — `src/synthetix/StakingRewards.sol` (modern unsigned re-issue)
- `curvefi/curve-dao-contracts` — `contracts/FeeDistributor.vy`
- `sushiswap/masterchef` — `contracts/MasterChef.sol`
- `yearn/tokenized-strategy` — `src/TokenizedStrategy.sol` (API 3.1.0)
- `yearn/yearn-vaults` — `contracts/Vault.vy` and PR #167 ("Profit lock up that increases share
  price steadily over time"), the origin of the anti-sandwich lock
- 0xmacro, "Synthetix Staking Rewards Issue — Inefficient Reward Distribution" (Abhishek Vispute)
- sherlock-audit/2024-06-makerdao-endgame-judging issue #40 (notify front-running, judged
  not-a-bug)
