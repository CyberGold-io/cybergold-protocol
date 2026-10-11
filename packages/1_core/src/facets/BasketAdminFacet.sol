// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {LibBasketConfig} from "../libraries/LibBasketConfig.sol";

import {ControllerBase} from "./ControllerBase.sol";

/// @notice Governance/admin basket configuration changes.
contract BasketAdminFacet is ControllerBase {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.controller.basket.admin");

    /// @notice Set basket.
    /// @param currentBasketHash Caller-expected hash of the current basket arrays.
    /// @param assets_ Basket asset addresses to configure.
    /// @param targetsPpm_ Basket target weights in parts per million.
    /// @param goldRefGramsFp18_ Asset gold reference amounts in 18-decimal fixed point.
    function setBasket(
        bytes32 currentBasketHash,
        address[] calldata assets_,
        uint256[] calldata targetsPpm_,
        uint256[] calldata goldRefGramsFp18_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bytes32 newBasketHash = LibBasketConfig.hash(assets_, targetsPpm_, goldRefGramsFp18_);
        if (currentBasketHash == newBasketHash) revert BasketChangeNoop();
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        bytes32 actualBasketHash = LibBasketConfig.hash(cs);
        if (currentBasketHash != actualBasketHash) revert BasketCurrentMismatch(currentBasketHash, actualBasketHash);
        _setBasket(cs, assets_, targetsPpm_, goldRefGramsFp18_);
        emit BasketUpdated(actualBasketHash, newBasketHash);
    }
}
