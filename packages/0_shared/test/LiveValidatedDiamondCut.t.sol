// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

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
import {LiveInitCoordinator} from "../src/helpers/LiveInitCoordinator.sol";
import {LiveValidatedDiamondCut} from "../src/helpers/LiveValidatedDiamondCut.sol";
import {LibInterfaceInvariant} from "../src/libraries/LibInterfaceInvariant.sol";
import {StandardInterfaceManifests} from "../src/libraries/StandardInterfaceManifests.sol";

contract LiveCutLaunchInit is LiveInitCoordinator {
    error AccessInitFailed(address target, bytes data);

    function init(
        address admin,
        address cutFacet,
        address loupeFacet,
        address accessFacet,
        address[] calldata extraGenerationFacets
    ) external {
        StandardInterfaceManifests.registerErc165();
        StandardInterfaceManifests.registerDiamondCut();
        StandardInterfaceManifests.registerDiamondLoupe();
        StandardInterfaceManifests.registerAccessControl();
        StandardInterfaceManifests.registerAccessControlEnumerable();

        _checkAndSetLiveLaunchFacetGeneration(cutFacet);
        _checkAndSetLiveLaunchFacetGeneration(loupeFacet);
        _checkAndSetLiveLaunchFacetGeneration(accessFacet);
        for (uint256 i; i < extraGenerationFacets.length; ++i) {
            _checkAndSetLiveLaunchFacetGeneration(extraGenerationFacets[i]);
        }

        bytes memory data = abi.encodeCall(AccessControlFacet.initAccessControl, (admin));
        _enterInitContext();
        (bool ok, bytes memory err) = accessFacet.delegatecall(data);
        _exitInitContext();
        if (!ok) {
            if (err.length != 0) {
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
            revert AccessInitFailed(accessFacet, data);
        }
    }
}

contract LiveCutUpgradeInit {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 private constant INTERFACE_SELECTOR_MANIFESTS_SLOT =
        0xff092d620461098e263264e3201620767bd3639a1424ca912571a18d26f5966e;

    function init(address) external pure {}

    function noop() external pure {}

    function initAndReenter(address) external {
        IDiamondCut.FacetCut[] memory noCuts = new IDiamondCut.FacetCut[](0);
        IDiamondCut(address(this)).diamondCut(noCuts, address(0), "");
    }

    function initAndSetFacetVersion(address facet, uint64 newVersion) external {
        VM.store(facet, bytes32(uint256(1)), bytes32(uint256(newVersion)));
    }

    function initAndSetFacetNamespace(address facet, bytes32 newNamespace) external {
        VM.store(facet, bytes32(0), newNamespace);
    }

    function initAndEtchFacet(address facet, address replacement) external {
        VM.etch(facet, replacement.code);
    }

    function initAndAppendSelector(address, bytes4 selector) external {
        LibDiamond.diamondStorage().selectors.push(selector);
    }

    function initAndSetSelectorOwner(address, bytes4 selector, address owner) external {
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress = owner;
    }

    function initAndSetSelectorPosition(address, bytes4 selector, uint16 position) external {
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].selectorPosition = position;
    }

    function initAndSubstituteEnumerableSelector(address, bytes4 declaredSelector, bytes4 undeclaredSelector) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        LibDiamond.FacetAddressAndSelectorPosition memory declared =
            ds.facetAddressAndSelectorPosition[declaredSelector];
        ds.selectors[declared.selectorPosition] = undeclaredSelector;
        ds.facetAddressAndSelectorPosition[undeclaredSelector] = declared;
    }

    function initAndEtchIncumbent(address, address incumbent, address replacement) external {
        VM.etch(incumbent, replacement.code);
    }

    function initAndSetRegistryGeneration(bytes32 namespace, uint64 generation) external {
        bytes32 generationSlot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
        VM.store(address(this), generationSlot, bytes32(uint256(generation)));
    }

    function setManifestAdvertisement(bytes4 interfaceId, bool advertised) external {
        bytes32 advertisedSlot = bytes32(uint256(INTERFACE_SELECTOR_MANIFESTS_SLOT) + 2);
        bytes32 valueSlot = keccak256(abi.encode(interfaceId, advertisedSlot));
        assembly {
            sstore(valueSlot, advertised)
        }
    }

    function initAndRegisterInterface(address, bytes4 interfaceId, bytes4 selector) external {
        bytes4[][] memory groups = new bytes4[][](1);
        groups[0] = new bytes4[](1);
        groups[0][0] = selector;
        LibInterfaceInvariant.registerInterface(interfaceId, groups);
    }
}

contract LivePairFacetV1 {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.test.live.pair");
    uint64 public constant FACET_VERSION = 1;

    function pairAlpha() external pure returns (uint256) {
        return 1;
    }

    function pairBeta() external pure returns (uint256) {
        return 2;
    }
}

contract LivePairFacetV2 {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.test.live.pair");
    uint64 public constant FACET_VERSION = 2;

    function pairAlpha() external pure returns (uint256) {
        return 11;
    }

    function pairBeta() external pure returns (uint256) {
        return 22;
    }

    function pairGamma() external pure returns (uint256) {
        return 33;
    }
}

contract LiveMutableFacet {
    bytes32 public FACET_NAMESPACE;
    uint64 public FACET_VERSION;

    constructor(bytes32 namespace, uint64 version) {
        FACET_NAMESPACE = namespace;
        FACET_VERSION = version;
    }

    function mutableProbe() external pure returns (bytes32) {
        return keccak256("live-mutable-runtime");
    }
}

contract LiveMutableFacetReplacementRuntime {
    bytes32 public FACET_NAMESPACE;
    uint64 public FACET_VERSION;

    function mutableProbe() external pure returns (bytes32) {
        return keccak256("live-mutated-runtime");
    }
}

contract LiveAuxiliaryFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.test.live.auxiliary");
    uint64 public constant FACET_VERSION = 1;

    function auxiliaryProbe() external pure returns (uint256) {
        return 42;
    }
}

contract LiveOversizedVersionFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.test.live.oversized-version");
    uint256 public constant FACET_VERSION = type(uint256).max;

    function oversizedProbe() external pure returns (uint256) {
        return 1;
    }
}

contract LiveTopologyCorruptorFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.test.live.topology-corruptor");
    uint64 public constant FACET_VERSION = 1;

    function duplicateEnumerableSelector(bytes4 selector, uint256 targetIndex) external {
        LibDiamond.diamondStorage().selectors[targetIndex] = selector;
    }
}

contract LiveMultiFacetA {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.test.live.multi-incumbent");
    uint64 public constant FACET_VERSION = 1;

    function multiAlpha() external pure returns (uint256) {
        return 1;
    }
}

