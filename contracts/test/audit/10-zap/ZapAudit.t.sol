// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ZapRouter} from "../../../src/ZapRouter.sol";
import {TradeRouter} from "../../../src/TradeRouter.sol";
import {FeeHook} from "../../../src/FeeHook.sol";
import {LaunchToken} from "../../../src/LaunchToken.sol";
import {ZapBase} from "../../ZapRouter.t.sol";

/// @dev One candidate hop-1 pool, as a list. Every ZapRouter entry point now takes EVERY ETH
///      pool the caller knows of and picks the first that is not pinned (Z-14), so a single-pool
///      call is the degenerate case. A free function so every contract in this file can use it.
function _one(PoolKey memory k) pure returns (PoolKey[] memory out) {
    out = new PoolKey[](1);
    out[0] = k;
}

// ===================================================================================================
// Probes
// ===================================================================================================

/// @notice A recipient that is handed native ether by `poolManager.take` from INSIDE the zap's
///         still-open unlock cycle.
///
/// @dev `CurrencyLibrary.transfer` does `call(gas(), to, amount, 0, 0, 0, 0)` — the FULL gas
///      allowance, not a 2300 stipend. So an arbitrary caller-chosen address gets to run arbitrary
///      code while the PoolManager is unlocked and while `ZapRouter.unlockCallback` is mid-frame.
///      This probe measures exactly what that buys an attacker.
contract ReentrantRecipient {
    IPoolManager public immutable manager;
    ZapRouter public immutable zap;
    address public immutable pairToken;

    /// 0 = observe only, 1 = flash loan and repay, 2 = flash loan and walk away
    uint8 public mode;
    uint256 public flashAmount;

    uint256 public hits;
    bool public sawManagerUnlocked;
    bool public nestedUnlockReverted;
    bool public nestedZapBuyReverted;
    bytes4 public nestedUnlockSelector;
    uint256 public flashedBalance;

    PoolKey internal ethKey;
    PoolKey internal tokenKey;

    constructor(IPoolManager m, ZapRouter z, address pair_) {
        manager = m;
        zap = z;
        pairToken = pair_;
    }

    function arm(uint8 mode_, uint256 flashAmount_, PoolKey memory e, PoolKey memory t) external {
        mode = mode_;
        flashAmount = flashAmount_;
        ethKey = e;
        tokenKey = t;
    }

    receive() external payable {
        hits++;
        sawManagerUnlocked = TransientStateLibrary.isUnlocked(manager);

        // Every ZapRouter entry point routes through `poolManager.unlock`, and v4's `Lock` is ONE
        // global transient flag (`PoolManager.sol:105`) — not per-caller. So re-entering the router
        // is structurally impossible. Asserted rather than assumed.
        try manager.unlock("") returns (bytes memory) {}
        catch (bytes memory err) {
            nestedUnlockReverted = true;
            nestedUnlockSelector = bytes4(err);
        }

        try zap.zapBuy{value: 1}(_one(ethKey), tokenKey, 1, address(this), type(uint256).max) returns (uint256) {}
        catch {
            nestedZapBuyReverted = true;
        }

        if (mode == 1) {
            // A fee-free flash loan out of the singleton, taken from inside somebody else's unlock
            // cycle without ever implementing `IUnlockCallback`.
            manager.take(Currency.wrap(pairToken), address(this), flashAmount);
            flashedBalance = IERC20(pairToken).balanceOf(address(this));
            manager.sync(Currency.wrap(pairToken));
            IERC20(pairToken).transfer(address(manager), flashAmount);
            manager.settle();
        } else if (mode == 2) {
            // Take and do not repay. The global `NonzeroDeltaCount` check at `unlock`'s close is
            // what stops this, and it takes the WHOLE transaction down with it.
            manager.take(Currency.wrap(pairToken), address(this), flashAmount);
            flashedBalance = IERC20(pairToken).balanceOf(address(this));
        }
    }
}

/// @notice A sell recipient on the WRAP path, where the payout callback runs AFTER the unlock
///         cycle has closed rather than inside it.
contract ReenteringSellRecipient {
    ZapRouter public immutable zap;
    IPoolManager public immutable manager;

    PoolKey internal ethKey;
    PoolKey internal tokenKey;

    uint256 internal depth;
    bool public reentered;
    bool public managerWasUnlocked;
    uint256 public reentrantOut;

    constructor(ZapRouter z, IPoolManager m) {
        zap = z;
        manager = m;
    }

    function arm(PoolKey memory e, PoolKey memory t) external {
        ethKey = e;
        tokenKey = t;
    }

    receive() external payable {
        if (depth != 0) return; // the nested buy's own refund lands here too
        depth = 1;
        managerWasUnlocked = TransientStateLibrary.isUnlocked(manager);
        try zap.zapBuy{value: 1 ether}(_one(ethKey), tokenKey, 1, address(this), type(uint256).max) returns (
            uint256 o
        ) {
            reentered = true;
            reentrantOut = o;
        } catch {}
        depth = 0;
    }
}

/// @notice Catches the quote revert the way a contract integrator would.
contract QuoteCatcher {
    ZapRouter public immutable zap;
    uint256 public quoted;
    bool public caught;

    constructor(ZapRouter z) {
        zap = z;
    }

    function quoteBuy(PoolKey calldata a, PoolKey calldata b, uint256 amt) external {
        try zap.quoteZapBuy(_one(a), b, amt) {
            revert("quoteZapBuy returned instead of reverting");
        } catch (bytes memory err) {
            require(bytes4(err) == ZapRouter.ZapQuote.selector, "wrong error from the quote");
            caught = true;
            bytes memory body = new bytes(err.length - 4);
            for (uint256 i = 4; i < err.length; ++i) {
                body[i - 4] = err[i];
            }
            quoted = abi.decode(body, (uint256));
        }
    }

    receive() external payable {}
}

/// @notice Measures what `PoolManager.settle{value: v}()` actually credits for the NATIVE currency.
/// @dev `_settle` (`PoolManager.sol:349-365`) short-circuits to `paid = msg.value` whenever the
///      synced currency is `address(0)`. It never reads a balance. That is what makes
///      `ZapRouter`'s native-leg `SettlementShortfall` guard unreachable.
contract NativeSettleProbe is IUnlockCallback {
    IPoolManager public immutable manager;
    uint256 public credited;

    constructor(IPoolManager m) {
        manager = m;
    }

    function probe(uint256 v) external {
        manager.unlock(abi.encode(v));
    }

    function unlockCallback(bytes calldata d) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        uint256 v = abi.decode(d, (uint256));
        manager.sync(CurrencyLibrary.ADDRESS_ZERO);
        credited = manager.settle{value: v}();
        // We are now `+v`. Close it so `unlock` does not revert.
        manager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), v);
        return "";
    }

    receive() external payable {}
}

/// @notice A contract buyer with no payable fallback. An ordinary shape: an aggregator, a vault,
///         or any integrator that never intends to hold ether.
/// @dev It can still be funded (`vm.deal` writes the balance without executing code, exactly as a
///      `SELFDESTRUCT` or a coinbase payment does) and it can still send `msg.value`. What it
///      cannot do is accept a refund.
contract NoReceiveBuyer {
    ZapRouter public immutable zap;

    constructor(ZapRouter z) {
        zap = z;
    }

    function buy(PoolKey calldata e, PoolKey calldata t, uint256 value, address to)
        external
        returns (uint256)
    {
        return zap.zapBuy{value: value}(_one(e), t, 1, to, type(uint256).max);
    }
}

/// @notice An ERC-20 that either keeps a slice of every transfer or hands the recipient extra.
///         Both are shapes `SettlementShortfall` has to decide about, and it takes the same branch
///         for each.
contract WeirdERC20 is ERC20 {
    uint256 public feeBps;
    uint256 public bonusBps;

    constructor() ERC20("Weird", "WEIRD") {}

    function setFeeBps(uint256 f) external {
        feeBps = f;
    }

    function setBonusBps(uint256 b) external {
        bonusBps = b;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        if (feeBps != 0) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, to, value - fee);
            if (fee != 0) super._update(from, address(0xdEaD), fee);
            return;
        }
        super._update(from, to, value);
        if (bonusBps != 0) {
            uint256 bonus = (value * bonusBps) / 10_000;
            if (bonus != 0) _mint(to, bonus);
        }
    }
}

/// @notice A hook a CALLER can point either PoolKey at, because BOTH keys are caller-supplied and
///         neither is checked against a registry.
///
/// @dev The two levers a v4 hook has over the SWAPPER's own delta, and they are not symmetric:
///
///      - `beforeSwap`'s SPECIFIED delta. `Hooks.sol:275` does `amountToSwap += hookDeltaSpecified`
///        and `:312` then does `swapDelta = swapDelta - hookDelta`, so the two cancel exactly and
///        the swapper's specified-currency debit is `amountSpecified` no matter what the hook
///        returns. `:276` refuses a value large enough to flip exact-input into exact-output.
///      - `afterSwap`'s UNSPECIFIED delta. Only `:312` applies here, with nothing on the other
///        side to cancel it, so the swapper's OUTPUT can be reduced past zero and INVERTED into a
///        debt.
///
///      The hook collects physically inside `afterSwap` and lets the credit that `:299-312`
///      creates a moment later cancel the debt the `take` just opened. That is the standard way a
///      returns-delta hook closes its own books, and it is what `FeeHook` does with `mint`.
contract EvilHook {
    IPoolManager public immutable manager;

    /// Charged on the SPECIFIED side out of `beforeSwap`. Positive = the hook takes.
    int128 public specifiedTake;
    /// Charged on the UNSPECIFIED side out of `afterSwap`. Positive = the hook takes.
    int128 public unspecifiedTake;

    /// Set to make the hook probe the router from inside the swap.
    ZapRouter public zap;

    uint256 public hits;
    bool public sawManagerUnlocked;
    bytes4 public nestedUnlockSelector;
    bytes4 public directCallbackSelector;

    constructor(IPoolManager m) {
        manager = m;
    }

    function arm(int128 s, int128 u) external {
        specifiedTake = s;
        unspecifiedTake = u;
    }

    function watch(ZapRouter z) external {
        zap = z;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        hits++;
        sawManagerUnlocked = TransientStateLibrary.isUnlocked(manager);

        if (address(zap) != address(0)) {
            // v4's `Lock` is ONE global transient flag, not a per-caller one, so every entry point
            // on the router is closed to anything running inside somebody else's unlock.
            try manager.unlock("") returns (bytes memory) {
                nestedUnlockSelector = bytes4(0);
            } catch (bytes memory e) {
                nestedUnlockSelector = bytes4(e);
            }
            // And the callback itself is keyed on the manager, not on "am I inside an unlock".
            try zap.unlockCallback("") returns (bytes memory) {
                directCallbackSelector = bytes4(0);
            } catch (bytes memory e) {
                directCallbackSelector = bytes4(e);
            }
        }

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedTake, 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        // Every hop this router builds is exact-input, so the SPECIFIED currency is the input.
        Currency spec = params.zeroForOne ? key.currency0 : key.currency1;
        Currency unspec = params.zeroForOne ? key.currency1 : key.currency0;

        if (specifiedTake > 0) manager.take(spec, address(this), uint256(uint128(specifiedTake)));
        if (unspecifiedTake > 0) manager.take(unspec, address(this), uint256(uint128(unspecifiedTake)));

        return (IHooks.afterSwap.selector, unspecifiedTake);
    }
}

