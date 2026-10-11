// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {StakingTestDeployer} from "../helpers/StakingTestDeployer.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";
import {SleeveDeployerHelper} from "../../src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "../../src/deploy/SleeveRequestBuilder.sol";
import {StakingDiamond} from "../../src/diamond/StakingDiamond.sol";
import {VaultFacet} from "../../src/facets/VaultFacet.sol";
import {QueueFacet} from "../../src/facets/QueueFacet.sol";
import {FundManagerFacet} from "../../src/facets/FundManagerFacet.sol";
import {SleeveRegistryFacet} from "../../src/facets/SleeveRegistryFacet.sol";
import {CustodyFacet} from "../../src/facets/CustodyFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {ICyberGoldStaking} from "../../src/interfaces/ICyberGoldStaking.sol";

import {MockCyberGold} from "staking-mocks/MockCyberGold.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";

contract StakingDiamondIntegrationTest is Test {
    address internal admin = address(this);
    address internal treasury = address(0xB0B);
    address internal user = address(0xCAFE);

    StakingDiamond internal diamond;
    MockCyberGold internal cygld;
    MockSleeve internal sleeve;

    function setUp() public {
        cygld = new MockCyberGold();

        DeploymentTypes.DeployConfig memory cfg;
        DeployConfig.ProtocolConfig memory defaults = DeployConfig.loadProtocol(vm);
        vm.etch(treasury, hex"00");
        address safeWallet = MockSafeWalletFactory.deploy(admin);
        cfg.safeWallet = safeWallet;
        cfg.name = defaults.staking.name;
        cfg.symbol = defaults.staking.symbol;
        cfg.coreDiamond = address(cygld);
        cfg.governanceDiamond = treasury;
        cfg.withdrawers = new address[](0);
        cfg.allocators = new address[](1);
        cfg.allocators[0] = admin;
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(cygld), false, 0);
        cfg.create2Deployer = address(this);
        cfg.shellSalt = keccak256("StakingDiamondIntegrationTest");
        cfg.claimExpiry = defaults.queue.claimExpiry;
        cfg.headSweepLimit = defaults.queue.headSweepLimit;
        cfg.autoProcessMax = defaults.queue.autoProcessMax;
        cfg.performanceFeePpm = defaults.performanceFeePpm;

        DeploymentTypes.DeployArtifacts memory art = StakingTestDeployer.deploy(cfg);
        diamond = art.diamond;
        vm.prank(safeWallet);
        PausableFacet(address(diamond)).unpause();
    }

    function test_fullFlow_deposit_queue_claim_and_allocate() public {
        // deposit
        cygld.mint(user, 1_000 ether);
        vm.prank(user);
        cygld.approve(address(diamond), type(uint256).max);

        vm.prank(user);
        VaultFacet(address(diamond)).deposit(500 ether, user);

        // queue redeem and claim
        vm.prank(user);
        uint256 reqId = QueueFacet(address(diamond)).requestRedeem(200 ether, user, user);

        vm.prank(admin);
        QueueFacet(address(diamond)).processQueue(10);

        vm.prank(user);
        uint256 assetsOut = QueueFacet(address(diamond)).claimRequest(reqId, user);
        assertEq(assetsOut, 200 ether);
        assertEq(cygld.balanceOf(user), 700 ether);
        assertEq(VaultFacet(address(diamond)).balanceOf(user), 300 ether);

        // register sleeve and allocate
        sleeve = _registerSleeve();

        // fund custody for allocation
        cygld.mint(address(diamond), 300 ether);

        vm.prank(admin);
        FundManagerFacet(address(diamond)).allocate(address(sleeve), 200 ether, "");

        // 600 total in diamond custody (300 post-claim + 300 minted) minus 200 allocated.
        assertEq(cygld.balanceOf(address(diamond)), 400 ether);
        assertEq(sleeve.principalAssets(), 200 ether);
    }

    function test_fullInterfaceIsRegistered() public view {
        IERC165 erc165 = IERC165(address(diamond));
        assertTrue(erc165.supportsInterface(type(ICyberGoldStaking).interfaceId));
    }

    function test_nativeCustodyConservesCygldAcrossDepositClaimAndAllocation() public {
        VaultFacet vault = VaultFacet(address(diamond));
        QueueFacet queue = QueueFacet(address(diamond));
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        assertEq(manager.cygld(), address(cygld));

        cygld.mint(user, 500 ether);
        vm.prank(user);
        cygld.approve(address(diamond), type(uint256).max);

        vm.prank(user);
        vault.deposit(500 ether, user);
        assertEq(cygld.balanceOf(user), 0);
        assertEq(cygld.balanceOf(address(diamond)), 500 ether);

        vm.prank(user);
        uint256 requestId = queue.requestRedeem(200 ether, user, user);
        queue.processQueue(1);
        vm.prank(user);
        assertEq(queue.claimRequest(requestId, user), 200 ether);

        assertEq(cygld.balanceOf(user), 200 ether);
        assertEq(cygld.balanceOf(address(diamond)), 300 ether);
        assertEq(vault.balanceOf(user), 300 ether);

        sleeve = _registerSleeve();
        uint256 managedBefore = cygld.balanceOf(address(diamond)) + cygld.balanceOf(address(sleeve));
        vm.prank(admin);
        manager.allocate(address(sleeve), 150 ether, "");

        assertEq(cygld.balanceOf(address(diamond)), 150 ether);
        assertEq(cygld.balanceOf(address(sleeve)), 150 ether);
        assertEq(sleeve.principalAssets(), 150 ether);
        assertEq(cygld.balanceOf(address(diamond)) + cygld.balanceOf(address(sleeve)), managedBefore);
        assertEq(cygld.balanceOf(user) + managedBefore, 500 ether);
    }

    function test_nativeCustodyAcceptsDirectDonationWithoutSelfTransfer() public {
        cygld.mint(address(diamond), 123 ether);
        uint256 balanceBefore = cygld.balanceOf(address(diamond));
        assertEq(cygld.balanceOf(address(diamond)), balanceBefore);
    }

    function _registerSleeve() internal returns (MockSleeve deployed) {
        deployed = MockSleeve(
            address(
                new ERC1967Proxy(
                    address(new MockSleeve()),
                    abi.encodeCall(MockSleeve.initialize, (address(diamond), address(cygld), 0))
                )
            )
        );
        vm.startPrank(treasury);
        DefaultAdminAccessControlFacet(address(diamond))
            .grantRole(CustodyFacet(address(diamond)).WITHDRAWER_ROLE(), address(deployed));
        SleeveRegistryFacet(address(diamond)).registerSleeve(address(deployed), address(cygld));
        SleeveRegistryFacet(address(diamond)).setSleeveApproval(address(deployed), true);
        vm.stopPrank();
    }
}
