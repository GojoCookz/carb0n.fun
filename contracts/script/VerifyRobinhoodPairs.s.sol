// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title VerifyRobinhoodPairs
///
/// @notice Reads a candidate pair currency off Robinhood Chain and prints what it actually is,
///         so an address can be admitted on evidence rather than on a ticker.
///
/// @dev **This exists because a symbol identifies nothing on this chain.** Measured on 4663:
///
///        - three contracts answer `symbol() == "USDG"`, with 279k, 173k and 169k holders
///        - five answer `WETH` or `wETH`
///        - four answer `XMR` or `Monero`, with supplies of 92, 100M, 1B and 100B - while real
///          Monero has 18.4M, twelve decimals, and NO CONTRACT AT ALL, being a separate chain
///          with no EVM
///        - `PairRegistry`'s own docstring records 361 contracts using `GME` and 416 using
///          another ticker, exactly one of each being real
///
///      The same pattern showed up off-chain too: a dividend contract reviewed in
///      `audit/11-external-bsc-contracts.md` hardcoded a token captioned `// SPX500` that resolved
///      to a 9-decimal lookalike with a live owner key, not the real thing.
///
///      **So the rule this script enforces: a comment naming a token is not a verification of that
///      token.** Resolve `name`, `symbol`, `decimals`, `totalSupply` and code size, then decide.
///
///      Run:
///        SMOKE_PAIR=0x... forge script script/VerifyRobinhoodPairs.s.sol:VerifyRobinhoodPairs \
///          --rpc-url $ROBINHOOD_RPC_URL
///
///      Or check several at once with PAIRS="0xaaa,0xbbb,0xccc".
contract VerifyRobinhoodPairs is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    function run() external view {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "VerifyRobinhoodPairs: Robinhood Chain (4663) only");

        address[] memory targets = _targets();
        require(targets.length > 0, "VerifyRobinhoodPairs: set SMOKE_PAIR=0x... or PAIRS=0x..,0x..");

        console.log("================================================================");
        console.log("Robinhood Chain pair verification");
        console.log("chain id", block.chainid);
        console.log("================================================================");

        for (uint256 i = 0; i < targets.length; i++) {
            _describe(targets[i]);
        }

        console.log("");
        console.log("REMINDER: holders and liquidity are NOT in this output and cannot be read");
        console.log("on-chain. Check them on robinhoodchain.blockscout.com before admitting a");
        console.log("pair. A contract that answers a famous ticker with 200 holders is a");
        console.log("lookalike, and this script cannot tell you that.");
    }

    /// @dev `PAIRS` wins when set; otherwise fall back to the single `SMOKE_PAIR`.
    ///
    ///      An earlier version called `vm.parseAddress(list)` first and branched on whether it
    ///      returned the zero address. That cannot work: `parseAddress` REVERTS on a
    ///      comma-separated string rather than returning zero, so the multi-address path was
    ///      unreachable and the whole script would have aborted the moment `PAIRS` held more than
    ///      one entry. Split first, parse second.
    function _targets() internal view returns (address[] memory out) {
        string memory list = vm.envOr("PAIRS", string(""));
        if (bytes(list).length > 0) return _split(list);
        return _single();
    }

    function _single() internal view returns (address[] memory out) {
        address a = vm.envOr("SMOKE_PAIR", address(0));
        if (a == address(0)) return new address[](0);
        out = new address[](1);
        out[0] = a;
    }

    function _split(string memory list) internal pure returns (address[] memory out) {
        // forge-std handles the parsing; a single entry is the common case and the loop above
        // already covers it, so this stays deliberately simple.
        string[] memory parts = _splitOn(list, ",");
        out = new address[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            out[i] = vm.parseAddress(parts[i]);
        }
    }

    function _splitOn(string memory s, string memory delim) internal pure returns (string[] memory) {
        bytes memory b = bytes(s);
        bytes memory d = bytes(delim);
        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == d[0]) count++;
        }
        string[] memory parts = new string[](count);
        uint256 start;
        uint256 idx;
        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == d[0]) {
                bytes memory piece = new bytes(i - start);
                for (uint256 j = 0; j < i - start; j++) {
                    piece[j] = b[start + j];
                }
                parts[idx++] = string(piece);
                start = i + 1;
            }
        }
        return parts;
    }

    function _describe(address token) internal view {
        console.log("");
        console.log("----------------------------------------------------------------");
        console.log("address ", token);

        uint256 size = token.code.length;
        console.log("code    ", size);

        if (size == 0) {
            console.log("VERDICT: NO CODE. This is an EOA or an empty slot. Do not admit.");
            return;
        }

        // A 44-45 byte runtime is an EIP-1167 minimal proxy. Not disqualifying - MarsCoin and every
        // launchpad token on this chain is one - but it means the behaviour lives elsewhere and the
        // implementation is what actually needs reading.
        if (size <= 60) {
            console.log("NOTE: 45-ish bytes means an EIP-1167 CLONE. The logic is in the");
            console.log("      implementation, not here. Resolve it before trusting anything.");
        }

        try IERC20Metadata(token).name() returns (string memory n) {
            console.log("name    ", n);
        } catch {
            console.log("name     <no name()>  <- not a standard ERC-20");
        }

        try IERC20Metadata(token).symbol() returns (string memory s) {
            console.log("symbol  ", s);
        } catch {
            console.log("symbol   <no symbol()>  <- not a standard ERC-20");
        }

        uint8 dec;
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            dec = d;
            console.log("decimals", d);
            if (d != 18) {
                console.log("  ^^ NOT 18. `approvePairWithoutOracle` takes this value and a wrong");
                console.log("     one misprices every launch against this pair by a power of ten.");
            }
        } catch {
            console.log("decimals <no decimals()>  <- DO NOT ADMIT, PairRegistry reads this");
            return;
        }

        try IERC20Metadata(token).totalSupply() returns (uint256 ts) {
            console.log("supply  ", ts);
            if (dec > 0) {
                console.log("  human ", ts / (10 ** dec));
            }
        } catch {
            console.log("supply   <no totalSupply()>");
        }

        // An owner that can still act is not disqualifying either - most bridged assets have one -
        // but it is the single fact most often missed, and it is what separated the real SPX6900
        // (renounced to 0x0) from the lookalike a reviewed contract had hardcoded.
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("owner()"));
        if (ok && ret.length == 32) {
            address owner = abi.decode(ret, (address));
            if (owner == address(0)) {
                console.log("owner    RENOUNCED (0x0)");
            } else {
                console.log("owner   ", owner);
                console.log("  ^^ LIVE OWNER KEY. Read what it can do before admitting this.");
            }
        } else {
            console.log("owner    <no owner()>");
        }

        console.log("");
        console.log("paste-ready, once you have checked holders and liquidity off-chain:");
        console.log("  pairs[N] = SeedPair({");
        console.log("      token: ", token);
        console.log("      decimals: ", dec);
        console.log("      symbol: \"...\", reason: \"holders=..., depth=..., why this one\" });");
    }
}
