// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {MockStakingDiamond} from "../helpers/MockStakingDiamond.sol";
import {ISleeve} from "../../src/sleeves/ISleeve.sol";
import {SleeveBase} from "../../src/sleeves/SleeveBase.sol";

contract StructuralStakingDiamondCandidate {
    bytes32 internal immutable _adminRole;
    bytes32 internal immutable _upgradeRole;
    address internal immutable _safeWallet;
    uint8 internal immutable _booleanMode;

    constructor(bytes32 adminRole_, bytes32 upgradeRole_, address safeWallet_, uint8 booleanMode_) {
        _adminRole = adminRole_;
        _upgradeRole = upgradeRole_;
        _safeWallet = safeWallet_;
        _booleanMode = booleanMode_;
    }

    function DEFAULT_ADMIN_ROLE() external view returns (bytes32) {
        return _adminRole;
    }

    function upgraderRole() external view returns (bytes32) {
        return _upgradeRole;
    }

    function safeWallet() external view returns (address) {
        return _safeWallet;
    }

    function hasRole(bytes32, address) external view returns (bool) {
        return _respond();
    }

    function canPause(address) external view returns (bool) {
        return _respond();
    }

    function canUnpause(address) external view returns (bool) {
        return _respond();
    }

    function _respond() internal view returns (bool) {
        if (_booleanMode == 1) revert();
        if (_booleanMode == 2) {
            assembly {
                return(0, 0)
            }
        }
        if (_booleanMode == 3) {
            assembly {
                mstore(0, 2)
                return(0, 0x20)
            }
        }
        return false;
    }
}

contract MissingBooleanAuthorityCandidate {
    function DEFAULT_ADMIN_ROLE() external pure returns (bytes32) {
        return bytes32(0);
    }

    function upgraderRole() external pure returns (bytes32) {
        return keccak256("UPGRADER_ROLE");
    }

    function safeWallet() external pure returns (address) {
        return address(0x5AFE);
    }
}

