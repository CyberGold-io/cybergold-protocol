// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {FacetVersionRegistry} from "diamond-infra/helpers/FacetVersionRegistry.sol";
import {DiamondCutAccessLiveFacet} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
import {ICoreDiamondCutMigration} from "../src/interfaces/ICoreDiamondCutMigration.sol";
import {CoreDiamondCutMigrationBridgeInit} from "../src/migration/CoreDiamondCutMigrationBridgeInit.sol";
import {CoreDiamondCutMigrationFacet} from "../src/migration/CoreDiamondCutMigrationFacet.sol";
import {CoreFacetRegistryRetirementInit} from "../src/migration/CoreFacetRegistryRetirementInit.sol";
import {LibCoreDiamondCutMigration} from "../src/migration/LibCoreDiamondCutMigration.sol";

contract CoreMigrationCoverageFacet {
    bytes32 public immutable FACET_NAMESPACE;
    uint64 public constant FACET_VERSION = 1;

    constructor(bytes32 namespace) {
        FACET_NAMESPACE = namespace;
    }

    function diamondCut(IDiamond.FacetCut[] calldata, address, bytes calldata) external {}
    function executeCoreDiamondCutMigration(bytes calldata) external {}
    function arbitrarySelector() external pure {}
}

contract CoreMigrationBridgeCoverageHarness is CoreDiamondCutMigrationBridgeInit {
    function seedSelector(bytes4 selector, address owner) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.facetAddressAndSelectorPosition[selector].facetAddress = owner;
        ds.facetAddressAndSelectorPosition[selector].selectorPosition = uint16(ds.selectors.length);
        ds.selectors.push(selector);
    }

    function setSelectorOwner(bytes4 selector, address owner) external {
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress = owner;
    }

    function seedGeneration(bytes32 namespace, uint64 generation) external {
        _facetVersions().versions[namespace] = generation;
    }
}

contract CoreMigrationFacetCoverageHarness is CoreDiamondCutMigrationFacet {
    bool private _roleAuthorized = true;
    uint64 private _getterGeneration;

    function hasRole(bytes32, address) external view returns (bool) {
        return _roleAuthorized;
    }

    function facetGeneration(bytes32) external view returns (uint64) {
        return _getterGeneration;
    }

    function setRoleAuthorized(bool authorized) external {
        _roleAuthorized = authorized;
    }

    function setGetterGeneration(uint64 generation) external {
        _getterGeneration = generation;
    }

    function setActive(bool active) external {
        _upgradeState().active = active;
    }

    function seedSelector(bytes4 selector, address owner, uint16 position) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.facetAddressAndSelectorPosition[selector].facetAddress = owner;
        ds.facetAddressAndSelectorPosition[selector].selectorPosition = position;
        ds.selectors.push(selector);
    }

    function setSelectorAt(uint256 index, bytes4 selector) external {
        LibDiamond.diamondStorage().selectors[index] = selector;
    }

    function setSelectorOwner(bytes4 selector, address owner) external {
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress = owner;
    }

    function setSelectorPosition(bytes4 selector, uint16 position) external {
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].selectorPosition = position;
    }

    function seedGeneration(bytes32 namespace, uint64 generation) external {
        _facetVersions().versions[namespace] = generation;
    }

    function seedLegacy(bytes32 namespace, uint256 offset, bytes32 value) external {
        FacetVersionStore storage registry = _facetVersions();
        if (offset == 1) registry.runtimeCodeHashes[namespace] = value;
        else if (offset == 2) registry.pendingFacets[namespace] = address(uint160(uint256(value)));
        else if (offset == 3) registry.pendingVersions[namespace] = uint64(uint256(value));
        else registry.pendingRuntimeCodeHashes[namespace] = value;
    }

    function requireAuthority(address safe) external view {
        _requireAuthority(safe);
    }

    function requireCoordinator(address coordinator) external view {
        _requireCoordinator(coordinator);
    }

    function requireRuntime(address target, bytes32 expected) external view {
        _requireRuntime(target, expected);
    }

    function requireTemporarySelectorLast() external view {
        _requireTemporarySelectorLast(LibDiamond.diamondStorage());
    }

    function requireCompleteManifest(bytes32[] calldata namespaces, uint64[] calldata generations) external view {
        ICoreDiamondCutMigration.Payload memory payload;
        payload.namespaces = namespaces;
        payload.generations = generations;
        _requireCompleteManifest(payload, LibDiamond.diamondStorage());
    }

    function requirePostflightTopology(
        bytes4[] calldata selectorsBefore,
        address[] calldata ownersBefore,
        address coordinator
    ) external view {
        _requirePostflightTopology(LibDiamond.diamondStorage(), selectorsBefore, ownersBefore, coordinator);
    }

    function requireGenerationGetter(bytes32 namespace, uint64 expected) external view {
        _requireGenerationGetter(namespace, expected);
    }

    function requireRetiredRegistry(
        bytes32[] calldata namespaces,
        uint64[] calldata generations,
        bool coordinatorCommitted
    ) external view {
        ICoreDiamondCutMigration.Payload memory payload;
        payload.namespaces = namespaces;
        payload.generations = generations;
        _requireRetiredRegistry(payload, coordinatorCommitted);
    }

    function armMigrationFor(bytes calldata payloadData, address caller) external {
        bytes32 commitment = keccak256(
            abi.encode(
                keccak256("CYBERGOLD_CORE_DIAMOND_CUT_MIGRATION_V1"),
                block.chainid,
                address(this),
                caller,
                keccak256(payloadData)
            )
        );
        bytes32 slot = keccak256("cybergold.core.diamond-cut-migration.transient.commitment");
        assembly {
            tstore(slot, commitment)
        }
    }
}

