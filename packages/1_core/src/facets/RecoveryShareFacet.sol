// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IRecoveryShareOutflowCallback} from "../interfaces/IRecoveryShareOutflowCallback.sol";
import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";
import {LibAccountCallbacks} from "../libraries/LibAccountCallbacks.sol";
import {LibRecoveryShareStorage} from "../libraries/LibRecoveryShareStorage.sol";
import {LibRecoveryStorage} from "../libraries/LibRecoveryStorage.sol";

/// @notice Transferable ERC-1155 shares for permanent asset-scoped recovery pools.
/// @dev The Diamond cut omits inherited supportsInterface(bytes4); the loupe facet owns it.
contract RecoveryShareFacet is ERC1155Upgradeable, PausableUpgradeable, IRecoveryTypes {
    /// @notice Facet version used by the Diamond initialization registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the Diamond initialization registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.core.recovery-share");

    /// @notice Return the external ERC-1155 supply for a recovery-share identifier.
    /// @param shareId Canonical ERC-1155 recovery-share identifier.
    /// @return supply External fungible share supply held outside Core accounting.
    function totalSupply(uint256 shareId) public view returns (uint256 supply) {
        return LibRecoveryShareStorage.getLayout().supply[shareId];
    }

    /// @notice Issue one strictly asset-ordered batch through a guarded Core self-call.
    /// @param to Account receiving the ERC-1155 shares.
    /// @param assets Strictly ascending impaired assets identifying the permanent pools.
    /// @param amounts Share amounts minted for the corresponding assets.
    function issueRecoveryShares(address to, address[] calldata assets, uint256[] calldata amounts)
        external
        onlyController
        whenNotPaused
    {
        if (to == address(0)) revert RecoveryRecipientInvalid(to);
        uint256 length = assets.length;
        if (length != amounts.length) revert RecoveryShareLengthMismatch(length, amounts.length);

        uint256[] memory ids = new uint256[](length);
        address previousAsset;
        for (uint256 i; i < length;) {
            address asset = assets[i];
            if (asset == address(0)) revert RecoveryAssetInvalid(asset);
            if (i != 0 && uint160(asset) <= uint160(previousAsset)) {
                revert RecoveryShareAssetsNotAscending(previousAsset, asset);
            }
            LibRecoveryStorage.RecoveryPool storage pool = _requireKnownPool(asset);
            if (!pool.impaired) {
                revert RecoveryPoolImpairmentInvalid(asset, true, false);
            }
            if (amounts[i] == 0) revert RecoveryShareAmountZero(asset);
            ids[i] = uint256(uint160(asset));
            previousAsset = asset;
            unchecked {
                ++i;
            }
        }
        _mintBatch(to, ids, amounts, "");
    }

    /// @notice Burn asset-scoped recovery shares through a guarded Core self-call.
    /// @param from Account whose ERC-1155 balance is reduced.
    /// @param asset Impaired asset identifying the permanent recovery pool.
    /// @param amount Recovery-share amount burned.
    function burnRecoveryShares(address from, address asset, uint256 amount) external onlyController whenNotPaused {
        if (from == address(0)) revert RecoveryRecipientInvalid(from);
        _requireKnownPool(asset);
        if (amount == 0) revert RecoveryShareAmountZero(asset);
        _burn(from, uint256(uint160(asset)), amount);
    }

    /// @dev Update custom external supply only on mint/burn; transfers remain live while paused.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        bool changesSupply = from == address(0) || to == address(0);
        if (changesSupply) {
            _requireNotPaused();
            super._update(from, to, ids, values);
        } else {
            if (ids.length != values.length) revert ERC1155InvalidArrayLength(ids.length, values.length);
            bool usesCallback =
                LibAccountCallbacks.supportsInterface(from, type(IRecoveryShareOutflowCallback).interfaceId);
            super._update(from, to, ids, values);
            if (usesCallback) {
                bytes4 callback = IRecoveryShareOutflowCallback.onRecoveryShareOutflow.selector;
                LibAccountCallbacks.callAndRequireMagic(
                    from,
                    callback,
                    abi.encodeCall(
                        IRecoveryShareOutflowCallback.onRecoveryShareOutflow, (_msgSender(), to, ids, values)
                    )
                );
            }
        }
        if (!changesSupply) return;

        LibRecoveryShareStorage.Layout storage shares = LibRecoveryShareStorage.getLayout();
        for (uint256 i; i < ids.length;) {
            if (from == address(0)) shares.supply[ids[i]] += values[i];
            else shares.supply[ids[i]] -= values[i];
            unchecked {
                ++i;
            }
        }
    }

    function _requireKnownPool(address asset) private view returns (LibRecoveryStorage.RecoveryPool storage pool) {
        if (asset == address(0)) revert RecoveryAssetInvalid(asset);
        pool = LibRecoveryStorage.getLayout().pools[asset];
        uint256 externalSupply = LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))];
        if (
            !pool.impaired && pool.coreAttachedShares == 0 && pool.redeemableRaw == 0 && pool.cygldPerAssetRawFp18 == 0
                && pool.cygldSupplyCap == 0 && externalSupply == 0
        ) revert RecoveryShareUnknown(asset);
    }

    modifier onlyController() {
        if (msg.sender != address(this)) revert RecoveryShareControllerOnly(msg.sender);
        _;
    }
}
