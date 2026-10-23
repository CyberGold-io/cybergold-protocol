// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";

import {DiamondArgs} from "diamond-1/Diamond.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

import {ProtocolDiamond} from "../src/diamond/ProtocolDiamond.sol";
import {FacetSelectors} from "../src/deploy/FacetSelectors.sol";
import {AccessControlFacet} from "../src/facets/AccessControlFacet.sol";
import {DiamondCutAccessLiveFacet} from "../src/facets/DiamondCutAccessLiveFacet.sol";
import {ProtocolDiamondLoupeFacet} from "../src/facets/ProtocolDiamondLoupeFacet.sol";
import {LiveFacetVersionRegistry} from "../src/helpers/LiveFacetVersionRegistry.sol";
import {LiveInitCoordinator} from "../src/helpers/LiveInitCoordinator.sol";
import {LiveValidatedDiamondCut} from "../src/helpers/LiveValidatedDiamondCut.sol";
import {StandardInterfaceManifests} from "../src/libraries/StandardInterfaceManifests.sol";

contract AuthorityCoverageLaunchInit is LiveInitCoordinator {
    error AccessInitializationFailed(address target);

    function init(address admin, address cutFacet, address loupeFacet, address accessFacet) external {
        StandardInterfaceManifests.registerErc165();
        StandardInterfaceManifests.registerDiamondCut();
        StandardInterfaceManifests.registerDiamondLoupe();
        StandardInterfaceManifests.registerAccessControl();
        StandardInterfaceManifests.registerAccessControlEnumerable();

        _checkAndSetLiveLaunchFacetGeneration(cutFacet);
        _checkAndSetLiveLaunchFacetGeneration(loupeFacet);
        _checkAndSetLiveLaunchFacetGeneration(accessFacet);

        _enterInitContext();
        (bool ok, bytes memory reason) =
            accessFacet.delegatecall(abi.encodeCall(AccessControlFacet.initAccessControl, (admin)));
        _exitInitContext();
        if (!ok) {
            if (reason.length != 0) {
                assembly {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
            revert AccessInitializationFailed(accessFacet);
        }
    }
}

contract AuthorityCoverageUpgradeInit {
    function consume(address) external pure {}
}

contract AuthorityCoverageManifestInit {
    bytes32 private constant INTERFACE_SELECTOR_MANIFESTS_SLOT =
        0xff092d620461098e263264e3201620767bd3639a1424ca912571a18d26f5966e;

    function setAdvertisement(bytes4 interfaceId, bool advertised) external {
        bytes32 advertisedSlot = bytes32(uint256(INTERFACE_SELECTOR_MANIFESTS_SLOT) + 2);
        bytes32 valueSlot = keccak256(abi.encode(interfaceId, advertisedSlot));
        assembly {
            sstore(valueSlot, advertised)
        }
    }

    function disableAccessAdvertisements() external {
        _setAdvertisement(type(IAccessControl).interfaceId, false);
        _setAdvertisement(type(IAccessControlEnumerable).interfaceId, false);
    }

    function _setAdvertisement(bytes4 interfaceId, bool advertised) private {
        bytes32 advertisedSlot = bytes32(uint256(INTERFACE_SELECTOR_MANIFESTS_SLOT) + 2);
        bytes32 valueSlot = keccak256(abi.encode(interfaceId, advertisedSlot));
        assembly {
            sstore(valueSlot, advertised)
        }
    }
}

contract LiveFacetVersionRegistryCoverageHarness is LiveFacetVersionRegistry {
    function install(address target, bytes4 selector) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.selectors.push(selector);
        ds.facetAddressAndSelectorPosition[selector].facetAddress = target;
    }

    function probeNamespace(address target) external view returns (bytes32 namespace) {
        return _facetNamespace(target);
    }

    function registerLaunch(address target) external returns (bytes32 namespace, uint64 generation) {
        return _checkAndSetLiveLaunchFacetGeneration(target);
    }

    function registeredGeneration(bytes32 namespace) external view returns (uint64) {
        return _facetVersions().versions[namespace];
    }

    function isInstalled(address target) external view returns (bool) {
        return _isInstalledFacet(target);
    }
}

contract AuthorityCoverageVersionedFacet {
    bytes32 public immutable FACET_NAMESPACE;
    uint64 public immutable FACET_VERSION;

    constructor(bytes32 namespace, uint64 version) {
        FACET_NAMESPACE = namespace;
        FACET_VERSION = version;
    }
}

contract AuthorityCoverageMissingMetadata {}

contract AuthorityCoverageNamespaceOnly {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.coverage.namespace-only");
}

contract AuthorityCoverageMalformedMetadata {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(31, 1)
        }
    }
}

contract AuthorityCoverageRoleCountFaultFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.coverage.role-count-fault");
    uint64 public constant FACET_VERSION = 1;

    uint8 private immutable _mode;

    constructor(uint8 mode) {
        _mode = mode;
    }

    function getRoleMemberCount(bytes32 role) external view returns (uint256) {
        bool isAdmin = role == bytes32(0);
        if (_mode == 0 || (_mode == 3 && isAdmin)) revert();
        if (_mode == 1 || (_mode == 4 && isAdmin)) {
            assembly {
                return(0, 0)
            }
        }
        if ((_mode == 2 && !isAdmin) || (_mode == 5 && isAdmin)) return 0;
        return 1;
    }
}

contract AuthorityCoverageRoleMemberFaultFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.coverage.role-member-fault");
    uint64 public constant FACET_VERSION = 1;

    uint8 private immutable _mode;

    constructor(uint8 mode) {
        _mode = mode;
    }

    function getRoleMemberCount(bytes32) external pure returns (uint256) {
        return 1;
    }

    function getRoleMember(bytes32, uint256) external view returns (address) {
        if (_mode == 0) revert();
        if (_mode == 1) {
            assembly {
                return(0, 0)
            }
        }
        return address(0);
    }
}

contract AuthorityCoverageRoleMemberSearchFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.coverage.role-member-search");
    uint64 public constant FACET_VERSION = 1;

    address private immutable _member;

    constructor(address member) {
        _member = member;
    }

    function getRoleMemberCount(bytes32) external pure returns (uint256) {
        return 2;
    }

    function getRoleMember(bytes32, uint256 index) external view returns (address) {
        return index == 0 ? address(0) : _member;
    }
}

contract LiveDiamondCutAuthorityCoverageTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant USER = address(0xBEEF);
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    struct BaseDeployment {
        address diamond;
        DiamondCutAccessLiveFacet cut;
        ProtocolDiamondLoupeFacet loupe;
        AccessControlFacet access;
    }

    function testLiveCoordinatorMetadataUnauthorizedAndAuthorizedCut() public {
        BaseDeployment memory base = _deployBase();
        IDiamond.FacetCut[] memory noCuts = new IDiamond.FacetCut[](0);

        assertEq(base.cut.FACET_NAMESPACE(), keccak256("cybergold.upgrade.coordinator.access"));

        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondCutAccessLiveFacet.AccessControlUnauthorizedAccount.selector, USER, UPGRADER_ROLE
            )
        );
        IDiamondCut(base.diamond).diamondCut(noCuts, address(0), "");

        vm.prank(ADMIN);
        IDiamondCut(base.diamond).diamondCut(noCuts, address(0), "");
    }

    function testLiveAuthorityRejectsMissingAccessInterfaceAdvertisements() public {
        bytes4[2] memory interfaceIds = [type(IAccessControl).interfaceId, type(IAccessControlEnumerable).interfaceId];

        for (uint256 i; i < interfaceIds.length; ++i) {
            BaseDeployment memory base = _deployBase();
            AuthorityCoverageManifestInit init = new AuthorityCoverageManifestInit();
            IDiamond.FacetCut[] memory noCuts = new IDiamond.FacetCut[](0);

            vm.prank(ADMIN);
            vm.expectRevert(
                abi.encodeWithSelector(
                    LiveValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, IAccessControl.hasRole.selector
                )
            );
            IDiamondCut(base.diamond)
                .diamondCut(
                    noCuts,
                    address(init),
                    abi.encodeCall(AuthorityCoverageManifestInit.setAdvertisement, (interfaceIds[i], false))
                );
        }
    }

    function testLiveAuthorityRejectsRemovedRecoverySelectors() public {
        bytes4[5] memory selectors = [
            IAccessControl.grantRole.selector,
            IAccessControl.revokeRole.selector,
            IAccessControl.hasRole.selector,
            IAccessControlEnumerable.getRoleMember.selector,
            IAccessControlEnumerable.getRoleMemberCount.selector
        ];

        for (uint256 i; i < selectors.length; ++i) {
            BaseDeployment memory base = _deployBase();
            AuthorityCoverageManifestInit init = new AuthorityCoverageManifestInit();

            vm.prank(ADMIN);
            vm.expectRevert(
                abi.encodeWithSelector(LiveValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, selectors[i])
            );
            IDiamondCut(base.diamond)
                .diamondCut(
                    _singleCut(address(0), IDiamond.FacetCutAction.Remove, selectors[i]),
                    address(init),
                    abi.encodeCall(AuthorityCoverageManifestInit.disableAccessAdvertisements, ())
                );
        }
    }

    function testLiveAuthorityRejectsEveryRoleCountFailureMode() public {
        BaseDeployment memory base = _deployBase();
        AuthorityCoverageUpgradeInit init = new AuthorityCoverageUpgradeInit();

        for (uint8 mode; mode < 6; ++mode) {
            AuthorityCoverageRoleCountFaultFacet facet = new AuthorityCoverageRoleCountFaultFacet(mode);

            vm.prank(ADMIN);
            vm.expectRevert(
                abi.encodeWithSelector(
                    LiveValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector,
                    IAccessControlEnumerable.getRoleMemberCount.selector
                )
            );
            IDiamondCut(base.diamond)
                .diamondCut(
                    _singleCut(
                        address(facet),
                        IDiamond.FacetCutAction.Replace,
                        IAccessControlEnumerable.getRoleMemberCount.selector
                    ),
                    address(init),
                    abi.encodeCall(AuthorityCoverageUpgradeInit.consume, (address(facet)))
                );
        }
    }

    function testLiveAuthorityRejectsEveryRoleMemberFailureMode() public {
        BaseDeployment memory base = _deployBase();
        AuthorityCoverageUpgradeInit init = new AuthorityCoverageUpgradeInit();

        for (uint8 mode; mode < 3; ++mode) {
            AuthorityCoverageRoleMemberFaultFacet facet = new AuthorityCoverageRoleMemberFaultFacet(mode);
            IDiamond.FacetCut[] memory cut = _roleEnumerationReplacement(address(facet));

            vm.prank(ADMIN);
            vm.expectRevert(
                abi.encodeWithSelector(
                    LiveValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector,
                    IAccessControlEnumerable.getRoleMemberCount.selector
                )
            );
            IDiamondCut(base.diamond)
                .diamondCut(cut, address(init), abi.encodeCall(AuthorityCoverageUpgradeInit.consume, (address(facet))));
        }
    }

    function testLiveAuthoritySearchesPastZeroRoleMember() public {
        BaseDeployment memory base = _deployBase();
        AuthorityCoverageUpgradeInit init = new AuthorityCoverageUpgradeInit();
        AuthorityCoverageRoleMemberSearchFacet facet = new AuthorityCoverageRoleMemberSearchFacet(ADMIN);

        vm.prank(ADMIN);
        IDiamondCut(base.diamond)
            .diamondCut(
                _roleEnumerationReplacement(address(facet)),
                address(init),
                abi.encodeCall(AuthorityCoverageUpgradeInit.consume, (address(facet)))
            );

        assertEq(
            IDiamondLoupe(base.diamond).facetAddress(IAccessControlEnumerable.getRoleMemberCount.selector),
            address(facet)
        );
        assertEq(
            IDiamondLoupe(base.diamond).facetAddress(IAccessControlEnumerable.getRoleMember.selector), address(facet)
        );
    }

    function testLiveRegistryLaunchValidationInstallationAndReplay() public {
        LiveFacetVersionRegistryCoverageHarness harness = new LiveFacetVersionRegistryCoverageHarness();
        bytes32 namespace = keccak256("cybergold.shared.coverage.registry-launch");
        AuthorityCoverageVersionedFacet zeroNamespace = new AuthorityCoverageVersionedFacet(bytes32(0), 1);
        AuthorityCoverageVersionedFacet facet = new AuthorityCoverageVersionedFacet(namespace, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                LiveFacetVersionRegistry.FacetLaunchNamespaceInvalid.selector, address(zeroNamespace), bytes32(0)
            )
        );
        harness.registerLaunch(address(zeroNamespace));

        vm.expectRevert(
            abi.encodeWithSelector(LiveFacetVersionRegistry.FacetRuntimeNotInstalled.selector, address(facet))
        );
        harness.registerLaunch(address(facet));

        harness.install(address(facet), bytes4(0xA0000001));
        (bytes32 registeredNamespace, uint64 registeredGeneration) = harness.registerLaunch(address(facet));
        assertEq(registeredNamespace, namespace);
        assertEq(registeredGeneration, 1);
        assertEq(harness.registeredGeneration(namespace), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                LiveFacetVersionRegistry.FacetGenerationAlreadyInitialized.selector, namespace, uint64(1)
            )
        );
        harness.registerLaunch(address(facet));
    }

    function testLiveRegistryInstalledStates() public {
        LiveFacetVersionRegistryCoverageHarness harness = new LiveFacetVersionRegistryCoverageHarness();
        AuthorityCoverageVersionedFacet first = new AuthorityCoverageVersionedFacet(
            keccak256("cybergold.shared.coverage.registry-installed"), 1
        );
        assertFalse(harness.isInstalled(address(0)));
        assertFalse(harness.isInstalled(address(first)));

        harness.install(address(first), bytes4(0xA0000003));
        assertTrue(harness.isInstalled(address(first)));
    }

    function testLiveRegistryMetadataProbeFailures() public {
        LiveFacetVersionRegistryCoverageHarness harness = new LiveFacetVersionRegistryCoverageHarness();
        AuthorityCoverageMissingMetadata missing = new AuthorityCoverageMissingMetadata();
        AuthorityCoverageNamespaceOnly namespaceOnly = new AuthorityCoverageNamespaceOnly();
        AuthorityCoverageMalformedMetadata malformed = new AuthorityCoverageMalformedMetadata();
        bytes32 namespace = keccak256("cybergold.shared.coverage.probe");
        AuthorityCoverageVersionedFacet valid = new AuthorityCoverageVersionedFacet(namespace, 7);

        _expectProbeFailure(harness, address(missing));
        _expectProbeFailure(harness, address(malformed));
        _expectProbeFailure(harness, address(0));

        assertEq(harness.probeNamespace(address(namespaceOnly)), namespaceOnly.FACET_NAMESPACE());
        assertEq(harness.probeNamespace(address(valid)), namespace);
    }

    function _expectProbeFailure(LiveFacetVersionRegistryCoverageHarness harness, address target) internal {
        vm.expectRevert(abi.encodeWithSelector(LiveFacetVersionRegistry.FacetNamespaceProbeFailed.selector, target));
        harness.probeNamespace(target);
    }

    function _deployBase() internal returns (BaseDeployment memory base) {
        base.cut = new DiamondCutAccessLiveFacet();
        base.loupe = new ProtocolDiamondLoupeFacet();
        base.access = new AccessControlFacet();
        AuthorityCoverageLaunchInit init = new AuthorityCoverageLaunchInit();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](3);
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(base.cut),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: FacetSelectors.liveCutSelectors()
        });
        cuts[1] = IDiamond.FacetCut({
            facetAddress: address(base.loupe),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: FacetSelectors.loupeSelectors()
        });
        cuts[2] = IDiamond.FacetCut({
            facetAddress: address(base.access),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: FacetSelectors.accessSelectors()
        });

        DiamondArgs memory args = DiamondArgs({
            owner: ADMIN,
            init: address(init),
            initCalldata: abi.encodeCall(
                AuthorityCoverageLaunchInit.init, (ADMIN, address(base.cut), address(base.loupe), address(base.access))
            )
        });
        base.diamond = address(new ProtocolDiamond(cuts, args));
    }

    function _roleEnumerationReplacement(address facet) internal pure returns (IDiamond.FacetCut[] memory cut) {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IAccessControlEnumerable.getRoleMemberCount.selector;
        selectors[1] = IAccessControlEnumerable.getRoleMember.selector;
        cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: facet, action: IDiamond.FacetCutAction.Replace, functionSelectors: selectors
        });
    }

    function _singleCut(address facet, IDiamond.FacetCutAction action, bytes4 selector)
        internal
        pure
        returns (IDiamond.FacetCut[] memory cut)
    {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({facetAddress: facet, action: action, functionSelectors: selectors});
    }
}