contract CoreMigrationRetirementCoverageHarness is CoreFacetRegistryRetirementInit {
    function seedGeneration(bytes32 namespace, uint64 generation) external {
        _facetVersions().versions[namespace] = generation;
    }

    function seedLegacy(bytes32 namespace, uint256 offset, bytes32 value) external {
        FacetVersionStore storage registry = _facetVersions();
        if (offset == 1) registry.runtimeCodeHashes[namespace] = value;
        else if (offset == 2) registry.pendingFacets[namespace] = address(uint160(uint256(value)));
        else if (offset == 3) registry.pendingVersions[namespace] = uint64(uint256(value));
        else registry.pendingRuntimeCodeHashes[namespace] = value;
    }

    function requireRetiredEntries(bytes32[] calldata namespaces, uint64[] calldata generations) external view {
        _requireRetiredEntries(namespaces, generations);
    }

    function requireLegacyRootsZero() external view {
        _requireLegacyRootsZero();
    }
}

contract CoreMigrationRetirementCallHarness is FacetVersionRegistry {
    function seedGeneration(bytes32 namespace, uint64 generation) external {
        _facetVersions().versions[namespace] = generation;
    }

    function execute(address initializer, bytes calldata data) external {
        LibCoreDiamondCutMigration.armRetirement(LibCoreDiamondCutMigration.retirementCommitment(data));
        (bool ok, bytes memory reason) = initializer.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}

contract CoreMigrationLibraryCoverageHarness {
    function seedSelector(bytes4 selector, address owner) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.facetAddressAndSelectorPosition[selector].facetAddress = owner;
        ds.facetAddressAndSelectorPosition[selector].selectorPosition = uint16(ds.selectors.length);
        ds.selectors.push(selector);
    }

    function topologyHashWithout(bytes4 selector) external view returns (bytes32) {
        return LibCoreDiamondCutMigration.topologyHashWithout(selector);
    }

    function facetNamespace(address facet) external view returns (bytes32) {
        return LibCoreDiamondCutMigration.facetNamespace(facet);
    }

    function requireOnlySelector(address facet, bytes4 selector) external view {
        LibCoreDiamondCutMigration.requireOnlySelector(facet, selector);
    }

    function requireLiveCoordinatorSelectors(address facet) external view {
        LibCoreDiamondCutMigration.requireLiveCoordinatorSelectors(facet);
    }

    function consumeRetirement(bytes32 commitment) external {
        LibCoreDiamondCutMigration.consumeRetirement(commitment);
    }
}

