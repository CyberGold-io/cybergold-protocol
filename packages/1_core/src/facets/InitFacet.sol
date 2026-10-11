// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {LibReserveLifecycle} from "../libraries/LibReserveLifecycle.sol";
import {LibSupplyCap} from "../libraries/LibSupplyCap.sol";

import {ControllerBase} from "./ControllerBase.sol";

/// @notice Controller init facet for wiring core configuration and default basket state.
contract InitFacet is ControllerBase {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.controller.init");

    /// @notice Initial core controller wiring and economic parameters.
    struct ControllerInitConfig {
        address coreTreasury;
        address[] assets;
        uint256[] targetsPpm;
        uint256[] goldRefGramsFp18;
        uint256 cygldRefGramsFp18;
        uint256 maxTotalSupply;
        uint256 issuanceFeePpm;
        uint256 redemptionFeePpm;
    }

    /// @notice Initialize controller wiring and deployment-provided fees.
    /// @param cfg Initial core controller wiring, basket, fee, and supply cap configuration.
    function initController(ControllerInitConfig calldata cfg) external onlyInit {
        if (cfg.coreTreasury == address(0)) revert TreasuryNotSet();
        LibSupplyCap.requireSet(cfg.maxTotalSupply);
        _validateFeePpm(cfg.issuanceFeePpm, cfg.redemptionFeePpm);

        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        cs.treasury = cfg.coreTreasury;
        cs.cygldRefGramsFp18 = cfg.cygldRefGramsFp18;
        cs.maxTotalSupply = cfg.maxTotalSupply;
        cs.issuanceFeePpm = cfg.issuanceFeePpm;
        cs.redemptionFeePpm = cfg.redemptionFeePpm;
        emit IssuanceFeePpmUpdated(0, cs.issuanceFeePpm);
        emit RedemptionFeePpmUpdated(0, cs.redemptionFeePpm);
        emit TreasuryUpdated(address(0), cfg.coreTreasury);
        emit MaxTotalSupplyUpdated(0, cfg.maxTotalSupply);

        _setInitialBasket(cs, cfg.assets, cfg.targetsPpm, cfg.goldRefGramsFp18);

        uint256 n = cfg.assets.length;
        for (uint256 i; i < n;) {
            LibReserveLifecycle.initializeActive(cfg.assets[i]);
            unchecked {
                ++i;
            }
        }
    }
}
