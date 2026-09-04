// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {LaunchToken} from "../../src/LaunchToken.sol";
import {LaunchMetadata} from "../../src/types/LaunchMetadata.sol";

/// @notice Shared clone-deploy helpers, so every suite creates launch tokens the same way the
///         `Launcher` does rather than each inventing its own shortcut.
/// @dev Mining a clone's salt is cheap in a way a full deployment's never is: an EIP-1167 proxy's
///      creation code is a fixed 55 bytes parameterised only by the implementation address, so the
///      init-code hash is constant for a given implementation and does not change when the token's
///      logic is edited. Currency-order mining therefore stays stable across refactors.
abstract contract LaunchTokenDeployer {
    LaunchToken internal launchTokenImpl;

    function _deployLaunchTokenImpl() internal {
        launchTokenImpl = new LaunchToken();
    }

    function _predictClone(bytes32 salt) internal view returns (address) {
        return Clones.predictDeterministicAddress(address(launchTokenImpl), salt, address(this));
    }

    function _cloneAndInit(bytes32 salt, LaunchToken.InitParams memory p) internal returns (LaunchToken t) {
        t = LaunchToken(Clones.cloneDeterministic(address(launchTokenImpl), salt));
        t.initialize(p);
    }

    /// @dev A metadata blob that satisfies the launcher's "image is required" rule.
    function _defaultMetadata() internal pure returns (LaunchMetadata memory) {
        return LaunchMetadata({
            imageCid: keccak256("image"), bannerCid: keccak256("banner"), infoCid: keccak256("info")
        });
    }
}
