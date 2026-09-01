// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Distributor} from "../src/Distributor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Random call sequences against the contract that holds everyone's money.
///
/// @dev **The existing 274 tests all ask "does this work when used correctly".** They are unit and
///      integration tests with scripted inputs, and every one of them was written by the same
///      person who wrote the code, so they encode the same assumptions about what order things
///      happen in. An attacker does not read those assumptions.
///
///      The invariant fuzzer does. It calls `distribute`, `setBalance`, `withdraw` and
///      `processBatch` in orders nobody would write by hand - withdraw before any distribution,
///      a balance set to zero mid-payout, a distribution while the holder base is one wei - and
///      after every single call it checks the properties below still hold.
///
///      `foundry.toml` has had an `[invariant]` section this whole time with no invariant tests
///      under it.
contract DistributorHandler is Test {
    Distributor public dist;
    MockERC20 public payout;

    address[] public actors;
    uint256 public ghostDistributed;

    constructor(Distributor _dist, MockERC20 _payout, address[] memory _actors) {
        dist = _dist;
        payout = _payout;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// The controller funds the contract and then tells it the money arrived. Doing only the
    /// second half is how an accounting system ends up promising more than it holds, so the
    /// handler always does both - the invariant should hold because of the code, not because
    /// the test forgot to move tokens.
    function distribute(uint96 amount) external {
        uint256 amt = uint256(amount);
        payout.mint(address(dist), amt);
        ghostDistributed += amt;
        dist.distribute(amt);
    }

    function setBalance(uint256 seed, uint96 newBalance) external {
        dist.setBalance(_actor(seed), uint256(newBalance));
    }

    function withdraw(uint256 seed) external {
        address a = _actor(seed);
        vm.prank(a);
        dist.withdraw();
    }

    function processBatch(uint8 n) external {
        dist.processBatch(uint256(n));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract DistributorInvariantTest is Test {
    Distributor internal dist;
    MockERC20 internal payout;
    DistributorHandler internal handler;
    address[] internal actors;

    function setUp() public {
        payout = new MockERC20("Pair", "PAIR", 18);

        // The handler is BOTH the controller and the share token, so the fuzzer can drive every
        // privileged entry point. Access control is tested separately; the question here is
        // whether the arithmetic survives arbitrary ordering, not whether the modifiers work.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);

        dist = new Distributor(
            predicted, // shareToken
            address(payout),
            predicted, // controller
            address(0),
            address(0),
            1, // minPushPayout
            1, // minShareForQueue
            1_000 // minSharesForDistribution
        );

        for (uint256 i = 0; i < 5; i++) {
            actors.push(address(uint160(0xA11CE + i)));
        }

        handler = new DistributorHandler(dist, payout, actors);
        require(address(handler) == predicted, "handler address prediction failed");

        targetContract(address(handler));
    }

    /// @notice THE ONE THAT MATTERS. The contract must always hold enough to pay what it owes.
    ///
    /// @dev If this ever breaks, the last holders to call `withdraw` get nothing while the
    ///      accounting still says they are owed - the failure mode of every broken dividend
    ///      token. Integer division in `_magnifiedPayoutPerShare` truncates, so the contract
    ///      should hold slightly MORE than it owes; strictly less is insolvency.
    function invariant_neverOwesMoreThanItHolds() public view {
        uint256 owed = dist.pendingPayouts();
        for (uint256 i = 0; i < actors.length; i++) {
            owed += dist.withdrawableOf(actors[i]);
        }
        assertGe(payout.balanceOf(address(dist)), owed, "distributor is insolvent");
    }

    /// @notice Nobody can withdraw money that was never distributed.
    function invariant_withdrawnNeverExceedsDistributed() public view {
        assertLe(dist.totalWithdrawn(), dist.totalDistributed(), "paid out more than came in");
    }

    /// @notice `totalShares` is the denominator every payout is divided by. If it drifts above the
    ///         real sum, every holder is underpaid forever and the difference is unreachable.
    function invariant_totalSharesEqualsSumOfShares() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += dist.shareOf(actors[i]);
        }
        assertEq(dist.totalShares(), sum, "totalShares drifted from the sum of balances");
    }

    /// @notice Everything ever handed to the contract is either distributed or explicitly carried.
    ///         A gap here is money that exists on the contract with nothing recording it - the
    ///         exact defect `pendingPayouts` was introduced to fix.
    function invariant_nothingIsSilentlyStranded() public view {
        assertGe(
            dist.totalDistributed() + dist.pendingPayouts(),
            handler.ghostDistributed(),
            "value went missing between arriving and being accounted for"
        );
    }
}
