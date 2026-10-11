// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {StakingDiamond} from "../../src/diamond/StakingDiamond.sol";
import {
    DiamondCutAccessLiveFacet as DiamondCutAccessFacet
} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {ReentrancyGuardFacet} from "diamond-infra/facets/ReentrancyGuardFacet.sol";
import {VaultFacet} from "../../src/facets/VaultFacet.sol";
import {TokenFacet} from "../../src/facets/TokenFacet.sol";
import {QueueRequestBase} from "../../src/facets/QueueRequestBase.sol";
import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";
import {SleeveDeployerHelper} from "../../src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "../../src/deploy/SleeveRequestBuilder.sol";
import {FacetSelectors} from "../../src/deploy/FacetSelectors.sol";
import {FacetSelectors as SharedFacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";

contract MockCustodyTF {
    function transferTo(address asset, address to, uint256 amount) external {
        require(MockERC20(asset).transfer(to, amount), "transfer failed");
    }
}

contract MockFundManagerTF {
    function stakerAssetsInSleeves(address) external pure returns (uint256) {
        return 0;
    }
}

contract DirectTokenFacetHarness is TokenFacet {
    function initializeForTest(address asset, string calldata name_, string calldata symbol_) external initializer {
        this.initToken(asset, name_, symbol_);
    }

    function pauseForTest() external {
        _pause();
    }

    function unpauseForTest() external {
        _unpause();
    }

    function mintSupplyForTest(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnSupplyForTest(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function transferSupplyForTest(address from, address to, uint256 amount) external {
        _transfer(from, to, amount);
    }
}

contract TokenFacetTest is Test {
    bytes32 internal constant REENTRANCY_GUARD_STORAGE =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    bytes32 internal constant INIT_CONTEXT_SLOT = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;

    MockERC20 internal asset;
    StakingDiamond internal diamond;
    DiamondCutAccessFacet internal cutFacet;
    DiamondLoupeFacet internal loupeFacet;
    DefaultAdminAccessControlFacet internal accessFacet;
    PausableFacet internal pauseFacet;
    ReentrancyGuardFacet internal reentrancyFacet;
    VaultFacet internal vaultFacet;
    TokenFacet internal tokenFacet;
    address internal safeWallet;

    address internal admin = address(0xA11CE);
    address internal pauser = address(0x5AFE);
    address internal user = address(0xBEEF);
    address internal receiver = address(0xCAFE);

    function setUp() public {
        asset = new MockERC20("CyberGold", "CYGLD", 18);
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
        cfg.shellSalt = keccak256("TokenFacetTest");
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.prepare(cfg);
        art = DeploymentHelper.deployCommittedShellLocal(cfg, art);
        art = DeploymentHelper.finalizeCommitted(cfg, art);
        diamond = art.diamond;
        cutFacet = art.facets.cut;
        loupeFacet = art.facets.loupe;
        accessFacet = art.facets.access;
        pauseFacet = art.facets.pause;
        reentrancyFacet = art.facets.reentrancy;
        vaultFacet = art.facets.vault;
        tokenFacet = art.facets.token;
        vm.prank(safeWallet);
        PausableFacet(address(diamond)).unpause();

        asset.mint(user, 10_000 ether);
        vm.prank(user);
        asset.approve(address(diamond), type(uint256).max);
    }

    function testDirectTokenFacetInitRejectsZeroAsset() public {
        DirectTokenFacetHarness direct = new DirectTokenFacetHarness();
        _enterInitContext(address(direct));
        vm.expectRevert(TokenFacet.ZeroAsset.selector);
        direct.initToken(address(0), "Wrapped", "wCYGLD");
    }

    function testDirectTokenFacetErc4626FlowAndAllowanceBranches() public {
        DirectTokenFacetHarness direct = _directTokenFacet();
        asset.mint(user, 1_000 ether);
        asset.mint(address(this), 100 ether);

        vm.startPrank(user);
        asset.approve(address(direct), type(uint256).max);
        uint256 shares = direct.deposit(200 ether, user);
        assertEq(shares, 200 ether);
        assertEq(direct.balanceOf(user), 200 ether);

        direct.approve(receiver, 50 ether);
        vm.stopPrank();

        vm.prank(receiver);
        assertTrue(direct.transferFrom(user, receiver, 40 ether));
        assertEq(direct.allowance(user, receiver), 10 ether);
        assertEq(direct.balanceOf(receiver), 40 ether);

        vm.prank(receiver);
        uint256 assetsOut = direct.redeem(25 ether, receiver, receiver);
        assertEq(assetsOut, 25 ether);
        assertEq(asset.balanceOf(receiver), 25 ether);

        asset.approve(address(direct), type(uint256).max);
        uint256 assetsIn = direct.mint(10 ether, address(this));
        assertEq(assetsIn, 10 ether);
        uint256 burnedShares = direct.withdraw(5 ether, address(this), address(this));
        assertEq(burnedShares, 5 ether);
    }

    function testDirectTokenFacetZeroAmountsAndPausedLimits() public {
        DirectTokenFacetHarness direct = _directTokenFacet();
        asset.mint(user, 100 ether);
        vm.prank(user);
        asset.approve(address(direct), type(uint256).max);

        vm.expectRevert(TokenFacet.ZeroAmount.selector);
        vm.prank(user);
        direct.deposit(0, user);

        vm.expectRevert(TokenFacet.ZeroAmount.selector);
        vm.prank(user);
        direct.mint(0, user);

        vm.prank(user);
        direct.deposit(10 ether, user);

        vm.expectRevert(TokenFacet.ZeroAmount.selector);
        vm.prank(user);
        direct.withdraw(0, user, user);

        vm.expectRevert(TokenFacet.ZeroAmount.selector);
        vm.prank(user);
        direct.redeem(0, user, user);

        direct.pauseForTest();
        assertEq(direct.maxDeposit(user), 0);
        assertEq(direct.maxMint(user), 0);
        assertEq(direct.maxWithdraw(user), 0);
        assertEq(direct.maxRedeem(user), 0);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        direct.mintSupplyForTest(receiver, 1 ether);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        direct.burnSupplyForTest(user, 1 ether);

        direct.transferSupplyForTest(user, receiver, 1 ether);
        assertEq(direct.balanceOf(receiver), 1 ether);

        vm.expectRevert();
        vm.prank(user);
        direct.deposit(1 ether, user);

        direct.unpauseForTest();
        assertGt(direct.maxDeposit(user), 0);
        assertGt(direct.maxMint(user), 0);
        assertEq(direct.maxRedeem(user), 9 ether);
    }

    function testInitLeavesPersistentReentrancyGuardSlotUnused() public view {
        assertEq(vm.load(address(diamond), REENTRANCY_GUARD_STORAGE), bytes32(0));
        assertFalse(IERC165(address(diamond)).supportsInterface(type(IERC20Permit).interfaceId));
        assertEq(IDiamondLoupe(address(diamond)).facetAddress(IERC20Permit.permit.selector), address(0));
    }

    function testDepositMintWithdrawRedeem() public {
        TokenFacet token = TokenFacet(address(diamond));
        assertEq(token.share(), address(diamond));

        vm.prank(user);
        uint256 shares = token.deposit(1_000 ether, user);
        assertEq(shares, 1_000 ether);
        assertEq(token.totalSupply(), 1_000 ether);
        assertEq(token.balanceOf(user), 1_000 ether);
        assertEq(asset.balanceOf(address(diamond)), 1_000 ether);

        // Mint shares by specifying shares
        vm.prank(user);
        uint256 assetsIn = token.mint(500 ether, user);
        assertEq(assetsIn, 500 ether);
        assertEq(token.balanceOf(user), 1_500 ether);
        assertEq(asset.balanceOf(address(diamond)), 1_500 ether);

        // Withdraw and redeem are routed through the queue; expect reverts here.
        vm.prank(user);
        vm.expectRevert(QueueRequestBase.ZeroAmount.selector);
        token.withdraw(400 ether, receiver, user);

        vm.prank(user);
        vm.expectRevert(QueueRequestBase.ZeroAmount.selector);
        token.redeem(1_100 ether, receiver, user);
    }

    function testAllowancesRespected() public {
        TokenFacet token = TokenFacet(address(diamond));
        vm.prank(user);
        token.deposit(200 ether, user);

        vm.prank(user);
        token.approve(receiver, 50 ether);

        vm.prank(receiver);
        require(token.transferFrom(user, receiver, 50 ether), "transfer failed");
        assertEq(token.balanceOf(receiver), 50 ether);
        assertEq(token.balanceOf(user), 150 ether);

        vm.prank(receiver);
        vm.expectRevert(QueueRequestBase.ZeroAmount.selector);
        token.redeem(50 ether, receiver, receiver); // redeem blocked via queue
    }

    function testPauseBlocksMintingButAllowsTransfers() public {
        TokenFacet token = TokenFacet(address(diamond));
        vm.prank(user);
        token.deposit(100 ether, user);

        vm.prank(pauser);
        PausableFacet(address(diamond)).pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        token.deposit(1 ether, user);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        token.mint(1 ether, user);

        vm.prank(user);
        assertTrue(token.transfer(receiver, 10 ether));
        assertEq(token.balanceOf(receiver), 10 ether);

        PausableFacet pause = PausableFacet(address(diamond));
        vm.prank(pause.safeWallet());
        pause.unpause();
        vm.prank(user);
        token.deposit(1 ether, user);
    }

    function _directTokenFacet() internal returns (DirectTokenFacetHarness direct) {
        direct = new DirectTokenFacetHarness();
        _enterInitContext(address(direct));
        direct.initializeForTest(address(asset), "Wrapped Staked CYGLD", "wstCYGLD");
        vm.store(address(direct), INIT_CONTEXT_SLOT, bytes32(0));
    }

    function _enterInitContext(address target) internal {
        vm.store(target, INIT_CONTEXT_SLOT, bytes32(uint256(1)));
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

    function tokenSelectors() internal pure returns (bytes4[] memory selectors) {
        return FacetSelectors.tokenSelectors();
    }

    function pauseSelectors() internal pure returns (bytes4[] memory selectors) {
        return SharedFacetSelectors.pauseSelectors();
    }

    function reentrancySelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = ReentrancyGuardFacet.initReentrancyGuard.selector;
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

    function fundManagerSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = MockFundManagerTF.stakerAssetsInSleeves.selector;
    }
}