contract CoreDiamondCutMigrationCoverageTest is Test {
    bytes32 private constant COORDINATOR_NAMESPACE = keccak256("cybergold.upgrade.coordinator.access");
    bytes32 private constant MIGRATION_NAMESPACE = keccak256("cybergold.core.diamond-cut-migration");
    bytes4 private constant MIGRATION_SELECTOR = bytes4(keccak256("executeCoreDiamondCutMigration(bytes)"));
    bytes4 private constant GENERATION_SELECTOR = bytes4(keccak256("facetGeneration(bytes32)"));
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 private constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");
    bytes32 private constant CANONICAL_LIVE_COORDINATOR_CODE_HASH =
        0x0282a85c0081e7384a120fc9ea2253a5a6b231f8169c07d5939f0540ef0df98f;

    function testBridgeRejectsEveryAuthenticatedInputMismatch() public {
        (
            CoreMigrationBridgeCoverageHarness harness,
            CoreMigrationCoverageFacet oldCoordinator,
            CoreMigrationCoverageFacet newCoordinator,
            CoreMigrationCoverageFacet migration,
            CoreMigrationCoverageFacet retirement,
            ICoreDiamondCutMigration.Payload memory payload
        ) = _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);

        payload.safe = address(0xBEEF);
        vm.expectRevert();
        harness.armCoreDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        payload.namespaces = new bytes32[](0);
        payload.generations = new uint64[](0);
        vm.expectRevert();
        harness.armCoreDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        vm.expectRevert();
        harness.armCoreDiamondCutMigration(address(retirement), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        payload.oldCoordinator = address(newCoordinator);
        vm.expectRevert();
        harness.armCoreDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        payload.newCoordinatorCodeHash = bytes32(0);
        vm.expectRevert();
        harness.armCoreDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(keccak256("wrong.coordinator"), MIGRATION_NAMESPACE);
        vm.expectRevert();
        harness.armCoreDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        harness.setSelectorOwner(MIGRATION_SELECTOR, address(retirement));
        vm.expectRevert();
        harness.armCoreDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, bytes32(0));
        vm.expectRevert();
        harness.armCoreDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        harness.seedGeneration(COORDINATOR_NAMESPACE, 2);
        vm.expectRevert();
        harness.armCoreDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        payload.baselineTopologyHash = bytes32(uint256(payload.baselineTopologyHash) ^ 1);
        vm.expectRevert();
        harness.armCoreDiamondCutMigration(address(migration), abi.encode(payload));
    }

    function testMigrationPrimitiveGuardsAndTopLevelEarlyBranches() public {
        CoreMigrationFacetCoverageHarness harness = new CoreMigrationFacetCoverageHarness();
        vm.expectRevert();
        harness.requireAuthority(address(0xBEEF));

        harness.setRoleAuthorized(false);
        vm.expectRevert();
        harness.requireAuthority(address(this));

        CoreMigrationCoverageFacet wrongNamespace = new CoreMigrationCoverageFacet(keccak256("wrong.namespace"));
        vm.expectRevert();
        harness.requireCoordinator(address(wrongNamespace));

        vm.expectRevert();
        harness.requireRuntime(address(0), bytes32(0));

        harness.setRoleAuthorized(true);
        ICoreDiamondCutMigration.Payload memory payload;
        payload.safe = address(this);
        bytes memory payloadData = abi.encode(payload);
        harness.armMigrationFor(payloadData, address(this));
        harness.setActive(true);
        vm.expectRevert();
        harness.executeCoreDiamondCutMigration(payloadData);

        harness = new CoreMigrationFacetCoverageHarness();
        payload.safe = address(this);
        payload.migrationFacet = address(0xCAFE);
        payloadData = abi.encode(payload);
        harness.armMigrationFor(payloadData, address(this));
        vm.expectRevert();
        harness.executeCoreDiamondCutMigration(payloadData);
    }

    function testTopLevelRejectsChangedCoordinatorOwnerAndTopology() public {
        (CoreMigrationFacetCoverageHarness harness, bytes memory payloadData) = _topLevelFixture(true, false);
        vm.expectRevert();
        harness.executeCoreDiamondCutMigration(payloadData);

        (harness, payloadData) = _topLevelFixture(false, true);
        vm.expectRevert();
        harness.executeCoreDiamondCutMigration(payloadData);
    }

    function testManifestValidationRejectsEveryDefensiveStateMismatch() public {
        CoreMigrationFacetCoverageHarness harness = new CoreMigrationFacetCoverageHarness();
        vm.expectRevert();
        harness.requireCompleteManifest(new bytes32[](0), new uint64[](0));

        bytes32[] memory namespaces = new bytes32[](1);
        uint64[] memory generations = new uint64[](0);
        namespaces[0] = bytes32(uint256(1));
        vm.expectRevert();
        harness.requireCompleteManifest(namespaces, generations);

        harness = new CoreMigrationFacetCoverageHarness();
        namespaces = new bytes32[](2);
        generations = new uint64[](2);
        namespaces[0] = bytes32(uint256(2));
        namespaces[1] = bytes32(uint256(1));
        vm.expectRevert();
        harness.requireCompleteManifest(namespaces, generations);

        harness = new CoreMigrationFacetCoverageHarness();
        CoreMigrationCoverageFacet zeroNamespace = new CoreMigrationCoverageFacet(bytes32(0));
        harness.seedSelector(bytes4(0x11111111), address(zeroNamespace), 0);
        namespaces = new bytes32[](1);
        generations = new uint64[](1);
        vm.expectRevert();
        harness.requireCompleteManifest(namespaces, generations);

        harness = new CoreMigrationFacetCoverageHarness();
        bytes32 duplicateNamespace = bytes32(uint256(3));
        CoreMigrationCoverageFacet first = new CoreMigrationCoverageFacet(duplicateNamespace);
        CoreMigrationCoverageFacet second = new CoreMigrationCoverageFacet(duplicateNamespace);
        harness.seedSelector(bytes4(0x11111111), address(first), 0);
        harness.seedSelector(bytes4(0x22222222), address(second), 1);
        harness.seedGeneration(duplicateNamespace, 1);
        namespaces[0] = duplicateNamespace;
        generations[0] = 1;
        vm.expectRevert();
        harness.requireCompleteManifest(namespaces, generations);

        harness = new CoreMigrationFacetCoverageHarness();
        bytes32 generationNamespace = bytes32(uint256(4));
        CoreMigrationCoverageFacet generationFacet = new CoreMigrationCoverageFacet(generationNamespace);
        harness.seedSelector(bytes4(0x11111111), address(generationFacet), 0);
        harness.seedGeneration(generationNamespace, 2);
        namespaces[0] = generationNamespace;
        generations[0] = 1;
        vm.expectRevert();
        harness.requireCompleteManifest(namespaces, generations);

        harness = new CoreMigrationFacetCoverageHarness();
        bytes32 installedNamespace = bytes32(uint256(5));
        CoreMigrationCoverageFacet installed = new CoreMigrationCoverageFacet(installedNamespace);
        harness.seedSelector(bytes4(0x11111111), address(installed), 0);
        harness.seedGeneration(installedNamespace, 1);
        namespaces = new bytes32[](2);
        generations = new uint64[](2);
        namespaces[0] = installedNamespace;
        namespaces[1] = bytes32(uint256(6));
        generations[0] = 1;
        generations[1] = 1;
        vm.expectRevert();
        harness.requireCompleteManifest(namespaces, generations);

        harness = new CoreMigrationFacetCoverageHarness();
        installedNamespace = bytes32(uint256(7));
        installed = new CoreMigrationCoverageFacet(installedNamespace);
        harness.seedSelector(bytes4(0x11111111), address(installed), 0);
        namespaces = new bytes32[](1);
        generations = new uint64[](1);
        namespaces[0] = bytes32(uint256(8));
        generations[0] = 1;
        vm.expectRevert();
        harness.requireCompleteManifest(namespaces, generations);
    }

    function testTemporarySelectorAndEveryPostflightTopologyGuard() public {
        CoreMigrationFacetCoverageHarness harness = new CoreMigrationFacetCoverageHarness();
        harness.seedSelector(MIGRATION_SELECTOR, address(harness), 1);
        vm.expectRevert();
        harness.requireTemporarySelectorLast();

        bytes4 baselineSelector = bytes4(0x11111111);
        address baselineOwner = address(0xA11CE);
        address coordinator = address(0xC001);
        bytes4[] memory beforeSelectors = new bytes4[](1);
        address[] memory beforeOwners = new address[](1);
        beforeSelectors[0] = MIGRATION_SELECTOR;
        beforeOwners[0] = address(harness);
        harness = new CoreMigrationFacetCoverageHarness();
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);

        beforeSelectors = new bytes4[](2);
        beforeOwners = new address[](2);
        beforeSelectors[0] = baselineSelector;
        beforeSelectors[1] = MIGRATION_SELECTOR;
        beforeOwners[0] = baselineOwner;
        beforeOwners[1] = address(harness);

        harness = _postflightHarness(bytes4(0x22222222), baselineOwner, coordinator);
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);

        harness = _postflightHarness(baselineSelector, address(0xBAD), coordinator);
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);

        harness = _postflightHarness(baselineSelector, baselineOwner, coordinator);
        harness.setSelectorPosition(baselineSelector, 1);
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);

        beforeSelectors = new bytes4[](1);
        beforeOwners = new address[](1);
        beforeSelectors[0] = MIGRATION_SELECTOR;
        beforeOwners[0] = address(harness);
        harness = new CoreMigrationFacetCoverageHarness();
        harness.seedSelector(baselineSelector, coordinator, 0);
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);

        harness = new CoreMigrationFacetCoverageHarness();
        harness.seedSelector(GENERATION_SELECTOR, address(0xBAD), 0);
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);

        harness = new CoreMigrationFacetCoverageHarness();
        harness.seedSelector(GENERATION_SELECTOR, coordinator, 1);
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);

        harness = new CoreMigrationFacetCoverageHarness();
        harness.seedSelector(GENERATION_SELECTOR, coordinator, 0);
        harness.setSelectorOwner(MIGRATION_SELECTOR, address(0xBAD));
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);
    }

    function testGenerationGetterAndRetiredRegistryDefensiveGuards() public {
        CoreMigrationFacetCoverageHarness harness = new CoreMigrationFacetCoverageHarness();
        harness.setGetterGeneration(1);
        vm.expectRevert();
        harness.requireGenerationGetter(bytes32(uint256(1)), 2);

        bytes32[] memory namespaces = new bytes32[](1);
        uint64[] memory generations = new uint64[](1);
        bytes32 namespace = bytes32(uint256(11));
        namespaces[0] = namespace;
        generations[0] = 1;

        harness = new CoreMigrationFacetCoverageHarness();
        vm.expectRevert();
        harness.requireRetiredRegistry(namespaces, generations, false);

        for (uint256 offset = 1; offset <= 4; ++offset) {
            harness = new CoreMigrationFacetCoverageHarness();
            harness.seedGeneration(namespace, 1);
            harness.seedLegacy(namespace, offset, bytes32(uint256(1)));
            vm.expectRevert();
            harness.requireRetiredRegistry(namespaces, generations, false);
        }

        harness = new CoreMigrationFacetCoverageHarness();
        harness.seedGeneration(namespace, 1);
        vm.store(address(harness), bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 1), bytes32(uint256(1)));
        vm.expectRevert();
        harness.requireRetiredRegistry(namespaces, generations, false);

        harness = new CoreMigrationFacetCoverageHarness();
        harness.seedGeneration(namespace, 1);
        bytes32 temporarySelectorSlot = keccak256(abi.encode(MIGRATION_SELECTOR, DIAMOND_STORAGE_POSITION));
        vm.store(address(harness), temporarySelectorSlot, bytes32(uint256(1)));
        vm.expectRevert();
        harness.requireRetiredRegistry(namespaces, generations, false);
    }

    function testRetirementInitializerAndVerificationRejectEveryMismatch() public {
        CoreFacetRegistryRetirementInit initializer = new CoreFacetRegistryRetirementInit();
        CoreMigrationRetirementCallHarness caller = new CoreMigrationRetirementCallHarness();
        bytes32[] memory namespaces = new bytes32[](0);
        uint64[] memory generations = new uint64[](0);
        bytes memory data =
            abi.encodeCall(CoreFacetRegistryRetirementInit.retireCoreLegacyFacetRegistry, (namespaces, generations));
        vm.expectRevert();
        caller.execute(address(initializer), data);

        caller = new CoreMigrationRetirementCallHarness();
        namespaces = new bytes32[](2);
        generations = new uint64[](2);
        namespaces[0] = bytes32(uint256(2));
        namespaces[1] = bytes32(uint256(1));
        generations[0] = 1;
        generations[1] = 1;
        caller.seedGeneration(namespaces[0], 1);
        caller.seedGeneration(namespaces[1], 1);
        data = abi.encodeCall(CoreFacetRegistryRetirementInit.retireCoreLegacyFacetRegistry, (namespaces, generations));
        vm.expectRevert();
        caller.execute(address(initializer), data);

        caller = new CoreMigrationRetirementCallHarness();
        namespaces = new bytes32[](1);
        generations = new uint64[](1);
        namespaces[0] = bytes32(uint256(3));
        generations[0] = 1;
        caller.seedGeneration(namespaces[0], 2);
        data = abi.encodeCall(CoreFacetRegistryRetirementInit.retireCoreLegacyFacetRegistry, (namespaces, generations));
        vm.expectRevert();
        caller.execute(address(initializer), data);

        CoreMigrationRetirementCoverageHarness verifier = new CoreMigrationRetirementCoverageHarness();
        namespaces[0] = bytes32(uint256(4));
        verifier.seedGeneration(namespaces[0], 2);
        vm.expectRevert();
        verifier.requireRetiredEntries(namespaces, generations);

        for (uint256 offset = 1; offset <= 4; ++offset) {
            verifier = new CoreMigrationRetirementCoverageHarness();
            verifier.seedGeneration(namespaces[0], 1);
            verifier.seedLegacy(namespaces[0], offset, bytes32(uint256(1)));
            vm.expectRevert();
            verifier.requireRetiredEntries(namespaces, generations);
        }

        verifier = new CoreMigrationRetirementCoverageHarness();
        vm.store(address(verifier), bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 1), bytes32(uint256(1)));
        vm.expectRevert();
        verifier.requireLegacyRootsZero();
    }

    function testLibraryRejectsEveryMalformedTopologyAndCommitment() public {
        CoreMigrationLibraryCoverageHarness harness = new CoreMigrationLibraryCoverageHarness();
        vm.expectRevert();
        harness.consumeRetirement(bytes32(uint256(1)));

        bytes4 selector = bytes4(0x11111111);
        harness = new CoreMigrationLibraryCoverageHarness();
        harness.seedSelector(selector, address(0xA11CE));
        harness.seedSelector(selector, address(0xA11CE));
        vm.expectRevert();
        harness.topologyHashWithout(selector);

        harness = new CoreMigrationLibraryCoverageHarness();
        vm.expectRevert();
        harness.facetNamespace(address(0xBEEF));

        CoreMigrationCoverageFacet facet = new CoreMigrationCoverageFacet(bytes32(uint256(1)));
        harness = new CoreMigrationLibraryCoverageHarness();
        harness.seedSelector(bytes4(0x22222222), address(facet));
        vm.expectRevert();
        harness.requireOnlySelector(address(facet), selector);

        harness = new CoreMigrationLibraryCoverageHarness();
        vm.expectRevert();
        harness.requireOnlySelector(address(facet), selector);

        harness = new CoreMigrationLibraryCoverageHarness();
        harness.seedSelector(IDiamondCut.diamondCut.selector, address(facet));
        harness.seedSelector(GENERATION_SELECTOR, address(facet));
        harness.seedSelector(bytes4(0x33333333), address(facet));
        vm.expectRevert();
        harness.requireLiveCoordinatorSelectors(address(facet));

        harness = new CoreMigrationLibraryCoverageHarness();
        harness.seedSelector(IDiamondCut.diamondCut.selector, address(facet));
        vm.expectRevert();
        harness.requireLiveCoordinatorSelectors(address(facet));
    }

    function _bridgeFixture(bytes32 newCoordinatorNamespace, bytes32 migrationNamespace)
        private
        returns (
            CoreMigrationBridgeCoverageHarness harness,
            CoreMigrationCoverageFacet oldCoordinator,
            CoreMigrationCoverageFacet newCoordinator,
            CoreMigrationCoverageFacet migration,
            CoreMigrationCoverageFacet retirement,
            ICoreDiamondCutMigration.Payload memory payload
        )
    {
        harness = new CoreMigrationBridgeCoverageHarness();
        oldCoordinator = new CoreMigrationCoverageFacet(COORDINATOR_NAMESPACE);
        newCoordinator = new CoreMigrationCoverageFacet(newCoordinatorNamespace);
        migration = new CoreMigrationCoverageFacet(migrationNamespace);
        retirement = new CoreMigrationCoverageFacet(bytes32(uint256(99)));
        harness.seedSelector(IDiamondCut.diamondCut.selector, address(oldCoordinator));
        harness.seedSelector(MIGRATION_SELECTOR, address(migration));
        harness.seedGeneration(COORDINATOR_NAMESPACE, 1);

        bytes4[] memory baselineSelectors = new bytes4[](1);
        address[] memory baselineOwners = new address[](1);
        baselineSelectors[0] = IDiamondCut.diamondCut.selector;
        baselineOwners[0] = address(oldCoordinator);
        bytes32[] memory namespaces = new bytes32[](2);
        uint64[] memory generations = new uint64[](2);
        namespaces[0] = COORDINATOR_NAMESPACE < migrationNamespace ? COORDINATOR_NAMESPACE : migrationNamespace;
        namespaces[1] = COORDINATOR_NAMESPACE < migrationNamespace ? migrationNamespace : COORDINATOR_NAMESPACE;
        generations[0] = 1;
        generations[1] = 1;
        payload = ICoreDiamondCutMigration.Payload({
            safe: address(this),
            oldCoordinator: address(oldCoordinator),
            oldCoordinatorCodeHash: address(oldCoordinator).codehash,
            newCoordinator: address(newCoordinator),
            newCoordinatorCodeHash: address(newCoordinator).codehash,
            migrationFacet: address(migration),
            migrationFacetCodeHash: address(migration).codehash,
            retirementInitializer: address(retirement),
            retirementInitializerCodeHash: address(retirement).codehash,
            baselineTopologyHash: keccak256(abi.encode(baselineSelectors, baselineOwners)),
            namespaces: namespaces,
            generations: generations
        });
    }

    function _postflightHarness(bytes4 baselineSelector, address baselineOwner, address coordinator)
        private
        returns (CoreMigrationFacetCoverageHarness harness)
    {
        harness = new CoreMigrationFacetCoverageHarness();
        harness.seedSelector(baselineSelector, baselineOwner, 0);
        harness.seedSelector(GENERATION_SELECTOR, coordinator, 1);
    }

    function _topLevelFixture(bool wrongOwner, bool wrongTopology)
        private
        returns (CoreMigrationFacetCoverageHarness harness, bytes memory payloadData)
    {
        harness = new CoreMigrationFacetCoverageHarness();
        CoreMigrationCoverageFacet oldCoordinator = new CoreMigrationCoverageFacet(COORDINATOR_NAMESPACE);
        CoreMigrationCoverageFacet migration = new CoreMigrationCoverageFacet(MIGRATION_NAMESPACE);
        CoreMigrationCoverageFacet retirement = new CoreMigrationCoverageFacet(bytes32(uint256(99)));
        DiamondCutAccessLiveFacet newCoordinator = _deployCanonicalCoordinator();

        harness.seedSelector(
            IDiamondCut.diamondCut.selector, wrongOwner ? address(retirement) : address(oldCoordinator), 0
        );
        harness.seedSelector(MIGRATION_SELECTOR, address(migration), 1);
        harness.seedGeneration(COORDINATOR_NAMESPACE, 1);
        harness.seedGeneration(MIGRATION_NAMESPACE, 1);

        bytes4[] memory baselineSelectors = new bytes4[](1);
        address[] memory baselineOwners = new address[](1);
        baselineSelectors[0] = IDiamondCut.diamondCut.selector;
        baselineOwners[0] = address(oldCoordinator);
        bytes32 topologyHash = keccak256(abi.encode(baselineSelectors, baselineOwners));
        if (wrongTopology) topologyHash = bytes32(uint256(topologyHash) ^ 1);

        bytes32[] memory namespaces = new bytes32[](2);
        uint64[] memory generations = new uint64[](2);
        namespaces[0] = COORDINATOR_NAMESPACE < MIGRATION_NAMESPACE ? COORDINATOR_NAMESPACE : MIGRATION_NAMESPACE;
        namespaces[1] = COORDINATOR_NAMESPACE < MIGRATION_NAMESPACE ? MIGRATION_NAMESPACE : COORDINATOR_NAMESPACE;
        generations[0] = 1;
        generations[1] = 1;
        ICoreDiamondCutMigration.Payload memory payload = ICoreDiamondCutMigration.Payload({
            safe: address(this),
            oldCoordinator: address(oldCoordinator),
            oldCoordinatorCodeHash: address(oldCoordinator).codehash,
            newCoordinator: address(newCoordinator),
            newCoordinatorCodeHash: address(newCoordinator).codehash,
            migrationFacet: address(migration),
            migrationFacetCodeHash: address(migration).codehash,
            retirementInitializer: address(retirement),
            retirementInitializerCodeHash: address(retirement).codehash,
            baselineTopologyHash: topologyHash,
            namespaces: namespaces,
            generations: generations
        });
        payloadData = abi.encode(payload);
        harness.armMigrationFor(payloadData, address(this));
    }

    function _deployCanonicalCoordinator() private returns (DiamondCutAccessLiveFacet coordinator) {
        coordinator = new DiamondCutAccessLiveFacet();
        // Preserve the exact deployed historical runtime even when current coordinator behavior changes.
        bytes memory runtime = vm.parseBytes(
            vm.trim(vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/deployed-core-live-coordinator.hex")))
        );
        vm.etch(address(coordinator), runtime);
        assertEq(address(coordinator).codehash, CANONICAL_LIVE_COORDINATOR_CODE_HASH);
    }
}
