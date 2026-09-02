// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

import {Launcher} from "../../src/Launcher.sol";
import {FeeHook} from "../../src/FeeHook.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {Distributor} from "../../src/Distributor.sol";
import {PairRegistry} from "../../src/PairRegistry.sol";
import {ReferralVault} from "../../src/ReferralVault.sol";
import {VestingVault} from "../../src/VestingVault.sol";
import {LaunchMetadata} from "../../src/types/LaunchMetadata.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title AccessAuditHarness
/// @notice Shared stack for audit surface #3 - access control and privileged paths.
///
/// @dev The deploy order is the real one and it is not optional: `FeeHook.launcher` and
///      `Launcher.feeHook` are both immutable and each needs the other, so the launcher's CREATE
///      address is reserved first and the hook is placed against it.
///
///      **`_deployer` on the launcher is `address(this)` here**, which is what makes the one-shot
///      initializer tests meaningful - the test contract is the only address that may call them.
abstract contract AccessAuditHarness is Test {
    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PairRegistry internal registry;
    LaunchToken internal tokenImpl;
    Launcher internal launcher;
    FeeHook internal hook;
    MockERC20 internal pair;
    MockERC20 internal rewardPair;

    address internal creator = address(0xC0EA702);
    address internal creator2 = address(0xC0EA703);
    address internal trader = address(0x7EAD);
    address internal attacker = address(0xBADBAD);
    address internal stranger = address(0x57A);
    address internal treasury = address(0x7EE);

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant OPENING_MCAP = 100e18;

    /// @dev Low 14 bits must be 0x20CC or `HookBase`'s constructor rejects the address.
    address internal constant HOOK_ADDR = address(uint160(uint256(0xF00D) << 144 | 0x20CC));

    /// @dev How many CREATEs a subclass performs between the address prediction and the launcher.
    function _nonceOffset() internal view virtual returns (uint256) {
        return 0;
    }

    /// @dev Returns the address that receives the platform's cut. May deploy contracts, in which
    ///      case `_nonceOffset` must account for them.
    function _platformFor(address predictedLauncher) internal virtual returns (address);

    function _baseSetUp() internal {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        registry = new PairRegistry(address(this));
        tokenImpl = new LaunchToken();
        pair = new MockERC20("Wrapped Ether", "WETH", 18);
        rewardPair = new MockERC20("Wrapped Monero", "WXMR", 18);
        registry.approvePairWithoutOracle(address(pair), 18);
        registry.approvePairWithoutOracle(address(rewardPair), 18);

        address predictedLauncher =
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + _nonceOffset());

        address platform = _platformFor(predictedLauncher);

        deployCodeTo(
            "FeeHook.sol:FeeHook",
            abi.encode(address(manager), predictedLauncher, platform),
            HOOK_ADDR
        );
        hook = FeeHook(HOOK_ADDR);

        launcher = new Launcher(IPoolManager(address(manager)), hook, registry, address(tokenImpl));
        assertEq(address(launcher), predictedLauncher, "launcher must land on the reserved address");

        _fund(creator);
        _fund(creator2);
        _fund(trader);
        _fund(attacker);
        _fund(stranger);
    }

    function _fund(address who) internal {
        pair.mint(who, 1_000_000e18);
        vm.startPrank(who);
        pair.approve(address(launcher), type(uint256).max);
        pair.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _params() internal view returns (Launcher.LaunchParams memory) {
        return Launcher.LaunchParams({
            name: "Hoodstonk",
            symbol: "HOOD",
            supply: SUPPLY,
            pair: address(pair),
            openingMarketCap: OPENING_MCAP,
            graduationThreshold: OPENING_MCAP * 5,
            feeBps: 300,
            sellFeeBps: 0,
            burnBps: 0,
            vestDuration: 0,
            vestCliff: 0,
            creatorBps: 2000,
            maxWalletBps: 0,
            tickSpacing: 60,
            devBuyPairAmount: 0,
            salt: bytes32(uint256(1)),
            minPushPayout: 1e6,
            minShareForQueue: 1e18,
            rewardCurrency: address(0),
            feeRecipient: address(0),
            referrer: address(0),
            metadata: LaunchMetadata({imageCid: keccak256("image"), bannerCid: 0, infoCid: 0})
        });
    }

    function _key(address token) internal view returns (PoolKey memory) {
        bool tokenIsCurrency0 = token < address(pair);
        return PoolKey({
            currency0: Currency.wrap(tokenIsCurrency0 ? token : address(pair)),
            currency1: Currency.wrap(tokenIsCurrency0 ? address(pair) : token),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _buy(address who, address token, uint256 amountIn) internal {
        PoolKey memory k = _key(token);
        bool zeroForOne = Currency.unwrap(k.currency0) == address(pair);

        vm.prank(who);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev An ordinary exact-input buy, then a sweep so the fee becomes real ERC-20.
    ///
    ///      The sweep moves MONEY onto the Distributor immediately. It does NOT move
    ///      ENTITLEMENT: `distribute` arms a linear vest over `STREAM_WINDOW` and nothing is
    ///      withdrawable in the block it lands. Anything that reads `withdrawableOf` must call
    ///      `_vest` first - which is deliberately NOT folded into this helper, because two tests
    ///      in this file warp on their own vesting-schedule clock and a hidden warp would
    ///      silently move that too.
    function _buyAndSweep(address who, address token, uint256 amountIn) internal {
        _buy(who, token, amountIn);
        hook.sweep(_key(token));
    }

    /// @dev Warp past the end of the current dividend stream. `skip` reads the clock back through
    ///      the cheatcode; `via_ir` caches `block.timestamp` and silently no-ops a chained
    ///      `vm.warp(block.timestamp + X)`.
    function _vest(Distributor dist) internal {
        skip(uint256(dist.STREAM_WINDOW()) + 1);
    }

    function _launchVested(uint256 devBuy, uint64 duration, uint64 cliff)
        internal
        returns (address token, VestingVault vault)
    {
        Launcher.LaunchParams memory p = _params();
        p.devBuyPairAmount = devBuy;
        p.vestDuration = duration;
        p.vestCliff = cliff;

        vm.prank(creator);
        (token,) = launcher.launch(p);
        vault = VestingVault(launcher.vaultOf(token));
        assertTrue(address(vault) != address(0), "expected a vault");
    }
}

// ==============================================================================================
//
//                                  SURFACE 3: ACCESS CONTROL
//
// Every external/public function in src/, asked two questions: who may call it, and what happens
// if the wrong person does. Guards already proven elsewhere are NOT re-tested here:
//
//   - `FeeHook.unlockCallback` / `autoRedeem` / `configurePool*` / `configureGraduation`
//     -> `test/HookAttack.t.sol`
//   - `Distributor.distribute` / `setBalance` / `setExcluded`   -> `test/Adversarial.t.sol`
//   - `PairRegistry` onlyOwner guards                            -> `test/PairRegistry.t.sol`
//   - `VestingVault.extend` / `renounceAccrual` onlyBeneficiary  -> `test/Vesting.t.sol`
//   - `ReferralVault.setReferrer` / `credit` guards              -> `test/Referral.t.sol`
//
// ==============================================================================================

contract AccessAuditTest is AccessAuditHarness {
    address internal constant PLATFORM = address(0xFEE0);

    function _platformFor(address) internal pure override returns (address) {
        return PLATFORM;
    }

    function setUp() public {
        _baseSetUp();
    }

    // ===========================================================================================
    // Launcher: the two one-shot initializers
    // ===========================================================================================

    /// SOUND. `_deployer` is captured in the constructor and there is no rotation.
    function test_sound_initializersRejectEveryCallerButTheDeployer() public {
        vm.prank(attacker);
        vm.expectRevert(Launcher.OnlyDeployer.selector);
        launcher.initReferralVault(address(0xA1));

        vm.prank(attacker);
        vm.expectRevert(Launcher.OnlyDeployer.selector);
        launcher.initRewardConverter(address(0xC1));

        // Not even the creator of a launch.
        vm.prank(creator);
        vm.expectRevert(Launcher.OnlyDeployer.selector);
        launcher.initReferralVault(address(0xA1));
    }

    /// SOUND. One shot each, and zero is refused so the slot cannot be "used up" on nothing.
    function test_sound_initializersAreTrulyOneShot() public {
        vm.expectRevert(Launcher.ReferralVaultAlreadySet.selector);
        launcher.initReferralVault(address(0));

        launcher.initReferralVault(address(0xAAA1));
        assertEq(launcher.referralVault(), address(0xAAA1));

        vm.expectRevert(Launcher.ReferralVaultAlreadySet.selector);
        launcher.initReferralVault(address(0xAAA2));
        assertEq(launcher.referralVault(), address(0xAAA1), "the vault was replaced");

        vm.expectRevert(Launcher.ReferralVaultAlreadySet.selector);
        launcher.initRewardConverter(address(0));

        launcher.initRewardConverter(address(0xBBB1));
        assertEq(launcher.rewardConverter(), address(0xBBB1));

        vm.expectRevert(Launcher.ReferralVaultAlreadySet.selector);
        launcher.initRewardConverter(address(0xBBB2));
        assertEq(launcher.rewardConverter(), address(0xBBB1), "the converter was replaced");
    }

    /// SOUND. Nobody can front-run the deployer into the slot, because the guard is on the CALLER
    /// and not on the emptiness of the slot.
    function test_sound_theInitializerSlotsCannotBeSquattedBeforeWiringCompletes() public {
        assertEq(launcher.referralVault(), address(0), "starts unset");
        assertEq(launcher.rewardConverter(), address(0), "starts unset");

        vm.prank(attacker);
        vm.expectRevert(Launcher.OnlyDeployer.selector);
        launcher.initReferralVault(address(0xBAD));

        // Still free for the deployer afterwards.
        launcher.initReferralVault(address(0xAAA1));
        assertEq(launcher.referralVault(), address(0xAAA1));
    }

    /// SOUND. A launch with both unset is a completely ordinary launch.
    function test_sound_aLaunchWorksWithBothInitializersUnset() public {
        Launcher.LaunchParams memory p = _params();
        p.referrer = address(0xBEEF); // ignored: no vault to record it in

        vm.prank(creator);
        (address token,) = launcher.launch(p);

        assertTrue(launcher.isOurs(token), "launch did not complete");
        _buyAndSweep(trader, token, 1e18);
        assertGt(LaunchToken(token).balanceOf(trader), 0, "pool is not tradeable");
    }

    // -------------------------------------------------------------------------------------------
    // FINDING A-1 (MEDIUM): a reward currency chosen before `initRewardConverter` is silently
    // dropped, forever, with no revert and no event.
    // -------------------------------------------------------------------------------------------
    //
    // `Launcher._cloneAndInit` reads `rewardConverter` at launch time and bakes it into the
    // Distributor as an IMMUTABLE. `_validate` checks that `rewardCurrency` is on the allowlist but
    // never checks that a converter exists to reach it. `Distributor._trySend` then requires
    // `converter != address(0)` before it will even *try*, so the `RewardConversionFailed` event -
    // which the contract's own docstring calls the thing that makes a wrong-currency payout
    // "visible on chain rather than inferred from a balance" - is never emitted either.
    function test_finding_rewardCurrencyIsSilentlyDroppedWhenTheConverterIsUnset() public {
        Launcher.LaunchParams memory p = _params();
        p.rewardCurrency = address(rewardPair); // an allowlisted, deliberately-chosen reward

        vm.prank(creator);
        (address token,) = launcher.launch(p);

        Distributor dist = LaunchToken(token).distributor();

        // The creator's choice was recorded...
        assertEq(dist.rewardToken(), address(rewardPair), "the reward currency was accepted");
        // ...and the route to it is permanently absent.
        assertEq(dist.converter(), address(0), "converter baked in as zero, immutably");

        // Two trades so a holder actually accrues, then a full window so the stream vests.
        _buyAndSweep(trader, token, 1e18);
        _buyAndSweep(stranger, token, 1e18);
        _vest(dist);

        uint256 owed = dist.withdrawableOf(trader);
        assertGt(owed, 0, "no dividend to test with");

        uint256 pairBefore = pair.balanceOf(trader);
        vm.recordLogs();
        vm.prank(trader);
        dist.withdraw();

        // Paid in the pair currency, not the advertised reward.
        assertEq(pair.balanceOf(trader) - pairBefore, owed, "not paid in the pair currency");
        assertEq(rewardPair.balanceOf(trader), 0, "holder never receives the chosen reward");

        // And nothing on chain says so. `RewardConversionFailed` is gated behind
        // `converter != address(0)`, so the honest signal is exactly what is missing.
        bytes32 failedSig = keccak256("RewardConversionFailed(address,uint256,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            assertTrue(logs[i].topics[0] != failedSig, "a failure event was emitted after all");
        }
    }

    /// The other half of the same finding: wiring order is the ONLY thing that decides it, and the
    /// launcher gives a creator no way to see or require it.
    function test_finding_theSameLaunchAfterWiringGetsAConverter() public {
        launcher.initRewardConverter(address(0xC0FFEE));

        Launcher.LaunchParams memory p = _params();
        p.salt = bytes32(uint256(77));
        p.rewardCurrency = address(rewardPair);

        vm.prank(creator);
        (address token,) = launcher.launch(p);

        assertEq(
            LaunchToken(token).distributor().converter(),
            address(0xC0FFEE),
            "an identical launch, minutes apart, gets a different permanent route"
        );
    }

    // -------------------------------------------------------------------------------------------
    // FINDING A-2 (HIGH): every dividend PUSHED to a VestingVault is permanently unrecoverable.
    // -------------------------------------------------------------------------------------------
    //
    // `Distributor.processBatch` is permissionless by design. `VestingVault.claimDividends` is
    // `onlyBeneficiary` and its ONLY way of moving payout currency out is
    // `balanceAfter - balanceBefore` around a `Distributor.withdraw()` that reverts when nothing
    // is withdrawable. So:
    //
    //   push  -> the vault's payout tokens land inside `balanceBefore`
    //   claim -> `withdraw()` reverts `NothingToWithdraw`, the whole call reverts
    //   later -> a claim succeeds but only forwards the NEW delta; the pushed balance is skipped
    //
    // `VestingVault` has no rescue, no owner and no other transfer of `payoutToken`. Cost to
    // trigger: one `processBatch` call by anybody - or an honest keeper doing exactly the job the
    // Distributor docstring advertises.
    function test_finding_pushedDividendsAreStrandedInAVestingVaultForever() public {
        (address token, VestingVault vault) = _launchVested(5e18, 90 days, 0);
        Distributor dist = LaunchToken(token).distributor();

        // Earn the vault a dividend, and let it vest - entitlement is on the clock now.
        _buyAndSweep(trader, token, 5e18);
        _buyAndSweep(stranger, token, 5e18);
        _vest(dist);

        uint256 owedToVault = dist.withdrawableOf(address(vault));
        assertGt(owedToVault, 0, "the locked bag must accrue like any other holder");
        assertEq(pair.balanceOf(address(vault)), 0, "vault holds no payout currency yet");

        // ANY address may push. This is the documented, intended, permissionless path.
        vm.prank(attacker);
        dist.processBatch(50);

        uint256 stranded = pair.balanceOf(address(vault));
        assertEq(stranded, owedToVault, "the push landed on the vault");
        assertEq(dist.withdrawableOf(address(vault)), 0, "and the claim is now settled");

        // The beneficiary's only door is now bolted. The two assertions above are what make this
        // `expectRevert` mean something: under streaming `NothingToWithdraw` also fires for a
        // holder who is merely un-vested, so the revert alone proves nothing. Here the vault was
        // provably owed `owedToVault`, provably paid it by the push, and is provably at zero.
        vm.prank(creator);
        vm.expectRevert(Distributor.NothingToWithdraw.selector);
        vault.claimDividends();

        // More trading, more dividends - and the stranded balance is STILL skipped, because
        // `claimDividends` forwards only the delta it observes around `withdraw()`.
        _buyAndSweep(trader, token, 5e18);
        _buyAndSweep(stranger, token, 5e18);
        _vest(dist);

        uint256 creatorBefore = pair.balanceOf(creator);
        vm.prank(creator);
        uint256 got = vault.claimDividends();

        assertGt(got, 0, "the new dividend did reach the beneficiary");
        assertEq(pair.balanceOf(creator) - creatorBefore, got, "and only the new one");
        assertEq(
            pair.balanceOf(address(vault)),
            stranded,
            "the pushed dividend is still sitting there, unreachable"
        );

        // There is no other exit. The only `payoutToken` transfer on VestingVault is the one
        // inside `claimDividends`, and it can only ever move the delta.
        _buyAndSweep(trader, token, 5e18);
        _vest(dist);
        vm.prank(creator);
        vault.claimDividends();
        assertEq(pair.balanceOf(address(vault)), stranded, "still stranded after a second claim");
    }

    /// The same defect, reached WITHOUT an attacker: the vault is enqueued like any holder, so the
    /// first well-meaning keeper to call `processBatch` destroys the creator's dividend stream.
    ///
    /// @dev **This was a VACUOUS PASS under streaming and was not on the failing list.** Without
    ///      the `_vest`, the vault is owed zero, `processBatch` walks past it paying nobody, and
    ///      `claimDividends` reverts `NothingToWithdraw` for the entirely innocent reason that
    ///      nothing had vested yet - i.e. the test was green on a system where the keeper had
    ///      done no harm at all. The three added assertions pin the causal chain instead of the
    ///      revert selector.
    function test_finding_anHonestKeeperCausesTheSameLoss() public {
        (address token, VestingVault vault) = _launchVested(5e18, 90 days, 0);
        Distributor dist = LaunchToken(token).distributor();

        _buyAndSweep(trader, token, 5e18);
        _buyAndSweep(stranger, token, 5e18);
        _vest(dist);

        // The vault really is in the push queue - it is not an exotic state.
        bool queued;
        for (uint256 i = 0; i < dist.queueLength(); i++) {
            if (dist.queueAt(i) == address(vault)) queued = true;
        }
        assertTrue(queued, "the vault is a queued holder");

        uint256 owedToVault = dist.withdrawableOf(address(vault));
        assertGt(owedToVault, 0, "the vault is genuinely owed before the keeper runs");

        vm.prank(stranger); // a bounty bot, not an attacker
        dist.processBatch(50);

        // The keeper really did land the money, and really did settle the claim. Without these
        // two the revert below is indistinguishable from "nothing had vested".
        assertEq(pair.balanceOf(address(vault)), owedToVault, "the keeper pushed it into the vault");
        assertEq(dist.withdrawableOf(address(vault)), 0, "and settled the claim doing it");

        vm.prank(creator);
        vm.expectRevert(Distributor.NothingToWithdraw.selector);
        vault.claimDividends();
    }

    // -------------------------------------------------------------------------------------------
    // FINDING A-3 (MEDIUM): `VestingVault.addSchedule` is permissionless AND takes an unbounded
    // caller-chosen `start`, so anyone can lock any top-up in anyone's vault for any length of
    // time - irreversibly, because `extend` cannot move `start` and nothing can shorten.
    // -------------------------------------------------------------------------------------------
    function test_finding_anyoneCanPermanentlyLockATopUpInSomeoneElsesVault() public {
        (address token, VestingVault vault) = _launchVested(5e18, 90 days, 0);
        uint256 t0 = block.timestamp;

        // The creator wants to lock MORE - the documented "add, never subtract" feature. The
        // tokens go in first, because `addSchedule` can only schedule what is already here.
        _buyAndSweep(trader, token, 20e18);
        uint256 topUp = 1_000e18;
        vm.prank(trader);
        IERC20(token).transfer(address(vault), topUp);

        // ...and are front-run. `start` has no upper bound and no relationship to now.
        uint64 farFuture = uint64(t0 + 100 * 365 days);
        vm.prank(attacker);
        vault.addSchedule(uint128(topUp), farFuture, 0, 7 days);

        assertEq(vault.scheduleCount(), 2, "the attacker's schedule was accepted");
        assertEq(vault.scheduleAt(1).start, farFuture, "with a start a century out");
        assertEq(vault.scheduleAt(1).total, topUp, "over the whole top-up");

        // Fifty years later it has still not begun to vest.
        vm.warp(t0 + 50 * 365 days);
        vm.prank(creator);
        vault.release();
        assertEq(
            IERC20(token).balanceOf(address(vault)),
            topUp,
            "the top-up is untouched half a century later"
        );

        // And it cannot be undone. `extend` is the only mutator, it refuses to shorten, and
        // `start` is not a parameter of it at all.
        vm.prank(creator);
        vm.expectRevert(VestingVault.CannotShorten.selector);
        vault.extend(1, 0, 1 days);
    }

    /// Same door, a cheaper abuse: 31 dust schedules fill `MAX_SCHEDULES` and the beneficiary can
    /// never lock anything again. Cost to the attacker: 31 wei of the launch token plus gas.
    function test_finding_anyoneCanFillMaxSchedulesAndBlockAllFutureLocks() public {
        (address token, VestingVault vault) = _launchVested(5e18, 90 days, 0);

        _buyAndSweep(trader, token, 20e18);
        vm.prank(trader);
        IERC20(token).transfer(attacker, 1_000e18);

        // Slot 0 is the launch's own schedule; 31 more fills the array.
        for (uint256 i = 0; i < 31; i++) {
            vm.startPrank(attacker);
            IERC20(token).transfer(address(vault), 1);
            vault.addSchedule(1, uint64(block.timestamp), 0, 7 days);
            vm.stopPrank();
        }
        assertEq(vault.scheduleCount(), vault.MAX_SCHEDULES(), "array is full");

        // The beneficiary's own top-up is now impossible, permanently.
        vm.prank(trader);
        IERC20(token).transfer(address(vault), 500e18);

        vm.prank(creator);
        vm.expectRevert(VestingVault.TooManySchedules.selector);
        vault.addSchedule(uint128(500e18), uint64(block.timestamp), 0, 30 days);
    }

    /// INFO, same function: `addSchedule` SILENTLY TRIMS an over-large amount instead of
    /// reverting. The project's own stated rule ("silent trimming is banned", `Launcher` docs) is
    /// not applied here.
    function test_info_addScheduleSilentlyTrimsInsteadOfReverting() public {
        (address token, VestingVault vault) = _launchVested(5e18, 90 days, 0);

        _buyAndSweep(trader, token, 20e18);
        vm.prank(trader);
        IERC20(token).transfer(address(vault), 100e18);

        vm.prank(creator);
        vault.addSchedule(type(uint128).max, uint64(block.timestamp), 0, 30 days);

        assertEq(
            vault.scheduleAt(1).total, 100e18, "asked for uint128 max, got a silently different lock"
        );
    }

    // -------------------------------------------------------------------------------------------
    // FINDING A-4 (LOW): a launch salt is public and colliding it reverts the victim's launch.
    // `Clones.cloneDeterministic` keys only on (implementation, salt, launcher).
    // -------------------------------------------------------------------------------------------
    function test_finding_aLaunchSaltCanBeFrontRunToRevertSomeoneElsesLaunch() public {
        bytes32 minedSalt = bytes32(uint256(0xC0FFEE));

        // Anyone can see which address a salt produces before the launch lands.
        address doomed = launcher.predictTokenAddress(minedSalt);
        assertTrue(doomed != address(0));
        assertEq(doomed.code.length, 0, "nothing there yet");

        Launcher.LaunchParams memory hostile = _params();
        hostile.salt = minedSalt;
        hostile.name = "Squat";
        vm.prank(attacker);
        launcher.launch(hostile);

        Launcher.LaunchParams memory victim = _params();
        victim.salt = minedSalt;
        vm.prank(creator);
        // The exact revert matters: the launch dies on the CLONE, at step 1, before any of the
        // validation the victim could have fixed by changing a parameter.
        vm.expectRevert(Errors.FailedDeployment.selector);
        launcher.launch(victim);

        // The salt is burned forever - and salts are mined off chain to control currency
        // ordering, so the victim does not get an equivalent one for free.
        assertGt(doomed.code.length, 0, "the address is taken permanently");
    }

    // -------------------------------------------------------------------------------------------
    // FINDING A-5 (LOW): `PairRegistry` ownership can be destroyed in ONE unconfirmed call.
    // `Ownable2Step` protects `transferOwnership` and leaves `renounceOwnership` single-step.
    // -------------------------------------------------------------------------------------------
    function test_finding_registryOwnershipCanBeRenouncedInOneCallAndFreezesTheAllowlist() public {
        assertEq(registry.owner(), address(this));

        registry.renounceOwnership();
        assertEq(registry.owner(), address(0), "ownership gone, with no second step");

        MockERC20 newPair = new MockERC20("New", "NEW", 18);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        registry.approvePairWithoutOracle(address(newPair), 18);

        // And nothing can be delisted either - the allowlist is frozen in whatever state it was in.
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        registry.revokePair(address(pair));
    }

    /// SOUND, the other half: ownership cannot be STOLEN. The two-step handshake holds.
    function test_sound_registryOwnershipCannotBeStolen() public {
        registry.transferOwnership(stranger);
        assertEq(registry.owner(), address(this), "transfer is not immediate");
        assertEq(registry.pendingOwner(), stranger);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        registry.acceptOwnership();

        vm.prank(stranger);
        registry.acceptOwnership();
        assertEq(registry.owner(), stranger);

        // The old owner is now a stranger.
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        registry.revokePair(address(pair));
    }

    // -------------------------------------------------------------------------------------------
    // FINDING A-6 (LOW): `tokenDecimals` is TRUSTED FROM THE CALLER on both approve paths, while
    // the docstring at PairRegistry.sol:101 states decimals "are read from the contracts, never
    // passed in, so a typo cannot misprice a pair by 1e12". Only `feedDecimals` is read.
    // -------------------------------------------------------------------------------------------
    function test_finding_tokenDecimalsIsTakenOnTrustDespiteTheDocstring() public {
        MockERC20 sixDecimals = new MockERC20("USD Coin", "USDC", 6);

        // The exact typo the comment claims is impossible: an 18-decimal token entered as 6.
        registry.approvePairWithoutOracle(address(pair), 6);
        assertEq(pair.decimals(), 18, "the token really is 18");
        assertEq(registry.pairConfig(address(pair)).tokenDecimals, 6, "the registry believes 6");

        // ...and the reverse, on a real 6-decimal token entered as 18.
        registry.approvePairWithoutOracle(address(sixDecimals), 18);
        assertEq(registry.pairConfig(address(sixDecimals)).tokenDecimals, 18);
        assertEq(sixDecimals.decimals(), 6);
    }

    /// INFO: re-approving an existing pair silently OVERWRITES its whole config. Owner-only, but
    /// there is no "already listed" guard and no event distinguishing an update from a listing.
    function test_info_reApprovalSilentlyOverwritesAnExistingPairConfig() public {
        assertTrue(registry.isApproved(address(pair)));
        uint256 countBefore = registry.pairCount();

        registry.approvePairWithoutOracle(address(pair), 2);
        assertEq(registry.pairConfig(address(pair)).tokenDecimals, 2, "config replaced in place");
        assertEq(registry.pairCount(), countBefore, "and the list does not show a change");
    }

    // ===========================================================================================
    // Launcher / LaunchToken: the clone and its implementation
    // ===========================================================================================

    /// SOUND. The implementation seals itself in its constructor, so the well-known address behind
    /// every clone cannot be initialised and hijacked.
    function test_sound_theTokenImplementationCannotBeInitialised() public {
        vm.prank(attacker);
        vm.expectRevert(LaunchToken.AlreadyInitialized.selector);
        tokenImpl.initialize(_initParams(attacker));

        assertEq(address(tokenImpl.distributor()), address(0), "no distributor on the template");
        assertEq(tokenImpl.totalSupply(), 0, "no supply on the template");
    }

    /// SOUND. A live clone cannot be re-initialised, so its distributor and max wallet cannot be
    /// repointed after people have bought.
    function test_sound_aLiveCloneCannotBeReinitialised() public {
        vm.prank(creator);
        (address token,) = launcher.launch(_params());

        vm.prank(attacker);
        vm.expectRevert(LaunchToken.AlreadyInitialized.selector);
        LaunchToken(token).initialize(_initParams(attacker));

        // Even the launcher itself cannot.
        vm.prank(address(launcher));
        vm.expectRevert(LaunchToken.AlreadyInitialized.selector);
        LaunchToken(token).initialize(_initParams(attacker));
    }

    /// SOUND. `Launcher.unlockCallback` is the launcher's own withdrawal-shaped surface: it
    /// decodes caller-supplied bytes and then `take`s and transfers. Only the PoolManager may
    /// reach it, and the PoolManager only ever calls back the address that called `unlock`.
    function test_sound_outsiderCannotDriveLauncherUnlockCallback() public {
        Launcher.SeedData memory d = Launcher.SeedData({
            key: _key(address(0x1111)),
            token: address(0x1111),
            tokenSeed: type(uint128).max,
            openingTick: 0,
            devBuyPairAmount: type(uint128).max,
            creator: attacker,
            tokenIsCurrency0: true,
            vestCliff: 0,
            vestDuration: 0
        });

        vm.prank(attacker);
        vm.expectRevert(Launcher.OnlyPoolManager.selector);
        launcher.unlockCallback(abi.encode(d));

        // Not even the hook, which is the only other contract in the system holding a pool key.
        vm.prank(address(hook));
        vm.expectRevert(Launcher.OnlyPoolManager.selector);
        launcher.unlockCallback(abi.encode(d));
    }

    /// SOUND. `sweep` is permissionless BY DESIGN and is not a withdrawal for anyone but the
    /// pool's own configured recipients. The caller earns the advertised bounty and nothing else.
    function test_sound_sweepIsPermissionlessButRoutesOnlyByStoredConfig() public {
        vm.prank(creator);
        (address token,) = launcher.launch(_params());
        PoolKey memory k = _key(token);

        _buy(trader, token, 1e18);

        uint256 attackerBefore = pair.balanceOf(attacker);
        uint256 creatorBefore = pair.balanceOf(creator);

        vm.prank(attacker);
        hook.sweep(k);

        uint256 bounty = pair.balanceOf(attacker) - attackerBefore;
        assertGt(bounty, 0, "the caller earns the advertised bounty");
        assertGt(pair.balanceOf(PLATFORM), bounty, "the platform still took the larger share");
        assertGt(pair.balanceOf(creator) - creatorBefore, 0, "and the creator was paid");
    }

    /// SOUND. An unconfigured pool cannot be swept or graduated, so the permissionless entry
    /// points cannot be pointed at pool ids the launcher never registered.
    function test_sound_permissionlessEntryPointsRefuseUnknownPools() public {
        PoolKey memory ghost = _key(address(0xDEADBEEF));

        vm.prank(attacker);
        vm.expectRevert(FeeHook.NotConfigured.selector);
        hook.sweep(ghost);

        vm.prank(attacker);
        vm.expectRevert(FeeHook.GraduationNotConfigured.selector);
        hook.checkGraduation(PoolId.wrap(keccak256("nope")));
    }

    // ===========================================================================================
    // Helpers
    // ===========================================================================================

    function _initParams(address who) internal view returns (LaunchToken.InitParams memory) {
        return LaunchToken.InitParams({
            name_: "Hijack",
            symbol_: "HJK",
            supply: SUPPLY,
            recipient: who,
            payoutToken: address(pair),
            rewardToken: address(0),
            converter: address(0),
            controller: who,
            poolManager_: address(manager),
            maxWallet_: 0,
            minPushPayout: 0,
            minShareForQueue: 0,
            metadata: LaunchMetadata({imageCid: keccak256("x"), bannerCid: 0, infoCid: 0})
        });
    }
}

// ==============================================================================================
//
//                      REFERRAL WIRING - the privileged path that pays money
//
// This harness wires the ReferralVault as the hook's `platformRecipient`, which is the ONLY
// configuration in which `ReferralVault.credit` is reachable at all.
//
// ==============================================================================================

contract ReferralAccessAuditTest is AccessAuditHarness {
    ReferralVault internal refVault;

    function _nonceOffset() internal pure override returns (uint256) {
        return 1; // the vault is deployed between the prediction and the launcher
    }

    function _platformFor(address predictedLauncher) internal override returns (address) {
        uint16[] memory tiers = new uint16[](5);
        tiers[0] = 2000;
        tiers[1] = 1000;
        tiers[2] = 500;
        tiers[3] = 300;
        tiers[4] = 200;
        refVault = new ReferralVault(predictedLauncher, HOOK_ADDR, treasury, tiers);
        return address(refVault);
    }

    function setUp() public {
        _baseSetUp();
        launcher.initReferralVault(address(refVault));
        assertEq(hook.platformRecipient(), address(refVault), "vault must be the platform sink");
    }

    // -------------------------------------------------------------------------------------------
    // FINDING A-7 (MEDIUM): a creator can credit THEMSELVES the whole referral schedule on their
    // own launch, using two wallets, because `setReferrer` never checks that the referrer already
    // exists in the graph.
    // -------------------------------------------------------------------------------------------
    //
    // `ReferralVault.credit` documents the opposite at ReferralVault.sol:130 - "**Cycles are
    // impossible** because `referrerOf` is write-once and a referrer must already exist when they
    // refer someone". `setReferrer` enforces the write-once half and NOT the must-already-exist
    // half, so A->B and B->A is a legal two-transaction construction, and the tier walk then
    // alternates between the two wallets until it exhausts the schedule.
    function test_finding_aTwoWalletCycleLetsACreatorCreditThemselvesTheWholeSchedule() public {
        // Both wallets belong to the same person. Two ordinary launches, each naming the other.
        Launcher.LaunchParams memory pa = _params();
        pa.salt = bytes32(uint256(101));
        pa.referrer = creator2;
        vm.prank(creator);
        (address tokenA,) = launcher.launch(pa);

        Launcher.LaunchParams memory pb = _params();
        pb.salt = bytes32(uint256(102));
        pb.referrer = creator;
        vm.prank(creator2);
        launcher.launch(pb);

        assertEq(refVault.referrerOf(creator), creator2, "cycle leg 1");
        assertEq(
            refVault.referrerOf(creator2),
            creator,
            "cycle leg 2 - the docstring says this is impossible"
        );

        _buyAndSweep(trader, tokenA, 10e18);

        uint256 toSelf =
            refVault.owed(creator, address(pair)) + refVault.owed(creator2, address(pair));
        uint256 toTreasury = refVault.owed(treasury, address(pair));
        assertGt(toSelf, 0, "no self-credit occurred");

        // The full 40% schedule was captured by the launcher's own two wallets.
        assertApproxEqAbs(
            (toSelf * 10_000) / (toSelf + toTreasury),
            4000,
            2,
            "expected the whole schedule to land on the creator's own wallets"
        );

        // And it is really withdrawable, not just an accounting artefact.
        uint256 before2 = pair.balanceOf(creator2);
        vm.prank(creator2);
        refVault.claim(address(pair));
        assertGt(pair.balanceOf(creator2) - before2, 0, "the second wallet was paid out for real");
    }

    // -------------------------------------------------------------------------------------------
    // FINDING A-8 (MEDIUM): setting `feeRecipient` silently destroys the referrer's entire claim.
    // -------------------------------------------------------------------------------------------
    //
    // `Launcher._configureHook` records `setReferrer(msg.sender, referrer)` - keyed on the
    // LAUNCHING WALLET - but stores `creator: feeRecipient == 0 ? msg.sender : feeRecipient` in the
    // pool config. `FeeHook._routeFee` then calls `credit(..., cfg.creator)`, so the chain is
    // looked up under the FEE RECIPIENT. A creator who routes fees to a multisig - which the
    // launch params explicitly invite - unknowingly zeroes out whoever referred them.
    function test_finding_aFeeRecipientBreaksTheReferralChainSilently() public {
        address referrer = address(0x8EEF);
        address multisig = address(0x115516);

        // Control: no feeRecipient, referrer is paid.
        Launcher.LaunchParams memory p1 = _params();
        p1.salt = bytes32(uint256(201));
        p1.referrer = referrer;
        vm.prank(creator);
        (address tokenA,) = launcher.launch(p1);
        _buyAndSweep(trader, tokenA, 10e18);
        assertGt(
            refVault.owed(referrer, address(pair)), 0, "control: the referrer earns on a plain launch"
        );

        // Same launch, same referrer, fees routed to a team wallet.
        Launcher.LaunchParams memory p2 = _params();
        p2.salt = bytes32(uint256(202));
        p2.referrer = referrer;
        p2.feeRecipient = multisig;
        vm.prank(creator2);
        (address tokenB,) = launcher.launch(p2);

        assertEq(refVault.referrerOf(creator2), referrer, "the referral WAS recorded");

        uint256 referrerBefore = refVault.owed(referrer, address(pair));
        uint256 treasuryBefore = refVault.owed(treasury, address(pair));
        _buyAndSweep(trader, tokenB, 10e18);

        assertEq(
            refVault.owed(referrer, address(pair)),
            referrerBefore,
            "the recorded referrer earned nothing from the launch they referred"
        );
        assertGt(
            refVault.owed(treasury, address(pair)),
            treasuryBefore,
            "the treasury silently took their share too"
        );
    }

    /// SOUND. `credit` still refuses every caller but the hook, even now that the hook really is
    /// wired to it and money really flows.
    function test_sound_onlyTheHookCanCreditEvenWhenLive() public {
        pair.mint(address(refVault), 100e18);

        vm.prank(attacker);
        vm.expectRevert(ReferralVault.OnlyFeeHook.selector);
        refVault.credit(address(pair), 100e18, attacker);

        vm.prank(address(launcher));
        vm.expectRevert(ReferralVault.OnlyFeeHook.selector);
        refVault.credit(address(pair), 100e18, attacker);

        vm.prank(attacker);
        vm.expectRevert(ReferralVault.OnlyLauncher.selector);
        refVault.setReferrer(attacker, creator);
    }
}

// ==============================================================================================
//
// FINDING A-9 (MEDIUM, deployment): as wired by `script/DeployTestnet.s.sol` the ReferralVault is
// ORPHANED. The script sets `platformRecipient = deployer` on the hook and only afterwards
// deploys the vault, so `ReferralVault.credit` is unreachable for the life of that hook -
// `platformRecipient` is immutable. Referrals are recorded and can never be paid.
//
// This harness reproduces exactly that wiring: vault set on the launcher, EOA on the hook.
//
// ==============================================================================================

contract OrphanedReferralVaultTest is AccessAuditHarness {
    ReferralVault internal refVault;
    address internal constant PLATFORM_EOA = address(0xFEE0);

    function _platformFor(address) internal pure override returns (address) {
        return PLATFORM_EOA;
    }

    function setUp() public {
        _baseSetUp();

        uint16[] memory tiers = new uint16[](5);
        tiers[0] = 2000;
        tiers[1] = 1000;
        tiers[2] = 500;
        tiers[3] = 300;
        tiers[4] = 200;
        // Deployed AFTER the hook, exactly as the script does it.
        refVault = new ReferralVault(address(launcher), address(hook), treasury, tiers);
        launcher.initReferralVault(address(refVault));
    }

    function test_finding_theDeployedReferralVaultCanNeverPayAnyone() public {
        address referrer = address(0x8EEF);

        assertEq(hook.platformRecipient(), PLATFORM_EOA, "the script's wiring");
        assertEq(launcher.referralVault(), address(refVault), "and its half-wired vault");

        Launcher.LaunchParams memory p = _params();
        p.referrer = referrer;
        vm.prank(creator);
        (address token,) = launcher.launch(p);

        // The referral is recorded, which is what makes this look wired.
        assertEq(refVault.referrerOf(creator), referrer, "referral recorded");

        // Real trading, real platform fees.
        _buyAndSweep(trader, token, 10e18);
        _buyAndSweep(stranger, token, 10e18);
        assertGt(pair.balanceOf(PLATFORM_EOA), 0, "the platform was paid");

        // None of it reached the vault, and none of it ever can: `platformRecipient` is immutable.
        assertEq(pair.balanceOf(address(refVault)), 0, "vault never receives anything");
        assertEq(refVault.owed(referrer, address(pair)), 0, "referrer is owed nothing");
        assertEq(refVault.owed(treasury, address(pair)), 0, "treasury is owed nothing");

        vm.prank(referrer);
        vm.expectRevert(ReferralVault.NothingOwed.selector);
        refVault.claim(address(pair));
    }
}
