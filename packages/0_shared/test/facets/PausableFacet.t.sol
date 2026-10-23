// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";

import {AccessControlFacet} from "diamond-infra/facets/AccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";

contract SharedMockSafeSingleton {}

contract SharedMockSafeWallet {
    address private _singleton;
    address[] private _owners;
    uint256 private _threshold;
    string private _version = "1.5.0";
    uint8 private _singletonResponseMode;
    uint8 private _versionResponseMode;
    uint8 private _ownersResponseMode;
    uint8 private _thresholdResponseMode;
    uint8 private _ownerResponseMode;

    constructor(address singleton_, address[] memory owners_, uint256 threshold_) {
        _singleton = singleton_;
        _owners = owners_;
        _threshold = threshold_;
    }

    function masterCopy() external view returns (address) {
        if (_singletonResponseMode == 1) revert("singleton revert");
        if (_singletonResponseMode == 2) {
            assembly {
                mstore(0, 1)
                return(1, 31)
            }
        }
        return _singleton;
    }

    function VERSION() external view returns (string memory) {
        if (_versionResponseMode == 1) revert("version revert");
        if (_versionResponseMode == 2) {
            assembly {
                return(0, 63)
            }
        }
        if (_versionResponseMode == 3) {
            assembly {
                mstore(0, 0)
                mstore(32, 0)
                return(0, 64)
            }
        }
        if (_versionResponseMode == 4) {
            assembly {
                mstore(0, 32)
                mstore(32, not(0))
                return(0, 64)
            }
        }
        if (_versionResponseMode == 5) {
            assembly {
                mstore(0, 32)
                mstore(32, sub(not(0), 62))
                return(0, 64)
            }
        }
        if (_versionResponseMode == 6) {
            assembly {
                mstore(0, 32)
                mstore(32, 33)
                return(0, 64)
            }
        }
        return _version;
    }

    function getOwners() external view returns (address[] memory) {
        if (_ownersResponseMode == 1) revert("owners revert");
        if (_ownersResponseMode == 2) {
            assembly {
                return(0, 63)
            }
        }
        if (_ownersResponseMode == 3) {
            assembly {
                mstore(0, 0)
                mstore(32, 0)
                return(0, 64)
            }
        }
        if (_ownersResponseMode == 4) {
            assembly {
                mstore(0, 32)
                mstore(32, not(0))
                return(0, 64)
            }
        }
        if (_ownersResponseMode == 5) {
            assembly {
                mstore(0, 32)
                mstore(32, 1)
                return(0, 64)
            }
        }
        return _owners;
    }

    function getThreshold() external view returns (uint256) {
        if (_thresholdResponseMode == 1) revert("threshold revert");
        if (_thresholdResponseMode == 2) {
            assembly {
                mstore(0, 1)
                return(1, 31)
            }
        }
        return _threshold;
    }

    function isOwner(address account) external view returns (bool) {
        if (_ownerResponseMode == 1) revert("owner revert");
        if (_ownerResponseMode == 2) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (_ownerResponseMode == 3) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        for (uint256 i; i < _owners.length; ++i) {
            if (_owners[i] == account) return true;
        }
        return false;
    }

    function setSingleton(address singleton_) external {
        _singleton = singleton_;
    }

    function setVersion(string calldata version_) external {
        _version = version_;
    }

    function setOwners(address[] calldata owners_, uint256 threshold_) external {
        _owners = owners_;
        _threshold = threshold_;
    }

    function setResponseModes(
        uint8 singletonMode,
        uint8 versionMode,
        uint8 ownersMode,
        uint8 thresholdMode,
        uint8 ownerMode
    ) external {
        _singletonResponseMode = singletonMode;
        _versionResponseMode = versionMode;
        _ownersResponseMode = ownersMode;
        _thresholdResponseMode = thresholdMode;
        _ownerResponseMode = ownerMode;
    }
}

contract SharedAlternateSafeWallet is SharedMockSafeWallet {
    constructor(address singleton_, address[] memory owners_, uint256 threshold_)
        SharedMockSafeWallet(singleton_, owners_, threshold_)
    {}

    function alternateMarker() external pure returns (bytes32) {
        return keccak256("alternate-safe-runtime");
    }
}

