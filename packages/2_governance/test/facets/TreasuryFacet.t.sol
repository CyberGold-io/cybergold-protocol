// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";
import {GovernanceDiamond} from "../../src/diamond/GovernanceDiamond.sol";
import {ICyberGoldGovernance} from "../../src/interfaces/ICyberGoldGovernance.sol";
import {IRecoveryFundTypes} from "../../src/interfaces/IRecoveryFundTypes.sol";
import {TreasuryFacet} from "../../src/facets/TreasuryFacet.sol";
import {EtherNotAccepted} from "diamond-infra/diamond/ProtocolDiamond.sol";
import {AccessControlFacet} from "diamond-infra/facets/AccessControlFacet.sol";
import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {ReentrancyGuardFacet} from "diamond-infra/facets/ReentrancyGuardFacet.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeSingleton, MockSafeWallet} from "shared/helpers/MockSafeWallet.sol";

contract FeeOnTransferTreasuryToken is ERC20 {
    constructor() ERC20("Fee Asset", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value > 1) {
            super._update(from, address(0xDEAD), 1);
            value -= 1;
        }
        super._update(from, to, value);
    }
}

contract TreasuryCygldMock is ERC20 {
    mapping(address owner => uint256 exposure) internal _exposure;

    constructor() ERC20("Core CyberGold", "CYGLD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setAllowanceExposure(address owner, uint256 exposure) external {
        _exposure[owner] = exposure;
    }

    function allowanceExposure(address owner) external view returns (uint256) {
        return _exposure[owner];
    }
}

