// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Configurable-decimals ERC-20 for tests and Sepolia deployments.
/// @dev Decimals are a constructor argument, not hardcoded to 18, because the decimal mismatch
///      between pair currencies is a real source of mispricing bugs - USDC is 6, WETH and WXMR are
///      18. Any test that only ever exercises 18 will miss that class of bug entirely.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @title MockBlacklistERC20
/// @notice An ERC-20 that can pause and blacklist, mirroring the powers actually present in BTSE's
///         WXMR bytecode (`pause`, `unpause`, `isBlackListed`, `addBlackList`).
/// @dev This exists so the failure modes we knowingly accepted are TESTED rather than assumed. A
///      blacklisted recipient must not brick the Distributor queue, and a paused pair currency must
///      fail in a way the system handles rather than corrupting accounting.
contract MockBlacklistERC20 is ERC20 {
    uint8 private immutable _decimals;

    bool public paused;
    mapping(address => bool) public isBlackListed;

    error TokenPaused();
    error Blacklisted(address account);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function addBlackList(address account) external {
        isBlackListed[account] = true;
    }

    function removeBlackList(address account) external {
        isBlackListed[account] = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert TokenPaused();
        if (isBlackListed[from]) revert Blacklisted(from);
        if (isBlackListed[to]) revert Blacklisted(to);
        super._update(from, to, value);
    }
}
