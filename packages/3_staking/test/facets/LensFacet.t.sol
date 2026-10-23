// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";

import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {StakingDiamond} from "../../src/diamond/StakingDiamond.sol";
import {
    DiamondCutAccessLiveFacet as DiamondCutAccessFacet
} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {ReentrancyGuardFacet} from "diamond-infra/facets/ReentrancyGuardFacet.sol";
import {TokenFacet} from "../../src/facets/TokenFacet.sol";
import {VaultFacet} from "../../src/facets/VaultFacet.sol";
import {QueueFacet} from "../../src/facets/QueueFacet.sol";
import {QueueOperatorFacet} from "../../src/facets/QueueOperatorFacet.sol";
import {QueueSigFacet} from "../../src/facets/QueueSigFacet.sol";
import {CustodyFacet} from "../../src/facets/CustodyFacet.sol";
import {SleeveRegistryFacet} from "../../src/facets/SleeveRegistryFacet.sol";
import {FundManagerFacet} from "../../src/facets/FundManagerFacet.sol";
import {LensFacet} from "../../src/facets/LensFacet.sol";
import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";
import {SleeveDeployerHelper} from "../../src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "../../src/deploy/SleeveRequestBuilder.sol";
import {FacetSelectors} from "../../src/deploy/FacetSelectors.sol";
import {FacetSelectors as SharedFacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {MockCyberGold} from "staking-mocks/MockCyberGold.sol";

contract LensFacetTest is Test {
    StakingDiamond internal diamond;
    DiamondCutAccessFacet internal cutFacet;
    DiamondLoupeFacet internal loupeFacet;
    DefaultAdminAccessControlFacet internal accessFacet;
    PausableFacet internal pauseFacet;
    ReentrancyGuardFacet internal reentrancyFacet;
    TokenFacet internal tokenFacet;
    VaultFacet internal vaultFacet;
    QueueFacet internal queueFacet;
    QueueOperatorFacet internal queueOperatorFacet;
    QueueSigFacet internal queueSigFacet;
    CustodyFacet internal custodyFacet;
    SleeveRegistryFacet internal registryFacet;
    FundManagerFacet internal fundFacet;
    LensFacet internal lensFacet;

    MockERC20 internal asset;
    MockCyberGold internal cygld;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockSleeve internal sleeveCygld;

    address internal admin = address(this);
    address internal pauser = address(0xBEEF);
    address internal allocator = address(0xA11CE);
    address internal treasury;
    address internal user = address(0xCAFE);

    function setUp() public {
        asset = new MockERC20("Underlying", "UND", 18);
        cygld = new MockCyberGold();
        treasury = address(this);
        address safeWallet = MockSafeWalletFactory.deploy(pauser);
        DeploymentTypes.DeployConfig memory cfg;
        cfg.safeWallet = safeWallet;
        cfg.name = "Wrapped Staked CYGLD";
        cfg.symbol = "wstCYGLD";
        cfg.coreDiamond = address(cygld);
        cfg.governanceDiamond = treasury;
        cfg.withdrawers = new address[](0);
        cfg.allocators = new address[](1);
        cfg.allocators[0] = allocator;
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(cygld), true, 0);
        cfg.claimExpiry = 1 days;
        cfg.headSweepLimit = 5;
        cfg.autoProcessMax = 5;
        cfg.performanceFeePpm = 30_000;
        cfg.create2Deployer = address(this);
        cfg.shellSalt = keccak256("LensFacetTest");
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.prepare(cfg);
        art = DeploymentHelper.deployCommittedShellLocal(cfg, art);
        art = DeploymentHelper.finalizeCommitted(cfg, art);
        diamond = art.diamond;
        cutFacet = art.facets.cut;
        loupeFacet = art.facets.loupe;
        accessFacet = art.facets.access;
        pauseFacet = art.facets.pause;
        reentrancyFacet = art.facets.reentrancy;
        tokenFacet = art.facets.token;
        vaultFacet = art.facets.vault;
        queueFacet = art.facets.queue;
        queueOperatorFacet = art.facets.queueOperator;
        queueSigFacet = art.facets.queueSig;
        custodyFacet = art.facets.custody;
        registryFacet = art.facets.sleeveRegistry;
        fundFacet = art.facets.fundManager;
        lensFacet = art.facets.lens;
        sleeveCygld = MockSleeve(art.sleeves[0].sleeve);
        vm.prank(safeWallet);
        PausableFacet(address(diamond)).unpause();

        cygld.mint(user, 1_000 ether);
        vm.prank(user);
        cygld.approve(address(diamond), type(uint256).max);
    }

    function test_systemState() public view {
        LensFacet.SystemState memory s = LensFacet(address(diamond)).systemState();
        assertEq(s.asset, address(cygld));
        assertTrue(s.fundManagerHealthy);
        assertFalse(s.paused);
    }

    function test_queueRequestsView() public {
        VaultFacet vault = VaultFacet(address(diamond));
        QueueFacet queue = QueueFacet(address(diamond));

        vm.prank(user);
        vault.deposit(100 ether, user);

        vm.prank(user);
        uint256 reqId = queue.requestRedeem(40 ether, user, user);

        LensFacet.QueueRequestView[] memory views = LensFacet(address(diamond)).queueRequests(user);
        assertEq(views.length, 1);
        assertEq(views[0].id, reqId);
        assertEq(views[0].controller, user);
        assertEq(views[0].owner, user);
        assertEq(views[0].shares, 40 ether);
        assertEq(views[0].readyAt, LensFacet(address(diamond)).readyAtFor(reqId));
    }

    function test_sleevePositionsView() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        // allocate to sleeve CYGLD
        cygld.mint(address(diamond), 200 ether);
        cygld.mint(address(0xB0B1), 400 ether);
        // Raise staker ratio so allocation headroom is sufficient.
        cygld.mint(address(diamond), 1_600 ether);

        vm.prank(allocator);
        manager.allocate(address(sleeveCygld), 150 ether, "");

        cygld.mint(address(this), 20 ether);
        cygld.approve(address(sleeveCygld), 20 ether);
        sleeveCygld.donate(20 ether);

        LensFacet.SleevePosition[] memory positions = LensFacet(address(diamond)).sleevePositions();
        assertEq(positions.length, 1);
        assertEq(positions[0].sleeve, address(sleeveCygld));
        assertEq(positions[0].asset, address(cygld));
        assertEq(positions[0].principalAssets, 150 ether);
        assertEq(positions[0].totalAssets, 170 ether);
        assertTrue(positions[0].approved);
        assertEq(positions[0].pnl, int256(20 ether));
    }

    function test_queueAggregatesScalarsPaginationAndReadyEpochSearch() public {
        VaultFacet vault = VaultFacet(address(diamond));
        QueueFacet queue = QueueFacet(address(diamond));
        LensFacet lens = LensFacet(address(diamond));

        vm.prank(user);
        vault.deposit(200 ether, user);

        vm.prank(user);
        uint256 firstId = queue.requestRedeem(40 ether, user, user);

        vm.warp(block.timestamp + 1);
        vm.prank(user);
        uint256 secondId = queue.requestRedeem(30 ether, user, user);

        LensFacet.QueueAggregates memory agg = lens.queueAggregates(user);
        assertEq(agg.headId, firstId);
        assertEq(agg.tailId, secondId);
        assertEq(agg.readyBoundaryId, secondId);
        assertEq(agg.claimExpiry, 1 days);
        assertEq(agg.headSweepLimit, 5);
        assertEq(agg.autoProcessMax, 5);
        assertEq(agg.seqInBlock, 0);
        assertEq(agg.claimableController, 70 ether);
        assertEq(agg.claimableTotal, 70 ether);

        assertEq(lens.headId(), firstId);
        assertEq(lens.tailId(), secondId);
        assertEq(lens.readyBoundaryId(), secondId);
        assertEq(lens.claimExpiry(), 1 days);
        assertEq(lens.headSweepLimit(), 5);
        assertEq(lens.autoProcessMax(), 5);
        assertEq(lens.seqInBlock(), 0);
        assertEq(lens.claimableShares(user), 70 ether);
        assertEq(lens.claimableSharesTotal(), 70 ether);
        // casting to uint64 is safe because queue ids encode the creation timestamp in the upper 64 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(lens.createdAt(firstId), uint64(firstId >> 64));
        assertEq(lens.claimableRedeemRequest(firstId, user), 0);

        uint256[] memory allIds = lens.controllerOpenQueries(user);
        assertEq(allIds.length, 2);
        assertEq(allIds[0], firstId);
        assertEq(allIds[1], secondId);

        (uint256[] memory page, uint256 total, uint256 nextStart) = lens.controllerOpenQueries(user, 1, 10);
        assertEq(total, 2);
        assertEq(page.length, 1);
        assertEq(page[0], secondId);
        assertEq(nextStart, 2);

        (uint256[] memory emptyPage, uint256 emptyTotal, uint256 emptyNext) = lens.controllerOpenQueries(user, 2, 10);
        assertEq(emptyTotal, 2);
        assertEq(emptyPage.length, 0);
        assertEq(emptyNext, 2);

        assertGt(lens.readyAtFor(secondId), lens.readyAtFor(firstId));
        assertEq(lens.readyAtFor(type(uint256).max), 0);
    }

    function test_sleevePositionsViewReportsNegativePnl() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        cygld.mint(address(diamond), 1_000 ether);
        cygld.mint(address(0xB0B1), 1_000 ether);

        vm.prank(allocator);
        manager.allocate(address(sleeveCygld), 150 ether, "");

        vm.prank(address(sleeveCygld));
        assertTrue(cygld.transfer(address(0xDEAD), 70 ether));

        LensFacet.SleevePosition[] memory positions = LensFacet(address(diamond)).sleevePositions();
        assertEq(positions.length, 1);
        assertEq(positions[0].principalAssets, 150 ether);
        assertEq(positions[0].totalAssets, 80 ether);
        assertEq(positions[0].pnl, -int256(70 ether));
    }

    // ----- Helpers -----

    function _deploySleeve(address assetAddr) internal returns (MockSleeve proxy) {
        MockSleeve implementation = new MockSleeve();
        proxy = MockSleeve(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(MockSleeve.initialize, (address(diamond), assetAddr, 0))
                )
            )
        );
    }

    function _registry() internal view returns (SleeveRegistryFacet) {
        return SleeveRegistryFacet(address(diamond));
    }

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

    function tokenSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = TokenFacet.initToken.selector;
        selectors[1] = bytes4(keccak256("share()"));
    }

    function vaultSelectors() internal pure returns (bytes4[] memory selectors) {
        return FacetSelectors.vaultSelectors();
    }

    function queueSelectors() internal pure returns (bytes4[] memory selectors) {
        return FacetSelectors.queueSelectors();
    }

    function queueOperatorSelectors() internal pure returns (bytes4[] memory selectors) {
        return FacetSelectors.queueOperatorSelectors();
    }

    function queueSigSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = QueueSigFacet.DOMAIN_SEPARATOR.selector;
        selectors[1] = QueueSigFacet.nonces.selector;
        selectors[2] = QueueSigFacet.requestRedeemBySig.selector;
    }

    function custodySelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = CustodyFacet.initCustody.selector;
        selectors[1] = CustodyFacet.transferTo.selector;
        selectors[2] = CustodyFacet.custodyBalance.selector;
        selectors[3] = bytes4(keccak256("WITHDRAWER_ROLE()"));
    }

    function registrySelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = SleeveRegistryFacet.registerSleeve.selector;
        selectors[1] = SleeveRegistryFacet.setSleeveApproval.selector;
        selectors[2] = SleeveRegistryFacet.sleeveConfig.selector;
        selectors[3] = SleeveRegistryFacet.sleeves.selector;
        selectors[4] = SleeveRegistryFacet.stakerAssetsInSleeves.selector;
    }

    function fundSelectors() internal pure returns (bytes4[] memory selectors) {
        return FacetSelectors.fundSelectors();
    }

    function lensSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](21);
        selectors[0] = LensFacet.systemState.selector;
        selectors[1] = LensFacet.queueAggregates.selector;
        selectors[2] = bytes4(keccak256("controllerOpenQueries(address)"));
        selectors[3] = bytes4(keccak256("controllerOpenQueries(address,uint256,uint256)"));
        selectors[4] = LensFacet.readyAtFor.selector;
        selectors[5] = LensFacet.createdAt.selector;
        selectors[6] = LensFacet.isReady.selector;
        selectors[7] = LensFacet.isExpired.selector;
        selectors[8] = LensFacet.claimableSharesTotal.selector;
        selectors[9] = LensFacet.claimableShares.selector;
        selectors[10] = LensFacet.headId.selector;
        selectors[11] = LensFacet.tailId.selector;
        selectors[12] = LensFacet.readyBoundaryId.selector;
        selectors[13] = LensFacet.claimExpiry.selector;
        selectors[14] = LensFacet.headSweepLimit.selector;
        selectors[15] = LensFacet.autoProcessMax.selector;
        selectors[16] = LensFacet.seqInBlock.selector;
        selectors[17] = LensFacet.claimableRedeemRequest.selector;
        selectors[18] = LensFacet.viewRequest.selector;
        selectors[19] = LensFacet.queueRequests.selector;
        selectors[20] = LensFacet.sleevePositions.selector;
    }
}
