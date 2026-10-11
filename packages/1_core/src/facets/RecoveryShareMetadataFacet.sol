// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IRecoveryShareMetadata} from "../interfaces/IRecoveryShareMetadata.sol";
import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";
import {LibRecoveryShareStorage} from "../libraries/LibRecoveryShareStorage.sol";
import {LibRecoveryStorage} from "../libraries/LibRecoveryStorage.sol";

/// @notice Deterministic HTTPS metadata locators for permanent asset-scoped recovery shares.
/// @dev Recovery-share amounts use retained asset-native decimal places. Metadata availability is
/// informational only and cannot affect share transfers, accounting, or settlement.
contract RecoveryShareMetadataFacet is IRecoveryShareMetadata, IRecoveryTypes {
    /// @notice Facet version used by the Diamond initialization registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the Diamond initialization registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.core.recovery-share-metadata");

    string internal constant RECOVERY_METADATA_BASE_URI = "https://cybergold.io/recovery-shares/";

    /// @inheritdoc IRecoveryShareMetadata
    function contractURI() external view returns (string memory) {
        return string.concat(_deploymentMetadataBaseUri(), "collection.json");
    }

    /// @inheritdoc IRecoveryShareMetadata
    function uri(uint256 shareId) external view returns (string memory) {
        if (shareId == 0 || shareId > type(uint160).max) revert RecoveryShareIdInvalid(shareId);
        // Casting is safe because the canonical range check above proves shareId fits uint160.
        // forge-lint: disable-next-line(unsafe-typecast)
        address asset = address(uint160(shareId));
        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
        uint256 externalSupply = LibRecoveryShareStorage.getLayout().supply[shareId];
        if (
            !pool.impaired && pool.coreAttachedShares == 0 && pool.redeemableRaw == 0 && pool.cygldPerAssetRawFp18 == 0
                && pool.cygldSupplyCap == 0 && externalSupply == 0 && pool.referenceShares == 0
        ) revert RecoveryShareUnknown(asset);

        return string.concat(_deploymentMetadataBaseUri(), Strings.toString(shareId), ".json");
    }

    function _deploymentMetadataBaseUri() private view returns (string memory) {
        return string.concat(
            RECOVERY_METADATA_BASE_URI, Strings.toString(block.chainid), "/", Strings.toHexString(address(this)), "/"
        );
    }
}
