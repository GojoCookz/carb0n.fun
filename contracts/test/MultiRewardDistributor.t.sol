// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRewardConverter} from "../src/Distributor.sol";
import {MultiRewardDistributor} from "../src/MultiRewardDistributor.sol";
import {PairRegistry} from "../src/PairRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The basket distributor: N creator-weighted slots plus one holder-elected slot.
///
/// @dev **The properties under test are inherited promises, not new ones.** Accounting stays in
///      the pair currency whatever the basket says; a slot that cannot convert DEGRADES to the
///      pair rather than corrupting or reverting anyone's claim; entitlement still streams over
///      `STREAM_WINDOW` so a zero-duration hold is worth nothing; and the holder election - the
///      audit/11 §7 idea whose reference implementation was a drain - is fenced by the pair
///      registry and by state-before-external-calls, which these tests attack directly with a
///      hostile elected token.
contract MintingConverter is IRewardConverter {
    /// Pays out 1:1 so per-slot amounts can be asserted without a second exchange rate in play.
    function convert(address tokenIn, address tokenOut, uint256 amountIn, address recipient)
        external
        returns (uint256)
    {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(recipient, amountIn);
        return amountIn;
    }
}

/// Reverts for exactly ONE output asset and routes everything else, so a single bad slot can be
/// staged next to healthy ones - the scenario the per-slot fallback exists for.
contract SelectiveRevertingConverter is IRewardConverter {
    address public immutable badOut;

    constructor(address _badOut) {
        badOut = _badOut;
    }

    function convert(address tokenIn, address tokenOut, uint256 amountIn, address recipient)
        external
        returns (uint256)
    {
        if (tokenOut == badOut) revert("no route");
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(recipient, amountIn);
        return amountIn;
    }
}

/// @notice The audit/11 §3 attacker, rebuilt for this contract: a token that is BOTH the holder
///         and its own elected reward, whose mint hook re-enters the distributor mid-claim.
///
/// @dev In the BSC lineage this exact shape drained the distributor, because the per-holder
///      reward setter was unguarded (any address, so the attacker supplies the callback) and the
///      claim's guards were written AFTER the tokens left. Here the registry has to have approved
///      this token for the election to exist at all - the test grants that approval deliberately,
///      to prove that even a listed-then-hostile asset cannot double-claim - and the re-entry
///      lands on consumed state behind a reentrancy guard.
contract ReentrantElectedToken is ERC20 {
    MultiRewardDistributor public dist;
    bool internal entered;
    /// How many times the hook actually fired - the non-vacuity witness.
    uint256 public attempts;
    /// If either of these ever goes true, the guard failed and the drain is live again.
    bool public nestedWithdrawSucceeded;
    bool public nestedBatchSucceeded;

    constructor() ERC20("Evil Elected", "EVIL") {}

    function arm(MultiRewardDistributor d) external {
        dist = d;
    }

    function elect() external {
        dist.setMyReward(address(this));
    }

    function pull() external returns (uint256) {
        return dist.withdraw();
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (address(dist) != address(0) && !entered) {
            entered = true;
            attempts++;
            // The two entry points the original attack chained: claim again, and walk the queue
            // to grief the shared allowance slot (R2-07). Both must be dead ends.
            try dist.withdraw() returns (uint256) {
                nestedWithdrawSucceeded = true;
            } catch {}
            try dist.processBatch(10) returns (uint256, uint256) {
                nestedBatchSucceeded = true;
            } catch {}
            entered = false;
        }
    }
}

