// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TradeRouter} from "../src/TradeRouter.sol";
import {FeeHookHarness} from "./FeeHook.t.sol";

/// @notice The router a buyer actually calls.
///
/// @dev **The property that matters is the SETTLEMENT ORDER**, not that a swap works. Audit 04
///      measured a `sync -> transfer -> swap -> settle` router being overcharged 8.5x on an
///      identical trade, because `FeeHook` can move real ERC-20 out of the singleton from inside
///      `afterSwap` and `PoolManager._settle` credits `balanceOfSelf() - syncedReserves` — so
///      anything leaving between a payer's `sync` and their `settle` is silently deducted from
///      what they are credited.
///
///      This router swaps first and settles from the resulting delta. These tests exist to hold
///      that ordering in place, because the tempting "pay once up front" refactor is exactly the
///      shape that breaks it, and it breaks SILENTLY — as an overcharge, not a revert.
abstract contract TradeRouterHarness is FeeHookHarness {
    TradeRouter internal router;

    function setUp() public virtual override {
        super.setUp();
        router = new TradeRouter(IPoolManager(address(manager)));

        pair.mint(alice, 1_000_000e18);
        vm.prank(alice);
        pair.approve(address(router), type(uint256).max);
        vm.prank(alice);
        token.approve(address(router), type(uint256).max);
    }

    // `_buyIsZeroForOne()` comes from `FeeHookHarness`.

    // ===========================================================================================

    function test_aBuyDeliversTokensAndChargesTheFee() public {
        uint256 tokensBefore = token.balanceOf(alice);
        uint256 pairBefore = pair.balanceOf(alice);

        vm.prank(alice);
        uint256 out = router.swap(key, _buyIsZeroForOne(), 10e18, 0, alice);

        assertGt(out, 0, "the buy returned nothing");
        assertEq(token.balanceOf(alice) - tokensBefore, out, "the reported output is not what arrived");
        assertEq(pairBefore - pair.balanceOf(alice), 10e18, "the buyer paid something other than amountIn");
        assertGt(hook.totalFeesTaken(poolId), 0, "no fee was charged on a routed buy");
    }

    function test_aSellReturnsPairCurrency() public {
        vm.prank(alice);
        router.swap(key, _buyIsZeroForOne(), 50e18, 0, alice);

        uint256 held = token.balanceOf(alice);
        assertGt(held, 0, "precondition: alice holds tokens to sell");
        uint256 pairBefore = pair.balanceOf(alice);

        vm.prank(alice);
        uint256 out = router.swap(key, !_buyIsZeroForOne(), held / 2, 0, alice);

        assertGt(out, 0, "the sell returned nothing");
        assertEq(pair.balanceOf(alice) - pairBefore, out, "the reported output is not what arrived");
    }

    /// Slippage protection has to actually bind, or it is decoration.
    function test_minAmountOutReverts() public {
        vm.prank(alice);
        uint256 fair = router.swap(key, _buyIsZeroForOne(), 1e18, 0, alice);

        vm.prank(alice);
        vm.expectRevert();
        // Demand twice what an identical trade just returned.
        router.swap(key, _buyIsZeroForOne(), 1e18, fair * 2, alice);
    }

    function test_outputCanGoToSomebodyElse() public {
        vm.prank(alice);
        uint256 out = router.swap(key, _buyIsZeroForOne(), 5e18, 0, bob);
        assertEq(token.balanceOf(bob), out, "the recipient did not receive the output");
    }

    /// **THE REGRESSION GUARD.** A buy through this router must cost the same as the identical
    /// buy through Uniswap's own test router, which also settles after swapping. If somebody
    /// refactors to pay up front, this diverges by multiples rather than reverting.
    function test_costsTheSameAsASettleAfterRouter() public {
        uint256 snap = vm.snapshotState();

        vm.prank(alice);
        router.swap(key, _buyIsZeroForOne(), 25e18, 0, alice);
        uint256 viaOurRouter = token.balanceOf(alice);

        vm.revertToState(snap);

        _buyExactIn(alice, 25e18); // the harness helper, via PoolSwapTest
        uint256 viaUniswap = token.balanceOf(alice);

        assertApproxEqRel(
            viaOurRouter, viaUniswap, 1e15, "our router does not price the same as Uniswap's"
        );
    }

    /// Every delta must be closed or `unlock` reverts, so a sequence of trades must simply work.
    function test_manyTradesInSequenceAllSettle() public {
        for (uint256 i = 0; i < 8; i++) {
            vm.prank(alice);
            router.swap(key, _buyIsZeroForOne(), 3e18, 0, alice);
        }
        uint256 held = token.balanceOf(alice);
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(alice);
            router.swap(key, !_buyIsZeroForOne(), held / 10, 0, alice);
        }
        assertEq(pair.balanceOf(address(router)), 0, "the router retained pair currency");
        assertEq(token.balanceOf(address(router)), 0, "the router retained launch tokens");
    }

    /// The router is a conduit. Anything it keeps is stranded, since it has no rescue function.
    function test_theRouterRetainsNothing() public {
        vm.prank(alice);
        router.swap(key, _buyIsZeroForOne(), 40e18, 0, alice);
        assertEq(pair.balanceOf(address(router)), 0, "router kept pair currency");
        assertEq(token.balanceOf(address(router)), 0, "router kept launch tokens");
    }

    function test_zeroAmountIsRejected() public {
        vm.prank(alice);
        vm.expectRevert(TradeRouter.ZeroAmount.selector);
        router.swap(key, _buyIsZeroForOne(), 0, 0, alice);
    }

    function test_onlyThePoolManagerMayDriveTheCallback() public {
        vm.prank(alice);
        vm.expectRevert(TradeRouter.NotPoolManager.selector);
        router.unlockCallback("");
    }
}

contract TradeRouterTokenIsCurrency0Test is TradeRouterHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract TradeRouterTokenIsCurrency1Test is TradeRouterHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