// ===================================================================================================
// Audit surface #10 — ZapRouter
// ===================================================================================================

/// @notice What `test/ZapRouter.t.sol`'s 250 tests do not ask.
///
/// @dev The shipped suite proves the happy paths, the 8.5x settlement-order guard, the fee equality
///      and the truncation refusal. It never asks:
///
///      1. **whose** money the router is holding when it refunds — `_refundEth` sends
///         `address(this).balance` and the wrap path unwraps `balanceOf(address(this))`, and the
///         `receive()` guard both cite as their defence covers neither forced ether nor a bare
///         ERC-20 `transfer`;
///      2. whether `SettlementShortfall` is REACHABLE at all, on either leg;
///      3. what `-int256(amountIn)` does when the caller-supplied `amountIn` is above `2**255`;
///      4. what an arbitrary caller-chosen `recipient` can do with the full-gas callback it gets
///         from `take(ADDRESS_ZERO, …)` while the manager is still unlocked;
///      5. whether the just-landed `FeeHook.PriceLimitedBuyWouldOvercharge` (audit 09 §11) changes
///         which of the two contracts refuses a truncated hop 2. `ZapRouter` was written against
///         the PRE-remediation hook and has not been re-read against the new one.
///
///      Everything below runs in BOTH currency orderings, because every delta sign in the callback
///      flips with the ordering and a one-sided proof is half a proof.
abstract contract ZapAuditCases is ZapBase {

    using StateLibrary for IPoolManager;
    using stdStorage for StdStorage;

    // ===============================================================================================
    // Z-01 — value sitting in the router is paid to whoever calls `zapBuy` next
    // ===============================================================================================

    /// **FINDING Z-01.** `_refundEth` (`ZapRouter.sol:418-423`) sends `address(this).balance` to
    /// `msg.sender`. The docstring on `receive()` (`:139-141`) justifies that with
    ///
    /// > "Ether may arrive here from exactly two places … Anything else is refused, so
    /// > `_refundEth`'s 'send whatever is left to the caller' can never be pointed at somebody
    /// > else's money."
    ///
    /// **That claim is false.** `receive()` is not on the path for `SELFDESTRUCT`, for a block
    /// reward paid to `block.coinbase`, or for a balance pre-funded at a counterfactual CREATE2
    /// address — none of those execute code at the recipient. `vm.deal` models exactly that class.
    ///
    /// Measured consequence: the donation is handed in full to the first person to call `zapBuy`.
    /// **INVERTED — Z-01 IS FIXED.** `_refundEth(baseline)` now measures against the balance this
    /// call started with, so a buy hands back only its own unspent ether. Before: alice ended
    /// `before + 4 ether`, having collected a 5-ether donation she did not make. After: she pays
    /// exactly `msg.value` and the donation is untouched at 5 ether.
    function test_Z01_fixed_forcedEtherIsNotPaidToWhoeverCallsZapBuyNext() public {
        // A stranger cannot get ether in through `receive()`. That is the PRECONDITION which makes
        // this finding interesting rather than trivial.
        vm.deal(address(0xBEEF), 1 ether);
        vm.prank(address(0xBEEF));
        (bool ok,) = address(zap).call{value: 1 ether}("");
        assertFalse(ok, "precondition: the guarded path really is guarded");
        assertEq(address(zap).balance, 0, "precondition: the router starts empty");

        // Forced ether. No code runs at the recipient, so `receive()` never sees it.
        vm.deal(address(zap), 5 ether);
        assertEq(address(zap).balance, 5 ether, "precondition: the router is holding a donation");

        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 1 ether}(_one(ethKey), key, 1, alice, DEADLINE);

        assertGt(out, 0, "the buy delivered nothing, so this measures nothing");
        assertEq(before - alice.balance, 1 ether, "the buyer paid something other than msg.value");
        assertEq(address(zap).balance, 5 ether, "the donation moved");
    }

    /// **NEGATIVE CONTROL for Z-01.** Without the donation the same call costs exactly `msg.value`.
    /// If the assertion above were satisfied by anything other than the sweep, this fails too.
    function test_Z01b_control_withoutTheDonationTheBuyerPaysExactlyMsgValue() public {
        assertEq(address(zap).balance, 0, "precondition: the router starts empty");
        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 1 ether}(_one(ethKey), key, 1, alice, DEADLINE);
        assertGt(out, 0, "the buy delivered nothing, so this measures nothing");
        assertEq(before - alice.balance, 1 ether, "a buy on an empty router must cost exactly msg.value");
    }

    /// **INVERTED — FIXED.** A relayer forwarding somebody else's zap used to collect the donation
    /// (alice ended `+2 ether` on a 3-ether donation). Now neither party's ether moves except the
    /// caller's own `msg.value`.
    function test_Z01c_fixed_neitherTheSenderNorTheRecipientCollectsADonation() public {
        vm.deal(address(zap), 3 ether);
        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 1 ether}(_one(ethKey), key, 1, bob, DEADLINE);

        assertGt(out, 0, "the buy delivered nothing");
        assertEq(aliceBefore - alice.balance, 1 ether, "the caller's ether moved by more than msg.value");
        assertEq(bob.balance, bobBefore, "the recipient's ether balance moved");
        assertEq(address(zap).balance, 3 ether, "the donation moved");
    }

    /// A SELL does not sweep — `zapSell` never calls `_refundEth`. Worth pinning, because it means
    /// the donation sits there until somebody BUYS, which is the cheaper and more frequent call.
    function test_Z01d_aSellLeavesTheDonationWhereItIs() public {
        uint256 held = _zapBuy(alice, 10 ether);
        vm.deal(address(zap), 2 ether);

        vm.prank(alice);
        uint256 out = zap.zapSell(_one(ethKey), key, held / 2, 1, alice, DEADLINE);

        assertGt(out, 0, "the sell delivered nothing, so this proves nothing");
        assertEq(address(zap).balance, 2 ether, "a sell moved the donation");
    }

    /// **INVERTED — Z-01e IS FIXED, and this was the sharpest form of Z-01.**
    ///
    /// The refund used to fire on the exit path of EVERY `zapBuy`, including one that needed no
    /// refund, so one wei of forced ether — the cheapest write in the EVM — made `zapBuy` revert
    /// `EthRefundFailed` for **every contract caller without a payable fallback**: an aggregator,
    /// a vault, a smart account. The victim could not clear it; only somebody else's buy could.
    ///
    /// `_refundEth` now returns early when the balance has not risen above its baseline, so a
    /// donation produces no refund call at all and there is nothing to fail.
    function test_Z01e_fixed_aForcedDonationNoLongerBricksContractCallers() public {
        NoReceiveBuyer buyer = new NoReceiveBuyer(zap);
        vm.deal(address(buyer), 10 ether);

        // POSITIVE CONTROL: on an empty router the identical call works.
        uint256 snap = vm.snapshotState();
        uint256 out = buyer.buy(ethKey, key, 1 ether, alice);
        assertGt(out, 0, "the contract buyer could not buy even on an empty router");
        vm.revertToState(snap);

        // One wei. No code runs at the router, so `receive()` never gets a vote.
        vm.deal(address(zap), 1);

        uint256 stillWorks = buyer.buy(ethKey, key, 1 ether, alice);
        assertGt(stillWorks, 0, "one wei of forced ether still bricks a contract caller");

        uint256 again = buyer.buy(ethKey, key, 2 ether, alice);
        assertGt(again, 0, "the second call failed, so the brick is only delayed");

        assertEq(address(zap).balance, 1, "the donation was swept after all");
    }

    // ===============================================================================================
    // Z-02 — anything else that lands in the router is stranded forever
    // ===============================================================================================

    /// **INVERTED — Z-02 IS FIXED.** `recipient` was caller-supplied and never compared against
    /// `address(this)`, so a zap naming the router as its own recipient succeeded, cleared the
    /// slippage floor, and parked the launch tokens in a contract with no rescue function and no
    /// code path that moves a launch token out — permanently, confirmed against later traffic.
    /// It now reverts before the unlock cycle opens.
    function test_Z02_fixed_theRouterRefusesToBeItsOwnRecipient() public {
        assertEq(token.balanceOf(address(zap)), 0, "precondition: the router holds no launch tokens");

        vm.prank(alice);
        vm.expectRevert(ZapRouter.RecipientIsTheRouter.selector);
        zap.zapBuy{value: 5 ether}(_one(ethKey), key, 1, address(zap), DEADLINE);

        vm.prank(alice);
        vm.expectRevert(ZapRouter.RecipientIsTheRouter.selector);
        zap.zapSell(_one(ethKey), key, 1e18, 1, address(zap), DEADLINE);

        assertEq(token.balanceOf(address(zap)), 0, "the router still ended up holding launch tokens");

        // POSITIVE CONTROL: the same buy to any other recipient still works, so the guard is not
        // simply refusing everything.
        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 5 ether}(_one(ethKey), key, 1, bob, DEADLINE);
        assertGt(out, 0, "the guard broke an ordinary zap");
    }

    // ===============================================================================================
    // Z-03 — `SettlementShortfall`: reachable, and what it actually decides
    // ===============================================================================================

    /// **FINDING Z-03 (reachability).** The guard at `ZapRouter.sol:336-337` is the one piece of
    /// this contract the project notes single out as "do this in every router from now on". It has
    /// never been shown to fire. It fires here, on the settlement leg that pulls from the payer, as
    /// soon as the "launch token" does anything to the amount in flight.
    ///
    /// `tokenKey` is entirely caller-supplied, so the router will route through a pool whose token
    /// is fee-on-transfer, rebasing or reflecting, and this is the only thing between that and a
    /// silently mis-settled cycle.
    function test_Z03_settlementShortfallFiresOnAFeeOnTransferToken() public {
        (PoolKey memory weirdKey, WeirdERC20 weird) = _buildWeirdTokenRoute();

        // POSITIVE CONTROL FIRST: with the transfer fee off, the identical sell settles.
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 clean = zap.zapSell(_one(ethKey), weirdKey, 100e18, 1, alice, DEADLINE);
        assertGt(clean, 0, "the control sell produced no ether, so the negative case proves nothing");
        vm.revertToState(snap);

        weird.setFeeBps(100);
        vm.prank(alice);
        try zap.zapSell(_one(ethKey), weirdKey, 100e18, 1, alice, DEADLINE) returns (uint256) {
            revert("a fee-on-transfer settle was allowed through");
        } catch (bytes memory err) {
            assertEq(
                bytes4(err),
                ZapRouter.SettlementShortfall.selector,
                "the shortfall guard did not fire on a fee-on-transfer settle"
            );
            (uint256 handed, uint256 credited) = abi.decode(_body(err), (uint256, uint256));
            assertEq(handed, 100e18, "the guard reported the wrong handed-over amount");
            assertEq(credited, handed - (handed * 100) / 10_000, "the shortfall is not the transfer fee");
            emit log_named_uint("Z-03  handed over", handed);
            emit log_named_uint("Z-03  credited   ", credited);
        }
    }

    /// **FINDING Z-03b.** The comparison is `credited != owed`, not `credited < owed`. A token that
    /// credits the singleton MORE than it was handed takes the identical branch and reverts through
    /// an error whose two field names then read backwards: `SettlementShortfall(handedOver,
    /// credited)` with `credited > handedOver`.
    ///
    /// Refusing is the right call — a surplus leaves the router with an unclosed positive delta —
    /// but on a router the error text is the whole diagnostic an integrator gets.
    function test_Z03b_aSurplusRevertsThroughTheSameErrorWithTheFieldsReadingBackwards() public {
        (PoolKey memory weirdKey, WeirdERC20 weird) = _buildWeirdTokenRoute();

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 clean = zap.zapSell(_one(ethKey), weirdKey, 100e18, 1, alice, DEADLINE);
        assertGt(clean, 0, "the control sell produced nothing, so the negative case proves nothing");
        vm.revertToState(snap);

        weird.setBonusBps(100);
        vm.prank(alice);
        try zap.zapSell(_one(ethKey), weirdKey, 100e18, 1, alice, DEADLINE) returns (uint256) {
            revert("a reflecting settle was allowed through");
        } catch (bytes memory err) {
            assertEq(
                bytes4(err),
                ZapRouter.SettlementShortfall.selector,
                "a surplus took a different branch from a deficit"
            );
            (uint256 handed, uint256 credited) = abi.decode(_body(err), (uint256, uint256));
            assertGt(credited, handed, "this is not the surplus case");
            emit log_named_uint("Z-03b handed over", handed);
            emit log_named_uint("Z-03b credited   ", credited);
        }
    }

    // ===============================================================================================
    // Z-04 — `-int256(amountIn)` silently flips an exact-input sell into an exact-OUTPUT swap
    // ===============================================================================================

    /// **FINDING Z-04.** `_hop` (`ZapRouter.sol:388`) builds the swap with
    ///
    /// ```solidity
    /// amountSpecified: -int256(amountIn), // negative = exact input
    /// ```
    ///
    /// `int256(uint256)` is an unchecked wrapping conversion. For `amountIn > 2**255` it produces a
    /// negative `int256`, and negating that gives a POSITIVE `amountSpecified` — which in v4 means
    /// **exact output**, the opposite shape from the one the comment on that very line promises.
    ///
    /// `zapSell`'s `amountIn` is caller-supplied and unbounded. So one out-of-range number turns
    /// "sell exactly this many tokens" into "buy exactly this much pair currency, taking however
    /// many tokens that costs" — bounded only by the caller's balance and their allowance to the
    /// router, which every frontend sets to `type(uint256).max`.
    ///
    /// **`minAmountOut` cannot bound it.** The floor bounds the OUTPUT from below and the flipped
    /// shape produces MORE output, not less.
    /// **INVERTED — Z-04 IS FIXED.** `_hop` now bounds `amountIn` to `int128` max before negating,
    /// so no input can flip the swap shape. Before: passing `2**256 - 5e18` sold an amount the POOL
    /// chose, satisfied the floor with a LARGER output, and was bounded only by the caller's
    /// unlimited allowance. After: `AmountTooLarge`, before any swap runs.
    function test_Z04_fixed_anAmountInAbove2Pow255IsRefusedRatherThanFlippingTheSwapShape() public {
        uint256 held = _zapBuy(alice, 40 ether);
        assertGt(held, 5e18, "precondition: alice holds enough to expose the flip");

        // `2**256 - 5e18`. `int256` of that is `-5e18`; negating gives `+5e18`, which v4 would have
        // read as "exact output: 5e18 of the pair currency".
        uint256 poisoned = type(uint256).max - uint256(5e18) + 1;

        // POSITIVE CONTROL: an honest sell from the same state still works, so the guard is not
        // simply refusing everything.
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 honest = zap.zapSell(_one(ethKey), key, held / 100, 1, alice, DEADLINE);
        vm.revertToState(snap);
        assertGt(honest, 0, "precondition: an honest sell delivers something");

        uint256 tokensBefore = token.balanceOf(alice);

        vm.prank(alice);
        vm.expectPartialRevert(ZapRouter.AmountTooLarge.selector);
        zap.zapSell(_one(ethKey), key, poisoned, honest, alice, DEADLINE);

        assertEq(token.balanceOf(alice), tokensBefore, "the poisoned call still moved tokens");
    }

    /// **INVERTED — FIXED.** The other end of the same range. `type(uint256).max`, the "sell
    /// everything" idiom every frontend reaches for, used to become `amountSpecified = 1` — an
    /// exact-output swap for ONE unit. It failed closed on the floor, but only by accident. Both
    /// the swap and the QUOTE now refuse it by name, so a frontend gets a real error instead of a
    /// quote for a shape it never asked for.
    function test_Z04b_fixed_theSellEverythingIdiomIsRefusedByNameOnBothChannels() public {
        uint256 held = _zapBuy(alice, 20 ether);
        assertGt(held, 0, "precondition: alice holds tokens");

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 honest = zap.zapSell(_one(ethKey), key, held / 100, 1, alice, DEADLINE);
        vm.revertToState(snap);
        assertGt(honest, 0, "precondition: an honest sell delivers something");

        vm.prank(alice);
        vm.expectPartialRevert(ZapRouter.AmountTooLarge.selector);
        zap.quoteZapSell(_one(ethKey), key, type(uint256).max);

        vm.prank(alice);
        vm.expectPartialRevert(ZapRouter.AmountTooLarge.selector);
        zap.zapSell(_one(ethKey), key, type(uint256).max, honest, alice, DEADLINE);
    }

    /// **INVERTED — FIXED.** Exactly `2**255` used to be the one input that reverted, and it did so
    /// on a bare arithmetic panic naming nothing (negating `type(int256).min` is checked). It is
    /// now inside the same named bound as every other oversized amount.
    function test_Z04c_fixed_exactly2Pow255IsNamedRatherThanPanicking() public {
        uint256 held = _zapBuy(alice, 5 ether);
        assertGt(held, 0, "precondition: alice holds tokens, so the revert is about the amount");
        vm.prank(alice);
        vm.expectPartialRevert(ZapRouter.AmountTooLarge.selector);
        zap.zapSell(_one(ethKey), key, 1 << 255, 1, alice, DEADLINE);
    }

    // ===============================================================================================
    // Z-05 — SOUND: the router only ever pulls from `msg.sender`
    // ===============================================================================================

    /// The most dangerous shape a router can have is a `transferFrom` whose `from` a caller
    /// controls. `ZapRouter` has exactly one, at `:332`, and its `from` is `d.payer`, which `_run`
    /// hardcodes to `msg.sender` (`:258`). No argument, no default, no override.
    ///
    /// Proven adversarially rather than by inspection: bob has approved the router for everything
    /// and holds a real position; alice tries to sell it and cannot.
    function test_Z05_sound_noCallerCanMakeTheRouterPullFromSomebodyElse() public {
        uint256 bobsTokens = _zapBuy(bob, 30 ether);
        vm.prank(bob);
        token.approve(address(zap), type(uint256).max);
        assertGt(bobsTokens, 0, "precondition: bob holds a position");
        assertEq(
            token.allowance(bob, address(zap)),
            type(uint256).max,
            "precondition: bob's approval is unlimited, so only the payer check protects him"
        );
        assertEq(token.balanceOf(alice), 0, "precondition: alice holds none of this token");

        vm.prank(alice);
        vm.expectRevert();
        zap.zapSell(_one(ethKey), key, bobsTokens, 1, alice, DEADLINE);

        assertEq(token.balanceOf(bob), bobsTokens, "bob's position moved");

        // POSITIVE CONTROL: the same call from bob works, so the revert above is the payer binding
        // and not a broken harness.
        vm.prank(bob);
        uint256 out = zap.zapSell(_one(ethKey), key, bobsTokens / 2, 1, bob, DEADLINE);
        assertGt(out, 0, "bob could not sell his own position, so the negative case proves nothing");
    }

    // ===============================================================================================
    // Z-06 — the full-gas callback an arbitrary recipient gets inside the unlock cycle
    // ===============================================================================================

    /// **FINDING Z-06 (INFO) and the SOUND half of it.**
    ///
    /// On a sell, `take(ADDRESS_ZERO, d.recipient, …)` at `:351` hands native ether to a
    /// caller-chosen address with `call(gas(), …)` — all the gas, arbitrary code — while
    /// `Lock.isUnlocked()` is still true and `ZapRouter.unlockCallback` is mid-frame. That is a real
    /// capability and it is documented nowhere in the contract.
    ///
    /// What it does NOT buy is re-entry into the router.
    function test_Z06_sound_theRecipientCallbackCannotReenterTheRouter() public {
        ReentrantRecipient r = new ReentrantRecipient(IPoolManager(address(manager)), zap, address(pair));
        r.arm(0, 0, ethKey, key);

        uint256 held = _zapBuy(alice, 20 ether);
        assertGt(held, 0, "precondition: alice holds tokens to sell");

        vm.prank(alice);
        uint256 out = zap.zapSell(_one(ethKey), key, held / 2, 1, address(r), DEADLINE);

        assertGt(out, 0, "the sell delivered nothing, so the callback never ran");
        assertEq(r.hits(), 1, "the recipient was not called");
        assertTrue(r.sawManagerUnlocked(), "the callback ran with the manager LOCKED, so this proves nothing");
        assertTrue(r.nestedUnlockReverted(), "a nested unlock was allowed");
        assertEq(
            r.nestedUnlockSelector(),
            IPoolManager.AlreadyUnlocked.selector,
            "the nested unlock failed for the wrong reason"
        );
        assertTrue(r.nestedZapBuyReverted(), "a nested zapBuy was allowed");
        assertEq(address(r).balance, out, "the recipient did not keep the ether");
    }

    /// It DOES buy a fee-free flash loan out of the singleton without ever implementing
    /// `IUnlockCallback`. Not a new primitive — anybody can `unlock` for themselves — but the
    /// router hands the capability to an address of the caller's choosing, and that deserves to be
    /// written down rather than discovered.
    function test_Z06b_theRecipientCanFlashLoanTheSingletonFromInsideTheZapsUnlock() public {
        ReentrantRecipient r = new ReentrantRecipient(IPoolManager(address(manager)), zap, address(pair));
        uint256 loan = 1_000e18;
        r.arm(1, loan, ethKey, key);
        // Fund the repayment: a flash loan is only a loan if it is repaid from the borrower's side.
        pair.mint(address(r), loan);

        uint256 managerBefore = pair.balanceOf(address(manager));
        assertGt(managerBefore, loan, "precondition: the singleton holds more than the loan");

        uint256 held = _zapBuy(alice, 20 ether);
        vm.prank(alice);
        zap.zapSell(_one(ethKey), key, held / 2, 1, address(r), DEADLINE);

        assertEq(r.hits(), 1, "the callback never ran");
        assertEq(r.flashedBalance(), loan * 2, "the loan was not actually delivered mid-cycle");
        assertEq(pair.balanceOf(address(manager)), managerBefore, "the singleton did not end whole");
    }

    /// And the thing that stops it being theft: `unlock`'s `NonzeroDeltaCount` check is global and
    /// sign-agnostic, so a borrower who walks away takes the whole transaction down with them.
    function test_Z06c_sound_aRecipientThatDoesNotRepayRevertsTheWholeZap() public {
        ReentrantRecipient r = new ReentrantRecipient(IPoolManager(address(manager)), zap, address(pair));
        r.arm(2, 1_000e18, ethKey, key);

        uint256 held = _zapBuy(alice, 20 ether);
        assertGt(held, 0, "precondition: alice holds tokens to sell");
        uint256 managerBefore = pair.balanceOf(address(manager));

        vm.prank(alice);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        zap.zapSell(_one(ethKey), key, held / 2, 1, address(r), DEADLINE);

        assertEq(pair.balanceOf(address(manager)), managerBefore, "the singleton lost currency");
        assertEq(pair.balanceOf(address(r)), 0, "the borrower kept the loan");
    }

    // ===============================================================================================
    // Z-07 — the quote channel
    // ===============================================================================================

    /// **SOUND.** `quoteZapBuy` reverts at `:316`, before any `settle`, any `take` and any
    /// `transferFrom`. The revert unwinds the manager's transient state along with everything else,
    /// so a contract caller that CATCHES it gets the number and nothing else — no tokens, no lock
    /// left standing, no fee accrued, no price moved.
    function test_Z07_sound_aCaughtQuoteChangesNothingAtAll() public {
        QuoteCatcher q = new QuoteCatcher(zap);

        (uint160 launchPriceBefore,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        (uint160 ethPriceBefore,,,) = IPoolManager(address(manager)).getSlot0(ethKey.toId());
        uint256 feesBefore = hook.totalFeesTaken(poolId);
        // The manager's PAIR balance is the wrong quantity to watch: hop 1 takes pair out of the
        // singleton and hop 2 puts it straight back, so a zap nets to zero on it. Ether in and
        // launch tokens out are the two that actually move.
        uint256 managerEthBefore = address(manager).balance;
        uint256 managerTokenBefore = token.balanceOf(address(manager));

        q.quoteBuy(ethKey, key, 7 ether);

        assertTrue(q.caught(), "the quote did not revert with ZapQuote");
        assertGt(q.quoted(), 0, "the quote returned zero, so it proves nothing");
        assertEq(token.balanceOf(address(q)), 0, "the quoter received tokens");
        assertEq(address(q).balance, 0, "the quoter received ether");
        assertFalse(
            TransientStateLibrary.isUnlocked(IPoolManager(address(manager))), "the manager was left unlocked"
        );

        (uint160 launchPriceAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        (uint160 ethPriceAfter,,,) = IPoolManager(address(manager)).getSlot0(ethKey.toId());
        assertEq(launchPriceAfter, launchPriceBefore, "the quote moved the launch pool");
        assertEq(ethPriceAfter, ethPriceBefore, "the quote moved the ETH pool");
        assertEq(hook.totalFeesTaken(poolId), feesBefore, "the quote accrued a fee");
        assertEq(address(manager).balance, managerEthBefore, "the quote moved ether into the singleton");
        assertEq(token.balanceOf(address(manager)), managerTokenBefore, "the quote moved launch tokens");
    }

    /// **NEGATIVE CONTROL for Z-07.** The same trade, executed rather than quoted, moves every one
    /// of those quantities. Without this the test above would pass on a build whose quote executed
    /// nothing at all.
    function test_Z07b_control_theSameTradeExecutedMovesEveryQuantityTheQuoteDidNot() public {
        (uint160 launchPriceBefore,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        (uint160 ethPriceBefore,,,) = IPoolManager(address(manager)).getSlot0(ethKey.toId());
        uint256 feesBefore = hook.totalFeesTaken(poolId);
        uint256 managerEthBefore = address(manager).balance;
        uint256 managerTokenBefore = token.balanceOf(address(manager));

        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 7 ether}(_one(ethKey), key, 1, alice, DEADLINE);

        assertGt(out, 0, "the control trade delivered nothing");
        (uint160 launchPriceAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        (uint160 ethPriceAfter,,,) = IPoolManager(address(manager)).getSlot0(ethKey.toId());
        assertTrue(launchPriceAfter != launchPriceBefore, "the control did not move the launch pool");
        assertTrue(ethPriceAfter != ethPriceBefore, "the control did not move the ETH pool");
        assertGt(hook.totalFeesTaken(poolId), feesBefore, "the control charged no fee");
        assertGt(address(manager).balance, managerEthBefore, "the control moved no ether into the singleton");
        assertLt(token.balanceOf(address(manager)), managerTokenBefore, "the control moved no launch tokens");
    }

    /// The catch-and-decode path a frontend or an aggregator actually uses, end to end.
    function test_Z07c_sound_theCaughtQuoteEqualsWhatTheZapDelivers() public {
        QuoteCatcher q = new QuoteCatcher(zap);

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 actual = zap.zapBuy{value: 7 ether}(_one(ethKey), key, 1, alice, DEADLINE);
        vm.revertToState(snap);

        q.quoteBuy(ethKey, key, 7 ether);
        assertEq(q.quoted(), actual, "the quote is not what the zap delivers");
    }

    // ===============================================================================================
    // Z-08 — degenerate key shapes
    // ===============================================================================================

    /// **FINDING Z-08 (INFO).** The router never checks that the derived `launchToken` is not
    /// native ether. Passing the SAME key for both hops makes `launchToken == address(0)`, and the
    /// callback's three delta reads then collapse to two: `tokenDelta` and `ethDelta` become the
    /// same number, and both settle branches plus both `take` branches key off it.
    ///
    /// It fails closed — the token settle is a `safeTransferFrom` against `address(0)`, which
    /// `SafeERC20` refuses because there is no code there — but the caller gets an OpenZeppelin
    /// ERC-20 error about a call they never made, and the router is one sign-flip away from
    /// double-`take`ing the same delta.
    function test_Z08_aSelfRoutedKeyMakesTheLaunchTokenNativeEtherAndFailsOpaquely() public {
        vm.prank(alice);
        vm.expectRevert();
        zap.zapBuy{value: 1 ether}(_one(ethKey), ethKey, 1, alice, DEADLINE);

        // The property that actually matters: it keeps nothing on the way out.
        assertEq(address(zap).balance, 0, "the router kept ether after the degenerate call");
    }

    // ===============================================================================================
    // Z-09 — the native-leg `SettlementShortfall` guard cannot fire
    // ===============================================================================================

    /// **FINDING Z-09 (INFO).** `ZapRouter.sol:344-346`:
    ///
    /// ```solidity
    /// poolManager.sync(CurrencyLibrary.ADDRESS_ZERO);
    /// uint256 credited = poolManager.settle{value: owed}();
    /// if (credited != owed) revert SettlementShortfall(owed, credited);
    /// ```
    ///
    /// `PoolManager._settle` short-circuits to `paid = msg.value` for the native currency and never
    /// reads a balance (`PoolManager.sol:353-354`). `msg.value` here IS `owed`, so `credited` is
    /// `owed` by construction and the guard cannot fire. Harmless — and the docstring three lines
    /// above says exactly why the native leg is structurally immune — but the guard beside it reads
    /// as a live defence and is not one.
    ///
    /// Measured rather than argued: the probe settles amounts that bear no relationship to any
    /// delta and is credited exactly what it sent, every time.
    function test_Z09_nativeSettleAlwaysCreditsMsgValueSoTheGuardIsUnreachable() public {
        NativeSettleProbe p = new NativeSettleProbe(IPoolManager(address(manager)));
        vm.deal(address(p), 10 ether);

        uint256[4] memory amounts = [uint256(1), 1 ether, 3 ether, 7 wei];
        for (uint256 i = 0; i < amounts.length; ++i) {
            p.probe(amounts[i]);
            assertEq(p.credited(), amounts[i], "native settle credited something other than msg.value");
        }
    }

    // ===============================================================================================
    // Z-10 — the remediation intersection: who refuses a truncated hop 2 now?
    // ===============================================================================================

    /// **FINDING Z-10.** `ZapRouter` was written against the PRE-remediation `FeeHook`. Audit 09
    /// §11 added `PriceLimitedBuyWouldOvercharge`, which refuses an exact-input BUY whose curve did
    /// not consume `requested - fee`.
    ///
    /// A zap's hop 2 IS an exact-input buy with the extreme price limit, so on any pool carrying
    /// `FeeHook` the hook now refuses a truncated hop 2 **before** `ZapRouter`'s own
    /// `IntermediateLegDidNotNet` guard can read the residual. The BUY half of that guard is now
    /// dead code on exactly the pools this product ships.
    ///
    /// Both refuse and nothing is lost — but it changes which contract owns the failure and which
    /// error a trader sees, and the router's docstring at `:49-57` still claims ownership.
    function test_Z10_aTruncatedHopTwoBuyIsNowRefusedByTheHookNotByTheRouter() public {
        PoolKey memory narrow = _narrowHookedLaunchPool();

        vm.prank(alice);
        try zap.zapBuy{value: 200 ether}(_one(ethKey), narrow, 1, alice, DEADLINE) returns (uint256) {
            revert("a hop 2 that cannot fill was allowed through");
        } catch (bytes memory err) {
            // A hook revert arrives wrapped by `CustomRevert.bubbleUpAndRevertWith`, so match on
            // the presence of the selector in the payload rather than on the outermost four bytes.
            assertTrue(
                _contains(err, FeeHook.PriceLimitedBuyWouldOvercharge.selector),
                "the hook did not refuse the truncated buy"
            );
            assertFalse(
                _contains(err, ZapRouter.IntermediateLegDidNotNet.selector),
                "the router's own guard fired, so the hook did not supersede it"
            );
        }
        assertEq(address(zap).balance, 0, "the router kept ether after the refusal");
    }

    /// **The control that shows the router's guard is still the only thing standing anywhere
    /// else.** The identical shape through an UNHOOKED hop 2 — a second pool on the same two
    /// currencies with `hooks: address(0)` — reaches `IntermediateLegDidNotNet` with a positive
    /// pair residual, which is the case `ZapRouter` was built for.
    function test_Z10b_theSameShapeOnAnUnhookedHopTwoStillHitsTheRoutersOwnGuard() public {
        PoolKey memory narrow = _narrowUnhookedLaunchPool();

        vm.prank(alice);
        try zap.zapBuy{value: 200 ether}(_one(ethKey), narrow, 1, alice, DEADLINE) returns (uint256) {
            revert("a hop 2 that cannot fill was allowed through");
        } catch (bytes memory err) {
            assertEq(
                bytes4(err),
                ZapRouter.IntermediateLegDidNotNet.selector,
                "the router's own netting guard did not fire on an unhooked route"
            );
            int256 residual = abi.decode(_body(err), (int256));
            assertGt(residual, 0, "the residual is not unspendable pair currency");
            emit log_named_int("Z-10b unspendable pair residual", residual);
        }
    }

    /// And the new hook revert must not fire on traffic that DOES fill, or the product is bricked.
    function test_Z10c_sound_anOrdinaryZapIsUnaffectedByTheNewHookRevert() public {
        uint256 out = _zapBuy(alice, 10 ether);
        assertGt(out, 0, "an ordinary zap stopped working");
        uint256 held = token.balanceOf(alice);
        vm.prank(alice);
        uint256 back = zap.zapSell(_one(ethKey), key, held / 2, 1, alice, DEADLINE);
        assertGt(back, 0, "an ordinary sell stopped working");
    }

    // ===============================================================================================
    // Z-11 — the two-hop shape doubles the surface an MEV bot gets to move
    // ===============================================================================================

    /// **FINDING Z-11 (LOW, measured).** `TradeRouter` exposes a buyer to one pool. `ZapRouter`
    /// exposes them to two, and `minAmountOut` is end-to-end only — there is no per-hop floor,
    /// unlike the installed periphery's `IV4Router.ExactInputParams.minHopPriceX36`.
    ///
    /// End-to-end IS sufficient for correctness: the route is atomic, so bounding the final output
    /// bounds everything. What it is not is neutral for MEV. Measured as the VICTIM's loss in their
    /// own output units, sandwiched versus not, from the same starting state, at equal attacker
    /// size — which is the only apples-to-apples comparison available between a one-pool route and
    /// a two-pool one.
    function test_Z11_sandwichingAZapCostsTheVictimMoreThanSandwichingTheSingleHop() public {
        uint256 victimEth = 20 ether;

        // How much pair currency `victimEth` is worth, so the single-hop victim trades the same
        // size. Taken from a snapshot so the measurement itself leaves no trace.
        uint256 snap0 = vm.snapshotState();
        uint256 victimPair = _hopOneAlone(alice, victimEth);
        vm.revertToState(snap0);
        assertGt(victimPair, 0, "precondition: hop 1 prices something");

        // --- Route A: the victim already holds the pair currency. One pool is exposed.
        uint256 snapA1 = vm.snapshotState();
        pair.mint(alice, victimPair);
        vm.prank(alice);
        uint256 aCalm = tradeRouter.swap(key, _buyIsZeroForOne(), victimPair, 0, alice);
        vm.revertToState(snapA1);

        uint256 snapA2 = vm.snapshotState();
        pair.mint(alice, victimPair);
        uint256 aSandwiched = _sandwichSingleHop(victimPair);
        vm.revertToState(snapA2);

        // --- Route B: the victim zaps. Two pools are exposed.
        uint256 snapB = vm.snapshotState();
        vm.prank(alice);
        uint256 bCalm = zap.zapBuy{value: victimEth}(_one(ethKey), key, 1, alice, DEADLINE);
        vm.revertToState(snapB);

        uint256 bSandwiched = _sandwichZap(victimEth);

        assertGt(aCalm, 0, "the single-hop control delivered nothing");
        assertGt(bCalm, 0, "the zap control delivered nothing");
        assertGt(aCalm, aSandwiched, "the single-hop sandwich cost the victim nothing");
        assertGt(bCalm, bSandwiched, "the zap sandwich cost the victim nothing");

        uint256 aLossBps = ((aCalm - aSandwiched) * 10_000) / aCalm;
        uint256 bLossBps = ((bCalm - bSandwiched) * 10_000) / bCalm;
        emit log_named_uint("Z-11 victim loss, single hop (bps)", aLossBps);
        emit log_named_uint("Z-11 victim loss, zap        (bps)", bLossBps);
        assertGt(bLossBps, aLossBps, "the two-hop route was not the more expensive one to be sandwiched in");
    }

    /// **FINDING Z-11b (INFO, measured).** The other half of Z-11: the extra hop taxes the
    /// ATTACKER too. A sandwicher has to round-trip through hop 1 as well, paying that pool's fee
    /// twice and its impact twice, on top of the launch pool's. So the zap is a worse route to
    /// sandwich FROM even though it is a worse route to be sandwiched IN.
    ///
    /// Both quantities are dimensionless loss fractions, which is the only way to compare an
    /// ether-denominated round trip against a pair-denominated one.
    function test_Z11b_aZapRoundTripIsStrictlyMoreLossyThanTheSingleHopRoundTrip() public {
        uint256 ethIn = 10 ether;

        // Route B: ETH -> pair -> token -> pair -> ETH.
        uint256 snapB = vm.snapshotState();
        vm.prank(alice);
        uint256 gotB = zap.zapBuy{value: ethIn}(_one(ethKey), key, 1, alice, DEADLINE);
        assertGt(gotB, 0, "the zap round trip bought nothing");
        vm.prank(alice);
        uint256 backB = zap.zapSell(_one(ethKey), key, gotB, 1, alice, DEADLINE);
        vm.revertToState(snapB);
        assertGt(backB, 0, "the zap round trip sold nothing");

        // Route A: the same launch pool only, entered and left in the pair currency. Sized so the
        // launch pool sees the same order — hop 1 priced from the SAME starting state.
        uint256 snap0 = vm.snapshotState();
        uint256 pairIn = _hopOneAlone(alice, ethIn);
        vm.revertToState(snap0);
        assertGt(pairIn, 0, "hop 1 prices nothing, so the comparison has no size");

        pair.mint(alice, pairIn);
        uint256 pairBefore = pair.balanceOf(alice);
        vm.prank(alice);
        uint256 gotA = tradeRouter.swap(key, _buyIsZeroForOne(), pairIn, 0, alice);
        assertGt(gotA, 0, "the single-hop round trip bought nothing");
        vm.prank(alice);
        tradeRouter.swap(key, !_buyIsZeroForOne(), gotA, 0, alice);
        uint256 backA = pair.balanceOf(alice) - (pairBefore - pairIn);

        uint256 lossA = ((pairIn - backA) * 10_000) / pairIn;
        uint256 lossB = ((ethIn - backB) * 10_000) / ethIn;
        emit log_named_uint("Z-11b round-trip loss, single hop (bps)", lossA);
        emit log_named_uint("Z-11b round-trip loss, zap        (bps)", lossB);
        assertGt(lossB, lossA, "the zap round trip was not the more expensive one");
    }

    // ===============================================================================================
    // Z-15 — both PoolKeys are caller-supplied, so hop 2 can carry an ARBITRARY hook
    // ===============================================================================================

    /// **FINDING Z-15.** Neither key is checked against `PairRegistry`, `FeeHook`, or anything
    /// else, so a caller can route hop 2 through a pool carrying a hook they wrote.
    ///
    /// `Hooks.afterSwap` (`Hooks.sol:299-312`) adds the hook's returned int128 to
    /// `hookDeltaUnspecified` and then does `swapDelta = swapDelta - hookDelta`, with nothing on
    /// the other side to cancel it. A hook that claims more of the output than the curve produced
    /// therefore drives the SWAPPER's delta on the output currency NEGATIVE.
    ///
    /// `ZapRouter` does not defend either end of that:
    ///
    /// 1. `:311`/`:314` do `uint256(tokenDelta)` on a raw `int256`. A negative delta wraps to a
    ///    number above `2**255`, which sails past every `minAmountOut` a caller can express.
    /// 2. `:329` then treats the negative delta as a debt and pays it with
    ///    `safeTransferFrom(d.payer, …)` — on a BUY, against the unlimited approval every frontend
    ///    sets. There is no "a buy must never settle the launch token" assertion anywhere.
    ///
    /// Result: a call named `zapBuy` takes the caller's ether AND their launch tokens, delivers
    /// nothing, and returns a success value of roughly 1.16e77.
    function test_Z15_aCallerSuppliedHopTwoHookTurnsABuyIntoADebitOfTheBuyersTokens() public {
        uint256 held = _zapBuy(alice, 30 ether);
        assertGt(held, 0, "precondition: the buyer holds launch tokens the router could pull");
        assertEq(
            token.allowance(alice, address(zap)),
            type(uint256).max,
            "precondition: the approval a frontend sets is what this spends"
        );

        (PoolKey memory evilKey, EvilHook evil) = _evilLaunchPool();

        // What the identical route delivers with the hook idle. Everything below is measured
        // against it, so nothing here depends on a number this test invented.
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 honest = zap.zapBuy{value: 1 ether}(_one(ethKey), evilKey, 1, alice, DEADLINE);
        vm.revertToState(snap);
        assertGt(honest, 0, "the idle route delivered nothing, so the armed case proves nothing");

        // The hook claims twice what the curve produced.
        evil.arm(0, int128(int256(honest * 2)));

        uint256 tokensBefore = token.balanceOf(alice);
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 1 ether}(_one(ethKey), evilKey, 1, alice, DEADLINE);

        assertGt(out, 1 << 255, "amountOut is not the wrapped negative delta, so the cast held");
        assertLt(token.balanceOf(alice), tokensBefore, "the 'buy' did not debit the buyer's tokens");
        assertEq(ethBefore - alice.balance, 1 ether, "the buyer did not also pay their ether");

        emit log_named_uint("Z-15 launch tokens taken FROM the buyer", tokensBefore - token.balanceOf(alice));
        emit log_named_uint("Z-15 ether taken FROM the buyer        ", ethBefore - alice.balance);
        emit log_named_uint("Z-15 launch tokens delivered           ", 0);
        emit log_named_uint("Z-15 amountOut the router reported     ", out);
    }

    /// **SOUND — Z-15b, and it is the invariant `IntermediateLegDidNotNet` actually rests on.**
    ///
    /// The other lever is bounded. On an exact-input hop the swapper's debit in the SPECIFIED
    /// currency is exactly `amountSpecified` whatever the hook charges, because `Hooks.sol:275`
    /// adds the hook's delta to the amount handed to the curve and `:312` subtracts the same
    /// number back off the swapper. `FeeHook` is one instance of that; this proves it for an
    /// arbitrary one, at four times `FeeHook`'s rate.
    ///
    /// Non-vacuity: the hook must have actually collected, or this is the idle configuration
    /// under a different name.
    function test_Z15b_sound_anExactInputHopDebitsExactlyAmountInWhateverTheHookCharges() public {
        uint256 held = _zapBuy(alice, 30 ether);
        (PoolKey memory evilKey, EvilHook evil) = _evilLaunchPool();

        uint256 sell = held / 10;
        assertGt(sell, 0, "precondition: there is something to sell");

        // A quarter of the input, out of the same `beforeSwap` slot `FeeHook` uses for 3%.
        int128 grab = int128(int256(sell / 4));
        assertGt(grab, 0, "precondition: the hook is charging something");
        evil.arm(grab, 0);

        uint256 tokensBefore = token.balanceOf(alice);
        vm.prank(alice);
        uint256 out = zap.zapSell(_one(ethKey), evilKey, sell, 1, alice, DEADLINE);

        assertGt(out, 0, "the sell through the hooked route delivered nothing");
        assertEq(
            tokensBefore - token.balanceOf(alice),
            sell,
            "the router debited something other than the amountIn the caller named"
        );
        assertEq(
            token.balanceOf(address(evil)),
            uint256(uint128(grab)),
            "the hook collected nothing, so this is the idle configuration"
        );
    }

    /// **The negative control for Z-15b, and it names the line the bound lives on.** Push the
    /// specified-side charge past the whole input and `Hooks.sol:276` refuses the swap outright
    /// with `HookDeltaExceedsSwapAmount` rather than letting exact-input become exact-output.
    ///
    /// Without this the claim above would be "the hook happened not to take more", not "it
    /// cannot".
    function test_Z15c_control_aSpecifiedChargeLargerThanTheInputIsRefusedByV4Itself() public {
        uint256 held = _zapBuy(alice, 30 ether);
        (PoolKey memory evilKey, EvilHook evil) = _evilLaunchPool();

        uint256 sell = held / 10;
        evil.arm(int128(int256(sell + 1)), 0);

        uint256 tokensBefore = token.balanceOf(alice);
        vm.prank(alice);
        try zap.zapSell(_one(ethKey), evilKey, sell, 1, alice, DEADLINE) returns (uint256) {
            revert("a hook charge larger than the whole input was allowed through");
        } catch (bytes memory err) {
            assertTrue(
                _contains(err, Hooks.HookDeltaExceedsSwapAmount.selector),
                "the swap failed for some other reason than the specified-delta bound"
            );
        }
        assertEq(token.balanceOf(alice), tokensBefore, "the seller was debited by a refused swap");
    }

    /// **SOUND — Z-15d.** The same arbitrary hook, running inside the router's own unlock cycle,
    /// gets no way back into the router. v4's `Lock` is one GLOBAL transient flag
    /// (`PoolManager.sol:105`), so `unlock` is closed to everybody, and `unlockCallback` is keyed
    /// on `msg.sender == poolManager` rather than on "am I inside an unlock".
    function test_Z15d_sound_aMaliciousHopTwoHookCannotReenterTheRouter() public {
        (PoolKey memory evilKey, EvilHook evil) = _evilLaunchPool();
        evil.watch(zap);

        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 2 ether}(_one(ethKey), evilKey, 1, alice, DEADLINE);

        assertGt(out, 0, "the route did not execute, so the hook never ran");
        assertGt(evil.hits(), 0, "the hook was never called");
        assertTrue(evil.sawManagerUnlocked(), "the hook ran with the manager LOCKED, so this proves nothing");
        assertEq(
            evil.nestedUnlockSelector(),
            IPoolManager.AlreadyUnlocked.selector,
            "a nested unlock from inside the hook was allowed"
        );
        assertEq(
            evil.directCallbackSelector(),
            ZapRouter.NotPoolManager.selector,
            "the hook drove the router's callback directly"
        );
        assertEq(address(zap).balance, 0, "the router kept ether");
        assertEq(pair.balanceOf(address(zap)), 0, "the router kept pair currency");
    }

    // ===============================================================================================
    // Z-16 — the other side of the audit-09 remediation: the max-wallet cap now bounds a HOLDING
    // ===============================================================================================

    /// **FINDING Z-16.** Audit 09 changed `LaunchToken._update` from "cap the pool's outbound
    /// transfer" to "cap EVERY inbound transfer" (`LaunchToken.sol:198`). A zap buy delivers with
    /// `poolManager.take(launchToken, recipient, …)`, which is an inbound ERC-20 transfer to a
    /// non-exempt address, so it is capped — correctly.
    ///
    /// **The quote channel is not.** `unlockCallback` reverts `ZapQuote` at `:316`, which is
    /// BEFORE the `take` at `:350`. So `quoteZapBuy` returns a healthy number for a trade that can
    /// never execute, and the failure a caller then meets is an OpenZeppelin-shaped
    /// `MaxWalletExceeded` bubbled out of a hook-free ERC-20 transfer three frames down.
    ///
    /// Nothing in the whole ZapRouter suite exercises this: `FeeHookHarness` initialises every
    /// launch token with `maxWallet_: 0`. `maxWallet` is written once in `initialize` and never
    /// again, so writing the slot reproduces exactly the state a capped launch is in.
    function test_Z16_theQuoteChannelDoesNotModelTheMaxWalletCap() public {
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 fair = zap.zapBuy{value: 10 ether}(_one(ethKey), key, 1, alice, DEADLINE);
        vm.revertToState(snap);
        assertGt(fair, 0, "the uncapped buy delivered nothing, so this measures nothing");

        uint256 cap = fair / 2;
        _armMaxWallet(cap);
        assertEq(token.balanceOf(alice), 0, "precondition: the buyer is not already at the cap");

        // The quote is happy, and it quotes a number the cap forbids.
        vm.prank(alice);
        try zap.quoteZapBuy(_one(ethKey), key, 10 ether) {
            revert("quoteZapBuy returned instead of reverting");
        } catch (bytes memory err) {
            assertEq(bytes4(err), ZapRouter.ZapQuote.selector, "wrong error from the quote");
            uint256 quoted = abi.decode(_body(err), (uint256));
            assertEq(quoted, fair, "the quote is not the uncapped number");
            assertGt(quoted, cap, "the quote does not exceed the cap, so this proves nothing");
        }

        // The execution is not, and the error names neither the router nor the cap's own guard.
        vm.prank(alice);
        try zap.zapBuy{value: 10 ether}(_one(ethKey), key, 1, alice, DEADLINE) returns (uint256) {
            revert("a buy over the max-wallet cap settled");
        } catch (bytes memory err) {
            assertTrue(
                _contains(err, LaunchToken.MaxWalletExceeded.selector),
                "the cap did not refuse the zapped buy"
            );
            assertFalse(
                _contains(err, ZapRouter.TooLittleReceived.selector),
                "the router saw the cap coming, which would make this a non-finding"
            );
        }
        assertEq(address(zap).balance, 0, "the router kept ether after the refusal");
    }

    /// **The positive control for Z-16.** With the cap set ABOVE what the buy delivers, the
    /// identical call goes through — so the revert above is the cap binding and not the harness
    /// being broken by the storage write.
    function test_Z16b_control_theSameBuyUnderTheCapStillExecutes() public {
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 fair = zap.zapBuy{value: 10 ether}(_one(ethKey), key, 1, alice, DEADLINE);
        vm.revertToState(snap);

        _armMaxWallet(fair * 2);

        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 10 ether}(_one(ethKey), key, 1, alice, DEADLINE);
        assertEq(out, fair, "a buy under the cap did not deliver what the uncapped one did");
        assertEq(token.balanceOf(alice), out, "the buyer did not receive the tokens");
    }

    /// **SOUND — Z-16c.** The property that keeps a cap from being a honeypot survives the zap: a
    /// sell moves tokens INTO the PoolManager, which `initialize` exempts, so no cap value can
    /// block an exit. Checked at a cap of ONE WEI, which is the most hostile setting that exists.
    function test_Z16c_sound_noCapValueCanBlockASellThroughTheZap() public {
        uint256 held = _zapBuy(alice, 20 ether);
        assertGt(held, 0, "precondition: the seller holds a position");

        _armMaxWallet(1);

        // Non-vacuity: at this cap a BUY of any size is impossible, so the sell below is genuinely
        // running against an armed cap rather than a dormant one.
        //
        // The cap's revert arrives inside an ERC-7751 `WrappedError` — the manager's `take` is an
        // ERC-20 `transfer` and `Currency.transfer` bubbles the failure with context — so neither
        // `expectRevert` nor `expectPartialRevert` matches it. Search the payload.
        vm.prank(bob);
        try zap.zapBuy{value: 1 ether}(_one(ethKey), key, 1, bob, DEADLINE) returns (uint256) {
            revert("a buy under a one-wei cap settled, so the cap is not armed");
        } catch (bytes memory err) {
            assertTrue(
                _contains(err, LaunchToken.MaxWalletExceeded.selector),
                "the buy failed for some reason other than the cap"
            );
        }

        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        uint256 out = zap.zapSell(_one(ethKey), key, held, 1, alice, DEADLINE);

        assertGt(out, 0, "a one-wei cap blocked the exit");
        assertEq(alice.balance - ethBefore, out, "the seller was not paid");
        assertEq(token.balanceOf(alice), 0, "the whole position did not leave");
    }

    // ===============================================================================================
    // Helpers
    // ===============================================================================================

    /// @dev A pool on the SAME two currencies as the launch pool, carrying a hook the caller
    ///      controls. Different fee and tick spacing, so a different PoolId.
    function _evilLaunchPool() internal returns (PoolKey memory k, EvilHook evil) {
        // 0x00CC = BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA,
        // which `Hooks.isValidHookAddress` accepts against a static fee.
        address addr = address(uint160(uint256(0xBADF) << 144 | 0x00CC));
        deployCodeTo("ZapAudit.t.sol:EvilHook", abi.encode(address(manager)), addr);
        evil = EvilHook(addr);

        k = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(addr)
        });
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));

        pair.mint(address(this), 10_000_000e18);
        token.approve(address(lpRouter), type(uint256).max);
        pair.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(10),
                tickUpper: TickMath.maxUsableTick(10),
                liquidityDelta: 500_000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev `maxWallet` is set once in `initialize` and has no setter, so a storage write is the
    ///      only way to reach the state a capped launch ships in. Asserted afterwards, because a
    ///      silently failed write would make every cap test vacuously green.
    function _armMaxWallet(uint256 cap) internal {
        stdstore.target(address(token)).sig("maxWallet()").checked_write(cap);
        assertEq(token.maxWallet(), cap, "the cap was not actually armed");
    }

    /// @dev Builds a fee-on-transfer / reflecting "launch token" plus a live pool for it against
    ///      the pair currency, alice's position and her approval. `ETH -> pair -> WEIRD` is a route
    ///      the router accepts from any caller, because `tokenKey` is entirely caller-supplied.
    function _buildWeirdTokenRoute() internal returns (PoolKey memory k, WeirdERC20 weird) {
        weird = new WeirdERC20();
        weird.mint(address(this), 100_000_000e18);
        weird.mint(alice, 10_000e18);

        (Currency c0, Currency c1) = address(weird) < address(pair)
            ? (Currency.wrap(address(weird)), Currency.wrap(address(pair)))
            : (Currency.wrap(address(pair)), Currency.wrap(address(weird)));

        k = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));

        pair.mint(address(this), 100_000_000e18);
        weird.approve(address(lpRouter), type(uint256).max);
        pair.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 1_000_000e18,
                salt: bytes32(0)
            }),
            ""
        );

        vm.prank(alice);
        weird.approve(address(zap), type(uint256).max);
    }

    /// @dev A second `FeeHook` pool on the same two currencies, opened at 1:1 with a NARROW band so
    ///      a large hop 2 exhausts it. A different tick spacing means a different PoolId.
    function _narrowHookedLaunchPool() internal returns (PoolKey memory k) {
        k = PoolKey({currency0: key.currency0, currency1: key.currency1, fee: 0, tickSpacing: 10, hooks: key.hooks});
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
            , openingWindow: 0, openingFeeBps: 0})
        );
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
        _seedNarrow(k);
    }

    /// @dev The same narrow shape with no hook on it at all.
    function _narrowUnhookedLaunchPool() internal returns (PoolKey memory k) {
        k = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
        _seedNarrow(k);
    }

    function _seedNarrow(PoolKey memory k) internal {
        token.approve(address(lpRouter), type(uint256).max);
        pair.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: 2_000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Front-run, victim, back-run, all against the launch pool only. Returns what the VICTIM
    ///      received. Assumes alice already holds `victimPairIn`.
    function _sandwichSingleHop(uint256 victimPairIn) internal returns (uint256 victimOut) {
        pair.mint(bob, victimPairIn);
        vm.prank(bob);
        pair.approve(address(tradeRouter), type(uint256).max);
        vm.prank(bob);
        token.approve(address(tradeRouter), type(uint256).max);

        vm.prank(bob);
        uint256 got = tradeRouter.swap(key, _buyIsZeroForOne(), victimPairIn, 0, bob);

        vm.prank(alice);
        victimOut = tradeRouter.swap(key, _buyIsZeroForOne(), victimPairIn, 0, alice);

        vm.prank(bob);
        tradeRouter.swap(key, !_buyIsZeroForOne(), got, 0, bob);
    }

    /// @dev The same sandwich, but the attacker front-runs BOTH hops because the victim is zapping.
    ///      Returns what the VICTIM received.
    function _sandwichZap(uint256 victimEthIn) internal returns (uint256 victimOut) {
        vm.deal(bob, 100_000 ether);
        vm.prank(bob);
        token.approve(address(zap), type(uint256).max);

        vm.prank(bob);
        zap.zapBuy{value: victimEthIn}(_one(ethKey), key, 1, bob, DEADLINE);

        vm.prank(alice);
        victimOut = zap.zapBuy{value: victimEthIn}(_one(ethKey), key, 1, alice, DEADLINE);

        uint256 held = token.balanceOf(bob);
        vm.prank(bob);
        zap.zapSell(_one(ethKey), key, held, 1, bob, DEADLINE);
    }

    /// @dev `vm.expectRevert(selector)` compares the WHOLE payload in this forge, and a hook revert
    ///      arrives wrapped by `CustomRevert.bubbleUpAndRevertWith`. Search the payload instead.
    function _contains(bytes memory haystack, bytes4 needle) internal pure returns (bool) {
        if (haystack.length < 4) return false;
        for (uint256 i = 0; i + 4 <= haystack.length; ++i) {
            if (
                haystack[i] == needle[0] && haystack[i + 1] == needle[1] && haystack[i + 2] == needle[2]
                    && haystack[i + 3] == needle[3]
            ) return true;
        }
        return false;
    }
}

