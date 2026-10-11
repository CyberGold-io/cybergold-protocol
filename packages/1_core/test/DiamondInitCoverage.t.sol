// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155MetadataURI} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {CoreAuthorityInvariant} from "../src/deploy/CoreAuthorityInvariant.sol";
import {DiamondInit} from "../src/deploy/DiamondInit.sol";
import {FacetSelectors} from "../src/deploy/FacetSelectors.sol";
import {FacetSelectors as SharedFacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {FacetVersionRegistry} from "diamond-infra/helpers/FacetVersionRegistry.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {InterfaceRetirementInit} from "diamond-infra/helpers/InterfaceRetirementInit.sol";
import {ValidatedDiamondCut} from "diamond-infra/helpers/ValidatedDiamondCut.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {IDiamondEmergencyAuthority} from "diamond-infra/interfaces/IDiamondEmergencyAuthority.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {ICyberGoldCore} from "../src/interfaces/ICyberGoldCore.sol";
import {ICoreRedemption} from "../src/interfaces/ICoreRedemption.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {LensFacet} from "../src/facets/LensFacet.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {IRecoveryShareMetadata} from "../src/interfaces/IRecoveryShareMetadata.sol";

contract CoreFacetSelectorsHarness {
    function specCount(address[] memory facets) external pure returns (uint256) {
        return FacetSelectors.specs(facets).length;
    }
}

contract InitUnavailableBalanceToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address) external pure returns (uint256) {
        revert("balance unavailable");
    }
}

