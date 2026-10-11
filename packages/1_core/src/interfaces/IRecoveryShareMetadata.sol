// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice Informational HTTPS metadata locators for Core recovery shares.
/// @dev Recovery-share amounts use the asset-native `recoveryPool(asset).shareDecimals` precision.
/// One raw share pays at most one raw asset unit; ERC-1155 itself defines no `decimals()` selector.
/// Recovery accounting and settlement remain authoritative through the typed Core lenses and do
/// not depend on the metadata service being available.
interface IRecoveryShareMetadata {
    /// @notice Return this chain and Core deployment's deterministic collection metadata URL.
    /// @return metadataUri HTTPS URL ending in `/collection.json`.
    function contractURI() external view returns (string memory metadataUri);

    /// @notice Return one known asset recovery pool's deterministic token-type metadata URL.
    /// @param shareId Canonical address-derived ERC-1155 recovery-share identifier.
    /// @return metadataUri HTTPS URL ending in the decimal `shareId` plus `.json`.
    function uri(uint256 shareId) external view returns (string memory metadataUri);
}
