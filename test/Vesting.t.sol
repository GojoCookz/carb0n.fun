// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {Launcher} from "../src/Launcher.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {VestingVault} from "../src/VestingVault.sol";
import {PairRegistry} from "../src/PairRegistry.sol";
import {LaunchMetadata} from "../src/types/LaunchMetadata.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title VestingTest
/// @notice The dev-buy vault, and the trade it makes.
///
/// @dev A vested dev buy is UNCAPPED. That is not an oversight, it is the design: the 10% cap and
///      the vault protect buyers from the same thing by different means. The cap limits how much
///      can be dumped; the vault makes the size and the schedule public in the launch transaction
///      and forbids ever shortening it. These tests pin both halves - that the cap really is
///      lifted, and that the disclosure really is unbreakable.
contract VestingTest is Test {
    PoolManager internal manager;
    PairRegistry internal registry;
    /// Where the platform's 1% of volume lands. A distinct address from every other actor in
    /// these tests on purpose: routing it to `address(this)` would hide a misrouted fee inside
    /// the test contract's own balance, which is exactly the bug worth catching.
    address internal constant PLATFORM = address(0xFEE0);
    FeeHook internal hook;
    Launcher internal launcher;
    LaunchToken internal tokenImpl;
    MockERC20 internal pair;

    address internal creator = address(0xC0EA702);
    address internal stranger = address(0x57A);

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant OPENING_MCAP = 100e18;

    function setUp() public {
        manager = new PoolManager(address(this));
        registry = new PairRegistry(address(this));
        tokenImpl = new LaunchToken();
        pair = new MockERC20("Wrapped Ether", "WETH", 18);
        registry.approvePairWithoutOracle(address(pair), 18);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address hookAddr = address(uint160(uint256(0xF00D) << 144 | 0x20CC));
        deployCodeTo("FeeHook.sol:FeeHook", abi.encode(address(manager), predicted, PLATFORM), hookAddr);
        hook = FeeHook(hookAddr);

        launcher = new Launcher(IPoolManager(address(manager)), hook, registry, address(tokenImpl));
        assertEq(address(launcher), predicted);

        pair.mint(creator, 1_000_000e18);
        vm.prank(creator);
        pair.approve(address(launcher), type(uint256).max);
    }

    function _params() internal view returns (Launcher.LaunchParams memory) {
        return Launcher.LaunchParams({
            name: "Vested",
            symbol: "VEST",
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
            feeRecipient: address(0),
            referrer: address(0),
            metadata: LaunchMetadata({imageCid: keccak256("i"), bannerCid: 0, infoCid: 0})
        });
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
    }

    // ===========================================================================================
    // The absence of a lock is as visible as its presence
    // ===========================================================================================

    function test_anUnvestedLaunchHasNoVaultAtAll() public {
        Launcher.LaunchParams memory p = _params();
        p.devBuyPairAmount = 1e18;

        vm.prank(creator);
        (address token,) = launcher.launch(p);

        assertEq(launcher.vaultOf(token), address(0), "no vault means no lock, and says so");
        assertGt(LaunchToken(token).balanceOf(creator), 0, "the creator holds it outright");
    }

    // ===========================================================================================
    // The cap, and the trade
    // ===========================================================================================

    /// @dev Unvested, the 10% cap still bites exactly as before.
    function test_unvestedDevBuyIsStillCapped() public {
        Launcher.LaunchParams memory p = _params();
        p.devBuyPairAmount = (OPENING_MCAP * 1001) / 10_000; // just over 10%

        vm.prank(creator);
        vm.expectRevert();
        launcher.launch(p);
    }

    /// @dev **The trade, made explicit.** Vested, the creator may take a position far larger than
    ///      the cap would ever allow - and every token of it is locked on a schedule the chain
    ///      announced in the launch transaction.
    function test_aVestedDevBuyIsUncapped() public {
        uint256 huge = (OPENING_MCAP * 5000) / 10_000; // 50%, five times the cap

        (address token, VestingVault vault) = _launchVested(huge, 90 days, 0);

        assertTrue(address(vault) != address(0), "a vested launch must have a vault");
        assertEq(LaunchToken(token).balanceOf(creator), 0, "not a single token went to the wallet");
        assertGt(vault.locked(), 0, "all of it is in the vault");
        assertEq(
            LaunchToken(token).balanceOf(address(vault)), vault.locked(), "and really held there"
        );
    }

    function test_vestingWithoutADevBuyIsRejected() public {
        Launcher.LaunchParams memory p = _params();
        p.vestDuration = 30 days;
        p.devBuyPairAmount = 0;

        vm.prank(creator);
        vm.expectRevert(Launcher.VestRequiresDevBuy.selector);
        launcher.launch(p);
    }

    function test_aVestShorterThanSevenDaysIsRejected() public {
        Launcher.LaunchParams memory p = _params();
        p.devBuyPairAmount = 1e18;
        p.vestDuration = 6 days;

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Launcher.VestTooShort.selector, uint64(6 days)));
        launcher.launch(p);
    }

    // ===========================================================================================
    // Release
    // ===========================================================================================

    function test_nothingUnlocksBeforeTheCliff() public {
        uint256 t0 = block.timestamp;
        (, VestingVault vault) = _launchVested(1e18, 90 days, 30 days);

        assertEq(vault.releasable(), 0, "vested before the cliff");

        vm.warp(t0 + 29 days);
        assertEq(vault.releasable(), 0, "still before the cliff");

        vm.warp(t0 + 31 days);
        assertGt(vault.releasable(), 0, "the cliff passed and it started unlocking");
    }

    function test_itReleasesLinearlyAndFullyByTheEnd() public {
        uint256 start = block.timestamp;
        (address token, VestingVault vault) = _launchVested(1e18, 100 days, 0);
        uint256 total = vault.locked();

        // ABSOLUTE warps, deliberately. Under via-ir the compiler caches `block.timestamp`, so a
        // second `vm.warp(block.timestamp + X)` in the same function silently reuses the ORIGINAL
        // reading and time never advances - which looks exactly like a broken vesting curve.
        vm.warp(start + 50 days);
        assertApproxEqRel(vault.releasable(), total / 2, 1e15, "half way through, half unlocked");

        vm.warp(start + 100 days);
        assertEq(vault.releasable(), total, "everything unlocked at the end");

        // Anyone may push it - the beneficiary is the only possible recipient.
        vm.prank(stranger);
        vault.release();

        assertEq(LaunchToken(token).balanceOf(creator), total, "it all reached the creator");
        assertEq(vault.locked(), 0, "and nothing is left locked");
    }

    // ===========================================================================================
    // The rules that make the disclosure worth anything
    // ===========================================================================================

    function test_aScheduleCanBeLengthenedButNeverShortened() public {
        (, VestingVault vault) = _launchVested(1e18, 90 days, 10 days);

        vm.prank(creator);
        vault.extend(0, 20 days, 180 days);
        assertEq(vault.scheduleAt(0).duration, 180 days, "lengthening is allowed");

        vm.prank(creator);
        vm.expectRevert(VestingVault.CannotShorten.selector);
        vault.extend(0, 20 days, 90 days);

        vm.prank(creator);
        vm.expectRevert(VestingVault.CannotShorten.selector);
        vault.extend(0, 5 days, 180 days);
    }

    function test_onlyTheBeneficiaryMayExtendOrRenounce() public {
        (, VestingVault vault) = _launchVested(1e18, 90 days, 0);

        vm.prank(stranger);
        vm.expectRevert(VestingVault.OnlyBeneficiary.selector);
        vault.extend(0, 0, 180 days);

        vm.prank(stranger);
        vm.expectRevert(VestingVault.OnlyBeneficiary.selector);
        vault.renounceAccrual();
    }

    /// @dev One way, for everyone. A signal that can be taken back is not a signal.
    function test_renouncingTheDividendStreamIsPermanent() public {
        (, VestingVault vault) = _launchVested(1e18, 90 days, 0);

        vm.prank(creator);
        vault.renounceAccrual();
        assertTrue(vault.accrualRenounced());

        vm.prank(creator);
        vm.expectRevert(VestingVault.AlreadyRenounced.selector);
        vault.renounceAccrual();

        // And the stream really is gone - not merely flagged.
        vm.prank(creator);
        vm.expectRevert(VestingVault.AlreadyRenounced.selector);
        vault.claimDividends();
    }

    /// @dev A project outliving the wallet that founded it is a normal thing to want.
    function test_theSeatCanMove() public {
        uint256 t0 = block.timestamp;
        (, VestingVault vault) = _launchVested(1e18, 90 days, 0);

        vm.prank(creator);
        vault.transferBeneficiary(stranger);
        assertEq(vault.beneficiary(), stranger);

        vm.warp(t0 + 91 days);
        vault.release();
        assertGt(
            LaunchToken(vault.token()).balanceOf(stranger), 0, "vested tokens follow the seat"
        );
    }

    /// @dev The schedule is public from the block the token exists. That is the entire product
    ///      claim of vesting, so it is asserted rather than assumed.
    function test_theScheduleIsPublicImmediately() public {
        (, VestingVault vault) = _launchVested(2e18, 365 days, 30 days);

        VestingVault.Schedule memory s = vault.scheduleAt(0);
        assertEq(s.duration, 365 days, "duration readable at once");
        assertEq(s.cliff, 30 days, "cliff readable at once");
        assertEq(s.released, 0, "nothing released yet");
        assertGt(s.total, 0, "and the size is readable too");
    }
}
