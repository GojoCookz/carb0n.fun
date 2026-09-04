// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Distributor, IRewardConverter} from "../src/Distributor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Paying holders in a currency the creator chose, rather than the one fees arrive in.
///
/// @dev **The property under test is that a failed conversion DEGRADES rather than corrupts.**
///      Fees necessarily arrive in the pair currency, because that is what a buyer hands over, so
///      any other reward means a swap. The tempting place to do that swap is on the way in, at
///      `_routeFee`, and it is wrong: the accumulator would be credited in one token while the
///      contract held another the moment a route failed, and every holder would be owed something
///      the distributor does not have.
///
///      Converting on the way OUT means the amount is already owed and already held, so a failed
///      route pays the pair currency and not one number in the ledger moves. These tests exist to
///      hold that line.
contract GoodConverter is IRewardConverter {
    /// Pays out at a fixed 2:1 so the test can assert an exact figure.
    function convert(address tokenIn, address tokenOut, uint256 amountIn, address recipient)
        external
        returns (uint256)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * 2;
        MockERC20(tokenOut).mint(recipient, out);
        return out;
    }
}

contract RevertingConverter is IRewardConverter {
    function convert(address, address, uint256, address) external pure returns (uint256) {
        revert("no route");
    }
}

/// The subtler failure: it does not revert, it just cannot route and says so by returning zero.
contract ZeroConverter is IRewardConverter {
    function convert(address, address, uint256, address) external pure returns (uint256) {
        return 0;
    }
}

