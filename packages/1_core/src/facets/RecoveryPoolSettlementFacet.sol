// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IRecoveryTypes} from "../interfaces/IRecoveryTypes.sol";
import {IRecoveryShareRedemptionCallback} from "../interfaces/IRecoveryShareRedemptionCallback.sol";
import {LibAccountCallbacks} from "../libraries/LibAccountCallbacks.sol";
import {LibRecoveryPoolSettlement} from "../libraries/LibRecoveryPoolSettlement.sol";
import {LibRecoveryStorage} from "../libraries/LibRecoveryStorage.sol";
import {LibRecoveryState} from "../libraries/LibRecoveryState.sol";
import {LibReserve} from "../libraries/LibReserve.sol";

import {ControllerBase} from "./ControllerBase.sol";

/// @notice Minimal guarded Core self-call interface used during recovery-share settlement.
interface IRecoveryShareController {
    /// @notice Return the external ERC-1155 supply for a recovery-share identifier.
    /// @param shareId Canonical ERC-1155 recovery-share identifier.
    /// @return supply External recovery-share supply.
    function totalSupply(uint256 shareId) external view returns (uint256 supply);

    /// @notice Burn external recovery shares through the Core-only controller hook.
    /// @param account Account whose shares are burned.
    /// @param asset Asset identifying the permanent recovery pool.
    /// @param amount Recovery-share amount burned.
    function burnRecoveryShares(address account, address asset, uint256 amount) external;
}

/// @notice Pool-wide original-asset redemption for asset-scoped recovery shares.
contract RecoveryPoolSettlementFacet is ControllerBase, IRecoveryTypes {
    /// @notice Facet version used by the Diamond initialization registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the Diamond initialization registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.core.recovery-pool-settlement");

    /// @notice Burn external shares for a pro-rata payment from a redeemable original-asset pool.
    /// @param asset Original impaired asset held in the recovery pool.
    /// @param shares Recovery-share amount burned from the caller.
    /// @param recipient Account receiving original-asset proceeds.
    /// @param minRawOut Minimum acceptable raw original-asset proceeds.
    /// @return rawOut Exact raw original-asset amount transferred.
    function redeemRecoveryShares(address asset, uint256 shares, address recipient, uint256 minRawOut)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 rawOut)
    {
        if (recipient == address(0)) revert RecoveryRecipientInvalid(recipient);
        (LibRecoveryStorage.RecoveryPool storage pool, uint256 externalSupply) = _requireRedeemablePool(asset, shares);
        bool usesCallback =
            LibAccountCallbacks.supportsInterface(msg.sender, type(IRecoveryShareRedemptionCallback).interfaceId);

        uint256 poolRawBefore = pool.redeemableRaw;
        LibRecoveryPoolSettlement.Quote memory quote =
            LibRecoveryPoolSettlement.quote(asset, pool, externalSupply, shares);
        if (!quote.observed) revert ReserveBalanceProbeUnavailable(asset);
        rawOut = quote.rawOut;
        if (rawOut == 0) revert RecoveryShareOutputZero(asset, shares);
        if (rawOut < minRawOut) revert RecoveryMinimumNotMet(minRawOut, rawOut);

        if (usesCallback) {
            bytes4 callback = IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector;
            LibAccountCallbacks.callAndRequireMagic(
                msg.sender,
                callback,
                abi.encodeCall(
                    IRecoveryShareRedemptionCallback.onRecoveryShareRedemption,
                    (asset, shares, recipient, minRawOut, rawOut)
                )
            );
        }

        uint256 expectedSupply = externalSupply - shares;
        pool.redeemableRaw = poolRawBefore - quote.liabilityReleasedRaw;
        if (expectedSupply == 0) assert(pool.redeemableRaw == 0);

        IRecoveryShareController(address(this)).burnRecoveryShares(msg.sender, asset, shares);
        uint256 actualSupply = IRecoveryShareController(address(this)).totalSupply(uint256(uint160(asset)));
        if (actualSupply != expectedSupply) {
            revert RecoveryShareSupplyInvariant(asset, expectedSupply, actualSupply);
        }
        LibRecoveryState.syncOutstanding(asset);

        LibReserve.transferRecoveryPoolOut(asset, recipient, rawOut);
        emit RecoverySharesRedeemed(asset, msg.sender, recipient, shares, quote.liabilityReleasedRaw, rawOut);
    }

    function _requireRedeemablePool(address asset, uint256 shares)
        private
        view
        returns (LibRecoveryStorage.RecoveryPool storage pool, uint256 externalSupply)
    {
        if (asset == address(0)) revert RecoveryAssetInvalid(asset);
        if (shares == 0) revert RecoveryShareAmountZero(asset);
        pool = LibRecoveryStorage.getLayout().pools[asset];
        if (!pool.impaired && pool.coreAttachedShares != 0) {
            revert RecoveryPoolAccountingInvariant(asset, 0, pool.coreAttachedShares);
        }
        externalSupply = IRecoveryShareController(address(this)).totalSupply(uint256(uint160(asset)));
        if (shares > externalSupply || externalSupply == 0) {
            revert RecoveryShareSupplyInvariant(asset, externalSupply, shares);
        }
    }
}
