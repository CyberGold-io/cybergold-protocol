// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {DiamondArgs} from "diamond-1/Diamond.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";

import {FunctionNotFound} from "diamond-infra/diamond/ProtocolDiamond.sol";
import {StakingDiamond} from "../diamond/StakingDiamond.sol";
import {DiamondInit} from "./DiamondInit.sol";
import {StakingBootstrapInit} from "./StakingBootstrapInit.sol";
import {StakingAuthorityInvariant} from "./StakingAuthorityInvariant.sol";
import {StakingSleeveInvariant} from "./StakingSleeveInvariant.sol";
import {StakingInterfaceInit} from "./StakingInterfaceInit.sol";
import {StakingLaunchTypes, IStakingFinalizer} from "./StakingLaunchTypes.sol";
import {LibStakingLaunch} from "../libraries/LibStakingLaunch.sol";
import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";
import {DiamondCutAccessLiveFacet} from "diamond-infra/facets/DiamondCutAccessLiveFacet.sol";
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
import {StakingDiamondLoupeFacet} from "../facets/StakingDiamondLoupeFacet.sol";
import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {FacetSelectors} from "./FacetSelectors.sol";
import {SleeveDeployerHelper} from "./SleeveDeployerHelper.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";

/// @notice Candidate builder and committed-shell deployer shared by scripts and tests.
library DeploymentHelper {
    /// @notice Raised when no Governance Diamond is configured for the Staking launch.
    error StakingDeploymentMissingGovernance();

    /// @notice Raised when a required launch dependency has no deployed runtime code.
    /// @param dependency The invalid dependency address.
    error StakingDeploymentInvalidDependency(address dependency);

    /// @notice Raised when the CREATE2 factory address is not configured.
    error StakingDeploymentMissingCreate2Deployer();

    /// @notice Raised when the committed-shell CREATE2 salt is zero.
    error StakingDeploymentMissingShellSalt();

    /// @notice Raised when the launch configuration contains no allocator.
    error StakingDeploymentEmptyAllocators();

    /// @notice Raised when the launch configuration contains no Sleeve.
    error StakingDeploymentEmptySleeves();

    /// @notice Raised when two identities that must remain distinct use the same address.
    /// @param first The first colliding identity.
    /// @param second The second colliding identity.
    error StakingDeploymentIdentityCollision(address first, address second);

    /// @notice Raised when an allocator entry is zero or duplicates an earlier allocator.
    /// @param index The index of the invalid allocator entry.
    /// @param allocator The invalid allocator address.
    error StakingDeploymentInvalidAllocator(uint256 index, address allocator);

    /// @notice Raised when a withdrawer entry is zero or duplicates an earlier withdrawer.
    /// @param index The index of the invalid withdrawer entry.
    /// @param withdrawer The invalid withdrawer address.
    error StakingDeploymentInvalidWithdrawer(uint256 index, address withdrawer);

    /// @notice Raised when a requested Sleeve implementation has no deployed runtime code.
    /// @param index The index of the affected Sleeve request.
    /// @param implementation The invalid implementation address.
    error StakingDeploymentInvalidSleeveImplementation(uint256 index, address implementation);

    /// @notice Raised when two Sleeve requests encode the same complete launch configuration.
    /// @param firstIndex The index of the first request.
    /// @param duplicateIndex The index of the duplicate request.
    error StakingDeploymentDuplicateSleeve(uint256 firstIndex, uint256 duplicateIndex);

    /// @notice Raised when a derived Sleeve base salt is zero.
    /// @param index The index of the affected Sleeve request.
    /// @param salt The invalid derived salt.
    error StakingDeploymentInvalidSleeveSalt(uint256 index, bytes32 salt);

    /// @notice Raised when two Sleeve requests derive the same base salt.
    /// @param firstIndex The index of the first Sleeve using the salt.
    /// @param duplicateIndex The index of the duplicate Sleeve using the salt.
    /// @param salt The duplicated derived salt.
    error StakingDeploymentDuplicateSleeveSalt(uint256 firstIndex, uint256 duplicateIndex, bytes32 salt);

    /// @notice Raised when the local deployer is not the CREATE2 deployer committed by configuration.
    /// @param expected The configured CREATE2 deployer.
    /// @param actual The contract attempting the local deployment.
    error StakingDeploymentCreate2DeployerMismatch(address expected, address actual);

    /// @notice Raised when a deployed shell address differs from the counterfactual address.
    /// @param expected The counterfactual committed-shell address.
    /// @param actual The address returned by deployment or supplied for adoption.
    error StakingDeploymentAddressMismatch(address expected, address actual);

    /// @notice Raised when the counterfactual committed-shell address has no runtime code.
    /// @param candidate The expected committed-shell address.
    error StakingDeploymentShellMissing(address candidate);

    /// @notice Raised when the shell runtime code does not match the canonical Staking Diamond runtime.
    /// @param candidate The address whose runtime code failed authentication.
    error StakingDeploymentRuntimeMismatch(address candidate);

    /// @notice Raised when the candidate is neither a committed shell nor the matching finalized launch.
    /// @param candidate The candidate whose launch phase or finalization hash is invalid.
    error StakingDeploymentLaunchStateMismatch(address candidate);

    /// @notice Raised when a facet does not expose valid namespace and version metadata.
    /// @param facet The facet that failed metadata authentication.
    error StakingDeploymentFacetMetadataInvalid(address facet);

    /// @notice Raised when deployment artifacts no longer encode the committed finalization candidate.
    error StakingDeploymentCandidateMismatch();

    /// @notice Raised when the finalized Diamond facet topology differs from the committed topology.
    error StakingDeploymentTopologyMismatch();

    /// @dev Prepare facets and the exact committed finalization without deploying the shell.
    function prepare(DeploymentTypes.DeployConfig memory cfg)
        internal
        returns (DeploymentTypes.DeployArtifacts memory out)
    {
        if (cfg.governanceDiamond == address(0)) revert StakingDeploymentMissingGovernance();
        if (cfg.coreDiamond.code.length == 0) revert StakingDeploymentInvalidDependency(cfg.coreDiamond);
        if (cfg.governanceDiamond.code.length == 0) {
            revert StakingDeploymentInvalidDependency(cfg.governanceDiamond);
        }
        if (cfg.create2Deployer == address(0)) revert StakingDeploymentMissingCreate2Deployer();
        if (cfg.shellSalt == bytes32(0)) revert StakingDeploymentMissingShellSalt();
        if (cfg.allocators.length == 0) revert StakingDeploymentEmptyAllocators();
        if (cfg.sleeves.length == 0) revert StakingDeploymentEmptySleeves();
        _requireDistinctIdentities(cfg);
        _requireUniqueRosters(cfg);
        _requireValidSleeves(cfg.sleeves);
        _requireUniqueSleeves(cfg.sleeves);
        out = _deployFacets(out);

        out.finalization = _buildFinalization(cfg, out);
        out.payloadHash = LibStakingLaunch.payloadHash(out.finalization);
        address predicted = predictedShell(cfg, out);
        requireDistinctLaunchIdentities(cfg, predicted);
    }

    function _requireDistinctIdentities(DeploymentTypes.DeployConfig memory cfg) private pure {
        if (cfg.coreDiamond == cfg.governanceDiamond) {
            revert StakingDeploymentIdentityCollision(cfg.coreDiamond, cfg.governanceDiamond);
        }
        if (cfg.coreDiamond == cfg.safeWallet) {
            revert StakingDeploymentIdentityCollision(cfg.coreDiamond, cfg.safeWallet);
        }
        if (cfg.governanceDiamond == cfg.safeWallet) {
            revert StakingDeploymentIdentityCollision(cfg.governanceDiamond, cfg.safeWallet);
        }
    }

    /// @dev Reject the counterfactual shell from every authenticated launch identity.
    function requireDistinctLaunchIdentities(DeploymentTypes.DeployConfig memory cfg, address predicted) internal pure {
        if (cfg.coreDiamond == predicted) revert StakingDeploymentIdentityCollision(cfg.coreDiamond, predicted);
        if (cfg.governanceDiamond == predicted) {
            revert StakingDeploymentIdentityCollision(cfg.governanceDiamond, predicted);
        }
        if (cfg.safeWallet == predicted) revert StakingDeploymentIdentityCollision(cfg.safeWallet, predicted);
    }

    function _requireUniqueRosters(DeploymentTypes.DeployConfig memory cfg) private pure {
        for (uint256 i; i < cfg.allocators.length; ++i) {
            address allocator = cfg.allocators[i];
            if (allocator == address(0)) revert StakingDeploymentInvalidAllocator(i, allocator);
            for (uint256 j; j < i; ++j) {
                if (cfg.allocators[j] == allocator) revert StakingDeploymentInvalidAllocator(i, allocator);
            }
        }
        for (uint256 i; i < cfg.withdrawers.length; ++i) {
            address withdrawer = cfg.withdrawers[i];
            if (withdrawer == address(0)) revert StakingDeploymentInvalidWithdrawer(i, withdrawer);
            for (uint256 j; j < i; ++j) {
                if (cfg.withdrawers[j] == withdrawer) revert StakingDeploymentInvalidWithdrawer(i, withdrawer);
            }
        }
    }

    function _requireValidSleeves(SleeveDeployerHelper.SleeveRequest[] memory sleeves) private view {
        for (uint256 i; i < sleeves.length; ++i) {
            SleeveDeployerHelper.SleeveRequest memory request = sleeves[i];
            if (request.implementation.code.length == 0) {
                revert StakingDeploymentInvalidSleeveImplementation(i, request.implementation);
            }
            SleeveDeployerHelper._buildInitializer(request, address(1));
        }
    }

    function _requireUniqueSleeves(SleeveDeployerHelper.SleeveRequest[] memory sleeves) private pure {
        for (uint256 i; i < sleeves.length; ++i) {
            bytes32 requestHash = keccak256(abi.encode(sleeves[i]));
            for (uint256 j; j < i; ++j) {
                if (requestHash == keccak256(abi.encode(sleeves[j]))) {
                    revert StakingDeploymentDuplicateSleeve(j, i);
                }
            }
        }
    }

    /// @dev Test/local-only CREATE2 helper. The calling contract is the actual deployer.
    /// Production callers must submit `salt || shellInitCode(out)` to the configured
    /// external factory and then use `adoptCommittedShell`.
    function deployCommittedShellLocal(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory out
    ) internal returns (DeploymentTypes.DeployArtifacts memory) {
        if (cfg.create2Deployer != address(this)) {
            revert StakingDeploymentCreate2DeployerMismatch(cfg.create2Deployer, address(this));
        }
        address predicted = predictedShell(cfg, out);
        if (predicted.code.length != 0) return adoptCommittedShell(cfg, out);

        (IDiamond.FacetCut[] memory shellCut, DiamondArgs memory args) = _shellCutAndArgs(out);
        StakingDiamond deployed = new StakingDiamond{salt: cfg.shellSalt}(shellCut, args);
        requireExpectedAddress(predicted, address(deployed));
        return adoptCommittedShell(cfg, out);
    }

    /// @notice Adopt code at the exact address committed by factory, salt, and init code.
    /// @dev This is deliberately read-only. Canonical creation history and pristine raw
    /// storage remain Ops evidence; the exact relay/reconciliation path below independently
    /// fails closed unless the shell is Committed or the matching payload is Finalized.
    function adoptCommittedShell(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory out)
        internal
        view
        returns (DeploymentTypes.DeployArtifacts memory)
    {
        if (cfg.create2Deployer == address(0)) revert StakingDeploymentMissingCreate2Deployer();
        if (cfg.shellSalt == bytes32(0)) revert StakingDeploymentMissingShellSalt();

        address predicted = predictedShell(cfg, out);
        if (predicted.code.length == 0) revert StakingDeploymentShellMissing(predicted);
        if (predicted.codehash != keccak256(type(StakingDiamond).runtimeCode)) {
            revert StakingDeploymentRuntimeMismatch(predicted);
        }
        out.diamond = StakingDiamond(payable(predicted));
        return out;
    }

    /// @dev Relay an exact committed finalization or reconcile an identical prior relay.
    function finalizeCommitted(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory out)
        internal
        returns (DeploymentTypes.DeployArtifacts memory)
    {
        out = adoptCommittedShell(cfg, out);
        address shell = address(out.diamond);
        bytes memory stateCall = abi.encodeCall(LensFacet.stakingLaunchState, ());
        (bool stateOk, bytes memory stateData) = shell.staticcall(stateCall);
        if (stateOk) {
            if (stateData.length != 64) revert StakingDeploymentLaunchStateMismatch(shell);
            (LibStakingLaunch.Phase phase, bytes32 finalizationHash) =
                abi.decode(stateData, (LibStakingLaunch.Phase, bytes32));
            if (phase != LibStakingLaunch.Phase.Finalized || finalizationHash != out.payloadHash) {
                revert StakingDeploymentLaunchStateMismatch(shell);
            }
            return finalizeCommittedResults(cfg, out);
        }

        bytes memory expectedMissingLens =
            abi.encodeWithSelector(FunctionNotFound.selector, LensFacet.stakingLaunchState.selector);
        if (keccak256(stateData) != keccak256(expectedMissingLens)) {
            revert StakingDeploymentLaunchStateMismatch(shell);
        }
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        return finalizeCommittedResults(cfg, out);
    }

    /// @dev Resolve authenticated deterministic artifacts after any permissionless relay finalized the shell.
    function finalizeCommittedResults(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory out
    ) internal view returns (DeploymentTypes.DeployArtifacts memory) {
        requireFinalizedCandidate(cfg, out);
        out.sleeves = _sleeveResults(cfg, address(out.diamond), out.payloadHash);
        return out;
    }

    /// @notice Require that a finalized shell still matches the complete committed candidate.
    /// @dev This is the shared semantic attestation used by relay reconciliation and artifact writing.
    ///      Raw selector positions and version-registry words are additionally checked by DeployParams,
    ///      whose Foundry VM boundary can inspect storage directly.
    function requireFinalizedCandidate(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory out
    ) internal view {
        requirePreparedCandidate(cfg, out);

        address shell = address(out.diamond);
        address predicted = predictedShell(cfg, out);
        if (shell != predicted) revert StakingDeploymentAddressMismatch(predicted, shell);
        if (shell.codehash != keccak256(type(StakingDiamond).runtimeCode)) {
            revert StakingDeploymentRuntimeMismatch(shell);
        }

        (LibStakingLaunch.Phase phase, bytes32 finalizationHash) = LensFacet(shell).stakingLaunchState();
        if (phase != LibStakingLaunch.Phase.Finalized || finalizationHash != out.payloadHash) {
            revert StakingDeploymentLaunchStateMismatch(shell);
        }
        _requireFinalizedTopology(out);
    }

    /// @notice Require a reconstructed pre-shell artifact to be the one canonical candidate for `cfg`.
    /// @dev Staged production broadcasters use this after decoding the sealed prepared artifact. It
    ///      recomputes the cut, facet expectations, initializer payload, payload hash, and shell identity
    ///      from the authenticated runtime contracts and typed deployment configuration.
    function requirePreparedCandidate(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory out
    ) internal view {
        if (LibStakingLaunch.payloadHash(out.finalization) != out.payloadHash) {
            revert StakingDeploymentCandidateMismatch();
        }

        StakingLaunchTypes.Finalization memory expected = _buildFinalization(cfg, out);
        if (keccak256(abi.encode(expected)) != keccak256(abi.encode(out.finalization))) {
            revert StakingDeploymentCandidateMismatch();
        }
        address predicted = predictedShell(cfg, out);
        requireDistinctLaunchIdentities(cfg, predicted);
    }

    function facetSpecs(DeploymentTypes.DeployArtifacts memory out)
        internal
        pure
        returns (FacetSpec.Entry[] memory specs)
    {
        FacetSpec.Entry[] memory baseSpecs = FacetSpec.liveDefaultAdminBase(
            address(out.facets.cut),
            address(out.facets.loupe),
            address(out.facets.access),
            address(out.facets.pause),
            true
        );
        FacetSpec.Entry[] memory productSpecs = FacetSelectors.specs(
            address(out.facets.token),
            address(out.facets.vault),
            address(out.facets.queue),
            address(out.facets.queueOperator),
            address(out.facets.queueSig),
            address(out.facets.custody),
            address(out.facets.sleeveRegistry),
            address(out.facets.fundManager),
            address(out.facets.lens)
        );
        specs = FacetSpec.concat(baseSpecs, productSpecs);
    }

    /// @notice Return the exact committed-shell constructor bytes submitted to the CREATE2 factory.
    function shellInitCode(DeploymentTypes.DeployArtifacts memory out) internal pure returns (bytes memory) {
        (IDiamond.FacetCut[] memory shellCut, DiamondArgs memory args) = _shellCutAndArgs(out);
        return bytes.concat(type(StakingDiamond).creationCode, abi.encode(shellCut, args));
    }

    /// @notice Return the exact committed-shell init-code hash shared by scripts and Ops verification.
    function shellInitCodeHash(DeploymentTypes.DeployArtifacts memory out) internal pure returns (bytes32) {
        return keccak256(shellInitCode(out));
    }

    /// @notice Predict the exact committed shell under the configured CREATE2 boundary.
    function predictedShell(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory out)
        internal
        pure
        returns (address)
    {
        return _create2Address(cfg.create2Deployer, cfg.shellSalt, shellInitCodeHash(out));
    }

    /// @notice Return the exact permissionless relay calldata for the committed candidate.
    function finalizationCalldata(DeploymentTypes.DeployArtifacts memory out) internal pure returns (bytes memory) {
        return abi.encodeCall(IStakingFinalizer.finalizeStaking, (out.finalization));
    }

    function finalizationCalldataHash(DeploymentTypes.DeployArtifacts memory out) internal pure returns (bytes32) {
        return keccak256(finalizationCalldata(out));
    }

    function _buildFinalization(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory out)
        private
        view
        returns (StakingLaunchTypes.Finalization memory finalization)
    {
        FacetSpec.Entry[] memory specs = facetSpecs(out);
        IDiamond.FacetCut[] memory productionCut = FacetSpec.buildCut(specs);
        IDiamond.FacetCut[] memory finalCut = new IDiamond.FacetCut[](productionCut.length + 1);
        bytes4[] memory removeSelector = new bytes4[](1);
        removeSelector[0] = IStakingFinalizer.finalizeStaking.selector;
        finalCut[0] = IDiamond.FacetCut({
            facetAddress: address(0), action: IDiamond.FacetCutAction.Remove, functionSelectors: removeSelector
        });
        for (uint256 i; i < productionCut.length; ++i) {
            finalCut[i + 1] = productionCut[i];
        }

        DiamondInit.LaunchSleeve[] memory launchSleeves = _launchSleeves(cfg);
        DiamondInit.InitConfig memory initCfg = _initConfig(cfg, out, launchSleeves);
        finalization = StakingLaunchTypes.Finalization({
            diamondCut: finalCut,
            facets: _facetExpectations(specs, out),
            initializer: address(out.diamondInit),
            initializerCodeHash: address(out.diamondInit).codehash,
            initializerCalldata: abi.encodeWithSelector(DiamondInit.finalize.selector, initCfg, cfg.name, cfg.symbol)
        });
    }

    /// @dev Require the exact ordered facet and selector topology committed by the candidate.
    function _requireFinalizedTopology(DeploymentTypes.DeployArtifacts memory out) internal view {
        FacetSpec.Entry[] memory expected = facetSpecs(out);
        IDiamondLoupe.Facet[] memory observed = IDiamondLoupe(address(out.diamond)).facets();
        if (observed.length != expected.length) revert StakingDeploymentTopologyMismatch();

        for (uint256 i; i < expected.length; ++i) {
            if (
                observed[i].facetAddress != expected[i].facet
                    || keccak256(abi.encode(observed[i].functionSelectors))
                        != keccak256(abi.encode(expected[i].selectors))
            ) revert StakingDeploymentTopologyMismatch();
        }
    }

    function _deployFacets(DeploymentTypes.DeployArtifacts memory out)
        private
        returns (DeploymentTypes.DeployArtifacts memory)
    {
        out.facets.cut = new DiamondCutAccessLiveFacet();
        out.facets.loupe = DiamondLoupeFacet(address(new StakingDiamondLoupeFacet()));
        out.facets.access = new DefaultAdminAccessControlFacet();
        out.facets.pause = new PausableFacet();
        out.facets.reentrancy = new ReentrancyGuardFacet();
        out.facets.token = new TokenFacet();
        out.facets.vault = new VaultFacet();
        out.facets.queue = new QueueFacet();
        out.facets.queueOperator = new QueueOperatorFacet();
        out.facets.queueSig = new QueueSigFacet();
        out.facets.custody = new CustodyFacet();
        out.facets.sleeveRegistry = new SleeveRegistryFacet();
        out.facets.fundManager = new FundManagerFacet();
        out.facets.lens = new LensFacet();
        out.facets.finalizer = new StakingFinalizerFacet();
        out.diamondInit = new DiamondInit();
        out.bootstrapInit = new StakingBootstrapInit();
        out.authorityInvariant = new StakingAuthorityInvariant();
        out.sleeveInvariant = new StakingSleeveInvariant();
        out.interfaceInit = new StakingInterfaceInit();
        return out;
    }

    function _initConfig(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory out,
        DiamondInit.LaunchSleeve[] memory launchSleeves
    ) private pure returns (DiamondInit.InitConfig memory initCfg) {
        initCfg = DiamondInit.InitConfig({
            safeWallet: cfg.safeWallet,
            authorityInvariant: address(out.authorityInvariant),
            sleeveInvariant: address(out.sleeveInvariant),
            interfaceInit: address(out.interfaceInit),
            accessControlFacet: address(out.facets.access),
            loupeFacet: address(out.facets.loupe),
            pausableFacet: address(out.facets.pause),
            reentrancyFacet: address(out.facets.reentrancy),
            cutFacet: address(out.facets.cut),
            tokenFacet: address(out.facets.token),
            vaultFacet: address(out.facets.vault),
            sleeveRegistryFacet: address(out.facets.sleeveRegistry),
            queueFacet: address(out.facets.queue),
            queueOperatorFacet: address(out.facets.queueOperator),
            queueSigFacet: address(out.facets.queueSig),
            custodyFacet: address(out.facets.custody),
            fundManagerFacet: address(out.facets.fundManager),
            lensFacet: address(out.facets.lens),
            coreDiamond: cfg.coreDiamond,
            governanceDiamond: cfg.governanceDiamond,
            withdrawers: cfg.withdrawers,
            allocators: cfg.allocators,
            sleeves: launchSleeves,
            claimExpiry: cfg.claimExpiry,
            headSweepLimit: cfg.headSweepLimit,
            autoProcessMax: cfg.autoProcessMax,
            performanceFeePpm: cfg.performanceFeePpm,
            fundManagerSwapAdapter: cfg.fundManagerSwapAdapter
        });
    }

    function _launchSleeves(DeploymentTypes.DeployConfig memory cfg)
        private
        view
        returns (DiamondInit.LaunchSleeve[] memory sleeves)
    {
        sleeves = new DiamondInit.LaunchSleeve[](cfg.sleeves.length);
        for (uint256 i; i < cfg.sleeves.length; ++i) {
            SleeveDeployerHelper.SleeveRequest memory request = cfg.sleeves[i];
            bytes32 requestHash = keccak256(abi.encode(request));
            bytes32 salt = LibStakingLaunch.sleeveBaseSalt(cfg.shellSalt, i, requestHash);
            requireValidSleeveSalt(sleeves, i, salt);
            sleeves[i] = DiamondInit.LaunchSleeve({
                request: request, implementationCodeHash: request.implementation.codehash, salt: salt
            });
        }
    }

    function _facetExpectations(FacetSpec.Entry[] memory specs, DeploymentTypes.DeployArtifacts memory out)
        private
        view
        returns (StakingLaunchTypes.FacetExpectation[] memory expected)
    {
        expected = new StakingLaunchTypes.FacetExpectation[](specs.length + 4);
        for (uint256 i; i < specs.length; ++i) {
            expected[i] = _expectFacet(specs[i].facet);
        }
        expected[specs.length] = _expectFacet(address(out.facets.reentrancy));
        expected[specs.length + 1] = _expectFacet(address(out.authorityInvariant));
        expected[specs.length + 2] = _expectFacet(address(out.sleeveInvariant));
        expected[specs.length + 3] = _expectFacet(address(out.interfaceInit));
    }

    /// @dev Authenticate one facet's runtime code and stable namespace metadata.
    function _expectFacet(address facet) internal view returns (StakingLaunchTypes.FacetExpectation memory expected) {
        (bool nsOk, bytes memory nsData) = facet.staticcall(abi.encodeWithSignature("FACET_NAMESPACE()"));
        if (!nsOk || nsData.length != 32) {
            revert StakingDeploymentFacetMetadataInvalid(facet);
        }
        expected = StakingLaunchTypes.FacetExpectation({
            facet: facet,
            runtimeCodeHash: facet.codehash,
            namespace: abi.decode(nsData, (bytes32))
        });
    }

    /// @dev Require a CREATE2 deployment result to equal its counterfactual address.
    function requireExpectedAddress(address expected, address actual) internal pure {
        if (actual != expected) revert StakingDeploymentAddressMismatch(expected, actual);
    }

    /// @dev Require a nonzero Sleeve base salt not already used by an earlier request.
    function requireValidSleeveSalt(DiamondInit.LaunchSleeve[] memory sleeves, uint256 index, bytes32 salt)
        internal
        pure
    {
        if (salt == bytes32(0)) revert StakingDeploymentInvalidSleeveSalt(index, salt);
        for (uint256 j; j < index; ++j) {
            if (salt == sleeves[j].salt) revert StakingDeploymentDuplicateSleeveSalt(j, index, salt);
        }
    }

    function _sleeveResults(DeploymentTypes.DeployConfig memory cfg, address stakingDiamond, bytes32 payloadHash_)
        private
        view
        returns (SleeveDeployerHelper.SleeveDeployment[] memory sleeves)
    {
        DiamondInit.LaunchSleeve[] memory launchSleeves = _launchSleeves(cfg);
        sleeves = new SleeveDeployerHelper.SleeveDeployment[](launchSleeves.length);
        for (uint256 i; i < launchSleeves.length; ++i) {
            address sleeve = SleeveDeployerHelper.predictDeterministic(
                stakingDiamond,
                stakingDiamond,
                launchSleeves[i].request,
                LibStakingLaunch.sleeveSalt(payloadHash_, launchSleeves[i].salt, i)
            );
            sleeves[i] = SleeveDeployerHelper.SleeveDeployment({
                sleeve: sleeve, asset: launchSleeves[i].request.asset, approve: launchSleeves[i].request.approve
            });
        }
    }

    function _create2Address(address deployer, bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    function _shellCutAndArgs(DeploymentTypes.DeployArtifacts memory out)
        private
        pure
        returns (IDiamond.FacetCut[] memory shellCut, DiamondArgs memory args)
    {
        shellCut = new IDiamond.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IStakingFinalizer.finalizeStaking.selector;
        shellCut[0] = IDiamond.FacetCut({
            facetAddress: address(out.facets.finalizer),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: selectors
        });
        args = DiamondArgs({
            owner: address(0),
            init: address(out.bootstrapInit),
            initCalldata: abi.encodeWithSelector(
                StakingBootstrapInit.initialize.selector, out.payloadHash, address(out.facets.finalizer)
            )
        });
    }
}
