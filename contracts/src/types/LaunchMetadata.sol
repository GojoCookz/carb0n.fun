// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Off-chain presentation data for a launch, written once and never again.
///
/// @dev **Content identifiers, never URLs.** A URL is a gateway plus a path plus a scheme, which is
///      at minimum two storage slots of string per image and encodes a hostname that will outlive
///      nobody. A CIDv1 is 36 bytes and fits in `bytes32` plus a codec byte for the common
///      dag-pb/sha2-256 case, so both images cost one slot each. Frontends prepend whichever gateway
///      they trust. Storing `https://ipfs.io/ipfs/...` on chain is a permanent tax on every launch
///      to hardcode one company's uptime.
///
///      Fields are `bytes32` holding the CID's multihash DIGEST. The frontend reassembles the CID
///      with the known codec prefix. `bytes32(0)` means "not set".
///
///      **`imageCid` is required and `bannerCid` is not.** A token with no image is unlistable;
///      a token with no banner just renders a fallback. `Launcher` enforces that asymmetry so it
///      cannot drift between the contract and the UI.
///
///      **The banner is 1500x500.** That is not stored on chain - a declared aspect ratio nothing
///      verifies is decoration. It is enforced at upload time, and recorded here so the contract's
///      documentation and the uploader cannot disagree about what the field means.
struct LaunchMetadata {
    /// @notice IPFS multihash digest of the square token image. REQUIRED.
    bytes32 imageCid;
    /// @notice IPFS multihash digest of the 1500x500 banner. Optional; zero means unset.
    bytes32 bannerCid;
    /// @notice IPFS multihash digest of a JSON blob holding description, links and socials.
    /// @dev Off-chain JSON rather than on-chain strings for the same reason as the images: a
    ///      description field on chain is an unbounded string a caller controls, which is an
    ///      unbounded gas cost on the launch path.
    bytes32 infoCid;
}
