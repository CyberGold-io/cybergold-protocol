// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IDiamondEmergencyAuthority} from "diamond-infra/interfaces/IDiamondEmergencyAuthority.sol";

/// @notice Fail-closed authority queries from a Staking Sleeve to its Staking Diamond.
library LibStakingDiamondAuthority {
    /// @notice Canonical role controlling ordinary Staking Diamond administration.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);
    /// @notice Canonical role controlling Staking Diamond and Sleeve upgrades.
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Determine whether `account` holds `role` on the Staking Diamond.
    function hasRole(address stakingDiamond, bytes32 role, address account) internal view returns (bool) {
        return readBoolean(stakingDiamond, abi.encodeWithSelector(IAccessControl.hasRole.selector, role, account));
    }

    /// @notice Determine whether `account` may pause through the Staking Diamond emergency authority.
    function canPause(address stakingDiamond, address account) internal view returns (bool) {
        return
            readBoolean(stakingDiamond, abi.encodeWithSelector(IDiamondEmergencyAuthority.canPause.selector, account));
    }

    /// @notice Determine whether `account` may unpause through the Staking Diamond emergency authority.
    function canUnpause(address stakingDiamond, address account) internal view returns (bool) {
        return
            readBoolean(stakingDiamond, abi.encodeWithSelector(IDiamondEmergencyAuthority.canUnpause.selector, account));
    }

    /// @notice Read one canonically encoded Boolean from `target`; every malformed response is false.
    function readBoolean(address target, bytes memory callData) internal view returns (bool) {
        (bool ok, bytes memory result) = target.staticcall(callData);
        if (!ok || result.length != 32) return false;

        uint256 raw;
        assembly {
            raw := mload(add(result, 0x20))
        }
        return raw == 1;
    }

    /// @notice Determine whether `target` returns one canonically encoded Boolean.
    function isCanonicalBooleanCall(address target, bytes memory callData) internal view returns (bool) {
        (bool ok, bytes memory result) = target.staticcall(callData);
        if (!ok || result.length != 32) return false;

        uint256 raw;
        assembly {
            raw := mload(add(result, 0x20))
        }
        return raw <= 1;
    }

    /// @notice Read one exact bytes32 response.
    function readBytes32(address target, bytes memory callData) internal view returns (bool ok, bytes32 value) {
        bytes memory result;
        (ok, result) = target.staticcall(callData);
        if (!ok || result.length != 32) return (false, bytes32(0));
        assembly {
            value := mload(add(result, 0x20))
        }
    }

    /// @notice Read one canonically encoded address response.
    function readAddress(address target, bytes memory callData) internal view returns (bool ok, address value) {
        bytes memory result;
        (ok, result) = target.staticcall(callData);
        if (!ok || result.length != 32) return (false, address(0));

        uint256 raw;
        assembly {
            raw := mload(add(result, 0x20))
        }
        if (raw > type(uint160).max) return (false, address(0));
        // safe: the preceding range check proves the word fits exactly in an address.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, address(uint160(raw)));
    }
}
