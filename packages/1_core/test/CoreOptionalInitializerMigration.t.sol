// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DiamondArgs} from "diamond-1/Diamond.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ProtocolDiamond} from "diamond-infra/diamond/ProtocolDiamond.sol";
import {FacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";
import {AccessControlFacet} from "diamond-infra/facets/AccessControlFacet.sol";
import {DiamondCutAccessLiveFacet} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
import {ProtocolDiamondLoupeFacet} from "diamond-infra/facets/ProtocolDiamondLoupeFacet.sol";
import {LiveInitCoordinator} from "diamond-infra/helpers/LiveInitCoordinator.sol";
import {LiveValidatedDiamondCut} from "diamond-infra/helpers/LiveValidatedDiamondCut.sol";
import {StandardInterfaceManifests} from "diamond-infra/libraries/StandardInterfaceManifests.sol";
import {ICoreOptionalInitializerMigration} from "../src/interfaces/ICoreOptionalInitializerMigration.sol";
import {CoreOptionalInitializerMigrationFacet} from "../src/migration/CoreOptionalInitializerMigrationFacet.sol";
import {LibCoreOptionalInitializerMigration} from "../src/migration/LibCoreOptionalInitializerMigration.sol";
import {
    CoreMigrationAtomicExecutor,
    CoreMigrationSafeHarness,
    CoreMigrationMultiSendCallOnly,
    CoreMigrationPostFacet,
    CoreMigrationNoopInit
} from "./CoreDiamondCutMigration.t.sol";

contract OptionalInitializerLaunchInit is LiveInitCoordinator {
    function init(address admin, address cut, address loupe, address access) external {
        StandardInterfaceManifests.registerErc165();
        StandardInterfaceManifests.registerDiamondCut();
        StandardInterfaceManifests.registerDiamondLoupe();
        StandardInterfaceManifests.registerAccessControl();
        StandardInterfaceManifests.registerAccessControlEnumerable();
        _checkAndSetLiveLaunchFacetGeneration(cut);
        _checkAndSetLiveLaunchFacetGeneration(loupe);
        _checkAndSetLiveLaunchFacetGeneration(access);
        _enterInitContext();
        (bool ok, bytes memory err) = access.delegatecall(abi.encodeCall(AccessControlFacet.initAccessControl, (admin)));
        _exitInitContext();
        if (!ok) assembly { revert(add(err, 32), mload(err)) }
    }
}

contract CoreOptionalInitializerMigrationTest is Test {
    bytes32 private constant DIAMOND_SLOT = keccak256("diamond.standard.diamond.storage");
    bytes32 private constant REGISTRY_SLOT = 0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 private constant COORDINATOR_NAMESPACE = keccak256("cybergold.upgrade.coordinator.access");
    bytes32 private constant TEMP_NAMESPACE = keccak256("cybergold.core.optional-initializer-migration");
    bytes32 private constant OLD_HASH = 0x0282a85c0081e7384a120fc9ea2253a5a6b231f8169c07d5939f0540ef0df98f;
    bytes32 private constant ROLE = keccak256("UPGRADER_ROLE");
    bytes4 private constant GENERATION = bytes4(keccak256("facetGeneration(bytes32)"));
    bytes4 private constant EXECUTE =
        ICoreOptionalInitializerMigration.executeCoreOptionalInitializerMigration.selector;
    address private diamond;
    DiamondCutAccessLiveFacet private oldCoordinator;
    DiamondCutAccessLiveFacet private newCoordinator;
    CoreOptionalInitializerMigrationFacet private migration;
    CoreMigrationAtomicExecutor private executor;
    CoreMigrationSafeHarness private safe;
    CoreMigrationMultiSendCallOnly private multiSend;

    function setUp() public {
        vm.chainId(1);
        oldCoordinator = new DiamondCutAccessLiveFacet();
        newCoordinator = new DiamondCutAccessLiveFacet();
        migration = new CoreOptionalInitializerMigrationFacet();
        executor = new CoreMigrationAtomicExecutor();
        safe = new CoreMigrationSafeHarness();
        multiSend = new CoreMigrationMultiSendCallOnly();
        ProtocolDiamondLoupeFacet loupe = new ProtocolDiamondLoupeFacet();
        AccessControlFacet access = new AccessControlFacet();
        OptionalInitializerLaunchInit init = new OptionalInitializerLaunchInit();
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](3);
        cut[0] =
            IDiamond.FacetCut(address(oldCoordinator), IDiamond.FacetCutAction.Add, FacetSelectors.liveCutSelectors());
        cut[1] = IDiamond.FacetCut(address(loupe), IDiamond.FacetCutAction.Add, FacetSelectors.loupeSelectors());
        cut[2] = IDiamond.FacetCut(address(access), IDiamond.FacetCutAction.Add, FacetSelectors.accessSelectors());
        diamond = address(
            new ProtocolDiamond(
                cut,
                DiamondArgs(
                    address(this),
                    address(init),
                    abi.encodeCall(
                        OptionalInitializerLaunchInit.init,
                        (address(this), address(oldCoordinator), address(loupe), address(access))
                    )
                )
            )
        );
        bytes memory oldRuntime = vm.parseBytes(
            vm.trim(vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/deployed-core-live-coordinator.hex")))
        );
        vm.etch(address(oldCoordinator), oldRuntime);
        assertEq(address(oldCoordinator).codehash, OLD_HASH);
        vm.store(diamond, _generationSlot(COORDINATOR_NAMESPACE), bytes32(uint256(2)));
        IAccessControl(diamond).grantRole(ROLE, address(executor));
        IAccessControl(diamond).grantRole(ROLE, address(safe));
    }

    function testSafeAtomicMigrationPreservesAllOtherSelectorsAndStorageAndEnablesNoInitCut() public {
        ICoreOptionalInitializerMigration.Payload memory payload = _payload();
        (bytes4[] memory selectors, address[] memory owners) = _topology();
        bytes32 sentinel = keccak256("unrelated.core.storage.sentinel");
        vm.store(diamond, sentinel, bytes32(uint256(717)));
        // The live migration must never revive or clear the retired registry's fields.
        bytes32 retired = keccak256(abi.encode(COORDINATOR_NAMESPACE, uint256(REGISTRY_SLOT) + 1));
        vm.store(diamond, retired, bytes32(uint256(919)));
        (bytes memory first, bytes memory second) = _stages(abi.encode(payload));
        bytes memory transactions = bytes.concat(_packedCall(first), _packedCall(second));
        vm.recordLogs();
        assertTrue(
            safe.execTransaction(
                address(multiSend),
                0,
                abi.encodeCall(CoreMigrationMultiSendCallOnly.multiSend, (transactions)),
                CoreMigrationSafeHarness.Operation.DelegateCall
            )
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertFinal(selectors, owners);
        assertEq(vm.load(diamond, sentinel), bytes32(uint256(717)));
        assertEq(vm.load(diamond, retired), bytes32(uint256(919)));
        _assertCutEvents(logs);
        assertTrue(IAccessControl(diamond).hasRole(ROLE, address(safe)));
        CoreMigrationPostFacet extra = new CoreMigrationPostFacet();
        executor.executeOne(
            diamond,
            abi.encodeCall(
                IDiamondCut.diamondCut,
                (
                    _singleCut(
                        address(extra), IDiamond.FacetCutAction.Add, CoreMigrationPostFacet.postMigrationPing.selector
                    ),
                    address(0),
                    bytes("")
                )
            )
        );
        assertEq(CoreMigrationPostFacet(diamond).postMigrationPing(), 1);
        assertEq(DiamondCutAccessLiveFacet(diamond).facetGeneration(extra.FACET_NAMESPACE()), 1);
    }

    function testFrozenOldCoordinatorStillRequiresInitAndForbidsSelfReplacement() public {
        CoreMigrationPostFacet extra = new CoreMigrationPostFacet();
        vm.expectRevert(bytes4(keccak256("DiamondCutInitializerRequired()")));
        IDiamondCut(diamond)
            .diamondCut(
                _singleCut(address(extra), IDiamond.FacetCutAction.Add, extra.postMigrationPing.selector),
                address(0),
                ""
            );
        _expectCoordinatorImmutable(address(oldCoordinator));
    }

    function testNewCoordinatorStillForbidsOrdinarySelfReplacement() public {
        _migrate(_payload());
        _expectCoordinatorImmutable(address(newCoordinator));
    }

    function testBadSecondCallRollsBackFirstCutAndArming() public {
        ICoreOptionalInitializerMigration.Payload memory payload = _payload();
        bytes32 beforeHash = payload.baselineTopologyHash;
        payload.baselineTopologyHash = bytes32(uint256(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreOptionalInitializerMigrationFacet.CoreOptionalInitializerTopologyMismatch.selector,
                payload.baselineTopologyHash,
                beforeHash
            )
        );
        _migrate(payload);
        (bytes4[] memory selectors, address[] memory owners) = _topology();
        assertEq(keccak256(abi.encode(selectors, owners)), beforeHash);
        assertEq(_generation(TEMP_NAMESPACE), 0);
        assertEq(_generation(COORDINATOR_NAMESPACE), 2);
        assertEq(IDiamondLoupe(diamond).facetAddress(EXECUTE), address(0));
        _migrate(_payload());
    }

    function testSecondCallRequiresExactArmedPayload() public {
        bytes memory payload = abi.encode(_payload());
        _stageA(payload);
        bytes memory different = bytes.concat(payload, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(
                LibCoreOptionalInitializerMigration.CoreOptionalInitializerCommitmentMismatch.selector,
                _commitment(different, address(executor)),
                _commitment(payload, address(executor))
            )
        );
        executor.executeOne(
            diamond,
            abi.encodeCall(ICoreOptionalInitializerMigration.executeCoreOptionalInitializerMigration, (different))
        );
    }

    function testSecondCallRequiresSameAuthorityAndChain() public {
        bytes memory payload = abi.encode(_payload());
        _stageA(payload);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibCoreOptionalInitializerMigration.CoreOptionalInitializerCommitmentMismatch.selector,
                _commitment(payload, address(this)),
                _commitment(payload, address(executor))
            )
        );
        ICoreOptionalInitializerMigration(diamond).executeCoreOptionalInitializerMigration(payload);
        vm.chainId(2);
        bytes32 expected = _commitment(payload, address(executor));
        vm.chainId(1);
        bytes32 actual = _commitment(payload, address(executor));
        vm.chainId(2);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibCoreOptionalInitializerMigration.CoreOptionalInitializerCommitmentMismatch.selector, expected, actual
            )
        );
        executor.executeOne(
            diamond,
            abi.encodeCall(ICoreOptionalInitializerMigration.executeCoreOptionalInitializerMigration, (payload))
        );
    }

    function testUnauthorizedExecuteAndArmRejected() public {
        bytes memory payload = abi.encode(_payload());
        _stageA(payload);
        vm.prank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreOptionalInitializerMigrationFacet.CoreOptionalInitializerUnauthorized.selector, address(0xBAD)
            )
        );
        ICoreOptionalInitializerMigration(diamond).executeCoreOptionalInitializerMigration(payload);
        // Direct implementation access has no authority query. Delegatecall the arm through Core
        // after temporarily installing its selector to exercise the actual authority predicate.
        _setOwner(ICoreOptionalInitializerMigration.armCoreOptionalInitializerMigration.selector, address(migration));
        vm.prank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreOptionalInitializerMigrationFacet.CoreOptionalInitializerUnauthorized.selector, address(0xBAD)
            )
        );
        ICoreOptionalInitializerMigration(diamond).armCoreOptionalInitializerMigration(payload);
    }

    function testUnarmedExecutionRejected() public {
        bytes memory payload = abi.encode(_payload());
        CoreMigrationNoopInit noop = new CoreMigrationNoopInit();
        IDiamondCut(diamond)
            .diamondCut(
                _singleCut(address(migration), IDiamond.FacetCutAction.Add, EXECUTE),
                address(noop),
                abi.encodeCall(CoreMigrationNoopInit.init, ())
            );
        vm.expectRevert(
            abi.encodeWithSelector(
                LibCoreOptionalInitializerMigration.CoreOptionalInitializerCommitmentMismatch.selector,
                _commitment(payload, address(executor)),
                bytes32(0)
            )
        );
        executor.executeOne(
            diamond,
            abi.encodeCall(ICoreOptionalInitializerMigration.executeCoreOptionalInitializerMigration, (payload))
        );
    }

    function testBaselineRuntimeHashBoundToDeployedCoordinator() public {
        ICoreOptionalInitializerMigration.Payload memory payload = _payload();
        payload.oldCoordinatorCodeHash = bytes32(uint256(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreOptionalInitializerMigrationFacet.CoreOptionalInitializerBaselineMismatch.selector,
                payload.oldCoordinatorCodeHash
            )
        );
        _migrate(payload);
    }

    function testEveryImplementationRuntimeIsBound() public {
        ICoreOptionalInitializerMigration.Payload memory payload = _payload();
        payload.oldCoordinator = address(0xBAD);
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreOptionalInitializerMigrationFacet.CoreOptionalInitializerRuntimeMismatch.selector,
                payload.oldCoordinator,
                OLD_HASH,
                bytes32(0)
            )
        );
        _migrate(payload);
        payload = _payload();
        payload.newCoordinatorCodeHash = bytes32(uint256(9));
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreOptionalInitializerMigrationFacet.CoreOptionalInitializerRuntimeMismatch.selector,
                payload.newCoordinator,
                payload.newCoordinatorCodeHash,
                payload.newCoordinator.codehash
            )
        );
        _migrate(payload);
        payload = _payload();
        payload.migrationFacetCodeHash = bytes32(uint256(10));
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreOptionalInitializerMigrationFacet.CoreOptionalInitializerRuntimeMismatch.selector,
                payload.migrationFacet,
                payload.migrationFacetCodeHash,
                payload.migrationFacet.codehash
            )
        );
        _migrate(payload);
    }

    function testUnchangedCoordinatorAndWrongNamespaceRejected() public {
        ICoreOptionalInitializerMigration.Payload memory payload = _payload();
        payload.newCoordinator = address(oldCoordinator);
        payload.newCoordinatorCodeHash = OLD_HASH;
        vm.expectRevert(CoreOptionalInitializerMigrationFacet.CoreOptionalInitializerRuntimeUnchanged.selector);
        _migrate(payload);
        payload = _payload();
        payload.newCoordinator = address(migration);
        payload.newCoordinatorCodeHash = address(migration).codehash;
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreOptionalInitializerMigrationFacet.CoreOptionalInitializerNamespaceMismatch.selector, TEMP_NAMESPACE
            )
        );
        _migrate(payload);
    }

    function testBothAffectedGenerationsMustMatchInstalledState() public {
        ICoreOptionalInitializerMigration.Payload memory payload = _payload();
        vm.store(diamond, _generationSlot(COORDINATOR_NAMESPACE), bytes32(uint256(4)));
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreOptionalInitializerMigrationFacet.CoreOptionalInitializerGenerationMismatch.selector,
                COORDINATOR_NAMESPACE,
                uint64(2),
                uint64(4)
            )
        );
        _migrate(payload);
        vm.store(diamond, _generationSlot(COORDINATOR_NAMESPACE), bytes32(uint256(2)));
        bytes memory data = abi.encode(payload);
        _stageA(data);
        vm.store(diamond, _generationSlot(TEMP_NAMESPACE), bytes32(uint256(3)));
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreOptionalInitializerMigrationFacet.CoreOptionalInitializerGenerationMismatch.selector,
                TEMP_NAMESPACE,
                uint64(1),
                uint64(3)
            )
        );
        executor.executeOne(
            diamond, abi.encodeCall(ICoreOptionalInitializerMigration.executeCoreOptionalInitializerMigration, (data))
        );
    }

    function testAffectedSelectorOwnersMustMatchBaseline() public {
        bytes memory payload = abi.encode(_payload());
        _stageA(payload);
        _setOwner(GENERATION, address(newCoordinator));
        vm.expectRevert(
            abi.encodeWithSelector(
                CoreOptionalInitializerMigrationFacet.CoreOptionalInitializerSelectorMismatch.selector,
                GENERATION,
                address(oldCoordinator),
                address(newCoordinator)
            )
        );
        executor.executeOne(
            diamond,
            abi.encodeCall(ICoreOptionalInitializerMigration.executeCoreOptionalInitializerMigration, (payload))
        );
    }

    function testRetainedTopologyMustMatchApproval() public {
        ICoreOptionalInitializerMigration.Payload memory payload = _payload();
        bytes memory data = abi.encode(payload);
        _stageA(data);
        _setOwner(IDiamondLoupe.facetAddresses.selector, address(newCoordinator));
        vm.expectPartialRevert(CoreOptionalInitializerMigrationFacet.CoreOptionalInitializerTopologyMismatch.selector);
        executor.executeOne(
            diamond, abi.encodeCall(ICoreOptionalInitializerMigration.executeCoreOptionalInitializerMigration, (data))
        );
    }

    function testMalformedTemporarySelectorPositionRollsBackRawCut() public {
        bytes memory payload = abi.encode(_payload());
        _stageA(payload);
        bytes32 slot = keccak256(abi.encode(EXECUTE, DIAMOND_SLOT));
        uint256 previous = uint256(vm.load(diamond, slot));
        // A corrupt position would otherwise remove the first retained selector.
        vm.store(diamond, slot, bytes32(previous & uint256(type(uint160).max)));
        vm.expectPartialRevert(CoreOptionalInitializerMigrationFacet.CoreOptionalInitializerTopologyMismatch.selector);
        executor.executeOne(
            diamond,
            abi.encodeCall(ICoreOptionalInitializerMigration.executeCoreOptionalInitializerMigration, (payload))
        );
        assertEq(IDiamondLoupe(diamond).facetAddress(IDiamondCut.diamondCut.selector), address(oldCoordinator));
        assertEq(_generation(COORDINATOR_NAMESPACE), 2);
        assertEq(_generation(TEMP_NAMESPACE), 1);
    }

    function testStageARegistersOnlyTemporarySelectorAndGeneration() public {
        bytes memory payload = abi.encode(_payload());
        _stageA(payload);
        assertEq(_generation(COORDINATOR_NAMESPACE), 2);
        assertEq(_generation(TEMP_NAMESPACE), 1);
        assertEq(IDiamondLoupe(diamond).facetAddress(EXECUTE), address(migration));
        assertEq(
            IDiamondLoupe(diamond)
                .facetAddress(ICoreOptionalInitializerMigration.armCoreOptionalInitializerMigration.selector),
            address(0)
        );
    }

    function _payload() private view returns (ICoreOptionalInitializerMigration.Payload memory payload) {
        (bytes4[] memory selectors, address[] memory owners) = _topology();
        payload = ICoreOptionalInitializerMigration.Payload(
            address(oldCoordinator),
            OLD_HASH,
            address(newCoordinator),
            address(newCoordinator).codehash,
            address(migration),
            address(migration).codehash,
            keccak256(abi.encode(selectors, owners))
        );
    }

    function _stages(bytes memory payload) private view returns (bytes memory first, bytes memory second) {
        first = abi.encodeCall(
            IDiamondCut.diamondCut,
            (
                _singleCut(address(migration), IDiamond.FacetCutAction.Add, EXECUTE),
                address(migration),
                abi.encodeCall(ICoreOptionalInitializerMigration.armCoreOptionalInitializerMigration, (payload))
            )
        );
        second = abi.encodeCall(ICoreOptionalInitializerMigration.executeCoreOptionalInitializerMigration, (payload));
    }

    function _migrate(ICoreOptionalInitializerMigration.Payload memory payload) private {
        (bytes memory first, bytes memory second) = _stages(abi.encode(payload));
        executor.execute(diamond, first, second);
    }

    function _stageA(bytes memory payload) private {
        (bytes memory first,) = _stages(payload);
        executor.executeOne(diamond, first);
    }

    function _packedCall(bytes memory data) private view returns (bytes memory) {
        return abi.encodePacked(uint8(0), diamond, uint256(0), uint256(data.length), data);
    }

    function _singleCut(address facet, IDiamond.FacetCutAction action, bytes4 selector)
        private
        pure
        returns (IDiamond.FacetCut[] memory cut)
    {
        cut = new IDiamond.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        cut[0] = IDiamond.FacetCut(facet, action, selectors);
    }

    function _generationSlot(bytes32 namespace) private pure returns (bytes32) {
        return keccak256(abi.encode(namespace, REGISTRY_SLOT));
    }

    function _generation(bytes32 namespace) private view returns (uint64) {
        return uint64(uint256(vm.load(diamond, _generationSlot(namespace))));
    }

    function _setOwner(bytes4 selector, address owner) private {
        bytes32 slot = keccak256(abi.encode(selector, DIAMOND_SLOT));
        uint256 previous = uint256(vm.load(diamond, slot));
        vm.store(diamond, slot, bytes32((previous & ~uint256(type(uint160).max)) | uint256(uint160(owner))));
    }

    function _topology() private view returns (bytes4[] memory selectors, address[] memory owners) {
        bytes32 lengthSlot = bytes32(uint256(DIAMOND_SLOT) + 1);
        uint256 count = uint256(vm.load(diamond, lengthSlot));
        selectors = new bytes4[](count);
        owners = new address[](count);
        bytes32 start = keccak256(abi.encode(lengthSlot));
        for (uint256 i; i < count; ++i) {
            uint256 word = uint256(vm.load(diamond, bytes32(uint256(start) + i / 8)));
            selectors[i] = bytes4(uint32(word >> ((i % 8) * 32)));
            owners[i] = address(uint160(uint256(vm.load(diamond, keccak256(abi.encode(selectors[i], DIAMOND_SLOT))))));
        }
    }

    function _commitment(bytes memory payload, address caller) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("CYBERGOLD_CORE_OPTIONAL_INITIALIZER_MIGRATION_V1"),
                block.chainid,
                diamond,
                caller,
                keccak256(payload)
            )
        );
    }

    function _assertFinal(bytes4[] memory selectorsBefore, address[] memory ownersBefore) private view {
        (bytes4[] memory selectors, address[] memory owners) = _topology();
        assertEq(selectors.length, selectorsBefore.length);
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(selectors[i], selectorsBefore[i]);
            address expected = selectors[i] == IDiamondCut.diamondCut.selector || selectors[i] == GENERATION
                ? address(newCoordinator)
                : ownersBefore[i];
            assertEq(owners[i], expected);
        }
        assertEq(vm.load(diamond, keccak256(abi.encode(EXECUTE, DIAMOND_SLOT))), bytes32(0));
        assertEq(DiamondCutAccessLiveFacet(diamond).facetGeneration(COORDINATOR_NAMESPACE), 3);
        assertEq(_generation(TEMP_NAMESPACE), 0);
    }

    function _assertCutEvents(Vm.Log[] memory logs) private view {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != diamond
                    || logs[i].topics[0] != keccak256("DiamondCut((address,uint8,bytes4[])[],address,bytes)")
            ) continue;
            ++count;
            if (count != 2) continue;
            (IDiamond.FacetCut[] memory cuts, address init, bytes memory data) =
                abi.decode(logs[i].data, (IDiamond.FacetCut[], address, bytes));
            assertEq(init, address(0));
            assertEq(data.length, 0);
            assertEq(cuts.length, 2);
            assertEq(cuts[0].facetAddress, address(newCoordinator));
            assertEq(uint8(cuts[0].action), uint8(IDiamond.FacetCutAction.Replace));
            assertEq(cuts[0].functionSelectors[0], IDiamondCut.diamondCut.selector);
            assertEq(cuts[0].functionSelectors[1], GENERATION);
            assertEq(cuts[1].facetAddress, address(0));
            assertEq(uint8(cuts[1].action), uint8(IDiamond.FacetCutAction.Remove));
            assertEq(cuts[1].functionSelectors[0], EXECUTE);
        }
        assertEq(count, 2);
    }

    function _expectCoordinatorImmutable(address current) private {
        CoreMigrationNoopInit noop = new CoreMigrationNoopInit();
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutCoordinatorImmutable.selector, IDiamondCut.diamondCut.selector
            )
        );
        IDiamondCut(diamond)
            .diamondCut(
                _singleCut(address(current), IDiamond.FacetCutAction.Replace, IDiamondCut.diamondCut.selector),
                address(noop),
                abi.encodeCall(CoreMigrationNoopInit.init, ())
            );
    }
}
