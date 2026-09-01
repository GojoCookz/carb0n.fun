// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {HookBase} from "../src/base/HookBase.sol";
import {FeeHookHarness} from "./FeeHook.t.sol";

/// @notice Attacks on the hook's external surface.
///
/// @dev **`unlockCallback` is the function to worry about on this contract.** It decodes caller
///      supplied bytes into a pool key and two amounts, then burns ERC-6909 claims, swaps, and
///      `take`s real ERC-20 out of the PoolManager. Callable by anyone, it is not a bug, it is a
///      withdrawal function for every fee the hook holds across every pool - and the PoolManager
///      is a singleton, so "every pool" means other people's launches too.
///
///      The rest are the ordinary access-control questions, which are cheap to test and expensive
///      to get wrong. They were not covered: the existing suite calls these functions only as the
///      launcher, which is the one caller for which they are supposed to work.
contract HookAttackTest is FeeHookHarness {
    address internal attacker = address(0xBADBAD);

    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    // ===========================================================================================
    // The dangerous one
    // ===========================================================================================

    /// Anyone calling `unlockCallback` directly would be spending the hook's claims. The guard is
    /// the only thing between an attacker and every fee the hook is holding.
    function test_attack_outsiderCannotDriveUnlockCallback() public {
        bytes memory payload = abi.encode(key, uint256(1e18), uint256(1e18), attacker);

        vm.prank(attacker);
        vm.expectRevert(HookBase.NotPoolManager.selector);
        hook.unlockCallback(payload);
    }

    /// Not even with a payload naming a pool that does not exist - the guard must be on the
    /// CALLER, never on the contents, because the contents are attacker-controlled.
    function test_attack_outsiderCannotDriveUnlockCallbackWithGarbage() public {
        PoolKey memory fake = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 0,
            tickSpacing: 60,
            hooks: hook
        });
        bytes memory payload = abi.encode(fake, type(uint128).max, type(uint128).max, attacker);

        vm.prank(attacker);
        vm.expectRevert(HookBase.NotPoolManager.selector);
        hook.unlockCallback(payload);
    }

    /// `autoRedeem` is `external` so the auto-sweep path gets a real revert boundary for its
    /// try/catch. External plus unguarded would mean anyone can drive the payout path directly.
    function test_attack_outsiderCannotCallAutoRedeem() public {
        // Read the config FIRST. `_cfgFor` makes an external call to the hook's `poolConfig`
        // getter, and Solidity evaluates arguments before the call they belong to - so inlining
        // it would feed the prank and the expectRevert to the getter instead, and the test would
        // "fail" on a contract that is behaving correctly.
        FeeHook.PoolConfig memory cfg = _cfgFor();

        vm.prank(attacker);
        vm.expectRevert(HookBase.NotPoolManager.selector);
        hook.autoRedeem(poolId, key, cfg);
    }

    // ===========================================================================================
    // Configuration
    // ===========================================================================================

    /// Reconfiguring a live pool would let someone redirect its fees to themselves.
    function test_attack_outsiderCannotConfigurePool() public {
        vm.prank(attacker);
        vm.expectRevert(FeeHook.OnlyLauncher.selector);
        hook.configurePool(key, address(dist), Currency.wrap(address(pair)), 300, attacker, 2000);
    }

    function test_attack_outsiderCannotConfigurePoolFull() public {
        FeeHook.FeeSetup memory s = FeeHook.FeeSetup({
            distributor: address(dist),
            pairCurrency: Currency.wrap(address(pair)),
            feeBps: 1000,
            sellFeeBps: 1000,
            burnBps: 0,
            creator: attacker,
            creatorBps: 10_000 // the whole fee to the attacker
        });

        vm.prank(attacker);
        vm.expectRevert(FeeHook.OnlyLauncher.selector);
        hook.configurePoolFull(key, s);
    }

    function test_attack_outsiderCannotConfigureGraduation() public {
        vm.prank(attacker);
        vm.expectRevert(FeeHook.OnlyLauncher.selector);
        hook.configureGraduation(key, 1, 1e18);
    }

    /// Even the real launcher must not be able to re-point a configured pool. The creator address
    /// and fee split are promises made to buyers at launch; a mutable version of them is not a
    /// promise. This is the case where "only the launcher can call it" is not sufficient.
    function test_attack_pairCurrencyCannotBeSwappedAfterConfiguration() public {
        FeeHook.FeeSetup memory s = FeeHook.FeeSetup({
            distributor: address(dist),
            pairCurrency: Currency.wrap(address(0xDEAD)), // a different currency entirely
            feeBps: 300,
            sellFeeBps: 0,
            burnBps: 0,
            creator: attacker,
            creatorBps: 2000
        });

        // Called AS the launcher, which this test contract is.
        vm.expectRevert();
        hook.configurePoolFull(key, s);
    }

    // ===========================================================================================
    // Fee ceiling
    // ===========================================================================================

    /// The 10% cap is the only thing bounding what a launch can charge. It has to hold on the
    /// full-form entry point too, not just the simple one.
    function test_attack_feeCeilingHoldsOnBothRates() public {
        FeeHook.FeeSetup memory s = FeeHook.FeeSetup({
            distributor: address(dist),
            pairCurrency: Currency.wrap(address(pair)),
            feeBps: 1001, // one bp over
            sellFeeBps: 0,
            burnBps: 0,
            creator: address(this),
            creatorBps: 0
        });

        vm.expectRevert(abi.encodeWithSelector(FeeHook.FeeTooHigh.selector, uint16(1001)));
        hook.configurePoolFull(_freshKey(), s);

        s.feeBps = 300;
        s.sellFeeBps = 1001;
        vm.expectRevert(abi.encodeWithSelector(FeeHook.FeeTooHigh.selector, uint16(1001)));
        hook.configurePoolFull(_freshKey(), s);
    }

    /// The creator's cut and the burn share both come out of the fee, so together they cannot
    /// exceed it. If they could, `_routeFee` would underflow or pay out of someone else's pool.
    function test_attack_creatorPlusBurnCannotExceedTheWholeFee() public {
        FeeHook.FeeSetup memory s = FeeHook.FeeSetup({
            distributor: address(dist),
            pairCurrency: Currency.wrap(address(pair)),
            feeBps: 300,
            sellFeeBps: 0,
            burnBps: 6000,
            creator: address(this),
            creatorBps: 5000 // 60% + 50% = 110% of the fee
        });

        vm.expectRevert();
        hook.configurePoolFull(_freshKey(), s);
    }

    // ===========================================================================================
    // Helpers
    // ===========================================================================================

    /// A key for a pool that has never been configured, so the revert under test is the one named
    /// rather than "already configured".
    function _freshKey() internal view returns (PoolKey memory k) {
        k = key;
        k.tickSpacing = 61;
    }

    function _cfgFor() internal view returns (FeeHook.PoolConfig memory) {
        (
            address distributor,
            Currency pairCurrency,
            uint16 feeBps,
            address creator,
            uint16 creatorBps,
            bool configured,
            uint16 sellFeeBps,
            uint16 burnBps,
            uint16 platformShareBps
        ) = hook.poolConfig(poolId);
        return FeeHook.PoolConfig({
            distributor: distributor,
            pairCurrency: pairCurrency,
            feeBps: feeBps,
            creator: creator,
            creatorBps: creatorBps,
            configured: configured,
            sellFeeBps: sellFeeBps,
            burnBps: burnBps,
            platformShareBps: platformShareBps
        });
    }}
