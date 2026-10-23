// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondEmergencyAuthority} from "diamond-infra/interfaces/IDiamondEmergencyAuthority.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {InitCoordinator} from "diamond-infra/helpers/InitCoordinator.sol";
import {ReentrancyGuardInitializable} from "diamond-infra/helpers/ReentrancyGuardInitializable.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {FacetSelectors as SharedFacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";
import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";
import {StandardInterfaceManifests} from "diamond-infra/libraries/StandardInterfaceManifests.sol";
import {TokenFacet} from "../facets/TokenFacet.sol";
import {InitFacet} from "../facets/InitFacet.sol";
import {ICoreRedemption} from "../interfaces/ICoreRedemption.sol";
import {FacetSelectors} from "./FacetSelectors.sol";
import {CoreAuthorityInvariant} from "./CoreAuthorityInvariant.sol";

/// @notice Consolidated initializer for core diamond infra facets.
/// @dev Used as the `_init` target of diamondCut; owns the component's single OZ initializer context.
contract DiamondInit is InitCoordinator, PausableUpgradeable, ReentrancyGuardInitializable {
    /// @notice Reverts when launch omits the initial administrator.
    error CoreAdminMissing();
    /// @notice Reverts when the installed facet topology differs from the production manifest.
    error CoreFacetTopologyMismatch();
    /// @notice Reverts when the trusted read-only authority invariant module is absent.
    error CoreAuthorityInvariantMissing();

    /// @notice Initializer payload for wiring diamond facets and package-specific state.
    struct InitConfig {
        address admin;
        address safeWallet;
        address authorityInvariant;
        bytes32 authorityInvariantCodeHash;
        address accessControlFacet;
        address pausableFacet;
        address tokenFacet;
        address initFacet;
        address issuanceFacet;
        address redemptionFacet;
        address rebalanceFacet;
        address previewFacet;
        address basketAdminFacet;
        address configFacet;
        address lensFacet;
        address reserveLifecycleFacet;
        address recoveryShareFacet;
        address recoveryShareMetadataFacet;
        address recoveryAdminFacet;
        address recoveryPoolSettlementFacet;
        address coreTreasury;
        address[] basketAssets;
        uint256[] basketTargetsPpm;
        uint256[] basketGoldRefGramsFp18;
        uint256 cygldRefGramsFp18;
        uint256 maxTotalSupply;
        uint256 issuanceFeePpm;
        uint256 redemptionFeePpm;
    }

    /// @notice Initialize core basket diamond state.
    /// @param cfg Initializer or deployment config consumed by this function.
    /// @param name_ Token or governor name used during initialization.
    /// @param symbol_ Token symbol used during initialization.
    function init(InitConfig calldata cfg, string calldata name_, string calldata symbol_) external initializer {
        if (cfg.admin == address(0)) revert CoreAdminMissing();
        bytes32 canonicalAuthorityInvariantCodeHash = keccak256(type(CoreAuthorityInvariant).runtimeCode);
        if (
            cfg.authorityInvariant.code.length == 0
                || cfg.authorityInvariantCodeHash != canonicalAuthorityInvariantCodeHash
                || cfg.authorityInvariant.codehash != canonicalAuthorityInvariantCodeHash
        ) {
            revert CoreAuthorityInvariantMissing();
        }
        _registerCoreInterfaces();
        if (LibDiamond.contractOwner() != cfg.admin) {
            LibDiamond.setContractOwner(cfg.admin);
        }
        _enterInitContext();
        _initPausable(cfg.pausableFacet, cfg.safeWallet);
        // Core remains inert until the configured Safe has reviewed the complete
        // Core/Helpers deployment and explicitly opens economic entrypoints.
        _pause();
        __ReentrancyGuard_init();
        _initToken(cfg.tokenFacet, name_, symbol_);
        _initController(cfg);
        _registerFacetVersion(cfg.issuanceFacet);
        _registerFacetVersion(cfg.redemptionFacet);
        _registerFacetVersion(cfg.rebalanceFacet);
        _registerFacetVersion(cfg.previewFacet);
        _registerFacetVersion(cfg.basketAdminFacet);
        _registerFacetVersion(cfg.configFacet);
        _registerFacetVersion(cfg.lensFacet);
        _registerFacetVersion(cfg.reserveLifecycleFacet);
        _registerFacetVersion(cfg.recoveryShareFacet);
        _registerFacetVersion(cfg.recoveryShareMetadataFacet);
        _registerFacetVersion(cfg.recoveryAdminFacet);
        _registerFacetVersion(cfg.recoveryPoolSettlementFacet);
        _registerInstalledCutFacetVersion();
        _requireProductionFacetTopology(cfg);
        // Authority is deliberately produced only after every product and topology check succeeds.
        // The exact Safe is the sole launch default admin and upgrader.
        _initAccessControl(cfg.accessControlFacet, cfg.safeWallet);
        _exitInitContext();
        LibDiamond.setContractOwner(address(0));
        // This exact code-bound module is view-only. No untrusted or state-producing call follows
        // the final composite authority hook.
        _delegate(
            cfg.authorityInvariant, abi.encodeCall(CoreAuthorityInvariant.requireFinalAuthority, (cfg.safeWallet))
        );
    }

    /// @dev Register core interfaces.
    function _registerCoreInterfaces() internal {
        StandardInterfaceManifests.registerErc165();
        StandardInterfaceManifests.registerDiamondCut();
        StandardInterfaceManifests.registerDiamondLoupe();
        StandardInterfaceManifests.registerAccessControl();
        StandardInterfaceManifests.registerAccessControlEnumerable();
        StandardInterfaceManifests.registerAccessControlDefaultAdminRules();
        _registerEmergencyInterfaceManifest();
        StandardInterfaceManifests.registerErc20();
        StandardInterfaceManifests.registerErc20Metadata();
        StandardInterfaceManifests.registerErc20Permit();
        StandardInterfaceManifests.registerErc1155();
        StandardInterfaceManifests.registerErc1155MetadataUri();
        _registerCoreRedemptionInterfaceManifest();
    }

    function _registerEmergencyInterfaceManifest() private {
        bytes4[][] memory groups = new bytes4[][](1);
        groups[0] = SharedFacetSelectors.pauseSelectors();
        LibInterfaceInvariant.registerInterface(type(IDiamondEmergencyAuthority).interfaceId, groups);
    }

    function _registerCoreRedemptionInterfaceManifest() private {
        bytes4[][] memory groups = new bytes4[][](2);
        groups[0] = FacetSelectors.redemptionSelectors();
        groups[1] = FacetSelectors.redemptionPreviewSelectors();
        LibInterfaceInvariant.registerInterface(type(ICoreRedemption).interfaceId, groups);
    }

    /// @dev Internal helper for init access control.
    /// @param accessControlFacet AccessControl facet called during diamond initialization.
    /// @param admin Exact Safe account receiving initial control roles.
    function _initAccessControl(address accessControlFacet, address admin) internal {
        _delegateInit(
            accessControlFacet,
            abi.encodeWithSelector(
                DefaultAdminAccessControlFacet.initDefaultAdminAccessControlFromOuter.selector, admin
            )
        );
    }

    /// @dev Internal helper for init pausable.
    /// @param pausableFacet Pausable facet called during diamond initialization.
    function _initPausable(address pausableFacet, address safeWallet_) internal {
        _delegateInit(pausableFacet, abi.encodeWithSelector(PausableFacet.initPausableFromOuter.selector, safeWallet_));
    }

    /// @dev Internal helper for init token.
    /// @param tokenFacet Token facet called during initialization.
    /// @param name_ Token or governor name used during initialization.
    /// @param symbol_ Token symbol used during initialization.
    function _initToken(address tokenFacet, string memory name_, string memory symbol_) internal {
        _delegateInit(tokenFacet, abi.encodeWithSelector(TokenFacet.initToken.selector, name_, symbol_));
    }

    /// @dev Internal helper for init controller.
    /// @param cfg Initializer or deployment config consumed by this function.
    function _initController(InitConfig calldata cfg) internal {
        InitFacet.ControllerInitConfig memory controllerCfg = InitFacet.ControllerInitConfig({
            coreTreasury: cfg.coreTreasury,
            assets: cfg.basketAssets,
            targetsPpm: cfg.basketTargetsPpm,
            goldRefGramsFp18: cfg.basketGoldRefGramsFp18,
            cygldRefGramsFp18: cfg.cygldRefGramsFp18,
            maxTotalSupply: cfg.maxTotalSupply,
            issuanceFeePpm: cfg.issuanceFeePpm,
            redemptionFeePpm: cfg.redemptionFeePpm
        });
        _delegateInit(cfg.initFacet, abi.encodeWithSelector(InitFacet.initController.selector, controllerCfg));
    }

    /// @dev Register facet version.
    /// @param facet Facet address probed or initialized by the helper.
    function _registerFacetVersion(address facet) internal {
        _checkAndSetLaunchFacetVersion(facet);
    }

    /// @dev Internal helper for delegate init.
    /// @param target Contract address called or initialized by the operation.
    /// @param data Opaque calldata passed to the selected initializer.
    function _delegateInit(address target, bytes memory data) internal {
        if (_isInstalledFacet(target)) {
            _checkAndSetLaunchFacetVersion(target);
        }

        _delegate(target, data);
    }

    function _delegate(address target, bytes memory data) private {
        (bool ok, bytes memory err) = target.delegatecall(data);
        if (!ok) {
            // The same byte-exact propagation also handles an empty revert payload.
            assembly ("memory-safe") {
                revert(add(err, 0x20), mload(err))
            }
        }
    }

    function _registerInstalledCutFacetVersion() internal {
        address facet =
            LibDiamond.diamondStorage().facetAddressAndSelectorPosition[IDiamondCut.diamondCut.selector].facetAddress;
        if (facet == address(0)) revert CoreFacetTopologyMismatch();
        _checkAndSetLaunchFacetVersion(facet);
        bytes4[] memory loupeSelectors = SharedFacetSelectors.loupeSelectors();
        facet = LibDiamond.diamondStorage().facetAddressAndSelectorPosition[loupeSelectors[0]].facetAddress;
        if (facet == address(0)) revert CoreFacetTopologyMismatch();
        _checkAndSetLaunchFacetVersion(facet);
    }

    function _requireProductionFacetTopology(InitConfig calldata cfg) internal view {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address cutFacet = ds.facetAddressAndSelectorPosition[IDiamondCut.diamondCut.selector].facetAddress;
        bytes4[] memory loupeSelectors = SharedFacetSelectors.loupeSelectors();
        address loupeFacet = ds.facetAddressAndSelectorPosition[loupeSelectors[0]].facetAddress;
        uint256 expectedSelectorCount;
        // Every group is a compile-time generated manifest (103 selectors in total),
        // so their cardinality sum cannot approach the uint256 limit.
        unchecked {
            expectedSelectorCount += _requireSelectorGroup(cutFacet, SharedFacetSelectors.cutSelectors());
            expectedSelectorCount += _requireSelectorGroup(loupeFacet, loupeSelectors);
            expectedSelectorCount += _requireSelectorGroup(
                cfg.accessControlFacet, SharedFacetSelectors.defaultAdminAccessSelectors()
            );
            expectedSelectorCount += _requireSelectorGroup(cfg.pausableFacet, SharedFacetSelectors.pauseSelectors());
            expectedSelectorCount += _requireSelectorGroup(cfg.tokenFacet, FacetSelectors.tokenSelectors());
            expectedSelectorCount += _requireSelectorGroup(cfg.issuanceFacet, FacetSelectors.issuanceSelectors());
            expectedSelectorCount += _requireSelectorGroup(cfg.redemptionFacet, FacetSelectors.redemptionSelectors());
            expectedSelectorCount += _requireSelectorGroup(cfg.rebalanceFacet, FacetSelectors.rebalanceSelectors());
            expectedSelectorCount += _requireSelectorGroup(cfg.previewFacet, FacetSelectors.previewSelectors());
            expectedSelectorCount += _requireSelectorGroup(cfg.basketAdminFacet, FacetSelectors.basketAdminSelectors());
            expectedSelectorCount += _requireSelectorGroup(cfg.configFacet, FacetSelectors.configSelectors());
            expectedSelectorCount += _requireSelectorGroup(cfg.lensFacet, FacetSelectors.lensSelectors());
            expectedSelectorCount += _requireSelectorGroup(
                cfg.reserveLifecycleFacet, FacetSelectors.reserveLifecycleSelectors()
            );
            expectedSelectorCount += _requireSelectorGroup(
                cfg.recoveryShareFacet, FacetSelectors.recoveryShareSelectors()
            );
            expectedSelectorCount += _requireSelectorGroup(
                cfg.recoveryShareMetadataFacet, FacetSelectors.recoveryShareMetadataSelectors()
            );
            expectedSelectorCount += _requireSelectorGroup(
                cfg.recoveryAdminFacet, FacetSelectors.recoveryAdminSelectors()
            );
            expectedSelectorCount += _requireSelectorGroup(
                cfg.recoveryPoolSettlementFacet, FacetSelectors.recoveryPoolSettlementSelectors()
            );
        }
        if (ds.selectors.length != expectedSelectorCount) {
            revert CoreFacetTopologyMismatch();
        }
    }

    function _requireSelectorGroup(address facet, bytes4[] memory selectors) internal view returns (uint256) {
        if (facet == address(0)) revert CoreFacetTopologyMismatch();
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        for (uint256 i; i < selectors.length;) {
            address actual = ds.facetAddressAndSelectorPosition[selectors[i]].facetAddress;
            if (actual != facet) revert CoreFacetTopologyMismatch();
            unchecked {
                ++i;
            }
        }
        return selectors.length;
    }
}
