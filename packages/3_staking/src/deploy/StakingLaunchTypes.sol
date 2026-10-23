// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";

/// @notice Canonical committed-launch payload shared by Staking deploy and finalization code.
library StakingLaunchTypes {
    /// @notice Authenticated metadata for one unique production facet.
    struct FacetExpectation {
        address facet;
        bytes32 runtimeCodeHash;
        bytes32 namespace;
    }

    /// @notice Exact cut and initializer relayed through the committed shell.
    struct Finalization {
        IDiamond.FacetCut[] diamondCut;
        FacetExpectation[] facets;
        address initializer;
        bytes32 initializerCodeHash;
        bytes initializerCalldata;
    }
}

/// @notice Sole callable interface of an unfinalized Staking shell.
interface IStakingFinalizer {
    /// @notice Atomically install and initialize the shell's sole committed production candidate.
    /// @param candidate Exact facet cut, authenticated facets, and initializer committed at shell creation.
    function finalizeStaking(StakingLaunchTypes.Finalization calldata candidate) external;
}