contract MultiRewardDistributorTest is Test {
    /// @dev Tolerances follow `RewardCurrency.t.sol`: the accumulator and `_arm` both floor, each
    ///      costing at most `STREAM_WINDOW` wei across a distribution, always in the direction
    ///      that leaves the contract solvent. Per-slot splits floor once more, worth at most
    ///      `MAX_SLOTS` wei, which vanishes inside the same bound.
    MockERC20 internal pair; // what fees arrive in, and what everything is accounted in
    MockERC20 internal tokA; // a registry-approved basket asset
    MockERC20 internal tokB; // another registry-approved basket asset
    MockERC20 internal impostor; // NOT in the registry - the address the gate must stop
    PairRegistry internal registry;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal creator = address(0xC0FFEE);
    address internal rando = address(0x5AD);

    uint256 internal WINDOW;

    function setUp() public {
        // An absolute clock near zero makes timestamp arithmetic meaningless; `skip`, not `warp`,
        // because `vm.warp(block.timestamp + n)` is a no-op under via_ir per the repo docs.
        skip(1_000_000);

        pair = new MockERC20("USD Global", "USDG", 18);
        tokA = new MockERC20("Apple Stock Token", "AAPL", 18);
        tokB = new MockERC20("Nvidia Stock Token", "NVDA", 18);
        impostor = new MockERC20("Totally Real GME", "GME", 18);

        registry = new PairRegistry(address(this));
        registry.approvePairWithoutOracle(address(tokA), 18);
        registry.approvePairWithoutOracle(address(tokB), 18);
        // `impostor` is deliberately never approved.
    }

    function _mk(address converter) internal returns (MultiRewardDistributor d) {
        d = new MultiRewardDistributor(
            address(this), // shareToken: the test drives setBalance directly
            address(pair),
            address(this), // controller (hook): the test drives distribute directly
            address(0),
            address(0),
            1, // minPushPayout
            1, // minShareForQueue
            1, // minSharesForDistribution
            converter,
            address(registry),
            creator
        );
        WINDOW = uint256(d.STREAM_WINDOW());
    }

    /// Fund and distribute exactly the way the hook does: pair currency in, pair-denominated.
    function _fund(MultiRewardDistributor d, uint256 amount) internal {
        pair.mint(address(d), amount);
        d.distribute(amount);
    }

    function _addrs1(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _w1(uint16 a) internal pure returns (uint16[] memory arr) {
        arr = new uint16[](1);
        arr[0] = a;
    }

    // ===========================================================================================
    // The weights invariant
    // ===========================================================================================

    function test_slotWeightsMustSumToTenThousand() public {
        MultiRewardDistributor d = _mk(address(0));

        // 4000 + 5000 = 9000: short of the whole.
        vm.prank(creator);
        vm.expectPartialRevert(MultiRewardDistributor.WeightsMustSumToBps.selector);
        d.setBasket(_addrs1(address(tokA)), _w1(4000), 5000);

        // 4000 + 7000 = 11000: over the whole.
        vm.prank(creator);
        vm.expectPartialRevert(MultiRewardDistributor.WeightsMustSumToBps.selector);
        d.setBasket(_addrs1(address(tokA)), _w1(4000), 7000);

        // NEGATIVE CONTROL for the control: nothing above may have taken effect.
        assertEq(d.creatorSlotCount(), 0, "a rejected basket left slots behind");
        assertEq(d.holderSlotBps(), 10_000, "a rejected basket moved the holder weight");

        // CONTROL: the same call with weights that DO sum lands, and the getters prove it.
        vm.prank(creator);
        d.setBasket(_addrs1(address(tokA)), _w1(4000), 6000);
        assertEq(d.creatorSlotCount(), 1, "the canonical path did not set a slot");
        (address t, uint16 w) = d.creatorSlotAt(0);
        assertEq(t, address(tokA));
        assertEq(w, 4000);
        assertEq(d.holderSlotBps(), 6000);
    }

    function test_moreThanFourCreatorSlotsIsRefused() public {
        MultiRewardDistributor d = _mk(address(0));

        address[] memory tokens = new address[](5);
        uint16[] memory weights = new uint16[](5);
        for (uint256 i = 0; i < 5; ++i) {
            tokens[i] = address(tokA); // duplicates are legal; the COUNT is what is on trial
            weights[i] = 2000;
        }

        vm.prank(creator);
        vm.expectPartialRevert(MultiRewardDistributor.TooManySlots.selector);
        d.setBasket(tokens, weights, 0);

        // CONTROL: exactly four is the cap and passes.
        address[] memory four = new address[](4);
        uint16[] memory fourW = new uint16[](4);
        for (uint256 i = 0; i < 4; ++i) {
            four[i] = address(tokA);
            fourW[i] = 2000;
        }
        vm.prank(creator);
        d.setBasket(four, fourW, 2000);
        assertEq(d.creatorSlotCount(), 4, "the cap rejected a basket it should allow");
    }

    function test_aBasketSlotMustBeRegistryApproved() public {
        MultiRewardDistributor d = _mk(address(0));

        vm.prank(creator);
        vm.expectPartialRevert(MultiRewardDistributor.TokenNotApproved.selector);
        d.setBasket(_addrs1(address(impostor)), _w1(5000), 5000);

        // CONTROL: the identical shape with an approved asset lands.
        vm.prank(creator);
        d.setBasket(_addrs1(address(tokA)), _w1(5000), 5000);
        assertEq(d.creatorSlotCount(), 1, "an approved asset was refused");
    }

    function test_onlyTheSeatMayReweight() public {
        MultiRewardDistributor d = _mk(address(0));

        vm.prank(rando);
        vm.expectPartialRevert(MultiRewardDistributor.OnlyBasketController.selector);
        d.setBasket(_addrs1(address(tokA)), _w1(5000), 5000);

        // CONTROL: the seat itself may.
        vm.prank(creator);
        d.setBasket(_addrs1(address(tokA)), _w1(5000), 5000);
        assertEq(d.creatorSlotCount(), 1);
    }

    // ===========================================================================================
    // The holder slot
    // ===========================================================================================

    function test_anUnsetHolderSlotPaysThePairCurrency() public {
        MultiRewardDistributor d = _mk(address(new MintingConverter()));
        // Default basket: 100% holder slot. Alice never elects anything.

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        skip(WINDOW + 1);

        vm.prank(alice);
        d.withdraw();

        assertApproxEqAbs(pair.balanceOf(alice), 100e18, WINDOW, "the default did not pay the pair");
        assertEq(tokA.balanceOf(alice), 0, "an unelected holder was paid a basket asset");
        assertEq(tokB.balanceOf(alice), 0, "an unelected holder was paid a basket asset");
    }

    function test_anElectedHolderSlotPaysTheElectedToken() public {
        MultiRewardDistributor d = _mk(address(new MintingConverter()));

        vm.prank(alice);
        d.setMyReward(address(tokA));
        assertEq(d.holderRewardOf(alice), address(tokA), "the election did not register");

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        skip(WINDOW + 1);

        vm.prank(alice);
        d.withdraw();

        // The converter pays 1:1, so the elected asset arrives at face value.
        assertApproxEqAbs(tokA.balanceOf(alice), 100e18, WINDOW, "the elected token never arrived");
        assertEq(pair.balanceOf(alice), 0, "the holder was also paid the pair currency");
    }

    function test_electingATokenTheRegistryHasNotApprovedReverts() public {
        MultiRewardDistributor d = _mk(address(new MintingConverter()));

        vm.prank(alice);
        vm.expectPartialRevert(MultiRewardDistributor.TokenNotApproved.selector);
        d.setMyReward(address(impostor));
        assertEq(d.electedRewardOf(alice), address(0), "a rejected election left state behind");

        // CONTROL: an approved token elects fine, and zero resets to the default.
        vm.prank(alice);
        d.setMyReward(address(tokA));
        assertEq(d.electedRewardOf(alice), address(tokA), "the canonical election failed");
        vm.prank(alice);
        d.setMyReward(address(0));
        assertEq(d.holderRewardOf(alice), address(pair), "the reset did not restore the default");
    }

    // ===========================================================================================
    // Per-slot degradation - the reason conversion lives at the exit
    // ===========================================================================================

    function test_aRevertingSlotFallsBackToPairWhileOtherSlotsStillConvert() public {
        // The converter can route everything EXCEPT tokA.
        MultiRewardDistributor d = _mk(address(new SelectiveRevertingConverter(address(tokA))));

        vm.prank(creator);
        d.setBasket(_addrs1(address(tokA)), _w1(5000), 5000);
        vm.prank(alice);
        d.setMyReward(address(tokB));

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        skip(WINDOW + 1);

        vm.prank(alice);
        d.withdraw();

        // The healthy slot converted; the broken slot paid the pair; NOTHING paid zero.
        assertApproxEqAbs(tokB.balanceOf(alice), 50e18, WINDOW, "the healthy slot was dragged down");
        assertApproxEqAbs(pair.balanceOf(alice), 50e18, WINDOW, "the broken slot did not fall back");
        assertEq(tokA.balanceOf(alice), 0, "the unroutable asset somehow arrived");
        assertEq(d.withdrawableOf(alice), 0, "the claim survived being paid");
    }

    /// CONTROL for the test above: the identical basket through a converter with no bad asset
    /// delivers BOTH slots in kind, proving the fallback fires on failure and only on failure.
    function test_control_withAWorkingConverterBothSlotsConvert() public {
        MultiRewardDistributor d = _mk(address(new MintingConverter()));

        vm.prank(creator);
        d.setBasket(_addrs1(address(tokA)), _w1(5000), 5000);
        vm.prank(alice);
        d.setMyReward(address(tokB));

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        skip(WINDOW + 1);

        vm.prank(alice);
        d.withdraw();

        assertApproxEqAbs(tokA.balanceOf(alice), 50e18, WINDOW, "the creator slot did not convert");
        assertApproxEqAbs(tokB.balanceOf(alice), 50e18, WINDOW, "the holder slot did not convert");
        assertEq(pair.balanceOf(alice), 0, "a healthy basket still paid the pair");
    }

    /// The ledger is denominated in the PAIR currency regardless of the basket. What a holder
    /// receives is a delivery detail; what they are owed is accounting.
    function test_accountingStaysInThePairCurrencyWhateverTheBasket() public {
        MultiRewardDistributor d = _mk(address(new MintingConverter()));

        vm.prank(creator);
        d.setBasket(_addrs1(address(tokA)), _w1(5000), 5000);
        vm.prank(alice);
        d.setMyReward(address(tokB));

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        skip(WINDOW + 1);

        assertApproxEqAbs(
            d.withdrawableOf(alice), 100e18, WINDOW, "owed should be denominated in the pair"
        );
        vm.prank(alice);
        d.withdraw();
        assertApproxEqAbs(
            d.totalWithdrawn(), 100e18, WINDOW, "withdrawn should be denominated in the pair"
        );
    }

    // ===========================================================================================
    // The seat
    // ===========================================================================================

    function test_aReweightChangesOnlyFuturePayouts() public {
        MultiRewardDistributor d = _mk(address(new MintingConverter()));

        // Basket 1: half tokA, half holder slot (alice is unset, so pair).
        vm.prank(creator);
        d.setBasket(_addrs1(address(tokA)), _w1(5000), 5000);

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        skip(WINDOW + 1);
        vm.prank(alice);
        d.withdraw();

        uint256 tokAAfterFirst = tokA.balanceOf(alice);
        uint256 pairAfterFirst = pair.balanceOf(alice);
        assertApproxEqAbs(tokAAfterFirst, 50e18, WINDOW, "basket 1 did not pay as configured");
        assertApproxEqAbs(pairAfterFirst, 50e18, WINDOW, "basket 1 did not pay as configured");

        // Reweight: tokB takes 20%, the holder slot takes 80%. tokA is out entirely.
        vm.prank(creator);
        d.setBasket(_addrs1(address(tokB)), _w1(2000), 8000);

        _fund(d, 100e18);
        skip(WINDOW + 1);
        vm.prank(alice);
        d.withdraw();

        // The SECOND payout follows the NEW basket...
        assertApproxEqAbs(
            tokB.balanceOf(alice), 20e18, WINDOW, "the reweight did not apply to the next payout"
        );
        assertApproxEqAbs(
            pair.balanceOf(alice) - pairAfterFirst,
            80e18,
            WINDOW,
            "the reweighted holder slot did not pay"
        );
        // ...and the FIRST payout is untouched: what was already delivered is beyond the seat.
        assertEq(tokA.balanceOf(alice), tokAAfterFirst, "a reweight reached back into a past payout");
    }

    function test_renounceIsOneWayAndBlocksFurtherMutation() public {
        MultiRewardDistributor d = _mk(address(0));

        // CONTROL first: before the renounce, the seat can mutate. Without this the reverts
        // below would prove nothing about the renounce.
        vm.prank(creator);
        d.setBasket(_addrs1(address(tokA)), _w1(5000), 5000);
        assertEq(d.creatorSlotCount(), 1, "the seat could not mutate even before renouncing");

        vm.prank(creator);
        d.renounceBasket();
        assertTrue(d.basketRenounced(), "the renounce did not register");
        assertEq(d.basketController(), address(0), "the seat survived its own renounce");

        // Every mutation path is now closed, INCLUDING to the address that held the seat.
        vm.prank(creator);
        vm.expectPartialRevert(MultiRewardDistributor.BasketIsRenounced.selector);
        d.setBasket(_addrs1(address(tokB)), _w1(5000), 5000);

        vm.prank(creator);
        vm.expectPartialRevert(MultiRewardDistributor.BasketIsRenounced.selector);
        d.transferBasketController(rando);

        vm.prank(creator);
        vm.expectPartialRevert(MultiRewardDistributor.BasketIsRenounced.selector);
        d.renounceBasket();

        // The basket froze AS CONFIGURED, not reset: holders keep what was advertised.
        assertEq(d.creatorSlotCount(), 1, "the renounce rewrote the basket");
        (address t,) = d.creatorSlotAt(0);
        assertEq(t, address(tokA), "the renounce rewrote the basket");
    }

    function test_theSeatTransferIsTwoStep() public {
        MultiRewardDistributor d = _mk(address(0));
        address newSeat = address(0xBEEF);

        vm.prank(creator);
        d.transferBasketController(newSeat);
        // Announcing a transfer moves nothing yet.
        assertEq(d.basketController(), creator, "the seat moved before acceptance");

        // Nobody but the named successor can accept.
        vm.prank(rando);
        vm.expectPartialRevert(MultiRewardDistributor.NotPendingBasketController.selector);
        d.acceptBasketController();

        vm.prank(newSeat);
        d.acceptBasketController();
        assertEq(d.basketController(), newSeat, "the handover did not complete");

        // The old seat is out...
        vm.prank(creator);
        vm.expectPartialRevert(MultiRewardDistributor.OnlyBasketController.selector);
        d.setBasket(_addrs1(address(tokA)), _w1(5000), 5000);

        // ...and the new seat is in (CONTROL).
        vm.prank(newSeat);
        d.setBasket(_addrs1(address(tokA)), _w1(5000), 5000);
        assertEq(d.creatorSlotCount(), 1, "the new seat cannot actually mutate");
    }

    // ===========================================================================================
    // The attack the registry gate exists for
    // ===========================================================================================

    /// @dev The audit/11 §3 chain, replayed against this contract: an elected token whose
    ///      transfer hook re-enters both payout entry points mid-claim. The registry gate is
    ///      deliberately handed to the attacker (the test approves their token) because the claim
    ///      under test is stronger than "the registry stops unlisted tokens" - it is that even a
    ///      LISTED token that turns hostile cannot double-claim, because state is consumed before
    ///      the first external call and the guard closes the shared-allowance drain (R2-07).
    function test_aReentrantElectedTokenCannotDoubleClaim() public {
        MultiRewardDistributor d = _mk(address(new MintingConverter()));

        ReentrantElectedToken evil = new ReentrantElectedToken();
        registry.approvePairWithoutOracle(address(evil), 18);
        evil.arm(d);
        evil.elect();

        d.setBalance(address(evil), 1_000e18);
        d.setBalance(alice, 1_000e18);
        _fund(d, 200e18);
        skip(WINDOW + 1);

        uint256 owedEvil = d.withdrawableOf(address(evil));
        uint256 owedAlice = d.withdrawableOf(alice);
        assertGt(owedEvil, 0, "precondition: the attacker must actually be owed something");

        evil.pull();

        // NON-VACUITY: the hook really fired. Without this every assertion below is hollow.
        assertGt(evil.attempts(), 0, "the reentrancy was never attempted, so this proves nothing");
        // The attack itself: both nested entry points must have been dead ends.
        assertFalse(evil.nestedWithdrawSucceeded(), "a nested withdraw went through mid-claim");
        assertFalse(evil.nestedBatchSucceeded(), "a nested processBatch went through mid-claim");

        // Paid once, exactly, in the elected asset - and the claim is spent.
        assertApproxEqAbs(
            evil.balanceOf(address(evil)), owedEvil, WINDOW, "the attacker was not paid once"
        );
        assertEq(d.withdrawableOf(address(evil)), 0, "the attacker can claim again");
        assertEq(d.withdrawnOf(address(evil)), owedEvil, "the ledger disagrees with the payment");

        // Nobody else's money moved, and the contract can still cover them.
        assertEq(d.withdrawableOf(alice), owedAlice, "the bystander's claim moved");
        assertGe(
            pair.balanceOf(address(d)), owedAlice, "the contract cannot cover the other holder"
        );

        // A second pull finds nothing.
        vm.expectPartialRevert(MultiRewardDistributor.NothingToWithdraw.selector);
        evil.pull();
    }

    // ===========================================================================================
    // Streaming is preserved
    // ===========================================================================================

    function test_aZeroDurationHoldIsOwedNothing() public {
        MultiRewardDistributor d = _mk(address(new MintingConverter()));

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);

        // Same block as the distribution: nothing has vested, nothing is claimable.
        assertEq(d.withdrawableOf(alice), 0, "a zero-duration hold earned something");
        vm.prank(alice);
        vm.expectPartialRevert(MultiRewardDistributor.NothingToWithdraw.selector);
        d.withdraw();

        // CONTROL: the same counter DOES move once time passes - the zero above is the stream
        // working, not the accounting being dead.
        skip(WINDOW + 1);
        assertApproxEqAbs(d.withdrawableOf(alice), 100e18, WINDOW, "the stream never vested");
    }

    // ===========================================================================================
    // The push path
    // ===========================================================================================

    function test_processBatchIsBoundedAndIdempotent() public {
        MultiRewardDistributor d = _mk(address(new MintingConverter()));

        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 3_000e18);
        _fund(d, 100e18);
        skip(WINDOW + 1);

        uint256 owedAlice = d.withdrawableOf(alice);
        uint256 owedBob = d.withdrawableOf(bob);
        assertGt(owedAlice, 0, "precondition: alice must be owed");
        assertGt(owedBob, 0, "precondition: bob must be owed");

        // BOUNDED: asked for one, pays exactly one, even though two are owed.
        (uint256 count1,) = d.processBatch(1);
        assertEq(count1, 1, "a batch of one paid a different number of holders");

        // The second call picks up from the cursor and pays the other.
        (uint256 count2, uint256 total2) = d.processBatch(10);
        assertEq(count2, 1, "the cursor lost its place");
        assertGt(total2, 0, "the second batch moved no money");

        assertApproxEqAbs(pair.balanceOf(alice), owedAlice, WINDOW, "alice was not pushed her claim");
        assertApproxEqAbs(pair.balanceOf(bob), owedBob, WINDOW, "bob was not pushed his claim");

        // IDEMPOTENT: a third walk finds everyone settled and moves nothing.
        uint256 aliceBefore = pair.balanceOf(alice);
        uint256 bobBefore = pair.balanceOf(bob);
        (uint256 count3, uint256 total3) = d.processBatch(10);
        assertEq(count3, 0, "a settled queue paid somebody");
        assertEq(total3, 0, "a settled queue moved money");
        assertEq(pair.balanceOf(alice), aliceBefore, "an idempotent batch changed a balance");
        assertEq(pair.balanceOf(bob), bobBefore, "an idempotent batch changed a balance");
    }

    // ===========================================================================================
    // Solvency, whatever shape the basket and converter take
    // ===========================================================================================

    /// The invariant the whole accounting-stays-in-payoutToken rule protects: the contract never
    /// owes more of the token it accounts in than it holds, whichever way delivery went.
    function testFuzz_solventWhicheverWayTheBasketBehaves(uint96 amount, uint8 pick) public {
        amount = uint96(bound(amount, 1e6, type(uint96).max));
        address conv = pick % 3 == 0
            ? address(new MintingConverter())
            : pick % 3 == 1 ? address(new SelectiveRevertingConverter(address(tokA))) : address(0);

        MultiRewardDistributor d = _mk(conv);
        vm.prank(creator);
        d.setBasket(_addrs1(address(tokA)), _w1(5000), 5000);
        vm.prank(alice);
        d.setMyReward(address(tokB));

        d.setBalance(alice, 1_000e18);
        d.setBalance(bob, 3_000e18);
        _fund(d, uint256(amount));
        // Fully vested is the worst case: the moment the contract owes the most it ever will.
        skip(WINDOW + 1);

        vm.prank(alice);
        d.withdraw();

        assertGe(
            pair.balanceOf(address(d)),
            d.withdrawableOf(alice) + d.withdrawableOf(bob) + d.pendingPayouts(),
            "distributor owes more than it holds"
        );
        assertLe(d.totalWithdrawn(), d.totalDistributed(), "paid out more than came in");
    }

    /// The converter must never be left with a standing allowance over everyone's dividends,
    /// however many slots touched it in one claim.
    function test_noAllowanceSurvivesAMultiSlotClaim() public {
        MintingConverter conv = new MintingConverter();
        MultiRewardDistributor d = _mk(address(conv));

        vm.prank(creator);
        d.setBasket(_addrs1(address(tokA)), _w1(5000), 5000);
        vm.prank(alice);
        d.setMyReward(address(tokB));

        d.setBalance(alice, 1_000e18);
        _fund(d, 100e18);
        skip(WINDOW + 1);
        vm.prank(alice);
        d.withdraw();

        assertEq(pair.allowance(address(d), address(conv)), 0, "converter kept an open allowance");
    }
}
