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
import {TokenFacet} from "../../src/facets/TokenFacet.sol";
import {VaultFacet} from "../../src/facets/VaultFacet.sol";
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
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {StakingInitV2} from "../helpers/StakingInitV2.sol";

contract MockFundManager is Test {
    bytes32 public constant FACET_NAMESPACE =
        keccak256("cybergold.staking.test.mock-fund-manager");
    uint64 public constant FACET_VERSION = 1;

    uint256 public sleeveAssets;
    bool public shouldRevert;

    function set(uint256 assets, bool revertFlag) external {
        sleeveAssets = assets;
        shouldRevert = revertFlag;
    }

    function stakerAssetsInSleeves(address) external view returns (uint256) {
        if (shouldRevert) revert("fail");
        return sleeveAssets;
    }
}

contract MockQueue is Test {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.staking.test.queue-mutator");
    uint64 public constant FACET_VERSION = 1;

    function setClaimable(address owner, uint256 shares) external {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        q.claimableSharesTotal += shares - q.claimableShares[owner];
        q.claimableShares[owner] = shares;
    }
}

contract VaultFacetSupplyPauseHarness is VaultFacet {
    function mintSupplyForTest(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnSupplyForTest(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function transferSupplyForTest(address from, address to, uint256 amount) external {
        _transfer(from, to, amount);
    }

    function pauseForTest() external {
        _pause();
    }

    function payoutForTest(address receiver, uint256 shares) external returns (uint256 assetsOut) {
        return this.payout(address(this), address(this), receiver, shares);
    }
}

contract VaultFacetTest is Test {
    MockERC20 internal asset;
    MockFundManager internal manager;
    MockQueue internal queue;

    StakingDiamond internal diamond;
    DiamondCutAccessFacet internal cutFacet;
    DiamondLoupeFacet internal loupeFacet;
    DefaultAdminAccessControlFacet internal accessFacet;
    PausableFacet internal pauseFacet;
    ReentrancyGuardFacet internal reentrancyFacet;
    TokenFacet internal tokenFacet;
    VaultFacet internal vaultFacet;

    address internal admin = address(0xA11CE);
    address internal pauser = address(0x5AFE);
    address internal user = address(0xBEEF);
    address internal recipient = address(0xCAFE);
    address internal spender = address(0xD00D);
    address internal safeWallet;

    function setUp() public {
        asset = new MockERC20("CyberGold", "CYGLD", 18);
        manager = new MockFundManager();
        queue = new MockQueue();
        vm.etch(admin, hex"00");
        safeWallet = MockSafeWalletFactory.deploy(pauser);
        DeploymentTypes.DeployConfig memory cfg;
        cfg.safeWallet = safeWallet;
        cfg.name = "Wrapped Staked CYGLD";
        cfg.symbol = "wstCYGLD";
        cfg.coreDiamond = address(asset);
        cfg.governanceDiamond = admin;
        cfg.withdrawers = new address[](0);
        cfg.allocators = new address[](1);
        cfg.allocators[0] = admin;
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(asset), false, 0);
        cfg.create2Deployer = address(this);
        cfg.shellSalt = keccak256("VaultFacetTest");
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

        IDiamond.FacetCut[] memory testCut = new IDiamond.FacetCut[](3);
        bytes4[] memory managerAdd = new bytes4[](1);
        managerAdd[0] = MockFundManager.set.selector;
        testCut[0] = IDiamond.FacetCut({
            facetAddress: address(manager), action: IDiamond.FacetCutAction.Add, functionSelectors: managerAdd
        });
        bytes4[] memory managerReplace = new bytes4[](1);
        managerReplace[0] = MockFundManager.stakerAssetsInSleeves.selector;
        testCut[1] = IDiamond.FacetCut({
            facetAddress: address(manager), action: IDiamond.FacetCutAction.Replace, functionSelectors: managerReplace
        });
        testCut[2] = IDiamond.FacetCut({
            facetAddress: address(queue),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: queueMutatorSelectors()
        });
        address[] memory testFacets = new address[](2);
        testFacets[0] = address(manager);
        testFacets[1] = address(queue);
        StakingInitV2 testInit = new StakingInitV2();
        vm.prank(admin);
        IDiamondCut(address(diamond))
            .diamondCut(testCut, address(testInit), abi.encodeCall(StakingInitV2.initMany, (testFacets)));

        manager = MockFundManager(address(diamond));
        queue = MockQueue(address(diamond));
        vm.prank(safeWallet);
        PausableFacet(address(diamond)).unpause();

        asset.mint(user, 1_000 ether);
        vm.prank(user);
        asset.approve(address(diamond), type(uint256).max);
    }

    function testSupplyUpdatePauseGuardBlocksMintAndBurnButAllowsTransfers() public {
        VaultFacetSupplyPauseHarness harness = new VaultFacetSupplyPauseHarness();
        harness.mintSupplyForTest(user, 10 ether);
        harness.pauseForTest();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        harness.mintSupplyForTest(recipient, 1 ether);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        harness.burnSupplyForTest(user, 1 ether);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        harness.payoutForTest(recipient, 1 ether);

        harness.transferSupplyForTest(user, recipient, 1 ether);
        assertEq(harness.balanceOf(user), 9 ether);
        assertEq(harness.balanceOf(recipient), 1 ether);
    }

    function testDepositRemainsInNativeCustody() public {
        VaultFacet vault = VaultFacet(address(diamond));
        vm.prank(user);
        vault.deposit(100 ether, user);
        assertEq(MockERC20(asset).balanceOf(address(diamond)), 100 ether, "diamond holds assets");
        assertEq(vault.balanceOf(user), 100 ether);
    }

    function testWithdrawAndRedeemRevert() public {
        VaultFacet vault = VaultFacet(address(diamond));
        vm.prank(user);
        vault.deposit(50 ether, user);

        vm.expectRevert();
        vault.withdraw(1, user, user);
        vm.expectRevert();
        vault.redeem(1, user, user);
        vm.expectRevert(VaultFacet.RedeemViaQueue.selector);
        vault.previewWithdraw(1);
        vm.expectRevert(VaultFacet.RedeemViaQueue.selector);
        vault.previewRedeem(1);
    }

    function testDirectFacetWithdrawAndRedeemRevertViaQueue() public {
        VaultFacet directFacet = new VaultFacet();

        vm.expectRevert(VaultFacet.RedeemViaQueue.selector);
        directFacet.withdraw(1, user, user);
        vm.expectRevert(VaultFacet.RedeemViaQueue.selector);
        directFacet.redeem(1, user, user);
    }

    function testOrdinaryTransfersRemainAvailableAcrossPauseCycles() public {
        VaultFacet vault = VaultFacet(address(diamond));
        vm.prank(user);
        vault.deposit(40 ether, user);

        vm.prank(user);
        vault.transfer(recipient, 10 ether);
        vm.prank(recipient);
        vault.approve(spender, 6 ether);

        vm.prank(pauser);
        PausableFacet(address(diamond)).pause();

        vm.prank(spender);
        vault.transferFrom(recipient, user, 3 ether);
        vm.prank(user);
        vault.transfer(recipient, 5 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(1 ether, user);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.mint(1 ether, user);

        assertEq(vault.totalSupply(), 40 ether, "ordinary transfers do not change supply");
        assertEq(vault.balanceOf(user), 28 ether);
        assertEq(vault.balanceOf(recipient), 12 ether);

        vm.prank(safeWallet);
        PausableFacet(address(diamond)).unpause();
        vm.prank(user);
        vault.transfer(recipient, 2 ether);

        vm.prank(pauser);
        PausableFacet(address(diamond)).pause();
        vm.prank(spender);
        vault.transferFrom(recipient, user, 3 ether);

        assertEq(vault.totalSupply(), 40 ether, "repeated pause cycles do not freeze transfers");
        assertEq(vault.balanceOf(user), 29 ether);
        assertEq(vault.balanceOf(recipient), 11 ether);
        assertEq(vault.allowance(recipient, spender), 0);
    }

    function testTransferToVaultOnlyQueueAllowed() public {
        VaultFacet vault = VaultFacet(address(diamond));
        vm.prank(user);
        vault.deposit(10 ether, user);

        vm.prank(user);
        vm.expectRevert(VaultFacet.UnsolicitedEscrowDisabled.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        vault.transfer(address(diamond), 1 ether);

        vm.prank(user);
        vault.approve(spender, 1 ether);
        vm.prank(spender);
        vm.expectRevert(VaultFacet.UnsolicitedEscrowDisabled.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        vault.transferFrom(user, address(diamond), 1 ether);

        vm.prank(pauser);
        PausableFacet(address(diamond)).pause();

        // The queue's internal escrow transfer remains available while paused.
        vm.prank(address(diamond));
        vault.escrowFrom(user, 5 ether);
        assertEq(vault.balanceOf(address(diamond)), 5 ether);
    }

    function testFundManagerUnhealthyBlocksDeposit() public {
        manager.set(0, true); // make peek revert
        VaultFacet vault = VaultFacet(address(diamond));
        vm.prank(user);
        vm.expectRevert(VaultFacet.FundManagerQueryFailed.selector);
        vault.deposit(1 ether, user);
    }

    function testMaxViewsUseQueueClaimablesAndZeroQueueFallback() public {
        VaultFacet vault = VaultFacet(address(diamond));
        vm.prank(user);
        vault.deposit(100 ether, user);

        queue.setClaimable(user, 25 ether);
        assertEq(vault.maxRedeem(user), 25 ether);
        assertEq(vault.maxWithdraw(user), 25 ether);
    }

    function testPausedMaxViewsReturnZero() public {
        VaultFacet vault = VaultFacet(address(diamond));
        queue.setClaimable(user, 25 ether);

        vm.prank(pauser);
        PausableFacet(address(diamond)).pause();

        assertEq(vault.maxDeposit(user), 0);
        assertEq(vault.maxMint(user), 0);
        assertEq(vault.maxRedeem(user), 0);
        assertEq(vault.maxWithdraw(user), 0);
    }

    function testUnhealthyManagerMaxViewsAndSafeTotals() public {
        VaultFacet vault = VaultFacet(address(diamond));
        vm.prank(user);
        vault.deposit(60 ether, user);

        manager.set(1_000 ether, true);
        assertEq(vault.maxDeposit(user), 0);
        assertEq(vault.maxMint(user), 0);

        (uint256 assets, bool healthy) = vault.totalAssetsSafe();
        assertEq(assets, 60 ether);
        assertFalse(healthy);
    }

    function testLiquidityBreakdownIncludesExternalCustody() public {
        VaultFacet vault = VaultFacet(address(diamond));
        vm.prank(user);
        vault.deposit(75 ether, user);
        manager.set(11 ether, false);
        queue.setClaimable(user, 15 ether);
        uint256 expectedClaimableAssets = vault.convertToAssets(15 ether);

        (VaultFacet.LiquidityBreakdown memory breakdown, bool healthy) = vault.liquidityBreakdown();
        assertEq(breakdown.custodyAssets, 75 ether);
        assertEq(breakdown.claimableAssets, expectedClaimableAssets);
        assertEq(breakdown.strategyAssets, 11 ether);
        assertEq(breakdown.totalManagedAssets, 86 ether);
        assertTrue(healthy);
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
        return FacetSelectors.tokenSelectors();
    }

    function vaultSelectors() internal pure returns (bytes4[] memory selectors) {
        bytes4[] memory runtimeSelectors = FacetSelectors.vaultSelectors();
        selectors = new bytes4[](runtimeSelectors.length + 2);
        for (uint256 i; i < runtimeSelectors.length; ++i) {
            selectors[i] = runtimeSelectors[i];
        }
        selectors[runtimeSelectors.length] = VaultFacet.withdraw.selector;
        selectors[runtimeSelectors.length + 1] = VaultFacet.redeem.selector;
    }

    function managerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = MockFundManager.set.selector;
        selectors[1] = MockFundManager.stakerAssetsInSleeves.selector;
    }

    function queueMutatorSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = MockQueue.setClaimable.selector;
    }
}