contract LiveMultiFacetB {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.test.live.multi-incumbent");
    uint64 public FACET_VERSION;

    constructor(uint64 version) {
        FACET_VERSION = version;
    }

    function multiAlpha() external pure returns (uint256) {
        return 10;
    }

    function multiBeta() external pure returns (uint256) {
        return 20;
    }
}

contract LiveMultiFacetC {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.test.live.multi-incumbent");

    function multiGamma() external pure returns (uint256) {
        return 30;
    }
}

contract LiveNoMetadataFacet {
    function noMetadataProbe() external pure returns (uint256) {
        return 1;
    }
}

contract LiveMalformedMetadataFacet {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(31, 1)
        }
    }
}

contract LiveSelectorOwnerCorruptorFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.test.live.selector-owner-corruptor");

    function setSelectorOwner(bytes4 selector, address owner) external {
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress = owner;
    }
}

contract LiveValidatedDiamondCutTest is Test {
    bytes32 private constant FACET_GENERATION_UPDATED_TOPIC =
        keccak256("FacetGenerationUpdated(bytes32,address,address,bytes32,bytes32,uint64)");
    bytes4 private constant FACET_GENERATION_SELECTOR = bytes4(keccak256("facetGeneration(bytes32)"));
    address internal constant ADMIN = address(0xA11CE);
    bytes32 internal constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;

    struct BaseDeployment {
        address diamond;
        DiamondCutAccessLiveFacet cut;
        ProtocolDiamondLoupeFacet loupe;
        AccessControlFacet access;
    }

    function testLiveCutAddsReplacesAndRemovesWithoutInitializer() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LivePairFacetV1 first = new LivePairFacetV1();
        LivePairFacetV2 second = new LivePairFacetV2();
        vm.startPrank(ADMIN);
        IDiamondCut(base.diamond).diamondCut(_pairCut(address(first), IDiamond.FacetCutAction.Add), address(0), "");
        assertEq(_registeredGeneration(base.diamond, first.FACET_NAMESPACE()), 1);
        IDiamondCut(base.diamond).diamondCut(_pairCut(address(second), IDiamond.FacetCutAction.Replace), address(0), "");
        assertEq(_registeredGeneration(base.diamond, first.FACET_NAMESPACE()), 2);
        assertEq(LivePairFacetV2(base.diamond).pairAlpha(), 11);
        assertEq(LivePairFacetV2(base.diamond).pairBeta(), 22);
        IDiamondCut(base.diamond).diamondCut(_pairCut(address(0), IDiamond.FacetCutAction.Remove), address(0), "");
        vm.stopPrank();
        assertEq(_registeredGeneration(base.diamond, first.FACET_NAMESPACE()), 0);
    }

    function testLiveCutWithoutInitializerStillRejectsUnauthorizedAndUnchangedRuntime() public {
        LivePairFacetV1 first = new LivePairFacetV1();
        BaseDeployment memory base = _deployWithGenerationExtra(address(first), LivePairFacetV1.pairAlpha.selector);
        LivePairFacetV1 duplicate = new LivePairFacetV1();
        IDiamond.FacetCut[] memory cut =
            _singleCut(address(duplicate), IDiamond.FacetCutAction.Replace, LivePairFacetV1.pairAlpha.selector);
        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondCutAccessLiveFacet.AccessControlUnauthorizedAccount.selector,
                address(this),
                keccak256("UPGRADER_ROLE")
            )
        );
        IDiamondCut(base.diamond).diamondCut(cut, address(0), "");
        bytes32 namespace = first.FACET_NAMESPACE();
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutFacetRuntimeUnchanged.selector,
                namespace,
                address(first),
                address(duplicate),
                address(first).codehash
            )
        );
        IDiamondCut(base.diamond).diamondCut(cut, address(0), "");
    }

    function testLiveLaunchRegistersGenerationsButLeavesLegacyAndRetiredSlotsZero() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));

        bytes32 cutNamespace = base.cut.FACET_NAMESPACE();
        bytes32 loupeNamespace = base.loupe.FACET_NAMESPACE();
        bytes32 accessNamespace = base.access.FACET_NAMESPACE();
        assertEq(_registeredGeneration(base.diamond, cutNamespace), 1);
        assertEq(_registeredGeneration(base.diamond, loupeNamespace), 1);
        assertEq(_registeredGeneration(base.diamond, accessNamespace), 1);
        assertEq(_legacyRuntimeHash(base.diamond, cutNamespace), bytes32(0));
        assertEq(_legacyRuntimeHash(base.diamond, loupeNamespace), bytes32(0));
        assertEq(_legacyRuntimeHash(base.diamond, accessNamespace), bytes32(0));
        _assertRetiredSlotsZero(base.diamond, cutNamespace);
        _assertRetiredSlotsZero(base.diamond, loupeNamespace);
        _assertRetiredSlotsZero(base.diamond, accessNamespace);

        assertTrue(IERC165(base.diamond).supportsInterface(type(IERC165).interfaceId));
        assertTrue(IERC165(base.diamond).supportsInterface(type(IDiamondCut).interfaceId));
        assertTrue(IERC165(base.diamond).supportsInterface(type(IDiamondLoupe).interfaceId));
        assertTrue(IERC165(base.diamond).supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(IERC165(base.diamond).supportsInterface(type(IAccessControlEnumerable).interfaceId));
    }

    function testLiveCutRejectsSameRuntimeAtDifferentAddressDespiteDifferentLegacyLabel() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        bytes32 namespace = keccak256("cybergold.shared.test.live.mutable-replace");
        LiveMutableFacet first = new LiveMutableFacet(namespace, 1);
        LiveMutableFacet second = new LiveMutableFacet(namespace, 2);
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        assertEq(address(first).codehash, address(second).codehash);

        _execute(
            base.diamond,
            _singleCut(address(first), IDiamond.FacetCutAction.Add, LiveMutableFacet.mutableProbe.selector),
            init,
            address(first)
        );

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutFacetRuntimeUnchanged.selector,
                namespace,
                address(first),
                address(second),
                address(second).codehash
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(second), IDiamond.FacetCutAction.Replace, LiveMutableFacet.mutableProbe.selector),
                address(init),
                abi.encodeCall(LiveCutUpgradeInit.init, (address(second)))
            );
    }

    function testLiveCutRejectsRemoveOrReplaceOfGenerationGetter() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LivePairFacetV1 candidate = new LivePairFacetV1();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();

        vm.startPrank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutCoordinatorImmutable.selector, FACET_GENERATION_SELECTOR
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(0), IDiamond.FacetCutAction.Remove, FACET_GENERATION_SELECTOR), address(0), ""
            );

        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutCoordinatorImmutable.selector, FACET_GENERATION_SELECTOR
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(candidate), IDiamond.FacetCutAction.Replace, FACET_GENERATION_SELECTOR),
                address(init),
                abi.encodeCall(LiveCutUpgradeInit.init, (address(candidate)))
            );

        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutSelectorOwnerMismatch.selector,
                FACET_GENERATION_SELECTOR,
                address(base.cut),
                address(candidate)
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                new IDiamond.FacetCut[](0),
                address(init),
                abi.encodeCall(
                    LiveCutUpgradeInit.initAndSetSelectorOwner,
                    (address(candidate), FACET_GENERATION_SELECTOR, address(candidate))
                )
            );
        vm.stopPrank();

        assertEq(IDiamondLoupe(base.diamond).facetAddress(FACET_GENERATION_SELECTOR), address(base.cut));
    }

    function testLiveCutIgnoresAndPreservesLegacySentinelAndEqualHash() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LivePairFacetV1 first = new LivePairFacetV1();
        LivePairFacetV2 second = new LivePairFacetV2();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        bytes32 namespace = first.FACET_NAMESPACE();
        bytes32 legacySlot = _registryMapSlot(namespace, 1);
        bytes32 sentinel = bytes32(uint256(1));

        vm.store(base.diamond, legacySlot, sentinel);
        _execute(base.diamond, _pairCut(address(first), IDiamond.FacetCutAction.Add), init, address(first));
        assertEq(vm.load(base.diamond, legacySlot), sentinel);
        assertNotEq(address(first).codehash, address(second).codehash);

        vm.store(base.diamond, legacySlot, address(second).codehash);
        _execute(base.diamond, _pairCut(address(second), IDiamond.FacetCutAction.Replace), init, address(second));
        assertEq(vm.load(base.diamond, legacySlot), address(second).codehash);
        assertEq(LivePairFacetV2(base.diamond).pairAlpha(), 11);
        assertEq(LivePairFacetV2(base.diamond).pairBeta(), 22);
        assertEq(_registeredGeneration(base.diamond, namespace), 2);
        _assertRetiredSlotsZero(base.diamond, namespace);
    }

    function testLiveCutIgnoresCorruptLegacyHashAndStillRejectsUnchangedLiveRuntime() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        bytes32 namespace = keccak256("cybergold.shared.test.live.corrupt-legacy");
        LiveMutableFacet first = new LiveMutableFacet(namespace, 1);
        LiveMutableFacet second = new LiveMutableFacet(namespace, 2);
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        bytes32 legacySlot = _registryMapSlot(namespace, 1);
        bytes32 corrupt = keccak256("corrupt-legacy-runtime-hash");

        _execute(
            base.diamond,
            _singleCut(address(first), IDiamond.FacetCutAction.Add, LiveMutableFacet.mutableProbe.selector),
            init,
            address(first)
        );
        vm.store(base.diamond, legacySlot, corrupt);

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutFacetRuntimeUnchanged.selector,
                namespace,
                address(first),
                address(second),
                address(second).codehash
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(second), IDiamond.FacetCutAction.Replace, LiveMutableFacet.mutableProbe.selector),
                address(init),
                abi.encodeCall(LiveCutUpgradeInit.init, (address(second)))
            );
        assertEq(vm.load(base.diamond, legacySlot), corrupt);
    }

    function testLiveCutAllowsCompleteSameNamespaceReplaceWithoutPendingStorage() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LivePairFacetV1 first = new LivePairFacetV1();
        LivePairFacetV2 second = new LivePairFacetV2();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        bytes32 namespace = first.FACET_NAMESPACE();

        _execute(base.diamond, _pairCut(address(first), IDiamond.FacetCutAction.Add), init, address(first));
        _assertRetiredSlotsZero(base.diamond, namespace);

        _execute(base.diamond, _pairCut(address(second), IDiamond.FacetCutAction.Replace), init, address(second));
        assertEq(IDiamondLoupe(base.diamond).facetAddress(LivePairFacetV1.pairAlpha.selector), address(second));
        assertEq(IDiamondLoupe(base.diamond).facetAddress(LivePairFacetV1.pairBeta.selector), address(second));
        assertEq(_registeredGeneration(base.diamond, namespace), 2);
        assertEq(_legacyRuntimeHash(base.diamond, namespace), bytes32(0));
        _assertRetiredSlotsZero(base.diamond, namespace);
    }

    function testFacetGenerationEventEmitsForInstallButNotSelectorOnlyTopologyAdd() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LivePairFacetV1 facet = new LivePairFacetV1();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        bytes32 namespace = facet.FACET_NAMESPACE();

        vm.recordLogs();
        _execute(
            base.diamond,
            _singleCut(address(facet), IDiamond.FacetCutAction.Add, LivePairFacetV1.pairAlpha.selector),
            init,
            address(facet)
        );
        Vm.Log[] memory installLogs = vm.getRecordedLogs();
        assertEq(_generationEventCount(installLogs, base.diamond), 1);
        assertEq(DiamondCutAccessLiveFacet(base.diamond).facetGeneration(namespace), 1);

        vm.recordLogs();
        _execute(
            base.diamond,
            _singleCut(address(facet), IDiamond.FacetCutAction.Add, LivePairFacetV1.pairBeta.selector),
            init,
            address(facet)
        );
        Vm.Log[] memory topologyOnlyLogs = vm.getRecordedLogs();
        assertEq(_generationEventCount(topologyOnlyLogs, base.diamond), 0);
        assertEq(DiamondCutAccessLiveFacet(base.diamond).facetGeneration(namespace), 1);
    }

    function testLiveCutAllowsMixedAddReplaceWhenNamespaceFullyConverges() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LivePairFacetV1 first = new LivePairFacetV1();
        LivePairFacetV2 second = new LivePairFacetV2();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();

        _execute(
            base.diamond,
            _singleCut(address(first), IDiamond.FacetCutAction.Add, LivePairFacetV1.pairAlpha.selector),
            init,
            address(first)
        );

        IDiamond.FacetCut[] memory mixed = new IDiamond.FacetCut[](2);
        mixed[0] = _singleCut(address(second), IDiamond.FacetCutAction.Replace, LivePairFacetV2.pairAlpha.selector)[0];
        mixed[1] = _singleCut(address(second), IDiamond.FacetCutAction.Add, LivePairFacetV2.pairBeta.selector)[0];
        _execute(base.diamond, mixed, init, address(second));

        assertEq(IDiamondLoupe(base.diamond).facetAddress(LivePairFacetV2.pairAlpha.selector), address(second));
        assertEq(IDiamondLoupe(base.diamond).facetAddress(LivePairFacetV2.pairBeta.selector), address(second));
    }

    function testLiveCutRejectsPartialSameNamespaceTransition() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LivePairFacetV1 first = new LivePairFacetV1();
        LivePairFacetV2 second = new LivePairFacetV2();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        bytes32 namespace = first.FACET_NAMESPACE();

        _execute(base.diamond, _pairCut(address(first), IDiamond.FacetCutAction.Add), init, address(first));

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutPartialFacetNamespaceTransition.selector,
                namespace,
                address(first),
                LivePairFacetV1.pairBeta.selector
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(second), IDiamond.FacetCutAction.Replace, LivePairFacetV2.pairAlpha.selector),
                address(init),
                abi.encodeCall(LiveCutUpgradeInit.init, (address(second)))
            );
    }

    function testLiveCutComparesCandidateAgainstEverySameNamespaceIncumbent() public {
        LiveMultiFacetA first = new LiveMultiFacetA();
        LiveMultiFacetB second = new LiveMultiFacetB(1);
        LiveMultiFacetB candidate = new LiveMultiFacetB(2);
        assertNotEq(address(first).codehash, address(candidate).codehash);
        assertEq(address(second).codehash, address(candidate).codehash);
        bytes32 namespace = first.FACET_NAMESPACE();

        IDiamond.FacetCut[] memory extras = new IDiamond.FacetCut[](2);
        extras[0] = _singleCut(address(first), IDiamond.FacetCutAction.Add, LiveMultiFacetA.multiAlpha.selector)[0];
        extras[1] = _singleCut(address(second), IDiamond.FacetCutAction.Add, LiveMultiFacetB.multiBeta.selector)[0];
        address[] memory registerAtLaunch = new address[](1);
        registerAtLaunch[0] = address(first);
        BaseDeployment memory base = _deployBase(extras, registerAtLaunch);

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = LiveMultiFacetB.multiAlpha.selector;
        selectors[1] = LiveMultiFacetB.multiBeta.selector;
        IDiamond.FacetCut[] memory replacement = new IDiamond.FacetCut[](1);
        replacement[0] = IDiamond.FacetCut({
            facetAddress: address(candidate), action: IDiamond.FacetCutAction.Replace, functionSelectors: selectors
        });
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutFacetRuntimeUnchanged.selector,
                namespace,
                address(second),
                address(candidate),
                address(candidate).codehash
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(replacement, address(init), abi.encodeCall(LiveCutUpgradeInit.init, (address(candidate))));
    }

    function testLiveCutFullRemoveClearsGenerationAndReaddStartsAtOne() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        bytes32 namespace = keccak256("cybergold.shared.test.live.remove-readd");
        LiveMutableFacet first = new LiveMutableFacet(namespace, 1);
        LiveMutableFacet stale = new LiveMutableFacet(namespace, 1);
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        assertEq(address(first).codehash, address(stale).codehash);

        _execute(
            base.diamond,
            _singleCut(address(first), IDiamond.FacetCutAction.Add, LiveMutableFacet.mutableProbe.selector),
            init,
            address(first)
        );
        vm.prank(ADMIN);
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(0), IDiamond.FacetCutAction.Remove, LiveMutableFacet.mutableProbe.selector),
                address(0),
                ""
            );
        assertEq(_registeredGeneration(base.diamond, namespace), 0);

        _execute(
            base.diamond,
            _singleCut(address(stale), IDiamond.FacetCutAction.Add, LiveMutableFacet.mutableProbe.selector),
            init,
            address(stale)
        );
        assertEq(_registeredGeneration(base.diamond, namespace), 1);
        assertEq(IDiamondLoupe(base.diamond).facetAddress(LiveMutableFacet.mutableProbe.selector), address(stale));
    }

    function testLiveCutFailsClosedForMissingAndMalformedIncumbentMetadata() public {
        LiveNoMetadataFacet missing = new LiveNoMetadataFacet();
        _assertInvalidIncumbent(address(missing), LiveNoMetadataFacet.noMetadataProbe.selector);

        LiveMalformedMetadataFacet malformed = new LiveMalformedMetadataFacet();
        _assertInvalidIncumbent(address(malformed), bytes4(0x7badcafe));
    }

    function testLiveCutAllowsRemoveOnlyCleanupOfMalformedIncumbent() public {
        LiveMalformedMetadataFacet malformed = new LiveMalformedMetadataFacet();
        bytes4 selector = bytes4(0x7badcafe);
        IDiamond.FacetCut[] memory extras = _singleCut(address(malformed), IDiamond.FacetCutAction.Add, selector);
        BaseDeployment memory base = _deployBase(extras, new address[](0));

        vm.prank(ADMIN);
        IDiamondCut(base.diamond)
            .diamondCut(_singleCut(address(0), IDiamond.FacetCutAction.Remove, selector), address(0), "");

        assertEq(IDiamondLoupe(base.diamond).facetAddress(selector), address(0));
    }

    function testLiveCutNeverReadsOrWritesRetiredPendingSlots() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LivePairFacetV1 facet = new LivePairFacetV1();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        bytes32 namespace = facet.FACET_NAMESPACE();
        bytes32 facetSentinel = bytes32(uint256(uint160(address(0xFACADE))));
        bytes32 pendingGenerationSentinel = bytes32(uint256(77));
        bytes32 runtimeSentinel = keccak256("retired-pending-runtime");
        vm.store(base.diamond, _registryMapSlot(namespace, 2), facetSentinel);
        vm.store(base.diamond, _registryMapSlot(namespace, 3), pendingGenerationSentinel);
        vm.store(base.diamond, _registryMapSlot(namespace, 4), runtimeSentinel);

        _execute(base.diamond, _pairCut(address(facet), IDiamond.FacetCutAction.Add), init, address(facet));

        assertEq(_registeredGeneration(base.diamond, namespace), 1);
        assertEq(vm.load(base.diamond, _registryMapSlot(namespace, 2)), facetSentinel);
        assertEq(vm.load(base.diamond, _registryMapSlot(namespace, 3)), pendingGenerationSentinel);
        assertEq(vm.load(base.diamond, _registryMapSlot(namespace, 4)), runtimeSentinel);
    }

    function testLiveCutRejectsNestedCutAndEveryMalformedInitializerShape() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LivePairFacetV1 facet = new LivePairFacetV1();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        IDiamond.FacetCut[] memory add =
            _singleCut(address(facet), IDiamond.FacetCutAction.Add, LivePairFacetV1.pairAlpha.selector);
        IDiamond.FacetCut[] memory noCuts = new IDiamond.FacetCut[](0);

        vm.prank(ADMIN);
        vm.expectRevert(LiveValidatedDiamondCut.DiamondCutInitializerCalldataTooShort.selector);
        IDiamondCut(base.diamond).diamondCut(add, address(init), hex"010203");

        vm.prank(ADMIN);
        vm.expectRevert(LiveValidatedDiamondCut.DiamondCutUnexpectedInitializerCalldata.selector);
        IDiamondCut(base.diamond).diamondCut(noCuts, address(0), hex"01");

        vm.prank(ADMIN);
        vm.expectRevert(LiveValidatedDiamondCut.DiamondCutInitializerCalldataTooShort.selector);
        IDiamondCut(base.diamond).diamondCut(noCuts, address(init), hex"010203");

        bytes32 upgraderRole = keccak256("UPGRADER_ROLE");
        vm.prank(ADMIN);
        IAccessControl(base.diamond).grantRole(upgraderRole, base.diamond);
        vm.prank(ADMIN);
        vm.expectRevert(LiveValidatedDiamondCut.DiamondCutReentrancy.selector);
        IDiamondCut(base.diamond)
            .diamondCut(add, address(init), abi.encodeCall(LiveCutUpgradeInit.initAndReenter, (address(facet))));
    }

    function testLiveCutRejectsInvalidCandidateMetadataDuplicateNamespaceAndCoordinatorMutation() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        address noCode = address(0xBEEF);

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(LiveValidatedDiamondCut.DiamondCutCandidateFacetRuntimeMissing.selector, noCode)
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(noCode, IDiamond.FacetCutAction.Add, LivePairFacetV1.pairAlpha.selector),
                address(init),
                abi.encodeCall(LiveCutUpgradeInit.noop, ())
            );

        LiveMutableFacet zeroNamespace = new LiveMutableFacet(bytes32(0), 1);
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutInvalidFacetNamespace.selector, address(zeroNamespace), bytes32(0)
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(zeroNamespace), IDiamond.FacetCutAction.Add, LiveMutableFacet.mutableProbe.selector),
                address(init),
                abi.encodeCall(LiveCutUpgradeInit.noop, ())
            );

        LivePairFacetV1 first = new LivePairFacetV1();
        LivePairFacetV2 second = new LivePairFacetV2();
        bytes32 duplicateNamespace = first.FACET_NAMESPACE();
        IDiamond.FacetCut[] memory duplicate = new IDiamond.FacetCut[](2);
        duplicate[0] = _singleCut(address(first), IDiamond.FacetCutAction.Add, LivePairFacetV1.pairAlpha.selector)[0];
        duplicate[1] = _singleCut(address(second), IDiamond.FacetCutAction.Add, LivePairFacetV2.pairBeta.selector)[0];
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutDuplicateFacetNamespace.selector, duplicateNamespace
            )
        );
        IDiamondCut(base.diamond).diamondCut(duplicate, address(init), abi.encodeCall(LiveCutUpgradeInit.noop, ()));

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutCoordinatorImmutable.selector, IDiamondCut.diamondCut.selector
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(0), IDiamond.FacetCutAction.Remove, IDiamondCut.diamondCut.selector), address(0), ""
            );
    }

    function testLiveCutRejectsZeroGenerationForAnInstalledIncumbent() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LiveAuxiliaryFacet candidate = new LiveAuxiliaryFacet();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        bytes32 incumbentNamespace = base.cut.FACET_NAMESPACE();
        vm.store(base.diamond, _registryMapSlot(incumbentNamespace, 0), bytes32(0));

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutFacetGenerationStateInvalid.selector,
                incumbentNamespace,
                uint64(0),
                true
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(candidate), IDiamond.FacetCutAction.Add, LiveAuxiliaryFacet.auxiliaryProbe.selector),
                address(init),
                abi.encodeCall(LiveCutUpgradeInit.init, (address(candidate)))
            );
    }

    function testLiveCutRejectsCandidateNamespaceOwnedByMultipleIncumbents() public {
        LiveMultiFacetA first = new LiveMultiFacetA();
        LiveMultiFacetB second = new LiveMultiFacetB(1);
        LiveMultiFacetC candidate = new LiveMultiFacetC();
        IDiamond.FacetCut[] memory extras = new IDiamond.FacetCut[](2);
        extras[0] = _singleCut(address(first), IDiamond.FacetCutAction.Add, LiveMultiFacetA.multiAlpha.selector)[0];
        extras[1] = _singleCut(address(second), IDiamond.FacetCutAction.Add, LiveMultiFacetB.multiBeta.selector)[0];
        address[] memory registerAtLaunch = new address[](1);
        registerAtLaunch[0] = address(first);
        BaseDeployment memory base = _deployBase(extras, registerAtLaunch);
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        bytes32 namespace = first.FACET_NAMESPACE();

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(LiveValidatedDiamondCut.DiamondCutDuplicateFacetNamespace.selector, namespace)
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(candidate), IDiamond.FacetCutAction.Add, LiveMultiFacetC.multiGamma.selector),
                address(init),
                abi.encodeCall(LiveCutUpgradeInit.init, (address(candidate)))
            );
    }

    function testLiveCutRejectsStaleGenerationWithoutAnInstalledIncumbent() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LiveAuxiliaryFacet candidate = new LiveAuxiliaryFacet();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        bytes32 namespace = candidate.FACET_NAMESPACE();
        vm.store(base.diamond, _registryMapSlot(namespace, 0), bytes32(uint256(7)));

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutFacetGenerationStateInvalid.selector, namespace, uint64(7), false
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(candidate), IDiamond.FacetCutAction.Add, LiveAuxiliaryFacet.auxiliaryProbe.selector),
                address(init),
                abi.encodeCall(LiveCutUpgradeInit.init, (address(candidate)))
            );
    }

    function testLiveCutRejectsGenerationOverflow() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LivePairFacetV1 incumbent = new LivePairFacetV1();
        LivePairFacetV2 candidate = new LivePairFacetV2();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        bytes32 namespace = incumbent.FACET_NAMESPACE();
        _execute(base.diamond, _pairCut(address(incumbent), IDiamond.FacetCutAction.Add), init, address(incumbent));
        vm.store(base.diamond, _registryMapSlot(namespace, 0), bytes32(uint256(type(uint64).max)));

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(LiveValidatedDiamondCut.DiamondCutFacetGenerationOverflow.selector, namespace)
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _pairCut(address(candidate), IDiamond.FacetCutAction.Replace),
                address(init),
                abi.encodeCall(LiveCutUpgradeInit.init, (address(candidate)))
            );
    }

    function testLiveCutRejectsInitializerMutationOfAnUnchangedIncumbentGeneration() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LiveAuxiliaryFacet candidate = new LiveAuxiliaryFacet();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        bytes32 incumbentNamespace = base.cut.FACET_NAMESPACE();

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutFacetGenerationChangedDuringInitialization.selector,
                incumbentNamespace,
                uint64(1),
                uint64(9)
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(candidate), IDiamond.FacetCutAction.Add, LiveAuxiliaryFacet.auxiliaryProbe.selector),
                address(init),
                abi.encodeCall(LiveCutUpgradeInit.initAndSetRegistryGeneration, (incumbentNamespace, uint64(9)))
            );
    }

    function testLiveCutRejectsZeroGenerationDuringNoOpPostflight() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        bytes32 namespace = base.access.FACET_NAMESPACE();
        vm.store(base.diamond, _registryMapSlot(namespace, 0), bytes32(0));

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutFacetGenerationStateInvalid.selector, namespace, uint64(0), true
            )
        );
        IDiamondCut(base.diamond).diamondCut(new IDiamond.FacetCut[](0), address(0), "");
    }

    function testLiveCutRejectsPreexistingGenerationGetterOwnerMismatch() public {
        LiveSelectorOwnerCorruptorFacet corruptor = new LiveSelectorOwnerCorruptorFacet();
        BaseDeployment memory base =
            _deployWithGenerationExtra(address(corruptor), LiveSelectorOwnerCorruptorFacet.setSelectorOwner.selector);
        LiveSelectorOwnerCorruptorFacet(base.diamond).setSelectorOwner(FACET_GENERATION_SELECTOR, address(corruptor));

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutSelectorOwnerMismatch.selector,
                FACET_GENERATION_SELECTOR,
                address(base.cut),
                address(corruptor)
            )
        );
        IDiamondCut(base.diamond).diamondCut(new IDiamond.FacetCut[](0), address(0), "");
    }

    function testLiveCutAllowsSameNamespaceRemoveThenAddAsNonDirectTransition() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LivePairFacetV1 first = new LivePairFacetV1();
        LivePairFacetV2 second = new LivePairFacetV2();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        _execute(base.diamond, _pairCut(address(first), IDiamond.FacetCutAction.Add), init, address(first));

        IDiamond.FacetCut[] memory transition = new IDiamond.FacetCut[](2);
        transition[0] = _pairCut(address(0), IDiamond.FacetCutAction.Remove)[0];
        transition[1] = _singleCut(address(second), IDiamond.FacetCutAction.Add, LivePairFacetV2.pairGamma.selector)[0];
        _execute(base.diamond, transition, init, address(second));

        assertEq(IDiamondLoupe(base.diamond).facetAddress(LivePairFacetV2.pairAlpha.selector), address(0));
        assertEq(IDiamondLoupe(base.diamond).facetAddress(LivePairFacetV2.pairBeta.selector), address(0));
        assertEq(IDiamondLoupe(base.diamond).facetAddress(LivePairFacetV2.pairGamma.selector), address(second));
    }

    function testLiveCutRejectsMissingIncumbentRuntime() public {
        LivePairFacetV1 missingRuntime = new LivePairFacetV1();
        BaseDeployment memory missingBase =
            _deployWithGenerationExtra(address(missingRuntime), LivePairFacetV1.pairAlpha.selector);
        vm.etch(address(missingRuntime), "");
        LiveAuxiliaryFacet missingCandidate = new LiveAuxiliaryFacet();
        LiveCutUpgradeInit missingInit = new LiveCutUpgradeInit();

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutIncumbentFacetRuntimeMissing.selector, address(missingRuntime)
            )
        );
        IDiamondCut(missingBase.diamond)
            .diamondCut(
                _singleCut(
                    address(missingCandidate), IDiamond.FacetCutAction.Add, LiveAuxiliaryFacet.auxiliaryProbe.selector
                ),
                address(missingInit),
                abi.encodeCall(LiveCutUpgradeInit.init, (address(missingCandidate)))
            );
    }

    function testLiveCutCommitsGenerationAndRejectsInitializerGenerationOrFacetMutation() public {
        BaseDeployment memory noOpBase = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LivePairFacetV1 noOpCandidate = new LivePairFacetV1();
        LiveCutUpgradeInit noOpInit = new LiveCutUpgradeInit();
        vm.prank(ADMIN);
        IDiamondCut(noOpBase.diamond)
            .diamondCut(
                _singleCut(address(noOpCandidate), IDiamond.FacetCutAction.Add, LivePairFacetV1.pairAlpha.selector),
                address(noOpInit),
                abi.encodeCall(LiveCutUpgradeInit.noop, ())
            );
        assertEq(_registeredGeneration(noOpBase.diamond, noOpCandidate.FACET_NAMESPACE()), 1);
        assertEq(
            IDiamondLoupe(noOpBase.diamond).facetAddress(LivePairFacetV1.pairAlpha.selector), address(noOpCandidate)
        );

        BaseDeployment memory generationBase = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        bytes32 generationNamespace = keccak256("cybergold.shared.test.live.registry-generation-change");
        LiveMutableFacet generationCandidate = new LiveMutableFacet(generationNamespace, 1);
        LiveCutUpgradeInit generationInit = new LiveCutUpgradeInit();

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutFacetGenerationChangedDuringInitialization.selector,
                generationNamespace,
                uint64(0),
                uint64(9)
            )
        );
        IDiamondCut(generationBase.diamond)
            .diamondCut(
                _singleCut(
                    address(generationCandidate), IDiamond.FacetCutAction.Add, LiveMutableFacet.mutableProbe.selector
                ),
                address(generationInit),
                abi.encodeCall(LiveCutUpgradeInit.initAndSetRegistryGeneration, (generationNamespace, uint64(9)))
            );
        assertEq(_registeredGeneration(generationBase.diamond, generationNamespace), 0);

        BaseDeployment memory metadataBase = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        bytes32 metadataNamespace = keccak256("cybergold.shared.test.live.metadata-change");
        LiveMutableFacet metadataCandidate = new LiveMutableFacet(metadataNamespace, 1);
        LiveCutUpgradeInit metadataInit = new LiveCutUpgradeInit();

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutFacetNamespaceChanged.selector,
                address(metadataCandidate),
                metadataNamespace,
                keccak256("cybergold.shared.test.live.metadata-change.mutated")
            )
        );
        IDiamondCut(metadataBase.diamond)
            .diamondCut(
                _singleCut(
                    address(metadataCandidate), IDiamond.FacetCutAction.Add, LiveMutableFacet.mutableProbe.selector
                ),
                address(metadataInit),
                abi.encodeCall(
                    LiveCutUpgradeInit.initAndSetFacetNamespace,
                    (address(metadataCandidate), keccak256("cybergold.shared.test.live.metadata-change.mutated"))
                )
            );

        BaseDeployment memory legacyVersionBase = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LiveMutableFacet legacyVersionCandidate =
            new LiveMutableFacet(keccak256("cybergold.shared.test.live.legacy-version-change"), 1);
        vm.prank(ADMIN);
        IDiamondCut(legacyVersionBase.diamond)
            .diamondCut(
                _singleCut(
                    address(legacyVersionCandidate), IDiamond.FacetCutAction.Add, LiveMutableFacet.mutableProbe.selector
                ),
                address(metadataInit),
                abi.encodeCall(LiveCutUpgradeInit.initAndSetFacetVersion, (address(legacyVersionCandidate), uint64(99)))
            );
        assertEq(legacyVersionCandidate.FACET_VERSION(), 99);
        assertEq(_registeredGeneration(legacyVersionBase.diamond, legacyVersionCandidate.FACET_NAMESPACE()), 1);

        BaseDeployment memory runtimeBase = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        bytes32 runtimeNamespace = keccak256("cybergold.shared.test.live.runtime-change");
        LiveMutableFacet runtimeCandidate = new LiveMutableFacet(runtimeNamespace, 1);
        LiveMutableFacetReplacementRuntime replacement = new LiveMutableFacetReplacementRuntime();
        LiveCutUpgradeInit runtimeInit = new LiveCutUpgradeInit();
        bytes32 expectedRuntime = address(runtimeCandidate).codehash;
        bytes32 actualRuntime = address(replacement).codehash;
        assertNotEq(expectedRuntime, actualRuntime);

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutFacetRuntimeChanged.selector,
                runtimeNamespace,
                address(runtimeCandidate),
                expectedRuntime,
                actualRuntime
            )
        );
        IDiamondCut(runtimeBase.diamond)
            .diamondCut(
                _singleCut(
                    address(runtimeCandidate), IDiamond.FacetCutAction.Add, LiveMutableFacet.mutableProbe.selector
                ),
                address(runtimeInit),
                abi.encodeCall(LiveCutUpgradeInit.initAndEtchFacet, (address(runtimeCandidate), address(replacement)))
            );
    }

    function testLiveCutRejectsEveryPostflightSelectorTopologyCorruption() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LivePairFacetV1 candidate = new LivePairFacetV1();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();
        IDiamond.FacetCut[] memory add =
            _singleCut(address(candidate), IDiamond.FacetCutAction.Add, LivePairFacetV1.pairAlpha.selector);
        uint256 initialSelectorCount = _selectorCount(base.diamond);
        bytes4 hiddenSelector = bytes4(0xdeadbeef);

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutSelectorCountMismatch.selector,
                initialSelectorCount + 1,
                initialSelectorCount + 2
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                add,
                address(init),
                abi.encodeCall(LiveCutUpgradeInit.initAndAppendSelector, (address(candidate), hiddenSelector))
            );

        address accessOwner = IDiamondLoupe(base.diamond).facetAddress(IAccessControl.grantRole.selector);
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutSelectorOwnerMismatch.selector,
                IAccessControl.grantRole.selector,
                accessOwner,
                address(candidate)
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                add,
                address(init),
                abi.encodeCall(
                    LiveCutUpgradeInit.initAndSetSelectorOwner,
                    (address(candidate), IAccessControl.grantRole.selector, address(candidate))
                )
            );

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutSelectorOwnerMismatch.selector,
                LivePairFacetV1.pairAlpha.selector,
                address(candidate),
                address(init)
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                add,
                address(init),
                abi.encodeCall(
                    LiveCutUpgradeInit.initAndSetSelectorOwner,
                    (address(candidate), LivePairFacetV1.pairAlpha.selector, address(init))
                )
            );

        uint16 outOfBoundsPosition = type(uint16).max;
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutSelectorEnumerationMismatch.selector,
                LivePairFacetV1.pairAlpha.selector,
                uint256(outOfBoundsPosition),
                bytes4(0)
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                add,
                address(init),
                abi.encodeCall(
                    LiveCutUpgradeInit.initAndSetSelectorPosition,
                    (address(candidate), LivePairFacetV1.pairAlpha.selector, outOfBoundsPosition)
                )
            );

        bytes4 undeclaredSelector = bytes4(0xdecafbad);
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutSelectorEnumerationMismatch.selector,
                LivePairFacetV1.pairAlpha.selector,
                initialSelectorCount,
                undeclaredSelector
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                add,
                address(init),
                abi.encodeCall(
                    LiveCutUpgradeInit.initAndSubstituteEnumerableSelector,
                    (address(candidate), LivePairFacetV1.pairAlpha.selector, undeclaredSelector)
                )
            );
    }

    function testLiveCutRejectsPreexistingDuplicateEnumerableSelector() public {
        LiveTopologyCorruptorFacet corruptor = new LiveTopologyCorruptorFacet();
        bytes4 corruptorSelector = LiveTopologyCorruptorFacet.duplicateEnumerableSelector.selector;
        BaseDeployment memory base = _deployWithGenerationExtra(address(corruptor), corruptorSelector);

        LiveTopologyCorruptorFacet(base.diamond).duplicateEnumerableSelector(corruptorSelector, 0);

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutSelectorOwnerMismatch.selector,
                corruptorSelector,
                address(0),
                address(corruptor)
            )
        );
        IDiamondCut(base.diamond).diamondCut(new IDiamond.FacetCut[](0), address(0), "");
    }

    function testLiveCutRejectsEveryPostflightIncumbentIdentityMutation() public {
        LiveAuxiliaryFacet emptyIncumbent = new LiveAuxiliaryFacet();
        BaseDeployment memory emptyBase =
            _deployWithGenerationExtra(address(emptyIncumbent), LiveAuxiliaryFacet.auxiliaryProbe.selector);
        LivePairFacetV1 emptyCandidate = new LivePairFacetV1();
        LiveCutUpgradeInit emptyInit = new LiveCutUpgradeInit();

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutIncumbentFacetRuntimeMissing.selector, address(emptyIncumbent)
            )
        );
        IDiamondCut(emptyBase.diamond)
            .diamondCut(
                _singleCut(address(emptyCandidate), IDiamond.FacetCutAction.Add, LivePairFacetV1.pairAlpha.selector),
                address(emptyInit),
                abi.encodeCall(
                    LiveCutUpgradeInit.initAndEtchIncumbent,
                    (address(emptyCandidate), address(emptyIncumbent), address(0))
                )
            );

        LiveAuxiliaryFacet malformedIncumbent = new LiveAuxiliaryFacet();
        BaseDeployment memory malformedBase =
            _deployWithGenerationExtra(address(malformedIncumbent), LiveAuxiliaryFacet.auxiliaryProbe.selector);
        LivePairFacetV1 malformedCandidate = new LivePairFacetV1();
        LiveNoMetadataFacet malformedRuntime = new LiveNoMetadataFacet();
        LiveCutUpgradeInit malformedInit = new LiveCutUpgradeInit();

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutIncumbentFacetMetadataInvalid.selector, address(malformedIncumbent)
            )
        );
        IDiamondCut(malformedBase.diamond)
            .diamondCut(
                _singleCut(
                    address(malformedCandidate), IDiamond.FacetCutAction.Add, LivePairFacetV1.pairAlpha.selector
                ),
                address(malformedInit),
                abi.encodeCall(
                    LiveCutUpgradeInit.initAndEtchIncumbent,
                    (address(malformedCandidate), address(malformedIncumbent), address(malformedRuntime))
                )
            );

        LiveAuxiliaryFacet convergingIncumbent = new LiveAuxiliaryFacet();
        BaseDeployment memory convergingBase =
            _deployWithGenerationExtra(address(convergingIncumbent), LiveAuxiliaryFacet.auxiliaryProbe.selector);
        LivePairFacetV1 convergingCandidate = new LivePairFacetV1();
        LivePairFacetV2 convergedRuntime = new LivePairFacetV2();
        LiveCutUpgradeInit convergingInit = new LiveCutUpgradeInit();
        bytes32 convergingNamespace = convergingCandidate.FACET_NAMESPACE();

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutPartialFacetNamespaceTransition.selector,
                convergingNamespace,
                address(convergingIncumbent),
                LiveAuxiliaryFacet.auxiliaryProbe.selector
            )
        );
        IDiamondCut(convergingBase.diamond)
            .diamondCut(
                _singleCut(
                    address(convergingCandidate), IDiamond.FacetCutAction.Add, LivePairFacetV1.pairAlpha.selector
                ),
                address(convergingInit),
                abi.encodeCall(
                    LiveCutUpgradeInit.initAndEtchIncumbent,
                    (address(convergingCandidate), address(convergingIncumbent), address(convergedRuntime))
                )
            );
    }

    function testLiveCutRejectsRecoverySelectorInterfaceAndManifestLoss() public {
        BaseDeployment memory base = _deployBase(new IDiamond.FacetCut[](0), new address[](0));
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, IDiamondLoupe.facets.selector
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(0), IDiamond.FacetCutAction.Remove, IDiamondLoupe.facets.selector), address(0), ""
            );

        bytes4[3] memory baseInterfaces =
            [type(IDiamondCut).interfaceId, type(IDiamondLoupe).interfaceId, type(IERC165).interfaceId];
        IDiamond.FacetCut[] memory noCuts = new IDiamond.FacetCut[](0);
        for (uint256 i; i < baseInterfaces.length; ++i) {
            vm.prank(ADMIN);
            vm.expectRevert(
                abi.encodeWithSelector(
                    LiveValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, IDiamondCut.diamondCut.selector
                )
            );
            IDiamondCut(base.diamond)
                .diamondCut(
                    noCuts,
                    address(init),
                    abi.encodeCall(LiveCutUpgradeInit.setManifestAdvertisement, (baseInterfaces[i], false))
                );
        }

        LivePairFacetV1 manifested = new LivePairFacetV1();
        bytes4 customInterface = bytes4(0x12345678);
        vm.prank(ADMIN);
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(manifested), IDiamond.FacetCutAction.Add, LivePairFacetV1.pairAlpha.selector),
                address(init),
                abi.encodeCall(
                    LiveCutUpgradeInit.initAndRegisterInterface,
                    (address(manifested), customInterface, LivePairFacetV1.pairAlpha.selector)
                )
            );

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, LivePairFacetV1.pairAlpha.selector
            )
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(0), IDiamond.FacetCutAction.Remove, LivePairFacetV1.pairAlpha.selector),
                address(0),
                ""
            );
    }

    function _assertInvalidIncumbent(address incumbent, bytes4 selector) internal {
        IDiamond.FacetCut[] memory extras = _singleCut(incumbent, IDiamond.FacetCutAction.Add, selector);
        BaseDeployment memory base = _deployBase(extras, new address[](0));
        LivePairFacetV1 candidate = new LivePairFacetV1();
        LiveCutUpgradeInit init = new LiveCutUpgradeInit();

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(LiveValidatedDiamondCut.DiamondCutIncumbentFacetMetadataInvalid.selector, incumbent)
        );
        IDiamondCut(base.diamond)
            .diamondCut(
                _singleCut(address(candidate), IDiamond.FacetCutAction.Add, LivePairFacetV1.pairAlpha.selector),
                address(init),
                abi.encodeCall(LiveCutUpgradeInit.init, (address(candidate)))
            );
    }

    function _deployWithGenerationExtra(address facet, bytes4 selector) internal returns (BaseDeployment memory base) {
        IDiamond.FacetCut[] memory extras = _singleCut(facet, IDiamond.FacetCutAction.Add, selector);
        address[] memory versioned = new address[](1);
        versioned[0] = facet;
        return _deployBase(extras, versioned);
    }

    function _deployBase(IDiamond.FacetCut[] memory extraCuts, address[] memory extraGenerationFacets)
        internal
        returns (BaseDeployment memory base)
    {
        base.cut = new DiamondCutAccessLiveFacet();
        base.loupe = new ProtocolDiamondLoupeFacet();
        base.access = new AccessControlFacet();
        LiveCutLaunchInit init = new LiveCutLaunchInit();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](3 + extraCuts.length);
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
        for (uint256 i; i < extraCuts.length; ++i) {
            cuts[3 + i] = extraCuts[i];
        }

        DiamondArgs memory args = DiamondArgs({
            owner: ADMIN,
            init: address(init),
            initCalldata: abi.encodeCall(
                LiveCutLaunchInit.init,
                (ADMIN, address(base.cut), address(base.loupe), address(base.access), extraGenerationFacets)
            )
        });
        base.diamond = address(new ProtocolDiamond(cuts, args));
    }

    function _selectorCount(address diamond) internal view returns (uint256 count) {
        IDiamondLoupe.Facet[] memory facets = IDiamondLoupe(diamond).facets();
        for (uint256 i; i < facets.length; ++i) {
            count += facets[i].functionSelectors.length;
        }
    }

    function _generationEventCount(Vm.Log[] memory logs, address diamond) internal pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == diamond && logs[i].topics.length != 0
                    && logs[i].topics[0] == FACET_GENERATION_UPDATED_TOPIC
            ) ++count;
        }
    }

    function _execute(address diamond, IDiamond.FacetCut[] memory cut, LiveCutUpgradeInit init, address facet)
        internal
    {
        vm.prank(ADMIN);
        IDiamondCut(diamond).diamondCut(cut, address(init), abi.encodeCall(LiveCutUpgradeInit.init, (facet)));
    }

    function _pairCut(address facet, IDiamond.FacetCutAction action)
        internal
        pure
        returns (IDiamond.FacetCut[] memory cut)
    {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = LivePairFacetV1.pairAlpha.selector;
        selectors[1] = LivePairFacetV1.pairBeta.selector;
        cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({facetAddress: facet, action: action, functionSelectors: selectors});
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

    function _registeredGeneration(address diamond, bytes32 namespace) internal view returns (uint64) {
        return uint64(uint256(vm.load(diamond, _registryMapSlot(namespace, 0))));
    }

    function _legacyRuntimeHash(address diamond, bytes32 namespace) internal view returns (bytes32) {
        return vm.load(diamond, _registryMapSlot(namespace, 1));
    }

    function _assertRetiredSlotsZero(address diamond, bytes32 namespace) internal view {
        assertEq(vm.load(diamond, _registryMapSlot(namespace, 2)), bytes32(0));
        assertEq(vm.load(diamond, _registryMapSlot(namespace, 3)), bytes32(0));
        assertEq(vm.load(diamond, _registryMapSlot(namespace, 4)), bytes32(0));
    }

    function _registryMapSlot(bytes32 namespace, uint256 offset) internal pure returns (bytes32) {
        return keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + offset)));
    }
}