contract ZapAuditTokenIsCurrency0Test is ZapAuditCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract ZapAuditTokenIsCurrency1Test is ZapAuditCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

// ===================================================================================================
// The wrap path — the pair IS wrapped ether, so hop 1 never happens
// ===================================================================================================

/// @dev Same swap-the-pair's-code trick the shipped suite uses: `MockWETH9` adds no storage over
///      `MockERC20`, so `deployCodeTo` gives the existing pair a real `deposit`/`withdraw` while
///      every balance, allowance and the launch token's `payoutToken` wiring survives untouched.
abstract contract ZapAuditWrapCases is ZapBase {

    using StateLibrary for IPoolManager;

    /// The shipped pool-routing behaviour (`weth == address(0)`), kept as the paired control.
    ZapRouter internal poolRouter;

    function setUp() public virtual override {
        super.setUp();
        poolRouter = zap;

        deployCodeTo(
            "ZapRouter.t.sol:MockWETH9", abi.encode("Wrapped Ether", "WETH", uint8(18)), address(pair)
        );
        vm.deal(address(pair), 1_000_000 ether);

        zap = new ZapRouter(IPoolManager(address(manager)), address(pair));
        vm.startPrank(alice);
        token.approve(address(zap), type(uint256).max);
        vm.stopPrank();
    }

    /// **FINDING Z-01f — the wrap path has a second, cheaper mouth.**
    ///
    /// `zapBuy` unwraps `IERC20(weth).balanceOf(address(this))` at `:188` — the router's ENTIRE
    /// wrapped-ether balance, not the dust this particular call created — and then `_refundEth`
    /// hands the lot to `msg.sender`.
    ///
    /// Putting wrapped ether into the router needs no forced-ether trick and no callback at all: a
    /// plain ERC-20 `transfer` does it. A mis-typed address, a bot's misrouted rebalance, or
    /// anybody who names the router as their `recipient` on a WETH-output route all end here, and
    /// the next WETH-paired buyer collects it as native ether.
    /// **INVERTED — Z-01f IS FIXED.** `zapBuy` now records the wrapped balance BEFORE it deposits
    /// and unwraps only the excess over that baseline, so a donation is never converted or paid
    /// out. Before: alice ended `before + 2 ether` on a 3-ether mis-sent transfer and the router
    /// was emptied. After: she pays exactly `msg.value` and the 3 ether stays put.
    function test_Z01f_fixed_donatedWrappedEtherIsLeftAloneByTheNextBuyer() public {
        assertEq(pair.balanceOf(address(zap)), 0, "precondition: the router holds no wrapped ether");
        assertEq(address(zap).balance, 0, "precondition: the router holds no ether");

        pair.mint(address(zap), 3 ether);
        assertEq(pair.balanceOf(address(zap)), 3 ether, "precondition: the donation landed");

        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 1 ether}(_one(ethKey), key, 1, alice, DEADLINE);

        assertGt(out, 0, "the wrapped buy delivered nothing, so this measures nothing");
        assertEq(before - alice.balance, 1 ether, "the buyer paid something other than msg.value");
        assertEq(pair.balanceOf(address(zap)), 3 ether, "the wrapped donation was touched");
        assertEq(address(zap).balance, 0, "the router kept native ether");
    }

    /// **NEGATIVE CONTROL for Z-01f.** Without the donation the same call costs exactly `msg.value`
    /// and the router ends empty.
    function test_Z01g_control_withoutTheDonationTheWrappedBuyCostsExactlyMsgValue() public {
        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 1 ether}(_one(ethKey), key, 1, alice, DEADLINE);
        assertGt(out, 0, "the wrapped buy delivered nothing");
        assertEq(before - alice.balance, 1 ether, "a wrapped buy on an empty router must cost msg.value");
    }

    /// A wrapped SELL does not sweep — `zapSell` withdraws exactly `amountOut` and never calls
    /// `_refundEth`. The donation therefore waits for a BUY, which is the cheaper call.
    function test_Z01h_aWrappedSellLeavesTheDonationWhereItIs() public {
        vm.prank(alice);
        uint256 held = zap.zapBuy{value: 10 ether}(_one(ethKey), key, 1, alice, DEADLINE);
        assertGt(held, 0, "precondition: alice holds tokens to sell");

        pair.mint(address(zap), 3 ether);
        vm.prank(alice);
        uint256 out = zap.zapSell(_one(ethKey), key, held / 2, 1, alice, DEADLINE);

        assertGt(out, 0, "the wrapped sell delivered nothing, so this proves nothing");
        assertEq(pair.balanceOf(address(zap)), 3 ether, "a sell moved the wrapped donation");
    }

    /// **SOUND — Z-12.** The contract's docstring claims `ethKey` is "ignored entirely when the
    /// pair IS weth". Proven rather than trusted: the key is given a dynamic-fee sentinel, a tick
    /// spacing of 1, and the live `FeeHook` as its hook — a pool that has never been initialised
    /// and could not legally be — and the wrap buy goes through untouched.
    ///
    /// The three assertions that make it a proof rather than a smoke test: the garbage pool is
    /// still uninitialised afterwards, the hook accrued nothing against its id, and the fee on the
    /// launch pool is the advertised rate on the FULL `msg.value`, which is only true if hop 1 was
    /// a 1:1 wrap rather than any kind of swap.
    function test_Z12_sound_theWrapPathIgnoresTheEthKeyEntirely() public {
        PoolKey memory garbage = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(pair)),
            fee: 0x800000, // the dynamic-fee sentinel
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });

        (uint160 garbageBefore,,,) = IPoolManager(address(manager)).getSlot0(garbage.toId());
        assertEq(garbageBefore, 0, "precondition: the garbage pool does not exist");

        uint256 feesBefore = hook.totalFeesTaken(poolId);
        uint256 spend = 40 ether;
        vm.prank(alice);
        uint256 out = zap.zapBuy{value: spend}(_one(garbage), key, 1, alice, DEADLINE);
        assertGt(out, 0, "the wrap buy through a garbage ETH key failed");

        (uint160 garbageAfter,,,) = IPoolManager(address(manager)).getSlot0(garbage.toId());
        assertEq(garbageAfter, 0, "the garbage pool was touched");
        assertEq(hook.totalFeesTaken(garbage.toId()), 0, "the hook accrued against the garbage key");
        assertEq(
            hook.totalFeesTaken(poolId) - feesBefore,
            (spend * FEE_BPS) / 10_000,
            "the fee is not the advertised rate on the FULL msg.value, so hop 1 was not a 1:1 wrap"
        );
    }

    /// **FINDING Z-17 (INFO) — the wrap path is the one place `ZapRouter` IS re-enterable.**
    ///
    /// On the pool path the seller's ether is delivered by `take(ADDRESS_ZERO, recipient, …)` at
    /// `:351`, from inside the still-open unlock, and Z-06 shows the global `Lock` closes every
    /// door from there. The wrap path cannot do that — `WETH.withdraw` is illegal inside an unlock
    /// — so `zapSell` calls the recipient at `:217`, AFTER the cycle has closed. The manager is
    /// free at that instant and the recipient can drive a whole second zap.
    ///
    /// The router is stateless, so nothing is corrupted. What the recipient DOES get is Z-01's
    /// donation sweep, pulled forward into the seller's own transaction and pointed at an address
    /// the seller named: the nested `zapBuy` ends in `_refundEth`, which hands `address(this)
    /// .balance` to `msg.sender` — the recipient.
    function test_Z17_theWrappedSellPaysOutAfterTheUnlockSoTheRecipientCanReenter() public {
        ReenteringSellRecipient r = new ReenteringSellRecipient(zap, IPoolManager(address(manager)));
        r.arm(ethKey, key);
        vm.deal(address(r), 10 ether);

        vm.prank(alice);
        uint256 held = zap.zapBuy{value: 20 ether}(_one(ethKey), key, 1, alice, DEADLINE);
        assertGt(held, 0, "precondition: the seller holds a position");

        // Value the router is holding that belongs to neither party in this transaction.
        vm.deal(address(zap), 4 ether);
        uint256 before = address(r).balance;

        vm.prank(alice);
        uint256 out = zap.zapSell(_one(ethKey), key, held / 2, 1, address(r), DEADLINE);
        assertGt(out, 0, "the wrapped sell delivered nothing");

        assertTrue(r.reentered(), "the recipient could not re-enter, so this proves nothing");
        assertFalse(
            r.managerWasUnlocked(),
            "the payout ran mid-unlock, which is the pool path and not the one under test"
        );
        assertGt(r.reentrantOut(), 0, "the nested buy delivered nothing");

        // **The re-entry itself remains possible and harmless — that half of Z-17 is unchanged.**
        // What it no longer buys the recipient is Z-01's donation. Before the fix this asserted
        // `before + out - 1 ether + 4 ether`: the sale, minus the nested buy, PLUS the whole
        // 4-ether donation pulled forward into the seller's transaction. Now the donation is
        // baselined out and the recipient collects only what this transaction actually produced.
        assertEq(
            address(r).balance,
            before + out - 1 ether,
            "the recipient collected more than the sale minus its own nested buy"
        );
        assertEq(address(zap).balance, 4 ether, "the donation moved");
    }

    /// The same call actually routed through the garbage key. On the wrap path it is inert; on the
    /// shipped pool path it is a pool that does not exist, and the router says so.
    function test_Z12b_control_theSameGarbageKeyIsFatalOnThePoolRoutingPath() public {
        PoolKey memory garbage = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(pair)),
            fee: 0x800000,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });

        // Wrap router: the key is never read, so it does not matter what is in it.
        vm.prank(alice);
        uint256 out = zap.zapBuy{value: 1 ether}(_one(garbage), key, 1, alice, DEADLINE);
        assertGt(out, 0, "the wrap path read the ETH key after all");

        // Pool router (`weth == address(0)`): the same key is hop 1, and hop 1 does not exist.
        vm.prank(alice);
        vm.expectRevert();
        poolRouter.zapBuy{value: 1 ether}(_one(garbage), key, 1, alice, DEADLINE);
    }
}

