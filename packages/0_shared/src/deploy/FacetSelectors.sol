// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {AccessControlFacet} from "diamond-infra/facets/AccessControlFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";

/// @notice Selector tables for shared infra facets.
library FacetSelectors {
    /// @dev Return cut selectors.
    /// @return selectors Function selectors included in the facet selector table.
    function cutSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
    }

    /// @dev Return the complete selector surface of the live-runtime upgrade coordinator.
    /// @return selectors Function selectors installed from `DiamondCutAccessLiveFacet`.
    function liveCutSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IDiamondCut.diamondCut.selector;
        selectors[1] = bytes4(keccak256("facetGeneration(bytes32)"));
    }

    /// @dev Return loupe selectors.
    /// @return selectors Function selectors included in the facet selector table.
    function loupeSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
        selectors[4] = IERC165.supportsInterface.selector;
    }

    /// @dev Return access selectors.
    /// @return selectors Function selectors included in the facet selector table.
    function accessSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](10);
        selectors[0] = IAccessControl.grantRole.selector;
        selectors[1] = IAccessControl.revokeRole.selector;
        selectors[2] = IAccessControl.renounceRole.selector;
        selectors[3] = IAccessControl.hasRole.selector;
        selectors[4] = IAccessControl.getRoleAdmin.selector;
        selectors[5] = IAccessControlEnumerable.getRoleMember.selector;
        selectors[6] = IAccessControlEnumerable.getRoleMemberCount.selector;
        selectors[7] = bytes4(keccak256("getRoleMembers(bytes32)"));
        selectors[8] = AccessControlFacet.upgraderRole.selector;
        selectors[9] = bytes4(keccak256("DEFAULT_ADMIN_ROLE()"));
    }

    /// @dev Return the Core/Staking two-step default-admin access selectors.
    function defaultAdminAccessSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](20);
        bytes4[] memory ordinary = accessSelectors();
        for (uint256 i; i < ordinary.length; ++i) {
            selectors[i] = ordinary[i];
        }
        selectors[8] = DefaultAdminAccessControlFacet.upgraderRole.selector;
        selectors[10] = IAccessControlDefaultAdminRules.defaultAdmin.selector;
        selectors[11] = IAccessControlDefaultAdminRules.pendingDefaultAdmin.selector;
        selectors[12] = IAccessControlDefaultAdminRules.defaultAdminDelay.selector;
        selectors[13] = IAccessControlDefaultAdminRules.pendingDefaultAdminDelay.selector;
        selectors[14] = IAccessControlDefaultAdminRules.defaultAdminDelayIncreaseWait.selector;
        selectors[15] = IAccessControlDefaultAdminRules.beginDefaultAdminTransfer.selector;
        selectors[16] = IAccessControlDefaultAdminRules.cancelDefaultAdminTransfer.selector;
        selectors[17] = IAccessControlDefaultAdminRules.acceptDefaultAdminTransfer.selector;
        selectors[18] = IAccessControlDefaultAdminRules.changeDefaultAdminDelay.selector;
        selectors[19] = IAccessControlDefaultAdminRules.rollbackDefaultAdminDelay.selector;
    }

    /// @dev Return pause selectors.
    /// @return selectors Function selectors included in the facet selector table.
    function pauseSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = PausableFacet.pause.selector;
        selectors[1] = PausableFacet.unpause.selector;
        selectors[2] = bytes4(keccak256("paused()"));
        selectors[3] = PausableFacet.safeWallet.selector;
        selectors[4] = PausableFacet.canPause.selector;
        selectors[5] = PausableFacet.canUnpause.selector;
        selectors[6] = PausableFacet.setSafeWallet.selector;
    }
}
