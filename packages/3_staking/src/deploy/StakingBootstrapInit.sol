// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {IStakingFinalizer} from "./StakingLaunchTypes.sol";
import {LibStakingLaunch} from "../libraries/LibStakingLaunch.sol";

/// @notice Constructor-only initializer for a pristine committed Staking shell.
contract StakingBootstrapInit {
    /// @notice Reverts when the shell is not pristine or its bootstrap topology is not canonical.
    error InvalidBootstrapState();
    /// @notice Reverts when the committed finalizer is absent or has no runtime code.
    /// @param finalizer Candidate finalizer address rejected by bootstrap validation.
    error InvalidFinalizer(address finalizer);

    /// @notice Commit a pristine one-selector shell to one finalization payload and finalizer facet.
    /// @param payloadHash Hash of the sole finalization candidate accepted by the shell.
    /// @param finalizer Runtime-bearing facet that will relay the committed finalization.
    function initialize(bytes32 payloadHash, address finalizer) external {
        LibStakingLaunch.Layout storage launch = LibStakingLaunch.getLayout();
        if (launch.phase != LibStakingLaunch.Phase.Uninitialized || payloadHash == bytes32(0)) {
            revert InvalidBootstrapState();
        }
        if (finalizer == address(0) || finalizer.code.length == 0) revert InvalidFinalizer(finalizer);

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        if (
            LibDiamond.contractOwner() != address(0) || ds.selectors.length != 1
                || ds.selectors[0] != IStakingFinalizer.finalizeStaking.selector
                || ds.facetAddressAndSelectorPosition[IStakingFinalizer.finalizeStaking.selector].facetAddress
                    != finalizer
        ) revert InvalidBootstrapState();

        launch.phase = LibStakingLaunch.Phase.Committed;
        launch.commitment = LibStakingLaunch.commitment(payloadHash);
        launch.finalizerFacet = finalizer;
    }
}
