// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {StakingLaunchTypes} from "../deploy/StakingLaunchTypes.sol";

/// @notice Namespaced state and canonical hashes for the committed Staking launch.
library LibStakingLaunch {
    bytes32 internal constant DOMAIN = keccak256("CYBERGOLD_STAKING_ATOMIC_LAUNCH_V1");
    bytes32 internal constant SLEEVE_DOMAIN = keccak256("CYBERGOLD_STAKING_SLEEVE_CREATE2_V1");
    // keccak256(abi.encode(uint256(keccak256("cybergold.staking.atomic.launch")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_SLOT = 0xaf998c30b6bf758887c4f7ae3b9979a4920a749d595a880ba4118393868a6f00;

    /// @notice Atomic Staking launch lifecycle.
    enum Phase {
        Uninitialized,
        Committed,
        Finalizing,
        Finalized
    }

    /// @notice Namespaced commitment and terminal evidence for one Staking launch.
    struct Layout {
        Phase phase;
        bytes32 commitment;
        bytes32 activePayloadHash;
        bytes32 finalizationHash;
        address finalizerFacet;
    }

    function getLayout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    function payloadHash(StakingLaunchTypes.Finalization memory candidate) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                candidate.diamondCut,
                candidate.facets,
                candidate.initializer,
                candidate.initializerCodeHash,
                keccak256(candidate.initializerCalldata)
            )
        );
    }

    function payloadHashCalldata(StakingLaunchTypes.Finalization calldata candidate) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                candidate.diamondCut,
                candidate.facets,
                candidate.initializer,
                candidate.initializerCodeHash,
                keccak256(candidate.initializerCalldata)
            )
        );
    }

    function commitment(bytes32 payloadHash_) internal view returns (bytes32) {
        return commitmentFor(block.chainid, address(this), payloadHash_);
    }

    function commitmentFor(uint256 chainId, address shell, bytes32 payloadHash_) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN, chainId, shell, payloadHash_));
    }

    function sleeveSalt(bytes32 payloadHash_, bytes32 baseSalt, uint256 index) internal pure returns (bytes32) {
        return keccak256(abi.encode(SLEEVE_DOMAIN, payloadHash_, baseSalt, index));
    }

    function sleeveBaseSalt(bytes32 shellSalt, uint256 index, bytes32 requestHash) internal pure returns (bytes32) {
        return keccak256(abi.encode("CYBERGOLD_STAKING_SLEEVE_V1", shellSalt, index, requestHash));
    }
}