contract RewardCurrencyTest is Test {
    /// @dev Amounts are asserted with tolerance throughout, and there are now TWO sources of it.
    ///      `_magnifiedPayoutPerShare` divides by total shares and truncates, costing at most a
    ///      wei per holder. `_arm` then divides the distribution into a per-second rate and
    ///      carries `total % STREAM_WINDOW` in `pendingPayouts` rather than dropping it, which
    ///      costs strictly less than `STREAM_WINDOW` wei. Both round DOWN - the direction that
    ///      leaves the contract solvent rather than short - so `STREAM_WINDOW` is the honest
    ///      bound and demanding exact equality would be asserting against the accumulator rather
    ///      than the feature.
    ///
    ///      Every test here also has to WAIT. A distribution no longer credits entitlement in the
    ///      block it lands; it vests linearly over `STREAM_WINDOW`, which is what makes a
    ///      zero-block position worthless. Without a warp `withdrawableOf` is 0 and `withdraw`
    ///      reverts with `NothingToWithdraw`, so nothing about conversion would ever be exercised.
    MockERC20 internal pair; // what fees arrive in
    MockERC20 internal reward; // what the creator wants holders paid in

    address internal alice = address(0xA11CE);

    function setUp() public {
        pair = new MockERC20("Wrapped Ether", "WETH", 18);
        reward = new MockERC20("Wrapped Bitcoin", "WBTC", 18);
    }

    function _mk(address rewardToken, address converter) internal returns (Distributor d) {
        d = new Distributor(
            address(this), address(pair), address(this), address(0), address(0), 1, 1, 1,
            rewardToken, converter
        );
    }

    /// Fund and distribute exactly the way the hook does: pair currency in, pair-denominated.
    function _fund(Distributor d, uint256 amount) internal {
        pair.mint(address(d), amount);
        d.distribute(amount);
    }

    // ===========================================================================================
    // The default: no reward currency at all
    // ===========================================================================================

    function test_withoutARewardCurrencyHoldersArePaidThePair() public {
        Distributor d = _mk(address(0), address(0));
        assertEq(d.rewardToken(), address(pair), "zero should collapse to the pair currency");

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        vm.warp(block.timestamp + d.STREAM_WINDOW() + 1);

        vm.prank(alice);
        d.withdraw();
        assertApproxEqAbs(
            pair.balanceOf(alice), 100e18, d.STREAM_WINDOW(), "holder was not paid the pair currency"
        );
    }

    // ===========================================================================================
    // The happy path
    // ===========================================================================================

    function test_aWorkingConverterPaysTheChosenCurrency() public {
        Distributor d = _mk(address(reward), address(new GoodConverter()));

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        vm.warp(block.timestamp + d.STREAM_WINDOW() + 1);

        vm.prank(alice);
        d.withdraw();

        // The converter pays 2:1, so it doubles the tolerance along with the amount.
        assertApproxEqAbs(
            reward.balanceOf(alice),
            200e18,
            2 * uint256(d.STREAM_WINDOW()),
            "holder was not paid in the reward currency"
        );
        assertEq(pair.balanceOf(alice), 0, "holder was also paid the pair currency");
    }

    /// **The ledger is denominated in the PAIR currency regardless.** What a holder receives is a
    /// delivery detail; what they are owed is accounting, and the two must not be confused.
    function test_accountingStaysInThePairCurrency() public {
        Distributor d = _mk(address(reward), address(new GoodConverter()));

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        vm.warp(block.timestamp + d.STREAM_WINDOW() + 1);

        assertApproxEqAbs(
            d.withdrawableOf(alice),
            100e18,
            d.STREAM_WINDOW(),
            "owed should be denominated in the pair"
        );
        vm.prank(alice);
        d.withdraw();
        assertApproxEqAbs(
            d.totalWithdrawn(),
            100e18,
            d.STREAM_WINDOW(),
            "withdrawn should be denominated in the pair"
        );
    }

    // ===========================================================================================
    // The failures, which are the point
    // ===========================================================================================

    function test_aRevertingConverterFallsBackToThePairCurrency() public {
        Distributor d = _mk(address(reward), address(new RevertingConverter()));

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        vm.warp(block.timestamp + d.STREAM_WINDOW() + 1);

        vm.prank(alice);
        d.withdraw();

        assertApproxEqAbs(
            pair.balanceOf(alice), 100e18, d.STREAM_WINDOW(), "holder was not paid at all"
        );
        assertEq(reward.balanceOf(alice), 0);
        assertEq(d.withdrawableOf(alice), 0, "the claim survived being paid");
    }

    /// A converter that cannot route says so by returning zero rather than reverting. Treating
    /// that as success would pay the holder nothing while marking them paid.
    function test_aConverterReturningZeroFallsBackRatherThanPayingNothing() public {
        Distributor d = _mk(address(reward), address(new ZeroConverter()));

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        vm.warp(block.timestamp + d.STREAM_WINDOW() + 1);

        vm.prank(alice);
        d.withdraw();

        assertApproxEqAbs(
            pair.balanceOf(alice),
            100e18,
            d.STREAM_WINDOW(),
            "a zero return was treated as a successful payout"
        );
    }

    /// A reward currency set with NO converter deployed must still pay, not strand.
    function test_aRewardCurrencyWithNoConverterStillPays() public {
        Distributor d = _mk(address(reward), address(0));

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        vm.warp(block.timestamp + d.STREAM_WINDOW() + 1);

        vm.prank(alice);
        d.withdraw();
        assertApproxEqAbs(
            pair.balanceOf(alice),
            100e18,
            d.STREAM_WINDOW(),
            "holder was stranded by a missing converter"
        );
    }

    /// **Solvency across every converter outcome.** This is the invariant the whole design exists
    /// to protect: the contract must never owe more of the token it accounts in than it holds.
    function testFuzz_solventWhicheverWayTheConverterBehaves(uint96 amount, uint8 pick) public {
        amount = uint96(bound(amount, 1e6, type(uint96).max));
        address conv = pick % 4 == 0
            ? address(new GoodConverter())
            : pick % 4 == 1
                ? address(new RevertingConverter())
                : pick % 4 == 2 ? address(new ZeroConverter()) : address(0);

        Distributor d = _mk(address(reward), conv);
        d.setBalance(alice, 1_000e18);
        _fund(d, uint256(amount));
        // Fully vested is the WORST case for this assertion: it is the moment the contract owes
        // the most it will ever owe on this distribution.
        vm.warp(block.timestamp + d.STREAM_WINDOW() + 1);

        vm.prank(alice);
        d.withdraw();

        assertGe(
            pair.balanceOf(address(d)),
            d.withdrawableOf(alice) + d.pendingPayouts(),
            "distributor owes more than it holds"
        );
        assertLe(d.totalWithdrawn(), d.totalDistributed(), "paid out more than came in");
    }

    /// The converter must never be left with a standing allowance over everyone's dividends.
    function test_noAllowanceSurvivesAConversion() public {
        GoodConverter conv = new GoodConverter();
        Distributor d = _mk(address(reward), address(conv));

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        vm.warp(block.timestamp + d.STREAM_WINDOW() + 1);
        vm.prank(alice);
        d.withdraw();

        assertEq(
            pair.allowance(address(d), address(conv)), 0, "converter kept an open allowance"
        );
    }
}
