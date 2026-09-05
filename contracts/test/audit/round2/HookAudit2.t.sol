// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeeHook} from "../../../src/FeeHook.sol";
import {Distributor} from "../../../src/Distributor.sol";
import {Launcher} from "../../../src/Launcher.sol";

import {HookAuditWorld} from "../HookAudit.t.sol";
import {FeeAuditWorld} from "../FeeAudit.t.sol";

// ===============================================================================================
// ROUND 2 - attacking the SWEEP-BRICK FIX in `FeeHook.unlockCallback`, not the bug it replaced.
//
// Round 1 (audit 01 F-05, cross-referenced by audit 04) found that `unlockCallback` burned the
// whole `pendingTokenFees` claim and assumed the swap consumed it. Commit `4fd4df5` added:
//
//   1. a `getSlot0` read that SKIPS the conversion when spot already sits at the swap's own price
//      limit         -> `FeeHook.sol:813-818`, the `PriceLimitAlreadyExceeded` mode; and
//   2. a re-mint of `tokenAmount - spent` that closes the leftover credit and returns the fee to
//      `pendingTokenFees` -> `FeeHook.sol:837-844`, the `CurrencyNotSettled` mode.
//
// This file attacks that new code on two different pool shapes, and the difference between them
// is the headline result:
//
//   PART 1 uses the world from `test/audit/HookAudit.t.sol`, which drives the REAL `Launcher`.
//          Every pool there is single-sided, whole-supply, opened at `_openingTick`. Neither new
//          branch can be reached on that shape - by trading, by a dev buy, by a burn wedge, or by
//          a permissionless third-party liquidity provider.
//
//   PART 2 uses the world from `test/audit/FeeAudit.t.sol`, where the launch token's supply is
//          held by the test contract and only part of it is seeded. Both branches are reachable
//          there, so that is where the new code's arithmetic is actually exercised.
//
// A previous attempt at this audit failed because it hypothesised states and could not build
// them. Where a state could not be constructed, this file says so in a comment instead of
// shipping a test whose precondition never holds.
// ===============================================================================================

// ===============================================================================================
// Probe
// ===============================================================================================

/// @notice A third-party liquidity provider.
/// @dev `FeeHook.getHookPermissions` yields the address suffix `0x20CC` = BEFORE_INITIALIZE |
///      BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA. It
///      contains neither `BEFORE_ADD_LIQUIDITY` (`0x0800`) nor `BEFORE_REMOVE_LIQUIDITY`
///      (`0x0200`), so ANY address may add a position to a launched pool and pull it out again.
///      That is the only mechanism that can change the pool's range capacity after a launch, and
///      therefore the only candidate for breaking the conservation argument in `R2H-01`.
contract OutsideLp {
    PoolModifyLiquidityTest public immutable router;

    constructor(PoolModifyLiquidityTest r) {
        router = r;
    }

    function add(PoolKey memory k, int24 lower, int24 upper, uint128 liq) external {
        router.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(uint256(1))
            }),
            ""
        );
    }

    function remove(PoolKey memory k, int24 lower, int24 upper, uint128 liq) external {
        router.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: -int256(uint256(liq)),
                salt: bytes32(uint256(1))
            }),
            ""
        );
    }
}

