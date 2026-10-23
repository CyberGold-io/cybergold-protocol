// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

/// @notice Staking diamond shared storage for CyberGold-specific vault, queue, and fund-manager state.
/// @dev OZ token/access/pause state lives in each module's ERC-7201 namespace; reentrancy state is transient.
library LibAppStorage {
    bytes32 internal constant APP_STORAGE_POSITION = keccak256("cybergold.staking.app.storage");

    /// @dev Return app storage position.
    /// @return Canonical staking application-storage slot.
    function appStoragePosition() internal pure returns (bytes32) {
        return APP_STORAGE_POSITION;
    }

    /// @notice ERC4626 vault storage owned by the staking diamond.
    struct VaultStorage {
        bool fundManagerHealthy;
    }

    /// @notice Readiness timestamp applied through a queue boundary id.
    struct ReadyEpoch {
        uint256 boundaryId;
        uint64 readyAt;
    }

    /// @notice Doubly linked redemption request with controller, owner, and shares.
    struct QueueNode {
        uint256 prevId;
        uint256 nextId;
        address controller;
        address owner;
        uint256 shares;
    }

    /// @notice Async redemption queue storage owned by the staking diamond.
    struct QueueStorage {
        ReadyEpoch[] readyEpochs;
        uint256 epochsHead;
        mapping(uint256 => QueueNode) nodes;
        uint256 headId;
        uint256 tailId;
        uint256 readyBoundaryId;
        mapping(address => uint256[]) queryIds;
        mapping(address => mapping(uint256 => uint256)) queryIndex;
        mapping(address => mapping(address => bool)) isOwnerOperator;
        mapping(address => mapping(address => bool)) isControllerOperator;
        mapping(address => uint256) claimableShares;
        uint256 claimableSharesTotal;
        uint64 claimExpiry;
        uint256 headSweepLimit;
        uint256 autoProcessMax;
        uint64 seqInBlock;
        uint64 seqTimestamp;
        mapping(address => uint256) nonces;
        bytes32 domainSeparator;
        bytes32 hashedName;
        bytes32 hashedVersion;
        uint256 cachedChainId;
    }

    /// @notice Registry status, underlying asset, and tracked sleeve principal.
    struct SleeveConfig {
        bool registered;
        bool approved;
        address asset;
        uint256 principalAssets;
    }

    /// @notice Fund manager and sleeve registry storage owned by the staking diamond.
    struct FundManagerStorage {
        address cygld;
        address treasury;
        uint256 performanceFeePpm;
        mapping(address => uint256) principalPerAsset;
        mapping(address => SleeveConfig) sleeves;
        address[] registeredSleeves;
        address swapAdapter;
    }

    /// @notice Diamond app storage layout for this package.
    struct AppStorage {
        VaultStorage vault;
        QueueStorage queue;
        FundManagerStorage fm;
    }

    /// @dev Return app storage.
    /// @return s Staking application storage anchored at the canonical slot.
    function appStorage() internal pure returns (AppStorage storage s) {
        bytes32 position = APP_STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }
}