contract DiamondInitCoverageTest is Test {
    bytes4 private constant OBSOLETE_ADMIT_RESERVE_SELECTOR = 0x13e2a3ff;
    bytes4 private constant REMOVED_ZERO_VALUE_SURRENDER_SELECTOR = 0xdd04c556;
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 private constant REENTRANCY_GUARD_STORAGE_SLOT =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    bytes32 private constant INITIALIZED_TOPIC = keccak256("Initialized(uint64)");
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 private constant INIT_CONTEXT_SLOT = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;

    function testFacetSelectorSpecsRejectWrongFacetCount() public {
        CoreFacetSelectorsHarness harness = new CoreFacetSelectorsHarness();
        vm.expectRevert(bytes("FacetSelectors: facet count mismatch"));
        harness.specCount(new address[](14));
    }

    function testDiamondInitRejectsZeroAdmin() public {
        DiamondInit init = new DiamondInit();
        DiamondInit.InitConfig memory cfg;
        vm.expectRevert(DiamondInit.CoreAdminMissing.selector);
        init.init(cfg, "CyberGold", "CYGLD");
    }

    function testDiamondInitRejectsMissingAuthorityInvariant() public {
        DiamondInit init = new DiamondInit();
        DiamondInit.InitConfig memory cfg;
        cfg.admin = address(this);
        vm.expectRevert(DiamondInit.CoreAuthorityInvariantMissing.selector);
        init.init(cfg, "CyberGold", "CYGLD");
    }

    function testDiamondInitRejectsCallerMatchedNoncanonicalAuthorityInvariant() public {
        DiamondInit init = new DiamondInit();
        InitUnavailableBalanceToken impostor = new InitUnavailableBalanceToken();
        DiamondInit.InitConfig memory cfg;
        cfg.admin = address(this);
        cfg.authorityInvariant = address(impostor);
        cfg.authorityInvariantCodeHash = address(impostor).codehash;

        vm.expectRevert(DiamondInit.CoreAuthorityInvariantMissing.selector);
        init.init(cfg, "CyberGold", "CYGLD");
    }

    function testCoreAuthorityInvariantRejectsEmptyAuthorityState() public {
        CoreAuthorityInvariant invariantContract = new CoreAuthorityInvariant();
        vm.expectRevert(CoreAuthorityInvariant.CoreAuthorityInvariantFailed.selector);
        invariantContract.requireFinalAuthority(address(this));
    }

    function testDeploymentDoesNotRequireLaunchCustodyProbe() public {
        InitUnavailableBalanceToken token = new InitUnavailableBalanceToken();
        MockERC20 support = new MockERC20("Support", "SPRT", 18);
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = address(this);
        cfg.safeWallet = MockSafeWalletFactory.deploy(address(this));
        cfg.name = "CyberGold";
        cfg.symbol = "CYGLD";
        cfg.coreTreasury = address(0xB0B);
        cfg.basketAssets = new address[](2);
        cfg.basketAssets[0] = address(token);
        cfg.basketAssets[1] = address(support);
        cfg.basketTargetsPpm = new uint256[](2);
        cfg.basketTargetsPpm[0] = 500_000;
        cfg.basketTargetsPpm[1] = 500_000;
        cfg.basketGoldRefGramsFp18 = new uint256[](2);
        cfg.basketGoldRefGramsFp18[0] = 100 ether;
        cfg.basketGoldRefGramsFp18[1] = 100 ether;
        cfg.cygldRefGramsFp18 = 1 ether;
        cfg.maxTotalSupply = 250 ether;

        address diamond = this.deployForCoverage(cfg);
        IRecoveryTypes.ReserveLifecycleView memory lifecycle = LensFacet(diamond).reserveLifecycle(address(token));
        IRecoveryTypes.ReserveCustodyStatus memory custody = LensFacet(diamond).reserveCustodyStatus(address(token));
        assertEq(uint8(lifecycle.lifecycle), uint8(IRecoveryTypes.ReserveLifecycle.Active));
        assertEq(lifecycle.exitEntitlementRaw, 0);
        assertFalse(custody.liveBalanceAvailable);
        assertEq(custody.liveRawCustody, 0);
    }

    function deployForCoverage(DeploymentTypes.DeployConfig memory cfg) external returns (address) {
        return address(DeploymentHelper.deploy(cfg).diamond);
    }

    function testDeploymentInitializesExtraInterfaceIds() public {
        DeploymentTypes.DeployArtifacts memory art = _deployCore();
        bytes32 ownerSlot = bytes32(uint256(keccak256("diamond.standard.diamond.storage")) + 3);
        assertEq(address(uint160(uint256(vm.load(address(art.diamond), ownerSlot)))), address(0));
        IERC165 erc165 = IERC165(address(art.diamond));
        assertFalse(erc165.supportsInterface(type(ICyberGoldCore).interfaceId));
        assertTrue(erc165.supportsInterface(type(ICoreRedemption).interfaceId));
        assertTrue(erc165.supportsInterface(type(IAccessControlDefaultAdminRules).interfaceId));
        assertFalse(erc165.supportsInterface(type(IERC5313).interfaceId));
        assertTrue(erc165.supportsInterface(type(IERC1155).interfaceId));
        assertTrue(erc165.supportsInterface(type(IERC1155MetadataURI).interfaceId));
        assertEq(
            IDiamondLoupe(address(art.diamond)).facetAddress(IERC165.supportsInterface.selector),
            address(art.facets.loupe),
            "central loupe must remain the sole supportsInterface owner"
        );
        assertEq(
            IDiamondLoupe(address(art.diamond)).facetAddress(IERC1155MetadataURI.uri.selector),
            address(art.facets.recoveryShareMetadata)
        );
        assertEq(
            IDiamondLoupe(address(art.diamond)).facetAddress(IRecoveryShareMetadata.contractURI.selector),
            address(art.facets.recoveryShareMetadata)
        );
        assertEq(IDiamondLoupe(address(art.diamond)).facetAddress(IERC5313.owner.selector), address(0));
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareUnknown.selector, address(1)));
        IERC1155MetadataURI(address(art.diamond)).uri(1);
        LensFacet lens = LensFacet(address(art.diamond));
        assertEq(lens.effectiveCygldSupplyCap(), 250 ether);
        assertEq(lens.coreAttachedRecoveryAssets().length, 0);
        address[] memory launchAssets = lens.basketAssets();
        IRecoveryTypes.ReserveLifecycleView memory launchReserve = lens.reserveLifecycle(launchAssets[0]);
        assertEq(uint8(launchReserve.lifecycle), uint8(IRecoveryTypes.ReserveLifecycle.Active));
        assertEq(launchReserve.exitEntitlementRaw, 0);
        assertEq(lens.treasury(), address(0xB0B));
        assertEq(uint256(vm.load(address(art.diamond), REENTRANCY_GUARD_STORAGE_SLOT)), 0);
        _assertCleanLaunchFacetVersionInventory(address(art.diamond));
    }

    function testFreshDeploymentOmitsAggregateAndRemovedSelectors() public {
        DeploymentTypes.DeployArtifacts memory art = _deployCore();
        address diamond = address(art.diamond);
        IERC165 erc165 = IERC165(diamond);
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        bytes4 obsoleteAggregateInterfaceId =
            type(ICyberGoldCore).interfaceId ^ ICyberGoldCore.activateAsset.selector ^ OBSOLETE_ADMIT_RESERVE_SELECTOR;

        assertFalse(erc165.supportsInterface(type(ICyberGoldCore).interfaceId));
        assertTrue(erc165.supportsInterface(type(ICoreRedemption).interfaceId));
        assertFalse(erc165.supportsInterface(obsoleteAggregateInterfaceId));
        assertEq(loupe.facetAddress(OBSOLETE_ADMIT_RESERVE_SELECTOR), address(0));
        assertEq(loupe.facetAddress(REMOVED_ZERO_VALUE_SURRENDER_SELECTOR), address(0));
        assertEq(loupe.facetAddress(ICyberGoldCore.activateAsset.selector), address(art.facets.reserveLifecycle));
    }

    function testFreshCoreUsesOneOuterInitializableVersion() public {
        vm.recordLogs();
        DeploymentTypes.DeployArtifacts memory art = _deployCore();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 initializedCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(art.diamond) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != INITIALIZED_TOPIC) continue;
            uint64 version = abi.decode(logs[i].data, (uint64));
            assertEq(version, 1);
            ++initializedCount;
        }

        assertEq(initializedCount, 1, "unexpected Initializable event count");
        assertEq(uint64(uint256(vm.load(address(art.diamond), INITIALIZABLE_STORAGE))), 1);
    }

    function testFullDiamondInitReplayRevertsAtomically() public {
        DeploymentTypes.DeployArtifacts memory art = _deployCore();
        address diamond = address(art.diamond);
        string memory nameBefore = IERC20Metadata(diamond).name();
        address safeBefore = PausableFacet(diamond).safeWallet();
        bytes32 ownerSlot = bytes32(uint256(keccak256("diamond.standard.diamond.storage")) + 3);
        bytes32 ownerBefore = vm.load(diamond, ownerSlot);
        DiamondInit.InitConfig memory replayCfg;

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        IDiamondCut(diamond)
            .diamondCut(
                new IDiamond.FacetCut[](0),
                address(art.diamondInit),
                abi.encodeWithSelector(DiamondInit.init.selector, replayCfg, "Mutated", "MUT")
            );

        assertEq(IERC20Metadata(diamond).name(), nameBefore);
        assertEq(PausableFacet(diamond).safeWallet(), safeBefore);
        assertEq(vm.load(diamond, ownerSlot), ownerBefore);
        assertEq(vm.load(diamond, INIT_CONTEXT_SLOT), bytes32(0));
        assertEq(uint256(vm.load(diamond, REENTRANCY_GUARD_STORAGE_SLOT)), 0);
    }

    function testAggregateOnlySelectorCanBeRemovedButNarrowSelectorsRemainProtected() public {
        address diamond = address(_deployCore().diamond);
        IDiamondCut(diamond).diamondCut(_removeCut(ICyberGoldCore.issue.selector), address(0), "");
        assertEq(IDiamondLoupe(diamond).facetAddress(ICyberGoldCore.issue.selector), address(0));
        _expectAdvertisedSelectorRemovalRejected(diamond, PausableFacet.pause.selector);
        _expectAdvertisedSelectorRemovalRejected(diamond, IERC1155.safeTransferFrom.selector);
    }

    function testUnadvertisedAggregateNeedsNoRetirementForSelectorRemoval() public {
        address diamond = address(_deployCore().diamond);
        IDiamondCut(diamond).diamondCut(_removeCut(ICyberGoldCore.issue.selector), address(0), "");

        assertFalse(IERC165(diamond).supportsInterface(type(ICyberGoldCore).interfaceId));
        assertEq(IDiamondLoupe(diamond).facetAddress(ICyberGoldCore.issue.selector), address(0));
    }

    function testNarrowAdvertisedInterfacesRemainProtectedAfterAggregateRetirement() public {
        address diamond = address(_deployCore().diamond);

        bytes4[] memory interfaceIds = new bytes4[](10);
        interfaceIds[0] = type(IAccessControl).interfaceId;
        interfaceIds[1] = type(IAccessControlEnumerable).interfaceId;
        interfaceIds[2] = type(IAccessControlDefaultAdminRules).interfaceId;
        interfaceIds[3] = type(IDiamondEmergencyAuthority).interfaceId;
        interfaceIds[4] = type(IERC20).interfaceId;
        interfaceIds[5] = type(IERC20Metadata).interfaceId;
        interfaceIds[6] = type(IERC20Permit).interfaceId;
        interfaceIds[7] = type(IERC1155).interfaceId;
        interfaceIds[8] = type(IERC1155MetadataURI).interfaceId;
        interfaceIds[9] = type(ICoreRedemption).interfaceId;

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = IAccessControl.grantRole.selector;
        selectors[1] = IAccessControlEnumerable.getRoleMember.selector;
        selectors[2] = IAccessControlDefaultAdminRules.defaultAdmin.selector;
        selectors[3] = IDiamondEmergencyAuthority.safeWallet.selector;
        selectors[4] = IERC20.transfer.selector;
        selectors[5] = IERC20Metadata.name.selector;
        selectors[6] = IERC20Permit.permit.selector;
        selectors[7] = IERC1155.balanceOf.selector;
        selectors[8] = IERC1155MetadataURI.uri.selector;
        selectors[9] = ICoreRedemption.redeem.selector;

        assertFalse(IERC165(diamond).supportsInterface(type(ICyberGoldCore).interfaceId));
        for (uint256 i; i < interfaceIds.length; ++i) {
            assertTrue(IERC165(diamond).supportsInterface(interfaceIds[i]));
            _expectAdvertisedSelectorRemovalRejected(diamond, selectors[i]);
        }
    }

    function testExtensionManifestsProtectInheritedSelectors() public {
        address erc20Diamond = address(_deployCore().diamond);
        _expectRetirementStillProtectedByExtension(erc20Diamond, type(IERC20).interfaceId, IERC20.transfer.selector);

        address erc1155Diamond = address(_deployCore().diamond);
        _expectRetirementStillProtectedByExtension(
            erc1155Diamond, type(IERC1155).interfaceId, IERC1155.balanceOf.selector
        );
    }

    function _deployCore() private returns (DeploymentTypes.DeployArtifacts memory art) {
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

        art = DeploymentHelper.deploy(cfg);
        _handoffCoreAuthorityForTest(address(art.diamond), cfg.safeWallet);
    }

    function _handoffCoreAuthorityForTest(address diamond, address launchSafe) private {
        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(diamond);
        bytes32 upgraderRole = access.upgraderRole();

        vm.prank(launchSafe);
        access.beginDefaultAdminTransfer(address(this));
        vm.warp(block.timestamp + 1);
        access.acceptDefaultAdminTransfer();

        access.grantRole(upgraderRole, address(this));
        access.revokeRole(upgraderRole, launchSafe);
    }

    function _expectAdvertisedSelectorRemovalRejected(address diamond, bytes4 selector) private {
        vm.expectRevert(
            abi.encodeWithSelector(ValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, selector)
        );
        IDiamondCut(diamond).diamondCut(_removeCut(selector), address(0), "");
    }

    function _expectRetirementStillProtectedByExtension(address diamond, bytes4 retiredId, bytes4 selector) private {
        InterfaceRetirementInit init = new InterfaceRetirementInit();
        bytes4[] memory interfaceIds = new bytes4[](1);
        interfaceIds[0] = retiredId;
        vm.expectRevert(
            abi.encodeWithSelector(ValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, selector)
        );
        IDiamondCut(diamond)
            .diamondCut(
                _removeCut(selector),
                address(init),
                abi.encodeCall(InterfaceRetirementInit.retireInterfaces, (interfaceIds))
            );
    }

    function _removeCut(bytes4 selector) private pure returns (IDiamond.FacetCut[] memory cut) {
        cut = new IDiamond.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(0), action: IDiamond.FacetCutAction.Remove, functionSelectors: selectors
        });
    }

    function _assertFacetVersion(address diamond, bytes32 namespace, uint64 expected) private view {
        bytes32 slot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
        assertEq(uint64(uint256(vm.load(diamond, slot))), expected);
    }

    function _assertCleanLaunchFacetVersionInventory(address diamond) private view {
        _assertFacetVersion(diamond, keccak256("cybergold.upgrade.coordinator.access"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.shared.diamond.loupe"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.access-control.default-admin-rules"), 1);
        _assertFacetVersion(diamond, keccak256("openzeppelin.storage.Pausable"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.core.token"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.controller.init"), 0);
        _assertFacetVersion(diamond, keccak256("cybergold.controller.issuance"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.controller.redemption"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.controller.rebalance"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.controller.preview"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.controller.basket.admin"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.controller.config"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.core.lens"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.core.reserve-lifecycle"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.core.recovery-share"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.core.recovery-share-metadata"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.core.recovery-admin"), 1);
        _assertFacetVersion(diamond, keccak256("cybergold.core.recovery-pool-settlement"), 1);
        _assertFacetVersion(diamond, keccak256("openzeppelin.storage.ReentrancyGuard"), 0);
    }

    function testDiamondInitBubblesNoDataDelegateRevert() public {
        CoreDiamondInitHarness init = new CoreDiamondInitHarness();
        EmptyRevertInitFacet target = new EmptyRevertInitFacet();
        bytes memory data = abi.encodeWithSelector(
            DefaultAdminAccessControlFacet.initDefaultAdminAccessControlFromOuter.selector, address(this)
        );

        (bool ok, bytes memory returndata) =
            address(init).call(abi.encodeCall(CoreDiamondInitHarness.exposedDelegate, (address(target), data)));
        assertFalse(ok);
        assertEq(returndata.length, 0);
    }

    function testLaunchFacetMetadataRejectsEoaFutureVersionAndDuplicateNamespace() public {
        CoreDiamondInitHarness init = new CoreDiamondInitHarness();
        address eoa = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(FacetVersionRegistry.FacetVersionProbeFailed.selector, eoa));
        init.exposedRegisterLaunch(eoa);

        bytes32 namespace = keccak256("cybergold.core.test.launch-metadata");
        CoreVersionedInitFacet future = new CoreVersionedInitFacet(namespace, 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                FacetVersionRegistry.FacetLaunchMetadataInvalid.selector, address(future), namespace, uint64(2)
            )
        );
        init.exposedRegisterLaunch(address(future));

        CoreVersionedInitFacet launch = new CoreVersionedInitFacet(namespace, 1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(0x11111111);
        init.seedGroup(address(launch), selectors);
        init.exposedRegisterLaunch(address(launch));
        vm.expectRevert(
            abi.encodeWithSelector(
                FacetVersionRegistry.FacetInitVersionAlreadyInitialized.selector, namespace, uint64(1), uint64(1)
            )
        );
        init.exposedRegisterLaunch(address(launch));
    }

    function testLaunchTopologyRejectsMissingCutWrongOwnerZeroFacetAndExtraSelector() public {
        CoreDiamondInitHarness empty = new CoreDiamondInitHarness();
        vm.expectRevert(DiamondInit.CoreFacetTopologyMismatch.selector);
        empty.exposedRegisterCut();

        CoreDiamondInitHarness missingLoupe = new CoreDiamondInitHarness();
        CoreVersionedInitFacet cut = new CoreVersionedInitFacet(keccak256("cybergold.core.test.cut"), 1);
        missingLoupe.seedGroup(address(cut), SharedFacetSelectors.cutSelectors());
        vm.expectRevert(DiamondInit.CoreFacetTopologyMismatch.selector);
        missingLoupe.exposedRegisterCut();

        CoreDiamondInitHarness init = new CoreDiamondInitHarness();
        DiamondInit.InitConfig memory cfg = _topologyConfig();
        _seedTopology(init, cfg);
        init.exposedRequireTopology(cfg);

        bytes4 tokenSelector = FacetSelectors.tokenSelectors()[0];
        init.overwriteOwner(tokenSelector, address(0xDEAD));
        vm.expectRevert(DiamondInit.CoreFacetTopologyMismatch.selector);
        init.exposedRequireTopology(cfg);
        init.overwriteOwner(tokenSelector, cfg.tokenFacet);

        address accessFacet = cfg.accessControlFacet;
        cfg.accessControlFacet = address(0);
        vm.expectRevert(DiamondInit.CoreFacetTopologyMismatch.selector);
        init.exposedRequireTopology(cfg);
        cfg.accessControlFacet = accessFacet;

        bytes4[] memory extra = new bytes4[](1);
        extra[0] = bytes4(0xfeedbeef);
        init.seedGroup(address(0xE11), extra);
        vm.expectRevert(DiamondInit.CoreFacetTopologyMismatch.selector);
        init.exposedRequireTopology(cfg);
    }

    function _topologyConfig() private pure returns (DiamondInit.InitConfig memory cfg) {
        cfg.accessControlFacet = address(0x101);
        cfg.pausableFacet = address(0x102);
        cfg.tokenFacet = address(0x103);
        cfg.initFacet = address(0x104);
        cfg.issuanceFacet = address(0x105);
        cfg.redemptionFacet = address(0x106);
        cfg.rebalanceFacet = address(0x107);
        cfg.previewFacet = address(0x108);
        cfg.basketAdminFacet = address(0x109);
        cfg.configFacet = address(0x10A);
        cfg.lensFacet = address(0x10B);
        cfg.reserveLifecycleFacet = address(0x10C);
        cfg.recoveryShareFacet = address(0x10D);
        cfg.recoveryShareMetadataFacet = address(0x10E);
        cfg.recoveryAdminFacet = address(0x10F);
        cfg.recoveryPoolSettlementFacet = address(0x110);
    }

    function _seedTopology(CoreDiamondInitHarness init, DiamondInit.InitConfig memory cfg) private {
        init.seedGroup(address(0xC01), SharedFacetSelectors.cutSelectors());
        init.seedGroup(address(0xC02), SharedFacetSelectors.loupeSelectors());
        init.seedGroup(cfg.accessControlFacet, SharedFacetSelectors.defaultAdminAccessSelectors());
        init.seedGroup(cfg.pausableFacet, SharedFacetSelectors.pauseSelectors());
        init.seedGroup(cfg.tokenFacet, FacetSelectors.tokenSelectors());
        init.seedGroup(cfg.issuanceFacet, FacetSelectors.issuanceSelectors());
        init.seedGroup(cfg.redemptionFacet, FacetSelectors.redemptionSelectors());
        init.seedGroup(cfg.rebalanceFacet, FacetSelectors.rebalanceSelectors());
        init.seedGroup(cfg.previewFacet, FacetSelectors.previewSelectors());
        init.seedGroup(cfg.basketAdminFacet, FacetSelectors.basketAdminSelectors());
        init.seedGroup(cfg.configFacet, FacetSelectors.configSelectors());
        init.seedGroup(cfg.lensFacet, FacetSelectors.lensSelectors());
        init.seedGroup(cfg.reserveLifecycleFacet, FacetSelectors.reserveLifecycleSelectors());
        init.seedGroup(cfg.recoveryShareFacet, FacetSelectors.recoveryShareSelectors());
        init.seedGroup(cfg.recoveryShareMetadataFacet, FacetSelectors.recoveryShareMetadataSelectors());
        init.seedGroup(cfg.recoveryAdminFacet, FacetSelectors.recoveryAdminSelectors());
        init.seedGroup(cfg.recoveryPoolSettlementFacet, FacetSelectors.recoveryPoolSettlementSelectors());
    }
}

