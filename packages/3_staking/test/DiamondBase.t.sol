// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {StakingDiamond} from "../src/diamond/StakingDiamond.sol";
import {
    DiamondCutAccessLiveFacet as DiamondCutAccessFacet
} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {StakingTestDeployer} from "./helpers/StakingTestDeployer.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {SleeveDeployerHelper} from "../src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "../src/deploy/SleeveRequestBuilder.sol";

import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlDefaultAdminRules} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {ICyberGoldStaking} from "../src/interfaces/ICyberGoldStaking.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";

contract DiamondBaseTest is Test {
    address internal owner = address(0xA11CE);
    address internal user = address(0xBEEF);

    StakingDiamond internal diamond;
    DiamondCutAccessFacet internal cutFacet;
    DiamondLoupeFacet internal loupeFacet;
    DefaultAdminAccessControlFacet internal accessFacet;
    address internal safeWallet;

    function setUp() public {
        MockERC20 core = new MockERC20("CyberGold", "CYGLD", 18);
        safeWallet = MockSafeWalletFactory.deploy(owner);
        DeploymentTypes.DeployConfig memory cfg;
        cfg.safeWallet = safeWallet;
        cfg.name = "Staked CyberGold";
        cfg.symbol = "sCYGLD";
        cfg.coreDiamond = address(core);
        cfg.governanceDiamond = address(this);
        cfg.withdrawers = new address[](0);
        cfg.allocators = new address[](1);
        cfg.allocators[0] = address(this);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(core), false, 0);
        cfg.create2Deployer = address(this);
        cfg.shellSalt = keccak256("DiamondBaseTest");

        DeploymentTypes.DeployArtifacts memory art = StakingTestDeployer.deploy(cfg);
        diamond = art.diamond;
        cutFacet = art.facets.cut;
        loupeFacet = art.facets.loupe;
        accessFacet = art.facets.access;
    }

    function testDiamondCutRequiresOwner() public {
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](0);
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, user, accessFacet.upgraderRole()
            )
        );
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
        vm.stopPrank();
    }

    function testLoupeListsFacetsAndSelectors() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));
        address[] memory facets = loupe.facetAddresses();
        assertGt(facets.length, 3);

        bytes4[] memory selectors = loupe.facetFunctionSelectors(address(cutFacet));
        assertEq(selectors.length, 2);
        assertEq(selectors[0], IDiamondCut.diamondCut.selector);
        assertEq(selectors[1], bytes4(keccak256("facetGeneration(bytes32)")));

        assertEq(loupe.facetAddress(IDiamondCut.diamondCut.selector), address(cutFacet));
        assertEq(
            DiamondCutAccessFacet(address(diamond)).facetGeneration(cutFacet.FACET_NAMESPACE()), 1
        );
        assertEq(loupe.facetAddress(IAccessControl.hasRole.selector), address(accessFacet));
    }

    function testSupportsInterfacesRegisteredInInit() public view {
        IERC165 erc165 = IERC165(address(diamond));
        assertTrue(erc165.supportsInterface(type(IERC165).interfaceId));
        assertTrue(erc165.supportsInterface(type(IDiamondCut).interfaceId));
        assertTrue(erc165.supportsInterface(type(IDiamondLoupe).interfaceId));
        // AccessControl emits ERC165 interface id via AccessControlEnumerableUpgradeable
        assertTrue(erc165.supportsInterface(type(IAccessControl).interfaceId));
        assertTrue(erc165.supportsInterface(type(IAccessControlDefaultAdminRules).interfaceId));
        assertTrue(erc165.supportsInterface(type(ICyberGoldStaking).interfaceId));
    }

    function testLaunchLeavesGovernanceAsSoleAdminAndSafeAsOnlyUnpauser() public view {
        DefaultAdminAccessControlFacet authority = DefaultAdminAccessControlFacet(address(diamond));
        assertEq(authority.defaultAdmin(), address(this));
        assertEq(authority.getRoleMemberCount(authority.DEFAULT_ADMIN_ROLE()), 1);
        assertEq(authority.getRoleMemberCount(authority.upgraderRole()), 1);
        assertTrue(authority.hasRole(authority.upgraderRole(), address(this)));
        PausableFacet pause = PausableFacet(address(diamond));
        assertTrue(pause.paused());
        assertTrue(pause.canPause(owner));
        assertTrue(pause.canUnpause(safeWallet));
        assertFalse(pause.canUnpause(owner));
    }
}
