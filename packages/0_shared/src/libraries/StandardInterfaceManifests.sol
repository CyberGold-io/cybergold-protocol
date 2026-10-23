// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC1155MetadataURI} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";

/// @notice Complete selector manifests for standard interfaces advertised by protocol diamonds.
/// @dev Extension manifests include the selector closure of every inherited interface even though
/// Solidity's `type(I).interfaceId` excludes inherited selectors.
library StandardInterfaceManifests {
    /// @notice Register ERC-165 itself.
    function registerErc165() internal {
        bytes4[][] memory groups = new bytes4[][](1);
        groups[0] = _erc165Selectors();
        LibInterfaceInvariant.registerInterface(type(IERC165).interfaceId, groups);
    }

    /// @notice Register the EIP-2535 cut entrypoint.
    function registerDiamondCut() internal {
        bytes4[][] memory groups = new bytes4[][](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
        groups[0] = selectors;
        LibInterfaceInvariant.registerInterface(type(IDiamondCut).interfaceId, groups);
    }

    /// @notice Register the complete EIP-2535 loupe surface.
    function registerDiamondLoupe() internal {
        bytes4[][] memory groups = new bytes4[][](1);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
        groups[0] = selectors;
        LibInterfaceInvariant.registerInterface(type(IDiamondLoupe).interfaceId, groups);
    }

    /// @notice Register AccessControl with its ERC-165 selector closure.
    function registerAccessControl() internal {
        bytes4[][] memory groups = new bytes4[][](2);
        groups[0] = _erc165Selectors();
        groups[1] = _accessControlSelectors();
        LibInterfaceInvariant.registerInterface(type(IAccessControl).interfaceId, groups);
    }

    /// @notice Register enumerable AccessControl with its inherited ERC-165 and AccessControl selector closure.
    function registerAccessControlEnumerable() internal {
        bytes4[][] memory groups = new bytes4[][](3);
        groups[0] = _erc165Selectors();
        groups[1] = _accessControlSelectors();
        bytes4[] memory enumerableSelectors = new bytes4[](2);
        enumerableSelectors[0] = IAccessControlEnumerable.getRoleMember.selector;
        enumerableSelectors[1] = IAccessControlEnumerable.getRoleMemberCount.selector;
        groups[2] = enumerableSelectors;
        LibInterfaceInvariant.registerInterface(type(IAccessControlEnumerable).interfaceId, groups);
    }

    /// @notice Register default-admin rules with the inherited AccessControl and ERC-165 selector closure.
    function registerAccessControlDefaultAdminRules() internal {
        bytes4[][] memory groups = new bytes4[][](3);
        groups[0] = _erc165Selectors();
        groups[1] = _accessControlSelectors();
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = IAccessControlDefaultAdminRules.defaultAdmin.selector;
        selectors[1] = IAccessControlDefaultAdminRules.pendingDefaultAdmin.selector;
        selectors[2] = IAccessControlDefaultAdminRules.defaultAdminDelay.selector;
        selectors[3] = IAccessControlDefaultAdminRules.pendingDefaultAdminDelay.selector;
        selectors[4] = IAccessControlDefaultAdminRules.defaultAdminDelayIncreaseWait.selector;
        selectors[5] = IAccessControlDefaultAdminRules.beginDefaultAdminTransfer.selector;
        selectors[6] = IAccessControlDefaultAdminRules.cancelDefaultAdminTransfer.selector;
        selectors[7] = IAccessControlDefaultAdminRules.acceptDefaultAdminTransfer.selector;
        selectors[8] = IAccessControlDefaultAdminRules.changeDefaultAdminDelay.selector;
        selectors[9] = IAccessControlDefaultAdminRules.rollbackDefaultAdminDelay.selector;
        groups[2] = selectors;
        LibInterfaceInvariant.registerInterface(type(IAccessControlDefaultAdminRules).interfaceId, groups);
    }

    /// @notice Register the complete ERC-20 interface manifest.
    function registerErc20() internal {
        bytes4[][] memory groups = new bytes4[][](1);
        groups[0] = _erc20Selectors();
        LibInterfaceInvariant.registerInterface(type(IERC20).interfaceId, groups);
    }

    /// @notice Register ERC-20 metadata together with its inherited ERC-20 selector closure.
    function registerErc20Metadata() internal {
        bytes4[][] memory groups = new bytes4[][](2);
        groups[0] = _erc20Selectors();
        groups[1] = _erc20MetadataSelectors();
        LibInterfaceInvariant.registerInterface(type(IERC20Metadata).interfaceId, groups);
    }

    /// @notice Register the complete ERC-2612 permit interface manifest.
    function registerErc20Permit() internal {
        bytes4[][] memory groups = new bytes4[][](1);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = IERC20Permit.permit.selector;
        selectors[1] = IERC20Permit.nonces.selector;
        selectors[2] = IERC20Permit.DOMAIN_SEPARATOR.selector;
        groups[0] = selectors;
        LibInterfaceInvariant.registerInterface(type(IERC20Permit).interfaceId, groups);
    }

    /// @notice Register ERC-1155 together with its inherited ERC-165 selector closure.
    function registerErc1155() internal {
        bytes4[][] memory groups = new bytes4[][](2);
        groups[0] = _erc165Selectors();
        groups[1] = _erc1155Selectors();
        LibInterfaceInvariant.registerInterface(type(IERC1155).interfaceId, groups);
    }

    /// @notice Register ERC-1155 metadata with its complete inherited selector closure.
    function registerErc1155MetadataUri() internal {
        bytes4[][] memory groups = new bytes4[][](3);
        groups[0] = _erc165Selectors();
        groups[1] = _erc1155Selectors();
        bytes4[] memory metadataSelectors = new bytes4[](1);
        metadataSelectors[0] = IERC1155MetadataURI.uri.selector;
        groups[2] = metadataSelectors;
        LibInterfaceInvariant.registerInterface(type(IERC1155MetadataURI).interfaceId, groups);
    }

    /// @notice Register the complete ERC-6372 clock interface manifest.
    function registerErc6372() internal {
        bytes4[][] memory groups = new bytes4[][](1);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IERC6372.clock.selector;
        selectors[1] = IERC6372.CLOCK_MODE.selector;
        groups[0] = selectors;
        LibInterfaceInvariant.registerInterface(type(IERC6372).interfaceId, groups);
    }

    /// @notice Register the complete ERC-721 receiver interface manifest.
    function registerErc721Receiver() internal {
        bytes4[][] memory groups = new bytes4[][](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IERC721Receiver.onERC721Received.selector;
        groups[0] = selectors;
        LibInterfaceInvariant.registerInterface(type(IERC721Receiver).interfaceId, groups);
    }

    /// @notice Register ERC-1155 receiver with its inherited ERC-165 selector closure.
    function registerErc1155Receiver() internal {
        bytes4[][] memory groups = new bytes4[][](2);
        groups[0] = _erc165Selectors();
        bytes4[] memory receiverSelectors = new bytes4[](2);
        receiverSelectors[0] = IERC1155Receiver.onERC1155Received.selector;
        receiverSelectors[1] = IERC1155Receiver.onERC1155BatchReceived.selector;
        groups[1] = receiverSelectors;
        LibInterfaceInvariant.registerInterface(type(IERC1155Receiver).interfaceId, groups);
    }

    function _erc165Selectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IERC165.supportsInterface.selector;
    }

    function _accessControlSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IAccessControl.hasRole.selector;
        selectors[1] = IAccessControl.getRoleAdmin.selector;
        selectors[2] = IAccessControl.grantRole.selector;
        selectors[3] = IAccessControl.revokeRole.selector;
        selectors[4] = IAccessControl.renounceRole.selector;
    }

    function _erc20Selectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = IERC20.totalSupply.selector;
        selectors[1] = IERC20.balanceOf.selector;
        selectors[2] = IERC20.transfer.selector;
        selectors[3] = IERC20.allowance.selector;
        selectors[4] = IERC20.approve.selector;
        selectors[5] = IERC20.transferFrom.selector;
    }

    function _erc20MetadataSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IERC20Metadata.name.selector;
        selectors[1] = IERC20Metadata.symbol.selector;
        selectors[2] = IERC20Metadata.decimals.selector;
    }

    function _erc1155Selectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = IERC1155.balanceOf.selector;
        selectors[1] = IERC1155.balanceOfBatch.selector;
        selectors[2] = IERC1155.setApprovalForAll.selector;
        selectors[3] = IERC1155.isApprovedForAll.selector;
        selectors[4] = IERC1155.safeTransferFrom.selector;
        selectors[5] = IERC1155.safeBatchTransferFrom.selector;
    }
}