contract EmptyRevertInitFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.basket.test.empty-revert");
    uint64 public constant FACET_VERSION = 1;

    receive() external payable {
        assembly {
            revert(0, 0)
        }
    }

    fallback() external payable {
        assembly {
            revert(0, 0)
        }
    }
}

contract CoreVersionedInitFacet {
    bytes32 public immutable FACET_NAMESPACE;
    uint64 public immutable FACET_VERSION;

    constructor(bytes32 namespace, uint64 version) {
        FACET_NAMESPACE = namespace;
        FACET_VERSION = version;
    }

    fallback() external {}
}

contract CoreDiamondInitHarness is DiamondInit {
    function exposedDelegate(address target, bytes calldata data) external {
        _delegateInit(target, data);
    }

    function exposedRegisterCut() external {
        _registerInstalledCutFacetVersion();
    }

    function exposedRegisterLaunch(address target) external {
        _checkAndSetLaunchFacetVersion(target);
    }

    function exposedRequireTopology(InitConfig calldata cfg) external view {
        _requireProductionFacetTopology(cfg);
    }

    function seedGroup(address facet, bytes4[] calldata selectors) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        for (uint256 i; i < selectors.length; ++i) {
            if (ds.facetAddressAndSelectorPosition[selectors[i]].facetAddress == address(0)) {
                ds.selectors.push(selectors[i]);
            }
            ds.facetAddressAndSelectorPosition[selectors[i]].facetAddress = facet;
        }
    }

    function overwriteOwner(bytes4 selector, address facet) external {
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress = facet;
    }

    function selectorCount() external view returns (uint256) {
        return LibDiamond.diamondStorage().selectors.length;
    }
}
