// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";

import {LibStakingDiamondAuthority} from "../../src/libraries/LibStakingDiamondAuthority.sol";

contract StakingAuthorityResponseMock {
    mapping(bytes32 role => mapping(address account => bool authorized)) internal _roles;
    mapping(address account => bool authorized) internal _pausers;
    mapping(address account => bool authorized) internal _unpausers;
    uint8 internal _responseMode;

    function setRole(bytes32 role, address account, bool authorized) external {
        _roles[role][account] = authorized;
    }

    function setCanPause(address account, bool authorized) external {
        _pausers[account] = authorized;
    }

    function setCanUnpause(address account, bool authorized) external {
        _unpausers[account] = authorized;
    }

    function setResponseMode(uint8 mode) external {
        _responseMode = mode;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _respond(_roles[role][account]);
    }

    function canPause(address account) external view returns (bool) {
        return _respond(_pausers[account]);
    }

    function canUnpause(address account) external view returns (bool) {
        return _respond(_unpausers[account]);
    }

    function _respond(bool authorized) internal view returns (bool) {
        uint8 mode = _responseMode;
        if (mode == 1) revert();
        if (mode == 2) {
            assembly {
                return(0, 0)
            }
        }
        if (mode == 3) {
            assembly {
                mstore(0, 1)
                return(1, 31)
            }
        }
        if (mode == 4) {
            assembly {
                mstore(0, 1)
                return(0, 33)
            }
        }
        if (mode == 5) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return authorized;
    }
}

contract StakingDiamondAuthorityHarness {
    function hasRole(address stakingDiamond, bytes32 role, address account) external view returns (bool) {
        return LibStakingDiamondAuthority.hasRole(stakingDiamond, role, account);
    }

    function canPause(address stakingDiamond, address account) external view returns (bool) {
        return LibStakingDiamondAuthority.canPause(stakingDiamond, account);
    }

    function canUnpause(address stakingDiamond, address account) external view returns (bool) {
        return LibStakingDiamondAuthority.canUnpause(stakingDiamond, account);
    }

    function readBytes32(address target, bytes calldata callData) external view returns (bool ok, bytes32 value) {
        return LibStakingDiamondAuthority.readBytes32(target, callData);
    }

    function readAddress(address target, bytes calldata callData) external view returns (bool ok, address value) {
        return LibStakingDiamondAuthority.readAddress(target, callData);
    }
}

contract RawAuthorityResponseMock {
    uint8 internal _responseMode;

    function setResponseMode(uint8 mode) external {
        _responseMode = mode;
    }

    function bytes32Value() external view returns (bytes32) {
        return _respond(0x1234);
    }

    function addressValue() external view returns (address) {
        return address(uint160(uint256(_respond(0xBEEF))));
    }

    function _respond(uint256 value) internal view returns (bytes32) {
        uint8 mode = _responseMode;
        if (mode == 1) revert();
        if (mode == 2) {
            assembly {
                return(0, 0)
            }
        }
        if (mode == 3) {
            assembly {
                mstore(0, value)
                mstore(0x20, 0)
                return(0, 0x40)
            }
        }
        if (mode == 4) {
            assembly {
                mstore(0, shl(160, 1))
                return(0, 0x20)
            }
        }
        return bytes32(value);
    }
}

contract LibStakingDiamondAuthorityTest is Test {
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    address internal account = address(0xA11CE);

    StakingAuthorityResponseMock internal authority;
    StakingDiamondAuthorityHarness internal harness;

    function setUp() public {
        authority = new StakingAuthorityResponseMock();
        harness = new StakingDiamondAuthorityHarness();
        authority.setRole(bytes32(0), account, true);
        authority.setRole(UPGRADER_ROLE, account, true);
        authority.setCanPause(account, true);
        authority.setCanUnpause(account, true);
    }

    function testCanonicalDecisionsFollowStakingDiamond() public view {
        assertTrue(harness.hasRole(address(authority), bytes32(0), account));
        assertTrue(harness.hasRole(address(authority), UPGRADER_ROLE, account));
        assertTrue(harness.canPause(address(authority), account));
        assertTrue(harness.canUnpause(address(authority), account));

        address stranger = address(0xDEAD);
        assertFalse(harness.hasRole(address(authority), bytes32(0), stranger));
        assertFalse(harness.hasRole(address(authority), UPGRADER_ROLE, stranger));
        assertFalse(harness.canPause(address(authority), stranger));
        assertFalse(harness.canUnpause(address(authority), stranger));
    }

    function testEveryMalformedResponseFailsClosed() public {
        for (uint8 mode = 1; mode <= 5; ++mode) {
            authority.setResponseMode(mode);
            assertFalse(harness.hasRole(address(authority), bytes32(0), account));
            assertFalse(harness.hasRole(address(authority), UPGRADER_ROLE, account));
            assertFalse(harness.canPause(address(authority), account));
            assertFalse(harness.canUnpause(address(authority), account));
        }
    }

    function testZeroAndEoaControllersFailClosed() public view {
        assertFalse(harness.hasRole(address(0), bytes32(0), account));
        assertFalse(harness.hasRole(address(0xBEEF), UPGRADER_ROLE, account));
        assertFalse(harness.canPause(address(0), account));
        assertFalse(harness.canUnpause(address(0xBEEF), account));
    }

    function testStructuralWordAndAddressDecodersRejectEveryMalformedResponse() public {
        RawAuthorityResponseMock raw = new RawAuthorityResponseMock();
        bytes memory bytesCall = abi.encodeWithSelector(raw.bytes32Value.selector);
        bytes memory addressCall = abi.encodeWithSelector(raw.addressValue.selector);

        (bool bytesOk, bytes32 word) = harness.readBytes32(address(raw), bytesCall);
        assertTrue(bytesOk);
        assertEq(word, bytes32(uint256(0x1234)));
        (bool addressOk, address decodedAddress) = harness.readAddress(address(raw), addressCall);
        assertTrue(addressOk);
        assertEq(decodedAddress, address(0xBEEF));

        for (uint8 mode = 1; mode <= 3; ++mode) {
            raw.setResponseMode(mode);
            (bytesOk, word) = harness.readBytes32(address(raw), bytesCall);
            assertFalse(bytesOk);
            assertEq(word, bytes32(0));
            (addressOk, decodedAddress) = harness.readAddress(address(raw), addressCall);
            assertFalse(addressOk);
            assertEq(decodedAddress, address(0));
        }

        raw.setResponseMode(4);
        (addressOk, decodedAddress) = harness.readAddress(address(raw), addressCall);
        assertFalse(addressOk);
        assertEq(decodedAddress, address(0));
    }
}
