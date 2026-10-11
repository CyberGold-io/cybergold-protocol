// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IDiamondEmergencyAuthority} from "../interfaces/IDiamondEmergencyAuthority.sol";

import {InitCoordinator} from "../helpers/InitCoordinator.sol";
import {AccessControlFacet} from "../facets/AccessControlFacet.sol";
import {PausableFacet} from "../facets/PausableFacet.sol";
import {ReentrancyGuardFacet} from "../facets/ReentrancyGuardFacet.sol";
import {FacetSelectors} from "./FacetSelectors.sol";
import {LibInterfaceInvariant} from "../libraries/LibInterfaceInvariant.sol";
import {StandardInterfaceManifests} from "../libraries/StandardInterfaceManifests.sol";

/// @notice Minimal initializer for the shared infra diamond used in tests.
contract InfraInit is InitCoordinator {
    /// @notice Reverts when facet init failed.
    /// @param target Contract address called or initialized by the operation.
    /// @param data Opaque calldata passed to the selected initializer.
    error FacetInitFailed(address target, bytes data);

    /// @notice Initializer payload for wiring diamond facets and package-specific state.
    struct InitConfig {
        address admin;
        address safeWallet;
        address accessControlFacet;
        address pausableFacet;
        address reentrancyFacet;
    }

    /// @notice Initialize shared diamond infrastructure state.
    /// @param cfg Initializer or deployment config consumed by this function.
    function init(InitConfig calldata cfg) external {
        _registerCoreInterfaces(cfg.pausableFacet);
        _enterInitContext();
        _delegateInit(
            cfg.accessControlFacet, abi.encodeWithSelector(AccessControlFacet.initAccessControl.selector, cfg.admin)
        );
        _delegateInit(cfg.pausableFacet, abi.encodeWithSelector(PausableFacet.initPausable.selector, cfg.safeWallet));
        _delegateInit(cfg.reentrancyFacet, abi.encodeWithSelector(ReentrancyGuardFacet.initReentrancyGuard.selector));
        _exitInitContext();
    }

    /// @dev Register core interfaces.
    function _registerCoreInterfaces(address pausableFacet) internal {
        StandardInterfaceManifests.registerErc165();
        StandardInterfaceManifests.registerDiamondCut();
        StandardInterfaceManifests.registerDiamondLoupe();
        StandardInterfaceManifests.registerAccessControl();
        StandardInterfaceManifests.registerAccessControlEnumerable();
        if (pausableFacet != address(0)) {
            bytes4[][] memory groups = new bytes4[][](1);
            groups[0] = FacetSelectors.pauseSelectors();
            LibInterfaceInvariant.registerInterface(type(IDiamondEmergencyAuthority).interfaceId, groups);
        }
    }

    /// @dev Internal helper for delegate init.
    /// @param target Contract address called or initialized by the operation.
    /// @param data Opaque calldata passed to the selected initializer.
    function _delegateInit(address target, bytes memory data) internal {
        if (target == address(0)) return;
        if (_isInstalledFacet(target)) {
            _checkAndSetLaunchFacetVersion(target);
        }
        (bool ok, bytes memory err) = target.delegatecall(data);
        if (!ok) {
            if (err.length > 0) {
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
            revert FacetInitFailed(target, data);
        }
    }
}
