// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {DiamondInit} from "../deploy/DiamondInit.sol";
import {GovernanceDiamond} from "../diamond/GovernanceDiamond.sol";
import {DiamondCutAccessLiveFacet} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {AccessControlFacet} from "diamond-infra/facets/AccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {GovernorCoreFacet} from "../facets/GovernorCoreFacet.sol";
import {TokenFacet} from "../facets/TokenFacet.sol";
import {TreasuryFacet} from "../facets/TreasuryFacet.sol";
import {RecoveryFundFacet} from "../facets/RecoveryFundFacet.sol";
import {RecoveryFundLensFacet} from "../facets/RecoveryFundLensFacet.sol";
import {GovernorSettingsFacet} from "../facets/GovernorSettingsFacet.sol";

/// @notice Deployment types helpers for the governance diamond.
library DeploymentTypes {
    /// @notice Facet addresses grouped for diamond deployment and initialization.
    struct Facets {
        DiamondCutAccessLiveFacet cut;
        DiamondLoupeFacet loupe;
        AccessControlFacet access;
        PausableFacet pause;
        GovernorCoreFacet governorCore;
        TokenFacet token;
        TreasuryFacet treasury;
        RecoveryFundFacet recoveryFund;
        RecoveryFundLensFacet recoveryFundLens;
        GovernorSettingsFacet governorSettings;
    }

    /// @notice Addresses produced by a package deployment.
    struct DeployArtifacts {
        GovernanceDiamond diamond;
        DiamondInit diamondInit;
        Facets facets;
    }

    /// @notice Deployment parameters consumed by the package deployment helper.
    struct DeployConfig {
        /// @dev Temporary constructor authority cleared atomically by `DiamondInit`.
        address constructorOwner;
        address safeWallet;
        address trustedCore;
        uint256 executionDelay;
        uint256 executionGracePeriod;
        string name;
        string tokenSymbol;
        address tokenInitialHolder;
        uint256 tokenInitialSupply;
        uint256 tokenTreasurySupply;
        uint256 votingDelay;
        uint256 votingPeriod;
        uint256 proposalThresholdNumerator;
        uint256 quorumNumerator;
    }
}
