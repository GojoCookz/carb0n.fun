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
            openingWindow: 0, openingFeeBps: 0, metadata: LaunchMetadata({
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

    /// @dev Warp past the end of the current dividend stream.
    ///
    ///      `Distributor.distribute` no longer credits `_magnifiedPayoutPerShare` in the instant
    ///      `sweep()` calls it - it arms a linear vest over `STREAM_WINDOW` (24 hours). **That
    ///      change is what closes E-03**, and it is why the two attack tests below now assert the
    ///      opposite of what they were written to assert.
    ///
    ///      Note what it does NOT delay: the pair currency itself still lands on the distributor,
    ///      the creator, the platform and the sweeper's bounty inside the sweep. Money and
    ///      entitlement are on different clocks now, and every P/L in this file is money.
    ///
    ///      `skip` reads the clock back through the cheatcode; `via_ir` caches `block.timestamp`
    ///      and silently no-ops a chained `vm.warp(block.timestamp + X)`.
    function _vest(Distributor dist) internal {
        skip(uint256(dist.STREAM_WINDOW()) + 1);
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

    /// @dev **PARTIALLY FIXED, and the residue is the point.** The bar used to be settable one wei
    ///      above `openingMarketCap`, which `_validate` compared against the number the creator
    ///      TYPED. The opening tick is snapped, so the pool really opens at 100.2905 pair, and a
    ///      100.000000000000000001 bar meant the launch was **born graduated**: measured cost to
    ///      latch it was -0.0003 pair, a third of a basis point of the opening cap.
    ///
    ///      `Launcher._assertNotBornGraduated` now refuses that launch outright (asserted first
    ///      below). What it does NOT and cannot fix is E-02 itself: the bar may still sit just
    ///      above the REAL opening price, and latching it is still a spot-price push that costs
    ///      only the buy fee. Graduation is a spot read, and only a TWAP or a cumulative-volume
    ///      measure changes that.
    function test_E02b_theCheapestLegalGraduationBarIsJustAboveTheRealOpen() public {
        // The old configuration is now refused: the pool would open above its own bar.
        Launcher.LaunchParams memory refused = _baseParams();
        refused.graduationThreshold = M + 1;
        vm.prank(creator);
        vm.expectPartialRevert(Launcher.BornGraduated.selector);
        launcher.launch(refused);

        // The cheapest bar that IS legal sits just above the snapped opening price - and it is
        // still latchable for the buy fee on a small push.
        Launcher.LaunchParams memory p = _baseParams();
        p.graduationThreshold = M + M / 50; // 2% above the requested open, ~1.7% above the real one
        (address t, PoolKey memory k, PoolId id) = _launch(p);
        _approveTrader(t, attacker);

        assertLt(hook.marketCapOf(id), p.graduationThreshold, "precondition: not born graduated");

        uint256 start = pair.balanceOf(attacker);
        _buy(k, attacker, 1e18);
        hook.checkGraduation(id);
        _sell(k, attacker, IERC20(t).balanceOf(attacker));

        int256 cost = int256(pair.balanceOf(attacker)) - int256(start);
        console2.log("E-02b  cost to latch the cheapest legal bar:", _p(cost));
        assertTrue(hook.hasGraduated(id), "graduated on a 1 pair buy");
        assertLt(-cost, int256(0.05e18), "for the buy fee on a one-pair push and nothing else");
    }

    /// @dev **THIS FINDING IS FIXED. The test is now the regression guard, not the exploit.**
    ///
    ///      As originally written this asserted the OPPOSITE: forcing graduation was not merely
    ///      cheap, it was FREE. The push that fakes the market cap also made the attacker the
    ///      dominant shareholder for one instant, so folding `sweep()` into the same bundle
    ///      recovered their own buy fee - plus whatever pot the pool had already accumulated -
    ///      out of the holders' side of the split, and turned a -3.8528 pair cost into a profit.
    ///
    ///         buy -> checkGraduation -> sweep -> sell -> withdraw
    ///
    ///      The bundle is unchanged and still runs end to end. What changed is that
    ///      `Distributor.distribute` arms a 24-hour linear vest instead of crediting the
    ///      accumulator, so the leg that used to pay for the whole exercise now pays nothing.
    ///
    ///      Measured on this exact scenario, identical to the wei in both currency orderings:
    ///
    ///        | | instant credit (audit/05) | streaming |
    ///        |---|---|---|
    ///        | bare push, no sweep           | -3.8528 pair     | **-3.8828 pair** (measured
    ///          in-test against this turnover pool, not quoted) |
    ///        | push with the sweep folded in | **+4.0114 pair** | **-3.8027 pair** |
    ///        | so the sweep leg is worth     | +7.86 pair       | **+0.0801 pair** |
    ///
    ///      The sweep leg is still worth SOMETHING - the bundle comes out 0.0801 pair ahead of
    ///      the bare push - and the test asserts that residue is EXACTLY the 0.5%
    ///      `SWEEP_BOUNTY_BPS` on the pot, to the wei. That is payment for gas on a public good
    ///      and was never the problem. `audit/08-streaming-designs.md` predicted precisely this:
    ///      "the 0.5% sweep bounty becomes safe again ... `FeeHook.sol:154` can stay". The
    ///      dividend leg, which was the profitable part, is now worth zero.
    ///
    ///      **Graduation is still forgeable.** E-02 and E-02b are untouched and still fail-by-
    ///      design as findings: a spot read is a spot read. All that changed is that the attacker
    ///      now has to pay for it.
    function test_E02c_foldingTheSweepIntoTheGraduationPushNoLongerPaysForIt() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        Distributor dist = LaunchToken(t).distributor();
        _approveTrader(t, attacker);

        // A pool with ordinary turnover, i.e. an unswept pot and a small resting register.
        _buildTurnoverPool(t, k, 5e18, 20e18, 20);

        uint256 curveIn = _sqrt(M * (M * 5)) - M;
        uint256 notional = (curveIn * 10_000) / (10_000 - 300) + 2e18;

        // ---- CONTROL: the bare push, measured here rather than quoted from the old audit, so
        // the "does the sweep leg pay for it" question is answered against this exact state.
        uint256 snap = vm.snapshotState();
        uint256 bareStart = pair.balanceOf(attacker);
        _buy(k, attacker, notional);
        hook.checkGraduation(id);
        _sell(k, attacker, IERC20(t).balanceOf(attacker));
        int256 bare = int256(pair.balanceOf(attacker)) - int256(bareStart);
        vm.revertToState(snap);

        // ---- THE BUNDLE: identical, plus the sweep the attacker used to be paid for.
        uint256 start = pair.balanceOf(attacker);
        _buy(k, attacker, notional);
        hook.checkGraduation(id);
        uint256 potAtSweep = hook.pendingFees(id);
        vm.prank(attacker);
        hook.sweep(k);

        // The instant the pot is distributed, the attacker owns most of the register and is
        // entitled to none of it. This is the line the whole change exists for.
        assertEq(dist.withdrawableOf(attacker), 0, "a zero-block position was credited");

        _sell(k, attacker, IERC20(t).balanceOf(attacker));
        if (dist.withdrawableOf(attacker) != 0) {
            vm.prank(attacker);
            dist.withdraw();
        }
        int256 pl = int256(pair.balanceOf(attacker)) - int256(start);

        // Waiting out the window does not rescue it either: the correction froze on the way out.
        _vest(dist);
        assertEq(dist.withdrawableOf(attacker), 0, "the exited attacker vested in afterwards");
        assertEq(
            int256(pair.balanceOf(attacker)) - int256(start), pl, "the P/L moved after they left"
        );

        uint256 bounty = (potAtSweep * hook.SWEEP_BOUNTY_BPS()) / 10_000;
        console2.log("E-02c  notional pushed              :", _p(int256(notional)));
        console2.log("E-02c  bare push, no sweep          :", _p(bare));
        console2.log("E-02c  NET P/L OF A FAKE GRADUATION :", _p(pl));
        console2.log("E-02c  what the sweep leg was worth :", _p(pl - bare));
        console2.log("E-02c  ...the 0.5% bounty alone     :", _p(int256(bounty)));

        assertTrue(hook.hasGraduated(id), "latched");
        assertLt(pl, 0, "REGRESSION: the attacker is once again PAID to forge the signal");
        assertGt(pl, bare, "the sweep bounty is still earned - it just no longer pays for the push");
        // Everything the sweep leg is worth is the bounty, to the wei. Nothing from the pot
        // itself reaches a position that was opened and closed inside one block. Both branches
        // run the identical two swaps from the identical snapshot, so this is exact, not
        // approximate - if entitlement ever leaks back into the same block, it shows up here
        // before it shows up in the sign of `pl`.
        assertEq(
            pl - bare,
            int256(bounty),
            "the sweep leg paid more than the bounty: entitlement is leaking into the same block"
        );
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
    //
    // THE CRITICAL OF THIS AUDIT, AND IT IS NOW CLOSED. Everything below is a regression guard.
    // ============================================================================================

    /// @dev **E-03 WAS THE CRITICAL. IT IS FIXED, AND THIS TEST IS THE PROOF.**
    ///
    ///      Nothing about the attack has been made harder. `sweep()` is still permissionless, it
    ///      still pays a 0.5% bounty to whoever calls it, the attacker still does not have to
    ///      predict a sweep or win a race, and the whole bundle still executes end to end:
    ///
    ///         buy -> sweep -> sell -> withdraw
    ///
    ///      What changed is one line of `Distributor`. `distribute` no longer credits
    ///      `_magnifiedPayoutPerShare` in the instant it is called - it arms a linear vest over
    ///      `STREAM_WINDOW` (24 hours), and `_checkpoint()` folds in elapsed time at the top of
    ///      every entry point. Inside one block `elapsed == 0`, so a position opened and closed
    ///      in the same block is credited **exactly zero**, not "a sliver". The revenue leg of
    ///      the attack is gone; the cost leg - `feeBps` on the buy - is untouched.
    ///
    ///      Measured on this exact scenario (5-pair resting holder, 400 pair of round-trip
    ///      volume, 40 pair deployed, 12.1500 pair in the pot), identical to the wei in both
    ///      currency orderings:
    ///
    ///        |                            | instant credit (audit/05) | streaming        |
    ///        |----------------------------|---------------------------|------------------|
    ///        | attacker net P/L           | **+4.8738 pair**          | **-1.1332 pair** |
    ///        | ...return on capital       | +12.18%                   | -2.83%           |
    ///        | ...share of the pot taken  | 40.11%                    | -9.32%           |
    ///        | attacker's share of the register at the sweep | ~ | 84.78% (unchanged)   |
    ///        | alice owed, honest sweep   | 6.4479 pair               | 6.4479 pair      |
    ///        | alice owed, attacked sweep | (lost 83.28%)             | **7.0847 pair**  |
    ///        | so the attack costs alice  | **-83.28%**               | **+0.6368 pair** |
    ///
    ///      The honest resting holder does not merely stop losing. She ends up 9.88% AHEAD of the
    ///      control, because the attacker's own buy fee joins the pot and then vests entirely to
    ///      her - she is the only party still holding when the clock runs. **The attack has
    ///      become a donation to the people it used to rob.**
    ///
    ///      What the attacker keeps is 0.0607 pair, and that is the `SWEEP_BOUNTY_BPS` they could
    ///      have had for calling `sweep()` while holding nothing at all. The buy leg is worth
    ///      **-1.1940 pair**, i.e. exactly the fee it costs and not one wei of entitlement.
    ///
    ///      The residual, stated plainly and unchanged from `audit/08-streaming-designs.md`: a
    ///      buyer who takes a large position right after a sweep and genuinely holds the full
    ///      window does capture the stream. That is not an attack, that is a holder, and every
    ///      design in the streaming literature accepts it.
    function test_E03_buySweepSellIsUnprofitableUnderStreaming() public {
        (address t, PoolKey memory k, PoolId id) = _defaultLaunch();
        Distributor dist = LaunchToken(t).distributor();
        _approveTrader(t, attacker);

        _buildTurnoverPool(t, k, 5e18, 20e18, 20);
        uint256 pot = hook.pendingFees(id);
        assertGt(pot, 0, "there is a pot to take");
        uint256 register = dist.totalShares();

        // ---- Control: an honest stranger sweeps from this exact state, and the window runs out.
        uint256 snap = vm.snapshotState();
        vm.prank(carol);
        hook.sweep(k);
        _vest(dist);
        uint256 aliceHonest = dist.withdrawableOf(alice);
        assertGt(aliceHonest, 0, "control: the resting holder is paid at all");
        vm.revertToState(snap);

        // ---- Baseline: the attacker calls `sweep()` and holds NOTHING. This is the number the
        // bundle has to beat, not zero - the 0.5% bounty is payment for gas on a public good and
        // was never the finding. See `_bareSweepBounty`.
        int256 bountyOnly = _bareSweepBounty(k);

        // ---- Attack: buy, sweep, sell, withdraw. One transaction's worth of actions.
        uint256 start = pair.balanceOf(attacker);
        uint256 buyIn = 40e18;

        _buy(k, attacker, buyIn);
        uint256 alpha = (dist.shareOf(attacker) * 10_000) / dist.totalShares();
        assertGt(alpha, 5_000, "precondition: the buy really did make them the dominant holder");

        vm.prank(attacker);
        hook.sweep(k);

        // THE ASSERTION THE WHOLE CHANGE EXISTS FOR. They own the overwhelming majority of the
        // share register at the exact instant the pot is distributed, and they are entitled to
        // none of it. Under instant credit this read ~40% of the pot.
        assertEq(dist.withdrawableOf(attacker), 0, "a zero-block position was credited");

        _sell(k, attacker, IERC20(t).balanceOf(attacker));
        if (dist.withdrawableOf(attacker) != 0) {
            vm.prank(attacker);
            dist.withdraw();
        }
        int256 profit = int256(pair.balanceOf(attacker)) - int256(start);

        // Nor can they simply come back tomorrow: `_setShares` froze their correction against the
        // accumulator as it stood when they exited, which was before any of this vested.
        _vest(dist);
        assertEq(dist.withdrawableOf(attacker), 0, "the exited attacker vested in later");
        assertEq(
            int256(pair.balanceOf(attacker)) - int256(start),
            profit,
            "the attacker's P/L moved after they had already left"
        );

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
            "E-03   HONEST HOLDER GAIN           :", _p(int256(aliceAttacked) - int256(aliceHonest))
        );
        console2.log("E-03   P/L of just calling sweep()  :", _p(bountyOnly));
        console2.log("E-03   ...what the BUY LEG is worth :", _p(profit - bountyOnly));

        assertLt(profit, 0, "REGRESSION: the zero-duration round trip is profitable again");
        // The sharpest form of the fix: taking a position ahead of the sweep is strictly worse
        // than not taking one. Everything the attacker earns, they would have earned by doing
        // nothing but paying the gas.
        assertLt(profit, bountyOnly, "REGRESSION: the buy leg buys entitlement again");
        assertGe(
            aliceAttacked, aliceHonest, "REGRESSION: the resting holder was diluted by the attack"
        );
    }

    /// @dev **There is no longer an optimum, because there is no longer a hump.**
    ///
    ///      Under instant credit the attacker paid `feeBps * B` and recovered the bounty plus
    ///      `alpha * holderShare * (pot + their own fee)`. `alpha` rose with `B` while the cost
    ///      rose linearly, so the curve had a maximum and sweeping `B` located it. Under
    ///      streaming the `alpha` term is identically zero at zero blocks held, so the only two
    ///      terms left are a bounty that does not depend on `B` at all and a fee that is linear
    ///      in it. The curve is now monotonically DECREASING and negative everywhere - bigger
    ///      buys simply lose more.
    ///
    ///      **The baseline is the bare sweep, not zero.** Calling `sweep()` while holding nothing
    ///      earns `SWEEP_BOUNTY_BPS` and always has - that is what the bounty is for, and E-04
    ///      shows it cannot be farmed. At a 2-pair buy the fee is smaller than that bounty, so
    ///      the bundle still nets a positive 0.0010 pair; measuring against zero would mis-read
    ///      the gas subsidy as a surviving exploit. The question E-03 asks is whether the BUY
    ///      adds anything, and the answer is that it subtracts, at every size.
    function test_E03b_theProfitCurveHasNoProfitableSize() public {
        console2.log("E-03b  buyIn(pair) | profit(pair) | ROI | vs. just sweeping");
        uint256[7] memory sizes =
            [uint256(2e18), 5e18, 10e18, 20e18, 40e18, 120e18, 400e18];
        int256 previous = type(int256).max;
        for (uint256 i = 0; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            (int256 profit, int256 bountyOnly) = _runDividendAttack(M, 5e18, 20e18, 20, sizes[i]);
            console2.log(
                string.concat(
                    "E-03b  ",
                    _p(int256(sizes[i])),
                    " | ",
                    _p(profit),
                    " | ",
                    _signedPct(profit, sizes[i]),
                    " | ",
                    _p(profit - bountyOnly)
                )
            );
            assertLt(
                profit, bountyOnly, "REGRESSION: taking a position ahead of the sweep pays again"
            );
            assertLt(profit, previous, "REGRESSION: the profit curve grew a hump again");
            previous = profit;
            vm.revertToState(snap);
        }
    }

    /// @dev The old finding was that the attack never becomes UNPROFITABLE at any pool size -
    ///      the payoff scaled with the pot and the pot scaled with the pool, so there was only a
    ///      size at which the profit stopped clearing L1 gas (~800k gas, 0.016 pair at 20 gwei
    ///      when the pair is WETH), and the table bracketed that crossing.
    ///
    ///      **Under streaming there is no crossing to bracket.** The payoff no longer scales with
    ///      anything, because it is zero, so the bundle is under water at every pool size from a
    ///      0.1-pair opening cap to a 100-pair one. Three orders of magnitude, one sign.
    function test_E03c_theDividendAttackIsUnderWaterAtEveryPoolSize() public {
        uint256 gasCost = 800_000 * 20 gwei; // 0.016 ETH
        console2.log("E-03c  gas floor for the bundle (pair):", _p(int256(gasCost)));
        console2.log("E-03c  openingMcap | volume | profit | clears gas?");

        uint256[5] memory caps = [uint256(0.1e18), 0.5e18, 2e18, 20e18, 100e18];
        for (uint256 i = 0; i < caps.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 c = caps[i];
            // Scale the scenario with the pool: 5% resting float, 4x the cap in round-trip volume.
            (int256 profit, int256 bountyOnly) =
                _runDividendAttack(c, c / 20, c / 5, 20, (c * 4) / 10);
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
            assertLt(profit, 0, "REGRESSION: some pool size makes the zero-block attack pay");
            assertLt(profit, bountyOnly, "REGRESSION: the buy leg is worth something again");
            vm.revertToState(snap);
        }
    }

    /// @dev The same attack across the legal fee band. `platformShareBps = 100*BPS/feeBps`, so the
    ///      holders' slice of every fee is `(1 - 100/feeBps) * (1 - creatorBps)`. A HIGHER trading
    ///      fee used to leave a bigger slice for holders, which was a bigger slice for the
    ///      attacker to take - and the old measurement was that this NETTED OUT IN THE ATTACKER'S
    ///      FAVOUR: +30.12 pair at the 1000 bps ceiling, ten times the profit at 100 bps. The fee
    ///      knob a creator reaches for to reward holders more was the same knob that made robbing
    ///      them more lucrative.
    ///
    ///      **That is inverted now.** The holders' slice is unreachable at zero blocks held, so
    ///      raising `feeBps` only raises the attacker's own cost. The band runs one way.
    function test_E03d_aHigherFeeNowOnlyMakesTheAttackWorseForTheAttacker() public {
        console2.log("E-03d  feeBps | creatorBps | attacker profit");
        // 110, not 100: `feeBps == PLATFORM_VOLUME_BPS` is now refused outright by the platform
        // floor (E-09), because at exactly the floor the creator and the holders receive nothing.
        uint16[4] memory fees = [uint16(110), 300, 600, 1000];
        int256 previous = type(int256).max;
        for (uint256 i = 0; i < fees.length; ++i) {
            uint256 snap = vm.snapshotState();
            (int256 profit, int256 bountyOnly) = _runDividendAttackAtFee(fees[i], 0);
            console2.log(
                string.concat(
                    "E-03d  ", vm.toString(uint256(fees[i])), " | 0 | ", _p(profit)
                )
            );
            assertLt(profit, 0, "REGRESSION: the attack pays at some legal fee rate");
            assertLt(profit, bountyOnly, "REGRESSION: the buy leg is worth something again");
            assertLt(profit, previous, "REGRESSION: a higher fee is once again better for the attacker");
            previous = profit;
            vm.revertToState(snap);
        }
    }

    // ---- attack plumbing -----------------------------------------------------------------------

    /// @dev The control that matters now. `sweep()` is permissionless and pays
    ///      `SWEEP_BOUNTY_BPS` to whoever calls it, so **doing nothing but calling it, holding no
    ///      position at all, has always been mildly profitable** - that is what the bounty is
    ///      FOR, and E-04 already establishes it cannot be farmed. The E-03 question is a
    ///      different one: does taking a POSITION ahead of the sweep add anything on top?
    ///
    ///      Under instant credit it added a share of the whole pot. Under streaming it adds
    ///      nothing and costs `feeBps`, so the bundle must come out strictly BELOW this baseline
    ///      at every size. Comparing against zero instead would mis-read the bounty as an
    ///      exploit at small buy sizes, where the fee on a tiny position is less than the bounty
    ///      the attacker would have earned anyway.
    function _bareSweepBounty(PoolKey memory k) internal returns (int256 bounty) {
        uint256 snap = vm.snapshotState();
        uint256 start = pair.balanceOf(attacker);
        vm.prank(attacker);
        hook.sweep(k);
        bounty = int256(pair.balanceOf(attacker)) - int256(start);
        require(vm.revertToState(snap), "bare-sweep control could not be unwound");
    }

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

    /// @return profit the P/L of `buy -> sweep -> sell -> withdraw`, measured over the attacker's
    ///         whole LIFETIME rather than just the atomic bundle
    /// @return bountyOnly the P/L of calling `sweep()` from the identical state while holding
    ///         nothing at all - the baseline the bundle has to beat to be an attack
    function _runDividendAttack(
        uint256 mcap,
        uint256 restingPair,
        uint256 tripPair,
        uint256 trips,
        uint256 buyIn
    ) internal returns (int256 profit, int256 bountyOnly) {
        Launcher.LaunchParams memory p = _baseParams();
        p.openingMarketCap = mcap;
        p.graduationThreshold = mcap * 5;
        (address t, PoolKey memory k,) = _launch(p);
        Distributor dist = LaunchToken(t).distributor();
        _approveTrader(t, attacker);

        _buildTurnoverPool(t, k, restingPair, tripPair, trips);

        bountyOnly = _bareSweepBounty(k);

        uint256 start = pair.balanceOf(attacker);
        _buy(k, attacker, buyIn);
        vm.prank(attacker);
        hook.sweep(k);
        _sell(k, attacker, IERC20(t).balanceOf(attacker));
        if (dist.withdrawableOf(attacker) != 0) {
            vm.prank(attacker);
            dist.withdraw();
        }
        // Give the attacker the benefit of the doubt: let the whole window run and let them try
        // again from a zero-share position. Reporting only the atomic P/L would understate the
        // payoff if the stream ever leaked to an exited holder, so the tables measure LIFETIME.
        _vest(dist);
        if (dist.withdrawableOf(attacker) != 0) {
            vm.prank(attacker);
            dist.withdraw();
        }
        profit = int256(pair.balanceOf(attacker)) - int256(start);
    }

    function _runDividendAttackAtFee(uint16 feeBps, uint16 creatorBps)
        internal
        returns (int256 profit, int256 bountyOnly)
    {
        Launcher.LaunchParams memory p = _baseParams();
        p.feeBps = feeBps;
        p.creatorBps = creatorBps;
        (address t, PoolKey memory k,) = _launch(p);
        Distributor dist = LaunchToken(t).distributor();
        _approveTrader(t, attacker);

        _buildTurnoverPool(t, k, 5e18, 20e18, 20);

        bountyOnly = _bareSweepBounty(k);

        uint256 start = pair.balanceOf(attacker);
        _buy(k, attacker, 40e18);
        vm.prank(attacker);
        hook.sweep(k);
        _sell(k, attacker, IERC20(t).balanceOf(attacker));
        if (dist.withdrawableOf(attacker) != 0) {
            vm.prank(attacker);
            dist.withdraw();
        }
        // Lifetime, not atomic - see `_runDividendAttack`.
        _vest(dist);
        if (dist.withdrawableOf(attacker) != 0) {
            vm.prank(attacker);
            dist.withdraw();
        }
        profit = int256(pair.balanceOf(attacker)) - int256(start);
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
    ///
    ///      **Unaffected by streaming, and worth saying why.** A sandwich is atomic by
    ///      definition - the front-run, the victim call and the unwind are one bundle - so the
    ///      attacker's position is open for zero blocks and the dividend leg of their P/L is now
    ///      structurally zero. The `withdraw` below is therefore dead code kept for shape; the
    ///      number it reports is pure sandwich P/L, which only makes the "grief, not theft"
    ///      reading stronger. The burn shortfall itself never depended on the dividend path.
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

    /// @notice REGRESSION GUARD. `maxWallet` now bounds the FINAL HOLDING, not just one purchase.
    ///
    /// @dev THE BUG. `LaunchToken._update` checked the cap only when `from == poolManager`, so
    ///      wallet-to-wallet transfers were uncapped and the cap did not bound what anyone could
    ///      end up owning. Buy wide, then consolidate.
    ///
    ///      MEASURED BEFORE, this exact scenario, both currency orderings:
    ///
    ///        advertised cap                : 200 bps of supply   ("2% max wallet")
    ///        wallets used                  : 12
    ///        final SINGLE-wallet holding   : 2,376 bps of supply (23.76% - 11.9x the cap)
    ///        gas per extra wallet          : 243,636   (~$17 at 20 gwei)
    ///
    ///      MEASURED AFTER: the twelve buys still succeed (each is under the cap and the cap has
    ///      not changed), and the FIRST consolidating transfer reverts
    ///      `MaxWalletExceeded(attacker, 3.96e25, 2e25)`. The attacker's final holding is 0.
    ///
    ///      THE FIX, and the property it must not break. The check now fires on every inbound
    ///      transfer to a non-exempt address instead of only on the pool's. **A sell can still
    ///      never be blocked** - a sell moves tokens INTO the PoolManager, which is exempt - so
    ///      this is not a honeypot, and that is asserted below rather than argued. The dead
    ///      address is exempt too, or a launch with both a burn wedge and a cap would brick its
    ///      own `sweep` once cumulative burns crossed the cap. Deliveries out of the launcher
    ///      (the dev buy, bounded by its own stricter rules) are the one exception.
    function test_E06_fixed_maxWalletNowBoundsTheFinalHoldingNotJustOneBuy() public {
        Launcher.LaunchParams memory p = _baseParams();
        p.maxWalletBps = 200; // "2% max wallet"
        (address t, PoolKey memory k,) = _launch(p);
        uint256 cap = LaunchToken(t).maxWallet();

        // A single buy above the cap is refused - unchanged.
        vm.expectRevert();
        _buy(k, attacker, 60e18);

        // Twelve wallets, each buying just under the cap. Still entirely legal.
        uint256 wallets = 12;
        for (uint256 i = 0; i < wallets; ++i) {
            address w = address(uint160(0x200000 + i));
            _fund(w);
            _buyExactOut(k, w, (cap * 99) / 100);
            assertGt(IERC20(t).balanceOf(w), 0, "precondition: the spread buy worked");
        }

        // Consolidating is what used to be free. The FIRST transfer over the cap now reverts.
        address w0 = address(uint160(0x200000));
        uint256 bal0 = IERC20(t).balanceOf(w0);
        vm.prank(w0);
        IERC20(t).transfer(attacker, bal0);
        assertEq(IERC20(t).balanceOf(attacker), bal0, "the first consolidation is under the cap");

        address w1 = address(uint160(0x200001));
        uint256 bal1 = IERC20(t).balanceOf(w1);
        assertGt(bal0 + bal1, cap, "precondition: two wallets really do exceed the cap");
        vm.prank(w1);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchToken.MaxWalletExceeded.selector, attacker, bal0 + bal1, cap
            )
        );
        IERC20(t).transfer(attacker, bal1);

        uint256 finalHolding = IERC20(t).balanceOf(attacker);
        console2.log("E-06   advertised cap (bps supply)  :", _bpsOfSupply(cap));
        console2.log("E-06   final single-wallet holding  :", _bpsOfSupply(finalHolding));
        assertLe(finalHolding, cap, "a wallet ended up over the advertised 'max wallet'");

        // NOT A HONEYPOT. The whole reason the old check was narrow was that a cap which can block
        // a sell is a trap. Every one of these wallets can still sell its entire position, and the
        // over-cap attacker can sell theirs.
        _approveTrader(t, attacker);
        uint256 pairBefore = pair.balanceOf(attacker);
        _sell(k, attacker, IERC20(t).balanceOf(attacker));
        assertGt(pair.balanceOf(attacker) - pairBefore, 0, "SELLING WAS BLOCKED - honeypot");
        assertEq(IERC20(t).balanceOf(attacker), 0, "the whole position could not be sold");

        _approveTrader(t, w1);
        uint256 w1PairBefore = pair.balanceOf(w1);
        _sell(k, w1, IERC20(t).balanceOf(w1));
        assertGt(pair.balanceOf(w1) - w1PairBefore, 0, "a capped wallet could not sell");
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
    ///
    /// @dev **HALF FIXED, and the half that is not is the product decision.**
    ///
    ///      (2) IS FIXED. `Launcher._assertNotBornGraduated` reads the pool's real market cap
    ///      after the seed and the dev buy have both happened and refuses the launch. MEASURED:
    ///      this configuration used to launch with `marketCapOf == 2,112.5357 pair` against a
    ///      500 pair bar (**4.2x**), `checkGraduation` succeeding in the launch block and
    ///      `graduationProgressBps == 10,000` before the first buyer existed. It now reverts
    ///      `BornGraduated(500e18, 2112535799871658722160)`, asserted below.
    ///
    ///      (1) IS NOT FIXED AND IS NOT A DEFECT. A vested dev buy is UNCAPPED on purpose and
    ///      `VestingVault`'s own docstring says so: the cap and the vault protect against the same
    ///      thing by different means. The rest of this test is therefore rerun with an honest bar,
    ///      so the 78%-supply / 10%-fee / 100%-to-creator parameter space is still measured rather
    ///      than deleted - it is a disclosure problem for the front end, not an arithmetic one.
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

        // THE FIX: the "5x to graduate" badge on a launch that opens at 21x is refused outright.
        vm.prank(creator);
        vm.expectPartialRevert(Launcher.BornGraduated.selector);
        launcher.launch(p);

        // Everything else about this launch is still legal, so measure it against an honest bar.
        p.graduationThreshold = M * 50;
        (address t, PoolKey memory k, PoolId id) = _launch(p);
        address v = launcher.vaultOf(t);
        uint256 creatorHeld = IERC20(t).balanceOf(v);

        console2.log("E-07   creator supply (bps)         :", _bpsOfSupply(creatorHeld));
        console2.log("E-07   public float (bps)           :", 10_000 - _bpsOfSupply(creatorHeld));
        console2.log("E-07   spot mcap at launch          :", _p(int256(hook.marketCapOf(id))));
        console2.log("E-07   graduation bar               :", _p(int256(p.graduationThreshold)));
        console2.log("E-07   progress bps at launch       :", hook.graduationProgressBps(id));

        assertGt(_bpsOfSupply(creatorHeld), 7000, "the creator owns most of the supply");

        // NOT born graduated any more, and that is the whole guard.
        assertLt(hook.marketCapOf(id), p.graduationThreshold, "still born graduated");
        assertFalse(hook.checkGraduation(id), "GRADUATED IN THE LAUNCH BLOCK");
        assertLt(hook.graduationProgressBps(id), 10_000, "the UI bar is full before anyone bought");

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
        // A 9x dev buy carries the spot cap to ~9,445 pair inside the launch transaction, so the
        // default `M * 5` bar is now refused `BornGraduated`. That is E-07's other half and it is
        // fixed; this test is about the SEVEN-DAY FLOOR, so give it an honest bar and keep
        // measuring the thing it exists to measure.
        p.graduationThreshold = M * 200;

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

    /// @notice REGRESSION GUARD. The fee rate that paid the creator and the holders literally
    ///         nothing is now refused at configuration time.
    ///
    /// @dev THE BUG. `platformShareBps = PLATFORM_VOLUME_BPS * BPS / feeBps` (`FeeHook.sol`). The
    ///      floor check was `feeBps < PLATFORM_VOLUME_BPS`, so the minimum legal `feeBps = 100`
    ///      made that expression exactly `BPS`: `_routeFee` sent 100% to the platform and `rest`
    ///      was ZERO, no matter what `creatorBps` said.
    ///
    ///      MEASURED BEFORE, on a 100-pair buy with the creator advertising `creatorBps = 8000`:
    ///
    ///        feeBps | platform | creator | holders
    ///           100 |   0.9950 |  0.0000 |  0.0000   <- nothing, silently, forever
    ///           110 |   0.9949 |  0.0796 |  0.0199
    ///           150 |   0.9949 |  0.3980 |  0.0995
    ///           300 |   0.9949 |  1.5920 |  0.3980
    ///
    ///      MEASURED AFTER: `feeBps = 100` reverts `FeeBelowPlatformFloor(100)` out of
    ///      `configurePoolFull`, so the launch never happens. Every rate that IS legal pays the
    ///      creator and the holders something, asserted below at every point on the band.
    ///
    ///      The steep band above the floor is correct arithmetic and is left alone;
    ///      `FeeHook.effectiveSplitBps` is what lets a UI show the real number before signing.
    function test_E09_fixed_theMinimumFeeIsRejectedInsteadOfPayingHoldersNothing() public {
        // The configuration that used to pay two of the three recipients zero no longer launches.
        Launcher.LaunchParams memory refused = _baseParams();
        refused.feeBps = 100;
        refused.creatorBps = 8000;
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(FeeHook.FeeBelowPlatformFloor.selector, uint16(100))
        );
        launcher.launch(refused);

        console2.log("E-09   feeBps | platform | creator | holders");
        uint16[4] memory fees = [uint16(101), 110, 200, 300];
        for (uint256 i = 0; i < fees.length; ++i) {
            uint256 snap = vm.snapshotState();

            Launcher.LaunchParams memory p = _baseParams();
            p.feeBps = fees[i];
            p.creatorBps = 8000; // the creator ADVERTISES 80% to themselves
            (address t, PoolKey memory k, PoolId id) = _launch(p);
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

            // EVERY legal rate pays all three. That is the property the floor now guarantees.
            assertGt(toPlatform, 0, "the platform was paid nothing");
            assertGt(toCreator, 0, "the creator was paid nothing at a LEGAL fee rate");
            assertGt(toHolders, 0, "the holders were paid nothing at a LEGAL fee rate");

            // And the split is readable up front, so the steep band cannot surprise anybody.
            (uint16 pBps, uint16 cBps, uint16 hBps) = hook.effectiveSplitBps(id);
            assertEq(uint256(pBps) + cBps + hBps, 10_000, "the advertised split is not exhaustive");
            assertGt(cBps, 0, "effectiveSplitBps claims the creator gets nothing");
            assertGt(hBps, 0, "effectiveSplitBps claims holders get nothing");

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

        Distributor dist = LaunchToken(t).distributor();
        uint256 start = pair.balanceOf(creator);
        for (uint256 i = 0; i < 5; ++i) {
            _buy(k, creator, 100e18);
            vm.prank(creator);
            hook.sweep(k);
            // HOLD ACROSS THE WINDOW before unwinding. Under streaming, a washer who round-trips
            // inside one block collects no dividend at all, which would make this test pass for
            // a reason that has nothing to do with the platform's flat 1%. Waiting out the full
            // stream is the BEST case available to the washer and therefore the only honest way
            // to state "always lossy" - they recover the entire holder slice as the sole holder.
            _vest(dist);
            if (dist.withdrawableOf(creator) != 0) {
                vm.prank(creator);
                dist.withdraw();
            }
            _sell(k, creator, IERC20(t).balanceOf(creator));
            vm.prank(creator);
            hook.sweep(k);
        }
        // ...and the last sweep's stream too, though they have already exited into it.
        _vest(dist);
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
