// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {CoreDiamond} from "../../src/diamond/CoreDiamond.sol";
import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";
import {ICoreTypes} from "../../src/interfaces/ICoreTypes.sol";
import {IssuanceFacet} from "../../src/facets/IssuanceFacet.sol";
import {LensFacet} from "../../src/facets/LensFacet.sol";
import {RebalanceFacet} from "../../src/facets/RebalanceFacet.sol";
import {RedemptionFacet} from "../../src/facets/RedemptionFacet.sol";
import {TokenFacet} from "../../src/facets/TokenFacet.sol";
import {IRecoveryTypes} from "../../src/interfaces/IRecoveryTypes.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {DiamondCutFacet as BootstrapDiamondCutFacet} from "diamond-1/facets/DiamondCutFacet.sol";

contract CoreDeploymentHelperTest is Test {
    address internal admin = address(this);
    address internal treasury = address(0xB0B);
    address internal user = address(0xCAFE);

    MockERC20 internal tokA;
    MockERC20 internal tokB;

    function setUp() public {
        tokA = new MockERC20("Gold A", "GLDA", 18);
        tokB = new MockERC20("Gold B", "GLDB", 18);
    }

    function test_deploy_and_issue_via_helper() public {
        DeploymentTypes.DeployConfig memory cfg = _coreConfig();

        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.deploy(cfg);
        _assertExactTopology(art);
        _assertInitialAuthority(art, cfg.safeWallet, cfg.admin);
        _assertLaunchPausedAndActivate(address(art.diamond));

        // Fund user and approve controller (diamond) to pull assets.
        tokA.mint(user, 10_000 ether);
        tokB.mint(user, 10_000 ether);
        vm.startPrank(user);
        tokA.approve(address(art.diamond), type(uint256).max);
        tokB.approve(address(art.diamond), type(uint256).max);

        IssuanceFacet issuance = IssuanceFacet(address(art.diamond));
        TokenFacet token = TokenFacet(address(art.diamond));

        uint256 netCygldOut = 1 ether;
        (uint256 issuedNetCygldOut, uint256 protocolFeeCygld, uint256[] memory amountsIn) = issuance.issue(netCygldOut);
        vm.stopPrank();

        assertEq(amountsIn.length, 2);
        assertEq(issuedNetCygldOut, netCygldOut, "caller received requested net");
        assertEq(token.totalSupply(), netCygldOut + protocolFeeCygld, "minted gross supply");
        assertEq(token.balanceOf(user), netCygldOut, "user received exact net amount");
        assertEq(token.balanceOf(treasury), protocolFeeCygld, "treasury received protocol fee");

        // Lens returns the configured basket/fees.
        LensFacet lens = LensFacet(address(art.diamond));
        assertEq(lens.treasury(), treasury);
        assertEq(lens.issuanceFeePpm(), 1_000);
        assertEq(lens.redemptionFeePpm(), 1_000);
        assertEq(lens.maxTotalSupply(), 250 ether);

        PausableFacet pause = PausableFacet(address(art.diamond));
        assertTrue(pause.canPause(admin), "admin Safe owner cannot pause");
        assertTrue(pause.canUnpause(pause.safeWallet()), "Safe wallet cannot unpause");
    }

    function test_deployCoreShell_idempotentlyAdoptsExactCanonicalDeployment() public {
        bytes32 salt = keccak256("core-shell-idempotent");
        (CoreDiamond first, address firstBootstrap) = DeploymentHelper.deployCoreShell(address(this), salt);
        (CoreDiamond adopted, address adoptedBootstrap) = DeploymentHelper.deployCoreShell(address(this), salt);

        assertEq(address(adopted), address(first));
        assertEq(adoptedBootstrap, firstBootstrap);
    }

    function test_deployCoreShell_ordinaryCreateRequiresOwnerAndDeploysBootstrapShell() public {
        vm.expectRevert(bytes("DeploymentHelper: bootstrap owner missing"));
        this.deployCoreShellForTest(address(0));

        (CoreDiamond shell, address bootstrap) = this.deployCoreShellForTest(address(this));
        assertGt(address(shell).code.length, 0);
        assertGt(bootstrap.code.length, 0);
    }

    function test_deployCoreShellFrom_requiresConfiguredDeployerAndAdoptsCanonicalDeployment() public {
        bytes32 salt = keccak256("core-shell-explicit-deployer");

        vm.expectRevert(bytes("DeploymentHelper: CREATE2 deployer missing"));
        this.deployCoreShellFromForTest(address(this), salt, address(0));

        (CoreDiamond first, address firstBootstrap) =
            this.deployCoreShellFromForTest(address(this), salt, address(this));
        (CoreDiamond adopted, address adoptedBootstrap) =
            this.deployCoreShellFromForTest(address(this), salt, address(this));

        assertEq(address(adopted), address(first));
        assertEq(adoptedBootstrap, firstBootstrap);
    }

    function test_deployCoreShellFrom_rejectsConfiguredBootstrapAddressMismatch() public {
        vm.expectRevert(bytes("DeploymentHelper: bootstrap address mismatch"));
        this.deployCoreShellFromForTest(
            address(this), keccak256("core-shell-bootstrap-address-mismatch"), address(0xDEAD)
        );
    }

    function test_deployCoreShellFrom_rejectsAdoptedBootstrapRuntimeMismatch() public {
        bytes32 salt = keccak256("core-shell-bootstrap-runtime-mismatch");
        (, address bootstrap) = this.deployCoreShellFromForTest(address(this), salt, address(this));
        vm.etch(bootstrap, hex"00");

        vm.expectRevert(bytes("DeploymentHelper: bootstrap runtime mismatch"));
        this.deployCoreShellFromForTest(address(this), salt, address(this));
    }

    function test_deployCoreShellFrom_rejectsConfiguredDiamondAddressMismatch() public {
        bytes32 salt = keccak256("core-shell-diamond-address-mismatch");
        address configuredDeployer = address(0xDEAD);
        bytes32 bootstrapSalt = keccak256(abi.encodePacked("cybergold.core.bootstrapCut", salt));
        address configuredBootstrap =
            _create2Address(configuredDeployer, bootstrapSalt, keccak256(type(BootstrapDiamondCutFacet).creationCode));
        vm.etch(configuredBootstrap, type(BootstrapDiamondCutFacet).runtimeCode);

        vm.expectRevert(bytes("DeploymentHelper: diamond address mismatch"));
        this.deployCoreShellFromForTest(address(this), salt, configuredDeployer);
    }

    function test_deployCoreShellFrom_rejectsAdoptedDiamondRuntimeMismatch() public {
        bytes32 salt = keccak256("core-shell-diamond-runtime-mismatch");
        (CoreDiamond shell,) = this.deployCoreShellFromForTest(address(this), salt, address(this));
        vm.etch(address(shell), hex"00");

        vm.expectRevert(bytes("DeploymentHelper: diamond runtime mismatch"));
        this.deployCoreShellFromForTest(address(this), salt, address(this));
    }

    function test_deploy_shell_finalize_and_issue_withoutTemporaryWithdrawer() public {
        address bootstrapOwner = address(this);
        address finalAdmin = address(0xA11CE);
        (CoreDiamond shell,) = DeploymentHelper.deployCoreShell(bootstrapOwner, keccak256("core-shell-test"));

        DeploymentTypes.DeployConfig memory cfg = _coreConfigForAdmin(finalAdmin);
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.finalizeExisting(shell, cfg);
        assertEq(address(art.diamond), address(shell));

        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(address(shell));
        bytes32 upgraderRole = access.upgraderRole();
        assertEq(access.defaultAdmin(), cfg.safeWallet);
        assertTrue(access.hasRole(upgraderRole, cfg.safeWallet));
        assertFalse(access.hasRole(upgraderRole, finalAdmin));
        assertFalse(access.hasRole(upgraderRole, bootstrapOwner));
        PausableFacet pause = PausableFacet(address(shell));
        assertTrue(pause.canPause(finalAdmin));
        assertFalse(pause.canPause(bootstrapOwner));
        assertTrue(pause.canUnpause(cfg.safeWallet));

        vm.prank(cfg.safeWallet);
        pause.unpause();

        tokA.mint(user, 10_000 ether);
        tokB.mint(user, 10_000 ether);
        vm.startPrank(user);
        tokA.approve(address(shell), type(uint256).max);
        tokB.approve(address(shell), type(uint256).max);

        (uint256 issuedNetCygldOut, uint256 protocolFeeCygld, uint256[] memory amountsIn) =
            IssuanceFacet(address(shell)).issue(1 ether);
        vm.stopPrank();

        assertEq(amountsIn.length, 2);
        assertEq(issuedNetCygldOut, 1 ether);
        assertEq(TokenFacet(address(shell)).totalSupply(), issuedNetCygldOut + protocolFeeCygld);
        assertEq(TokenFacet(address(shell)).balanceOf(user), issuedNetCygldOut);
        assertEq(TokenFacet(address(shell)).balanceOf(treasury), protocolFeeCygld);
        LensFacet lens = LensFacet(address(shell));
        assertEq(lens.maxTotalSupply(), 250 ether);
        assertEq(lens.treasury(), treasury);
    }

    function test_defaultAdminTransferRequiresLaterTimestampAndKeepsUpgraderIndependent() public {
        DeploymentTypes.DeployConfig memory cfg = _coreConfig();
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.deploy(cfg);
        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(address(art.diamond));
        address candidate = address(0xD00D);

        vm.prank(cfg.safeWallet);
        access.beginDefaultAdminTransfer(candidate);
        (address pending, uint48 schedule) = access.pendingDefaultAdmin();
        assertEq(pending, candidate);
        assertEq(schedule, block.timestamp);

        vm.prank(candidate);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        access.acceptDefaultAdminTransfer();

        vm.warp(block.timestamp + 1);
        vm.prank(candidate);
        access.acceptDefaultAdminTransfer();

        assertEq(access.defaultAdmin(), candidate);
        assertTrue(access.hasRole(bytes32(0), candidate));
        assertFalse(access.hasRole(bytes32(0), cfg.safeWallet));
        assertTrue(access.hasRole(access.upgraderRole(), cfg.safeWallet));
        assertFalse(access.hasRole(access.upgraderRole(), candidate));
        _assertNoPendingAuthority(access);
    }

    function test_defaultAdminTransferCanBeReplacedAndCanceledWhileCoreIsPaused() public {
        DeploymentTypes.DeployConfig memory cfg = _coreConfig();
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.deploy(cfg);
        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(address(art.diamond));

        assertTrue(PausableFacet(address(art.diamond)).paused());
        vm.startPrank(cfg.safeWallet);
        access.beginDefaultAdminTransfer(address(0xA));
        access.beginDefaultAdminTransfer(address(0xB));
        (address pending,) = access.pendingDefaultAdmin();
        assertEq(pending, address(0xB));
        access.cancelDefaultAdminTransfer();
        vm.stopPrank();

        assertEq(access.defaultAdmin(), cfg.safeWallet);
        _assertNoPendingAuthority(access);
    }

    function test_finalizeDustedDeterministicShellTreatsLaunchCustodyAsLiveBacking() public {
        (CoreDiamond shell,) =
            DeploymentHelper.deployCoreShell(address(this), keccak256("core-shell-prefunded-reserve"));
        uint256 unsolicitedDustRaw = 17;
        tokA.mint(address(shell), unsolicitedDustRaw);

        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.finalizeExisting(shell, _coreConfig());
        IRecoveryTypes.ReserveLifecycleView memory launch =
            LensFacet(address(art.diamond)).reserveLifecycle(address(tokA));

        assertEq(tokA.balanceOf(address(shell)), unsolicitedDustRaw);
        assertEq(uint256(launch.lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Active));
        IRecoveryTypes.ReserveCustodyStatus memory custody =
            LensFacet(address(art.diamond)).reserveCustodyStatus(address(tokA));
        assertTrue(custody.liveBalanceAvailable);
        assertEq(custody.liveRawCustody, unsolicitedDustRaw);
        assertEq(custody.activeAvailableRaw, unsolicitedDustRaw);
    }

    function test_deploy_rejectsTooHighInitialFees() public {
        DeploymentTypes.DeployConfig memory cfg = _coreConfig();
        cfg.issuanceFeePpm = 10_001;

        vm.expectRevert(ICoreTypes.FeeTooHigh.selector);
        this.deployCoreForTest(cfg);
    }

    function test_deploy_rejectsSinglePositiveTargetReserve() public {
        DeploymentTypes.DeployConfig memory cfg = _coreConfig();
        cfg.basketAssets = new address[](1);
        cfg.basketAssets[0] = address(tokA);
        cfg.basketTargetsPpm = new uint256[](1);
        cfg.basketTargetsPpm[0] = 1_000_000;
        cfg.basketGoldRefGramsFp18 = new uint256[](1);
        cfg.basketGoldRefGramsFp18[0] = 1 ether;

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketInsufficientPositiveTargets.selector, 1, 2));
        this.deployCoreForTest(cfg);
    }

    function test_deploy_rejectsZeroAdmin() public {
        DeploymentTypes.DeployConfig memory cfg = _coreConfig();
        cfg.admin = address(0);

        vm.expectRevert(bytes("DeploymentHelper: admin missing"));
        this.deployCoreForTest(cfg);
    }

    function deployCoreForTest(DeploymentTypes.DeployConfig memory cfg)
        external
        returns (DeploymentTypes.DeployArtifacts memory)
    {
        return DeploymentHelper.deploy(cfg);
    }

    function deployCoreShellFromForTest(address bootstrapOwner, bytes32 salt, address create2Deployer)
        external
        returns (CoreDiamond diamond, address bootstrapDiamondCutFacet)
    {
        return DeploymentHelper.deployCoreShellFrom(bootstrapOwner, salt, create2Deployer);
    }

    function deployCoreShellForTest(address bootstrapOwner)
        external
        returns (CoreDiamond diamond, address bootstrapDiamondCutFacet)
    {
        return DeploymentHelper.deployCoreShell(bootstrapOwner);
    }

    function _assertLaunchPausedAndActivate(address core) private {
        PausableFacet pause = PausableFacet(core);
        assertTrue(pause.paused(), "Core must remain paused through Phase 1 postflight");

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(user);
        IssuanceFacet(core).issue(1 ether);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(user);
        RedemptionFacet(core).redeem(1 ether);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(user);
        RebalanceFacet(core).rebalanceSwapExactIn(address(tokA), address(tokB), 1 ether, 0);

        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, admin));
        pause.unpause();

        vm.prank(pause.safeWallet());
        pause.unpause();
        assertFalse(pause.paused(), "configured Safe did not activate Core");
    }

    function _assertExactTopology(DeploymentTypes.DeployArtifacts memory art) internal view {
        FacetSpec.Entry[] memory specs = DeploymentHelper.facetSpecs(art);
        IDiamondLoupe loupe = IDiamondLoupe(address(art.diamond));
        assertEq(loupe.facetAddresses().length, specs.length, "unexpected facet count");
        for (uint256 i; i < specs.length; ++i) {
            bytes4[] memory actual = loupe.facetFunctionSelectors(specs[i].facet);
            assertEq(actual.length, specs[i].selectors.length, "selector count mismatch");
            for (uint256 j; j < specs[i].selectors.length; ++j) {
                assertEq(loupe.facetAddress(specs[i].selectors[j]), specs[i].facet, "selector mapping mismatch");
            }
        }
    }

    function _assertInitialAuthority(
        DeploymentTypes.DeployArtifacts memory art,
        address safeWallet,
        address constructorAdmin
    ) private view {
        address core = address(art.diamond);
        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(core);
        bytes32 defaultAdminRole = access.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = access.upgraderRole();

        assertEq(access.defaultAdmin(), safeWallet);
        assertEq(access.defaultAdminDelay(), 0);
        assertEq(access.getRoleAdmin(upgraderRole), defaultAdminRole);
        assertEq(access.getRoleMemberCount(defaultAdminRole), 1);
        assertEq(access.getRoleMember(defaultAdminRole, 0), safeWallet);
        assertTrue(access.hasRole(defaultAdminRole, safeWallet));
        assertEq(access.getRoleMemberCount(upgraderRole), 1);
        assertEq(access.getRoleMember(upgraderRole, 0), safeWallet);
        assertTrue(access.hasRole(upgraderRole, safeWallet));
        assertFalse(access.hasRole(defaultAdminRole, constructorAdmin));
        assertFalse(access.hasRole(upgraderRole, constructorAdmin));
        _assertNoPendingAuthority(access);

        IDiamondLoupe loupe = IDiamondLoupe(core);
        assertEq(loupe.facetAddress(IERC5313.owner.selector), address(0));
        assertEq(loupe.facetFunctionSelectors(address(art.authorityInvariant)).length, 0);
        assertFalse(IERC165(core).supportsInterface(type(IERC5313).interfaceId));
        bytes32 ownerSlot = bytes32(uint256(keccak256("diamond.standard.diamond.storage")) + 3);
        assertEq(address(uint160(uint256(vm.load(core, ownerSlot)))), address(0));
    }

    function _assertNoPendingAuthority(DefaultAdminAccessControlFacet access) private view {
        (address candidate, uint48 schedule) = access.pendingDefaultAdmin();
        (uint48 pendingDelay, uint48 pendingDelaySchedule) = access.pendingDefaultAdminDelay();
        assertEq(candidate, address(0));
        assertEq(schedule, 0);
        assertEq(pendingDelay, 0);
        assertEq(pendingDelaySchedule, 0);
        assertEq(access.defaultAdminDelay(), 0);
    }

    function _coreConfig() internal returns (DeploymentTypes.DeployConfig memory cfg) {
        cfg = _coreConfigForAdmin(admin);
    }

    function _coreConfigForAdmin(address admin_) internal returns (DeploymentTypes.DeployConfig memory cfg) {
        cfg.admin = admin_;
        cfg.safeWallet = MockSafeWalletFactory.deploy(admin_);
        cfg.name = "CyberGold";
        cfg.symbol = "CYGLD";
        cfg.coreTreasury = treasury;

        cfg.basketAssets = new address[](2);
        cfg.basketAssets[0] = address(tokA);
        cfg.basketAssets[1] = address(tokB);
        cfg.basketTargetsPpm = new uint256[](2);
        cfg.basketTargetsPpm[0] = 500_000;
        cfg.basketTargetsPpm[1] = 500_000;
        cfg.basketGoldRefGramsFp18 = new uint256[](2);
        cfg.basketGoldRefGramsFp18[0] = 1e18;
        cfg.basketGoldRefGramsFp18[1] = 1e18;
        cfg.cygldRefGramsFp18 = 1e18;
        cfg.maxTotalSupply = 250 ether;
        cfg.issuanceFeePpm = 1_000;
        cfg.redemptionFeePpm = 1_000;
    }

    function _create2Address(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
