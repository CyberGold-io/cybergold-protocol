// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {DiamondCutAccessLiveFacet} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {ICoreDiamondCutMigration} from "../src/interfaces/ICoreDiamondCutMigration.sol";
import {CoreDiamondCutMigrationBridgeInit} from "../src/migration/CoreDiamondCutMigrationBridgeInit.sol";
import {CoreDiamondCutMigrationFacet} from "../src/migration/CoreDiamondCutMigrationFacet.sol";
import {CoreFacetRegistryRetirementInit} from "../src/migration/CoreFacetRegistryRetirementInit.sol";
import {LibCoreDiamondCutMigration} from "../src/migration/LibCoreDiamondCutMigration.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";

contract CoreMigrationAtomicExecutor {
    function execute(address diamond, bytes calldata first, bytes calldata second) external {
        _call(diamond, first);
        _call(diamond, second);
    }

    function executeOne(address diamond, bytes calldata data) external {
        _call(diamond, data);
    }

    function _call(address target, bytes calldata data) private {
        (bool ok, bytes memory err) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }
    }
}

/// @notice Faithful Safe execution envelope for the reviewed outer DELEGATECALL.
contract CoreMigrationSafeHarness {
    enum Operation {
        Call,
        DelegateCall
    }

    function execTransaction(address to, uint256 value, bytes calldata data, Operation operation)
        external
        returns (bool success)
    {
        bytes memory returndata;
        if (operation == Operation.DelegateCall) {
            (success, returndata) = to.delegatecall(data);
        } else {
            (success, returndata) = to.call{value: value}(data);
        }
        if (!success) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }
}

/// @notice Test implementation of MultiSendCallOnly's packed, CALL-only transaction semantics.
contract CoreMigrationMultiSendCallOnly {
    error InvalidOperation(uint8 operation);
    error MalformedTransactions();

    function multiSend(bytes memory transactions) external payable {
        uint256 cursor;
        while (cursor < transactions.length) {
            if (transactions.length - cursor < 85) revert MalformedTransactions();
            uint8 operation = uint8(transactions[cursor]);
            if (operation != 0) revert InvalidOperation(operation);

            address target;
            uint256 value;
            uint256 dataLength;
            assembly {
                let body := add(transactions, 0x20)
                target := shr(96, mload(add(body, add(cursor, 1))))
                value := mload(add(body, add(cursor, 21)))
                dataLength := mload(add(body, add(cursor, 53)))
            }
            cursor += 85;
            if (dataLength > transactions.length - cursor) revert MalformedTransactions();
            bytes memory data = new bytes(dataLength);
            for (uint256 i; i < dataLength; ++i) {
                data[i] = transactions[cursor + i];
            }
            cursor += dataLength;
            (bool ok, bytes memory returndata) = target.call{value: value}(data);
            if (!ok) {
                assembly {
                    revert(add(returndata, 0x20), mload(returndata))
                }
            }
        }
    }
}

contract CoreMigrationTopologyHarness {
    function topologyHashWithout(bytes4 selector) external view returns (bytes32) {
        return LibCoreDiamondCutMigration.topologyHashWithout(selector);
    }
}

contract CoreMigrationFakeCoordinator {
    uint64 public constant FACET_VERSION = 1;
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.upgrade.coordinator.access");

    function diamondCut(IDiamond.FacetCut[] calldata, address, bytes calldata) external {}
}

contract CoreMigrationPostFacet {
    uint64 public constant FACET_VERSION = 1;
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.core.test.post-migration");

    function postMigrationPing() external pure returns (uint256) {
        return 1;
    }
}

contract CoreMigrationNoopInit {
    function init() external pure {}
}

