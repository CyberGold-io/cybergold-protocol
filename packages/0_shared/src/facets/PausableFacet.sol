// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {IDiamondEmergencyAuthority} from "diamond-infra/interfaces/IDiamondEmergencyAuthority.sol";
import {ISafeWallet} from "diamond-infra/interfaces/ISafeWallet.sol";
import {LibEmergencyAuthority} from "diamond-infra/libraries/LibEmergencyAuthority.sol";

/// @notice Pause control backed by current Safe-wallet ownership.
contract PausableFacet is PausableUpgradeable, InitContext, IDiamondEmergencyAuthority {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("openzeppelin.storage.Pausable");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    /// @notice Reverts when AccessControl authority is missing.
    /// @param account Caller rejected by AccessControl.
    /// @param neededRole Role the caller must hold.
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);
    /// @notice Reverts when Safe-wallet emergency authority rejects the caller.
    /// @param account Caller rejected by the configured Safe-wallet authority.
    error EmergencyAuthorityUnauthorizedAccount(address account);
    /// @notice Reverts when a Safe-wallet replacement uses stale expected state.
    /// @param expected Safe wallet the caller expected to replace.
    /// @param actual Safe wallet currently configured in storage.
    error SafeWalletExpectedCurrentMismatch(address expected, address actual);
    /// @notice Reverts when the proposed Safe wallet equals the current wallet.
    /// @param safeWallet Safe wallet supplied as both current and replacement value.
    error SafeWalletUnchanged(address safeWallet);
    /// @notice Reverts when a candidate is not a structurally valid Safe wallet.
    /// @param candidate Address rejected by Safe-wallet structural validation.
    error InvalidSafeWallet(address candidate);

    /// @notice Initialize Pausable storage and configure the verified Safe wallet.
    /// @param safeWallet_ Safe wallet whose owners may pause and whose wallet address may unpause.
    function initPausable(address safeWallet_) external onlyInit reinitializer(_getInitializedVersion() + 1) {
        _updateSafeWallet(address(0), safeWallet_);
    }

    /// @notice Configure emergency authority inside a component's outer initializer.
    /// @dev Core and Governance use this non-installed hook to avoid another Initializable counter bump.
    /// @param safeWallet_ Safe wallet whose owners may pause and whose wallet address may unpause.
    function initPausableFromOuter(address safeWallet_) external onlyInit {
        _updateSafeWallet(address(0), safeWallet_);
    }

    /// @inheritdoc IDiamondEmergencyAuthority
    function safeWallet() public view override returns (address) {
        return LibEmergencyAuthority.getLayout().safeWallet;
    }

    /// @inheritdoc IDiamondEmergencyAuthority
    function canPause(address account) public view override returns (bool) {
        address configuredSafeWallet = safeWallet();
        if (configuredSafeWallet == address(0)) return false;

        (bool ok, bytes memory result) =
            configuredSafeWallet.staticcall(abi.encodeWithSelector(ISafeWallet.isOwner.selector, account));
        if (!ok || result.length != 32) return false;

        uint256 raw;
        assembly {
            raw := mload(add(result, 0x20))
        }
        return raw == 1;
    }

    /// @inheritdoc IDiamondEmergencyAuthority
    function canUnpause(address account) public view override returns (bool) {
        address configuredSafeWallet = safeWallet();
        return configuredSafeWallet != address(0) && account == configuredSafeWallet;
    }

    /// @inheritdoc IDiamondEmergencyAuthority
    function setSafeWallet(address expectedCurrentSafeWallet, address newSafeWallet) external override {
        _checkDefaultAdmin();
        _updateSafeWallet(expectedCurrentSafeWallet, newSafeWallet);
    }

    /// @notice Pause when the caller is a current owner of the configured Safe wallet.
    function pause() external {
        if (!canPause(msg.sender)) revert EmergencyAuthorityUnauthorizedAccount(msg.sender);
        _pause();
    }

    /// @notice Unpause when the caller is the configured Safe wallet.
    function unpause() external {
        if (!canUnpause(msg.sender)) revert EmergencyAuthorityUnauthorizedAccount(msg.sender);
        _unpause();
    }

    function _checkDefaultAdmin() internal view {
        if (!IAccessControl(address(this)).hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, DEFAULT_ADMIN_ROLE);
        }
    }

    function _updateSafeWallet(address expectedCurrentSafeWallet, address newSafeWallet) internal {
        LibEmergencyAuthority.Layout storage l = LibEmergencyAuthority.getLayout();
        address currentSafeWallet = l.safeWallet;
        if (currentSafeWallet != expectedCurrentSafeWallet) {
            revert SafeWalletExpectedCurrentMismatch(expectedCurrentSafeWallet, currentSafeWallet);
        }
        if (newSafeWallet == currentSafeWallet) revert SafeWalletUnchanged(newSafeWallet);
        if (newSafeWallet == address(this)) revert InvalidSafeWallet(newSafeWallet);

        _validateSafeWallet(newSafeWallet);

        l.safeWallet = newSafeWallet;
        emit SafeWalletUpdated(currentSafeWallet, newSafeWallet);
    }

    function _validateSafeWallet(address candidate) internal view {
        if (candidate == address(0) || candidate.code.length == 0) revert InvalidSafeWallet(candidate);
        _validateOwnerConfiguration(candidate);
    }

    function _validateOwnerConfiguration(address candidate) internal view {
        (bool ownersOk, bytes memory ownersData) =
            candidate.staticcall(abi.encodeWithSelector(ISafeWallet.getOwners.selector));
        address[] memory owners = _decodeCanonicalAddressArray(ownersOk, ownersData, candidate);
        if (owners.length == 0) revert InvalidSafeWallet(candidate);

        (bool thresholdOk, bytes memory thresholdData) =
            candidate.staticcall(abi.encodeWithSelector(ISafeWallet.getThreshold.selector));
        if (!thresholdOk || thresholdData.length != 32) revert InvalidSafeWallet(candidate);
        uint256 threshold = abi.decode(thresholdData, (uint256));
        if (threshold == 0 || threshold > owners.length) revert InvalidSafeWallet(candidate);

        for (uint256 i; i < owners.length; ++i) {
            _validateOwner(candidate, owners, i);
        }
    }

    function _validateOwner(address candidate, address[] memory owners, uint256 index) internal view {
        address owner = owners[index];
        if (owner == address(0)) revert InvalidSafeWallet(candidate);
        for (uint256 j; j < index; ++j) {
            if (owners[j] == owner) revert InvalidSafeWallet(candidate);
        }
        (bool ok, bytes memory data) = candidate.staticcall(abi.encodeWithSelector(ISafeWallet.isOwner.selector, owner));
        if (!ok || data.length != 32 || abi.decode(data, (uint256)) != 1) {
            revert InvalidSafeWallet(candidate);
        }
    }

    function _decodeCanonicalAddressArray(bool ok, bytes memory data, address candidate)
        internal
        pure
        returns (address[] memory decoded)
    {
        if (!ok || data.length < 64) revert InvalidSafeWallet(candidate);
        uint256 offset;
        uint256 length;
        assembly {
            offset := mload(add(data, 0x20))
            length := mload(add(data, 0x40))
        }
        if (offset != 32 || length > (type(uint256).max - 64) / 32 || data.length != 64 + length * 32) {
            revert InvalidSafeWallet(candidate);
        }
        decoded = abi.decode(data, (address[]));
    }
}
