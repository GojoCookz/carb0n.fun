// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Distributor} from "./Distributor.sol";
import {LaunchMetadata} from "./types/LaunchMetadata.sol";

/// @title LaunchToken
/// @notice The ERC-20 a launch mints. Fixed supply, no mint function, no owner.
///
/// @dev Four deliberate properties:
///
///      1. **It is a CLONE TARGET, so it has an initializer instead of a constructor.**
///         `Launcher` deploys each launch as an EIP-1167 minimal proxy - 45 bytes instead of 8 KB of
///         creation code - which means this contract can never use `immutable` or a constructor for
///         per-launch data. A minimal proxy `delegatecall`s into this implementation, and
///         `immutable` values are baked into the IMPLEMENTATION's runtime code, so every clone would
///         read the implementation's values rather than its own. That is a silent, total corruption
///         of the max-wallet cap and the distributor pointer, so every one of those fields is
///         ordinary storage here.
///
///         The same constraint is why `name()` and `symbol()` are overridden: OpenZeppelin's `ERC20`
///         sets `_name` and `_symbol` in its constructor and keeps them `private`, which a clone
///         never runs.
///
///      2. **It deploys its own Distributor inside `initialize`.** The token and its dividend ledger
///         are paired in one call, so `Distributor.shareToken` is `address(this)` by construction and
///         cannot be pointed at a different token later. The alternative - deploy both, then wire
///         them with a setter - leaves a window where the pairing is wrong or forgeable.
///
///         The Distributor is a REAL deployment, not a clone, on purpose. Its `shareToken`,
///         `controller` and thresholds stay `immutable`, and `setBalance` is called TWICE on every
///         single transfer for the life of the token. Trading a one-time deploy cost for two
///         permanent SLOADs on the hottest path in the system is the wrong way round.
///
///      3. **There is no fee in `_update`.** Fees are taken by the v4 hook INSIDE the swap, not by
///         the token. Wallet-to-wallet transfers are therefore free, and no venue can route around
///         the fee by avoiding this contract. This is the single most important structural choice
///         inherited from the BaseStonk design and it is why the token stays this simple.
///
///      4. **Max wallet caps BUYS only.** The check fires only when tokens move OUT of the pool.
///         Selling is never blocked, wallet-to-wallet is never blocked. A cap that can block a sell
///         is a honeypot, and the difference is one condition.
contract LaunchToken is ERC20 {
    /// @notice The dividend ledger for this token, deployed alongside it in `initialize`.
    Distributor public distributor;

    /// @notice The v4 PoolManager. Transfers originating here are buys.
    /// @dev v4 is a singleton: pool reserves live in the PoolManager, not in a per-pair contract.
    ///      A v2/v3-shaped implementation that looks for a pair address finds nothing here.
    address public poolManager;

    /// @notice Largest balance an address may reach via a buy. Zero disables the cap entirely.
    uint256 public maxWallet;

    /// @notice Off-chain presentation data, written once at launch and never again.
    LaunchMetadata public metadata;

    /// @notice Addresses the max-wallet cap does not apply to (pool, launcher, hook, treasury).
    mapping(address account => bool) public exemptFromMaxWallet;

    string private _tokenName;
    string private _tokenSymbol;
    bool private _initialized;

    error MaxWalletExceeded(address to, uint256 attempted, uint256 cap);
    error ZeroAddress();
    error AlreadyInitialized();

    /// @param name_            token name
    /// @param symbol_          token symbol
    /// @param supply           full fixed supply, minted once to `recipient`
    /// @param recipient        receives the entire supply (the launcher, which seeds the pool)
    /// @param payoutToken      currency holders are paid dividends in - the PAIR asset, not this
    /// @param controller       the fee hook; the only address allowed to push distributions
    /// @param poolManager_     Uniswap v4 PoolManager
    /// @param maxWallet_       buy cap, or 0 to disable
    /// @param minPushPayout    dust guard below which a push send costs more gas than it delivers
    /// @param minShareForQueue balance below which a holder is not queued for pushes (can pull)
    struct InitParams {
        string name_;
        string symbol_;
        uint256 supply;
        address recipient;
        address payoutToken;
        address controller;
        address poolManager_;
        uint256 maxWallet_;
        uint256 minPushPayout;
        uint256 minShareForQueue;
        LaunchMetadata metadata;
    }

    /// @dev The implementation itself is sealed at deploy time. An uninitialised implementation
    ///      sitting behind a known address is an invitation; there is no reason to leave it open.
    constructor() ERC20("", "") {
        _initialized = true;
    }

    /// @notice One-shot setup, called by `Launcher` immediately after `Clones.cloneDeterministic`.
    /// @dev Deliberately permissionless but single-shot. Front-running it is possible in principle
    ///      and worthless in practice: a clone's address is derived from the salt the launcher
    ///      chose, so an attacker initialising it first produces a token at an address the launcher
    ///      then refuses to use (the launch reverts on the ordering or wiring checks) and gains a
    ///      token nobody has heard of. Adding an authorised initialiser would cost a storage slot
    ///      and an SLOAD to prevent someone burning their own gas.
    function initialize(InitParams calldata p) external {
        if (_initialized) revert AlreadyInitialized();
        if (p.recipient == address(0) || p.poolManager_ == address(0)) revert ZeroAddress();
        _initialized = true;

        _tokenName = p.name_;
        _tokenSymbol = p.symbol_;
        poolManager = p.poolManager_;
        maxWallet = p.maxWallet_;
        metadata = p.metadata;

        // The PoolManager and the launcher are both passed through so the Distributor can exclude
        // them at construction. Between them they hold the entire supply for the whole of the
        // launch, and neither is a holder - the pool is reserves and the launcher is a conduit.
        //
        // `supply / 1e6` is the distribution floor: 0.0001% of supply must be in real hands before
        // a fee is spread across it. Below that the per-share accumulator inflates far enough to
        // overflow later and brick every transfer.
        distributor = new Distributor(
            address(this),
            p.payoutToken,
            p.controller,
            p.poolManager_,
            p.recipient,
            p.minPushPayout,
            p.minShareForQueue,
            p.supply / 1e6
        );

        // The pool, the launcher and the hook hold large balances as infrastructure, never as
        // holders. Capping them would break the launch; paying them dividends would silently
        // redirect holder yield to the protocol.
        exemptFromMaxWallet[p.poolManager_] = true;
        exemptFromMaxWallet[p.recipient] = true;
        exemptFromMaxWallet[p.controller] = true;
        exemptFromMaxWallet[address(this)] = true;
        exemptFromMaxWallet[address(distributor)] = true;

        _mint(p.recipient, p.supply);
    }

    /// @dev OpenZeppelin stores name/symbol in constructor-set private storage a clone never runs.
    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /// @dev Balance-change hook. Two jobs, in this order:
    ///        1. enforce the buy cap
    ///        2. tell the Distributor both sides' new balances
    ///
    ///      The Distributor MUST be updated with post-transfer balances, which is why the calls sit
    ///      after `super._update` rather than before. Updating with stale balances silently
    ///      misallocates every dividend from that point forward.
    function _update(address from, address to, uint256 value) internal override {
        // A buy is tokens leaving the pool. Mints (from == 0) are the initial supply, not buys.
        if (maxWallet != 0 && from == poolManager && !exemptFromMaxWallet[to]) {
            uint256 resulting = balanceOf(to) + value;
            if (resulting > maxWallet) revert MaxWalletExceeded(to, resulting, maxWallet);
        }

        super._update(from, to, value);

        // address(0) is the mint/burn counterparty and is permanently excluded inside Distributor.
        Distributor d = distributor;
        if (from != address(0)) d.setBalance(from, balanceOf(from));
        if (to != address(0)) d.setBalance(to, balanceOf(to));
    }
}