contract ZapAuditWrapTokenIsCurrency0Test is ZapAuditWrapCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract ZapAuditWrapTokenIsCurrency1Test is ZapAuditWrapCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

// ===================================================================================================
// The wedge — a sell tax and a burn share, the two configurations the remediation touched
// ===================================================================================================

/// @notice `IntermediateLegDidNotNet` rests on the claim that `Hooks.beforeSwap`'s
///         `amountToSwap += hookDeltaSpecified` makes hop 2 debit exactly what hop 1 produced.
///         That claim has to survive every configuration the REMEDIATED `FeeHook` can now produce,
///         not just the default one the shipped suite runs.
abstract contract ZapAuditWedgeCases is ZapBase {

    function _sellFeeBps() internal pure override returns (uint16) {
        return 1000; // the 10% ceiling
    }

    function _burnBps() internal pure override returns (uint16) {
        return 3000;
    }

    /// **SOUND.** A round trip under a 10% sell tax and a 30% burn wedge settles in both
    /// directions, the pair nets to exactly zero on both legs, and the router keeps nothing.
    ///
    /// Non-vacuity: the sell tax must actually have been charged, in the LAUNCH TOKEN, or this
    /// would be the default configuration wearing a different name.
    function test_Z13_sound_aSellTaxAndABurnWedgeDoNotBreakTheIntermediateNetting() public {
        uint256 held = _zapBuy(alice, 30 ether);
        assertGt(held, 0, "the buy under the wedge delivered nothing");

        uint256 tokenFeesBefore = hook.pendingTokenFees(poolId);
        vm.prank(alice);
        uint256 out = zap.zapSell(_one(ethKey), key, held / 2, 1, alice, DEADLINE);

        assertGt(out, 0, "the sell under the wedge delivered nothing");
        assertGt(
            hook.pendingTokenFees(poolId) - tokenFeesBefore,
            0,
            "no sell tax was charged, so this is not the wedge configuration"
        );

        assertEq(address(zap).balance, 0, "the router kept ether");
        assertEq(pair.balanceOf(address(zap)), 0, "the router kept pair currency");
        assertEq(token.balanceOf(address(zap)), 0, "the router kept launch tokens");
    }

    /// And the wedge's own machinery — the conversion swap and the buyback, both of which run
    /// inside `sweep`'s separate unlock cycle — still works on a pool whose only traffic came
    /// through the zap.
    function test_Z13b_sound_aSweepAfterZapOnlyTrafficStillConvertsAndBurns() public {
        uint256 held = _zapBuy(alice, 30 ether);
        vm.prank(alice);
        zap.zapSell(_one(ethKey), key, held / 2, 1, alice, DEADLINE);

        assertGt(hook.pendingTokenFees(poolId), 0, "precondition: there is a sell-tax pile to convert");
        uint256 burnedBefore = hook.totalBurned(poolId);
        uint256 distBefore = pair.balanceOf(address(dist));

        hook.sweep(key);

        assertGt(hook.totalBurned(poolId) - burnedBefore, 0, "the buyback did not run on zap-only traffic");
        assertGt(pair.balanceOf(address(dist)) - distBefore, 0, "holders were not paid on zap-only traffic");
    }

    /// A sell big enough to be cut short at the opening-tick floor is still ALLOWED — the
    /// remediation deliberately scoped `PriceLimitedBuyWouldOvercharge` to buys, and the zap's
    /// own `IntermediateLegDidNotNet` is what covers the sell direction. This is the boundary
    /// between the two guards, asserted rather than assumed.
    function test_Z13c_sound_theNewHookRevertIsScopedToBuysAndDoesNotTouchTheZapsSellLeg() public {
        uint256 held = _zapBuy(alice, 30 ether);
        vm.prank(alice);
        uint256 out = zap.zapSell(_one(ethKey), key, held, 1, alice, DEADLINE);
        assertGt(out, 0, "a full-position sell under the wedge was refused");
    }
}

