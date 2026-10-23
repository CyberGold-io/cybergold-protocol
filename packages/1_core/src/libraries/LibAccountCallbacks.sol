// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Bounded ERC-165 discovery and fail-closed dispatch for optional account policies.
library LibAccountCallbacks {
    /// @notice Maximum gas stipend requested for each operation-specific ERC-165 probe.
    uint256 internal constant ACCOUNT_CALLBACK_PROBE_GAS = 30_000;

    /// @notice Reverts when an advertised callback fails without policy revert data.
    /// @param account Account whose callback failed.
    /// @param callback Operation-specific callback selector.
    error AccountCallbackFailed(address account, bytes4 callback);

    /// @notice Reverts when an advertised callback does not return exactly one ABI word.
    /// @param account Account whose callback returned malformed data.
    /// @param callback Operation-specific callback selector.
    /// @param returnDataLength Exact callback return-data length.
    error AccountCallbackReturnMalformed(address account, bytes4 callback, uint256 returnDataLength);

    /// @notice Reverts when an advertised callback returns a word other than its canonical selector encoding.
    /// @param account Account whose callback returned the wrong magic value.
    /// @param callback Operation-specific callback selector.
    /// @param returnedWord Complete callback return word, including ABI padding.
    error AccountCallbackMagicMismatch(address account, bytes4 callback, bytes32 returnedWord);

    /// @notice Discover one operation-specific account policy with the frozen bounded probe.
    /// @dev False, revert, OOG, malformed, and noncanonical results are deliberately unsupported.
    ///      There is no pre-probe gas floor: EIP-150 may forward less than the requested stipend.
    function supportsInterface(address account, bytes4 interfaceId) internal view returns (bool supported) {
        if (account.code.length == 0) return false;

        bytes memory callData = abi.encodeCall(IERC165.supportsInterface, (interfaceId));

        bool success;
        uint256 returnDataLength;
        bytes32 returnedWord;
        uint256 probeGas = ACCOUNT_CALLBACK_PROBE_GAS;
        assembly ("memory-safe") {
            success := staticcall(probeGas, account, add(callData, 0x20), mload(callData), 0, 0)
            returnDataLength := returndatasize()
            if eq(returnDataLength, 0x20) {
                returndatacopy(0, 0, 0x20)
                returnedWord := mload(0)
            }
        }
        return success && returnDataLength == 32 && returnedWord == bytes32(uint256(1));
    }

    /// @notice Invoke an advertised callback and require exact canonical magic.
    /// @dev Nonempty policy reverts bubble unchanged; successful returndata is copied only when exactly one word.
    function callAndRequireMagic(address account, bytes4 callback, bytes memory callData) internal view {
        bool success;
        uint256 returnDataLength;
        bytes32 returnedWord;
        assembly ("memory-safe") {
            success := staticcall(gas(), account, add(callData, 0x20), mload(callData), 0, 0)
            returnDataLength := returndatasize()
            if and(success, eq(returnDataLength, 0x20)) {
                returndatacopy(0, 0, 0x20)
                returnedWord := mload(0)
            }
        }

        if (!success) {
            if (returnDataLength == 0) revert AccountCallbackFailed(account, callback);
            assembly {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        if (returnDataLength != 32) {
            revert AccountCallbackReturnMalformed(account, callback, returnDataLength);
        }
        if (returnedWord != bytes32(callback)) {
            revert AccountCallbackMagicMismatch(account, callback, returnedWord);
        }
    }
}
