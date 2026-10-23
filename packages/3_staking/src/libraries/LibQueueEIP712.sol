// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {LibAppStorage} from "../diamond/LibAppStorage.sol";

/// @notice EIP-712 domain construction shared by queue initialization and signatures.
library LibQueueEIP712 {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev Return the cached separator for the current chain or rebuild it after a chain-id change.
    function domainSeparator(LibAppStorage.QueueStorage storage q) internal view returns (bytes32) {
        if (q.cachedChainId == block.chainid && q.domainSeparator != bytes32(0)) {
            return q.domainSeparator;
        }
        return buildDomainSeparator(q, block.chainid);
    }

    /// @dev Build the queue domain separator for a specific chain id.
    function buildDomainSeparator(LibAppStorage.QueueStorage storage q, uint256 chainId)
        internal
        view
        returns (bytes32)
    {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(DOMAIN_TYPEHASH, q.hashedName, q.hashedVersion, chainId, address(this)));
    }
}
