// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {FeeHookHarness} from "./FeeHook.t.sol";

/// @notice Pins what the platform ACTUALLY earns once a burn wedge is configured.
///
/// @dev **This test exists because the obvious claim is false.** "The platform takes 1% of volume"
///      is true on a default launch and only there. `unlockCallback` spends the burn share and the
///      sweep bounty out of the swept total BEFORE `_routeFee` ever sees it, so a launch with a
///      burn pays the platform 1% of what is left, not 1% of the trade.
///
///      The dilution is bounded and benign, and is left in place rather than engineered away:
///
///        - It is NOT an avoidance route. Burning destroys the creator's own revenue to reduce the
///          platform's take, which costs the creator more than it saves. Nobody optimises into it.
///        - Taking the platform's cut ahead of the burn would mean the burn wedge is computed on a
///          post-platform base, quietly making every configured burn smaller than the number the
///          creator chose and was shown. That is a worse lie than this one.
///
///      What matters is that it is measured and written down rather than asserted away, because
///      "the platform always earns 1%" is exactly the kind of claim that ends up in marketing copy
///      and then in somebody's model.
contract PlatformDilutionTest is FeeHookHarness {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function _configureWithBurn(uint16 burnBps) internal returns (PoolKey memory k) {
        k = key;
        k.tickSpacing = 61;
        hook.configurePoolFull(
            k,
            FeeHook.FeeSetup({
                distributor: address(dist),
                pairCurrency: Currency.wrap(address(pair)),
                feeBps: 200, // 2%, the simple-mode rate
                sellFeeBps: 0,
                burnBps: burnBps,
                creator: creator,
                creatorBps: 5000,
                rewardCurrency: Currency.wrap(address(0))
            })
        );
    }

    /// With no burn, the platform's slice of the fee is worth exactly the flat rate.
    function test_withoutABurnThePlatformEarnsTheFullFlatRate() public {
        PoolKey memory k = _configureWithBurn(0);
        (,, uint16 feeBps,,,,,, uint16 shareBps,) = hook.poolConfig(k.toId());

        uint256 volumeBps = (uint256(feeBps) * shareBps) / hook.BPS();
        assertEq(volumeBps, hook.PLATFORM_VOLUME_BPS(), "default launch must pay the full 1%");
    }

    /// With a burn, it is diluted by exactly the burn share - and this is the number, stated.
    function test_aBurnDilutesThePlatformCutByTheBurnShare() public {
        uint16 burnBps = 1500; // 15%
        PoolKey memory k = _configureWithBurn(burnBps);
        (,, uint16 feeBps,,,,,, uint16 shareBps,) = hook.poolConfig(k.toId());

        // What `_routeFee` actually receives is the fee less the burn share.
        uint256 reaching = (uint256(feeBps) * (hook.BPS() - burnBps)) / hook.BPS();
        uint256 volumeBps = (reaching * shareBps) / hook.BPS();

        // 2% fee, 15% burn -> the platform earns 0.85% of volume, not 1%.
        assertEq(volumeBps, 85, "a 15% burn should leave the platform 0.85% of volume");
        assertLt(volumeBps, hook.PLATFORM_VOLUME_BPS(), "burn must dilute, or this test is stale");
    }

    /// The dilution is bounded by the burn cap, so the platform can never be starved outright.
    /// A creator cannot configure their way to a zero platform fee.
    function testFuzz_platformCutIsNeverZeroWhateverTheBurn(uint16 burnBps) public {
        // `creatorBps + burnBps <= BPS`, and the harness creator takes 50%.
        burnBps = uint16(bound(burnBps, 0, 5000));

        PoolKey memory k = _configureWithBurn(burnBps);
        (,, uint16 feeBps,,,,,, uint16 shareBps,) = hook.poolConfig(k.toId());

        uint256 reaching = (uint256(feeBps) * (hook.BPS() - burnBps)) / hook.BPS();
        uint256 volumeBps = (reaching * shareBps) / hook.BPS();

        assertGt(volumeBps, 0, "a burn setting starved the platform entirely");
        assertLe(volumeBps, hook.PLATFORM_VOLUME_BPS(), "platform earned MORE than its flat rate");
    }
}
