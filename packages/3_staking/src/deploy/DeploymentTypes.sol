// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {DiamondInit} from "../deploy/DiamondInit.sol";
import {StakingDiamond} from "../diamond/StakingDiamond.sol";
import {DiamondCutAccessLiveFacet} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {ReentrancyGuardFacet} from "diamond-infra/facets/ReentrancyGuardFacet.sol";
import {TokenFacet} from "../facets/TokenFacet.sol";
import {VaultFacet} from "../facets/VaultFacet.sol";
import {QueueFacet} from "../facets/QueueFacet.sol";
import {QueueOperatorFacet} from "../facets/QueueOperatorFacet.sol";
import {QueueSigFacet} from "../facets/QueueSigFacet.sol";
import {CustodyFacet} from "../facets/CustodyFacet.sol";
import {SleeveRegistryFacet} from "../facets/SleeveRegistryFacet.sol";
import {FundManagerFacet} from "../facets/FundManagerFacet.sol";
import {LensFacet} from "../facets/LensFacet.sol";
import {StakingFinalizerFacet} from "../facets/StakingFinalizerFacet.sol";
import {StakingBootstrapInit} from "./StakingBootstrapInit.sol";
import {StakingAuthorityInvariant} from "./StakingAuthorityInvariant.sol";
import {StakingSleeveInvariant} from "./StakingSleeveInvariant.sol";
import {StakingInterfaceInit} from "./StakingInterfaceInit.sol";
import {StakingLaunchTypes} from "./StakingLaunchTypes.sol";
import {SleeveDeployerHelper} from "./SleeveDeployerHelper.sol";

/// @notice Deployment types helpers for the staking diamond.
library DeploymentTypes {
    /// @notice Facet addresses grouped for diamond deployment and initialization.
    struct Facets {
        DiamondCutAccessLiveFacet cut;
        DiamondLoupeFacet loupe;
        DefaultAdminAccessControlFacet access;
        PausableFacet pause;
        ReentrancyGuardFacet reentrancy;
        TokenFacet token;
        VaultFacet vault;
        QueueFacet queue;
        QueueOperatorFacet queueOperator;
        QueueSigFacet queueSig;
        CustodyFacet custody;
        SleeveRegistryFacet sleeveRegistry;
        FundManagerFacet fundManager;
        LensFacet lens;
        StakingFinalizerFacet finalizer;
    }

    /// @notice Addresses produced by a package deployment.
    struct DeployArtifacts {
        StakingDiamond diamond;
        DiamondInit diamondInit;
        StakingBootstrapInit bootstrapInit;
        StakingAuthorityInvariant authorityInvariant;
        StakingSleeveInvariant sleeveInvariant;
        StakingInterfaceInit interfaceInit;
        Facets facets;
        StakingLaunchTypes.Finalization finalization;
        bytes32 payloadHash;
        SleeveDeployerHelper.SleeveDeployment[] sleeves;
    }

    /// @notice Deployment parameters consumed by the package deployment helper.
    struct DeployConfig {
        address safeWallet;
        string name;
        string symbol;
        address coreDiamond;
        address governanceDiamond;
        address[] withdrawers;
        uint64 claimExpiry;
        uint256 headSweepLimit;
        uint256 autoProcessMax;
        uint256 performanceFeePpm;
        address fundManagerSwapAdapter;
        address[] allocators;
        SleeveDeployerHelper.SleeveRequest[] sleeves;
        address create2Deployer;
        bytes32 shellSalt;
    }
}
