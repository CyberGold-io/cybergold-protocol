// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";

import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {StakingDiamond} from "../../src/diamond/StakingDiamond.sol";
import {
    DiamondCutAccessLiveFacet as DiamondCutAccessFacet
} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {ReentrancyGuardFacet} from "diamond-infra/facets/ReentrancyGuardFacet.sol";
import {CustodyFacet} from "../../src/facets/CustodyFacet.sol";
import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";
import {SleeveDeployerHelper} from "../../src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "../../src/deploy/SleeveRequestBuilder.sol";

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {FacetSelectors as SharedFacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";

contract CustodyFacetTest is Test {
    MockERC20 internal token;

    StakingDiamond internal diamond;
    DiamondCutAccessFacet internal cutFacet;
    DiamondLoupeFacet internal loupeFacet;
    DefaultAdminAccessControlFacet internal accessFacet;
    PausableFacet internal pauseFacet;
    ReentrancyGuardFacet internal reentrancyFacet;
    CustodyFacet internal custodyFacet;
    address internal safeWallet;

    address internal admin = address(0xA11CE);
    address internal pauser = address(0xBEEF);
    address internal withdrawer = address(0xCAFE);
    address internal user = address(0xD00D);

    function setUp() public {
        token = new MockERC20("Mock", "MOCK", 18);
        vm.etch(admin, hex"00");
        address[] memory withdrawers = new address[](1);
        withdrawers[0] = withdrawer;
        safeWallet = MockSafeWalletFactory.deploy(pauser);
        DeploymentTypes.DeployConfig memory cfg;
        cfg.safeWallet = safeWallet;
        cfg.name = "Staked Mock";
        cfg.symbol = "sMOCK";
        cfg.coreDiamond = address(token);
        cfg.governanceDiamond = admin;
        cfg.withdrawers = withdrawers;
        cfg.allocators = new address[](1);
        cfg.allocators[0] = admin;
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(token), false, 0);
        cfg.create2Deployer = address(this);
        cfg.shellSalt = keccak256("CustodyFacetTest");
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.prepare(cfg);
        art = DeploymentHelper.deployCommittedShellLocal(cfg, art);
        art = DeploymentHelper.finalizeCommitted(cfg, art);
        diamond = art.diamond;
        cutFacet = art.facets.cut;
        loupeFacet = art.facets.loupe;
        accessFacet = art.facets.access;
        pauseFacet = art.facets.pause;
        reentrancyFacet = art.facets.reentrancy;
        custodyFacet = art.facets.custody;

        vm.prank(safeWallet);
        PausableFacet(address(diamond)).unpause();

        token.mint(address(diamond), 1_000 ether);
    }

    function testRolesSeeded() public view {
        CustodyFacet custody = CustodyFacet(address(diamond));
        assertTrue(custody.hasRole(custody.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(custody.hasRole(custody.WITHDRAWER_ROLE(), withdrawer));
        assertTrue(PausableFacet(address(diamond)).canPause(pauser));
    }

    function testWithdrawerCanTransfer() public {
        CustodyFacet custody = CustodyFacet(address(diamond));
        uint256 balBefore = token.balanceOf(user);
        vm.prank(withdrawer);
        custody.transferTo(address(token), user, 200 ether);
        assertEq(token.balanceOf(user) - balBefore, 200 ether);
    }

    function testTransferWhenPausedReverts() public {
        CustodyFacet custody = CustodyFacet(address(diamond));
        vm.prank(pauser);
        PausableFacet(address(diamond)).pause();

        vm.prank(withdrawer);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        custody.transferTo(address(token), user, 1 ether);
    }

    function testPauseOnlySafeOwnerUnpauseOnlySafeWallet() public {
        CustodyFacet custody = CustodyFacet(address(diamond));
        PausableFacet pause = PausableFacet(address(diamond));

        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, user));
        vm.prank(user);
        pause.pause();

        vm.prank(pauser);
        pause.pause();
        assertTrue(custody.paused());

        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, user));
        vm.prank(user);
        pause.unpause();

        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, pauser));
        vm.prank(pauser);
        pause.unpause();

        vm.prank(pause.safeWallet());
        pause.unpause();
        assertFalse(custody.paused());
    }

    function testTransferZeroAmountNoop() public {
        CustodyFacet custody = CustodyFacet(address(diamond));
        vm.prank(withdrawer);
        custody.transferTo(address(token), user, 0);
        assertEq(token.balanceOf(user), 0);
    }

    function testTransferZeroAddressReverts() public {
        CustodyFacet custody = CustodyFacet(address(diamond));
        vm.prank(withdrawer);
        vm.expectRevert(CustodyFacet.ZeroAddress.selector);
        custody.transferTo(address(0), user, 1);
        vm.prank(withdrawer);
        vm.expectRevert(CustodyFacet.ZeroAddress.selector);
        custody.transferTo(address(token), address(0), 1);
    }

    function testCustodyBalance() public view {
        CustodyFacet custody = CustodyFacet(address(diamond));
        assertEq(custody.custodyBalance(address(token)), token.balanceOf(address(diamond)));
    }

    function testSupportsInterface() public view {
        assertTrue(custodyFacet.supportsInterface(type(IERC165).interfaceId));
    }

    // ----- Selector helpers -----
    function cutSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
    }

    function loupeSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
        selectors[4] = IERC165.supportsInterface.selector;
    }

    function accessSelectors() internal pure returns (bytes4[] memory selectors) {
        return SharedFacetSelectors.accessSelectors();
    }

    function pauseSelectors() internal pure returns (bytes4[] memory selectors) {
        return SharedFacetSelectors.pauseSelectors();
    }

    function reentrancySelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = ReentrancyGuardFacet.initReentrancyGuard.selector;
    }

    function custodySelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = CustodyFacet.initCustody.selector;
        selectors[1] = CustodyFacet.transferTo.selector;
        selectors[2] = CustodyFacet.custodyBalance.selector;
        selectors[3] = bytes4(keccak256("WITHDRAWER_ROLE()"));
    }
}