contract CoreDiamondCutMigrationTest is Test {
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 private constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");
    bytes32 private constant COORDINATOR_NAMESPACE = keccak256("cybergold.upgrade.coordinator.access");
    bytes32 private constant CANONICAL_LIVE_COORDINATOR_CODE_HASH =
        0x0282a85c0081e7384a120fc9ea2253a5a6b231f8169c07d5939f0540ef0df98f;
    bytes4 private constant MIGRATION_SELECTOR = bytes4(keccak256("executeCoreDiamondCutMigration(bytes)"));
    bytes4 private constant GENERATION_SELECTOR = bytes4(keccak256("facetGeneration(bytes32)"));
    bytes32 private constant DIAMOND_CUT_TOPIC = keccak256("DiamondCut((address,uint8,bytes4[])[],address,bytes)");

    address private diamond;
    address private launchSafe;
    CoreMigrationAtomicExecutor private executor;
    CoreMigrationSafeHarness private safeExecutor;
    CoreMigrationMultiSendCallOnly private multiSend;
    DiamondCutAccessLiveFacet private liveCoordinator;
    CoreDiamondCutMigrationFacet private migrationFacet;
    CoreDiamondCutMigrationBridgeInit private bridgeInit;
    CoreFacetRegistryRetirementInit private retirementInit;

    function setUp() public {
        vm.chainId(1);
        DeploymentTypes.DeployArtifacts memory deployed = _deployLegacyCore();
        diamond = address(deployed.diamond);
        launchSafe = PausableFacet(diamond).safeWallet();
        executor = new CoreMigrationAtomicExecutor();
        safeExecutor = new CoreMigrationSafeHarness();
        multiSend = new CoreMigrationMultiSendCallOnly();
        liveCoordinator = _deployCanonicalLiveCoordinator();
        migrationFacet = new CoreDiamondCutMigrationFacet();
        bridgeInit = new CoreDiamondCutMigrationBridgeInit();
        retirementInit = new CoreFacetRegistryRetirementInit();

        bytes32 upgraderRole = deployed.facets.access.upgraderRole();
        vm.prank(launchSafe);
        IAccessControl(diamond).grantRole(upgraderRole, address(executor));
        vm.prank(launchSafe);
        IAccessControl(diamond).grantRole(upgraderRole, address(safeExecutor));
    }

    function testAtomicMigrationInstallsExactSharedRuntimeAndRetiresLegacyRegistry() public {
        (ICoreDiamondCutMigration.Payload memory payload, bytes memory payloadData) = _payload(address(liveCoordinator));
        (bytes memory stageA, bytes memory stageB) = _stages(payloadData);
        (bytes4[] memory selectorsBefore, address[] memory ownersBefore) = _orderedTopology();

        vm.recordLogs();
        executor.execute(diamond, stageA, stageB);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        assertEq(loupe.facetAddress(IDiamondCut.diamondCut.selector), address(liveCoordinator));
        assertEq(loupe.facetAddress(GENERATION_SELECTOR), address(liveCoordinator));
        assertEq(loupe.facetAddress(MIGRATION_SELECTOR), address(0));
        assertEq(_rawSelectorWord(MIGRATION_SELECTOR), bytes32(0));
        assertEq(loupe.facetAddress(IDiamondCut.diamondCut.selector).codehash, CANONICAL_LIVE_COORDINATOR_CODE_HASH);
        assertEq(liveCoordinator.FACET_NAMESPACE(), COORDINATOR_NAMESPACE, "shared coordinator namespace changed");
        _assertFinalTopology(selectorsBefore, ownersBefore, address(liveCoordinator));
        _assertRetiredManifest(payload);
        assertEq(_registryGeneration(COORDINATOR_NAMESPACE), 2, "Core coordinator generation");
        assertEq(_registryGeneration(migrationFacet.FACET_NAMESPACE()), 0, "temporary generation scar");
        assertEq(DiamondCutAccessLiveFacet(diamond).facetGeneration(COORDINATOR_NAMESPACE), 2);
        assertEq(DiamondCutAccessLiveFacet(diamond).facetGeneration(migrationFacet.FACET_NAMESPACE()), 0);
        _assertStageBDiamondCutEvent(logs, payload);

        CoreMigrationPostFacet postFacet = new CoreMigrationPostFacet();
        CoreMigrationNoopInit init = new CoreMigrationNoopInit();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = CoreMigrationPostFacet.postMigrationPing.selector;
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(postFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: selectors
        });
        bytes memory ordinaryUpgrade = abi.encodeCall(
            IDiamondCut.diamondCut, (cut, address(init), abi.encodeCall(CoreMigrationNoopInit.init, ()))
        );
        executor.executeOne(diamond, ordinaryUpgrade);
        assertEq(loupe.facetAddress(selectors[0]), address(postFacet));
        assertEq(_registryGeneration(postFacet.FACET_NAMESPACE()), 1);
        assertEq(_legacyWord(postFacet.FACET_NAMESPACE(), 1), bytes32(0));
    }

    function testSafeDelegatecallMultiSendExecutesExactTwoCallAtomicEnvelope() public {
        (ICoreDiamondCutMigration.Payload memory payload, bytes memory payloadData) =
            _payloadFor(address(liveCoordinator), address(safeExecutor));
        (bytes memory stageA, bytes memory stageB) = _stages(payloadData);
        bytes memory transactions = bytes.concat(
            abi.encodePacked(uint8(0), diamond, uint256(0), uint256(stageA.length), stageA),
            abi.encodePacked(uint8(0), diamond, uint256(0), uint256(stageB.length), stageB)
        );

        bool success = safeExecutor.execTransaction(
            address(multiSend),
            0,
            abi.encodeCall(CoreMigrationMultiSendCallOnly.multiSend, (transactions)),
            CoreMigrationSafeHarness.Operation.DelegateCall
        );

        assertTrue(success);
        assertEq(IDiamondLoupe(diamond).facetAddress(IDiamondCut.diamondCut.selector), address(liveCoordinator));
        assertEq(IDiamondLoupe(diamond).facetAddress(GENERATION_SELECTOR), address(liveCoordinator));
        assertEq(IDiamondLoupe(diamond).facetAddress(MIGRATION_SELECTOR), address(0));
        assertEq(_rawSelectorWord(MIGRATION_SELECTOR), bytes32(0));
        assertEq(_registryGeneration(COORDINATOR_NAMESPACE), 2);
        assertEq(_registryGeneration(migrationFacet.FACET_NAMESPACE()), 0);
        assertEq(DiamondCutAccessLiveFacet(diamond).facetGeneration(COORDINATOR_NAMESPACE), 2);
        assertEq(DiamondCutAccessLiveFacet(diamond).facetGeneration(migrationFacet.FACET_NAMESPACE()), 0);
        _assertRetiredManifest(payload);
    }

    function testLateRetirementFailureRollsBackBothStagesAndEveryMutation() public {
        (, bytes memory payloadData) = _payload(address(liveCoordinator));
        (bytes memory stageA, bytes memory stageB) = _stages(payloadData);
        address oldCoordinator = IDiamondLoupe(diamond).facetAddress(IDiamondCut.diamondCut.selector);
        bytes32 rootSlot = bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 1);
        bytes32 sentinel = keccak256("late-retirement-root-failure");
        vm.store(diamond, rootSlot, sentinel);

        vm.expectRevert();
        executor.execute(diamond, stageA, stageB);

        assertEq(IDiamondLoupe(diamond).facetAddress(IDiamondCut.diamondCut.selector), oldCoordinator);
        assertEq(IDiamondLoupe(diamond).facetAddress(MIGRATION_SELECTOR), address(0));
        assertEq(_rawSelectorWord(MIGRATION_SELECTOR), bytes32(0));
        assertEq(_registryGeneration(COORDINATOR_NAMESPACE), 1);
        assertEq(_registryGeneration(migrationFacet.FACET_NAMESPACE()), 0);
        assertEq(vm.load(diamond, rootSlot), sentinel);
    }

    function testRawInterleavedSelectorOrderIsBoundAndPreserved() public {
        _swapRawSelectors(1, 10);
        (ICoreDiamondCutMigration.Payload memory payload, bytes memory payloadData) = _payload(address(liveCoordinator));
        (bytes memory stageA, bytes memory stageB) = _stages(payloadData);
        (bytes4[] memory selectorsBefore, address[] memory ownersBefore) = _orderedTopology();

        executor.execute(diamond, stageA, stageB);

        _assertFinalTopology(selectorsBefore, ownersBefore, address(liveCoordinator));
        assertEq(_registryGeneration(COORDINATOR_NAMESPACE), 2);
        _assertRetiredManifest(payload);
    }

    function testMissingExcludedSelectorUsesDeclaredError() public {
        CoreMigrationTopologyHarness harness = new CoreMigrationTopologyHarness();
        vm.expectRevert(
            abi.encodeWithSelector(
                LibCoreDiamondCutMigration.CoreMigrationTopologySelectorMissing.selector, MIGRATION_SELECTOR
            )
        );
        harness.topologyHashWithout(MIGRATION_SELECTOR);
    }

    function testUnauthorizedStageAReverts() public {
        (, bytes memory payloadData) = _payload(address(liveCoordinator));
        bytes memory bridgeCalldata = abi.encodeCall(
            CoreDiamondCutMigrationBridgeInit.armCoreDiamondCutMigration, (address(migrationFacet), payloadData)
        );
        vm.expectRevert();
        IDiamondCut(diamond).diamondCut(_addMigrationCut(), address(bridgeInit), bridgeCalldata);
    }

    function testWrongTransientCommitmentRevertsBothStagesAtomically() public {
        (ICoreDiamondCutMigration.Payload memory payload, bytes memory payloadData) = _payload(address(liveCoordinator));
        (bytes memory stageA,) = _stages(payloadData);
        payload.baselineTopologyHash = bytes32(uint256(payload.baselineTopologyHash) ^ 1);
        bytes memory wrongPayload = abi.encode(payload);
        bytes memory stageB = abi.encodeCall(ICoreDiamondCutMigration.executeCoreDiamondCutMigration, (wrongPayload));
        address oldCoordinator = IDiamondLoupe(diamond).facetAddress(IDiamondCut.diamondCut.selector);

        vm.expectRevert();
        executor.execute(diamond, stageA, stageB);

        assertEq(IDiamondLoupe(diamond).facetAddress(IDiamondCut.diamondCut.selector), oldCoordinator);
        assertEq(IDiamondLoupe(diamond).facetAddress(MIGRATION_SELECTOR), address(0));
        assertEq(_registryGeneration(migrationFacet.FACET_NAMESPACE()), 0);
    }

    function testWrongCanonicalRuntimeRevertsAtomicMigration() public {
        CoreMigrationFakeCoordinator fake = new CoreMigrationFakeCoordinator();
        (, bytes memory payloadData) = _payload(address(fake));
        (bytes memory stageA, bytes memory stageB) = _stages(payloadData);
        address oldCoordinator = IDiamondLoupe(diamond).facetAddress(IDiamondCut.diamondCut.selector);

        vm.expectRevert();
        executor.execute(diamond, stageA, stageB);

        assertEq(IDiamondLoupe(diamond).facetAddress(IDiamondCut.diamondCut.selector), oldCoordinator);
        assertEq(IDiamondLoupe(diamond).facetAddress(MIGRATION_SELECTOR), address(0));
    }

    function testIncompleteManifestRevertsBothStagesAtomically() public {
        (ICoreDiamondCutMigration.Payload memory payload,) = _payload(address(liveCoordinator));
        bytes32[] memory namespaces = new bytes32[](payload.namespaces.length - 1);
        uint64[] memory generations = new uint64[](payload.generations.length - 1);
        for (uint256 i; i < namespaces.length; ++i) {
            namespaces[i] = payload.namespaces[i];
            generations[i] = payload.generations[i];
        }
        payload.namespaces = namespaces;
        payload.generations = generations;
        bytes memory payloadData = abi.encode(payload);
        (bytes memory stageA, bytes memory stageB) = _stages(payloadData);

        vm.expectRevert();
        executor.execute(diamond, stageA, stageB);

        assertEq(IDiamondLoupe(diamond).facetAddress(MIGRATION_SELECTOR), address(0));
        assertEq(_registryGeneration(migrationFacet.FACET_NAMESPACE()), 0);
    }

    function testSuccessfulMigrationCannotReplay() public {
        (, bytes memory payloadData) = _payload(address(liveCoordinator));
        (bytes memory stageA, bytes memory stageB) = _stages(payloadData);
        executor.execute(diamond, stageA, stageB);

        vm.expectRevert();
        executor.executeOne(diamond, stageB);
    }

    function _payload(address newCoordinator)
        private
        view
        returns (ICoreDiamondCutMigration.Payload memory payload, bytes memory payloadData)
    {
        return _payloadFor(newCoordinator, address(executor));
    }

    function _payloadFor(address newCoordinator, address safe)
        private
        view
        returns (ICoreDiamondCutMigration.Payload memory payload, bytes memory payloadData)
    {
        (bytes4[] memory selectors, address[] memory owners) = _orderedTopology();
        (bytes32[] memory namespaces, uint64[] memory generations) = _manifest();
        address oldCoordinator = IDiamondLoupe(diamond).facetAddress(IDiamondCut.diamondCut.selector);
        payload = ICoreDiamondCutMigration.Payload({
            safe: safe,
            oldCoordinator: oldCoordinator,
            oldCoordinatorCodeHash: oldCoordinator.codehash,
            newCoordinator: newCoordinator,
            newCoordinatorCodeHash: newCoordinator.codehash,
            migrationFacet: address(migrationFacet),
            migrationFacetCodeHash: address(migrationFacet).codehash,
            retirementInitializer: address(retirementInit),
            retirementInitializerCodeHash: address(retirementInit).codehash,
            baselineTopologyHash: keccak256(abi.encode(selectors, owners)),
            namespaces: namespaces,
            generations: generations
        });
        payloadData = abi.encode(payload);
    }

    function _stages(bytes memory payloadData) private view returns (bytes memory stageA, bytes memory stageB) {
        bytes memory bridgeCalldata = abi.encodeCall(
            CoreDiamondCutMigrationBridgeInit.armCoreDiamondCutMigration, (address(migrationFacet), payloadData)
        );
        stageA = abi.encodeCall(IDiamondCut.diamondCut, (_addMigrationCut(), address(bridgeInit), bridgeCalldata));
        stageB = abi.encodeCall(ICoreDiamondCutMigration.executeCoreDiamondCutMigration, (payloadData));
    }

    function _addMigrationCut() private view returns (IDiamond.FacetCut[] memory cut) {
        cut = new IDiamond.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = MIGRATION_SELECTOR;
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(migrationFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: selectors
        });
    }

    function _manifest() private view returns (bytes32[] memory namespaces, uint64[] memory generations) {
        address[] memory facets = IDiamondLoupe(diamond).facetAddresses();
        namespaces = new bytes32[](facets.length + 1);
        generations = new uint64[](facets.length + 1);
        for (uint256 i; i < facets.length; ++i) {
            (bool ok, bytes memory data) = facets[i].staticcall(abi.encodeWithSignature("FACET_NAMESPACE()"));
            assertTrue(ok);
            namespaces[i] = abi.decode(data, (bytes32));
            generations[i] = 1;
        }
        namespaces[facets.length] = migrationFacet.FACET_NAMESPACE();
        generations[facets.length] = 1;
        _sort(namespaces, generations);
    }

    function _sort(bytes32[] memory namespaces, uint64[] memory generations) private pure {
        for (uint256 i = 1; i < namespaces.length; ++i) {
            bytes32 namespace = namespaces[i];
            uint64 generation = generations[i];
            uint256 j = i;
            while (j != 0 && namespaces[j - 1] > namespace) {
                namespaces[j] = namespaces[j - 1];
                generations[j] = generations[j - 1];
                --j;
            }
            namespaces[j] = namespace;
            generations[j] = generation;
        }
    }

    function _orderedTopology() private view returns (bytes4[] memory selectors, address[] memory owners) {
        bytes32 lengthSlot = bytes32(uint256(DIAMOND_STORAGE_POSITION) + 1);
        uint256 count = uint256(vm.load(diamond, lengthSlot));
        selectors = new bytes4[](count);
        owners = new address[](count);
        for (uint256 i; i < count; ++i) {
            bytes4 selector = _rawSelectorAt(i);
            selectors[i] = selector;
            owners[i] = address(uint160(uint256(_rawSelectorWord(selector))));
        }
    }

    function _swapRawSelectors(uint256 firstIndex, uint256 secondIndex) private {
        bytes4 first = _rawSelectorAt(firstIndex);
        bytes4 second = _rawSelectorAt(secondIndex);
        _setRawSelectorAt(firstIndex, second);
        _setRawSelectorAt(secondIndex, first);
        _setRawSelectorPosition(first, secondIndex);
        _setRawSelectorPosition(second, firstIndex);
    }

    function _rawSelectorAt(uint256 index) private view returns (bytes4 selector) {
        bytes32 lengthSlot = bytes32(uint256(DIAMOND_STORAGE_POSITION) + 1);
        bytes32 dataStart = keccak256(abi.encode(lengthSlot));
        uint256 word = uint256(vm.load(diamond, bytes32(uint256(dataStart) + index / 8)));
        // The shift isolates exactly one packed four-byte selector before truncation.
        // forge-lint: disable-next-line(unsafe-typecast)
        selector = bytes4(uint32(word >> ((index % 8) * 32)));
    }

    function _setRawSelectorAt(uint256 index, bytes4 selector) private {
        bytes32 lengthSlot = bytes32(uint256(DIAMOND_STORAGE_POSITION) + 1);
        bytes32 dataStart = keccak256(abi.encode(lengthSlot));
        bytes32 slot = bytes32(uint256(dataStart) + index / 8);
        uint256 shift = (index % 8) * 32;
        uint256 word = uint256(vm.load(diamond, slot));
        word = (word & ~(uint256(type(uint32).max) << shift)) | (uint256(uint32(selector)) << shift);
        vm.store(diamond, slot, bytes32(word));
    }

    function _setRawSelectorPosition(bytes4 selector, uint256 position) private {
        bytes32 slot = keccak256(abi.encode(selector, DIAMOND_STORAGE_POSITION));
        uint256 word = uint256(vm.load(diamond, slot));
        word = (word & ~(uint256(type(uint16).max) << 160)) | (position << 160);
        vm.store(diamond, slot, bytes32(word));
    }

    function _rawSelectorWord(bytes4 selector) private view returns (bytes32) {
        return vm.load(diamond, keccak256(abi.encode(selector, DIAMOND_STORAGE_POSITION)));
    }

    function _assertFinalTopology(
        bytes4[] memory selectorsBefore,
        address[] memory ownersBefore,
        address expectedCoordinator
    ) private view {
        (bytes4[] memory selectorsAfter, address[] memory ownersAfter) = _orderedTopology();
        assertEq(selectorsAfter.length, selectorsBefore.length + 1);
        for (uint256 i; i < selectorsBefore.length; ++i) {
            assertEq(selectorsAfter[i], selectorsBefore[i]);
            address expected =
                selectorsBefore[i] == IDiamondCut.diamondCut.selector ? expectedCoordinator : ownersBefore[i];
            assertEq(ownersAfter[i], expected);
        }
        assertEq(selectorsAfter[selectorsBefore.length], GENERATION_SELECTOR);
        assertEq(ownersAfter[selectorsBefore.length], expectedCoordinator);
    }

    function _assertRetiredManifest(ICoreDiamondCutMigration.Payload memory payload) private view {
        for (uint256 i; i < payload.namespaces.length; ++i) {
            for (uint256 offset = 1; offset <= 4; ++offset) {
                assertEq(_legacyWord(payload.namespaces[i], offset), bytes32(0));
            }
        }
    }

    function _assertStageBDiamondCutEvent(Vm.Log[] memory logs, ICoreDiamondCutMigration.Payload memory payload)
        private
        view
    {
        uint256 stageBEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != diamond || logs[i].topics.length == 0 || logs[i].topics[0] != DIAMOND_CUT_TOPIC) {
                continue;
            }
            (IDiamond.FacetCut[] memory cut, address initializer, bytes memory initCalldata) =
                abi.decode(logs[i].data, (IDiamond.FacetCut[], address, bytes));
            if (cut.length != 3) continue;
            ++stageBEvents;
            assertEq(initializer, payload.retirementInitializer);
            assertEq(
                initCalldata,
                abi.encodeCall(
                    CoreFacetRegistryRetirementInit.retireCoreLegacyFacetRegistry,
                    (payload.namespaces, payload.generations)
                )
            );
            assertEq(cut[0].facetAddress, payload.newCoordinator);
            assertEq(uint8(cut[0].action), uint8(IDiamond.FacetCutAction.Replace));
            assertEq(cut[0].functionSelectors.length, 1);
            assertEq(cut[0].functionSelectors[0], IDiamondCut.diamondCut.selector);
            assertEq(cut[1].facetAddress, payload.newCoordinator);
            assertEq(uint8(cut[1].action), uint8(IDiamond.FacetCutAction.Add));
            assertEq(cut[1].functionSelectors.length, 1);
            assertEq(cut[1].functionSelectors[0], GENERATION_SELECTOR);
            assertEq(cut[2].facetAddress, address(0));
            assertEq(uint8(cut[2].action), uint8(IDiamond.FacetCutAction.Remove));
            assertEq(cut[2].functionSelectors.length, 1);
            assertEq(cut[2].functionSelectors[0], MIGRATION_SELECTOR);
        }
        assertEq(stageBEvents, 1, "exact Stage-B DiamondCut event");
    }

    function _registryGeneration(bytes32 namespace) private view returns (uint64) {
        return uint64(uint256(vm.load(diamond, keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT)))));
    }

    function _legacyWord(bytes32 namespace, uint256 offset) private view returns (bytes32) {
        return
            vm.load(diamond, keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + offset))));
    }

    function _deployLegacyCore() private returns (DeploymentTypes.DeployArtifacts memory deployed) {
        MockERC20 tokA = new MockERC20("Gold A", "GLDA", 18);
        MockERC20 tokB = new MockERC20("Gold B", "GLDB", 6);
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = address(this);
        cfg.safeWallet = MockSafeWalletFactory.deploy(address(this));
        cfg.name = "CyberGold";
        cfg.symbol = "CYGLD";
        cfg.coreTreasury = address(0xB0B);
        cfg.basketAssets = new address[](2);
        cfg.basketAssets[0] = address(tokA);
        cfg.basketAssets[1] = address(tokB);
        cfg.basketTargetsPpm = new uint256[](2);
        cfg.basketTargetsPpm[0] = 600_000;
        cfg.basketTargetsPpm[1] = 400_000;
        cfg.basketGoldRefGramsFp18 = new uint256[](2);
        cfg.basketGoldRefGramsFp18[0] = 100 ether;
        cfg.basketGoldRefGramsFp18[1] = 50 ether;
        cfg.cygldRefGramsFp18 = 1 ether;
        cfg.maxTotalSupply = 250 ether;
        cfg.issuanceFeePpm = 1_000;
        cfg.redemptionFeePpm = 1_000;
        deployed = DeploymentHelper.deploy(cfg);
    }

    function _deployCanonicalLiveCoordinator() private returns (DiamondCutAccessLiveFacet coordinator) {
        coordinator = new DiamondCutAccessLiveFacet();
        // Preserve the exact deployed historical runtime even when current coordinator behavior changes.
        bytes memory runtime = vm.parseBytes(
            vm.trim(vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/deployed-core-live-coordinator.hex")))
        );
        vm.etch(address(coordinator), runtime);
        assertEq(address(coordinator).codehash, CANONICAL_LIVE_COORDINATOR_CODE_HASH);
    }
}
