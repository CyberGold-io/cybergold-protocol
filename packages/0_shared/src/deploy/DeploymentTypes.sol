// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {ProtocolDiamond} from "../diamond/ProtocolDiamond.sol";
import {DiamondCutAccessFacet} from "diamond-infra/facets/DiamondCutAccessFacet.sol";
import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {AccessControlFacet} from "../facets/AccessControlFacet.sol";
import {PausableFacet} from "../facets/PausableFacet.sol";
import {ReentrancyGuardFacet} from "../facets/ReentrancyGuardFacet.sol";
import {InfraInit} from "./InfraInit.sol";

/// @notice Deployment types helpers for the shared diamond infrastructure.
library DeploymentTypes {
    /// @notice Facet addresses grouped for diamond deployment and initialization.
    struct Facets {
        DiamondCutAccessFacet cut;
        DiamondLoupeFacet loupe;
        AccessControlFacet access;
        PausableFacet pause;
        ReentrancyGuardFacet reentrancy;
    }

    /// @notice Addresses produced by a package deployment.
    struct DeployArtifacts {
        ProtocolDiamond diamond;
        InfraInit diamondInit;
        Facets facets;
    }

    /// @notice Deployment parameters consumed by the package deployment helper.
    struct DeployConfig {
        address admin;
        address safeWallet;
        bool includePause;
        bool includeReentrancy;
    }
}
