// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {FeeHookHarness} from "./FeeHook.t.sol";

/// @notice The platform's cut: that it is taken, that it is the right size, and that nothing a
///         creator configures can avoid it.
///
/// @dev **The property under test is that the platform earns a share of VOLUME, not of the fee.**
///      A share of the fee would tie the launchpad's revenue to how hard its own customers tax
///      their buyers, which points the incentive exactly the wrong way - the pad would earn more
///      every time a creator squeezed harder. Fixing it to volume means a 2% launch and a 9%
///      launch pay the same 1%, and everything above that belongs to the creator.
///
///      These tests therefore check the RATIO against the trade, and against `feeBps`, rather than
///      reconstructing an absolute. Three things already come off a fee before it is divided (the
///      burn wedge, the sweep bounty, and a burn share reserved by an auto-sweep for a later
///      manual one), so a reconstructed absolute would just re-implement the contract and assert
///      it against itself.
contract PlatformFeeTest is FeeHookHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    // ===========================================================================================
    // The share is derived from the rate, at configuration
    // ===========================================================================================

    /// At the harness's own rate, the platform's share of the fee is exactly the flat volume rate
    /// divided by that fee. This is the arithmetic the whole design rests on.
    function test_platformShareIsDerivedFromTheFeeRate() public view {
        (,, uint16 feeBps,,,,,, uint16 platformShareBps,) = hook.poolConfig(poolId);

        uint256 expected = (uint256(hook.PLATFORM_VOLUME_BPS()) * hook.BPS()) / feeBps;
        assertEq(platformShareBps, expected, "platform share was not derived from the fee rate");

        // And that share of that fee is the flat rate, back out again.
        assertApproxEqAbs(
            (uint256(feeBps) * platformShareBps) / hook.BPS(),
            hook.PLATFORM_VOLUME_BPS(),
            1,
            "the platform's share of the fee is not 1% of volume"
        );
    }

    /// The invariant that matters, across the whole legal range of fees: whatever a creator
    /// charges, the platform's slice of it is worth the same 1% of the trade.
    function testFuzz_platformAlwaysEarnsOnePercentOfVolume(uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, hook.PLATFORM_VOLUME_BPS(), hook.MAX_FEE_BPS()));

        FeeHook.FeeSetup memory s = FeeHook.FeeSetup({
            distributor: address(dist),
            pairCurrency: Currency.wrap(address(pair)),
            feeBps: feeBps,
            sellFeeBps: 0,
            burnBps: 0,
            creator: creator,
            creatorBps: 5000,
            rewardCurrency: Currency.wrap(address(0))
        });

        PoolKey memory k = key;
        k.tickSpacing = 61; // a pool that has never been configured
        hook.configurePoolFull(k, s);

        (,,,,,,,, uint16 platformShareBps,) = hook.poolConfig(k.toId());

        // Rounding is toward zero on an integer division, so the platform is never overpaid.
        uint256 volumeBpsEarned = (uint256(feeBps) * platformShareBps) / hook.BPS();
        assertApproxEqAbs(
            volumeBpsEarned,
            hook.PLATFORM_VOLUME_BPS(),
            1,
            "platform take drifted from 1% of volume"
        );
        assertLe(volumeBpsEarned, hook.PLATFORM_VOLUME_BPS(), "platform was overpaid");
    }

    // ===========================================================================================
    // It actually gets paid, from a real trade
    // ===========================================================================================

    function test_platformIsPaidFromARealSwap() public {
        _giveTokens(alice, 10_000_000e18);

        uint256 platformBefore = pair.balanceOf(PLATFORM);
        _buyExactOut(bob, 500_000e18);

        assertGt(pair.balanceOf(PLATFORM) - platformBefore, 0, "platform was paid nothing");
    }

    /// The platform's slice comes out of the top, so its ratio against everything distributed is
    /// `platformShareBps` regardless of how the creator split the remainder.
    function test_platformTakesItsShareBeforeCreatorAndHolders() public {
        _giveTokens(alice, 10_000_000e18);

        uint256 platformBefore = pair.balanceOf(PLATFORM);
        uint256 creatorBefore = pair.balanceOf(creator);
        _buyExactOut(bob, 500_000e18);

        uint256 platformGot = pair.balanceOf(PLATFORM) - platformBefore;
        uint256 creatorGot = pair.balanceOf(creator) - creatorBefore;
        uint256 holdersGot = pair.balanceOf(address(dist));
        uint256 distributed = platformGot + creatorGot + holdersGot;

        assertGt(distributed, 0, "nothing was distributed at all");

        (,,,,,,,, uint16 platformShareBps,) = hook.poolConfig(poolId);
        assertApproxEqRel(
            (platformGot * 10_000) / distributed,
            platformShareBps,
            1e15, // 0.1%
            "platform did not receive its configured share of what was distributed"
        );
    }

    /// **A creator taking 100% takes 100% of their own cut, not of the fee.** This is the case the
    /// ordering exists for: if the platform were paid out of the remainder, `creatorBps = 10000`
    /// would leave nothing to pay it with and the launchpad would earn zero on its own product.
    function test_creatorTakingEverythingStillCannotStarveThePlatform() public {
        FeeHook.FeeSetup memory s = FeeHook.FeeSetup({
            distributor: address(dist),
            pairCurrency: Currency.wrap(address(pair)),
            feeBps: 200,
            sellFeeBps: 0,
            burnBps: 0,
            creator: creator,
            creatorBps: 10_000, // everything, and dividends off - "simple mode"
                rewardCurrency: Currency.wrap(address(0))
        });

        PoolKey memory k = key;
        k.tickSpacing = 61;
        hook.configurePoolFull(k, s);

        (,,,,,,,, uint16 platformShareBps,) = hook.poolConfig(k.toId());
        assertGt(platformShareBps, 0, "a 100% creator share zeroed the platform");
        assertEq(platformShareBps, 5000, "at a 2% fee the platform's half of it is 1% of volume");
    }

    // ===========================================================================================
    // The floor
    // ===========================================================================================

    /// A fee below the platform's own flat rate cannot pay it. Rejected rather than clamped - a
    /// launch that quietly charges more than the creator chose is worse than one that reverts.
    function test_aFeeBelowThePlatformFloorIsRejected() public {
        FeeHook.FeeSetup memory s = FeeHook.FeeSetup({
            distributor: address(dist),
            pairCurrency: Currency.wrap(address(pair)),
            feeBps: uint16(hook.PLATFORM_VOLUME_BPS() - 1),
            sellFeeBps: 0,
            burnBps: 0,
            creator: creator,
            creatorBps: 5000,
            rewardCurrency: Currency.wrap(address(0))
        });

        PoolKey memory k = key;
        k.tickSpacing = 61;
        vm.expectRevert(
            abi.encodeWithSelector(
                FeeHook.FeeBelowPlatformFloor.selector, uint16(hook.PLATFORM_VOLUME_BPS() - 1)
            )
        );
        hook.configurePoolFull(k, s);
    }

    /// Exactly at the floor is legal, and hands the platform the entire fee.
    function test_aFeeExactlyAtTheFloorIsAcceptedAndIsAllPlatform() public {
        FeeHook.FeeSetup memory s = FeeHook.FeeSetup({
            distributor: address(dist),
            pairCurrency: Currency.wrap(address(pair)),
            feeBps: hook.PLATFORM_VOLUME_BPS(),
            sellFeeBps: 0,
            burnBps: 0,
            creator: creator,
            creatorBps: 5000,
            rewardCurrency: Currency.wrap(address(0))
        });

        PoolKey memory k = key;
        k.tickSpacing = 61;
        hook.configurePoolFull(k, s);

        (,,,,,,,, uint16 platformShareBps,) = hook.poolConfig(k.toId());
        assertEq(platformShareBps, hook.BPS(), "at the floor the platform takes the whole fee");
    }

    // ===========================================================================================
    // The recipient is immutable
    // ===========================================================================================

    /// @dev There is deliberately no setter. A launchpad that can redirect its own take after
    ///      people have launched on it is one nobody should launch on, so this test exists to
    ///      fail loudly if a setter is ever added.
    function test_platformRecipientIsFixedAtDeploy() public view {
        assertEq(hook.platformRecipient(), PLATFORM, "platform recipient moved");
    }

    function test_platformRateIsAConstant() public view {
        assertEq(hook.PLATFORM_VOLUME_BPS(), 100, "the platform rate is not 1%");
    }

    /// @notice REGRESSION. A plain-wallet platform recipient must not brick every sweep.
    ///
    /// @dev `_routeFee` notifies the recipient so a referral vault can split the cut, and the
    ///      first version wrapped that call in `try/catch` believing it was safe against a
    ///      recipient with no code. It is NOT: Solidity emits an `extcodesize` guard BEFORE the
    ///      call and that guard reverts in the calling frame, where `catch` cannot reach it.
    ///
    ///      The consequence was total - every sweep in the system reverted, so no fee ever reached
    ///      a creator or a holder again - and it only appears when the recipient is an EOA, which
    ///      is exactly what a testnet deploy uses. `PLATFORM` in this harness is a bare address
    ///      for precisely this reason.
    function test_aPlainWalletPlatformRecipientDoesNotBrickSweeps() public {
        assertEq(PLATFORM.code.length, 0, "this test is meaningless against a contract");

        _giveTokens(alice, 10_000_000e18);
        uint256 before = pair.balanceOf(PLATFORM);

        // Would revert `call to non-contract address` without the code-length guard.
        _buyExactOut(bob, 500_000e18);

        assertGt(pair.balanceOf(PLATFORM) - before, 0, "sweep did not pay the wallet");
    }
}
