// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {StakingDiamond} from "../../src/diamond/StakingDiamond.sol";
import {DiamondCutAccessLiveFacet as DiamondCutAccessFacet} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {ReentrancyGuardFacet} from "diamond-infra/facets/ReentrancyGuardFacet.sol";
import {CustodyFacet} from "../../src/facets/CustodyFacet.sol";
import {FundManagerFacet} from "../../src/facets/FundManagerFacet.sol";
import {SleeveRegistryFacet} from "../../src/facets/SleeveRegistryFacet.sol";
import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";
import {SleeveDeployerHelper} from "../../src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "../../src/deploy/SleeveRequestBuilder.sol";
import {FacetSelectors} from "../../src/deploy/FacetSelectors.sol";
import {FacetSelectors as SharedFacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";
import {LibAppStorage} from "../../src/diamond/LibAppStorage.sol";

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {SleeveBase} from "../../src/sleeves/SleeveBase.sol";
import {Sleeve4626} from "../../src/sleeves/Sleeve4626.sol";

import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {MockStakingVault} from "staking-mocks/MockStakingVault.sol";
import {MockSwapAdapter} from "staking-mocks/MockSwapAdapter.sol";
import {MockCyberGold} from "staking-mocks/MockCyberGold.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {MockVault4626} from "staking-mocks/MockVault4626.sol";
import {StakingInitV2} from "../helpers/StakingInitV2.sol";

contract FundManagerFacetTest is Test {
    uint256 private constant PPM_DENOMINATOR = 1_000_000;

    StakingDiamond internal diamond;
    DiamondCutAccessFacet internal cutFacet;
    DiamondLoupeFacet internal loupeFacet;
    DefaultAdminAccessControlFacet internal accessFacet;
    PausableFacet internal pauseFacet;
    ReentrancyGuardFacet internal reentrancyFacet;
    CustodyFacet internal custodyFacet;
    SleeveRegistryFacet internal sleeveFacet;
    FundManagerFacet internal fundFacet;

    CustodyFacet internal custody;
    MockStakingVault internal stakingVault;
    MockSwapAdapter internal swapAdapter;
    MockCyberGold internal cygld;

    MockERC20 internal assetA;
    MockERC20 internal assetB;

    MockSleeve internal sleeveAssetA;
    // forge-lint: disable-next-line(mixed-case-variable)
    MockSleeve internal sleeveCygld;

    address internal admin = address(this);
    address internal pauser = address(0xABC1);
    address internal allocator = address(0xABC2);
    address internal treasury;

    function setUp() public {
        cygld = new MockCyberGold();

        assetA = new MockERC20("AssetA", "AA", 18);
        assetB = new MockERC20("AssetB", "BB", 18);

        swapAdapter = new MockSwapAdapter();
        treasury = address(this);

        MockStakingVault stakingVaultFacet = new MockStakingVault();
        address safeWallet = MockSafeWalletFactory.deploy(pauser);
        DeploymentTypes.DeployConfig memory cfg;
        cfg.safeWallet = safeWallet;
        cfg.name = "Staked CyberGold";
        cfg.symbol = "sCYGLD";
        cfg.coreDiamond = address(cygld);
        cfg.governanceDiamond = treasury;
        cfg.withdrawers = new address[](0);
        cfg.allocators = new address[](1);
        cfg.allocators[0] = allocator;
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](2);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(assetA), false, 0);
        cfg.sleeves[1] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(cygld), false, 0);
        cfg.performanceFeePpm = 30_000;
        cfg.create2Deployer = address(this);
        cfg.shellSalt = keccak256("FundManagerFacetTest");
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
        sleeveFacet = art.facets.sleeveRegistry;
        fundFacet = art.facets.fundManager;
        custody = CustodyFacet(address(diamond));

        IDiamond.FacetCut[] memory mockVaultCut = new IDiamond.FacetCut[](2);
        bytes4[] memory addSelectors = new bytes4[](3);
        addSelectors[0] = MockStakingVault.setAsset.selector;
        addSelectors[1] = MockStakingVault.setTotalAssets.selector;
        addSelectors[2] = MockStakingVault.setClaimableAssets.selector;
        mockVaultCut[0] = IDiamond.FacetCut({
            facetAddress: address(stakingVaultFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: addSelectors
        });
        bytes4[] memory replaceSelectors = new bytes4[](3);
        replaceSelectors[0] = MockStakingVault.asset.selector;
        replaceSelectors[1] = MockStakingVault.totalAssets.selector;
        replaceSelectors[2] = MockStakingVault.liquidityBreakdown.selector;
        mockVaultCut[1] = IDiamond.FacetCut({
            facetAddress: address(stakingVaultFacet),
            action: IDiamond.FacetCutAction.Replace,
            functionSelectors: replaceSelectors
        });
        StakingInitV2 testInit = new StakingInitV2();
        IDiamondCut(address(diamond))
            .diamondCut(
                mockVaultCut, address(testInit), abi.encodeCall(StakingInitV2.init, (address(stakingVaultFacet)))
            );
        stakingVault = MockStakingVault(address(diamond));
        stakingVault.setAsset(address(cygld));
        vm.prank(safeWallet);
        PausableFacet(address(diamond)).unpause();

        address[] memory basket = new address[](1);
        basket[0] = address(assetA);
        cygld.setBasketAssets(basket);

        sleeveAssetA = MockSleeve(art.sleeves[0].sleeve);
        sleeveCygld = MockSleeve(art.sleeves[1].sleeve);
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_initialize_setsState() public view {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        assertEq(manager.cygld(), address(cygld));
        assertEq(address(stakingVault), address(diamond));
        assertEq(address(custody), address(diamond));
        assertEq(manager.treasury(), treasury);
        assertEq(manager.performanceFeePpm(), 30_000);

        LibAppStorage.SleeveConfig memory cfg = _sleeveConfig(address(sleeveAssetA));
        assertTrue(cfg.registered);
        assertEq(cfg.asset, address(assetA));
        assertEq(cfg.principalAssets, 0);
        assertFalse(cfg.approved);
    }

    function test_setPerformanceFee_onlyAdmin() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));

        vm.startPrank(allocator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, allocator, manager.DEFAULT_ADMIN_ROLE()
            )
        );
        manager.setPerformanceFee(30_000, 10_000);
        vm.stopPrank();

        manager.setPerformanceFee(30_000, 10_000);
        assertEq(manager.performanceFeePpm(), 10_000);
    }

    function test_setPerformanceFee_tooHigh_reverts() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        uint256 maxPerformanceFeePpm = manager.MAX_PERFORMANCE_FEE_PPM();
        assertEq(maxPerformanceFeePpm, 100_000);
        vm.expectRevert(FundManagerFacet.FeeTooHigh.selector);
        manager.setPerformanceFee(30_000, maxPerformanceFeePpm + 1);
    }

    function test_setPerformanceFee_rejectsNoopBeforeCurrentMismatch() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));

        vm.expectRevert(FundManagerFacet.PerformanceFeeChangeNoop.selector);
        manager.setPerformanceFee(29_999, 29_999);
    }

    function test_setPerformanceFee_rejectsCurrentMismatchBeforeFeeCap() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));

        vm.expectRevert(abi.encodeWithSelector(FundManagerFacet.PerformanceFeeCurrentMismatch.selector, 29_999, 30_000));
        manager.setPerformanceFee(29_999, 200_000);
    }

    function test_setTreasury_onlyAdmin() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        vm.startPrank(allocator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, allocator, manager.DEFAULT_ADMIN_ROLE()
            )
        );
        manager.setTreasury(address(0xDEF));
        vm.stopPrank();

        manager.setTreasury(address(0xDEF));
        assertEq(manager.treasury(), address(0xDEF));
    }

    function test_setTreasury_zero_reverts() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        vm.expectRevert(FundManagerFacet.ZeroAddress.selector);
        manager.setTreasury(address(0));
    }

    function test_setSwapAdapter_onlyAdmin() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        vm.startPrank(allocator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, allocator, manager.DEFAULT_ADMIN_ROLE()
            )
        );
        manager.setSwapAdapter(address(swapAdapter));
        vm.stopPrank();

        manager.setSwapAdapter(address(swapAdapter));
        assertEq(manager.swapAdapter(), address(swapAdapter));
    }

    function test_setSwapAdapter_zero_reverts() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        vm.expectRevert(FundManagerFacet.ZeroAddress.selector);
        manager.setSwapAdapter(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function test_stakerRatioFp18() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        stakingVault.setTotalAssets(100 ether);
        cygld.mint(address(0xB0B), 200 ether);
        assertEq(manager.stakerRatioFp18(), 5e17);
    }

    function test_investableFor_calculatesIdleMinusPrincipal() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        assetA.mint(address(custody), 1_000 ether);

        stakingVault.setTotalAssets(200 ether);
        cygld.mint(address(0xB0B), 400 ether);

        _registry().setSleeveApproval(address(sleeveAssetA), true);

        uint256 investable = manager.investableFor(address(assetA));
        assertEq(investable, 500 ether);
    }

    function test_investableFor_respectsClaimableAssets() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        cygld.mint(address(this), 600 ether);
        cygld.mint(address(custody), 200 ether);
        stakingVault.setTotalAssets(400 ether);

        _registry().setSleeveApproval(address(sleeveCygld), true);

        uint256 baseline = manager.investableFor(address(cygld));
        assertEq(baseline, 100 ether, "baseline investable should follow staker ratio");

        stakingVault.setClaimableAssets(150 ether);
        uint256 afterClaimable = manager.investableFor(address(cygld));
        assertEq(afterClaimable, 50 ether, "claimable assets reduce investable headroom");

        assertLt(afterClaimable, baseline, "locked liquidity must shrink capacity");
    }

    /*//////////////////////////////////////////////////////////////
                             ALLOCATE/DEALLOCATE
    //////////////////////////////////////////////////////////////*/

    function _primeSleeve(address sleeve, MockERC20 asset, uint256 amount) internal {
        asset.mint(address(custody), amount);
        _registry().setSleeveApproval(sleeve, true);
        stakingVault.setTotalAssets(amount);
        cygld.mint(address(0xB0B), amount);
    }

    function test_allocate_requiresApproval() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        assetA.mint(address(custody), 100 ether);
        stakingVault.setTotalAssets(100 ether);
        cygld.mint(address(0xB0B), 100 ether);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(FundManagerFacet.SleeveNotApproved.selector, address(sleeveAssetA)));
        manager.allocate(address(sleeveAssetA), 10 ether, "");
    }

    function test_allocate_movesAssetsToSleeve() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _primeSleeve(address(sleeveAssetA), assetA, 1_000 ether);

        vm.prank(allocator);
        uint256 used = manager.allocate(address(sleeveAssetA), 400 ether, "");

        assertEq(used, 400 ether);
        assertEq(assetA.balanceOf(address(sleeveAssetA)), 400 ether);

        LibAppStorage.SleeveConfig memory cfg = _sleeveConfig(address(sleeveAssetA));
        assertEq(cfg.principalAssets, 400 ether);
        assertEq(manager.principalPerAsset(address(assetA)), 400 ether);
    }

    function test_allocate_enforcesCustodyCap() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        assetA.mint(address(custody), 100 ether);
        _registry().setSleeveApproval(address(sleeveAssetA), true);
        stakingVault.setTotalAssets(0);

        vm.prank(allocator);
        vm.expectRevert(FundManagerFacet.SleeveExceeded.selector);
        manager.allocate(address(sleeveAssetA), 10 ether, "");
    }

    function test_allocate_respectsSleevePrincipalCap() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _primeSleeve(address(sleeveAssetA), assetA, 1_000 ether);
        sleeveAssetA.setPrincipalCap(300 ether);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(SleeveBase.PrincipalCapExceeded.selector, 300 ether, 400 ether));
        manager.allocate(address(sleeveAssetA), 400 ether, "");

        vm.prank(allocator);
        uint256 used = manager.allocate(address(sleeveAssetA), 250 ether, "");
        assertEq(used, 250 ether);
    }

    function test_deallocate_returnsPrincipal() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _primeSleeve(address(sleeveAssetA), assetA, 1_000 ether);

        vm.prank(allocator);
        manager.allocate(address(sleeveAssetA), 500 ether, "");

        vm.prank(allocator);
        uint256 returned = manager.deallocate(address(sleeveAssetA), 200 ether, "");

        assertEq(returned, 200 ether);
        assertEq(assetA.balanceOf(address(custody)), 700 ether);

        LibAppStorage.SleeveConfig memory cfg = _sleeveConfig(address(sleeveAssetA));
        assertEq(cfg.principalAssets, 300 ether);
        assertEq(manager.principalPerAsset(address(assetA)), 300 ether);
    }

    function test_deallocate_allowedWhenNotApproved() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _primeSleeve(address(sleeveAssetA), assetA, 500 ether);

        vm.prank(allocator);
        manager.allocate(address(sleeveAssetA), 200 ether, "");

        _registry().setSleeveApproval(address(sleeveAssetA), false);

        vm.prank(allocator);
        manager.deallocate(address(sleeveAssetA), 100 ether, "");

        LibAppStorage.SleeveConfig memory cfg = _sleeveConfig(address(sleeveAssetA));
        assertEq(cfg.principalAssets, 100 ether);
    }

    function test_deallocateOverReturnedAssetsZerosPrincipalAccounting() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _primeSleeve(address(sleeveAssetA), assetA, 300 ether);

        vm.prank(allocator);
        manager.allocate(address(sleeveAssetA), 100 ether, "");

        assetA.mint(address(this), 50 ether);
        assetA.approve(address(sleeveAssetA), 50 ether);
        sleeveAssetA.donate(50 ether);

        vm.prank(allocator);
        uint256 returned = manager.deallocate(address(sleeveAssetA), 150 ether, "");

        assertEq(returned, 150 ether);
        LibAppStorage.SleeveConfig memory cfg = _sleeveConfig(address(sleeveAssetA));
        assertEq(cfg.principalAssets, 0);
        assertEq(manager.principalPerAsset(address(assetA)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         HARVEST AND DONATE (CYGLD)
    //////////////////////////////////////////////////////////////*/

    function _allocateCygldSleeve(uint256 amount) internal {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        cygld.mint(address(custody), amount);
        _registry().setSleeveApproval(address(sleeveCygld), true);
        stakingVault.setTotalAssets(amount * 2);
        cygld.mint(address(0xB0B1), amount);
        vm.prank(allocator);
        manager.allocate(address(sleeveCygld), amount, "");
    }

    function test_harvestAndDonateAsCygld_directCygld() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _allocateCygldSleeve(1_000 ether);

        cygld.mint(address(this), 200 ether);
        cygld.approve(address(sleeveCygld), 200 ether);
        sleeveCygld.donate(200 ether);

        uint256 treasuryBefore = cygld.balanceOf(treasury);
        uint256 custodyBefore = cygld.balanceOf(address(custody));

        vm.prank(allocator);
        (uint256 profitAssets, uint256 cygldOut, uint256 feeCygld, uint256 donatedCygld) =
            manager.harvestAndDonateAsCygld(address(sleeveCygld), 0, "");

        assertEq(profitAssets, 200 ether);
        assertEq(cygldOut, 200 ether);
        assertEq(feeCygld, (200 ether * manager.performanceFeePpm()) / PPM_DENOMINATOR);
        assertEq(donatedCygld, cygldOut - feeCygld);
        assertEq(cygld.balanceOf(treasury) - treasuryBefore, feeCygld);
        assertEq(cygld.balanceOf(address(custody)) - custodyBefore, donatedCygld);
    }

    function test_harvestAndDonateAsCygld_directCygld_respectsMinOut() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _allocateCygldSleeve(1_000 ether);

        cygld.mint(address(this), 50 ether);
        cygld.approve(address(sleeveCygld), 50 ether);
        sleeveCygld.donate(50 ether);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(FundManagerFacet.MinCygldOutNotMet.selector, 50 ether, 60 ether));
        manager.harvestAndDonateAsCygld(address(sleeveCygld), 60 ether, "");
    }

    function test_harvestAndDonateAsCygld_preservesPrincipal() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _allocateCygldSleeve(1_000 ether);
        cygld.mint(address(this), 100 ether);
        cygld.approve(address(sleeveCygld), 100 ether);
        sleeveCygld.donate(100 ether);

        vm.prank(allocator);
        manager.harvestAndDonateAsCygld(address(sleeveCygld), 0, "");

        LibAppStorage.SleeveConfig memory cfg = _sleeveConfig(address(sleeveCygld));
        assertEq(cfg.principalAssets, 1_000 ether);
    }

    function test_harvestAndDonateAsCygld_withSwap() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _primeSleeve(address(sleeveAssetA), assetA, 1_000 ether);
        vm.prank(allocator);
        manager.allocate(address(sleeveAssetA), 800 ether, "");

        assetA.mint(address(this), 200 ether);
        assetA.approve(address(sleeveAssetA), 200 ether);
        sleeveAssetA.donate(200 ether);

        manager.setSwapAdapter(address(swapAdapter));
        swapAdapter.setRate(2e18);

        uint256 treasuryBefore = cygld.balanceOf(treasury);
        uint256 custodyBefore = cygld.balanceOf(address(custody));

        vm.prank(allocator);
        (uint256 profitAssets, uint256 cygldOut, uint256 feeCygld, uint256 donatedCygld) =
            manager.harvestAndDonateAsCygld(address(sleeveAssetA), 0, "");

        assertEq(profitAssets, 200 ether);
        assertEq(cygldOut, 400 ether);
        assertEq(feeCygld, (cygldOut * manager.performanceFeePpm()) / PPM_DENOMINATOR);
        assertEq(cygld.balanceOf(treasury) - treasuryBefore, feeCygld);
        assertEq(cygld.balanceOf(address(custody)) - custodyBefore, donatedCygld);
    }

    function test_harvestAndDonateAsCygld_usesObservedSwapOutput() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _primeSleeve(address(sleeveAssetA), assetA, 1_000 ether);
        vm.prank(allocator);
        manager.allocate(address(sleeveAssetA), 800 ether, "");

        assetA.mint(address(this), 200 ether);
        assetA.approve(address(sleeveAssetA), 200 ether);
        sleeveAssetA.donate(200 ether);

        manager.setSwapAdapter(address(swapAdapter));
        swapAdapter.setRate(2e18);
        swapAdapter.setReportedAmount(10_000 ether);

        vm.prank(allocator);
        (, uint256 cygldOut,,) = manager.harvestAndDonateAsCygld(address(sleeveAssetA), 0, "");

        assertEq(cygldOut, 400 ether);
    }

    function test_harvestAndDonateAsCygld_withSwap_respectsMinOut() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _primeSleeve(address(sleeveAssetA), assetA, 1_000 ether);
        vm.prank(allocator);
        manager.allocate(address(sleeveAssetA), 800 ether, "");

        assetA.mint(address(this), 200 ether);
        assetA.approve(address(sleeveAssetA), 200 ether);
        sleeveAssetA.donate(200 ether);

        manager.setSwapAdapter(address(swapAdapter));
        swapAdapter.setRate(2e18);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(FundManagerFacet.MinCygldOutNotMet.selector, 400 ether, 401 ether));
        manager.harvestAndDonateAsCygld(address(sleeveAssetA), 401 ether, "");
    }

    function test_harvestAndDonateAsCygld_forwardsMinOutToAdapter() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _primeSleeve(address(sleeveAssetA), assetA, 1_000 ether);
        vm.prank(allocator);
        manager.allocate(address(sleeveAssetA), 800 ether, "");

        assetA.mint(address(this), 200 ether);
        assetA.approve(address(sleeveAssetA), 200 ether);
        sleeveAssetA.donate(200 ether);

        manager.setSwapAdapter(address(swapAdapter));
        swapAdapter.setRate(2e18);

        uint256 minOut = 400 ether;
        vm.prank(allocator);
        manager.harvestAndDonateAsCygld(address(sleeveAssetA), minOut, "");

        assertEq(swapAdapter.lastMinOut(), minOut);
    }

    function test_harvestAndDonateAsCygld_requiresAdapterForNonCygld() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _primeSleeve(address(sleeveAssetA), assetA, 100 ether);
        vm.prank(allocator);
        manager.allocate(address(sleeveAssetA), 80 ether, "");

        assetA.mint(address(this), 10 ether);
        assetA.approve(address(sleeveAssetA), 10 ether);
        sleeveAssetA.donate(10 ether);

        vm.prank(allocator);
        vm.expectRevert(FundManagerFacet.AdapterNotSet.selector);
        manager.harvestAndDonateAsCygld(address(sleeveAssetA), 0, "");
    }

    function test_harvestAndDonateAsCygld_zeroProfit_noop() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        uint256 stakeAssets = 200 ether;
        cygld.mint(address(custody), stakeAssets);
        cygld.mint(address(0xB0B), stakeAssets);
        stakingVault.setTotalAssets(stakeAssets);

        _registry().setSleeveApproval(address(sleeveCygld), true);
        vm.prank(allocator);
        manager.allocate(address(sleeveCygld), 100 ether, "");

        uint256 treasuryBefore = cygld.balanceOf(treasury);
        uint256 custodyBefore = cygld.balanceOf(address(custody));

        vm.prank(allocator);
        (uint256 profitAssets, uint256 cygldOut, uint256 feeCygld, uint256 donatedCygld) =
            manager.harvestAndDonateAsCygld(address(sleeveCygld), 0, "");

        assertEq(profitAssets, 0);
        assertEq(cygldOut, 0);
        assertEq(feeCygld, 0);
        assertEq(donatedCygld, 0);
        assertEq(cygld.balanceOf(treasury), treasuryBefore);
        assertEq(cygld.balanceOf(address(custody)), custodyBefore);
    }

    function test_harvestAndDonateAsCygld_clearsSwapAllowance() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _primeSleeve(address(sleeveAssetA), assetA, 1_000 ether);
        vm.prank(allocator);
        manager.allocate(address(sleeveAssetA), 400 ether, "");

        assetA.mint(address(this), 120 ether);
        assetA.approve(address(sleeveAssetA), 120 ether);
        sleeveAssetA.donate(120 ether);

        manager.setSwapAdapter(address(swapAdapter));
        swapAdapter.setRate(1.5e18);
        uint256 custodyBalanceBefore = assetA.balanceOf(address(diamond));

        vm.prank(allocator);
        manager.harvestAndDonateAsCygld(address(sleeveAssetA), 0, "");

        assertEq(assetA.allowance(address(diamond), address(swapAdapter)), 0);
        assertEq(assetA.balanceOf(address(diamond)), custodyBalanceBefore);
    }

    function test_allocate_withSleeve4626() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        MockVault4626 vault = new MockVault4626(assetB);
        Sleeve4626 sleeve4626 = _deploySleeve4626(address(assetB), address(vault));
        custody.grantRole(custody.WITHDRAWER_ROLE(), address(sleeve4626));

        _registry().registerSleeve(address(sleeve4626), address(assetB));
        _registry().setSleeveApproval(address(sleeve4626), true);

        assetB.mint(address(custody), 1_000 ether);
        stakingVault.setTotalAssets(1_000 ether);
        cygld.mint(address(0xB0B3), 1_000 ether);

        vm.prank(allocator);
        uint256 used = manager.allocate(address(sleeve4626), 600 ether, "");

        assertEq(used, 600 ether);
        assertEq(IERC20(address(vault)).balanceOf(address(sleeve4626)), vault.convertToShares(600 ether));
        LibAppStorage.SleeveConfig memory cfg = _sleeveConfig(address(sleeve4626));
        assertEq(cfg.principalAssets, 600 ether);
        assertEq(manager.principalPerAsset(address(assetB)), 600 ether);
    }

    function test_harvestAndDonateAsCygld_withSleeve4626() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        MockVault4626 vault = new MockVault4626(assetB);
        Sleeve4626 sleeve4626 = _deploySleeve4626(address(assetB), address(vault));
        custody.grantRole(custody.WITHDRAWER_ROLE(), address(sleeve4626));

        _registry().registerSleeve(address(sleeve4626), address(assetB));
        _registry().setSleeveApproval(address(sleeve4626), true);

        assetB.mint(address(custody), 1_000 ether);
        stakingVault.setTotalAssets(1_000 ether);
        cygld.mint(address(0xB0B4), 1_000 ether);

        vm.prank(allocator);
        manager.allocate(address(sleeve4626), 400 ether, "");

        assetB.mint(address(this), 120 ether);
        assetB.approve(address(vault), 120 ether);
        vault.donate(120 ether);

        manager.setSwapAdapter(address(swapAdapter));
        swapAdapter.setRate(2e18);

        uint256 treasuryBefore = cygld.balanceOf(treasury);
        uint256 custodyBefore = cygld.balanceOf(address(custody));

        vm.prank(allocator);
        (uint256 profitAssets, uint256 cygldOut, uint256 feeCygld, uint256 donatedCygld) =
            manager.harvestAndDonateAsCygld(address(sleeve4626), 0, "");

        assertEq(profitAssets, 120 ether);
        assertEq(cygldOut, 240 ether);
        assertEq(feeCygld, (cygldOut * manager.performanceFeePpm()) / PPM_DENOMINATOR);
        assertEq(cygld.balanceOf(treasury) - treasuryBefore, feeCygld);
        assertEq(cygld.balanceOf(address(custody)) - custodyBefore, donatedCygld);

        LibAppStorage.SleeveConfig memory cfg = _sleeveConfig(address(sleeve4626));
        assertEq(cfg.principalAssets, 400 ether);
    }

    /*//////////////////////////////////////////////////////////////
                             POSITION VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_position_reportsSleeveView() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _primeSleeve(address(sleeveAssetA), assetA, 500 ether);
        vm.prank(allocator);
        manager.allocate(address(sleeveAssetA), 200 ether, "");

        assetA.mint(address(this), 40 ether);
        assetA.approve(address(sleeveAssetA), 40 ether);
        sleeveAssetA.donate(40 ether);

        (address asset, uint256 principal, uint256 totalAssets, int256 pnl) = manager.position(address(sleeveAssetA));
        assertEq(asset, address(assetA));
        assertEq(principal, 200 ether);
        assertEq(totalAssets, 240 ether);
        assertEq(pnl, int256(40 ether));
    }

    function test_position_reportsNegativePnl() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _primeSleeve(address(sleeveAssetA), assetA, 500 ether);
        vm.prank(allocator);
        manager.allocate(address(sleeveAssetA), 200 ether, "");

        vm.prank(address(sleeveAssetA));
        assertTrue(assetA.transfer(address(0xDEAD), 70 ether));

        (address asset, uint256 principal, uint256 totalAssets, int256 pnl) = manager.position(address(sleeveAssetA));
        assertEq(asset, address(assetA));
        assertEq(principal, 200 ether);
        assertEq(totalAssets, 130 ether);
        assertEq(pnl, -int256(70 ether));
    }

    /*//////////////////////////////////////////////////////////////
                                 PAUSE
    //////////////////////////////////////////////////////////////*/

    function test_pause_blocksAllocate() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        assetA.mint(address(custody), 100 ether);
        _registry().setSleeveApproval(address(sleeveAssetA), true);
        stakingVault.setTotalAssets(200 ether);
        cygld.mint(address(0xB0B), 200 ether);

        vm.prank(pauser);
        PausableFacet(address(diamond)).pause();

        vm.prank(allocator);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        manager.allocate(address(sleeveAssetA), 10 ether, "");
    }

    function test_pause_allowsDeallocate() public {
        FundManagerFacet manager = FundManagerFacet(address(diamond));
        _primeSleeve(address(sleeveAssetA), assetA, 100 ether);
        vm.prank(allocator);
        manager.allocate(address(sleeveAssetA), 60 ether, "");

        vm.prank(pauser);
        PausableFacet(address(diamond)).pause();

        vm.prank(allocator);
        uint256 returned = manager.deallocate(address(sleeveAssetA), 40 ether, "");

        assertEq(returned, 40 ether);
        assertEq(assetA.balanceOf(address(custody)), 80 ether);
    }

    // ----- Helpers -----

    function _registry() internal view returns (SleeveRegistryFacet) {
        return SleeveRegistryFacet(address(diamond));
    }

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

    function _deploySleeve4626(address assetAddr, address vaultAddr) internal returns (Sleeve4626 proxy) {
        Sleeve4626 implementation = new Sleeve4626();
        proxy = Sleeve4626(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(Sleeve4626.initialize, (address(diamond), assetAddr, 0, vaultAddr, true, false))
                )
            )
        );
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

    function custodySelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = CustodyFacet.initCustody.selector;
        selectors[1] = CustodyFacet.transferTo.selector;
        selectors[2] = CustodyFacet.custodyBalance.selector;
        selectors[3] = bytes4(keccak256("WITHDRAWER_ROLE()"));
    }

    function sleeveSelectors() internal pure returns (bytes4[] memory selectors) {
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

    function stakingVaultSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = MockStakingVault.setAsset.selector;
        selectors[1] = MockStakingVault.setTotalAssets.selector;
        selectors[2] = MockStakingVault.setClaimableAssets.selector;
        selectors[3] = MockStakingVault.asset.selector;
        selectors[4] = MockStakingVault.totalAssets.selector;
        selectors[5] = MockStakingVault.liquidityBreakdown.selector;
    }

    function _sleeveConfig(address sleeve) internal view returns (LibAppStorage.SleeveConfig memory cfg) {
        cfg = SleeveRegistryFacet(address(diamond)).sleeveConfig(sleeve);
    }
}
