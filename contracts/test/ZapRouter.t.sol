// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {ZapRouter} from "../src/ZapRouter.sol";
import {TradeRouter} from "../src/TradeRouter.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {FeeHookHarness} from "./FeeHook.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice A real WETH9: an ERC-20 that also wraps and unwraps native ether.
/// @dev Storage layout is IDENTICAL to `MockERC20` — it adds no state, only two functions. That is
///      what lets `ZapWrapHarness` swap it in over an existing pair's code without disturbing a
///      single balance.
contract MockWETH9 is MockERC20 {
    constructor(string memory n, string memory s, uint8 d) MockERC20(n, s, d) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "weth: ether transfer failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @notice ETH in, launch token out. The pair currency never reaches the buyer.
///
/// @dev **What these tests are actually for.** A zap that "works" is easy: two swaps in an unlock
///      that leaves no delta behind. The three things that are hard, and that this file is built
///      around, are all silent failures:
///
///      1. **The settlement order.** Audit 04 measured a `sync -> transfer -> swap -> settle`
///         router being overcharged **8.5x** by our own hook on an identical trade, because
///         `FeeHook` moves ERC-20 out of the singleton during `afterSwap` and `PoolManager._settle`
///         credits `balanceOfSelf() - syncedReserves`. That is an OVERCHARGE, not a revert. Every
///         "did it succeed" test passes straight through it. `test_costsTheSameAsTwoHopsByHand` is
///         the guard, and it is a comparison against an independently priced route rather than an
///         absolute number, because the absolute number is exactly what an overcharge changes.
///      2. **The fee.** A zap that quietly bypasses the hook still delivers tokens and still
///         balances, and the product's entire economics disappear. So the fee assertion is an
///         EQUALITY against a separately derived quantity — the pair that hop 1 produced, measured
///         by running hop 1 alone from the same snapshot — not `assertGt(fee, 0)`, which passes on
///         any wrong number as long as it is not zero.
///      3. **The intermediate leg.** The pair delta from hop 1 does not automatically cancel hop
///         2's. `test_aTruncatedLegIsRefusedRatherThanPaidOutInThePair` builds the case where it
///         does not.
///
///      Everything runs in BOTH currency orderings, because which side the launch token sorts onto
///      flips the sign of every delta and the direction of both hops.
abstract contract ZapBase is FeeHookHarness {
    ZapRouter internal zap;
    /// Used only as the second half of the hand-rolled control route.
    TradeRouter internal tradeRouter;

    /// ETH / pair. Native ether is `address(0)`, so it sorts to `currency0` unconditionally.
    PoolKey internal ethKey;

    /// A normal v4 fee tier. Nothing about hop 1 is ours — it is somebody else's pool.
    uint24 internal constant ETH_POOL_FEE = 3000;

    /// Far enough out that no test is measuring the deadline unless it means to.
    uint256 internal constant DEADLINE = type(uint256).max;

    /// @dev Refunds arrive here from `PoolSwapTest`/`PoolModifyLiquidityTest`, which hand back any
    ///      native ether they did not spend.
    receive() external payable {}

    function setUp() public virtual override {
        super.setUp();

        zap = new ZapRouter(IPoolManager(address(manager)), address(0));
        tradeRouter = new TradeRouter(IPoolManager(address(manager)));

        ethKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(pair)),
            fee: ETH_POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(ethKey, TickMath.getSqrtPriceAtTick(0));
        _seedEthPool();

        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);

        vm.startPrank(alice);
        token.approve(address(zap), type(uint256).max);
        pair.approve(address(tradeRouter), type(uint256).max);
        token.approve(address(tradeRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Full range at 1:1. **The price here is a number this test invented** — there is no
    ///      market that says one pair unit is one ether. That is fine for proving the ROUTING, and
    ///      it is not evidence about anybody's economics.
    function _seedEthPool() internal virtual {
        pair.mint(address(this), 10_000e18);
        pair.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 50_000 ether);

        lpRouter.modifyLiquidity{value: 5_000 ether}(
            ethKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 2_000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    // ===============================================================================================
    // Helpers
    // ===============================================================================================

    /// @dev Hop 1 on its own, through Uniswap's own settle-after router. Used to derive the
    ///      intermediate amount independently of the contract under test.
    function _hopOneAlone(address who, uint256 ethIn) internal returns (uint256 pairOut) {
        vm.prank(who);
        BalanceDelta d = swapRouter.swap{value: ethIn}(
            ethKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        pairOut = uint256(uint128(d.amount1()));
    }

    /// @dev A pool key on the same two currencies as `key`, so it has a different PoolId and can be
    ///      opened at a price of our choosing. Configured on the hook exactly as a launch would be.
    function _pinnedLaunchKey() internal returns (PoolKey memory k) {
        k = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: 0,
            tickSpacing: 10, // different spacing => different PoolId
            hooks: key.hooks
        });
        hook.configurePoolFull(
            k,
            FeeHook.FeeSetup({
                distributor: address(dist),
                pairCurrency: Currency.wrap(address(pair)),
                feeBps: FEE_BPS,
                sellFeeBps: 0,
                burnBps: 0,
                creator: creator,
                creatorBps: CREATOR_BPS,
                rewardCurrency: Currency.wrap(address(0))
            })
        );
        // Opened hard against the limit in the direction a SELL would push it, which is the state a
        // freshly launched single-sided pool is in before anybody has bought from it.
        manager.initialize(k, _tokenIsCurrency0() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _ethPoolAt(uint160 sqrtPriceX96, uint24 fee) internal returns (PoolKey memory k) {
        k = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(pair)),
            fee: fee,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(k, sqrtPriceX96);
    }

    /// @dev Buy through the zap so there is something to sell. Returns the tokens received.
    function _zapBuy(address who, uint256 ethIn) internal returns (uint256) {
        vm.prank(who);
        return zap.zapBuy{value: ethIn}(ethKey, key, 1, who, DEADLINE);
    }

    /// @dev Strips the 4-byte selector so a custom error's arguments can be decoded.
    function _body(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i = 4; i < err.length; ++i) {
            out[i - 4] = err[i];
        }
    }
}

/// @notice The deep-pool suite. Hop 1 has enough depth that nothing is ever cut short, which is
///         the state every assertion below assumes.
abstract contract ZapRouterHarness is ZapBase {
    // ===============================================================================================
    // The product claim: ETH in, ETH out, the pair currency never appears
    // ===============================================================================================

    function test_aBuyIsPaidInEtherAndNeverTouchesThePair() public {
        uint256 ethBefore = alice.balance;
        uint256 pairBefore = pair.balanceOf(alice);
        uint256 tokenBefore = token.balanceOf(alice);

        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 10 ether}(ethKey, key, 1, alice, DEADLINE);

        assertGt(out, 0, "the zap returned nothing");
        assertEq(token.balanceOf(alice) - tokenBefore, out, "the reported output is not what arrived");
        assertEq(ethBefore - alice.balance, 10 ether, "the buyer paid something other than msg.value");
        assertEq(pair.balanceOf(alice), pairBefore, "the buyer's pair balance moved");
    }

    function test_aSellIsPaidOutInEtherAndNeverTouchesThePair() public {
        uint256 held = _zapBuy(alice, 20 ether);
        assertGt(held, 0, "precondition: alice holds tokens to sell");

        uint256 ethBefore = alice.balance;
        uint256 pairBefore = pair.balanceOf(alice);

        vm.prank(alice);
        uint256 out = zap.zapSell(ethKey, key, held / 2, 1, alice, DEADLINE);

        assertGt(out, 0, "the sell returned nothing");
        assertEq(alice.balance - ethBefore, out, "the reported output is not what arrived");
        assertEq(pair.balanceOf(alice), pairBefore, "the seller's pair balance moved");
        assertEq(token.balanceOf(alice), held - held / 2, "the wrong number of tokens left the wallet");
    }

    /// A buyer who never held the pair currency is the entire point. Bob is funded with ether only.
    function test_aWalletHoldingNoPairCurrencyAtAllCanStillBuy() public {
        // Read the balance BEFORE the prank: an argument expression is itself a call, and it would
        // consume the prank so the transfer would come from the test contract instead.
        uint256 bobsPair = pair.balanceOf(bob);
        vm.prank(bob);
        pair.transfer(address(0xdead), bobsPair);
        assertEq(pair.balanceOf(bob), 0, "precondition: bob holds no pair currency");

        vm.prank(bob);
        uint256 out = zap.zapBuy{value: 5 ether}(ethKey, key, 1, bob, DEADLINE);

        assertGt(out, 0, "a pairless wallet could not buy");
        assertEq(pair.balanceOf(bob), 0, "bob ended up holding the pair currency");
    }

    // ===============================================================================================
    // THE 8.5x GUARD
    // ===============================================================================================

    /// **The regression guard for the settlement order.**
    ///
    /// The zap must price identically to doing the two hops by hand: Uniswap's own `PoolSwapTest`
    /// for hop 1, then `TradeRouter` for hop 2. Both of those settle AFTER swapping. If somebody
    /// refactors `ZapRouter` to pay up front — the natural shape when a function is `payable` and
    /// the ether is already sitting there — this diverges by multiples rather than reverting.
    function test_costsTheSameAsTwoHopsByHand() public {
        uint256 spend = 25 ether;
        uint256 snap = vm.snapshotState();

        vm.prank(alice);
        uint256 viaZap = zap.zapBuy{value: spend}(ethKey, key, 1, alice, DEADLINE);

        vm.revertToState(snap);

        uint256 pairOut = _hopOneAlone(alice, spend);
        vm.prank(alice);
        uint256 viaHand = tradeRouter.swap(key, _buyIsZeroForOne(), pairOut, 0, alice);

        assertApproxEqRel(viaZap, viaHand, 1e15, "the zap does not price like the two hops it replaces");
    }

    /// The sell direction has its own settlement path — an ERC-20 debt and a native credit, which
    /// is the mirror image of the buy — so it gets its own parity check.
    function test_theSellCostsTheSameAsTwoHopsByHand() public {
        uint256 held = _zapBuy(alice, 30 ether);
        uint256 sell = held / 3;
        uint256 snap = vm.snapshotState();

        vm.prank(alice);
        uint256 viaZap = zap.zapSell(ethKey, key, sell, 1, alice, DEADLINE);

        vm.revertToState(snap);

        vm.prank(alice);
        uint256 pairBack = tradeRouter.swap(key, !_buyIsZeroForOne(), sell, 0, alice);
        vm.prank(alice);
        pair.approve(address(swapRouter), type(uint256).max);
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        swapRouter.swap(
            ethKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(pairBack),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 viaHand = alice.balance - ethBefore;

        assertApproxEqRel(viaZap, viaHand, 1e15, "the zap does not price like the two hops it replaces");
    }

    // ===============================================================================================
    // THE FEE NEGATIVE CONTROL
    // ===============================================================================================

    /// **A zap that charges nothing must FAIL this test, not pass it.**
    ///
    /// So the assertion is an equality against a quantity derived without the zap: hop 1 run alone
    /// from the same snapshot tells us exactly how much pair currency reaches the launch pool, and
    /// the hook's advertised rate says exactly what it must charge on that. `assertGt(fee, 0)`
    /// would be satisfied by a fee charged on the wrong base, on the wrong leg, or at the wrong
    /// rate — all of which are the realistic ways this breaks.
    function test_theFeeIsChargedOnEveryUnitThatReachesTheLaunchPool() public {
        uint256 spend = 10 ether;

        uint256 snap = vm.snapshotState();
        uint256 pairIntoTheLaunchPool = _hopOneAlone(alice, spend);
        vm.revertToState(snap);

        uint256 feeBefore = hook.totalFeesTaken(poolId);
        vm.prank(alice);
        zap.zapBuy{value: spend}(ethKey, key, 1, alice, DEADLINE);
        uint256 charged = hook.totalFeesTaken(poolId) - feeBefore;

        assertGt(pairIntoTheLaunchPool, 0, "hop 1 produced nothing, so this proves nothing");
        assertEq(
            charged,
            (pairIntoTheLaunchPool * FEE_BPS) / 10_000,
            "the fee is not the advertised rate on the amount that actually reached the pool"
        );
    }

    /// **The negative control for the test above.**
    ///
    /// The same two currencies, a second pool, no `FeeHook` on it. The zap routes through it
    /// perfectly happily: ether goes in, launch tokens come out, every delta closes, the router
    /// keeps nothing. And the fee counter does not move by a single unit. That is the point — a
    /// build that charged nothing would pass every "did it succeed" assertion in this file, which
    /// is why the fee test is an equality against an independently derived amount and why this
    /// case is written down rather than assumed impossible.
    function test_negativeControl_aRouteWithNoHookOnItChargesNothingAndStillSucceeds() public {
        PoolKey memory unhooked = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: ETH_POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(unhooked, TickMath.getSqrtPriceAtTick(0));
        lpRouter.modifyLiquidity(
            unhooked,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 1_000_000e18,
                salt: bytes32(0)
            }),
            ""
        );

        uint256 feesEverywhereBefore = hook.totalFeesTaken(poolId) + hook.totalFeesTaken(unhooked.toId());

        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 10 ether}(ethKey, unhooked, 1, alice, DEADLINE);

        assertGt(out, 0, "the unhooked route did not even deliver tokens");
        assertEq(
            hook.totalFeesTaken(poolId) + hook.totalFeesTaken(unhooked.toId()),
            feesEverywhereBefore,
            "the control charged a fee, so it is not a control"
        );
        assertEq(address(zap).balance, 0, "the router kept ether on the unhooked route");
    }

    /// The claim the whole product rests on, stated about the zap rather than about a swap: money
    /// charged as a fee has to end up somewhere holders can be paid out of.
    function test_theFeeReachesTheDistributor() public {
        uint256 before = pair.balanceOf(address(dist));

        vm.prank(alice);
        zap.zapBuy{value: 40 ether}(ethKey, key, 1, alice, DEADLINE);
        // Fees accrue as ERC-6909 claims inside the swap and become real ERC-20 on the sweep. That
        // is a property of single-sided seeding, not of the zap.
        hook.sweep(key);

        assertGt(
            pair.balanceOf(address(dist)) - before,
            0,
            "a zapped buy paid the pool but not the people the pool exists to pay"
        );
    }

    // ===============================================================================================
    // Slippage
    // ===============================================================================================

    function test_aBuyWithNoFloorIsRejected() public {
        vm.prank(alice);
        vm.expectRevert(ZapRouter.NoSlippageFloor.selector);
        zap.zapBuy{value: 1 ether}(ethKey, key, 0, alice, DEADLINE);
    }

    function test_aSellWithNoFloorIsRejected() public {
        uint256 held = _zapBuy(alice, 5 ether);
        vm.prank(alice);
        vm.expectRevert(ZapRouter.NoSlippageFloor.selector);
        zap.zapSell(ethKey, key, held / 2, 0, alice, DEADLINE);
    }

    /// Slippage protection has to bind, or it is decoration.
    function test_theFloorBinds() public {
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 fair = zap.zapBuy{value: 1 ether}(ethKey, key, 1, alice, DEADLINE);
        vm.revertToState(snap);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ZapRouter.TooLittleReceived.selector, fair, fair * 2));
        zap.zapBuy{value: 1 ether}(ethKey, key, fair * 2, alice, DEADLINE);
    }

    // ===============================================================================================
    // Quoting
    // ===============================================================================================

    /// The quote entry points always revert, which is what makes it impossible to use them to
    /// execute a floorless swap — and what lets a wallet with nothing in it get a price.
    function test_aQuoteNeedsNeitherBalanceNorApproval() public {
        address broke = address(0xB0BB1E);
        assertEq(broke.balance, 0, "precondition: no ether");
        assertEq(pair.balanceOf(broke), 0, "precondition: no pair currency");

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 actual = zap.zapBuy{value: 3 ether}(ethKey, key, 1, alice, DEADLINE);
        vm.revertToState(snap);

        vm.prank(broke);
        try zap.quoteZapBuy(ethKey, key, 3 ether) {
            revert("quoteZapBuy returned instead of reverting");
        } catch (bytes memory err) {
            assertEq(bytes4(err), ZapRouter.ZapQuote.selector, "wrong revert from the quote");
            uint256 quoted = abi.decode(_body(err), (uint256));
            assertEq(quoted, actual, "the quote is not what the zap delivers");
        }
    }

    function test_aSellQuoteMatchesWhatTheSellDelivers() public {
        uint256 held = _zapBuy(alice, 12 ether);
        uint256 sell = held / 4;

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 actual = zap.zapSell(ethKey, key, sell, 1, alice, DEADLINE);
        vm.revertToState(snap);

        vm.prank(alice);
        try zap.quoteZapSell(ethKey, key, sell) {
            revert("quoteZapSell returned instead of reverting");
        } catch (bytes memory err) {
            assertEq(bytes4(err), ZapRouter.ZapQuote.selector, "wrong revert from the quote");
            assertEq(abi.decode(_body(err), (uint256)), actual, "the quote is not what the zap delivers");
        }
    }

    // ===============================================================================================
    // The pin — a v4 property that reads like a honeypot unless it is named
    // ===============================================================================================

    /// A freshly launched pool sits at its opening tick with nothing below it, so `Pool.swap`
    /// refuses every sell in that direction with a bare `PriceLimitAlreadyExceeded`. A trader who
    /// meets that without explanation concludes the token cannot be sold.
    function test_aPinnedLaunchPoolIsNamedRatherThanRevertingRaw() public {
        PoolKey memory pinned = _pinnedLaunchKey();
        uint256 held = _zapBuy(alice, 5 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ZapRouter.PoolIsPinnedAtItsPriceLimit.selector, _tokenIsCurrency0())
        );
        zap.zapSell(ethKey, pinned, held / 2, 1, alice, DEADLINE);
    }

    /// The same guard on the other leg: an ETH pool sitting on its ceiling cannot absorb a sell.
    function test_aPinnedEthPoolIsNamedRatherThanRevertingRaw() public {
        PoolKey memory pinnedEth = _ethPoolAt(TickMath.MAX_SQRT_PRICE - 1, 500);
        uint256 held = _zapBuy(alice, 5 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ZapRouter.PoolIsPinnedAtItsPriceLimit.selector, false));
        zap.zapSell(pinnedEth, key, held / 2, 1, alice, DEADLINE);
    }

    function test_aPinnedEthPoolCannotBeBoughtThroughEither() public {
        PoolKey memory pinnedEth = _ethPoolAt(TickMath.MIN_SQRT_PRICE + 1, 500);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ZapRouter.PoolIsPinnedAtItsPriceLimit.selector, true));
        zap.zapBuy{value: 1 ether}(pinnedEth, key, 1, alice, DEADLINE);
    }

    // ===============================================================================================
    // Shape of the call
    // ===============================================================================================

    function test_zeroAmountIsRejected() public {
        vm.prank(alice);
        vm.expectRevert(ZapRouter.ZeroAmount.selector);
        zap.zapBuy{value: 0}(ethKey, key, 1, alice, DEADLINE);

        vm.prank(alice);
        vm.expectRevert(ZapRouter.ZeroAmount.selector);
        zap.zapSell(ethKey, key, 0, 1, alice, DEADLINE);
    }

    function test_onlyThePoolManagerMayDriveTheCallback() public {
        vm.prank(alice);
        vm.expectRevert(ZapRouter.NotPoolManager.selector);
        zap.unlockCallback("");
    }

    // ===============================================================================================
    // The deadline — a price floor is not a time bound
    // ===============================================================================================

    /// `minAmountOut` stops a bad price. It does NOT stop a transaction sitting unmined for hours
    /// and then landing into a market the quote no longer describes.
    function test_anExpiredDeadlineIsRejectedOnABuy() public {
        uint256 past = vm.getBlockTimestamp() - 1;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ZapRouter.Expired.selector, past, vm.getBlockTimestamp())
        );
        zap.zapBuy{value: 1 ether}(ethKey, key, 1, alice, past);
    }

    function test_anExpiredDeadlineIsRejectedOnASell() public {
        uint256 held = _zapBuy(alice, 5 ether);
        uint256 past = vm.getBlockTimestamp() - 1;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ZapRouter.Expired.selector, past, vm.getBlockTimestamp())
        );
        zap.zapSell(ethKey, key, held / 2, 1, alice, past);
    }

    /// The boundary is `>`, not `>=` — a deadline of exactly now is still valid, which is what a
    /// caller who sets `deadline = block.timestamp` in the same block expects.
    function test_aDeadlineOfExactlyNowStillExecutes() public {
        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 1 ether}(ethKey, key, 1, alice, vm.getBlockTimestamp());
        assertGt(out, 0, "a deadline equal to the current timestamp was rejected");
    }

    /// The guard has to bind on TIME PASSING, not just on a number in the past at call time.
    function test_aDeadlineThatPassesWhileWaitingIsRejected() public {
        uint256 deadline = vm.getBlockTimestamp() + 300;
        skip(301);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ZapRouter.Expired.selector, deadline, vm.getBlockTimestamp())
        );
        zap.zapBuy{value: 1 ether}(ethKey, key, 1, alice, deadline);
    }

    /// Nothing may send this router ether except a caller's `msg.value` and `WETH.withdraw`.
    /// Otherwise the refund sweep could be pointed at somebody else's money.
    function test_strayEtherIsRefused() public {
        vm.deal(address(0xBEEF), 1 ether);
        vm.prank(address(0xBEEF));
        (bool ok,) = address(zap).call{value: 1 ether}("");
        assertFalse(ok, "the router accepted ether from a stranger");
        assertEq(address(zap).balance, 0, "the router is holding ether it should have refused");
    }

    /// The first key has to be an ETH pool. If it is not, the router would be quietly zapping
    /// through some other asset while the caller believes they are spending ether.
    function test_anEthKeyThatIsNotNativeIsRejected() public {
        PoolKey memory notEth = key; // the launch pool, which contains no native ether
        vm.prank(alice);
        vm.expectRevert(ZapRouter.EthLegIsNotNative.selector);
        zap.zapBuy{value: 1 ether}(notEth, key, 1, alice, DEADLINE);
    }

    /// The two keys have to share the pair currency, or there is no route between them.
    function test_aLaunchKeyThatDoesNotContainThePairIsRejected() public {
        PoolKey memory unrelated = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: ETH_POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        vm.prank(alice);
        vm.expectRevert(ZapRouter.PairIsNotInTheLaunchPool.selector);
        zap.zapBuy{value: 1 ether}(ethKey, unrelated, 1, alice, DEADLINE);
    }

    function test_outputCanGoToSomebodyElse() public {
        uint256 before = token.balanceOf(bob);
        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 4 ether}(ethKey, key, 1, bob, DEADLINE);
        assertEq(token.balanceOf(bob) - before, out, "the recipient did not receive the output");
    }

    // ===============================================================================================
    // The router is a conduit
    // ===============================================================================================

    function test_theRouterRetainsNothing() public {
        _zapBuy(alice, 15 ether);
        uint256 held = token.balanceOf(alice);
        vm.prank(alice);
        zap.zapSell(ethKey, key, held / 2, 1, alice, DEADLINE);

        assertEq(address(zap).balance, 0, "the router kept ether");
        assertEq(pair.balanceOf(address(zap)), 0, "the router kept pair currency");
        assertEq(token.balanceOf(address(zap)), 0, "the router kept launch tokens");
    }

    /// Every delta has to be closed or `unlock` reverts, so a run of trades in both directions
    /// must simply work.
    function test_manyZapsInSequenceAllSettle() public {
        for (uint256 i = 0; i < 6; i++) {
            _zapBuy(alice, 3 ether);
        }
        uint256 held = token.balanceOf(alice);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            zap.zapSell(ethKey, key, held / 10, 1, alice, DEADLINE);
        }
        assertEq(address(zap).balance, 0, "the router kept ether");
        assertEq(pair.balanceOf(address(zap)), 0, "the router kept pair currency");
        assertEq(token.balanceOf(address(zap)), 0, "the router kept launch tokens");
    }
}

