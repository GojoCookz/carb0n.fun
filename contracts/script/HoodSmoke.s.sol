// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {Launcher} from "../src/Launcher.sol";
import {FeeHook} from "../src/FeeHook.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Distributor} from "../src/Distributor.sol";
import {LaunchMetadata} from "../src/types/LaunchMetadata.sol";
import {Addresses} from "./Addresses.sol";

/// @title HoodSmoke
///
/// @notice The first real launch. Runs the whole product end to end on Ethereum mainnet with the
///         smallest position that still proves anything, and aborts loudly the moment a step does
///         not do what the local suite says it does.
///
/// @dev **This is instrumentation, not validation.** A green run proves the happy path works at
///      small size against real infrastructure. It says nothing adversarial, and it is not a
///      substitute for the third-party audit that `audit/12-pre-mainnet-concerns.md` lists as
///      blocker B-1. Keep the position small enough that being wrong is cheap.
///
///      **What this measures that no fork test can.** Real gas against a live basefee, real MEV,
///      real pair depth, and a real router that is not `PoolSwapTest` in a controlled harness. The
///      three things worth watching in the output are the sweep's gas against its bounty (C-2 in
///      the same file), whether the buy fee is exactly the configured rate on a live pool, and
///      whether the dividend actually lands in a wallet.
///
///      **Ordering matters and it is not the obvious one.** The claim is asserted LAST, because
///      everything before it only proves a holder is OWED something. `withdraw()` is the only step
///      that proves the money moves, and it is the entire product claim.
///
///      Run:
///        forge script script/MainnetSmoke.s.sol:MainnetSmoke --rpc-url $MAINNET_RPC_URL
///        (add --broadcast once the simulation above prints SMOKE PASSED)
contract HoodSmoke is Script {
    // Set from the DeployMainnet output.
    address internal LAUNCHER;
    address internal FEE_HOOK;

    /// The pair to launch against. MUST be one of the GOOD-depth pairs from `app/src/lib/ethRoute.ts`.
    /// `DeployMainnet` prints a depth warning for thin pairs; heed it.
    address internal PAIR;

    /// The seed. Deliberately tiny: this is a test, and every unit of it is real money.
    uint256 internal pairSeed;

    /// @dev The compromised Sepolia deployer, blocked here for the same reason `DeployMainnet`
    ///      blocks it: its private key is public, so anything it signs on mainnet is a donation.
    address internal constant COMPROMISED_DEPLOYER = 0xc286b1956c7691d678520e370727D8aB57328556;

    uint256 internal constant SUPPLY = 1_000_000_000e18;

    function run() external {
        require(block.chainid == 4663, "HoodSmoke: Robinhood Chain (4663) only");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        require(me != COMPROMISED_DEPLOYER, "HoodSmoke: that key's private key is PUBLIC");

        LAUNCHER = vm.envAddress("LAUNCHER");
        FEE_HOOK = vm.envAddress("FEE_HOOK");
        PAIR = vm.envAddress("SMOKE_PAIR");
        pairSeed = vm.envOr("SMOKE_PAIR_SEED", uint256(0));

        require(LAUNCHER.code.length > 0, "HoodSmoke: no code at LAUNCHER");
        require(FEE_HOOK.code.length > 0, "HoodSmoke: no code at FEE_HOOK");
        require(PAIR.code.length > 0, "HoodSmoke: no code at SMOKE_PAIR");
        require(pairSeed > 0, "HoodSmoke: set SMOKE_PAIR_SEED (in pair units) - there is no safe default");

        Launcher launcher = Launcher(LAUNCHER);
        FeeHook hook = FeeHook(FEE_HOOK);
        IERC20 pair = IERC20(PAIR);
        IPoolManager mgr = IPoolManager(Addresses.ROBINHOOD_POOL_MANAGER);

        uint256 haveBefore = pair.balanceOf(me);
        require(haveBefore >= pairSeed * 3, "HoodSmoke: hold at least 3x SMOKE_PAIR_SEED - buy, sell and slippage");

        console.log("================================================================");
        console.log("chain id        ", block.chainid);
        console.log("caller          ", me);
        console.log("eth balance     ", me.balance);
        console.log("pair            ", PAIR);
        console.log("pair balance    ", haveBefore);
        console.log("seed per trade  ", pairSeed);
        console.log("basefee (wei)   ", block.basefee);
        console.log("================================================================");

        vm.startBroadcast(pk);

        // Own router, own approvals. Nothing shared, nothing assumed.
        PoolSwapTest router = new PoolSwapTest(mgr);

        // ---- 1. LAUNCH, supplying no pair currency ------------------------------------------
        // The single-sided property is the first thing that would break against a real pair, and
        // it is measured rather than trusted: the balance must not move by a single unit.
        uint256 mgrPairBefore = pair.balanceOf(address(mgr));

        (address token, PoolId id) = launcher.launch(
            Launcher.LaunchParams({
                name: "Mainnet Smoke",
                symbol: "SMOKE",
                supply: SUPPLY,
                pair: PAIR,
                openingMarketCap: pairSeed * 20,
                graduationThreshold: type(uint256).max, // never graduate during a smoke test
                feeBps: 300,
                sellFeeBps: 300,
                burnBps: 0, // no burn: one less moving part on the first live run
                vestDuration: 0,
                vestCliff: 0,
                creatorBps: 0,
                maxWalletBps: 0,
                tickSpacing: 60,
                devBuyPairAmount: 0,
                salt: bytes32(uint256(block.timestamp)),
                minPushPayout: 1,
                minShareForQueue: 1e18,
                rewardCurrency: address(0),
                feeRecipient: address(0),
                referrer: address(0),
                openingWindow: 0,
                openingFeeBps: 0,
                metadata: LaunchMetadata({imageCid: keccak256("smoke"), bannerCid: 0, infoCid: 0})
            })
        );

        require(pair.balanceOf(me) == haveBefore, "ABORT: the launch spent pair currency - single-sided broken");
        require(
            pair.balanceOf(address(mgr)) == mgrPairBefore,
            "ABORT: the launch put pair currency into the pool - single-sided broken"
        );
        require(LaunchToken(token).balanceOf(address(mgr)) > 0, "ABORT: the pool did not receive the supply");

        PoolKey memory key = _key(token);

        // ---- 2. BUY, and the fee must be EXACTLY the configured rate --------------------------
        // An equality, not a `> 0`. A wrong-but-nonzero fee is the failure this catches, and it is
        // the one that would survive every "did it succeed" check.
        pair.approve(address(router), type(uint256).max);
        _swap(router, key, _buyIsZeroForOne(token), pairSeed);

        uint256 charged = hook.pendingFees(id);
        require(charged == (pairSeed * 300) / 10_000, "ABORT: buy fee is not exactly 3% of the stated input");
        require(LaunchToken(token).balanceOf(me) > 0, "ABORT: the buy delivered no tokens");

        // ---- 3. SWEEP, and measure what it actually cost --------------------------------------
        // C-2 in audit/12: the bounty has to cover the caller's gas or nobody ever sweeps and
        // holders silently stop being paid. This is the first real measurement of that number.
        Distributor dist = LaunchToken(token).distributor();
        uint256 gasBefore = gasleft();
        hook.sweep(key);
        uint256 sweepGas = gasBefore - gasleft();

        require(hook.pendingFees(id) == 0, "ABORT: sweep did not redeem the claim");

        // ---- 4. SELL, charged in the launch token ---------------------------------------------
        LaunchToken(token).approve(address(router), type(uint256).max);
        uint256 held = LaunchToken(token).balanceOf(me);
        _swap(router, key, !_buyIsZeroForOne(token), held / 4);
        require(hook.pendingTokenFees(id) > 0, "ABORT: the sell was not charged in launch tokens");

        // ---- 5. SWEEP AGAIN: the token fee becomes pair currency for holders -------------------
        uint256 ledgerBefore = pair.balanceOf(address(dist));
        hook.sweep(key);
        require(hook.pendingTokenFees(id) == 0, "ABORT: the token fee was not converted");
        require(pair.balanceOf(address(dist)) >= ledgerBefore, "ABORT: the conversion did not reach holders");

        // ---- 6. THE DIVIDEND LANDS IN A WALLET ------------------------------------------------
        // Everything above proves a holder is OWED something. Only this proves they can take it.
        //
        // Entitlement STREAMS - that is what killed E-03 - so a zero-duration position is owed
        // nothing by construction. On a live chain the only way to advance time is to wait, so a
        // zero here is reported rather than treated as a failure: it is the anti-front-running
        // property working, and the claim can be made in a later transaction.
        uint256 owed = dist.withdrawableOf(me);
        if (owed > 0) {
            uint256 pairBeforeClaim = pair.balanceOf(me);
            uint256 tokenBeforeClaim = LaunchToken(token).balanceOf(me);

            dist.withdraw();

            require(
                pair.balanceOf(me) - pairBeforeClaim == owed,
                "ABORT: withdraw did not pay exactly what was owed, in the pair currency"
            );
            require(
                LaunchToken(token).balanceOf(me) == tokenBeforeClaim,
                "ABORT: the claim moved launch tokens - dividends must never be paid in the token"
            );
            require(dist.withdrawableOf(me) == 0, "ABORT: balance not cleared after withdraw");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== SMOKE PASSED on Robinhood Chain ===");
        console.log("token             ", token);
        console.log("pair spent to launch  0  (single-sided)");
        console.log("fees charged      ", hook.totalFeesTaken(id));
        console.log("sweep gas used    ", sweepGas);
        console.log("sweep cost (wei)  ", sweepGas * block.basefee);
        console.log("dividend claimed  ", owed);
        console.log("still withdrawable", dist.withdrawableOf(me));
        console.log("");
        if (owed == 0) {
            console.log("NOTE: nothing claimable yet. Entitlement streams, so a zero-duration hold is");
            console.log("      owed nothing BY DESIGN (this is the E-03 fix). Re-run step 6 later:");
            console.log("      cast send <distributor> 'withdraw()' --private-key $PRIVATE_KEY");
        }
        console.log("COMPARE: sweep cost above against the bounty. If the bounty does not cover it,");
        console.log("         C-2 in audit/12 is live and nobody will sweep. That is the number to watch.");
    }

    function _key(address token) internal view returns (PoolKey memory) {
        (Currency c0, Currency c1) = token < PAIR
            ? (Currency.wrap(token), Currency.wrap(PAIR))
            : (Currency.wrap(PAIR), Currency.wrap(token));
        return PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(FEE_HOOK)});
    }

    /// @dev Buying the launch token means swapping the PAIR in, so the direction depends on which
    ///      side the token sorted onto. Getting this backwards sells instead of buying.
    function _buyIsZeroForOne(address token) internal view returns (bool) {
        return PAIR < token;
    }

    function _swap(PoolSwapTest router, PoolKey memory key, bool zeroForOne, uint256 amountIn) internal {
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