contract ZapAuditWedgeTokenIsCurrency0Test is ZapAuditWedgeCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract ZapAuditWedgeTokenIsCurrency1Test is ZapAuditWedgeCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

// ===================================================================================================
// A thin hop 1 — where `IntermediateLegDidNotNet` becomes somebody else's weapon
// ===================================================================================================

/// @notice The shipped suite proves a seller who is TOO BIG for hop 1 is refused by name. It never
///         asks whether a THIRD PARTY can make a seller too big without the seller changing
///         anything — which is the difference between a documented limit and a griefing vector.
abstract contract ZapAuditThinCases is ZapBase {

    /// Same band the shipped thin-pool suite uses: ±600 ticks on `L = 2000e18`, roughly 59 units a
    /// side, so a 10-unit trade is real impact and a 200-unit one runs it dry.
    function _seedEthPool() internal override {
        pair.mint(address(this), 10_000e18);
        pair.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 50_000 ether);

        lpRouter.modifyLiquidity{value: 5_000 ether}(
            ethKey,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: 2_000e18,
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// **FINDING Z-14 — the sell side of the zap can be switched off by a stranger, for the price
    /// of a round trip in a pool nobody in this system owns.**
    ///
    /// Hop 1 on a sell is `pair -> ETH` with `sqrtPriceLimitX96 = MAX_SQRT_PRICE - 1`. Exhaust the
    /// ether side of that pool's liquidity and the price does not stop at the top of the band: with
    /// no liquidity above it, `Pool.swap` walks the remaining distance to the limit for free and
    /// parks there. `ZapRouter._requireNotPinned` then refuses **every** sell through that ETH pool
    /// by name, for everybody, until somebody buys the price back down.
    ///
    /// Round 2's `04-hook.md` records the pin as an INFORMATIONAL property of a launch pool, where
    /// reaching it means selling the entire float back through a single-sided seed. Hop 1 is an
    /// ordinary two-sided pool: reaching its pin is one exact-input swap, and the attacker gets
    /// almost all of it back on the way out.
    ///
    /// `TradeRouter` has no equivalent — a single-hop sell has no second pool to be starved of.
    function test_Z14_fixed_pinningOnePoolNoLongerTakesEverySellOffline() public {
        // The victim builds a position with her OWN pair currency, so the ETH pool is untouched and
        // still sitting mid-band. Nothing about her position is unusual.
        vm.prank(alice);
        tradeRouter.swap(key, _buyIsZeroForOne(), 40e18, 0, alice);
        uint256 held = token.balanceOf(alice);
        assertGt(held, 0, "precondition: the victim holds a position");

        // POSITIVE CONTROL: her sell works in an untouched market.
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 calm = zap.zapSell(_one(ethKey), key, held, 1, alice, DEADLINE);
        assertGt(calm, 0, "the victim's sell does not work even unattacked");
        vm.revertToState(snap);

        // THE ATTACK. One exact-input swap. Bob never touches the victim, her position, or the
        // launch pool.
        uint256 bobEth0 = bob.balance;
        uint256 bobPair0 = pair.balanceOf(bob);
        vm.prank(bob);
        pair.approve(address(swapRouter), type(uint256).max);
        vm.prank(bob);
        swapRouter.swap(
            ethKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(uint256(300e18)),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        (uint160 pinned,,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), ethKey.toId());
        assertEq(pinned, TickMath.MAX_SQRT_PRICE - 1, "the ETH pool did not end on its price limit");

        // What the pin actually cost to place, measured before anything else moves.
        uint256 pairConsumed = bobPair0 - pair.balanceOf(bob);
        uint256 ethGained = bob.balance - bobEth0;
        assertGt(pairConsumed, 0, "the attack swap consumed nothing");

        // Every seller, not only the one who was targeted.
        vm.prank(alice);
        vm.expectPartialRevert(ZapRouter.AllEthPoolsPinned.selector);
        zap.zapSell(_one(ethKey), key, held, 1, alice, DEADLINE);

        vm.prank(alice);
        vm.expectPartialRevert(ZapRouter.AllEthPoolsPinned.selector);
        zap.zapSell(_one(ethKey), key, held / 1000, 1, alice, DEADLINE);

        // BUYS still work, which is what makes it a one-way valve rather than an outage: holders
        // cannot leave and newcomers can still arrive.
        uint256 bought = _zapBuy(bob, 1 ether);
        assertGt(bought, 0, "buys were blocked too, so this is not a sell-side valve");

        // The attacker unwinds with an exact-input swap of the ether he was handed, and we measure
        // what the whole round trip cost him.
        vm.prank(bob);
        swapRouter.swap{value: ethGained}(
            ethKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethGained),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 pairCost = bobPair0 > pair.balanceOf(bob) ? bobPair0 - pair.balanceOf(bob) : 0;
        emit log_named_uint("Z-14 pair consumed to place the pin         ", pairConsumed);
        emit log_named_uint("Z-14 ether the pin handed the attacker      ", ethGained);
        emit log_named_uint("Z-14 attacker NET pair cost of the round trip", pairCost);
        emit log_named_uint("Z-14 victim's sell, unattacked (wei)        ", calm);
    }

    /// The state is not permanent — a buy walks the price back off the pin — which is exactly what
    /// makes it a cheap, repeatable, bundle-shaped grief rather than a brick.
    function test_Z14c_theOutageEndsAsSoonAsAnybodyBuysThePriceBackDown() public {
        vm.prank(alice);
        tradeRouter.swap(key, _buyIsZeroForOne(), 40e18, 0, alice);
        uint256 held = token.balanceOf(alice);

        vm.prank(bob);
        pair.approve(address(swapRouter), type(uint256).max);
        vm.prank(bob);
        swapRouter.swap(
            ethKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(uint256(300e18)),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        vm.prank(alice);
        vm.expectPartialRevert(ZapRouter.AllEthPoolsPinned.selector);
        zap.zapSell(_one(ethKey), key, held, 1, alice, DEADLINE);

        // Anybody buying enough ether into hop 1 restores it.
        _zapBuy(bob, 100 ether);

        vm.prank(alice);
        uint256 out = zap.zapSell(_one(ethKey), key, held, 1, alice, DEADLINE);
        assertGt(out, 0, "the pin did not clear after a buy");
    }

    /// The other half of the same statement: the identical victim, the identical attack, but
    /// selling through `TradeRouter` instead. She receives the pair currency and is unaffected —
    /// the second pool is what the attacker needs, and a single-hop route does not have one.
    function test_Z14b_control_theSameAttackDoesNothingToASingleHopSell() public {
        vm.prank(alice);
        tradeRouter.swap(key, _buyIsZeroForOne(), 40e18, 0, alice);
        uint256 held = token.balanceOf(alice);

        vm.prank(bob);
        pair.approve(address(swapRouter), type(uint256).max);
        vm.prank(bob);
        swapRouter.swap(
            ethKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(uint256(300e18)),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 pairBefore = pair.balanceOf(alice);
        vm.prank(alice);
        uint256 got = tradeRouter.swap(key, !_buyIsZeroForOne(), held, 0, alice);
        assertGt(got, 0, "the single-hop sell was affected too, so hop 1 is not the cause");
        assertEq(pair.balanceOf(alice) - pairBefore, got, "the single-hop seller was not paid");
    }
}

contract ZapAuditThinTokenIsCurrency0Test is ZapAuditThinCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract ZapAuditThinTokenIsCurrency1Test is ZapAuditThinCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