contract PausableFacetTest is Test {
    bytes32 internal constant EMERGENCY_AUTHORITY_STORAGE =
        0x513d37eedc2d7de2e29625428c80148c9bb7f7daf0e09d0261c85d7c6077c600;
    bytes32 internal constant INIT_CONTEXT_SLOT = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
    bytes32 internal constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    address internal admin = address(0xA11CE);
    address internal pauser = address(0xBEEF);
    address internal user = address(0xCAFE);

    PausableFacet internal pauseFacet;
    SharedMockSafeSingleton internal singleton;
    SharedMockSafeWallet internal safe;
    address internal diamond;

    function setUp() public {
        singleton = new SharedMockSafeSingleton();
        safe = new SharedMockSafeWallet(address(singleton), _owners(admin, pauser), 2);
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = admin;
        cfg.safeWallet = address(safe);
        cfg.includePause = true;
        cfg.includeReentrancy = false;
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.deploy(cfg);
        diamond = address(art.diamond);
        pauseFacet = PausableFacet(address(diamond));
    }

    function testInitGuardBlocksDirectCall() public {
        vm.expectRevert();
        pauseFacet.initPausable(address(safe));
    }

    function testUninitializedAuthorityViewFailsClosed() public {
        PausableFacet uninitialized = new PausableFacet();
        assertEq(uninitialized.safeWallet(), address(0));
        assertFalse(uninitialized.canPause(pauser));
        assertFalse(uninitialized.canUnpause(address(0)));
    }

    function testOuterInitializerHookConfiguresSafeWithoutFacetCounterBump() public {
        PausableFacet facet = new PausableFacet();
        vm.store(address(facet), INIT_CONTEXT_SLOT, bytes32(uint256(1)));
        vm.store(address(facet), INITIALIZABLE_STORAGE, bytes32(uint256(1) << 64));

        facet.initPausableFromOuter(address(safe));

        assertEq(facet.safeWallet(), address(safe));
        assertEq(vm.load(address(facet), INITIALIZABLE_STORAGE), bytes32(uint256(1) << 64));
    }

    function testNonOwnerCannotPause() public {
        vm.prank(user);
        vm.expectRevert();
        PausableFacet(address(diamond)).pause();
    }

    function testSafeWalletCanUnpause() public {
        vm.prank(admin);
        pauseFacet.pause();
        assertTrue(pauseFacet.paused());

        vm.prank(address(safe));
        pauseFacet.unpause();
        assertFalse(pauseFacet.paused());
    }

    function testSafeOwnerCannotUnpause() public {
        vm.prank(pauser);
        pauseFacet.pause();

        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, pauser));
        pauseFacet.unpause();
    }

    function testDeploymentUsesLiveSafeAuthority() public {
        address[] memory owners = _owners(pauser, user);
        SharedMockSafeSingleton otherSingleton = new SharedMockSafeSingleton();
        SharedMockSafeWallet otherSafe = new SharedMockSafeWallet(address(otherSingleton), owners, 2);
        PausableFacet deployedPause = _deployWithSafe(otherSafe);

        assertEq(deployedPause.safeWallet(), address(otherSafe));
        assertTrue(deployedPause.canPause(pauser));
        assertTrue(deployedPause.canPause(user));
        assertFalse(deployedPause.canPause(address(otherSafe)));
        assertTrue(deployedPause.canUnpause(address(otherSafe)));
        assertFalse(deployedPause.canUnpause(pauser));

        vm.prank(pauser);
        deployedPause.pause();
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, user));
        deployedPause.unpause();
        vm.prank(address(otherSafe));
        deployedPause.unpause();
    }

    function testAuthorityViewsFailClosedForMalformedSafeResponses() public {
        safe.setResponseModes(0, 0, 0, 0, 1);
        assertFalse(pauseFacet.canPause(pauser));
        safe.setResponseModes(0, 0, 0, 0, 2);
        assertFalse(pauseFacet.canPause(pauser));
        safe.setResponseModes(0, 0, 0, 0, 3);
        assertFalse(pauseFacet.canPause(pauser));
        safe.setResponseModes(0, 0, 0, 0, 0);
        assertFalse(pauseFacet.canPause(address(0xDEAD)));

        vm.prank(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, address(0xDEAD))
        );
        pauseFacet.pause();
    }

    function testSafeWalletSetterUsesCompareAndSetAndWorksWhilePaused() public {
        address[] memory owners = _owners(pauser, user);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(PausableFacet.AccessControlUnauthorizedAccount.selector, user, bytes32(0))
        );
        pauseFacet.setSafeWallet(address(safe), address(safe));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                PausableFacet.SafeWalletExpectedCurrentMismatch.selector, address(0xDEAD), address(safe)
            )
        );
        pauseFacet.setSafeWallet(address(0xDEAD), address(safe));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.SafeWalletUnchanged.selector, address(safe)));
        pauseFacet.setSafeWallet(address(safe), address(safe));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.InvalidSafeWallet.selector, address(0)));
        pauseFacet.setSafeWallet(address(safe), address(0));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.InvalidSafeWallet.selector, diamond));
        pauseFacet.setSafeWallet(address(safe), diamond);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.InvalidSafeWallet.selector, user));
        pauseFacet.setSafeWallet(address(safe), user);

        SharedMockSafeWallet replacement = new SharedMockSafeWallet(address(singleton), owners, 2);
        vm.prank(admin);
        pauseFacet.pause();
        vm.prank(admin);
        pauseFacet.setSafeWallet(address(safe), address(replacement));
        assertEq(pauseFacet.safeWallet(), address(replacement));
    }

    function testSafeWalletValidationRejectsMalformedOwnerAndThresholdResponses() public {
        address[] memory owners = _owners(pauser, user);
        SharedMockSafeSingleton candidateSingleton = new SharedMockSafeSingleton();

        for (uint8 mode = 1; mode <= 5; ++mode) {
            SharedMockSafeWallet candidate = new SharedMockSafeWallet(address(candidateSingleton), owners, 2);
            candidate.setResponseModes(0, 0, mode, 0, 0);
            _expectInvalid(candidate);
        }
        SharedMockSafeWallet emptyOwners = new SharedMockSafeWallet(address(candidateSingleton), new address[](0), 0);
        _expectInvalid(emptyOwners);

        for (uint8 mode = 1; mode <= 2; ++mode) {
            SharedMockSafeWallet candidate = new SharedMockSafeWallet(address(candidateSingleton), owners, 2);
            candidate.setResponseModes(0, 0, 0, mode, 0);
            _expectInvalid(candidate);
        }
        _expectInvalid(new SharedMockSafeWallet(address(candidateSingleton), owners, 0));
        _expectInvalid(new SharedMockSafeWallet(address(candidateSingleton), owners, 3));

        address[] memory zeroOwner = _owners(address(0), user);
        _expectInvalid(new SharedMockSafeWallet(address(candidateSingleton), zeroOwner, 1));
        address[] memory duplicateOwner = _owners(pauser, pauser);
        _expectInvalid(new SharedMockSafeWallet(address(candidateSingleton), duplicateOwner, 1));
        for (uint8 mode = 1; mode <= 3; ++mode) {
            SharedMockSafeWallet candidate = new SharedMockSafeWallet(address(candidateSingleton), owners, 2);
            candidate.setResponseModes(0, 0, 0, 0, mode);
            _expectInvalid(candidate);
        }
    }

    function testReplacementAcceptsAValidSafeWithDifferentRuntimeSingletonAndVersion() public {
        address[] memory owners = _owners(pauser, user);
        SharedMockSafeSingleton candidateSingleton = new SharedMockSafeSingleton();
        SharedAlternateSafeWallet alternate = new SharedAlternateSafeWallet(address(candidateSingleton), owners, 2);
        alternate.setVersion("1.6.0");

        _assertLeanAuthorityStorage(address(safe));
        assertNotEq(address(alternate).codehash, address(safe).codehash);
        assertNotEq(alternate.masterCopy(), safe.masterCopy());
        vm.prank(admin);
        pauseFacet.setSafeWallet(address(safe), address(alternate));

        assertEq(pauseFacet.safeWallet(), address(alternate));
        assertTrue(pauseFacet.canPause(pauser));
        _assertLeanAuthorityStorage(address(alternate));
    }

    function _deployWithSafe(SharedMockSafeWallet safe_) internal returns (PausableFacet deployed) {
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = admin;
        cfg.safeWallet = address(safe_);
        cfg.includePause = true;
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.deploy(cfg);
        deployed = PausableFacet(address(art.diamond));
    }

    function _expectInvalid(SharedMockSafeWallet candidate) internal {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.InvalidSafeWallet.selector, address(candidate)));
        pauseFacet.setSafeWallet(address(safe), address(candidate));
    }

    function _assertLeanAuthorityStorage(address expectedSafe) internal view {
        assertEq(address(uint160(uint256(vm.load(diamond, EMERGENCY_AUTHORITY_STORAGE)))), expectedSafe);
        for (uint256 i = 1; i <= 4; ++i) {
            assertEq(vm.load(diamond, bytes32(uint256(EMERGENCY_AUTHORITY_STORAGE) + i)), bytes32(0));
        }
    }

    function _owners(address first, address second) internal pure returns (address[] memory owners) {
        owners = new address[](2);
        owners[0] = first;
        owners[1] = second;
    }
}