contract ZapRouterTokenIsCurrency0Test is ZapRouterHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract ZapRouterTokenIsCurrency1Test is ZapRouterHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

// ===================================================================================================
// A hop-1 pool thin enough that price impact is real, and thin enough to run out
// ===================================================================================================

/// @notice The same router against an ETH/pair pool with a NARROW liquidity band.
///
/// @dev The deep pool above hides two behaviours worth pinning. First, price impact: with real
///      depth every buy prices almost linearly and a wrong intermediate amount would not show.
///      Second, and more importantly, a hop that RUNS OUT of liquidity is the case where the pair
///      currency stops cancelling between the legs — and this is the only shape in the suite that
///      can produce it.
///
///      Band is +/-600 ticks (about +/-6%) on `L = 2000e18`, so each side of the position holds
///      roughly 59 units. That makes a 10-unit trade a sixth of the book — real impact — while a
///      200-unit trade runs it dry, which is what the truncation cases need.
abstract contract ZapThinEthPoolHarness is ZapBase {
    int24 internal constant BAND = 600;

    function _seedEthPool() internal override {
        pair.mint(address(this), 10_000e18);
        pair.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 50_000 ether);

        lpRouter.modifyLiquidity{value: 5_000 ether}(
            ethKey,
            ModifyLiquidityParams({
                tickLower: -BAND,
                tickUpper: BAND,
                liquidityDelta: 2_000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// Price impact has to be REAL, not a rounding artefact: the marginal price a big order gets
    /// must be materially worse than the price a small one gets, measured from the SAME state.
    ///
    /// @dev The tempting version of this test — "ten small buys beat one big buy" — is wrong, and
    ///      it was written that way first. A constant-function AMM is path independent, so ten
    ///      sequential 1-ether swaps return the same total as one 10-ether swap to within a few wei
    ///      (measured: a five-wei difference, in favour of the single trade). Splitting an order
    ///      only helps against a fee charged per swap or a discretely priced book. What impact
    ///      actually means here is that the AVERAGE price degrades with size.
    function test_priceImpactOnAThinHopIsReal() public {
        uint256 snap = vm.snapshotState();
        uint256 small = _zapBuy(alice, 1 ether);
        vm.revertToState(snap);

        uint256 big = _zapBuy(alice, 40 ether);

        uint256 perEtherSmall = small;
        uint256 perEtherBig = big / 40;

        assertLt(perEtherBig, perEtherSmall, "a 40x order got the same price as a 1x order");
        assertLt(
            perEtherBig,
            (perEtherSmall * 99) / 100,
            "the price impact on a deliberately thin pool is under 1%, so this pool is not thin"
        );
    }

    /// A hop 1 that cannot absorb the whole order spends what it can and the rest comes home in the
    /// same transaction. The router has no rescue function, so anything it keeps is stranded.
    function test_aBuyBiggerThanHopOneRefundsTheUnspentEther() public {
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 200 ether}(ethKey, key, 1, alice, DEADLINE);

        uint256 spent = ethBefore - alice.balance;
        assertGt(out, 0, "the truncated buy delivered nothing");
        assertLt(spent, 200 ether, "the pool absorbed the whole order, so nothing was truncated here");
        assertEq(address(zap).balance, 0, "the router kept the unspent ether");
    }

    /// **The intermediate leg does not simply net, and this is the proof.**
    ///
    /// Alice takes a position using her OWN pair currency, straight through `TradeRouter`, so the
    /// ETH pool is untouched and still sitting mid-band. Selling that whole position produces more
    /// pair than the band can absorb, hop 1 fills partially, and the router is left holding a
    /// positive pair delta. Handing that to the seller would mean delivering the exact asset the
    /// zap exists to hide, so it is refused by name and the size is theirs to reduce.
    function test_aTruncatedLegIsRefusedRatherThanPaidOutInThePair() public {
        vm.prank(alice);
        tradeRouter.swap(key, _buyIsZeroForOne(), 300e18, 0, alice);
        uint256 held = token.balanceOf(alice);
        assertGt(held, 0, "precondition: alice holds tokens to dump");

        vm.prank(alice);
        try zap.zapSell(ethKey, key, held, 1, alice, DEADLINE) returns (uint256) {
            revert("a dump that exhausts hop 1 was allowed to settle");
        } catch (bytes memory err) {
            assertEq(
                bytes4(err),
                ZapRouter.IntermediateLegDidNotNet.selector,
                "an exhausted hop 1 was not reported as a failure to net"
            );
            assertGt(
                abi.decode(_body(err), (int256)),
                0,
                "the residual should be pair currency the router could not spend"
            );
        }
    }

    /// The guard has to be a CEILING, not a blanket refusal: a sell small enough for the band to
    /// absorb still has to work.
    function test_aSellTheBandCanAbsorbStillGoesThrough() public {
        vm.prank(alice);
        tradeRouter.swap(key, _buyIsZeroForOne(), 300e18, 0, alice);
        uint256 held = token.balanceOf(alice);

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        uint256 out = zap.zapSell(ethKey, key, held / 20, 1, alice, DEADLINE);

        assertGt(out, 0, "a sell the band can absorb returned nothing");
        assertEq(alice.balance - ethBefore, out, "the reported output is not what arrived");
    }
}

contract ZapThinEthPoolTokenIsCurrency0Test is ZapThinEthPoolHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract ZapThinEthPoolTokenIsCurrency1Test is ZapThinEthPoolHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

// ===================================================================================================
// The pair IS wrapped ether, so hop 1 is a wrap and not a swap
// ===================================================================================================

/// @notice WETH is `DEFAULT_PAIR`, which makes this the most common launch on mainnet.
///
/// @dev Routing `ETH -> WETH` through a pool is legal and it works — there is a live v4 ETH/WETH
///      pool with real liquidity, measured at 6.3 bps all-in. But `WETH.deposit()` does the same
///      thing for free, at exactly 1:1, with no pool and no price impact. Paying a fee to a market
///      maker to perform an identity function is not a trade, it is a leak.
///
///      Swapping the pair's CODE rather than rebuilding the world: `MockWETH9` adds no storage over
///      `MockERC20`, so `deployCodeTo` gives the existing pair real `deposit`/`withdraw` while every
///      balance, allowance and the launch token's `payoutToken` wiring survive untouched.
abstract contract ZapWrapHarness is ZapBase {
    /// The un-wrapped router, kept for the side-by-side price comparison.
    ZapRouter internal poolRouter;

    function setUp() public virtual override {
        super.setUp();

        // `poolRouter` is the shipped behaviour: `weth == address(0)`, hop 1 goes through a pool.
        poolRouter = zap;

        deployCodeTo(
            "ZapRouter.t.sol:MockWETH9",
            abi.encode("Wrapped Ether", "WETH", uint8(18)),
            address(pair)
        );
        // The harness minted this "WETH" without ever depositing ether, so back it now or
        // `withdraw` has nothing to pay out. A test artefact, not a property of WETH9.
        vm.deal(address(pair), 1_000_000 ether);

        zap = new ZapRouter(IPoolManager(address(manager)), address(pair));
        vm.startPrank(alice);
        token.approve(address(zap), type(uint256).max);
        vm.stopPrank();
    }

    function test_wrap_aBuyNeverTouchesTheEthPool() public {
        (uint160 priceBefore,,,) = _ethPoolPrice();

        uint256 tokenBefore = token.balanceOf(alice);
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 10 ether}(ethKey, key, 1, alice, DEADLINE);

        (uint160 priceAfter,,,) = _ethPoolPrice();

        assertGt(out, 0, "the wrapped buy delivered nothing");
        assertEq(token.balanceOf(alice) - tokenBefore, out, "the reported output is not what arrived");
        assertEq(ethBefore - alice.balance, 10 ether, "the buyer paid something other than msg.value");
        assertEq(priceAfter, priceBefore, "hop 1 went through the pool instead of wrapping");
    }

    function test_wrap_aSellReturnsEther() public {
        vm.prank(alice);
        uint256 held = zap.zapBuy{value: 20 ether}(ethKey, key, 1, alice, DEADLINE);
        assertGt(held, 0, "precondition: alice holds tokens to sell");

        (uint160 priceBefore,,,) = _ethPoolPrice();
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        uint256 out = zap.zapSell(ethKey, key, held / 2, 1, alice, DEADLINE);

        (uint160 priceAfter,,,) = _ethPoolPrice();

        assertGt(out, 0, "the wrapped sell returned nothing");
        assertEq(alice.balance - ethBefore, out, "the seller did not receive the reported ether");
        assertEq(priceAfter, priceBefore, "hop 1 went through the pool instead of unwrapping");
    }

    /// **The reason the shortcut exists, measured.** Same trade, same state, one router wrapping
    /// and one routing through the ETH/WETH pool. Wrapping must deliver strictly more, because the
    /// pool charges a fee and moves a price to do what `deposit()` does for nothing.
    function test_wrap_deliversStrictlyMoreThanRoutingThroughThePool() public {
        uint256 spend = 25 ether;
        uint256 snap = vm.snapshotState();

        vm.prank(alice);
        uint256 viaPool = poolRouter.zapBuy{value: spend}(ethKey, key, 1, alice, DEADLINE);

        vm.revertToState(snap);

        vm.prank(alice);
        uint256 viaWrap = zap.zapBuy{value: spend}(ethKey, key, 1, alice, DEADLINE);

        assertGt(viaWrap, viaPool, "wrapping did not beat paying an LP to perform an identity");
        emit log_named_uint("tokens via the ETH/WETH pool", viaPool);
        emit log_named_uint("tokens via a plain wrap     ", viaWrap);
        emit log_named_uint("bps saved by wrapping       ", ((viaWrap - viaPool) * 10_000) / viaPool);
    }

    function test_wrap_theRouterRetainsNothing() public {
        vm.prank(alice);
        uint256 held = zap.zapBuy{value: 15 ether}(ethKey, key, 1, alice, DEADLINE);
        vm.prank(alice);
        zap.zapSell(ethKey, key, held / 2, 1, alice, DEADLINE);

        assertEq(address(zap).balance, 0, "the router kept ether");
        assertEq(pair.balanceOf(address(zap)), 0, "the router kept wrapped ether");
        assertEq(token.balanceOf(address(zap)), 0, "the router kept launch tokens");
    }

    /// The wrap path must still honour the floor and the deadline — it is a different hop 1, not a
    /// different set of guarantees.
    function test_wrap_stillHonoursTheFloorAndTheDeadline() public {
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 fair = zap.zapBuy{value: 1 ether}(ethKey, key, 1, alice, DEADLINE);
        vm.revertToState(snap);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ZapRouter.TooLittleReceived.selector, fair, fair * 2));
        zap.zapBuy{value: 1 ether}(ethKey, key, fair * 2, alice, DEADLINE);

        uint256 past = vm.getBlockTimestamp() - 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ZapRouter.Expired.selector, past, vm.getBlockTimestamp()));
        zap.zapBuy{value: 1 ether}(ethKey, key, 1, alice, past);
    }

    /// The fee is charged on the wrap path exactly as it is on the pool path — the shortcut changes
    /// hop 1, and the hook lives on hop 2.
    function test_wrap_theFeeStillReachesTheDistributor() public {
        uint256 before = pair.balanceOf(address(dist));
        uint256 feesBefore = hook.totalFeesTaken(poolId);

        vm.prank(alice);
        zap.zapBuy{value: 40 ether}(ethKey, key, 1, alice, DEADLINE);

        // A wrap is 1:1, so the amount reaching the launch pool is exactly what was sent.
        uint256 wrapped = 40 ether;
        assertEq(
            hook.totalFeesTaken(poolId) - feesBefore,
            (wrapped * FEE_BPS) / 10_000,
            "the fee is not the advertised rate on the wrapped amount"
        );

        hook.sweep(key);
        assertGt(pair.balanceOf(address(dist)) - before, 0, "holders were not paid on a wrapped buy");
    }

    function _ethPoolPrice() internal view returns (uint160, int24, uint24, uint24) {
        return StateLibrary.getSlot0(IPoolManager(address(manager)), ethKey.toId());
    }
}

contract ZapWrapTokenIsCurrency0Test is ZapWrapHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract ZapWrapTokenIsCurrency1Test is ZapWrapHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
