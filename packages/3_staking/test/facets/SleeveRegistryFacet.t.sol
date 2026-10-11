// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {StakingDiamond} from "../../src/diamond/StakingDiamond.sol";
import {
    DiamondCutAccessLiveFacet as DiamondCutAccessFacet
} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
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

import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {MockStakingVault} from "staking-mocks/MockStakingVault.sol";
import {MockCyberGold} from "staking-mocks/MockCyberGold.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {MockStakingDiamond} from "../helpers/MockStakingDiamond.sol";
import {StakingInitV2} from "../helpers/StakingInitV2.sol";

contract SleeveRegistryStorageMutator {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.staking.test.sleeve-registry-mutator");
    uint64 public constant FACET_VERSION = 1;

    function setSleeveAsset(address sleeve, address asset) external {
        LibAppStorage.appStorage().fm.sleeves[sleeve].asset = asset;
    }
}

contract SleeveRegistryFacetTest is Test {
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
        treasury = address(this);

        MockStakingVault stakingVaultFacet = new MockStakingVault();
        SleeveRegistryStorageMutator mutatorFacet = new SleeveRegistryStorageMutator();
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
        cfg.shellSalt = keccak256("SleeveRegistryFacetTest");
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

        IDiamond.FacetCut[] memory testCut = new IDiamond.FacetCut[](3);
        bytes4[] memory addVaultSelectors = new bytes4[](3);
        addVaultSelectors[0] = MockStakingVault.setAsset.selector;
        addVaultSelectors[1] = MockStakingVault.setTotalAssets.selector;
        addVaultSelectors[2] = MockStakingVault.setClaimableAssets.selector;
        testCut[0] = IDiamond.FacetCut({
            facetAddress: address(stakingVaultFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: addVaultSelectors
        });
        bytes4[] memory replaceVaultSelectors = new bytes4[](3);
        replaceVaultSelectors[0] = MockStakingVault.asset.selector;
        replaceVaultSelectors[1] = MockStakingVault.totalAssets.selector;
        replaceVaultSelectors[2] = MockStakingVault.liquidityBreakdown.selector;
        testCut[1] = IDiamond.FacetCut({
            facetAddress: address(stakingVaultFacet),
            action: IDiamond.FacetCutAction.Replace,
            functionSelectors: replaceVaultSelectors
        });
        testCut[2] = IDiamond.FacetCut({
            facetAddress: address(mutatorFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: sleeveRegistryStorageMutatorSelectors()
        });
        address[] memory testFacets = new address[](2);
        testFacets[0] = address(stakingVaultFacet);
        testFacets[1] = address(mutatorFacet);
        StakingInitV2 testInit = new StakingInitV2();
        IDiamondCut(address(diamond))
            .diamondCut(testCut, address(testInit), abi.encodeCall(StakingInitV2.initMany, (testFacets)));
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

    function test_registerSleeve_setsConfig() public {
        MockSleeve newSleeve = _deploySleeve(address(assetB));

        vm.expectEmit(true, true, false, true);
        emit SleeveRegistryFacet.SleeveRegistered(address(newSleeve), address(assetB));
        _registry().registerSleeve(address(newSleeve), address(assetB));

        LibAppStorage.SleeveConfig memory cfg = _registry().sleeveConfig(address(newSleeve));
        assertTrue(cfg.registered);
        assertEq(cfg.asset, address(assetB));
        assertEq(cfg.principalAssets, 0);
    }

    function test_registerSleeve_reassign_requiresPrincipalCleared() public {
        _registry().setSleeveApproval(address(sleeveAssetA), true);
        assetA.mint(address(custody), 200 ether);
        stakingVault.setTotalAssets(200 ether);
        cygld.mint(address(0xB0B), 200 ether);

        vm.prank(allocator);
        _manager().allocate(address(sleeveAssetA), 100 ether, "");

        vm.expectRevert(
            abi.encodeWithSelector(
                SleeveRegistryFacet.SleevePrincipalNotCleared.selector, address(sleeveAssetA), 100 ether
            )
        );
        _registry().registerSleeve(address(sleeveAssetA), address(assetB));
    }

    function test_registerSleeve_reassign_mismatchedAsset_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SleeveRegistryFacet.SleeveAssetMismatch.selector, address(sleeveAssetA), address(assetB)
            )
        );
        _registry().registerSleeve(address(sleeveAssetA), address(assetB));
    }

    function test_registerSleeve_reassignsStaleAssetAfterPrincipalCleared() public {
        SleeveRegistryStorageMutator(address(diamond)).setSleeveAsset(address(sleeveAssetA), address(assetB));

        vm.expectEmit(true, true, false, true);
        emit SleeveRegistryFacet.SleeveRegistered(address(sleeveAssetA), address(assetA));
        _registry().registerSleeve(address(sleeveAssetA), address(assetA));

        LibAppStorage.SleeveConfig memory cfg = _registry().sleeveConfig(address(sleeveAssetA));
        assertEq(cfg.asset, address(assetA));
    }

    function test_registerSleeve_initial_assetMismatch_reverts() public {
        MockSleeve newSleeve = _deploySleeve(address(assetA));
        address wrongAsset = address(assetB);
        vm.expectRevert(
            abi.encodeWithSelector(SleeveRegistryFacet.SleeveAssetMismatch.selector, address(newSleeve), wrongAsset)
        );
        _registry().registerSleeve(address(newSleeve), wrongAsset);
    }

    function test_registerSleeve_initialStakingDiamondMismatch_reverts() public {
        MockStakingDiamond otherStakingDiamond = new MockStakingDiamond(admin, address(0x5AFE));
        MockSleeve newSleeve = _deploySleeveCustom(address(assetB), address(otherStakingDiamond));
        vm.expectRevert(
            abi.encodeWithSelector(
                SleeveRegistryFacet.SleeveStakingDiamondMismatch.selector, address(newSleeve), address(_registry())
            )
        );
        _registry().registerSleeve(address(newSleeve), address(assetB));
    }

    function test_setSleeveApproval_requiresRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(SleeveRegistryFacet.SleeveNotRegistered.selector, address(0xC0FFEE)));
        _registry().setSleeveApproval(address(0xC0FFEE), true);
    }

    function test_setSleeveApproval_updatesFlag() public {
        vm.expectEmit(true, false, false, true);
        emit SleeveRegistryFacet.SleeveApprovalUpdated(address(sleeveAssetA), true);
        _registry().setSleeveApproval(address(sleeveAssetA), true);

        LibAppStorage.SleeveConfig memory cfg = _registry().sleeveConfig(address(sleeveAssetA));
        assertTrue(cfg.approved);
    }

    function test_sleeves_returnsRegisteredList() public view {
        address[] memory listed = _registry().sleeves();
        assertEq(listed.length, 2);
        assertEq(listed[0], address(sleeveAssetA));
        assertEq(listed[1], address(sleeveCygld));
    }

    function test_stakerAssetsInSleeves_tracksHoldings() public {
        _allocateCygldSleeve(400 ether);
        cygld.mint(address(this), 50 ether);
        cygld.approve(address(sleeveCygld), 50 ether);
        sleeveCygld.donate(50 ether);

        uint256 total = _registry().stakerAssetsInSleeves(address(cygld));
        assertEq(total, 450 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _registry() internal view returns (SleeveRegistryFacet) {
        return SleeveRegistryFacet(address(diamond));
    }

    function _manager() internal view returns (FundManagerFacet) {
        return FundManagerFacet(address(diamond));
    }

    function _allocateCygldSleeve(uint256 amount) internal {
        cygld.mint(address(custody), amount);
        _registry().setSleeveApproval(address(sleeveCygld), true);
        stakingVault.setTotalAssets(amount * 2);
        cygld.mint(address(0xB0B1), amount);
        vm.prank(allocator);
        _manager().allocate(address(sleeveCygld), amount, "");
    }

    function _deploySleeve(address assetAddr) internal returns (MockSleeve proxy) {
        proxy = _deploySleeveCustom(assetAddr, address(diamond));
    }

    function _deploySleeveCustom(address assetAddr, address stakingDiamondAddr) internal returns (MockSleeve proxy) {
        MockSleeve implementation = new MockSleeve();
        proxy = MockSleeve(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(MockSleeve.initialize, (stakingDiamondAddr, assetAddr, 0))
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

    function sleeveRegistryStorageMutatorSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = SleeveRegistryStorageMutator.setSleeveAsset.selector;
    }
}