contract TreasuryFacetTest is Test {
    address internal admin = address(this);
    address internal user = address(0xBEEF);
    address internal recipient = address(0xCAFE);

    GovernanceDiamond internal diamond;
    TreasuryFacet internal treasury;
    AccessControlFacet internal access;
    DiamondLoupeFacet internal loupe;
    PausableFacet internal pause;
    MockERC20 internal asset;
    TreasuryCygldMock internal core;

    function setUp() public {
        core = new TreasuryCygldMock();
        DeploymentTypes.DeployArtifacts memory d = DeploymentHelper.deploy(_config());
        diamond = d.diamond;
        treasury = TreasuryFacet(address(diamond));
        access = AccessControlFacet(address(diamond));
        loupe = DiamondLoupeFacet(address(diamond));
        pause = PausableFacet(address(diamond));

        asset = new MockERC20("Treasury Asset", "TAST", 18);
        asset.mint(address(diamond), 100 ether);
        core.mint(address(diamond), 100 ether);
    }

    function test_init_setsCriticalRolesOnlyToGovernanceDiamond() public view {
        bytes32 defaultAdminRole = access.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = access.upgraderRole();

        assertEq(access.getRoleMemberCount(defaultAdminRole), 1);
        assertEq(access.getRoleMember(defaultAdminRole, 0), address(diamond));
        assertEq(access.getRoleMemberCount(upgraderRole), 1);
        assertEq(access.getRoleMember(upgraderRole, 0), address(diamond));
        assertFalse(access.hasRole(defaultAdminRole, admin));
        assertFalse(access.hasRole(upgraderRole, admin));
    }

    function test_init_usesSafeWalletPauseAuthority() public view {
        assertTrue(pause.canPause(admin));
        assertTrue(pause.canUnpause(pause.safeWallet()));
        assertFalse(pause.canUnpause(admin));
    }

    function test_treasuryPauseUsesSafeWalletAuthority() public {
        address stranger = address(0xD1A);

        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        pause.pause();

        vm.prank(admin);
        pause.pause();
        assertTrue(pause.paused());

        vm.expectRevert(ICyberGoldGovernance.EnforcedPause.selector);
        vm.prank(admin);
        treasury.treasuryWithdraw(address(asset), recipient, 1 ether);

        vm.prank(pause.safeWallet());
        pause.unpause();

        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        pause.pause();
    }

    function test_treasuryWithdraw_requiresDefaultAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ICyberGoldGovernance.AccessControlUnauthorizedAccount.selector, user, access.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(user);
        treasury.treasuryWithdraw(address(asset), recipient, 1 ether);
    }

    function test_treasuryWithdraw_sendsErc20HeldByGovernanceDiamond() public {
        vm.expectEmit(address(diamond));
        emit ICyberGoldGovernance.TreasuryWithdrawn(address(asset), recipient, 10 ether);

        vm.prank(address(diamond));
        treasury.treasuryWithdraw(address(asset), recipient, 10 ether);

        assertEq(asset.balanceOf(recipient), 10 ether);
        assertEq(asset.balanceOf(address(diamond)), 90 ether);
    }

    function test_treasuryWithdraw_preservesAggregateFundCommitment() public {
        _setAggregateCommitment(80 ether);

        vm.prank(address(diamond));
        treasury.treasuryWithdraw(address(core), recipient, 20 ether);

        assertEq(core.balanceOf(recipient), 20 ether);
        assertEq(core.balanceOf(address(diamond)), 80 ether);
    }

    function test_treasuryWithdraw_rejectsAmountReservedByAggregateFundCommitment() public {
        _setAggregateCommitment(80 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundCygldCommitmentDeficit.selector, 100 ether, 0, 101 ether
            )
        );
        vm.prank(address(diamond));
        treasury.treasuryWithdraw(address(core), recipient, 21 ether);

        assertEq(core.balanceOf(recipient), 0);
        assertEq(core.balanceOf(address(diamond)), 100 ether);
    }

    function test_treasuryWithdraw_rejectsCygldExposedByAllowances() public {
        _setAggregateCommitment(80 ether);
        core.setAllowanceExposure(address(diamond), 10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundCygldCommitmentDeficit.selector, 100 ether, 10 ether, 91 ether
            )
        );
        vm.prank(address(diamond));
        treasury.treasuryWithdraw(address(core), recipient, 11 ether);
    }

    function test_treasuryWithdraw_rejectsFeeOnTransferCreditMismatch() public {
        FeeOnTransferTreasuryToken feeAsset = new FeeOnTransferTreasuryToken();
        feeAsset.mint(address(diamond), 100 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundExactCreditMismatch.selector, address(feeAsset), 10 ether, 10 ether - 1
            )
        );
        vm.prank(address(diamond));
        treasury.treasuryWithdraw(address(feeAsset), recipient, 10 ether);

        assertEq(feeAsset.balanceOf(recipient), 0);
        assertEq(feeAsset.balanceOf(address(diamond)), 100 ether);
    }

    function test_treasuryWithdraw_zeroAmountNoop() public {
        vm.prank(address(diamond));
        treasury.treasuryWithdraw(address(asset), recipient, 0);

        assertEq(asset.balanceOf(recipient), 0);
        assertEq(asset.balanceOf(address(diamond)), 100 ether);
    }

    function test_treasuryWithdraw_zeroAddress_reverts() public {
        vm.startPrank(address(diamond));
        vm.expectRevert(ICyberGoldGovernance.ZeroAddress.selector);
        treasury.treasuryWithdraw(address(0), recipient, 1);
        vm.expectRevert(ICyberGoldGovernance.ZeroAddress.selector);
        treasury.treasuryWithdraw(address(asset), address(0), 1);
        vm.stopPrank();
    }

    function test_treasuryWithdraw_whenPaused_reverts() public {
        pause.pause();

        vm.expectRevert(ICyberGoldGovernance.EnforcedPause.selector);
        vm.prank(address(diamond));
        treasury.treasuryWithdraw(address(asset), recipient, 1 ether);
    }

    function test_plainEthTransfer_reverts() public {
        (bool ok, bytes memory err) = payable(address(diamond)).call{value: 1 wei}("");

        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(EtherNotAccepted.selector));
    }

    function test_fallbackRejectsValueForKnownSelector() public {
        (bool ok,) = address(diamond).call{value: 1 wei}(abi.encodeWithSignature("paused()"));

        assertFalse(ok);
        assertEq(address(diamond).balance, 0);
    }

    function test_executionSelectorsRejectCallerFundedValue() public {
        bytes[] memory payloads = new bytes[](0);
        address[] memory targets = new address[](0);
        uint256[] memory values = new uint256[](0);

        (bool governorOk,) = address(diamond).call{value: 1 wei}(
            abi.encodeWithSelector(
                bytes4(keccak256("execute(address[],uint256[],bytes[],bytes32)")), targets, values, payloads, bytes32(0)
            )
        );
        (bool removedSingleExecuteOk,) = address(diamond).call{value: 1 wei}(
            abi.encodeWithSignature(
                "execute(address,uint256,bytes,bytes32,bytes32)", address(0), 0, bytes(""), bytes32(0), bytes32(0)
            )
        );
        (bool removedBatchExecuteOk,) = address(diamond).call{value: 1 wei}(
            abi.encodeWithSignature(
                "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)",
                targets,
                values,
                payloads,
                bytes32(0),
                bytes32(0)
            )
        );

        assertFalse(governorOk);
        assertFalse(removedSingleExecuteOk);
        assertFalse(removedBatchExecuteOk);
        assertEq(address(diamond).balance, 0);
    }

    function test_noTreasuryBalanceOrEthWithdrawSelectors() public {
        (bool balanceOk,) =
            address(diamond).staticcall(abi.encodeWithSignature("treasuryBalance(address)", address(asset)));
        (bool balancesOk,) =
            address(diamond).staticcall(abi.encodeWithSignature("treasuryBalances(address[])", new address[](0)));
        (bool nativeBalanceOk,) = address(diamond).staticcall(abi.encodeWithSignature("treasuryNativeBalance()"));
        (bool ethWithdrawOk,) =
            address(diamond).call(abi.encodeWithSignature("treasuryWithdrawETH(address,uint256)", recipient, 1));

        assertFalse(balanceOk);
        assertFalse(balancesOk);
        assertFalse(nativeBalanceOk);
        assertFalse(ethWithdrawOk);
        assertEq(IERC20(address(diamond)).balanceOf(address(asset)), 0);
        assertEq(asset.balanceOf(address(diamond)), 100 ether);
    }

    function test_reentrancyInitializerIsNotInstalledAsRuntimeSelector() public view {
        assertEq(loupe.facetAddress(ReentrancyGuardFacet.initReentrancyGuard.selector), address(0));
    }

    function _config() internal returns (DeploymentTypes.DeployConfig memory cfg) {
        cfg.constructorOwner = admin;
        address[] memory owners = new address[](1);
        owners[0] = admin;
        cfg.safeWallet = address(new MockSafeWallet(address(new MockSafeSingleton()), owners, 1));
        cfg.trustedCore = address(core);
        cfg.executionDelay = 1 days;
        cfg.executionGracePeriod = 14 days;
        cfg.name = "CyberGold Governance";
        cfg.tokenSymbol = "CYGOV";
        cfg.tokenInitialHolder = admin;
        cfg.tokenInitialSupply = 100 ether;
        cfg.tokenTreasurySupply = 0;
        cfg.votingDelay = 1 days;
        cfg.votingPeriod = 1 weeks;
        cfg.proposalThresholdNumerator = 100;
        cfg.quorumNumerator = 8;
    }

    function _setAggregateCommitment(uint256 amount) internal {
        uint256 namespace = uint256(0x902e6a2d7e9cb88e4a3b9fa10fb5f40f0aa4c8c068454989655905c02697f900);
        // trustedCore occupies slot zero; totalCommittedCygld is slot one.
        vm.store(address(diamond), bytes32(namespace + 1), bytes32(amount));
    }
}
