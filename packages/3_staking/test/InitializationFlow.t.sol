// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";

import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {
    DiamondCutAccessLiveFacet as DiamondCutAccessFacet
} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {StakingDiamond} from "../src/diamond/StakingDiamond.sol";
import {FunctionNotFound} from "diamond-infra/diamond/ProtocolDiamond.sol";
import {LiveFacetVersionRegistry} from "diamond-infra/helpers/LiveFacetVersionRegistry.sol";
import {LiveValidatedDiamondCut} from "diamond-infra/helpers/LiveValidatedDiamondCut.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {StakingTestDeployer} from "./helpers/StakingTestDeployer.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {SleeveDeployerHelper} from "../src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "../src/deploy/SleeveRequestBuilder.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";

import {StakingInitV2} from "./helpers/StakingInitV2.sol";
import {AccessControlFacetV2} from "./helpers/AccessControlFacetV2.sol";
import {NoVersionFacet} from "./helpers/NoVersionFacet.sol";

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";

contract InitializationFlowTest is Test {
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    address internal admin;

    StakingDiamond internal diamond;
    DiamondCutAccessFacet internal cutFacet;
    DiamondLoupeFacet internal loupeFacet;
    DefaultAdminAccessControlFacet internal accessFacet;

    function setUp() public {
        admin = address(this);
        MockERC20 core = new MockERC20("CyberGold", "CYGLD", 18);
        DeploymentTypes.DeployConfig memory cfg;
        cfg.safeWallet = MockSafeWalletFactory.deploy(address(0x5AFE));
        cfg.name = "Staked CyberGold";
        cfg.symbol = "sCYGLD";
        cfg.coreDiamond = address(core);
        cfg.governanceDiamond = admin;
        cfg.withdrawers = new address[](0);
        cfg.allocators = new address[](1);
        cfg.allocators[0] = admin;
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(core), false, 0);
        cfg.create2Deployer = address(this);
        cfg.shellSalt = keccak256("InitializationFlowTest");

        DeploymentTypes.DeployArtifacts memory art = StakingTestDeployer.deploy(cfg);
        diamond = art.diamond;
        cutFacet = art.facets.cut;
        loupeFacet = art.facets.loupe;
        accessFacet = art.facets.access;
    }

    function testInitializerOnlyCallDoesNotAdvanceFacetGeneration() public {
        StakingInitV2 initV2 = new StakingInitV2();
        AccessControlFacetV2 acV2 = new AccessControlFacetV2();

        assertEq(acV2.FACET_NAMESPACE(), accessFacet.FACET_NAMESPACE());
        assertEq(_registeredGeneration(acV2.FACET_NAMESPACE()), 1);
        vm.prank(admin);
        IDiamondCut(address(diamond))
            .diamondCut(
                new IDiamondCut.FacetCut[](0), address(initV2), abi.encodeCall(StakingInitV2.init, (address(acV2)))
            );
        assertEq(_registeredGeneration(acV2.FACET_NAMESPACE()), 1);
    }

    function testAddOnlyUpgradeOfInstalledNamespaceRejectsPartialTransition() public {
        AccessControlFacetV2 acV2 = new AccessControlFacetV2();
        StakingInitV2 initV2 = new StakingInitV2();

        assertEq(acV2.FACET_NAMESPACE(), accessFacet.FACET_NAMESPACE());
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(acV2), action: IDiamond.FacetCutAction.Add, functionSelectors: markerSelectors()
        });

        vm.expectPartialRevert(
            LiveValidatedDiamondCut.DiamondCutPartialFacetNamespaceTransition.selector
        );
        vm.prank(admin);
        IDiamondCut(address(diamond))
            .diamondCut(cut, address(initV2), abi.encodeCall(StakingInitV2.init, (address(acV2))));

        vm.expectRevert(
            abi.encodeWithSelector(FunctionNotFound.selector, AccessControlFacetV2.marker.selector)
        );
        AccessControlFacetV2(address(diamond)).marker();
    }

    function testTopologyOnlyAddToInstalledFacetKeepsGeneration() public {
        StakingInitV2 initV2 = new StakingInitV2();
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(accessFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: markerSelectors()
        });
        vm.startPrank(admin);
        IDiamondCut(address(diamond))
            .diamondCut(
                cut, address(initV2), abi.encodeCall(StakingInitV2.init, (address(accessFacet)))
            );
        vm.stopPrank();
        assertEq(_registeredGeneration(accessFacet.FACET_NAMESPACE()), 1);
        assertEq(IDiamondLoupe(address(diamond)).facetAddress(AccessControlFacetV2.marker.selector), address(accessFacet));
    }

    function testInitFailsWhenFacetMissingNamespaceInfo() public {
        NoVersionFacet invalid = new NoVersionFacet();
        StakingInitV2 initV2 = new StakingInitV2();
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = NoVersionFacet.init.selector;
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(invalid),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: selectors
        });

        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(LiveFacetVersionRegistry.FacetNamespaceProbeFailed.selector, address(invalid))
        );
        IDiamondCut(address(diamond))
            .diamondCut(cut, address(initV2), abi.encodeCall(StakingInitV2.init, (address(invalid))));
        vm.stopPrank();
    }

    function markerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = AccessControlFacetV2.marker.selector;
    }

    function _registeredGeneration(bytes32 namespace) internal view returns (uint64) {
        bytes32 slot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
        return uint64(uint256(vm.load(address(diamond), slot)));
    }
}