contract SleeveBaseTest is Test {
    bytes32 internal constant REENTRANCY_GUARD_STORAGE =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    MockERC20 internal asset;
    MockStakingDiamond internal stakingDiamond;
    MockSleeve internal sleeve;

    address internal admin = address(this);
    address internal pauser = address(0xBEEF);
    address internal unpauser = address(0xCAFE);

    function setUp() public {
        asset = new MockERC20("Asset", "AST", 18);
        stakingDiamond = new MockStakingDiamond(admin, unpauser);
        stakingDiamond.setCanPause(pauser, true);
        stakingDiamond.setCanUnpause(unpauser, true);

        MockSleeve implementation = new MockSleeve();
        sleeve = MockSleeve(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(MockSleeve.initialize, (address(stakingDiamond), address(asset), 0))
                )
            )
        );
        stakingDiamond.setSleeveCaller(address(sleeve), true);
    }

    function test_init_leavesPersistentSleeveReentrancyGuardSlotUnused() public view {
        assertEq(vm.load(address(sleeve), REENTRANCY_GUARD_STORAGE), bytes32(0));
    }

    function test_controllerIsSingleStakingDiamondAddress() public view {
        assertEq(sleeve.stakingDiamond(), address(stakingDiamond));
    }

    function test_initialize_rejectsZeroBaseArgs() public {
        MockSleeve implementation = new MockSleeve();
        vm.expectRevert(ISleeve.ZeroAddress.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(MockSleeve.initialize, (address(0), address(asset), 0))
        );
    }

    function test_initialize_rejectsInvalidStakingDiamondSurfaces() public {
        _expectInvalidStakingDiamond(address(0xBEEF));
        _expectInvalidStakingDiamond(address(new MissingBooleanAuthorityCandidate()));
        _expectInvalidStakingDiamond(
            address(
                new StructuralStakingDiamondCandidate(
                    keccak256("WRONG_ADMIN_ROLE"), keccak256("UPGRADER_ROLE"), address(0x5AFE), 0
                )
            )
        );
        _expectInvalidStakingDiamond(
            address(
                new StructuralStakingDiamondCandidate(
                    bytes32(0), keccak256("WRONG_UPGRADER_ROLE"), address(0x5AFE), 0
                )
            )
        );
        _expectInvalidStakingDiamond(
            address(new StructuralStakingDiamondCandidate(bytes32(0), keccak256("UPGRADER_ROLE"), address(0), 0))
        );
        _expectInvalidStakingDiamond(
            address(
                new StructuralStakingDiamondCandidate(
                    bytes32(0), keccak256("UPGRADER_ROLE"), address(0x5AFE), 3
                )
            )
        );
    }

    function test_allocate_movesFundsFromCustody() public {
        asset.mint(address(stakingDiamond), 1_000 ether);

        vm.prank(address(stakingDiamond));
        uint256 used = sleeve.allocate(400 ether, "");
        assertEq(used, 400 ether);
        assertEq(asset.balanceOf(address(sleeve)), 400 ether);
        assertEq(sleeve.principalAssets(), 400 ether);
        assertEq(asset.balanceOf(address(stakingDiamond)), 600 ether);
    }

    function test_allocate_onlyStakingDiamond() public {
        vm.expectRevert(abi.encodeWithSelector(ISleeve.NotStakingDiamond.selector, address(this)));
        sleeve.allocate(100, "");
    }

    function test_allocatorRoleHolderCannotOperateSleeveDirectly() public {
        address allocator = address(0xA110C);
        stakingDiamond.grantRole(stakingDiamond.ALLOCATOR_ROLE(), allocator);
        asset.mint(address(stakingDiamond), 100 ether);

        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(ISleeve.NotStakingDiamond.selector, allocator));
        sleeve.allocate(100 ether, "");

        assertEq(sleeve.principalAssets(), 0);
        assertEq(asset.balanceOf(address(stakingDiamond)), 100 ether);

        vm.prank(address(stakingDiamond));
        assertEq(sleeve.allocate(100 ether, ""), 100 ether);
    }

    function testFuzz_nonDiamondCallerCannotChangePrincipal(address caller, uint96 rawAssets) public {
        vm.assume(caller != address(stakingDiamond));
        uint256 assets = bound(uint256(rawAssets), 1, 1_000_000 ether);
        asset.mint(address(stakingDiamond), assets);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ISleeve.NotStakingDiamond.selector, caller));
        sleeve.allocate(assets, "");

        assertEq(sleeve.principalAssets(), 0);
        assertEq(asset.balanceOf(address(stakingDiamond)), assets);
        assertEq(asset.balanceOf(address(sleeve)), 0);
    }

    function test_deallocate_returnsFundsToCustody() public {
        asset.mint(address(stakingDiamond), 1_000 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(500 ether, "");

        vm.prank(address(stakingDiamond));
        uint256 returned = sleeve.deallocate(200 ether, "");
        assertEq(returned, 200 ether);
        assertEq(asset.balanceOf(address(stakingDiamond)), 700 ether);
        assertEq(sleeve.principalAssets(), 300 ether);
    }

    function test_deallocateReturnedAbovePrincipalZerosPrincipal() public {
        asset.mint(address(stakingDiamond), 500 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(100 ether, "");
        asset.mint(address(sleeve), 75 ether);

        vm.prank(address(stakingDiamond));
        uint256 returned = sleeve.deallocate(150 ether, "");

        assertEq(returned, 150 ether);
        assertEq(sleeve.principalAssets(), 0);
    }

    function test_deallocate_zeroAmount_reverts() public {
        vm.expectRevert(ISleeve.ZeroAmount.selector);
        vm.prank(address(stakingDiamond));
        sleeve.deallocate(0, "");
    }

    function test_pause_blocksAllocate() public {
        asset.mint(address(stakingDiamond), 1_000 ether);
        vm.prank(pauser);
        sleeve.pause();

        vm.prank(address(stakingDiamond));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        sleeve.allocate(100, "");

        vm.prank(unpauser);
        sleeve.unpause();
        assertFalse(sleeve.paused());
    }

    function test_pause_allowsDeallocate() public {
        asset.mint(address(stakingDiamond), 1_000 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(500 ether, "");
        vm.prank(pauser);
        sleeve.pause();

        vm.prank(address(stakingDiamond));
        uint256 returned = sleeve.deallocate(200 ether, "");

        assertEq(returned, 200 ether);
        assertEq(asset.balanceOf(address(stakingDiamond)), 700 ether);
        assertEq(sleeve.principalAssets(), 300 ether);
    }

    function test_pauseAuthorityTracksLiveStakingDiamondDecisions() public {
        vm.prank(pauser);
        sleeve.pause();
        vm.prank(unpauser);
        sleeve.unpause();

        stakingDiamond.setCanPause(pauser, false);
        address replacementPauser = address(0xABCD);
        stakingDiamond.setCanPause(replacementPauser, true);

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(SleeveBase.EmergencyAuthorityUnauthorizedAccount.selector, pauser));
        sleeve.pause();
        vm.prank(replacementPauser);
        sleeve.pause();
    }

    function test_unpauseAuthorityIsSeparateFromAdminAndPauser() public {
        vm.prank(pauser);
        sleeve.pause();

        vm.expectRevert(abi.encodeWithSelector(SleeveBase.EmergencyAuthorityUnauthorizedAccount.selector, admin));
        sleeve.unpause();
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(SleeveBase.EmergencyAuthorityUnauthorizedAccount.selector, pauser));
        sleeve.unpause();
        vm.prank(unpauser);
        sleeve.unpause();
    }

    function test_authorityQueryFailuresFailClosed() public {
        for (uint8 mode = 1; mode <= 5; ++mode) {
            stakingDiamond.setResponseMode(mode);
            vm.prank(pauser);
            vm.expectRevert(abi.encodeWithSelector(SleeveBase.EmergencyAuthorityUnauthorizedAccount.selector, pauser));
            sleeve.pause();
            assertFalse(sleeve.paused());
        }
    }

    function test_unpauseAuthorityQueryFailuresFailClosedAndPreservePause() public {
        for (uint8 mode = 1; mode <= 5; ++mode) {
            stakingDiamond.setResponseMode(0);
            vm.prank(pauser);
            sleeve.pause();

            stakingDiamond.setResponseMode(mode);
            vm.prank(unpauser);
            vm.expectRevert(
                abi.encodeWithSelector(SleeveBase.EmergencyAuthorityUnauthorizedAccount.selector, unpauser)
            );
            sleeve.unpause();
            assertTrue(sleeve.paused());

            stakingDiamond.setResponseMode(0);
            vm.prank(unpauser);
            sleeve.unpause();
        }
    }

    function test_harvest_sendsProfitToStakingDiamond() public {
        asset.mint(address(stakingDiamond), 1_000 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(500 ether, "");

        asset.mint(address(sleeve), 50 ether); // simulate profit sitting on the sleeve

        vm.prank(address(stakingDiamond));
        uint256 harvested = sleeve.harvest("");
        assertEq(harvested, 50 ether);
        assertEq(asset.balanceOf(address(stakingDiamond)), 550 ether);
        assertEq(sleeve.principalAssets(), 500 ether);
    }

    function test_allocate_revertsWhenNotOperational() public {
        sleeve.setOperational(false);
        asset.mint(address(stakingDiamond), 200 ether);
        vm.prank(address(stakingDiamond));
        vm.expectRevert(SleeveBase.SleeveNotOperational.selector);
        sleeve.allocate(100 ether, "");
    }

    function test_setOperational_onlyAdmin() public {
        sleeve.setOperational(false);
        assertEq(sleeve.operational(), false);

        vm.prank(address(stakingDiamond));
        vm.expectRevert();
        sleeve.setOperational(true);
    }

    function test_configurationAndUpgradeFollowSeparateLiveDiamondRoles() public {
        address configurationAdmin = address(0xC0F1);
        address upgrader = address(0xA6DE);
        bytes32 defaultAdminRole = stakingDiamond.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = stakingDiamond.UPGRADER_ROLE();
        stakingDiamond.grantRole(defaultAdminRole, configurationAdmin);
        stakingDiamond.grantRole(upgraderRole, upgrader);

        vm.prank(configurationAdmin);
        sleeve.setOperational(false);
        assertFalse(sleeve.operational());

        MockSleeve newImplementation = new MockSleeve();
        bytes32 implementationBefore = vm.load(address(sleeve), IMPLEMENTATION_SLOT);

        vm.prank(configurationAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                SleeveBase.StakingDiamondAuthorityUnauthorizedAccount.selector,
                configurationAdmin,
                upgraderRole
            )
        );
        sleeve.upgradeToAndCall(address(newImplementation), "");
        assertEq(vm.load(address(sleeve), IMPLEMENTATION_SLOT), implementationBefore);

        vm.prank(upgrader);
        vm.expectRevert(
            abi.encodeWithSelector(
                SleeveBase.StakingDiamondAuthorityUnauthorizedAccount.selector,
                upgrader,
                defaultAdminRole
            )
        );
        sleeve.setOperational(true);

        vm.prank(upgrader);
        sleeve.upgradeToAndCall(address(newImplementation), "");
        assertEq(vm.load(address(sleeve), IMPLEMENTATION_SLOT), bytes32(uint256(uint160(address(newImplementation)))));
    }

    function test_safeOwnerCannotConfigureOrUpgradeWithoutDiamondRoles() public {
        MockSleeve newImplementation = new MockSleeve();
        bytes32 defaultAdminRole = stakingDiamond.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = stakingDiamond.UPGRADER_ROLE();

        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(
                SleeveBase.StakingDiamondAuthorityUnauthorizedAccount.selector,
                pauser,
                defaultAdminRole
            )
        );
        sleeve.setOperational(false);

        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(
                SleeveBase.StakingDiamondAuthorityUnauthorizedAccount.selector,
                pauser,
                upgraderRole
            )
        );
        sleeve.upgradeToAndCall(address(newImplementation), "");
    }

    function test_configurationAuthorityFailuresFailClosedAndPreserveState() public {
        for (uint8 mode = 1; mode <= 5; ++mode) {
            stakingDiamond.setResponseMode(mode);
            vm.expectRevert(
                abi.encodeWithSelector(
                    SleeveBase.StakingDiamondAuthorityUnauthorizedAccount.selector,
                    admin,
                    stakingDiamond.DEFAULT_ADMIN_ROLE()
                )
            );
            sleeve.setOperational(false);
            assertTrue(sleeve.operational());
        }
        stakingDiamond.setResponseMode(0);
    }

    function testFuzz_configurationSuccessEqualsPublishedDiamondDecision(address caller, bool authorize) public {
        vm.assume(caller != address(0) && caller != admin);
        bytes32 role = stakingDiamond.DEFAULT_ADMIN_ROLE();
        if (authorize) stakingDiamond.grantRole(role, caller);

        bool decision = stakingDiamond.hasRole(role, caller);
        vm.prank(caller);
        (bool ok,) = address(sleeve).call(abi.encodeWithSelector(SleeveBase.setOperational.selector, false));

        assertEq(ok, decision);
        assertEq(!sleeve.operational(), decision);
    }

    function test_upgradeAuthorityFailuresFailClosedAndPreserveImplementation() public {
        MockSleeve newImplementation = new MockSleeve();
        bytes32 implementationBefore = vm.load(address(sleeve), IMPLEMENTATION_SLOT);

        for (uint8 mode = 1; mode <= 5; ++mode) {
            stakingDiamond.setResponseMode(mode);
            vm.expectRevert(
                abi.encodeWithSelector(
                    SleeveBase.StakingDiamondAuthorityUnauthorizedAccount.selector,
                    admin,
                    stakingDiamond.UPGRADER_ROLE()
                )
            );
            sleeve.upgradeToAndCall(address(newImplementation), "");
            assertEq(vm.load(address(sleeve), IMPLEMENTATION_SLOT), implementationBefore);
        }
        stakingDiamond.setResponseMode(0);
    }

    function testFuzz_upgradeSuccessEqualsPublishedDiamondDecision(address caller, bool authorize) public {
        vm.assume(caller != address(0) && caller != admin);
        bytes32 role = stakingDiamond.UPGRADER_ROLE();
        if (authorize) stakingDiamond.grantRole(role, caller);
        bool decision = stakingDiamond.hasRole(role, caller);

        MockSleeve newImplementation = new MockSleeve();
        bytes32 implementationBefore = vm.load(address(sleeve), IMPLEMENTATION_SLOT);
        vm.prank(caller);
        (bool ok,) = address(sleeve).call(
            abi.encodeWithSelector(sleeve.upgradeToAndCall.selector, address(newImplementation), bytes(""))
        );

        assertEq(ok, decision);
        bytes32 implementationAfter = vm.load(address(sleeve), IMPLEMENTATION_SLOT);
        assertEq(implementationAfter != implementationBefore, decision);
    }

    function test_configurationAndUpgradeRemainAvailableWhileSleevePaused() public {
        vm.prank(pauser);
        sleeve.pause();

        sleeve.setOperational(false);
        MockSleeve newImplementation = new MockSleeve();
        sleeve.upgradeToAndCall(address(newImplementation), "");

        assertTrue(sleeve.paused());
        assertFalse(sleeve.operational());
        assertEq(vm.load(address(sleeve), IMPLEMENTATION_SLOT), bytes32(uint256(uint160(address(newImplementation)))));
    }

    function test_cleanSleeveHasNoLocalAccessControlOrLegacyControllerSelectors() public {
        _assertSelectorAbsent(abi.encodeWithSignature("FUND_MANAGER_ROLE()"));
        _assertSelectorAbsent(abi.encodeWithSignature("fundManager()"));
        _assertSelectorAbsent(abi.encodeWithSignature("custody()"));
        _assertSelectorAbsent(abi.encodeWithSignature("getRoleMemberCount(bytes32)", bytes32(0)));
        _assertSelectorAbsent(abi.encodeWithSignature("grantRole(bytes32,address)", bytes32(0), address(this)));
        _assertSelectorAbsent(abi.encodeWithSignature("revokeRole(bytes32,address)", bytes32(0), address(this)));
    }

    function test_setPrincipalCap_enforcesLimit() public {
        asset.mint(address(stakingDiamond), 1_000 ether);
        sleeve.setPrincipalCap(300 ether);

        vm.prank(address(stakingDiamond));
        vm.expectRevert(abi.encodeWithSelector(SleeveBase.PrincipalCapExceeded.selector, 300 ether, 400 ether));
        sleeve.allocate(400 ether, "");

        vm.prank(address(stakingDiamond));
        sleeve.allocate(250 ether, "");
        assertEq(sleeve.principalAssets(), 250 ether);
    }

    function test_setPrincipalCap_cannotDropBelowOutstanding() public {
        asset.mint(address(stakingDiamond), 1_000 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(400 ether, "");

        vm.expectRevert(abi.encodeWithSelector(SleeveBase.PrincipalCapTooLow.selector, 400 ether, 300 ether));
        sleeve.setPrincipalCap(300 ether);
    }

    function test_upgradeAuthorizedByDiamondUpgrader() public {
        MockSleeve newImplementation = new MockSleeve();
        sleeve.upgradeToAndCall(address(newImplementation), "");
    }

    function _expectInvalidStakingDiamond(address candidate) internal {
        MockSleeve implementation = new MockSleeve();
        vm.expectRevert(abi.encodeWithSelector(SleeveBase.InvalidStakingDiamond.selector, candidate));
        new ERC1967Proxy(
            address(implementation), abi.encodeCall(MockSleeve.initialize, (candidate, address(asset), 0))
        );
    }

    function _assertSelectorAbsent(bytes memory callData) internal {
        (bool ok,) = address(sleeve).call(callData);
        assertFalse(ok);
    }
}
