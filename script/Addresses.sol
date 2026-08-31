// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Addresses
/// @notice Deployment constants for Ethereum L1 and Sepolia.
///
/// @dev **Every address in this file was verified with `eth_getCode` against a live RPC on
///      2026-08-31, not copied from documentation.** The byte counts are recorded so a future
///      reader can re-run the same check and notice if something moved or was redeployed.
///
///      Rule for adding anything here: query the chain first. Uniswap's own deployment docs warn
///      that v4 addresses are NOT consistent across chains, and this codebase's entire reason for
///      existing is that names and symbols are not identity - only addresses are.
library Addresses {
    // ===========================================================================================
    // Ethereum mainnet - chainid 1
    // ===========================================================================================

    uint256 internal constant MAINNET_CHAIN_ID = 1;

    // --- Uniswap v4 (verified 2026-08-31) ---
    /// @dev 24,009 bytes. Note how close that is to the EIP-170 limit of 24,576 - Uniswap had to
    ///      fight for this too. Our launcher has the same ceiling.
    address internal constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant MAINNET_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e; // 23,877 b
    address internal constant MAINNET_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af; // 19,499 b
    address internal constant MAINNET_STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227; // 3,531 b
    address internal constant MAINNET_QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203; // 5,820 b

    /// @dev Permit2 and the deterministic CREATE2 deployer are the same address on every chain.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // 9,152 b
    /// @dev Foundry's CREATE2 deployer. Required for mining hook addresses - a v4 hook's
    ///      permissions are encoded in the low 14 bits of its address, so every hook variant needs
    ///      its own mined salt. All salts must be re-mined for L1: the init code hash changes when
    ///      the constructor's PoolManager argument changes.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C; // 69 b

    // --- Pair currencies (verified 2026-08-31) ---
    address internal constant MAINNET_WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // 3,124 b
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 2,186 b, 6 dp

    /// @notice BTSE's wrapped Monero. The launch pair this build targets.
    /// @dev 7,404 bytes, 18 decimals, totalSupply 7,000.00000000000000011, not a proxy.
    ///      Liquidity as of 2026-08-31: ~$316,681 across 4 pools, the main one being a Uniswap **V2**
    ///      WXMR/WETH pair created 2021-01-06 holding ~$310K and turning over ~$17K/day.
    ///
    ///      KNOWN RISKS, accepted deliberately:
    ///        - custodial; BTSE holds the underlying XMR, no on-chain proof of reserve
    ///        - bytecode exposes `pause()`/`unpause()` - BTSE can freeze every pool paired to it
    ///        - bytecode exposes `isBlackListed(address)`/`addBlackList(address)` - a blacklisted
    ///          Distributor silently stops paying, because `_trySend` skips failures by design
    ///        - `mint()` exists under AccessControl (no `owner()`; not Ownable)
    ///      Mitigating evidence: 5.6 years live with none of those powers exercised.
    ///
    ///      NOT USD-PRICEABLE ON L1. Register with `approvePairWithoutOracle`.
    address internal constant MAINNET_WXMR = 0x465e07d6028830124BE2E4aA551fBe12805dB0f5;

    // --- Chainlink (verified 2026-08-31) ---
    /// @dev ETH/USD push feed, 8 decimals, ~1h heartbeat. Read $2,417.09 at 13 minutes old.
    ///      Set `maxStaleness` to a multiple of the heartbeat (3h is sane), never equal to it.
    address internal constant MAINNET_ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    /// @dev Chainlink Data Streams VerifierProxy, 7,009 bytes.
    ///      An XMR/USD Data Stream DOES exist, but Data Streams is PULL-based: a caller submits a
    ///      signed report to a state-changing, subscription-billed `verify()`. That is architecturally
    ///      incompatible with `PairRegistry.priceUsd`, which is a `view`. Recorded here for when the
    ///      oracle question is revisited; nothing in this codebase uses it yet.
    address internal constant MAINNET_DS_VERIFIER_PROXY = 0x5A1634A86e9b7BfEf33F0f3f3EA3b1aBBc4CC85F;

    /// @notice **Almost no memecoin has a USD feed on Ethereum L1.** Enumerated 2026-09 from
    ///         Chainlink's own reference-data-directory for mainnet - 292 feeds, 192 of them Crypto
    ///         - and cross-checked against `getFeed()` on the FeedRegistry at
    ///         `0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf`. The ETH/USD proxy below appears in that
    ///         directory, which is how we know the enumeration is reading the right thing.
    ///
    /// @dev    Of every pair currency considered for this launchpad:
    ///
    ///           DIRECT  ETH · USDC · UNI · WLFI · APE · LINK · AAVE · CRV
    ///           DERIVED SHIB   (only SHIB/ETH exists; multiply by ETH/USD)
    ///           NONE    PEPE · SPX · ELON · FLOKI · Mog · NPC · ANDY · APU · WOJAK ·
    ///                   PORK · WOLF · ENA · ANIME · XMR · XRP
    ///
    ///         **PEPE has no feed of any kind on L1** - not PEPE/USD, not PEPE/ETH. It is listed on
    ///         every major CEX and Chainlink does publish PEPE/USD on OTHER chains; they simply have
    ///         not deployed it here. Do not assume a feed exists because the asset is liquid.
    ///
    ///         CONSEQUENCE: a USD-denominated launch threshold (opening market cap, graduation)
    ///         cannot be computed on chain for the pairs a memecoin launchpad actually cares about.
    ///         Denominate thresholds in the PAIR ASSET on chain and render dollars in the UI.
    ///
    /// @dev **There is NO XMR/USD Chainlink push feed on Ethereum L1.** Both published aggregator
    ///      addresses return 0 bytes here. They are live on other chains and are recorded so nobody
    ///      re-derives this the hard way:
    ///        Optimism `0x2a8D91686A048E98e6CCF1A89E82f40D14312672` - $493.48, ~4 min fresh
    ///        Polygon  `0xBE6FB0AB6302B693368D0E9001fAF77ecc6571db` - $489.58, ~54 min fresh
    ///      Checked and absent on: Ethereum, Base, Arbitrum, BSC, Avalanche.
    address internal constant MAINNET_XMR_USD_FEED = address(0);

    // ===========================================================================================
    // Sepolia - chainid 11155111
    // ===========================================================================================

    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    // --- Uniswap v4 (verified 2026-08-31) ---
    address internal constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543; // 24,009 b
    address internal constant SEPOLIA_POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4; // 23,877 b
    address internal constant SEPOLIA_UNIVERSAL_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b; // 19,540 b
    address internal constant SEPOLIA_STATE_VIEW = 0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C; // 3,531 b
    address internal constant SEPOLIA_QUOTER = 0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227; // 5,820 b

    /// @dev v4-core test helpers, deployed by Uniswap on Sepolia only. Useful for driving swaps and
    ///      liquidity against a hook without writing a router.
    address internal constant SEPOLIA_POOL_SWAP_TEST = 0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe;
    address internal constant SEPOLIA_POOL_MODIFY_LIQUIDITY_TEST = 0x0C478023803a644c94c4CE1C1e7b9A087e411B0A;

    /// @dev **No WXMR exists on Sepolia**, and no XMR/USD feed either. Testnet runs must deploy a
    ///      MockERC20 stand-in and a MockAggregatorV3, which is what `test/mocks/` provides.
    address internal constant SEPOLIA_WXMR = address(0);

    // ===========================================================================================
    // Helpers
    // ===========================================================================================

    /// @notice PoolManager for the chain this is executing on. Reverts on unknown chains so a
    ///         script can never silently deploy against address(0).
    function poolManager(uint256 chainId) internal pure returns (address) {
        if (chainId == MAINNET_CHAIN_ID) return MAINNET_POOL_MANAGER;
        if (chainId == SEPOLIA_CHAIN_ID) return SEPOLIA_POOL_MANAGER;
        revert("Addresses: unsupported chain");
    }
}
