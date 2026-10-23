// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {LibSupplyCap} from "../libraries/LibSupplyCap.sol";
import {ICyberGoldCore} from "cybergold-core/interfaces/ICyberGoldCore.sol";

import {ControllerBase} from "./ControllerBase.sol";

/// @notice Governance/admin configuration knobs for the controller.
contract ControllerConfigFacet is ControllerBase {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.controller.config");

    /// @notice Maximum protocol fee in parts per million.
    uint256 public constant MAX_FEE_PPM = MAX_FEE_PPM_VALUE;

    /// @notice Set the issuance fee in parts per million.
    /// @param currentIssuanceFeePpm Caller-supplied current issuance fee rate in parts per million.
    /// @param newIssuanceFeePpm Replacement issuance fee rate in parts per million.
    function setIssuanceFeePpm(uint256 currentIssuanceFeePpm, uint256 newIssuanceFeePpm)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (currentIssuanceFeePpm == newIssuanceFeePpm) revert FeeChangeNoop();
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        uint256 actualIssuanceFeePpm = cs.issuanceFeePpm;
        if (currentIssuanceFeePpm != actualIssuanceFeePpm) {
            revert IssuanceFeeCurrentMismatch(currentIssuanceFeePpm, actualIssuanceFeePpm);
        }
        _validateSingleFeePpm(newIssuanceFeePpm);
        cs.issuanceFeePpm = newIssuanceFeePpm;
        emit IssuanceFeePpmUpdated(actualIssuanceFeePpm, newIssuanceFeePpm);
    }

    /// @notice Set the redemption fee in parts per million.
    /// @param currentRedemptionFeePpm Caller-supplied current redemption fee rate in parts per million.
    /// @param newRedemptionFeePpm Replacement redemption fee rate in parts per million.
    function setRedemptionFeePpm(uint256 currentRedemptionFeePpm, uint256 newRedemptionFeePpm)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (currentRedemptionFeePpm == newRedemptionFeePpm) revert FeeChangeNoop();
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        uint256 actualRedemptionFeePpm = cs.redemptionFeePpm;
        if (currentRedemptionFeePpm != actualRedemptionFeePpm) {
            revert RedemptionFeeCurrentMismatch(currentRedemptionFeePpm, actualRedemptionFeePpm);
        }
        _validateSingleFeePpm(newRedemptionFeePpm);
        cs.redemptionFeePpm = newRedemptionFeePpm;
        emit RedemptionFeePpmUpdated(actualRedemptionFeePpm, newRedemptionFeePpm);
    }

    /// @notice Set treasury.
    /// @param currentTreasury Caller-expected current treasury address.
    /// @param newTreasury Proposed replacement treasury address.
    function setTreasury(address currentTreasury, address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (currentTreasury == newTreasury) revert TreasuryChangeNoop();
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        address actualTreasury = cs.treasury;
        if (currentTreasury != actualTreasury) revert TreasuryCurrentMismatch(currentTreasury, actualTreasury);
        if (newTreasury == address(0)) revert TreasuryNotSet();
        cs.treasury = newTreasury;
        emit TreasuryUpdated(actualTreasury, newTreasury);
    }

    /// @notice Set max total supply.
    /// @param currentMaxTotalSupply Caller-expected current maximum CYGLD total supply.
    /// @param newMaxTotalSupply Proposed replacement maximum CYGLD total supply.
    function setMaxTotalSupply(uint256 currentMaxTotalSupply, uint256 newMaxTotalSupply)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        uint256 oldMaxTotalSupply = cs.maxTotalSupply;
        if (currentMaxTotalSupply == newMaxTotalSupply) revert MaxTotalSupplyChangeNoop();
        LibSupplyCap.requireCurrent(currentMaxTotalSupply, oldMaxTotalSupply);
        LibSupplyCap.requireNotBelowCurrentSupply(ICyberGoldCore(address(this)).totalSupply(), newMaxTotalSupply);
        cs.maxTotalSupply = newMaxTotalSupply;
        emit MaxTotalSupplyUpdated(oldMaxTotalSupply, newMaxTotalSupply);
    }
}