/// @notice Replays `unlockCallback`'s burn -> swap -> re-mint sequence against a real pool, with a
///         switch that selects which side of the returned `BalanceDelta` the "spent" figure is
///         read from.
/// @dev This is the negative control for `FeeHook.sol:837-838`. The hook reads
///      `pairIsCurrency0 ? d.amount1() : d.amount0()` - the TOKEN side - and re-mints
///      `tokenAmount - spent`. If it read the PAIR side instead, the re-mint would be the wrong
///      size and `PoolManager.unlock:112` would revert `CurrencyNotSettled` on the residue. Run
///      both ways against the same state, this shows the choice is load-bearing rather than
///      incidentally correct.
contract SideSwitchSettler {
    IPoolManager public immutable manager;

    struct D {
        PoolKey key;
        uint256 amount;
        bool usePairSide;
        bool tokenIsCurrency0;
        address payer;
    }

    constructor(IPoolManager m) {
        manager = m;
    }

    function sell(PoolKey memory key, uint256 amount, bool usePairSide, bool tokenIsCurrency0)
        external
    {
        manager.unlock(abi.encode(D(key, amount, usePairSide, tokenIsCurrency0, msg.sender)));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        D memory d = abi.decode(raw, (D));

        Currency tokenC = d.tokenIsCurrency0 ? d.key.currency0 : d.key.currency1;
        Currency pairC = d.tokenIsCurrency0 ? d.key.currency1 : d.key.currency0;

        // Stand in for the hook's `burn`: open a token credit of exactly `amount`.
        manager.sync(tokenC);
        IERC20(Currency.unwrap(tokenC)).transferFrom(d.payer, address(manager), d.amount);
        manager.settle();

        BalanceDelta bd = manager.swap(
            d.key,
            SwapParams({
                zeroForOne: d.tokenIsCurrency0,
                amountSpecified: -int256(d.amount),
                sqrtPriceLimitX96: d.tokenIsCurrency0
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 tokenDelta = d.tokenIsCurrency0 ? bd.amount0() : bd.amount1();
        int128 pairDelta = d.tokenIsCurrency0 ? bd.amount1() : bd.amount0();

        uint256 spent = d.usePairSide
            ? (pairDelta > 0 ? uint256(uint128(pairDelta)) : 0) // THE WRONG SIDE
            : (tokenDelta < 0 ? uint256(uint128(-tokenDelta)) : 0); // what the hook does

        if (spent < d.amount) manager.mint(address(this), tokenC.toId(), d.amount - spent);
        if (pairDelta > 0) manager.take(pairC, address(this), uint256(uint128(pairDelta)));

        return "";
    }
}

// ===============================================================================================
// PART 1 - the production shape. World: the real `Launcher`.
// ===============================================================================================

abstract contract HookAudit2Launcher is HookAuditWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolModifyLiquidityTest internal lpRouter;
    OutsideLp internal outsideLp;

    function setUp() public virtual override {
        super.setUp();
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        outsideLp = new OutsideLp(lpRouter);
        pair.mint(address(outsideLp), 50_000_000e18);
        vm.startPrank(address(outsideLp));
        pair.approve(address(lpRouter), type(uint256).max);
        pair.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    /// @dev `HookAuditWorld._baseParams` has `sellFeeBps = 0`, which means `pendingTokenFees` is
    ///      never written and the entire surface under test is dead. Everything here needs a tax.
    function _taxedLaunch(uint16 sellFeeBps, uint16 burnBps, uint256 devBuy)
        internal
        returns (address token, PoolKey memory k, PoolId id)
    {
        Launcher.LaunchParams memory p = _baseParams();
        p.sellFeeBps = sellFeeBps;
        p.burnBps = burnBps;
        p.devBuyPairAmount = devBuy;
        return _launch(p);
    }

    function _spot(PoolId id) internal view returns (uint160 s) {
        (s,,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), id);
    }

    /// @dev The limit `FeeHook.sol:809-811` hands the sell-fee conversion.
    ///      `pairIsCurrency0 == !_tokenIsCurrency0()`, so `!pairIsCurrency0 == _tokenIsCurrency0()`.
    function _conversionLimit() internal pure returns (uint160) {
        return _tokenIsCurrency0() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @dev `FeeHook.sol:816-817`, reproduced verbatim, so a test asserts on the SAME predicate
    ///      the code branches on rather than on a proxy for it.
    function _priceAllows(PoolId id) internal view returns (bool) {
        uint160 s = _spot(id);
        return _tokenIsCurrency0() ? s > _conversionLimit() : s < _conversionLimit();
    }

    function _tokenClaims(address token) internal view returns (uint256) {
        return manager.balanceOf(address(hook), Currency.wrap(token).toId());
    }

    function _deferred(PoolId id) internal returns (uint256 total) {
        bytes32 sig = keccak256("SellFeeConversionDeferred(bytes32,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] != sig) continue;
            if (logs[i].topics[1] != PoolId.unwrap(id)) continue;
            total += abi.decode(logs[i].data, (uint256));
        }
    }

    function _sweepRecording(PoolKey memory k, address who) internal returns (uint256) {
        vm.recordLogs();
        vm.prank(who);
        hook.sweep(k);
        return _deferred(k.toId());
    }

    function _acquire(PoolKey memory k, address token, address who, uint256 pairIn)
        internal
        returns (uint256)
    {
        uint256 before = IERC20(token).balanceOf(who);
        _buyExactIn(k, who, pairIn);
        return IERC20(token).balanceOf(who) - before;
    }

    // ------------------------------------------------------------------------------------------
    // R2H-01  Neither new branch is reachable on a pool the real Launcher built.
    // ------------------------------------------------------------------------------------------

    /// @dev **The conservation law, and it is what decides this whole audit.**
    ///
    ///      `Launcher._seedLiquidity` (`Launcher.sol:599-630`) puts the ENTIRE supply into ONE
    ///      position running from the opening tick to `maxUsableTick`, and `_refundResidual` burns
    ///      the dust. So at genesis every launch token in existence is inside the pool's range.
    ///
    ///      A sell fee is taken OUT of the seller's input (`_beforeSwap:605` returns
    ///      `toBeforeSwapDelta(+fee, 0)`) or added on top of it (`_afterSwap:656`). Either way the
    ///      tokens that become `pendingTokenFees` are tokens a BUY had previously pulled out of
    ///      the range. The amount of token the range can reabsorb walking spot back to the opening
    ///      tick is exactly the amount the range has given out - same `L`, same integral, and v4
    ///      rounds that integral in the POOL's favour in both directions.
    ///
    ///      So `pile <= reabsorbable` always, with slack equal to the float plus anything burned.
    ///      The conversion swap can at worst walk spot back to the opening tick; it can never walk
    ///      THROUGH it, which is the only way to run out of liquidity or to hit the price limit.
    ///
    ///      The one thing that does leak is ROUNDING. v4 rounds the input a swap needs UP and the
    ///      output it delivers DOWN (`SwapMath.computeSwapStep`), in the pool's favour both ways,
    ///      so putting the pile back costs a few wei more than taking it out returned. That
    ///      residue - measured below in the low hundreds of wei against a pile of 5.0e25 - is the
    ///      ONLY thing that reaches the re-mint branch on a Launcher pool.
    ///
    ///      This test drives the extreme the mechanism allows: the max sell tax, a dev buy so
    ///      tokens exist outside the pool from block one, and every holder exiting completely
    ///      before a single sweep runs.
    function test_R2H_01_aLauncherPoolOnlyEverDefersRoundingDust() public {
        (address token, PoolKey memory k, PoolId id) = _taxedLaunch(1000, 0, 5e18);

        uint160 openingSpot = _spot(id);

        // The dev buy put tokens in the creator's hands at the opening tick.
        uint256 devBag = IERC20(token).balanceOf(creator);
        assertGt(devBag, 0, "precondition: the dev buy delivered tokens outside the pool");
        vm.prank(creator);
        IERC20(token).approve(address(swapRouter), type(uint256).max);

        uint256 aliceBag = _acquire(k, token, alice, 40e18);
        uint256 bobBag = _acquire(k, token, bob, 60e18);

        // Everybody exits, completely, and the creator dumps the dev bag on top. This maximises
        // the pile relative to what the pool still holds.
        _sellExactIn(k, alice, aliceBag);
        _sellExactIn(k, bob, bobBag);
        _sellExactIn(k, creator, devBag);

        assertEq(IERC20(token).balanceOf(alice), 0, "alice exited completely");
        assertEq(IERC20(token).balanceOf(bob), 0, "bob exited completely");
        assertEq(IERC20(token).balanceOf(creator), 0, "the creator dumped the whole dev bag");

        uint256 pile = hook.pendingTokenFees(id);
        assertGt(pile, 0, "precondition: the sell tax accrued in launch tokens");
        emit log_named_uint("sell-fee pile (launch tokens)   ", pile);
        emit log_named_uint("pool pair reserve at sweep time ", pair.balanceOf(address(manager)));

        // Branch 2's precondition (`priceAllows == false`) does not hold either.
        assertTrue(_priceAllows(id), "the price-limit SKIP branch is not reached");
        assertTrue(
            _tokenIsCurrency0() ? _spot(id) >= openingSpot : _spot(id) <= openingSpot,
            "spot never moved through the opening tick"
        );

        uint256 deferred = _sweepRecording(k, address(this));

        emit log_named_uint("deferred (rounding residue)     ", deferred);
        assertLt(deferred, 1e6, "the re-mint branch carried more than rounding dust");
        assertLt(deferred, pile / 1e18, "the residue is not negligible against the pile");
        assertEq(hook.pendingTokenFees(id), deferred, "the ledger carries exactly the residue");
        assertEq(_tokenClaims(token), deferred, "and the residue is backed by a real claim");

        // The economically meaningful part converted, and the holders were paid out of it.
        assertGt(pile - deferred, pile / 2, "essentially the whole pile converted in one sweep");
    }

    /// @dev The consequence of that residue, and it is a behaviour change round 1 relied on the
    ///      opposite of. `sweep` returns early only when BOTH queues are empty
    ///      (`FeeHook.sol:755`), and the carry writes the residue straight back into
    ///      `pendingTokenFees`, so on any pool that has ever charged a sell fee that early return
    ///      is never taken again. Every later `sweep` opens an unlock cycle, burns the residue,
    ///      runs a swap and re-mints - for a few hundred wei.
    ///
    ///      Not exploitable (see `R2H-14`), but `FeeAudit.t.sol:test_sound_sweepBounty
    ///      CannotBeFarmedByRepetition` states its reasoning as "the early return at `:751` makes
    ///      every subsequent call a no-op", and on a taxed pool that sentence is now false.
    ///      Note that a residue is not guaranteed by every sequence - a single buy/sell/sweep
    ///      round trip converts to exactly zero. It appears once several partial exits have
    ///      compounded their rounding, which the sequence below reproduces deterministically.
    function test_R2H_04_aCarriedResidueKeepsSweepPermanentlyLive() public {
        (address token, PoolKey memory k, PoolId id) = _taxedLaunch(1000, 0, 5e18);

        uint256 devBag = IERC20(token).balanceOf(creator);
        vm.prank(creator);
        IERC20(token).approve(address(swapRouter), type(uint256).max);

        uint256 aliceBag = _acquire(k, token, alice, 40e18);
        uint256 bobBag = _acquire(k, token, bob, 60e18);
        _sellExactIn(k, alice, aliceBag);
        _sellExactIn(k, bob, bobBag);
        _sellExactIn(k, creator, devBag);
        _sweepRecording(k, address(this));

        uint256 residue = hook.pendingTokenFees(id);
        assertGt(residue, 0, "a fully swept taxed pool still carries a residue");
        emit log_named_uint("residue after a clean sweep     ", residue);

        // Ten more sweeps with no new trading at all: each one really executes, and none of them
        // moves the residue, pays a bounty, or pays a dividend.
        uint256 sweeperBefore = pair.balanceOf(bob);
        for (uint256 i = 0; i < 10; ++i) {
            uint256 deferred = _sweepRecording(k, bob);
            assertEq(deferred, hook.pendingTokenFees(id), "the residue was mis-reported");
        }
        assertLe(hook.pendingTokenFees(id), residue, "the residue GREW with no new sells");
        assertEq(pair.balanceOf(bob), sweeperBefore, "an empty sweep paid a bounty");
    }

    /// @dev The same conclusion under randomised traffic rather than one scripted extreme:
    ///      interleaved buys, full and partial exits, sweeps at arbitrary points, and a
    ///      permissionless third-party LP adding and removing a full-range position - the only
    ///      operation that can change the pool's range capacity after a launch.
    ///
    ///      Asserted every step: spot never passes the opening tick (so the SKIP branch is never
    ///      reached), and any carry is bounded by the rounding residue of `R2H-01` rather than by
    ///      a real fee. A scripted prologue and epilogue guarantee the run is not vacuous, which
    ///      is checked explicitly at the end.
    function testFuzz_R2H_01b_noTradeSequenceEverDefersMoreThanDust(uint256 seed) public {
        (address token, PoolKey memory k, PoolId id) = _taxedLaunch(1000, 1500, 0);

        uint160 openingSpot = _spot(id);
        int24 lower = TickMath.minUsableTick(k.tickSpacing);
        int24 upper = TickMath.maxUsableTick(k.tickSpacing);

        vm.startPrank(address(outsideLp));
        IERC20(token).approve(address(lpRouter), type(uint256).max);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        uint128 lpLiq;
        uint256 sweepsWithAPile;
        uint256 sells;
        uint256 lpCycles;
        uint256 worstDeferral;

        // Prologue: a guaranteed buy and a guaranteed sell, so a pile exists whatever the seed
        // makes the loop do.
        uint256 opening = _acquire(k, token, alice, 30e18);
        _sellExactIn(k, alice, opening / 3);
        sells++;

        for (uint256 i = 0; i < 14; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address who = (r >> 8) % 2 == 0 ? alice : bob;
            uint256 amt = 1e15 + ((r >> 16) % 80e18);

            uint256 action = r % 5;
            if (action == 0 || action == 1) {
                _buyExactIn(k, who, amt);
            } else if (action == 2) {
                uint256 bal = IERC20(token).balanceOf(who);
                if (bal > 1e12) {
                    // Sometimes a full exit, sometimes a partial one.
                    uint256 out = (r >> 64) % 2 == 0 ? bal : bal / 2;
                    _sellExactIn(k, who, out);
                    sells++;
                }
            } else if (action == 3) {
                if (hook.pendingTokenFees(id) != 0) sweepsWithAPile++;
                uint256 deferred = _sweepRecording(k, address(this));
                if (deferred > worstDeferral) worstDeferral = deferred;
            } else {
                // The third-party LP toggles a full-range position.
                if (lpLiq == 0) {
                    uint256 bag = _acquire(k, token, address(outsideLp), 5e18 + (r >> 128) % 30e18);
                    uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
                        _spot(id),
                        TickMath.getSqrtPriceAtTick(lower),
                        TickMath.getSqrtPriceAtTick(upper),
                        _tokenIsCurrency0() ? bag : 20_000_000e18,
                        _tokenIsCurrency0() ? 20_000_000e18 : bag
                    );
                    if (liq != 0) {
                        outsideLp.add(k, lower, upper, liq);
                        lpLiq = liq;
                    }
                } else {
                    outsideLp.remove(k, lower, upper, lpLiq);
                    lpLiq = 0;
                    lpCycles++;
                }
            }

            assertTrue(_priceAllows(id), "spot reached the conversion's own price limit");
            assertTrue(
                _tokenIsCurrency0() ? _spot(id) >= openingSpot : _spot(id) <= openingSpot,
                "spot passed through the opening tick"
            );
        }

        // Epilogue: a fresh sell and a guaranteed sweep against it.
        uint256 tail = _acquire(k, token, bob, 10e18);
        _sellExactIn(k, bob, tail);
        sells++;
        assertGt(hook.pendingTokenFees(id), 0, "the epilogue really did queue a pile");
        sweepsWithAPile++;
        uint256 last = _sweepRecording(k, address(this));
        if (last > worstDeferral) worstDeferral = last;

        assertLt(worstDeferral, 1e6, "A RANDOMISED SEQUENCE DEFERRED MORE THAN ROUNDING DUST");
        assertGt(sells, 1, "vacuous: no sell ever happened, so no pile could exist");
        assertGt(sweepsWithAPile, 0, "vacuous: never swept while a pile was queued");
        lpCycles; // the LP path is opportunistic; R2H-01c drives it deliberately
    }

    // ------------------------------------------------------------------------------------------
    // R2H-02  The buyback leg still has NO price guard - but a pin can never reach it.
    // ------------------------------------------------------------------------------------------

    /// @dev The fix gave the CONVERSION swap a `getSlot0` guard (`FeeHook.sol:813-818`) and gave
    ///      the BUYBACK swap (`FeeHook.sol:861-872`) nothing. Round 1's V-04 flagged the buyback's
    ///      partial-fill mode; the `PriceLimitAlreadyExceeded` mode it also has was not mentioned.
    ///
    ///      This checks the two things that would make that asymmetry exploitable, and neither
    ///      holds:
    ///
    ///      1. The buyback's limit is always at the OPPOSITE extreme from the conversion's, so a
    ///         pin created by a conversion can never be the pin the buyback trips over.
    ///      2. Exhausting the seeded range in the buy direction is not merely expensive, it
    ///         DIVERGES: the position runs to `maxUsableTick`, and the pair currency needed to walk
    ///         spot to the far edge is `L * (sqrt(P_max) - sqrt(P_open))`, which is ~1e19 times the
    ///         whole opening market cap. A buy of 100x the opening market cap moves spot a
    ///         measurable but tiny fraction of the way.
    function test_R2H_02_theBuybackLegCannotBePinnedOnALauncherPool() public {
        (address token, PoolKey memory k, PoolId id) = _taxedLaunch(1000, 2000, 0);

        // 1. Opposite extremes, by construction.
        uint160 conversionLimit = _conversionLimit();
        uint160 buybackLimit =
            _tokenIsCurrency0() ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
        assertTrue(conversionLimit != buybackLimit, "the two legs share a limit");
        assertEq(
            _tokenIsCurrency0() ? conversionLimit : buybackLimit,
            TickMath.MIN_SQRT_PRICE + 1,
            "one leg is at the floor"
        );

        // 2. Buy at 100x the opening market cap and watch the range refuse to be exhausted.
        _buyExactIn(k, alice, OPENING_MCAP * 100);
        uint160 s = _spot(id);
        assertTrue(
            _tokenIsCurrency0() ? s < buybackLimit : s > buybackLimit,
            "a 100x-market-cap buy did NOT exhaust the seeded range"
        );
        emit log_named_uint("spot after a 100x mcap buy      ", s);
        emit log_named_uint("the buyback's own limit         ", buybackLimit);

        // And the sweep that follows - conversion leg and buyback leg in the same unlock cycle -
        // settles cleanly on that state.
        _sellExactIn(k, alice, IERC20(token).balanceOf(alice) / 2);
        assertGt(hook.pendingTokenFees(id), 0, "precondition: a pile to convert");
        uint256 deferred = _sweepRecording(k, address(this));
        assertEq(deferred, 0, "nothing deferred");
        assertGt(hook.totalBurned(id), 0, "the buyback leg really ran in the same callback");
        assertEq(hook.pendingTokenFees(id), 0, "and the conversion leg cleared the pile");
    }

    // ------------------------------------------------------------------------------------------
    // R2H-03  Streaming: `sweep` moves MONEY now, entitlement vests over 24h.
    // ------------------------------------------------------------------------------------------

    /// @dev `Distributor.distribute` no longer credits the accumulator in the instant a sweep
    ///      lands. Nothing in `FeeHook` may depend on instant credit. Checked by measuring both
    ///      clocks around one sweep: the distributor's BALANCE moves immediately, every holder's
    ///      `withdrawableOf` is still exactly zero, and the sweep's own accounting
    ///      (`pendingFees`, `pendingTokenFees`, the claim ledger) is complete regardless.
    function test_R2H_03_theHookNeverAssumesInstantHolderCredit() public {
        (address token, PoolKey memory k, PoolId id) = _taxedLaunch(1000, 0, 0);
        (address distAddr,,,,,,,,,,,,,) = hook.poolConfig(id);
        Distributor dist = Distributor(distAddr);

        uint256 bag = _acquire(k, token, alice, 50e18);
        _sellExactIn(k, alice, bag / 2);
        assertGt(hook.pendingTokenFees(id), 0, "precondition: a pile exists");

        uint256 distBefore = pair.balanceOf(address(dist));
        uint256 aliceClaimBefore = dist.withdrawableOf(alice);

        uint256 deferred = _sweepRecording(k, address(this));

        assertEq(deferred, 0, "sanity: this is the ordinary path");
        assertEq(hook.pendingTokenFees(id), 0, "the hook finished its own accounting");
        assertEq(hook.pendingFees(id), 0, "and cleared the pair queue");
        assertGt(pair.balanceOf(address(dist)) - distBefore, 0, "MONEY moved on the sweep");
        assertEq(
            dist.withdrawableOf(alice), aliceClaimBefore, "ENTITLEMENT did not move on the sweep"
        );

        // ...and it does arrive once the stream has run. This is the control that stops the
        // assertion above from being "the dividend was never credited at all".
        _vest(dist);
        assertGt(dist.withdrawableOf(alice), aliceClaimBefore, "the stream did credit alice later");
    }
}

contract HookAudit2LauncherToken0Test is HookAudit2Launcher {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract HookAudit2LauncherToken1Test is HookAudit2Launcher {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

// ===============================================================================================
// PART 2 - the shape where the new branches ARE reachable, so the new arithmetic gets exercised.
//
// `FeeAuditWorld` mints the whole supply to the test contract and seeds only part of it, so
// launch tokens exist that were never inside the pool's range. That breaks the conservation
// argument of R2H-01 and is exactly the distribution round 1's F-05 reproduction used.
//
// It is NOT what `Launcher` produces (see PART 1). Everything below therefore measures whether
// the new code is CORRECT, not whether it is reachable.
// ===============================================================================================

abstract contract HookAudit2Deferral is FeeAuditWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant SWEEPER = address(0x51EEE9);

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    /// @dev `FeeAuditWorld._newSingleSidedPool` hardcodes `burnBps: 0`, so the buyback leg never
    ///      runs beside a deferral. This one can. (It also arms graduation, which used to arm the
    ///      automatic sweep as a side effect; that mechanism has been deleted and graduation now
    ///      arms nothing but graduation.)
    function _ssPool(uint16 feeBps, uint16 sellFeeBps, uint16 burnBps, uint256 gradThreshold)
        internal
        returns (PoolKey memory k)
    {
        return _ssPoolAt(0, feeBps, sellFeeBps, burnBps, gradThreshold);
    }

    /// @dev The same, opened at an arbitrary (spacing-aligned) tick. A pool at tick 0 prices the
    ///      launch token 1:1 against the pair, which makes the two sides of a swap delta
    ///      numerically similar and weakens any test that needs to tell them apart.
    function _ssPoolAt(
        int24 openingTick,
        uint16 feeBps,
        uint16 sellFeeBps,
        uint16 burnBps,
        uint256 gradThreshold
    ) internal returns (PoolKey memory k) {
        (Currency c0, Currency c1) = _tokenIsCurrency0()
            ? (Currency.wrap(address(token)), Currency.wrap(address(pair)))
            : (Currency.wrap(address(pair)), Currency.wrap(address(token)));

        k = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        hook.configurePoolFull(
            k,
            FeeHook.FeeSetup({
                distributor: address(dist),
                pairCurrency: Currency.wrap(address(pair)),
                feeBps: feeBps,
                sellFeeBps: sellFeeBps,
                burnBps: burnBps,
                creator: creator,
                creatorBps: 2000,
                rewardCurrency: Currency.wrap(address(0))
            , openingWindow: 0, openingFeeBps: 0})
        );
        if (gradThreshold != 0) hook.configureGraduation(k, gradThreshold, SUPPLY);

        manager.initialize(k, TickMath.getSqrtPriceAtTick(openingTick));

        (int24 lower, int24 upper) = _tokenIsCurrency0()
            ? (openingTick, TickMath.maxUsableTick(60))
            : (TickMath.minUsableTick(60), openingTick);

        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: 1_000_000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _spot(PoolId id) internal view returns (uint160 s) {
        (s,,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), id);
    }

    function _conversionLimit() internal pure returns (uint160) {
        return _tokenIsCurrency0() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _priceAllows(PoolId id) internal view returns (bool) {
        uint160 s = _spot(id);
        return _tokenIsCurrency0() ? s > _conversionLimit() : s < _conversionLimit();
    }

    function _tokenClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), Currency.wrap(address(token)).toId());
    }

    function _pairClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), Currency.wrap(address(pair)).toId());
    }

    function _deferred(PoolId id) internal returns (uint256 total) {
        bytes32 sig = keccak256("SellFeeConversionDeferred(bytes32,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics.length < 2) continue;
            if (logs[i].topics[0] != sig) continue;
            if (logs[i].topics[1] != PoolId.unwrap(id)) continue;
            total += abi.decode(logs[i].data, (uint256));
        }
    }

    function _sweepRecording(PoolKey memory k, address who) internal returns (uint256) {
        vm.recordLogs();
        vm.prank(who);
        hook.sweep(k);
        return _deferred(k.toId());
    }

    /// @dev A dump that is larger than anything the pool ever sold - the distribution round 1's
    ///      F-05 used. Leaves the pile far bigger than the pool's whole pair reserve, spot pinned
    ///      at the conversion's own limit, and the pair-currency fees queued behind it.
    function _pileUpASellTax(PoolKey memory k, uint256 dump) internal {
        _buyExactIn(k, bob, 1e18);
        token.transfer(alice, dump);
        _sellExactIn(k, alice, dump);
    }

    // ------------------------------------------------------------------------------------------
    // R2H-10  The re-mint closes the delta EXACTLY on a partial fill.
    // ------------------------------------------------------------------------------------------

    /// @dev `PoolManager.unlock:112` checks `NonzeroDeltaCount.read() != 0`, which is
    ///      SIGN-AGNOSTIC. So the only value of `unspent` that lets the cycle close is exactly
    ///      `tokenAmount - spent`, where `spent` is read off the TOKEN side of the swap delta.
    ///      A sweep that returns at all is therefore already most of the proof; this pins the
    ///      arithmetic on top of it.
    ///
    ///      Measured on the partial-fill path: the singleton's ERC-6909 launch-token balance falls
    ///      by exactly what the pool consumed, `pendingTokenFees` equals what came back, and the
    ///      two are the same number the event reported.
    function test_R2H_10_thePartialFillRemintClosesTheDeltaToTheWei() public {
        // Opened well away from 1:1 on purpose, so the token side and the pair side of the same
        // swap delta differ by orders of magnitude and the sign control below has teeth.
        PoolKey memory k =
            _ssPoolAt(_tokenIsCurrency0() ? int24(-46080) : int24(46080), 300, 1000, 0, 0);
        PoolId id = k.toId();

        _pileUpASellTax(k, 2_000_000e18);
        uint256 pile = hook.pendingTokenFees(id);

        // Lift spot off the pin so the swap is legal, then let it partially fill.
        _buyExactIn(k, bob, 1e18);
        assertTrue(_priceAllows(id), "precondition: the conversion swap runs");

        uint256 claimsBefore = _tokenClaims();
        uint256 pairInManagerBefore = pair.balanceOf(address(manager));
        uint256 pairQueued = hook.pendingFees(id);

        uint256 deferred = _sweepRecording(k, SWEEPER);

        assertGt(deferred, 0, "precondition: this input really is a PARTIAL fill");
        assertLt(deferred, pile, "precondition: some of the pile really did convert");

        uint256 consumed = pile - deferred;
        assertEq(
            claimsBefore - _tokenClaims(),
            consumed,
            "the singleton's claim balance moved by exactly what the pool consumed"
        );
        assertEq(hook.pendingTokenFees(id), deferred, "the ledger carries exactly what came back");
        assertEq(_tokenClaims(), deferred, "and the carried ledger is fully backed by a claim");

        // The sign control. `spent` must come from the TOKEN side of the delta. The PAIR side of
        // the same swap is a completely different number here, so a wrong-side read would have
        // minted the wrong amount and `unlock` would have reverted `CurrencyNotSettled`.
        uint256 pairGained = pairInManagerBefore - pair.balanceOf(address(manager)) - pairQueued;
        emit log_named_uint("token consumed by the pool      ", consumed);
        emit log_named_uint("pair gained by the same swap    ", pairGained);
        assertGt(
            consumed > pairGained ? consumed / (pairGained + 1) : pairGained / (consumed + 1),
            10,
            "the two sides are too close for this to be a real sign control"
        );
    }

    // ------------------------------------------------------------------------------------------
    // R2H-11  The price-limit SKIP branch settles at zero fill, and is idempotent.
    // ------------------------------------------------------------------------------------------

    /// @dev `Pool.swap:322-338` reverts `PriceLimitAlreadyExceeded` when
    ///      `sqrtPriceLimitX96 >= sqrtPriceX96` (zeroForOne) or `<=` (oneForZero). The guard at
    ///      `FeeHook.sol:816-817` is the exact negation of that condition in both orderings, so
    ///      the skip fires on precisely the inputs that would have reverted and on no others.
    ///
    ///      Nothing is burned on that branch, so there is no delta to close - checked by hammering
    ///      it twenty times and asserting the claim ledger, the pile and the sweeper's balance are
    ///      bit-identical throughout.
    function test_R2H_11_theSkipBranchIsAnExactIdempotentNoOp() public {
        PoolKey memory k = _ssPool(300, 1000, 0, 0);
        PoolId id = k.toId();

        _pileUpASellTax(k, 2_000_000e18);

        assertEq(_spot(id), _conversionLimit(), "precondition: spot is pinned AT the limit");
        assertFalse(_priceAllows(id), "precondition: the SKIP branch is the one taken");

        // First sweep releases the pair-currency fees queued behind the pile.
        uint256 first = _sweepRecording(k, SWEEPER);
        assertEq(first, hook.pendingTokenFees(id), "the whole pile was reported as deferred");
        assertEq(hook.pendingFees(id), 0, "the pair fees behind it were NOT trapped");

        uint256 pile = hook.pendingTokenFees(id);
        uint256 claims = _tokenClaims();
        uint256 sweeperBal = pair.balanceOf(SWEEPER);
        uint256 distBal = pair.balanceOf(address(dist));

        for (uint256 i = 0; i < 20; ++i) {
            uint256 deferred = _sweepRecording(k, SWEEPER);
            assertEq(deferred, pile, "the skip branch returned something other than the pile");
            assertEq(hook.pendingTokenFees(id), pile, "PILE MOVED on a no-op sweep");
            assertEq(_tokenClaims(), claims, "CLAIM LEDGER MOVED on a no-op sweep");
        }

        assertEq(pair.balanceOf(SWEEPER), sweeperBal, "a pinned pool paid a repeat bounty");
        assertEq(pair.balanceOf(address(dist)), distBal, "a pinned pool paid a repeat dividend");
        assertEq(_pairClaims(), 0, "no stray pair claim was left behind");
    }

    // ------------------------------------------------------------------------------------------
    // R2H-12  `pendingTokenFees` cannot be inflated by the carry.
    // ------------------------------------------------------------------------------------------

    /// @dev `sweep` zeroes `pendingTokenFees[id]` (`FeeHook.sol:758`) BEFORE `unlock`, and the
    ///      callback adds back inside it (`:842` / `:850`). The two things that could double-count
    ///      are (a) an accrual landing between the zeroing and the add-back and (b) a second
    ///      add-back in one call.
    ///
    ///      (a) is impossible: the only writer is `_accrue`, reachable only from `_beforeSwap` /
    ///      `_afterSwap`, and `Hooks.beforeSwap:253` / `Hooks.afterSwap:293` skip both when
    ///      `msg.sender == address(self)` - which is exactly the internal conversion and buyback
    ///      swaps. No outside swap can interleave, because v4's `Lock` is a single global
    ///      transient flag and the cycle is already open.
    ///
    ///      (b) is structural: the branches are exclusive.
    ///
    ///      Measured here against the strongest available oracle - the singleton's own ERC-6909
    ///      balance, which no test can fake - across a mixed sequence of pinned sweeps, partial
    ///      fills and buys.
    function test_R2H_12_thePileIsAlwaysExactlyBackedByARealClaim() public {
        PoolKey memory k = _ssPool(300, 1000, 0, 0);
        PoolId id = k.toId();

        _pileUpASellTax(k, 2_000_000e18);
        uint256 accrued = hook.pendingTokenFees(id);
        uint256 converted;

        for (uint256 i = 0; i < 8; ++i) {
            uint256 before = _tokenClaims();
            _sweepRecording(k, SWEEPER);
            converted += before - _tokenClaims();

            assertEq(
                hook.pendingTokenFees(id), _tokenClaims(), "the ledger drifted from the singleton"
            );
            assertLe(hook.pendingTokenFees(id), accrued, "THE PILE GREW WITHOUT A NEW SELL");
            assertEq(
                hook.pendingTokenFees(id) + converted,
                accrued,
                "a launch-token fee was neither converted nor still queued"
            );

            _buyExactIn(k, bob, 5e18);
        }
        assertGt(converted, 0, "vacuous: nothing ever converted");
    }

    // ------------------------------------------------------------------------------------------
    // R2H-13  The deferred pile really does convert - the HIGH question.
    // ------------------------------------------------------------------------------------------

    /// @dev The existing regression (`FeeAudit.t.sol:test_F05_...`) proves this on a pool with no
    ///      burn wedge. This runs the same proof with `burnBps = 2000`, so the conversion leg, the
    ///      buyback leg, the bounty and the three-way split all execute in the same
    ///      `unlockCallback` as the carry.
    function test_R2H_13_aCarriedPileConvertsInFullOnceBuyingRebuildsThePairSide() public {
        PoolKey memory k = _ssPool(300, 1000, 2000, 1_000_000e18);
        PoolId id = k.toId();

        _pileUpASellTax(k, 2_000_000e18);
        uint256 pile = hook.pendingTokenFees(id);

        // Two sweeps the pool cannot fill: one pinned, one partial.
        assertFalse(_priceAllows(id), "precondition: pinned");
        assertEq(_sweepRecording(k, SWEEPER), pile, "sweep #1 carried the whole pile");

        _buyExactIn(k, bob, 1e18);
        uint256 afterPartial = hook.pendingTokenFees(id);
        _sweepRecording(k, SWEEPER);
        assertLt(hook.pendingTokenFees(id), afterPartial, "sweep #2 converted some of it");
        assertGt(hook.pendingTokenFees(id), 0, "sweep #2 could not finish - that is the scenario");

        // Real buying puts real pair currency in the pool, and the SAME claim finally clears.
        _buyExactIn(k, bob, 500_000e18);
        uint256 distBefore = pair.balanceOf(address(dist));
        uint256 burnedBefore = hook.totalBurned(id);

        uint256 deferred = _sweepRecording(k, SWEEPER);

        assertEq(deferred, 0, "nothing was deferred on the final sweep");
        assertEq(hook.pendingTokenFees(id), 0, "THE CARRIED CLAIM CONVERTED IN FULL");
        assertEq(_tokenClaims(), 0, "and the singleton holds no launch-token claim for it");
        assertGt(pair.balanceOf(address(dist)) - distBefore, 0, "holders were paid out of it");
        assertGt(hook.totalBurned(id) - burnedBefore, 0, "the buyback ran in the same callback");
        assertEq(hook.pendingFees(id), 0, "and the pool is fully swept");
    }

    // ------------------------------------------------------------------------------------------
    // R2H-14  Round 1's "the bounty cannot be farmed by repetition" no longer holds LITERALLY.
    // ------------------------------------------------------------------------------------------

    /// @dev `FeeAudit.t.sol:test_sound_sweepBountyCannotBeFarmedByRepetition` rests on "`sweep`
    ///      zeroes both counters, so every later call hits the `pairAmount == 0 && tokenAmount == 0`
    ///      early return at `:755`". After the fix a carried pile is written straight back, so that
    ///      early return is NOT taken and `sweep` is repeatedly live on the same pool.
    ///
    ///      Checked here for whether that is exploitable, and it is not: fragmenting the same
    ///      economic activity across many sweeps never pays more bounty than sweeping once, because
    ///      the bounty is a linear 0.5% with floor division. Both arms run from the same state
    ///      snapshot so the curve is bit-identical.
    function test_R2H_14_repeatedSweepsOnACarriedPileCannotOutEarnOneSweep() public {
        PoolKey memory k = _ssPool(300, 1000, 0, 0);

        _pileUpASellTax(k, 2_000_000e18);
        _sweepRecording(k, SWEEPER); // clear the pair queue; the pile is now carried

        uint256 snap = vm.snapshotState();

        // Arm A: buy five times, sweep after each.
        uint256 startBal = pair.balanceOf(SWEEPER);
        for (uint256 i = 0; i < 5; ++i) {
            _buyExactIn(k, bob, 20_000e18);
            _sweepRecording(k, SWEEPER);
        }
        uint256 fragmented = pair.balanceOf(SWEEPER) - startBal;

        vm.revertToState(snap);

        // Arm B: the same five buys, one sweep at the end.
        for (uint256 i = 0; i < 5; ++i) {
            _buyExactIn(k, bob, 20_000e18);
        }
        _sweepRecording(k, SWEEPER);
        uint256 once = pair.balanceOf(SWEEPER) - startBal;

        emit log_named_uint("bounty, five fragmented sweeps  ", fragmented);
        emit log_named_uint("bounty, one sweep at the end    ", once);
        assertGt(once, 0, "vacuous: the single sweep paid no bounty at all");
        assertLe(fragmented, once, "FRAGMENTING SWEEPS OUT-EARNED SWEEPING ONCE");
    }

    // ------------------------------------------------------------------------------------------
    // R2H-15  Conservation of the sell tax across a long mixed sequence.
    // ------------------------------------------------------------------------------------------

    /// @dev Every launch token ever charged as a sell fee is, at all times, either (a) still
    ///      queued in `pendingTokenFees`, or (b) consumed by a conversion swap. Never destroyed,
    ///      never duplicated. Asserted against the singleton's ERC-6909 balance rather than
    ///      against the hook's own bookkeeping, so the hook cannot mark its own homework.
    function testFuzz_R2H_15_everySellFeeIsEitherConvertedOrStillQueued(uint256 seed) public {
        PoolKey memory k = _ssPool(300, 1000, 1500, 0);
        PoolId id = k.toId();

        token.transfer(alice, 300_000_000e18);
        _buyExactIn(k, bob, 1e18);

        uint256 accrued;
        uint256 converted;
        uint256 sells;

        // A guaranteed sell up front, so no seed can produce a run with nothing to conserve.
        {
            uint256 before = hook.pendingTokenFees(id);
            _sellExactIn(k, alice, 5_000_000e18);
            accrued += hook.pendingTokenFees(id) - before;
            sells++;
        }

        for (uint256 i = 0; i < 10; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = r % 3;

            if (action == 0) {
                _buyExactIn(k, bob, 1e18 + (r >> 32) % 200_000e18);
            } else if (action == 1) {
                uint256 amt = 1e18 + (r >> 32) % 20_000_000e18;
                // A pinned pool rejects EVERY sell, not just the hook's. `Pool.swap:322-325`
                // reverts `PriceLimitAlreadyExceeded` for any caller passing the same extreme
                // limit, which is what every router sends. Skipping here keeps the sequence
                // legal; the effect itself is reported as R2H-A in the writeup.
                if (token.balanceOf(alice) > amt && _priceAllows(id)) {
                    uint256 before = hook.pendingTokenFees(id);
                    _sellExactIn(k, alice, amt);
                    accrued += hook.pendingTokenFees(id) - before;
                    sells++;
                }
            } else {
                uint256 claimsBefore = _tokenClaims();
                _sweepRecording(k, SWEEPER);
                converted += claimsBefore - _tokenClaims();
            }

            assertEq(
                hook.pendingTokenFees(id),
                _tokenClaims(),
                "the ledger and the singleton disagree"
            );
            assertEq(
                hook.pendingTokenFees(id) + converted, accrued, "a sell fee went missing or doubled"
            );
        }

        assertGt(sells, 0, "vacuous: no sell fee was ever charged");
    }

    // ------------------------------------------------------------------------------------------
    // R2H-10b  The sign choice is load-bearing - the negative control.
    // ------------------------------------------------------------------------------------------

    /// @dev Same pool, same state, same burn/swap/re-mint sequence, run twice from one snapshot.
    ///      Reading `spent` off the TOKEN side settles; reading it off the PAIR side reverts
    ///      `CurrencyNotSettled`. Since `PoolManager.unlock:112` tests
    ///      `NonzeroDeltaCount.read() != 0` and is sign-agnostic, that is the whole proof: the
    ///      only re-mint value that closes the cycle is `tokenAmount - tokenSideSpent`.
    ///
    ///      The probe pool charges NO sell tax on purpose. With a tax the hook's own
    ///      `BeforeSwapDelta` debits the caller the full specified amount, so the token side of
    ///      the delta is always `-amount` and a partial fill is invisible from outside.
    function test_R2H_10b_readingSpentOffThePairSideFailsToSettle() public {
        PoolKey memory k =
            _ssPoolAt(_tokenIsCurrency0() ? int24(-46080) : int24(46080), 300, 0, 0, 0);
        PoolId id = k.toId();

        SideSwitchSettler probe = new SideSwitchSettler(IPoolManager(address(manager)));
        token.approve(address(probe), type(uint256).max);

        // A shallow pair reserve, so the probe's sell is a genuine partial fill.
        _buyExactIn(k, bob, 1e18);
        assertTrue(_priceAllows(id), "precondition: the swap is legal");

        uint256 amount = 2_000_000e18;
        uint256 snap = vm.snapshotState();

        // The hook's choice.
        probe.sell(k, amount, false, _tokenIsCurrency0());
        assertEq(
            manager.balanceOf(address(probe), Currency.wrap(address(token)).toId()) > 0,
            true,
            "the token-side read left an unconsumed claim, as it should"
        );

        vm.revertToState(snap);

        // The other side, identical in every other respect.
        vm.expectRevert(abi.encodeWithSignature("CurrencyNotSettled()"));
        probe.sell(k, amount, true, _tokenIsCurrency0());
    }

    // ------------------------------------------------------------------------------------------
    // R2H-17  A pinned pool rejects EVERY sell, from everyone.
    // ------------------------------------------------------------------------------------------

    /// @dev The state the SKIP branch exists to survive is not a hook state, it is a POOL state,
    ///      and it has a consequence outside the hook. Once spot sits at `MIN_SQRT_PRICE + 1`
    ///      (or `MAX_SQRT_PRICE - 1`), `Pool.swap:322-325` reverts `PriceLimitAlreadyExceeded` for
    ///      any caller whose limit is that same extreme - which is what every router sends by
    ///      default, and the only limit that can be passed in that direction, since a legal one
    ///      must be strictly beyond spot and there is nothing beyond it.
    ///
    ///      So the fix keeps `sweep` alive through a state in which the token cannot be sold at
    ///      all. Buys still work, and a buy is what lifts spot back off the pin.
    function test_R2H_17_aPinnedPoolRejectsEverySellUntilSomebodyBuys() public {
        PoolKey memory k = _ssPool(300, 1000, 0, 0);
        PoolId id = k.toId();

        _pileUpASellTax(k, 2_000_000e18);
        assertEq(_spot(id), _conversionLimit(), "precondition: spot is pinned at the limit");

        // An ordinary holder cannot exit. This is not the hook reverting - it is the pool.
        token.transfer(bob, 1_000e18);
        vm.expectRevert(
            abi.encodeWithSignature(
                "PriceLimitAlreadyExceeded(uint160,uint160)", _spot(id), _conversionLimit()
            )
        );
        _sellExactIn(k, bob, 1_000e18);

        // The sweep, by contrast, survives it - which is the whole point of the skip branch.
        _sweepRecording(k, SWEEPER);
        assertGt(hook.pendingTokenFees(id), 0, "the pile is carried through the pinned state");

        // And the smallest possible buy unpins the pool for everyone. There is no liquidity
        // between the pin and the opening tick, so the walk back up costs nothing.
        _buyExactIn(k, bob, 1);
        assertTrue(_priceAllows(id), "a one-wei buy did not lift spot off the pin");
        _sellExactIn(k, bob, 1_000e18); // no revert
    }

    // ------------------------------------------------------------------------------------------
    // R2H-18  The zero-gain edge: a conversion that consumes token and returns no pair.
    // ------------------------------------------------------------------------------------------

    /// @dev The narrowest delta path in the new code. With `pairAmount == 0`, a conversion that
    ///      fills only partially and earns nothing leaves `totalPair == 0`, and `FeeHook.sol:855`
    ///      returns from the callback BEFORE the buyback and before the `take`. Every delta the
    ///      call opened (burn +tokenAmount, swap -spent, mint -unspent) has to already be closed
    ///      at that line or the cycle reverts.
    ///
    ///      Reached by unpinning with a buy small enough that `fee == 0` at `_beforeSwap:597`, so
    ///      the pair queue stays empty and the pool gains essentially nothing to sell into.
    function test_R2H_18_aZeroGainConversionStillSettlesAndTheEarlyReturnIsSafe() public {
        PoolKey memory k = _ssPool(300, 1000, 0, 0);
        PoolId id = k.toId();

        _pileUpASellTax(k, 2_000_000e18);
        _sweepRecording(k, SWEEPER); // drains the pair queue; the pile is carried
        assertEq(hook.pendingFees(id), 0, "precondition: pairAmount is zero from here on");

        uint256 pile = hook.pendingTokenFees(id);
        _buyExactIn(k, bob, 1);
        assertEq(hook.pendingFees(id), 0, "a one-wei buy is below the fee floor, as intended");

        uint256 distBefore = pair.balanceOf(address(dist));
        uint256 sweeperBefore = pair.balanceOf(SWEEPER);

        uint256 deferred = _sweepRecording(k, SWEEPER);

        assertGt(deferred, 0, "precondition: still a partial fill");
        assertEq(hook.pendingTokenFees(id), deferred, "the ledger carries what came back");
        assertEq(_tokenClaims(), deferred, "and it is backed to the wei");
        assertEq(pair.balanceOf(address(dist)), distBefore, "nothing could be paid out");
        assertEq(pair.balanceOf(SWEEPER), sweeperBefore, "and no bounty was paid");

        // What the pool DID consume for that nothing. This is a real, permanent loss of launch
        // tokens from the pile - bounded here, but not zero.
        emit log_named_uint("tokens consumed for zero pair   ", pile - deferred);
        assertLt(pile - deferred, pile / 1000, "the zero-gain leak is bounded");
    }

    // ------------------------------------------------------------------------------------------
    // R2H-19  Sandwiching the conversion. Round 1's E-05 said the sweep swaps have no minimum
    //         output; the fix changes what that costs, because the sweep no longer reverts.
    // ------------------------------------------------------------------------------------------

    /// @dev Before the fix, an attacker who dumped in front of a `sweep` made the sweep REVERT -
    ///      annoying, but nothing left the system. After the fix the same dump makes the sweep
    ///      convert the pile at the depressed price and carry the rest. Availability was traded
    ///      for the possibility of value leakage, so the question is whether the leak pays.
    ///
    ///      Measured against a snapshot control of the identical sweep with no attacker, so the
    ///      curve is bit-identical. The attacker never calls `sweep` themselves - the 0.5% bounty
    ///      is payable to anyone holding nothing, and including it would flatter the attack.
    function test_R2H_19_frontRunningTheConversionCostsTheAttackerMoreThanItMoves() public {
        PoolKey memory k = _ssPool(300, 1000, 0, 0);
        PoolId id = k.toId();

        // A pool with real depth on both sides and a pile worth converting. Deliberately NOT
        // drained: the conversion has to actually run for the sandwich to have a victim.
        _buyExactIn(k, bob, 500_000e18);
        token.transfer(alice, 60_000e18);
        _sellExactIn(k, alice, 60_000e18);
        assertGt(hook.pendingTokenFees(id), 0, "precondition: a pile to convert");
        assertTrue(_priceAllows(id), "precondition: the conversion will actually run");

        uint256 snap = vm.snapshotState();

        // CONTROL: nobody interferes.
        uint256 distBefore = pair.balanceOf(address(dist));
        _sweepRecording(k, SWEEPER);
        uint256 honestToHolders = pair.balanceOf(address(dist)) - distBefore;

        vm.revertToState(snap);

        // ATTACK: dump in front, let the sweep convert into it, buy back behind.
        token.transfer(bob, 150_000e18);
        uint256 attackerPairStart = pair.balanceOf(bob);
        uint256 attackerTokenStart = token.balanceOf(bob);

        _sellExactIn(k, bob, 150_000e18);
        uint256 distBefore2 = pair.balanceOf(address(dist));
        _sweepRecording(k, SWEEPER);
        uint256 sandwichedToHolders = pair.balanceOf(address(dist)) - distBefore2;

        // Buy back to the same token position, so the two arms are compared on pair currency only.
        uint256 owed = attackerTokenStart - token.balanceOf(bob);
        _buyExactOut(k, bob, owed);

        int256 attackerPnl =
            int256(pair.balanceOf(bob)) - int256(attackerPairStart);

        emit log_named_uint("holders paid, no attacker       ", honestToHolders);
        emit log_named_uint("holders paid, sandwiched        ", sandwichedToHolders);
        emit log_named_int("attacker pair P&L               ", attackerPnl);
        assertEq(token.balanceOf(bob), attackerTokenStart, "the arms are not comparable");

        assertLt(attackerPnl, int256(0), "SANDWICHING THE CONVERSION IS PROFITABLE");
    }

    // ------------------------------------------------------------------------------------------
    // R2H-20  What a carried pile does to subsequent buying.
    // ------------------------------------------------------------------------------------------

    /// @dev The design consequence of deferring rather than reverting, stated as a number. While
    ///      a pile is carried, `sweep` is permissionless and pays a bounty, so somebody will call
    ///      it. Each call sells as much of the pile as the pool's pair reserve can absorb - and on
    ///      a single-sided pool the pair reserve IS the new buying. So new buying is converted
    ///      into dividends rather than into price, until the backlog clears.
    ///
    ///      This is not a defect of the fix - reverting instead was strictly worse - but it is a
    ///      behaviour the UI has to state, so it is measured rather than asserted about.
    function test_R2H_20_aCarriedPileConvertsNewBuyingRatherThanLettingItLift() public {
        PoolKey memory k = _ssPool(300, 1000, 0, 0);
        PoolId id = k.toId();

        _pileUpASellTax(k, 2_000_000e18);
        _sweepRecording(k, SWEEPER);
        assertGt(hook.pendingTokenFees(id), 0, "precondition: a large pile is carried");

        uint160 pinned = _spot(id);
        uint256 buyIn = 20_000e18;

        uint256 managerBefore = pair.balanceOf(address(manager));
        _buyExactIn(k, bob, buyIn);
        uint256 landedInPool = pair.balanceOf(address(manager)) - managerBefore;
        uint160 afterBuy = _spot(id);

        uint256 poolPairBeforeSweep = pair.balanceOf(address(manager));
        _sweepRecording(k, SWEEPER);
        uint256 pulledOut = poolPairBeforeSweep - pair.balanceOf(address(manager));

        emit log_named_uint("pair that landed in the pool    ", landedInPool);
        emit log_named_uint("pair the next sweep pulled out  ", pulledOut);
        emit log_named_uint("recovered, bps of the buy       ", (pulledOut * 10_000) / landedInPool);

        assertGt(
            (pulledOut * 10_000) / landedInPool,
            9_000,
            "the sweep recovered less of the new buying than expected"
        );
        assertTrue(afterBuy != pinned, "sanity: the buy did move the price");
        assertEq(_spot(id), pinned, "the sweep put spot straight back on the pin");
    }

    // ------------------------------------------------------------------------------------------
    // R2H-16  A carry on one pool cannot reach another pool's claims.
    // ------------------------------------------------------------------------------------------

    /// @dev The PoolManager is a singleton, so the hook's ERC-6909 balance in the launch token is
    ///      shared by every pool that charges a sell tax in it. The invariant that matters is that
    ///      the balance equals the SUM of the per-pool ledgers - never more (unredeemable) and
    ///      never less (one sweep would spend another pool's claims). Round 1 verified that for
    ///      ordinary sweeps; the carry writes back into that same shared balance, so it is checked
    ///      again here through a deferral.
    function test_R2H_16_aCarryOnOnePoolNeverTouchesAnothersClaims() public {
        PoolKey memory a = _ssPool(300, 1000, 0, 0);
        PoolId idA = a.toId();

        // A second pool on the SAME launch token and the SAME pair currency.
        PoolKey memory b = PoolKey({
            currency0: a.currency0,
            currency1: a.currency1,
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
        hook.configurePoolFull(
            b,
            FeeHook.FeeSetup({
                distributor: address(dist),
                pairCurrency: Currency.wrap(address(pair)),
                feeBps: 300,
                sellFeeBps: 500,
                burnBps: 0,
                creator: creator,
                creatorBps: 2000,
                rewardCurrency: Currency.wrap(address(0))
            , openingWindow: 0, openingFeeBps: 0})
        );
        manager.initialize(b, TickMath.getSqrtPriceAtTick(0));
        (int24 lo, int24 hi) = _tokenIsCurrency0()
            ? (int24(0), TickMath.maxUsableTick(200))
            : (TickMath.minUsableTick(200), int24(0));
        lpRouter.modifyLiquidity(
            b,
            ModifyLiquidityParams({
                tickLower: lo,
                tickUpper: hi,
                liquidityDelta: 1_000_000e18,
                salt: bytes32(0)
            }),
            ""
        );

        // Pool B accrues a small pile its own reserve can absorb.
        _buyExactIn(b, bob, 100e18);
        vm.prank(bob);
        token.approve(address(swapRouter), type(uint256).max);
        _sellExactIn(b, bob, token.balanceOf(bob) / 4);
        uint256 pileB = hook.pendingTokenFees(b.toId());
        assertGt(pileB, 0, "precondition: pool B has a pile");

        // Pool A is driven into a carry.
        _pileUpASellTax(a, 2_000_000e18);
        assertEq(
            _tokenClaims(),
            hook.pendingTokenFees(idA) + pileB,
            "precondition: the shared claim balance is the sum of the two ledgers"
        );

        uint256 deferred = _sweepRecording(a, SWEEPER);
        assertGt(deferred, 0, "precondition: pool A really carried");

        assertEq(hook.pendingTokenFees(b.toId()), pileB, "POOL B'S LEDGER WAS TOUCHED");
        assertEq(
            _tokenClaims(),
            hook.pendingTokenFees(idA) + pileB,
            "the shared claim balance stopped matching the sum of the ledgers"
        );

        // ...and B can still sweep normally afterwards, converting essentially all of its own
        // pile without touching A's carry.
        uint256 carriedA = hook.pendingTokenFees(idA);
        _sweepRecording(b, SWEEPER);
        assertLt(hook.pendingTokenFees(b.toId()), pileB / 100, "pool B could no longer sweep");
        assertEq(hook.pendingTokenFees(idA), carriedA, "sweeping B disturbed A's carry");
        assertEq(
            _tokenClaims(),
            carriedA + hook.pendingTokenFees(b.toId()),
            "the shared claim balance stopped matching the sum of the ledgers"
        );
    }
}

contract HookAudit2DeferralToken0Test is HookAudit2Deferral {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract HookAudit2DeferralToken1Test is HookAudit2Deferral {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
