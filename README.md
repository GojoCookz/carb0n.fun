# hoodstonk

A Uniswap v4 token launchpad on Ethereum where **holders are paid dividends in the pair currency**
— hold `$GOLDFISH`, get paid in PAXG — rather than in more of the token they already hold.

**Sepolia only. Not audited by a third party. Not deployed to mainnet, and not ready to be.**

> Read [`HANDOFF.md`](./HANDOFF.md) first. It lists what does not work, which is the part that
> matters.

## Layout

```
contracts/   Foundry. 1,319 tests, 0 failing.
  src/       PairRegistry, FeeHook, Distributor, LaunchToken, Launcher,
             VestingVault, ReferralVault, TradeRouter, ZapRouter
  test/      Unit, fuzz, invariant, and ten audit surfaces under test/audit/
  audit/     Ten audit write-ups with measured numbers. READ THESE.
  legal/     Securities analysis of the dividend mechanism. Unresolved.
  script/    Deploy and live-test scripts
app/         Vite + React + viem frontend (no wagmi)
```

## Getting started

```bash
git clone --recursive https://github.com/GojoCookz/hoodstonk.git
cd hoodstonk

# contracts
cd contracts
forge test --no-match-contract Fork     # 1,319 passing

# app
cd ../app
bun install
cp .env.example .env                    # needs VITE_PINATA_JWT for image pinning
bun run dev
```

`--recursive` matters: `forge-std`, `openzeppelin-contracts`, `v4-core` and `v4-periphery` are
submodules. **solc is pinned to 0.8.26** and has to stay there — `v4-core/src/PoolManager.sol`
declares an exact `pragma solidity 0.8.26`.

Fork tests are excluded above because they need an archive RPC. `eth.drpc.org` works;
publicnode 403s archive reads.

## How it works

A creator launches a token in one transaction. The Launcher clones an ERC-20, opens a v4 pool
single-sided at a chosen opening market cap, seeds the entire supply, and locks the liquidity by
owning the position and containing no code path that removes it — no admin, no owner, no upgrade.

`FeeHook` charges the fee **inside the swap** rather than through `PoolKey.fee`, which is zero on
every pool here. That means any indexer reading the pool reports a 0% trading cost and is wrong;
the rate is in the `PoolConfigured` event. The fee divides between the platform (a flat 1% of
volume), an optional buyback-and-burn wedge, the creator, and holders — in that order, which is why
the holder rate is **not** the headline rate.

`Distributor` is a Synthetix-style accumulator that streams each distribution linearly over 24
hours. That window is not cosmetic: it is what closed a CRITICAL where an attacker could buy,
trigger a sweep, sell and withdraw in one transaction, taking 40% of the pot. Post-fix the same
attack is a **donation** — measured at -1.13 pair, with the honest resting holder ending 9.88%
ahead.

`ZapRouter` lets a buyer pay in ETH for a launch paired against something else, routing
`ETH -> PAIR -> TOKEN` in one transaction. Holders are still paid in the pair currency; the buyer
just never has to hold it.

## Status

Working end to end on Sepolia: launch, buy, sell, ETH zap, fee collection, sweep, dividend payout.

Not working, in short: no indexer so no chart or trade feed; referrals cannot pay anyone; several
audit findings are documented rather than fixed; and the securities question about the dividend
mechanism is open. `HANDOFF.md` has the full list with numbers.

## License

Unlicensed / all rights reserved for now.
