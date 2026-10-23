// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IRecoveryTypes} from "cybergold-core/interfaces/IRecoveryTypes.sol";

import {IRecoveryFundCore} from "../interfaces/IRecoveryFundCore.sol";
import {IRecoveryFundTypes} from "../interfaces/IRecoveryFundTypes.sol";
import {LibRecoveryFundStorage} from "../libraries/LibRecoveryFundStorage.sol";
import {LibRecoveryFundTransfer} from "../libraries/LibRecoveryFundTransfer.sol";

/// @notice Shared current-state trusted-Core reconciliation used by recovery Fund facets.
abstract contract RecoveryFundBase is IRecoveryFundTypes {
    /// @notice One scalar snapshot of the asset-keyed Core pool and Governance inventory.
    struct CoreSnapshot {
        IRecoveryTypes.RecoveryPoolView pool;
        uint256 externalSupply;
        uint256 governanceBalance;
    }

    function _loadCoreSnapshot(address impairedAsset) internal view returns (CoreSnapshot memory snapshot) {
        uint256 shareId = _shareIdForAsset(impairedAsset);
        IRecoveryFundCore core = IRecoveryFundCore(LibRecoveryFundStorage.getLayout().trustedCore);
        snapshot.pool = core.recoveryPool(impairedAsset);
        snapshot.externalSupply = core.totalSupply(shareId);
        if (snapshot.pool.externalShares != snapshot.externalSupply) {
            revert RecoveryFundPoolAccountingMismatch(snapshot.pool.externalShares, snapshot.externalSupply);
        }
        snapshot.governanceBalance =
            LibRecoveryFundTransfer.strictRecoveryShareBalance(address(core), address(this), shareId);
        if (snapshot.governanceBalance > snapshot.externalSupply) {
            revert RecoveryFundGovernanceBalanceExceedsExternalShares(
                snapshot.governanceBalance, snapshot.externalSupply
            );
        }
    }

    function _samePurchaseSnapshot(CoreSnapshot memory before_, CoreSnapshot memory after_)
        internal
        pure
        returns (bool)
    {
        return before_.pool.impaired == after_.pool.impaired
            && before_.pool.coreAttachedShares == after_.pool.coreAttachedShares
            && before_.pool.externalShares == after_.pool.externalShares
            && before_.pool.redeemableRaw == after_.pool.redeemableRaw
            && before_.pool.cygldPerAssetRawFp18 == after_.pool.cygldPerAssetRawFp18
            && before_.pool.cygldSupplyCap == after_.pool.cygldSupplyCap
            && before_.pool.referenceShares == after_.pool.referenceShares
            && before_.pool.referenceValueCygld == after_.pool.referenceValueCygld
            && before_.pool.shareDecimals == after_.pool.shareDecimals
            && before_.externalSupply == after_.externalSupply && before_.governanceBalance == after_.governanceBalance;
    }

    function _shareIdForAsset(address asset) internal pure returns (uint256) {
        return uint256(uint160(_assetKey(asset)));
    }

    function _assetKey(address asset) internal pure returns (address) {
        if (asset == address(0)) revert RecoveryFundZeroAddress();
        return asset;
    }

    function _assetForShareId(uint256 shareId) internal pure returns (address asset) {
        if (shareId == 0 || shareId > type(uint160).max) revert RecoveryFundInvalidShareId(shareId);
        // The canonical range check above proves the narrowing conversion is lossless.
        // forge-lint: disable-next-line(unsafe-typecast)
        asset = address(uint160(shareId));
    }

    function _requireSelfCall() internal view {
        if (msg.sender != address(this)) revert RecoveryFundUnauthorizedSelfCall(msg.sender);
    }
}
