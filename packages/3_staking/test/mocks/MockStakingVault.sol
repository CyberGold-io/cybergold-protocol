// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

contract MockStakingVault {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.staking.test.mock-vault");
    uint64 public constant FACET_VERSION = 1;

    bytes32 private constant STORAGE_SLOT = keccak256("cybergold.test.mock-staking-vault");

    struct MockStakingVaultStorage {
        address asset;
        uint256 totalAssets;
        uint256 claimableAssets;
    }

    function _storage() private pure returns (MockStakingVaultStorage storage s) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function setAsset(address asset_) external {
        _storage().asset = asset_;
    }

    function setTotalAssets(uint256 amount) external {
        _storage().totalAssets = amount;
    }

    function setClaimableAssets(uint256 amount) external {
        _storage().claimableAssets = amount;
    }

    function asset() external view returns (address) {
        return _storage().asset;
    }

    function totalAssets() external view returns (uint256) {
        return _storage().totalAssets;
    }

    function claimableAssets() external view returns (uint256) {
        return _storage().claimableAssets;
    }

    struct LiquidityBreakdown {
        uint256 idleAssets;
        uint256 claimableAssets;
        uint256 strategyAssets;
        uint256 custodyAssets;
        uint256 totalManagedAssets;
    }

    function liquidityBreakdown() external view returns (LiquidityBreakdown memory breakdown, bool healthy) {
        breakdown.claimableAssets = _storage().claimableAssets;
        // other fields unused by FundManager tests
        healthy = true;
    }
}
