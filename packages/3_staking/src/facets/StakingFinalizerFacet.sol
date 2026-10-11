// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {StakingLaunchTypes, IStakingFinalizer} from "../deploy/StakingLaunchTypes.sol";
import {DiamondInit} from "../deploy/DiamondInit.sol";
import {LibStakingLaunch} from "../libraries/LibStakingLaunch.sol";

/// @notice Permissionless exact-payload relay for the committed Staking shell.
contract StakingFinalizerFacet is IStakingFinalizer {
    /// @notice Reverts when finalization does not begin from the exact one-selector committed shell.
    error StakingFinalizationInvalidShell();
    /// @notice Reverts when finalization is attempted outside the committed launch phase.
    /// @param phase Launch phase observed before the attempted relay.
    error StakingFinalizationInvalidPhase(LibStakingLaunch.Phase phase);
    /// @notice Reverts when trailing or non-canonical outer relay calldata is supplied.
    error StakingFinalizationInvalidRelayCalldata();
    /// @notice Reverts when the relayed candidate does not match the shell commitment.
    error StakingFinalizationCommitmentMismatch();
    /// @notice Reverts when the initializer identity or runtime hash is invalid.
    /// @param initializer Initializer address rejected by the candidate validator.
    error StakingFinalizationInvalidInitializer(address initializer);
    /// @notice Reverts when initializer calldata is malformed or non-canonical.
    error StakingFinalizationInvalidInitializerCalldata();
    /// @notice Reverts when the candidate cut is incomplete, ambiguous, or non-canonical.
    error StakingFinalizationInvalidCut();
    /// @notice Reverts when a required candidate facet is absent, duplicated, or invalid.
    /// @param facet Facet or init-only dependency rejected by validation.
    error StakingFinalizationInvalidFacet(address facet);
    /// @notice Reverts when a facet's live namespace differs from its commitment.
    /// @param facet Facet whose metadata probe did not match the candidate.
    error StakingFinalizationFacetMetadataMismatch(address facet);
    /// @notice Reverts when the initializer did not complete every terminal launch transition.
    error StakingFinalizationIncomplete();

    /// @notice Emitted after the exact committed candidate finalizes successfully.
    /// @param finalizationHash Hash of the finalized candidate payload.
    /// @param relay Permissionless account that submitted the exact relay calldata.
    event StakingFinalized(bytes32 indexed finalizationHash, address indexed relay);

    /// @notice Install and initialize the exact candidate committed by the shell constructor.
    /// @param candidate Complete cut, facet evidence, initializer identity, and initializer calldata.
    function finalizeStaking(StakingLaunchTypes.Finalization calldata candidate) external override {
        if (keccak256(msg.data) != keccak256(abi.encodeCall(IStakingFinalizer.finalizeStaking, (candidate)))) {
            revert StakingFinalizationInvalidRelayCalldata();
        }
        LibStakingLaunch.Layout storage launch = LibStakingLaunch.getLayout();
        if (launch.phase != LibStakingLaunch.Phase.Committed) {
            revert StakingFinalizationInvalidPhase(launch.phase);
        }
        _requirePristineShell(launch.finalizerFacet);

        bytes32 payloadHash_ = LibStakingLaunch.payloadHashCalldata(candidate);
        if (launch.commitment != LibStakingLaunch.commitment(payloadHash_)) {
            revert StakingFinalizationCommitmentMismatch();
        }
        _validateCandidate(candidate);

        launch.phase = LibStakingLaunch.Phase.Finalizing;
        launch.activePayloadHash = payloadHash_;
        LibDiamond.diamondCut(candidate.diamondCut, candidate.initializer, candidate.initializerCalldata);

        if (
            launch.phase != LibStakingLaunch.Phase.Finalized || launch.commitment != bytes32(0)
                || launch.activePayloadHash != bytes32(0) || launch.finalizationHash != payloadHash_
                || LibDiamond.contractOwner() != address(0)
        ) revert StakingFinalizationIncomplete();

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        if (
            ds.facetAddressAndSelectorPosition[IStakingFinalizer.finalizeStaking.selector].facetAddress != address(0)
                || ds.facetAddressAndSelectorPosition[IDiamondCut.diamondCut.selector].facetAddress == address(0)
        ) revert StakingFinalizationIncomplete();

        emit StakingFinalized(payloadHash_, msg.sender);
    }

    function _requirePristineShell(address expectedFinalizer) private view {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        if (
            LibDiamond.contractOwner() != address(0) || ds.selectors.length != 1
                || ds.selectors[0] != IStakingFinalizer.finalizeStaking.selector
                || ds.facetAddressAndSelectorPosition[IStakingFinalizer.finalizeStaking.selector].facetAddress
                    != expectedFinalizer
        ) revert StakingFinalizationInvalidShell();
    }

    function _validateCandidate(StakingLaunchTypes.Finalization calldata candidate) private view {
        if (
            candidate.initializer == address(0) || candidate.initializer.codehash != candidate.initializerCodeHash
                || candidate.initializerCalldata.length < 4
        ) revert StakingFinalizationInvalidInitializer(candidate.initializer);
        DiamondInit.InitConfig memory initCfg = _decodeCanonicalInitializer(candidate.initializerCalldata);

        uint256 addCount;
        uint256 removeCount;
        for (uint256 i; i < candidate.diamondCut.length; ++i) {
            IDiamond.FacetCut calldata cut = candidate.diamondCut[i];
            if (cut.functionSelectors.length == 0) revert StakingFinalizationInvalidCut();
            if (cut.action == IDiamond.FacetCutAction.Add) {
                ++addCount;
                for (uint256 j; j < cut.functionSelectors.length; ++j) {
                    if (cut.functionSelectors[j] == IStakingFinalizer.finalizeStaking.selector) {
                        revert StakingFinalizationInvalidCut();
                    }
                }
            } else if (cut.action == IDiamond.FacetCutAction.Remove) {
                if (
                    cut.facetAddress != address(0) || cut.functionSelectors.length != 1
                        || cut.functionSelectors[0] != IStakingFinalizer.finalizeStaking.selector
                ) revert StakingFinalizationInvalidCut();
                ++removeCount;
            } else {
                revert StakingFinalizationInvalidCut();
            }
        }
        if (removeCount != 1 || addCount == 0 || candidate.facets.length < addCount) {
            revert StakingFinalizationInvalidCut();
        }

        for (uint256 i; i < candidate.diamondCut.length; ++i) {
            IDiamond.FacetCut calldata cut = candidate.diamondCut[i];
            if (cut.action != IDiamond.FacetCutAction.Add) continue;
            bool expectedCutFacet;
            for (uint256 j; j < candidate.facets.length; ++j) {
                if (candidate.facets[j].facet == cut.facetAddress) {
                    expectedCutFacet = true;
                    break;
                }
            }
            if (!expectedCutFacet) revert StakingFinalizationInvalidFacet(cut.facetAddress);
        }

        for (uint256 i; i < candidate.facets.length; ++i) {
            StakingLaunchTypes.FacetExpectation calldata expected = candidate.facets[i];
            if (
                expected.facet == address(0) || expected.facet.codehash != expected.runtimeCodeHash
                    || expected.namespace == bytes32(0)
            ) revert StakingFinalizationInvalidFacet(expected.facet);
            for (uint256 j; j < i; ++j) {
                if (candidate.facets[j].facet == expected.facet || candidate.facets[j].namespace == expected.namespace)
                {
                    revert StakingFinalizationInvalidFacet(expected.facet);
                }
            }
            (bool nsOk, bytes memory nsData) = expected.facet.staticcall(abi.encodeWithSignature("FACET_NAMESPACE()"));
            if (
                !nsOk || nsData.length != 32 || abi.decode(nsData, (bytes32)) != expected.namespace
            ) revert StakingFinalizationFacetMetadataMismatch(expected.facet);
        }
        _requireExactDependencyExpectations(candidate.facets, initCfg);
    }

    function _decodeCanonicalInitializer(bytes calldata initializerCalldata)
        private
        pure
        returns (DiamondInit.InitConfig memory cfg)
    {
        bytes4 selector;
        assembly {
            selector := calldataload(initializerCalldata.offset)
        }
        if (selector != DiamondInit.finalize.selector) revert StakingFinalizationInvalidInitializerCalldata();

        string memory name_;
        string memory symbol_;
        (cfg, name_, symbol_) = abi.decode(initializerCalldata[4:], (DiamondInit.InitConfig, string, string));
        if (
            keccak256(initializerCalldata)
                != keccak256(abi.encodeWithSelector(DiamondInit.finalize.selector, cfg, name_, symbol_))
        ) revert StakingFinalizationInvalidInitializerCalldata();
    }

    function _requireExactDependencyExpectations(
        StakingLaunchTypes.FacetExpectation[] calldata expectations,
        DiamondInit.InitConfig memory cfg
    ) private pure {
        address[17] memory required;
        required[0] = cfg.cutFacet;
        required[1] = cfg.loupeFacet;
        required[2] = cfg.accessControlFacet;
        required[3] = cfg.pausableFacet;
        required[4] = cfg.tokenFacet;
        required[5] = cfg.vaultFacet;
        required[6] = cfg.queueFacet;
        required[7] = cfg.queueOperatorFacet;
        required[8] = cfg.queueSigFacet;
        required[9] = cfg.custodyFacet;
        required[10] = cfg.sleeveRegistryFacet;
        required[11] = cfg.fundManagerFacet;
        required[12] = cfg.lensFacet;
        required[13] = cfg.reentrancyFacet;
        required[14] = cfg.authorityInvariant;
        required[15] = cfg.sleeveInvariant;
        required[16] = cfg.interfaceInit;
        if (expectations.length != required.length) revert StakingFinalizationInvalidCut();

        for (uint256 i; i < required.length; ++i) {
            address dependency = required[i];
            if (dependency == address(0)) revert StakingFinalizationInvalidFacet(dependency);
            for (uint256 j; j < i; ++j) {
                if (required[j] == dependency) revert StakingFinalizationInvalidFacet(dependency);
            }
            bool found;
            for (uint256 j; j < expectations.length; ++j) {
                if (expectations[j].facet == dependency) {
                    found = true;
                    break;
                }
            }
            if (!found) revert StakingFinalizationInvalidFacet(dependency);
        }
    }
}
