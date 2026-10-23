// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// @notice ERC-1967 Sleeve proxy with a non-delegated implementation attestation surface.
contract SleeveProxy is ERC1967Proxy {
    /// @notice Reverts when native value is sent to a Sleeve proxy.
    error SleeveNativeValueNotAccepted();

    /// @notice Create a Sleeve proxy and execute its complete launch initializer.
    /// @param implementation_ Initial implementation committed by the Staking launch.
    /// @param initCalldata Exact initializer calldata executed by the proxy constructor.
    constructor(address implementation_, bytes memory initCalldata) ERC1967Proxy(implementation_, initCalldata) {}

    /// @notice Return the implementation selected by the proxy's ERC-1967 slot.
    /// @dev Defined on the proxy itself so a delegated implementation cannot spoof the attestation.
    /// @return implementation_ Current implementation read directly from the ERC-1967 slot.
    function implementation() external view returns (address implementation_) {
        implementation_ = ERC1967Utils.getImplementation();
    }

    /// @notice Reject an empty-calldata native transfer.
    receive() external payable {
        revert SleeveNativeValueNotAccepted();
    }

    /// @dev Reject value before dispatching any unknown selector to the implementation.
    function _fallback() internal override {
        if (msg.value != 0) revert SleeveNativeValueNotAccepted();
        super._fallback();
    }
}

/// @notice Non-delegated implementation view exposed by every canonical Sleeve proxy.
interface ISleeveProxy {
    /// @notice Return the implementation stored in the proxy's ERC-1967 slot.
    /// @return implementation_ Current Sleeve implementation.
    function implementation() external view returns (address implementation_);
}
