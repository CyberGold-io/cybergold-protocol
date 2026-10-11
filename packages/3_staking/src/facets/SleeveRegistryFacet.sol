// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {ISleeve} from "../sleeves/ISleeve.sol";

/// @notice Registry of Staking-controlled Sleeve adapters, their underlying assets, principal, and allocation approval.
contract SleeveRegistryFacet is AccessControlEnumerableUpgradeable, InitContext {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.sleeve.registry");

    // ----- Events -----
    /// @notice Emitted when a Sleeve is registered or its zero-principal asset binding changes.
    /// @param sleeve Staking-controlled Sleeve address.
    /// @param asset Underlying token authenticated from the Sleeve.
    event SleeveRegistered(address indexed sleeve, address indexed asset);
    /// @notice Emitted when a registered Sleeve's eligibility for new allocations changes.
    /// @param sleeve Registered Sleeve whose allocation approval changed.
    /// @param approved Whether new allocations to the Sleeve are permitted.
    event SleeveApprovalUpdated(address indexed sleeve, bool approved);

    // ----- Errors -----
    /// @notice A Sleeve registration contains a zero Sleeve or asset address.
    error ZeroAddress();
    /// @notice Atomic launch supplied Sleeve, asset, and approval arrays with different lengths.
    error InvalidSleeveArrays();
    /// @notice An approval update targets an unregistered Sleeve.
    /// @param sleeve Unregistered Sleeve address.
    error SleeveNotRegistered(address sleeve);
    /// @notice A Sleeve asset-binding change is attempted before book principal reaches zero.
    /// @param sleeve Sleeve whose asset binding cannot yet change.
    /// @param principal Principal assets currently deployed through the sleeve.
    error SleevePrincipalNotCleared(address sleeve, uint256 principal);
    /// @notice A Sleeve's reported underlying differs from the proposed registry binding.
    /// @param sleeve Sleeve reporting the mismatched underlying.
    /// @param expectedAsset Underlying token required by the registry operation.
    error SleeveAssetMismatch(address sleeve, address expectedAsset);
    /// @notice A Sleeve reports a controller other than the registering Staking Diamond.
    /// @param sleeve Sleeve reporting the mismatched controller.
    /// @param expectedStakingDiamond Staking Diamond required as the Sleeve controller.
    error SleeveStakingDiamondMismatch(address sleeve, address expectedStakingDiamond);

    /// @notice Register a Staking-controlled Sleeve, or change its asset binding only at zero principal.
    /// @param sleeve Sleeve adapter to register.
    /// @param asset Expected underlying token reported by the Sleeve.
    function registerSleeve(address sleeve, address asset) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _registerSleeve(sleeve, asset);
    }

    /// @notice Register and approve the exact launch Sleeves inside the outer initializer.
    /// @dev This hook is intentionally absent from the installed selector table.
    /// @param sleeveList Ordered Sleeve proxy addresses created by the atomic launch.
    /// @param assets Ordered underlying assets corresponding to `sleeveList`.
    /// @param approvals Ordered initial approval states corresponding to `sleeveList`.
    function initSleeves(address[] calldata sleeveList, address[] calldata assets, bool[] calldata approvals)
        external
        onlyInit
    {
        uint256 length = sleeveList.length;
        if (length != assets.length || length != approvals.length) revert InvalidSleeveArrays();
        for (uint256 i; i < length; ++i) {
            _registerSleeve(sleeveList[i], assets[i]);
            _setSleeveApproval(sleeveList[i], approvals[i]);
        }
    }

    function _registerSleeve(address sleeve, address asset) internal {
        if (sleeve == address(0) || asset == address(0)) revert ZeroAddress();
        LibAppStorage.FundManagerStorage storage fm = LibAppStorage.appStorage().fm;
        LibAppStorage.SleeveConfig storage cfg = fm.sleeves[sleeve];
        if (!cfg.registered) {
            address reportedAsset = ISleeve(sleeve).asset();
            if (reportedAsset != asset) revert SleeveAssetMismatch(sleeve, asset);
            address reportedStakingDiamond = ISleeve(sleeve).stakingDiamond();
            if (reportedStakingDiamond != address(this)) {
                revert SleeveStakingDiamondMismatch(sleeve, address(this));
            }

            cfg.registered = true;
            cfg.asset = reportedAsset;
            fm.registeredSleeves.push(sleeve);
            emit SleeveRegistered(sleeve, asset);
        } else if (cfg.asset != asset) {
            uint256 principal = cfg.principalAssets;
            if (principal != 0) revert SleevePrincipalNotCleared(sleeve, principal);
            if (asset != ISleeve(sleeve).asset()) revert SleeveAssetMismatch(sleeve, asset);

            cfg.asset = asset;
            emit SleeveRegistered(sleeve, asset);
        }
    }

    /// @notice Enable or disable new allocations to a registered Sleeve.
    /// @param sleeve Registered Sleeve whose allocation eligibility changes.
    /// @param approved Whether new allocations are permitted.
    function setSleeveApproval(address sleeve, bool approved) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setSleeveApproval(sleeve, approved);
    }

    function _setSleeveApproval(address sleeve, bool approved) internal {
        LibAppStorage.FundManagerStorage storage fm = LibAppStorage.appStorage().fm;
        LibAppStorage.SleeveConfig storage cfg = fm.sleeves[sleeve];
        if (!cfg.registered) revert SleeveNotRegistered(sleeve);
        if (cfg.approved != approved) {
            cfg.approved = approved;
            emit SleeveApprovalUpdated(sleeve, approved);
        }
    }

    /// @notice Return the registry and principal-accounting state for one Sleeve.
    /// @param sleeve Sleeve address to query.
    /// @return cfg Registration, approval, underlying, and book-principal state.
    function sleeveConfig(address sleeve) external view returns (LibAppStorage.SleeveConfig memory cfg) {
        cfg = LibAppStorage.appStorage().fm.sleeves[sleeve];
    }

    /// @notice Return every Sleeve in registry insertion order.
    /// @return Registered Sleeve addresses.
    function sleeves() external view returns (address[] memory) {
        return LibAppStorage.appStorage().fm.registeredSleeves;
    }

    /// @notice Aggregated sleeve-held assets for the provided underlying token.
    /// @param asset Underlying asset whose registered sleeve balances are aggregated.
    /// @return total Total assets held across registered sleeves for the requested asset.
    function stakerAssetsInSleeves(address asset) external view returns (uint256 total) {
        LibAppStorage.FundManagerStorage storage fm = LibAppStorage.appStorage().fm;
        address[] memory sleevesList = fm.registeredSleeves;
        for (uint256 i = 0; i < sleevesList.length; ++i) {
            address sleeveAddr = sleevesList[i];
            LibAppStorage.SleeveConfig memory cfg = fm.sleeves[sleeveAddr];
            if (!cfg.registered || cfg.asset != asset) continue;
            total += ISleeve(sleeveAddr).totalAssets();
        }
    }
}
