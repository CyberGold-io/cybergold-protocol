// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";

/// @notice Compact selector manifests for interfaces advertised through ERC-165.
/// @dev Product initializers register their complete interface selector groups once.
/// The manifest registry is the exclusive advertisement authority. The validated
/// cut coordinator rejects missing selectors, legacy direct-map writes, and invalid
/// retirement. A reviewed selector-removal cut may retire a registered manifest.
library LibInterfaceInvariant {
    bytes4 internal constant INVALID_INTERFACE_ID = 0xffffffff;
    // keccak256("cybergold.interface.selector.manifests")
    bytes32 private constant INTERFACE_SELECTOR_MANIFESTS_SLOT =
        0xff092d620461098e263264e3201620767bd3639a1424ca912571a18d26f5966e;

    /// @notice Reverts when an initializer tries to register an interface manifest twice.
    /// @param interfaceId Interface identifier that already has a manifest.
    error InterfaceManifestAlreadyRegistered(bytes4 interfaceId);
    /// @notice Reverts when an interface identifier is zero, ERC-165's invalid ID, or has no selectors.
    /// @param interfaceId Invalid or zero-selector interface identifier.
    error InterfaceManifestEmpty(bytes4 interfaceId);
    /// @notice Reverts when a selector manifest contains the zero selector.
    /// @param interfaceId Interface identifier containing the invalid selector.
    /// @param index Position of the invalid selector in the flattened manifest.
    error InterfaceManifestInvalidSelector(bytes4 interfaceId, uint256 index);
    /// @notice Reverts when a selector occurs more than once in one interface manifest.
    /// @param interfaceId Interface identifier containing the duplicate selector.
    /// @param selector Selector duplicated in the manifest.
    error InterfaceManifestDuplicateSelector(bytes4 interfaceId, bytes4 selector);
    /// @notice Reverts when retirement targets an interface with no registered manifest.
    /// @param interfaceId Unregistered interface identifier.
    error InterfaceManifestNotRegistered(bytes4 interfaceId);
    /// @notice Reverts when retirement targets an interface that is already inactive.
    /// @param interfaceId Already retired interface identifier.
    error InterfaceManifestAlreadyRetired(bytes4 interfaceId);
    /// @notice Reverts when retirement is attempted without removing any manifest selector.
    /// @param interfaceId Interface whose complete selector closure remains installed.
    error InterfaceRetirementSelectorsStillInstalled(bytes4 interfaceId);

    /// @notice Namespaced storage for registered interface identifiers and packed selectors.
    struct Layout {
        bytes4[] interfaceIds;
        mapping(bytes4 interfaceId => bytes packedSelectors) selectors;
        mapping(bytes4 interfaceId => bool advertised) advertised;
    }

    /// @notice Register one advertised interface from canonical selector groups.
    function registerInterface(bytes4 interfaceId, bytes4[][] memory selectorGroups) internal {
        Layout storage l = getLayout();
        if (l.selectors[interfaceId].length != 0) revert InterfaceManifestAlreadyRegistered(interfaceId);

        uint256 selectorCount;
        for (uint256 i; i < selectorGroups.length; ++i) {
            selectorCount += selectorGroups[i].length;
        }
        if (interfaceId == bytes4(0) || interfaceId == INVALID_INTERFACE_ID || selectorCount == 0) {
            revert InterfaceManifestEmpty(interfaceId);
        }

        bytes memory packed = new bytes(selectorCount * 4);
        uint256 cursor;
        for (uint256 i; i < selectorGroups.length; ++i) {
            bytes4[] memory group = selectorGroups[i];
            for (uint256 j; j < group.length; ++j) {
                bytes4 selector = group[j];
                if (selector == bytes4(0)) revert InterfaceManifestInvalidSelector(interfaceId, cursor);
                for (uint256 k; k < cursor; ++k) {
                    if (_selectorAt(packed, k) == selector) {
                        revert InterfaceManifestDuplicateSelector(interfaceId, selector);
                    }
                }
                _writeSelector(packed, cursor, selector);
                ++cursor;
            }
        }

        l.interfaceIds.push(interfaceId);
        l.selectors[interfaceId] = packed;
        l.advertised[interfaceId] = true;
    }

    /// @notice Retire a registered interface after its containing cut removes at least one selector.
    function retireInterface(bytes4 interfaceId) internal {
        Layout storage l = getLayout();
        bytes memory packed = l.selectors[interfaceId];
        if (packed.length == 0) revert InterfaceManifestNotRegistered(interfaceId);
        if (!l.advertised[interfaceId]) revert InterfaceManifestAlreadyRetired(interfaceId);

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 selectorCount = packed.length / 4;
        for (uint256 i; i < selectorCount; ++i) {
            bytes4 selector = _selectorAt(packed, i);
            if (ds.facetAddressAndSelectorPosition[selector].facetAddress == address(0)) {
                l.advertised[interfaceId] = false;
                return;
            }
        }
        revert InterfaceRetirementSelectorsStillInstalled(interfaceId);
    }

    /// @notice Return whether an identifier is registered and currently advertised.
    function isAdvertised(bytes4 interfaceId) internal view returns (bool) {
        if (interfaceId == bytes4(0) || interfaceId == INVALID_INTERFACE_ID) return false;
        Layout storage l = getLayout();
        return l.selectors[interfaceId].length != 0 && l.advertised[interfaceId];
    }

    /// @notice Return whether an identifier has a registered manifest.
    function isRegistered(bytes4 interfaceId) internal view returns (bool) {
        return getLayout().selectors[interfaceId].length != 0;
    }

    /// @notice Return the first selector or advertisement boundary violating the registered authority.
    function firstInvariantViolation() internal view returns (bytes4 violation) {
        Layout storage l = getLayout();
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        if (ds.supportedInterfaces[INVALID_INTERFACE_ID]) return IERC165.supportsInterface.selector;
        for (uint256 i; i < l.interfaceIds.length; ++i) {
            bytes4 interfaceId = l.interfaceIds[i];
            // The upstream Diamond mapping is deliberately inert. Any direct
            // write is rejected; ProtocolDiamondLoupeFacet reads only this registry.
            if (ds.supportedInterfaces[interfaceId]) return IERC165.supportsInterface.selector;
            if (!l.advertised[interfaceId]) continue;

            bytes memory packed = l.selectors[interfaceId];
            uint256 selectorCount = packed.length / 4;
            for (uint256 j; j < selectorCount; ++j) {
                bytes4 selector = _selectorAt(packed, j);
                if (ds.facetAddressAndSelectorPosition[selector].facetAddress == address(0)) return selector;
            }
        }
    }

    /// @notice Return the first selector missing from an advertised registered interface.
    function firstMissingAdvertisedSelector() internal view returns (bytes4 missing) {
        return firstInvariantViolation();
    }

    /// @notice Number of registered interface manifests, used by pristine-shell checks.
    function registeredInterfaceCount() internal view returns (uint256) {
        return getLayout().interfaceIds.length;
    }

    /// @notice Number of currently advertised registered manifests.
    function advertisedInterfaceCount() internal view returns (uint256 count) {
        Layout storage l = getLayout();
        for (uint256 i; i < l.interfaceIds.length; ++i) {
            if (l.advertised[l.interfaceIds[i]]) ++count;
        }
    }

    /// @notice Return one registered interface identifier by index for enumerable postflight consumers.
    function registeredInterfaceAt(uint256 index) internal view returns (bytes4) {
        return getLayout().interfaceIds[index];
    }

    function getLayout() private pure returns (Layout storage l) {
        bytes32 slot = INTERFACE_SELECTOR_MANIFESTS_SLOT;
        assembly {
            l.slot := slot
        }
    }

    function _selectorAt(bytes memory packed, uint256 index) private pure returns (bytes4) {
        uint256 offset = index * 4;
        uint32 raw = uint32(uint8(packed[offset])) << 24 | uint32(uint8(packed[offset + 1])) << 16
            | uint32(uint8(packed[offset + 2])) << 8 | uint32(uint8(packed[offset + 3]));
        return bytes4(raw);
    }

    function _writeSelector(bytes memory packed, uint256 index, bytes4 selector) private pure {
        uint256 offset = index * 4;
        packed[offset] = selector[0];
        packed[offset + 1] = selector[1];
        packed[offset + 2] = selector[2];
        packed[offset + 3] = selector[3];
    }
}
