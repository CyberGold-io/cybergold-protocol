// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Vm} from "forge-std/Vm.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {DiamondInit} from "./DiamondInit.sol";
import {IStakingFinalizer, StakingLaunchTypes} from "./StakingLaunchTypes.sol";
import {DeploymentHelper} from "./DeploymentHelper.sol";
import {SleeveDeployerHelper} from "./SleeveDeployerHelper.sol";
import {SleeveArtifactWriter} from "./SleeveArtifactWriter.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";
import {FacetSelectors} from "./FacetSelectors.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {LensFacet} from "../facets/LensFacet.sol";
import {FundManagerFacet} from "../facets/FundManagerFacet.sol";
import {LibStakingLaunch} from "../libraries/LibStakingLaunch.sol";
import {StakingDiamond} from "../diamond/StakingDiamond.sol";
import {SleeveProxy} from "../sleeves/SleeveProxy.sol";

/// @notice Centralized parameter builder for Staking diamond deployments.
library DeployParams {
    bytes32 private constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");
    bytes32 private constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    bytes32 private constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 private constant STAKING_LAUNCH_STORAGE_SLOT =
        0xaf998c30b6bf758887c4f7ae3b9979a4920a749d595a880ba4118393868a6f00;
    uint256 private constant SELECTOR_BEARING_FACET_COUNT = 13;

    /// @notice Environment-derived deployment parameters.
    struct Params {
        address safeWallet;
        address coreDiamond;
        address governanceDiamond;
        address[] withdrawers;
        string name;
        string symbol;
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

    /// @notice ABI-level and raw-storage observations required to attest a finalized Staking launch.
    struct FinalizedEvidence {
        LibStakingLaunch.Phase phase;
        bytes32 finalizationHash;
        address bootstrapSelectorOwner;
        address diamondOwner;
        bool paused;
        bytes32 shellInitCodeHash;
        address predictedShell;
        address[] effectiveWithdrawers;
        bytes32 liveCommitment;
        bytes32 activePayloadHash;
        address committedFinalizerFacet;
    }

    /// @notice Observations read from the finalized Diamond and its raw launch registries.
    struct CandidateEvidence {
        bytes32[] selectors;
        address[] selectorOwners;
        uint256[] selectorPositions;
        address[] facetAddresses;
        bytes32[] facetRuntimeCodeHashes;
        bytes32[] facetNamespaces;
        uint256[] initializedFacetGenerations;
        bytes32 selectorTopologyHash;
        bytes32 facetEvidenceHash;
        bytes32 initializedFacetGenerationsHash;
    }

    /// @notice Canonical pre-shell Sleeve inputs and derived CREATE2 identities.
    struct PreparedSleeveEvidence {
        address[] implementations;
        bytes32[] implementationHashes;
        bytes[] requestAbi;
        bytes32[] requestHashes;
        bytes32[] baseSalts;
        bytes32[] effectiveSalts;
        bytes[] initializerCalldata;
        bytes32[] initializerCalldataHashes;
        bytes32[] proxyInitCodeHashes;
        address[] predictedProxies;
    }

    /// @notice Load params from environment variables used by the package script.
    /// Canonical inputs use DEPLOY_SAFE_WALLET and the documented STAKING_* names.
    /// @param vm_ Foundry VM cheatcode handle used to read environment variables and config defaults.
    /// @return p Deployment parameters assembled from defaults and environment overrides.
    function fromEnv(Vm vm_) internal view returns (Params memory p) {
        DeployConfig.ProtocolConfig memory defaults = DeployConfig.loadProtocol(vm_);
        p.safeWallet =
            DeployParamsHelper.envAddressOr(vm_, DeployParamsHelper.keys1("DEPLOY_SAFE_WALLET"), defaults.safeWallet);
        p.coreDiamond = DeployParamsHelper.envAddressRequired(vm_, DeployParamsHelper.keys1("STAKING_CORE_DIAMOND"));
        p.governanceDiamond = DeployParamsHelper.envAddressRequired(vm_, DeployParamsHelper.keys1("GOVERNANCE_DIAMOND"));
        p.name = DeployParamsHelper.envStringOr(vm_, DeployParamsHelper.keys1("STAKING_NAME"), defaults.staking.name);
        p.symbol =
            DeployParamsHelper.envStringOr(vm_, DeployParamsHelper.keys1("STAKING_SYMBOL"), defaults.staking.symbol);
        p.claimExpiry = uint64(
            DeployParamsHelper.envUintOr(
                vm_, DeployParamsHelper.keys1("STAKING_CLAIM_EXPIRY"), defaults.queue.claimExpiry
            )
        );
        p.headSweepLimit = DeployParamsHelper.envUintOr(
            vm_, DeployParamsHelper.keys1("STAKING_HEAD_SWEEP_LIMIT"), defaults.queue.headSweepLimit
        );
        p.autoProcessMax = DeployParamsHelper.envUintOr(
            vm_, DeployParamsHelper.keys1("STAKING_AUTO_PROCESS_MAX"), defaults.queue.autoProcessMax
        );
        p.performanceFeePpm = DeployParamsHelper.envUintOr(
            vm_, DeployParamsHelper.keys1("STAKING_PERFORMANCE_FEE_PPM"), defaults.performanceFeePpm
        );
        p.fundManagerSwapAdapter = vm_.envAddress("STAKING_FUND_MANAGER_SWAP_ADAPTER");
        p.withdrawers = vm_.envOr("STAKING_WITHDRAWERS", ",", defaults.staking.withdrawers);
        p.create2Deployer =
            DeployParamsHelper.envAddressRequired(vm_, DeployParamsHelper.keys1("STAKING_CREATE2_DEPLOYER"));
        p.shellSalt = vm_.envBytes32("STAKING_SHELL_SALT");
        p.allocators = vm_.envAddress("STAKING_ALLOCATORS", ",");
        p.sleeves = sleevesFromEnv(vm_);
        validateExecutionContext(vm_, p);
    }

    /// @dev Require a configured Safe wallet and an explicit mainnet input.
    /// @param vm_ Forge VM used to attest explicit environment variables.
    /// @param p Candidate deployment parameters to validate.
    function validateExecutionContext(Vm vm_, Params memory p) internal view {
        require(p.safeWallet != address(0), "DEPLOY_SAFE_WALLET must be nonzero");
        require(p.coreDiamond != address(0), "STAKING_CORE_DIAMOND must be nonzero");
        require(p.governanceDiamond != address(0), "GOVERNANCE_DIAMOND must be nonzero");
        require(p.create2Deployer != address(0), "STAKING_CREATE2_DEPLOYER must be nonzero");
        require(p.shellSalt != bytes32(0), "STAKING_SHELL_SALT must be nonzero");
        require(p.allocators.length != 0, "STAKING_ALLOCATORS must not be empty");
        require(p.sleeves.length != 0, "STAKING_SLEEVES must not be empty");
        if (block.chainid != 1) return;
        require(vm_.envExists("DEPLOY_SAFE_WALLET"), "mainnet DEPLOY_SAFE_WALLET must be explicit");
    }

    /// @dev Return to config.
    /// @param p Deployment parameter struct being loaded or serialized.
    /// @return cfg Configuration view or deployment parameters assembled by the helper.
    function toConfig(Params memory p) internal pure returns (DeploymentTypes.DeployConfig memory cfg) {
        cfg.safeWallet = p.safeWallet;
        cfg.coreDiamond = p.coreDiamond;
        cfg.governanceDiamond = p.governanceDiamond;
        cfg.withdrawers = p.withdrawers;
        cfg.name = p.name;
        cfg.symbol = p.symbol;
        cfg.claimExpiry = p.claimExpiry;
        cfg.headSweepLimit = p.headSweepLimit;
        cfg.autoProcessMax = p.autoProcessMax;
        cfg.performanceFeePpm = p.performanceFeePpm;
        cfg.fundManagerSwapAdapter = p.fundManagerSwapAdapter;
        cfg.allocators = p.allocators;
        cfg.sleeves = p.sleeves;
        cfg.create2Deployer = p.create2Deployer;
        cfg.shellSalt = p.shellSalt;
    }

    /// @notice Load the exact ordered Sleeve requests from the canonical Staking environment inputs.
    /// @dev Exposed to the full-stack Protocol builder so standalone and aggregate launches share one parser.
    function sleevesFromEnv(Vm vm_) internal view returns (SleeveDeployerHelper.SleeveRequest[] memory sleeves) {
        address[] memory implementations = vm_.envAddress("STAKING_SLEEVE_IMPLEMENTATIONS", ",");
        address[] memory assets = vm_.envAddress("STAKING_SLEEVE_ASSETS", ",");
        bool[] memory approvals = vm_.envBool("STAKING_SLEEVE_APPROVALS", ",");
        bool[] memory initialOperational = vm_.envBool("STAKING_SLEEVE_OPERATIONAL", ",");
        bool[] memory initialPaused = vm_.envBool("STAKING_SLEEVE_LOCAL_PAUSED", ",");
        uint256[] memory principalCaps = vm_.envUint("STAKING_SLEEVE_PRINCIPAL_CAPS", ",");
        uint256[] memory initTypes = vm_.envUint("STAKING_SLEEVE_INIT_TYPES", ",");
        bytes[] memory initArgs = vm_.envBytes("STAKING_SLEEVE_INIT_ARGS", ",");
        uint256 count = implementations.length;
        require(assets.length == count, "STAKING_SLEEVE_ASSETS length mismatch");
        require(approvals.length == count, "STAKING_SLEEVE_APPROVALS length mismatch");
        require(initialOperational.length == count, "STAKING_SLEEVE_OPERATIONAL length mismatch");
        require(initialPaused.length == count, "STAKING_SLEEVE_LOCAL_PAUSED length mismatch");
        require(principalCaps.length == count, "STAKING_SLEEVE_PRINCIPAL_CAPS length mismatch");
        require(initTypes.length == count, "STAKING_SLEEVE_INIT_TYPES length mismatch");
        require(initArgs.length == count, "STAKING_SLEEVE_INIT_ARGS length mismatch");

        sleeves = new SleeveDeployerHelper.SleeveRequest[](count);
        for (uint256 i; i < count; ++i) {
            require(initTypes[i] <= uint256(SleeveDeployerHelper.InitType.Curve), "invalid Staking Sleeve init type");
            sleeves[i] = SleeveDeployerHelper.SleeveRequest({
                implementation: implementations[i],
                asset: assets[i],
                approve: approvals[i],
                initialOperational: initialOperational[i],
                initialPaused: initialPaused[i],
                principalCap: principalCaps[i],
                initType: SleeveDeployerHelper.InitType(initTypes[i]),
                initArgs: initArgs[i]
            });
        }
    }

    /// @notice Persist deployment outputs to disk for reproducibility.
    /// @param vm_ Foundry VM cheatcode handle used to serialize and write JSON.
    /// @param cfg Staking deployment configuration being serialized.
    /// @param art Deployed diamond and facet artifact addresses.
    /// @param path Output path for the staking deployment JSON file.
    /// @param sleevesPath Output path for sleeve deployment JSON artifacts.
    function writeJson(
        Vm vm_,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        string memory path,
        string memory sleevesPath
    ) internal {
        require(bytes(path).length != 0, "Staking deployment output path missing");
        require(bytes(sleevesPath).length != 0, "Staking Sleeve output path missing");
        require(art.sleeves.length != 0, "Staking Sleeve results empty");
        require(art.sleeves.length == cfg.sleeves.length, "Staking Sleeve result length mismatch");
        require(art.finalization.initializer == address(art.diamondInit), "Staking initializer identity mismatch");
        require(art.finalization.initializer.code.length != 0, "Staking initializer code missing");
        require(
            art.finalization.initializer.codehash == art.finalization.initializerCodeHash,
            "Staking initializer codehash mismatch"
        );
        require(art.finalization.initializerCalldata.length != 0, "Staking initializer calldata missing");
        require(
            LibStakingLaunch.payloadHash(art.finalization) == art.payloadHash, "Staking finalization candidate mismatch"
        );
        require(address(art.authorityInvariant).code.length != 0, "Staking authority invariant missing");
        require(address(art.sleeveInvariant).code.length != 0, "Staking Sleeve invariant missing");
        require(address(art.interfaceInit).code.length != 0, "Staking interface initializer missing");

        DeploymentHelper.requireFinalizedCandidate(cfg, art);
        FinalizedEvidence memory evidence = _requireFinalizedLaunch(vm_, cfg, art);
        CandidateEvidence memory candidateEvidence = _requireCandidateEvidence(vm_, art);
        evidence.shellInitCodeHash = DeploymentHelper.shellInitCodeHash(art);
        evidence.predictedShell = DeploymentHelper.predictedShell(cfg, art);
        requirePredictedShell(evidence.predictedShell, address(art.diamond));
        _requireScalarLaunchState(cfg, art);
        evidence.effectiveWithdrawers = _requireOrdinaryRoles(cfg, art);

        string memory label = "deploy";
        string memory out = _serializeShellEvidence(vm_, label, cfg, art, evidence);
        out = _serializeFinalizationEvidence(vm_, label, out, art);
        out = _serializeFinalizedState(vm_, label, out, art, evidence);
        out = _serializeLaunchConfiguration(vm_, label, out, cfg, art, evidence.effectiveWithdrawers);
        out = _serializeFacetEvidence(vm_, label, out, art, candidateEvidence);
        vm_.writeJson(out, path);

        SleeveArtifactWriter.writeJson(vm_, cfg, art, sleevesPath);
    }

    /// @notice Persist the exact pre-shell launch candidate produced by `DeploymentHelper.prepare`.
    /// @dev This artifact is intentionally written before shell creation. Ops independently seals its
    ///      bytes, authenticates the named contracts and source identity, and reuses the encoded candidate
    ///      for the later shell and finalization stages. It is not deployment authorization.
    function writePreparedJson(
        Vm vm_,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        string memory protocolCommit,
        string memory path
    ) internal {
        require(bytes(path).length != 0, "Staking prepared output path missing");
        require(bytes(protocolCommit).length == 40, "Staking Protocol commit must be 40 hex characters");
        require(art.finalization.initializer == address(art.diamondInit), "Staking prepared initializer mismatch");
        require(
            art.finalization.initializer.codehash == art.finalization.initializerCodeHash,
            "Staking prepared initializer codehash mismatch"
        );
        require(
            LibStakingLaunch.payloadHash(art.finalization) == art.payloadHash,
            "Staking prepared finalization candidate mismatch"
        );
        require(art.finalization.facets.length == 17, "Staking prepared facet expectation count mismatch");
        require(cfg.sleeves.length != 0, "Staking prepared Sleeves empty");

        bytes memory shellInitCode = DeploymentHelper.shellInitCode(art);
        address predictedShell = DeploymentHelper.predictedShell(cfg, art);
        require(predictedShell.code.length == 0, "Staking prepared shell already has code");

        string memory label = "prepared";
        string memory out = vm_.serializeString(label, "schemaVersion", "1.0");
        out = vm_.serializeString(label, "kind", "cybergold-staking-prepared-launch");
        out = vm_.serializeString(label, "protocolCommit", protocolCommit);
        out = vm_.serializeString(label, "compilerVersion", "0.8.38");
        out = vm_.serializeString(label, "compilerProfile", "default");
        out = vm_.serializeUint(label, "compilerOptimizerRuns", 100);
        out = vm_.serializeUint(label, "chainId", block.chainid);
        out = _serializePreparedFactoryAndShell(vm_, label, out, cfg, art, shellInitCode, predictedShell);
        out = _serializePreparedFinalization(vm_, label, out, art);
        out = _serializePreparedConfiguration(vm_, label, out, cfg);
        out = _serializePreparedFacetExpectations(vm_, label, out, art);
        out = _serializePreparedSleeves(vm_, label, out, cfg, art, predictedShell);
        vm_.writeJson(out, path);
    }

    function _serializePreparedFactoryAndShell(
        Vm vm_,
        string memory label,
        string memory out,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        bytes memory shellInitCode,
        address predictedShell
    ) private returns (string memory) {
        out = vm_.serializeAddress(label, "factory", cfg.create2Deployer);
        out = vm_.serializeBytes32(label, "factoryRuntimeCodeHash", cfg.create2Deployer.codehash);
        out = vm_.serializeString(label, "factoryCalldataPolicy", "raw-salt-concatenated-with-init-code");
        out = vm_.serializeBytes32(label, "shellSalt", cfg.shellSalt);
        out = vm_.serializeBytes(label, "shellInitCode", shellInitCode);
        out = vm_.serializeBytes32(label, "shellInitCodeHash", keccak256(shellInitCode));
        out = vm_.serializeAddress(label, "predictedShell", predictedShell);
        out = vm_.serializeBytes32(label, "expectedShellRuntimeCodeHash", keccak256(type(StakingDiamond).runtimeCode));
        out = vm_.serializeBytes32(label, "finalizerSelector", bytes32(IStakingFinalizer.finalizeStaking.selector));
        out = vm_.serializeAddress(label, "initialOwner", address(0));
        out = vm_.serializeUint(label, "initialSelectorCount", 1);
        out = vm_.serializeAddress(label, "bootstrapInit", address(art.bootstrapInit));
        out = vm_.serializeBytes32(label, "bootstrapInitRuntimeCodeHash", address(art.bootstrapInit).codehash);
        out = vm_.serializeAddress(label, "finalizerFacet", address(art.facets.finalizer));
        out = vm_.serializeBytes32(label, "finalizerFacetRuntimeCodeHash", address(art.facets.finalizer).codehash);
        return out;
    }

    function _serializePreparedFinalization(
        Vm vm_,
        string memory label,
        string memory out,
        DeploymentTypes.DeployArtifacts memory art
    ) private returns (string memory) {
        bytes memory finalizationCandidate = abi.encode(art.finalization);
        bytes memory finalizationCalldata = DeploymentHelper.finalizationCalldata(art);
        out = vm_.serializeBytes(label, "finalizationCandidate", finalizationCandidate);
        out = vm_.serializeBytes32(label, "payloadHash", art.payloadHash);
        out = vm_.serializeBytes(label, "finalizationCalldata", finalizationCalldata);
        out = vm_.serializeBytes32(label, "finalizationCalldataHash", keccak256(finalizationCalldata));
        out = vm_.serializeUint(label, "finalizationValue", 0);
        out = vm_.serializeAddress(label, "initializer", art.finalization.initializer);
        out = vm_.serializeBytes32(label, "initializerRuntimeCodeHash", art.finalization.initializerCodeHash);
        out = vm_.serializeBytes32(label, "initializerSelector", bytes32(DiamondInit.finalize.selector));
        out = vm_.serializeBytes(label, "initializerCalldata", art.finalization.initializerCalldata);
        out = vm_.serializeBytes32(label, "initializerCalldataHash", keccak256(art.finalization.initializerCalldata));
        out = vm_.serializeBytes32(label, "finalizationCutHash", keccak256(abi.encode(art.finalization.diamondCut)));
        out = vm_.serializeBytes32(
            label, "finalizationFacetExpectationsHash", keccak256(abi.encode(art.finalization.facets))
        );
        out = vm_.serializeUint(label, "finalizationCutCount", art.finalization.diamondCut.length);
        out = vm_.serializeUint(label, "finalizationFacetExpectationCount", art.finalization.facets.length);
        return out;
    }

    function _serializePreparedConfiguration(
        Vm vm_,
        string memory label,
        string memory out,
        DeploymentTypes.DeployConfig memory cfg
    ) private returns (string memory) {
        out = vm_.serializeAddress(label, "safeWallet", cfg.safeWallet);
        out = vm_.serializeAddress(label, "coreDiamond", cfg.coreDiamond);
        out = vm_.serializeAddress(label, "governanceDiamond", cfg.governanceDiamond);
        out = vm_.serializeString(label, "name", cfg.name);
        out = vm_.serializeString(label, "symbol", cfg.symbol);
        out = vm_.serializeAddress(label, "withdrawers", cfg.withdrawers);
        out = vm_.serializeAddress(label, "allocators", cfg.allocators);
        out = vm_.serializeUint(label, "claimExpiry", cfg.claimExpiry);
        out = vm_.serializeUint(label, "headSweepLimit", cfg.headSweepLimit);
        out = vm_.serializeUint(label, "autoProcessMax", cfg.autoProcessMax);
        out = vm_.serializeUint(label, "performanceFeePpm", cfg.performanceFeePpm);
        out = vm_.serializeAddress(label, "fundManagerSwapAdapter", cfg.fundManagerSwapAdapter);
        return out;
    }

    function _serializePreparedFacetExpectations(
        Vm vm_,
        string memory label,
        string memory out,
        DeploymentTypes.DeployArtifacts memory art
    ) private returns (string memory) {
        StakingLaunchTypes.FacetExpectation[] memory facets = art.finalization.facets;
        string[] memory names = _preparedFacetNames();
        address[] memory addresses = new address[](facets.length);
        bytes32[] memory runtimeCodeHashes = new bytes32[](facets.length);
        bytes32[] memory namespaces = new bytes32[](facets.length);
        uint256[] memory installedGenerations = new uint256[](facets.length);
        bool[] memory selectorBearing = new bool[](facets.length);
        for (uint256 i; i < facets.length; ++i) {
            addresses[i] = facets[i].facet;
            runtimeCodeHashes[i] = facets[i].runtimeCodeHash;
            namespaces[i] = facets[i].namespace;
            selectorBearing[i] = i < SELECTOR_BEARING_FACET_COUNT;
            installedGenerations[i] = selectorBearing[i] ? 1 : 0;
        }
        out = vm_.serializeString(label, "facetExpectationNames", names);
        out = vm_.serializeAddress(label, "facetExpectationAddresses", addresses);
        out = vm_.serializeBytes32(label, "facetExpectationRuntimeCodeHashes", runtimeCodeHashes);
        out = vm_.serializeBytes32(label, "facetExpectationNamespaces", namespaces);
        out = vm_.serializeUint(label, "facetExpectationInstalledGenerations", installedGenerations);
        out = vm_.serializeBool(label, "facetExpectationSelectorBearing", selectorBearing);
        return out;
    }

    function _serializePreparedSleeves(
        Vm vm_,
        string memory label,
        string memory out,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        address predictedShell
    ) private returns (string memory) {
        uint256 count = cfg.sleeves.length;
        PreparedSleeveEvidence memory evidence = _allocatePreparedSleeves(count);
        for (uint256 i; i < count; ++i) {
            _collectPreparedSleeve(evidence, cfg, art.payloadHash, predictedShell, i);
        }
        out = vm_.serializeUint(label, "sleeveCount", count);
        out = vm_.serializeBytes(label, "sleeveProxyCreationCode", type(SleeveProxy).creationCode);
        out = vm_.serializeBytes32(label, "sleeveProxyCreationCodeHash", keccak256(type(SleeveProxy).creationCode));
        out = vm_.serializeBytes32(label, "sleeveProxyRuntimeCodeHash", keccak256(type(SleeveProxy).runtimeCode));
        out = vm_.serializeAddress(label, "sleeveImplementations", evidence.implementations);
        out = vm_.serializeBytes32(label, "sleeveImplementationRuntimeCodeHashes", evidence.implementationHashes);
        out = vm_.serializeBytes(label, "sleeveRequestAbi", evidence.requestAbi);
        out = vm_.serializeBytes32(label, "sleeveRequestHashes", evidence.requestHashes);
        out = vm_.serializeBytes32(label, "sleeveBaseSalts", evidence.baseSalts);
        out = vm_.serializeBytes32(label, "sleeveEffectiveSalts", evidence.effectiveSalts);
        out = vm_.serializeBytes(label, "sleeveInitializerCalldata", evidence.initializerCalldata);
        out = vm_.serializeBytes32(label, "sleeveInitializerCalldataHashes", evidence.initializerCalldataHashes);
        out = vm_.serializeBytes32(label, "sleeveProxyInitCodeHashes", evidence.proxyInitCodeHashes);
        out = vm_.serializeAddress(label, "sleevePredictedAddresses", evidence.predictedProxies);
        return out;
    }

    function _allocatePreparedSleeves(uint256 count) private pure returns (PreparedSleeveEvidence memory evidence) {
        evidence.implementations = new address[](count);
        evidence.implementationHashes = new bytes32[](count);
        evidence.requestAbi = new bytes[](count);
        evidence.requestHashes = new bytes32[](count);
        evidence.baseSalts = new bytes32[](count);
        evidence.effectiveSalts = new bytes32[](count);
        evidence.initializerCalldata = new bytes[](count);
        evidence.initializerCalldataHashes = new bytes32[](count);
        evidence.proxyInitCodeHashes = new bytes32[](count);
        evidence.predictedProxies = new address[](count);
    }

    function _collectPreparedSleeve(
        PreparedSleeveEvidence memory evidence,
        DeploymentTypes.DeployConfig memory cfg,
        bytes32 payloadHash,
        address predictedShell,
        uint256 index
    ) private view {
        SleeveDeployerHelper.SleeveRequest memory request = cfg.sleeves[index];
        evidence.implementations[index] = request.implementation;
        evidence.implementationHashes[index] = request.implementation.codehash;
        evidence.requestAbi[index] = abi.encode(request);
        evidence.requestHashes[index] = keccak256(evidence.requestAbi[index]);
        evidence.baseSalts[index] = LibStakingLaunch.sleeveBaseSalt(cfg.shellSalt, index, evidence.requestHashes[index]);
        evidence.effectiveSalts[index] = LibStakingLaunch.sleeveSalt(payloadHash, evidence.baseSalts[index], index);
        evidence.initializerCalldata[index] = SleeveDeployerHelper._buildInitializer(request, predictedShell);
        evidence.initializerCalldataHashes[index] = keccak256(evidence.initializerCalldata[index]);
        bytes memory proxyInitCode = bytes.concat(
            type(SleeveProxy).creationCode, abi.encode(request.implementation, evidence.initializerCalldata[index])
        );
        evidence.proxyInitCodeHashes[index] = keccak256(proxyInitCode);
        evidence.predictedProxies[index] =
            _create2Address(predictedShell, evidence.effectiveSalts[index], evidence.proxyInitCodeHashes[index]);
    }

    function _preparedFacetNames() private pure returns (string[] memory names) {
        names = new string[](17);
        names[0] = "cutFacet";
        names[1] = "loupeFacet";
        names[2] = "accessControlFacet";
        names[3] = "pausableFacet";
        names[4] = "tokenFacet";
        names[5] = "vaultFacet";
        names[6] = "queueFacet";
        names[7] = "queueOperatorFacet";
        names[8] = "queueSigFacet";
        names[9] = "custodyFacet";
        names[10] = "sleeveRegistryFacet";
        names[11] = "fundManagerFacet";
        names[12] = "lensFacet";
        names[13] = "reentrancyFacet";
        names[14] = "authorityInvariant";
        names[15] = "sleeveInvariant";
        names[16] = "interfaceInit";
    }

    function _create2Address(address deployer, bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    function _serializeShellEvidence(
        Vm vm_,
        string memory label,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        FinalizedEvidence memory evidence
    ) private returns (string memory out) {
        out = vm_.serializeUint(label, "chainId", block.chainid);
        out = vm_.serializeAddress(label, "create2Deployer", cfg.create2Deployer);
        out = vm_.serializeBytes32(label, "shellSalt", cfg.shellSalt);
        out = vm_.serializeBytes32(label, "shellInitCodeHash", evidence.shellInitCodeHash);
        out = vm_.serializeAddress(label, "predictedShell", evidence.predictedShell);
        out = vm_.serializeAddress(label, "committedShell", address(art.diamond));
        out = vm_.serializeBytes32(
            label,
            "shellCommitment",
            LibStakingLaunch.commitmentFor(block.chainid, address(art.diamond), art.payloadHash)
        );
        out = vm_.serializeBytes32(label, "diamondRuntimeCodeHash", address(art.diamond).codehash);
        out = vm_.serializeAddress(label, "bootstrapInit", address(art.bootstrapInit));
        out = vm_.serializeBytes32(label, "bootstrapInitCodeHash", address(art.bootstrapInit).codehash);
        out = vm_.serializeAddress(label, "finalizerFacet", address(art.facets.finalizer));
        out = vm_.serializeBytes32(label, "finalizerFacetCodeHash", address(art.facets.finalizer).codehash);
        out = vm_.serializeBytes32(label, "finalizerSelector", bytes32(IStakingFinalizer.finalizeStaking.selector));
        out = vm_.serializeString(label, "finalizerPolicy", "permissionless-exact-committed-candidate");
        out = vm_.serializeBool(label, "finalizerSelectorInstalled", false);
        out = vm_.serializeAddress(label, "authorityInvariant", address(art.authorityInvariant));
        out = vm_.serializeBytes32(label, "authorityInvariantCodeHash", address(art.authorityInvariant).codehash);
        out = vm_.serializeBytes32(label, "authorityInvariantNamespace", art.authorityInvariant.FACET_NAMESPACE());
        out = vm_.serializeAddress(label, "sleeveInvariant", address(art.sleeveInvariant));
        out = vm_.serializeBytes32(label, "sleeveInvariantCodeHash", address(art.sleeveInvariant).codehash);
        out = vm_.serializeBytes32(label, "sleeveInvariantNamespace", art.sleeveInvariant.FACET_NAMESPACE());
        out = vm_.serializeAddress(label, "interfaceInit", address(art.interfaceInit));
        out = vm_.serializeBytes32(label, "interfaceInitCodeHash", address(art.interfaceInit).codehash);
        out = vm_.serializeBytes32(label, "interfaceInitNamespace", art.interfaceInit.FACET_NAMESPACE());
    }

    function _serializeFinalizationEvidence(
        Vm vm_,
        string memory label,
        string memory out,
        DeploymentTypes.DeployArtifacts memory art
    ) private returns (string memory) {
        out = vm_.serializeAddress(label, "diamondInit", address(art.diamondInit));
        out = vm_.serializeAddress(label, "initializer", art.finalization.initializer);
        out = vm_.serializeBytes32(label, "initializerCodeHash", art.finalization.initializerCodeHash);
        out = vm_.serializeBytes(label, "initializerCalldata", art.finalization.initializerCalldata);
        out = vm_.serializeBytes32(label, "initializerCalldataHash", keccak256(art.finalization.initializerCalldata));
        out = vm_.serializeBytes(label, "finalizationCandidate", abi.encode(art.finalization));
        out = vm_.serializeBytes(label, "finalizationCalldata", DeploymentHelper.finalizationCalldata(art));
        out = vm_.serializeBytes32(label, "finalizationCalldataHash", DeploymentHelper.finalizationCalldataHash(art));
        out = vm_.serializeUint(label, "finalizationValue", 0);
        out = vm_.serializeBytes32(label, "finalizationCutHash", keccak256(abi.encode(art.finalization.diamondCut)));
        out = vm_.serializeBytes32(
            label, "finalizationFacetExpectationsHash", keccak256(abi.encode(art.finalization.facets))
        );
        out = vm_.serializeUint(label, "finalizationCutCount", art.finalization.diamondCut.length);
        out = vm_.serializeUint(label, "finalizationFacetExpectationCount", art.finalization.facets.length);
        out = vm_.serializeBytes32(label, "payloadHash", art.payloadHash);
        return out;
    }

    function _serializeFinalizedState(
        Vm vm_,
        string memory label,
        string memory out,
        DeploymentTypes.DeployArtifacts memory art,
        FinalizedEvidence memory evidence
    ) private returns (string memory) {
        out = vm_.serializeBytes32(label, "finalizationHash", evidence.finalizationHash);
        out = vm_.serializeUint(label, "launchPhase", uint8(evidence.phase));
        out = vm_.serializeBool(label, "finalized", evidence.phase == LibStakingLaunch.Phase.Finalized);
        out = vm_.serializeBool(label, "paused", evidence.paused);
        out = vm_.serializeAddress(label, "diamondOwner", evidence.diamondOwner);
        out = vm_.serializeAddress(label, "bootstrapSelectorOwner", evidence.bootstrapSelectorOwner);
        out = vm_.serializeAddress(label, "ownerSelectorOwner", address(0));
        out = vm_.serializeBool(label, "erc5313Supported", false);
        out = vm_.serializeUint(label, "initialShareSupply", IERC20(address(art.diamond)).totalSupply());
        out = vm_.serializeBytes32(label, "liveCommitment", evidence.liveCommitment);
        out = vm_.serializeBytes32(label, "activePayloadHash", evidence.activePayloadHash);
        out = vm_.serializeAddress(label, "committedFinalizerFacet", evidence.committedFinalizerFacet);
        return out;
    }

    function _serializeLaunchConfiguration(
        Vm vm_,
        string memory label,
        string memory out,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        address[] memory effectiveWithdrawers
    ) private returns (string memory) {
        out = vm_.serializeAddress(label, "safeWallet", cfg.safeWallet);
        out = vm_.serializeAddress(label, "stakingDiamond", address(art.diamond));
        out = vm_.serializeAddress(label, "coreDiamond", cfg.coreDiamond);
        out = vm_.serializeAddress(label, "governanceDiamond", cfg.governanceDiamond);
        out = vm_.serializeString(label, "name", cfg.name);
        out = vm_.serializeString(label, "symbol", cfg.symbol);
        out = vm_.serializeUint(label, "claimExpiry", cfg.claimExpiry);
        out = vm_.serializeUint(label, "headSweepLimit", cfg.headSweepLimit);
        out = vm_.serializeUint(label, "autoProcessMax", cfg.autoProcessMax);
        out = vm_.serializeUint(label, "performanceFeePpm", cfg.performanceFeePpm);
        out = vm_.serializeAddress(label, "fundManagerSwapAdapter", cfg.fundManagerSwapAdapter);
        out = vm_.serializeAddress(label, "withdrawers", cfg.withdrawers);
        out = vm_.serializeAddress(label, "allocators", cfg.allocators);
        out = vm_.serializeBytes32(label, "withdrawerRole", WITHDRAWER_ROLE);
        out = vm_.serializeBytes32(label, "allocatorRole", ALLOCATOR_ROLE);
        out = vm_.serializeAddress(label, "effectiveWithdrawers", effectiveWithdrawers);
        out = vm_.serializeAddress(label, "allocatorRoleMembers", cfg.allocators);
        out = vm_.serializeUint(label, "sleeveCount", art.sleeves.length);
        return out;
    }

    function _serializeFacetEvidence(
        Vm vm_,
        string memory label,
        string memory out,
        DeploymentTypes.DeployArtifacts memory art,
        CandidateEvidence memory evidence
    ) private returns (string memory) {
        out = DeployParamsHelper.writeFacetsFromSpecs(vm_, label, _facetSpecs(art));
        out = vm_.serializeAddress(label, "facet.reentrancy", address(art.facets.reentrancy));
        out = vm_.serializeBytes32(label, "facet.reentrancyCodeHash", address(art.facets.reentrancy).codehash);
        out = vm_.serializeBytes32(label, "facet.reentrancyNamespace", art.facets.reentrancy.FACET_NAMESPACE());
        out = vm_.serializeBytes32(label, "observedSelectors", evidence.selectors);
        out = vm_.serializeAddress(label, "observedSelectorOwners", evidence.selectorOwners);
        out = vm_.serializeUint(label, "observedSelectorPositions", evidence.selectorPositions);
        out = vm_.serializeBytes32(label, "observedSelectorTopologyHash", evidence.selectorTopologyHash);
        out = vm_.serializeAddress(label, "observedFacetAddresses", evidence.facetAddresses);
        out = vm_.serializeBytes32(label, "observedFacetRuntimeCodeHashes", evidence.facetRuntimeCodeHashes);
        out = vm_.serializeBytes32(label, "observedFacetNamespaces", evidence.facetNamespaces);
        out = vm_.serializeBytes32(label, "observedFacetEvidenceHash", evidence.facetEvidenceHash);
        out = vm_.serializeUint(label, "observedInstalledFacetGenerations", evidence.initializedFacetGenerations);
        out = vm_.serializeBytes32(
            label, "observedInstalledFacetGenerationsHash", evidence.initializedFacetGenerationsHash
        );
        return out;
    }

    /// @dev Authenticate the finalized selector topology and active-generation registry from raw storage.
    /// @param vm_ Foundry VM used to read raw Diamond storage.
    /// @param art Finalized deployment artifacts whose committed candidate is being authenticated.
    /// @return evidence Exact selector, facet, code-hash, namespace, and installed-generation observations.
    function _requireCandidateEvidence(Vm vm_, DeploymentTypes.DeployArtifacts memory art)
        internal
        view
        returns (CandidateEvidence memory evidence)
    {
        FacetSpec.Entry[] memory specs = _facetSpecs(art);
        uint256 selectorCount;
        for (uint256 i; i < specs.length; ++i) {
            selectorCount += specs[i].selectors.length;
        }

        address staking = address(art.diamond);
        bytes32 selectorLengthSlot = bytes32(uint256(DIAMOND_STORAGE_POSITION) + 1);
        require(uint256(vm_.load(staking, selectorLengthSlot)) == selectorCount, "Staking raw selector count mismatch");

        evidence.selectors = new bytes32[](selectorCount);
        evidence.selectorOwners = new address[](selectorCount);
        evidence.selectorPositions = new uint256[](selectorCount);
        uint256 cursor;
        for (uint256 i; i < specs.length; ++i) {
            FacetSpec.Entry memory spec = specs[i];
            for (uint256 j; j < spec.selectors.length; ++j) {
                bytes4 selector = spec.selectors[j];
                bytes32 selectorSlot = keccak256(abi.encode(selector, DIAMOND_STORAGE_POSITION));
                uint256 observedWord = uint256(vm_.load(staking, selectorSlot));
                uint256 expectedWord = uint256(uint160(spec.facet)) | (cursor << 160);
                require(observedWord == expectedWord, "Staking raw selector topology mismatch");

                evidence.selectors[cursor] = bytes32(selector);
                // Equality with `expectedWord` above proves the low 160 bits are the expected facet address.
                // forge-lint: disable-next-line(unsafe-typecast)
                evidence.selectorOwners[cursor] = address(uint160(observedWord));
                // Diamond selector positions occupy exactly bits 160..175, and the fixed production topology
                // contains fewer than 2**16 selectors; equality with `expectedWord` proves the decoded value.
                // forge-lint: disable-next-line(unsafe-typecast)
                evidence.selectorPositions[cursor] = uint16(observedWord >> 160);
                ++cursor;
            }
        }
        _requireRawSelectorArray(vm_, staking, selectorLengthSlot, evidence.selectors);
        require(
            vm_.load(
                    staking, keccak256(abi.encode(IStakingFinalizer.finalizeStaking.selector, DIAMOND_STORAGE_POSITION))
                ) == bytes32(0),
            "Staking bootstrap selector raw state remains"
        );
        require(
            vm_.load(staking, keccak256(abi.encode(IERC5313.owner.selector, DIAMOND_STORAGE_POSITION))) == bytes32(0),
            "Staking owner selector raw state remains"
        );
        evidence.selectorTopologyHash =
            keccak256(abi.encode(evidence.selectors, evidence.selectorOwners, evidence.selectorPositions));

        uint256 facetCount = art.finalization.facets.length;
        evidence.facetAddresses = new address[](facetCount);
        evidence.facetRuntimeCodeHashes = new bytes32[](facetCount);
        evidence.facetNamespaces = new bytes32[](facetCount);
        evidence.initializedFacetGenerations = new uint256[](facetCount);
        for (uint256 i; i < facetCount; ++i) {
            address facet = art.finalization.facets[i].facet;
            bytes32 namespace = _readFacetNamespace(facet);
            bytes32 runtimeCodeHash = facet.codehash;
            require(
                runtimeCodeHash == art.finalization.facets[i].runtimeCodeHash,
                "Staking observed facet codehash mismatch"
            );
            require(
                namespace == art.finalization.facets[i].namespace,
                "Staking observed facet metadata mismatch"
            );

            bytes32 generationSlot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
            uint256 installedGeneration = uint256(vm_.load(staking, generationSlot));
            uint256 expectedInstalledGeneration = i < SELECTOR_BEARING_FACET_COUNT ? 1 : 0;
            require(
                installedGeneration == expectedInstalledGeneration,
                "Staking installed facet generation mismatch"
            );

            evidence.facetAddresses[i] = facet;
            evidence.facetRuntimeCodeHashes[i] = runtimeCodeHash;
            evidence.facetNamespaces[i] = namespace;
            evidence.initializedFacetGenerations[i] = installedGeneration;
        }
        evidence.facetEvidenceHash = keccak256(
            abi.encode(
                evidence.facetAddresses,
                evidence.facetRuntimeCodeHashes,
                evidence.facetNamespaces
            )
        );
        evidence.initializedFacetGenerationsHash =
            keccak256(abi.encode(evidence.facetNamespaces, evidence.initializedFacetGenerations));
    }

    function _requireRawSelectorArray(Vm vm_, address staking, bytes32 selectorLengthSlot, bytes32[] memory selectors)
        private
        view
    {
        bytes32 selectorDataStart = keccak256(abi.encode(selectorLengthSlot));
        for (uint256 i; i < selectors.length; i += 8) {
            uint256 expectedWord;
            uint256 remaining = selectors.length - i;
            uint256 packedCount = remaining < 8 ? remaining : 8;
            for (uint256 j; j < packedCount; ++j) {
                expectedWord |= uint256(uint32(bytes4(selectors[i + j]))) << (j * 32);
            }
            require(
                vm_.load(staking, bytes32(uint256(selectorDataStart) + i / 8)) == bytes32(expectedWord),
                "Staking raw selector array mismatch"
            );
        }
    }

    function _readFacetNamespace(address facet) private view returns (bytes32 namespace) {
        (bool namespaceOk, bytes memory namespaceData) = facet.staticcall(abi.encodeWithSignature("FACET_NAMESPACE()"));
        require(namespaceOk && namespaceData.length == 32, "Staking facet namespace probe failed");
        namespace = abi.decode(namespaceData, (bytes32));
    }

    /// @dev Authenticate launch phase, pause state, removed bootstrap surfaces, and final critical authority.
    /// @param vm_ Foundry VM used to read raw launch and Diamond storage.
    /// @param cfg Exact deployment configuration committed by the candidate.
    /// @param art Finalized deployment artifacts being authenticated.
    /// @return evidence Observed finalized launch and authority state.
    function _requireFinalizedLaunch(
        Vm vm_,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art
    ) internal view returns (FinalizedEvidence memory evidence) {
        address staking = address(art.diamond);
        require(staking.code.length != 0, "Staking deployment missing");
        (evidence.phase, evidence.finalizationHash) = LensFacet(staking).stakingLaunchState();
        require(evidence.phase == LibStakingLaunch.Phase.Finalized, "Staking launch not finalized");
        require(evidence.finalizationHash == art.payloadHash, "Staking finalization hash mismatch");
        evidence.paused = PausableFacet(staking).paused();
        require(evidence.paused, "Staking launch must remain paused");
        evidence.bootstrapSelectorOwner =
            IDiamondLoupe(staking).facetAddress(IStakingFinalizer.finalizeStaking.selector);
        require(evidence.bootstrapSelectorOwner == address(0), "Staking bootstrap selector remains");
        require(
            IDiamondLoupe(staking).facetAddress(IERC5313.owner.selector) == address(0), "Staking owner selector remains"
        );
        require(
            IDiamondLoupe(staking).facetFunctionSelectors(address(art.authorityInvariant)).length == 0,
            "Staking authority invariant installed"
        );
        require(
            IDiamondLoupe(staking).facetFunctionSelectors(address(art.sleeveInvariant)).length == 0,
            "Staking Sleeve invariant installed"
        );
        require(
            IDiamondLoupe(staking).facetFunctionSelectors(address(art.interfaceInit)).length == 0,
            "Staking interface initializer installed"
        );
        require(!IERC165(staking).supportsInterface(type(IERC5313).interfaceId), "Staking advertises IERC5313");

        require(
            vm_.load(staking, STAKING_LAUNCH_STORAGE_SLOT) == bytes32(uint256(uint8(LibStakingLaunch.Phase.Finalized))),
            "Staking raw launch phase mismatch"
        );
        evidence.liveCommitment = vm_.load(staking, bytes32(uint256(STAKING_LAUNCH_STORAGE_SLOT) + 1));
        evidence.activePayloadHash = vm_.load(staking, bytes32(uint256(STAKING_LAUNCH_STORAGE_SLOT) + 2));
        require(evidence.liveCommitment == bytes32(0), "Staking live commitment remains");
        require(evidence.activePayloadHash == bytes32(0), "Staking active payload remains");
        require(
            vm_.load(staking, bytes32(uint256(STAKING_LAUNCH_STORAGE_SLOT) + 3)) == art.payloadHash,
            "Staking raw finalization hash mismatch"
        );
        bytes32 finalizerWord = vm_.load(staking, bytes32(uint256(STAKING_LAUNCH_STORAGE_SLOT) + 4));
        require(
            finalizerWord == bytes32(uint256(uint160(address(art.facets.finalizer)))),
            "Staking committed finalizer identity mismatch"
        );
        evidence.committedFinalizerFacet = address(uint160(uint256(finalizerWord)));

        bytes32 ownerSlot = bytes32(uint256(keccak256("diamond.standard.diamond.storage")) + 3);
        bytes32 ownerWord = vm_.load(staking, ownerSlot);
        require(ownerWord == bytes32(0), "Staking diamond owner remains");
        evidence.diamondOwner = address(0);
        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(staking);
        bytes32 defaultAdminRole = access.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = access.upgraderRole();
        require(access.defaultAdmin() == cfg.governanceDiamond, "Staking Governance default admin mismatch");
        require(access.getRoleMemberCount(defaultAdminRole) == 1, "Staking default admin count mismatch");
        require(
            access.getRoleMember(defaultAdminRole, 0) == cfg.governanceDiamond, "Staking default admin member mismatch"
        );
        require(access.getRoleMemberCount(upgraderRole) == 1, "Staking upgrader count mismatch");
        require(access.getRoleMember(upgraderRole, 0) == cfg.governanceDiamond, "Staking upgrader member mismatch");
        require(access.getRoleAdmin(upgraderRole) == defaultAdminRole, "Staking upgrader admin mismatch");
        require(!access.hasRole(defaultAdminRole, cfg.safeWallet), "Staking Safe retained default admin");
        require(!access.hasRole(upgraderRole, cfg.safeWallet), "Staking Safe retained upgrader");
        require(access.defaultAdminDelay() == 0, "Staking default admin delay mismatch");
        (address pendingAdmin, uint48 pendingAdminSchedule) = access.pendingDefaultAdmin();
        require(pendingAdmin == address(0) && pendingAdminSchedule == 0, "Staking pending default admin");
        (uint48 pendingDelay, uint48 pendingDelaySchedule) = access.pendingDefaultAdminDelay();
        require(pendingDelay == 0 && pendingDelaySchedule == 0, "Staking pending admin delay");
    }

    /// @dev Authenticate all scalar token, queue, fund-manager, and system launch values.
    /// @param cfg Exact deployment configuration committed by the candidate.
    /// @param art Finalized deployment artifacts being authenticated.
    function _requireScalarLaunchState(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art
    ) internal view {
        address staking = address(art.diamond);
        require(keccak256(bytes(IERC20Metadata(staking).name())) == keccak256(bytes(cfg.name)), "Staking name mismatch");
        require(
            keccak256(bytes(IERC20Metadata(staking).symbol())) == keccak256(bytes(cfg.symbol)),
            "Staking symbol mismatch"
        );
        require(IERC20(staking).totalSupply() == 0, "Staking initial supply mismatch");
        require(LensFacet(staking).claimExpiry() == cfg.claimExpiry, "Staking claim expiry mismatch");
        require(LensFacet(staking).headSweepLimit() == cfg.headSweepLimit, "Staking head sweep mismatch");
        require(LensFacet(staking).autoProcessMax() == cfg.autoProcessMax, "Staking auto process mismatch");

        FundManagerFacet fundManager = FundManagerFacet(staking);
        require(fundManager.cygld() == cfg.coreDiamond, "Staking Core asset mismatch");
        require(fundManager.treasury() == cfg.governanceDiamond, "Staking treasury mismatch");
        require(fundManager.performanceFeePpm() == cfg.performanceFeePpm, "Staking fee mismatch");
        require(fundManager.swapAdapter() == cfg.fundManagerSwapAdapter, "Staking launch adapter mismatch");

        LensFacet.SystemState memory system = LensFacet(staking).systemState();
        require(system.asset == cfg.coreDiamond, "Staking system asset mismatch");
        require(system.paused, "Staking system pause mismatch");
        require(system.fundManagerHealthy, "Staking fund manager unhealthy");
    }

    /// @dev Authenticate ordinary role admins, members, and deterministic member ordering.
    /// @param cfg Exact deployment configuration committed by the candidate.
    /// @param art Finalized deployment artifacts being authenticated.
    /// @return effectiveWithdrawers Configured withdrawers followed by every launched Sleeve.
    function _requireOrdinaryRoles(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art)
        internal
        view
        returns (address[] memory effectiveWithdrawers)
    {
        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(address(art.diamond));
        bytes32 defaultAdminRole = access.DEFAULT_ADMIN_ROLE();
        require(access.getRoleAdmin(WITHDRAWER_ROLE) == defaultAdminRole, "Staking withdrawer admin mismatch");
        require(access.getRoleAdmin(ALLOCATOR_ROLE) == defaultAdminRole, "Staking allocator admin mismatch");

        effectiveWithdrawers = new address[](cfg.withdrawers.length + art.sleeves.length);
        for (uint256 i; i < cfg.withdrawers.length; ++i) {
            effectiveWithdrawers[i] = cfg.withdrawers[i];
        }
        for (uint256 i; i < art.sleeves.length; ++i) {
            effectiveWithdrawers[cfg.withdrawers.length + i] = art.sleeves[i].sleeve;
        }

        require(
            access.getRoleMemberCount(WITHDRAWER_ROLE) == effectiveWithdrawers.length,
            "Staking withdrawer count mismatch"
        );
        for (uint256 i; i < effectiveWithdrawers.length; ++i) {
            require(access.hasRole(WITHDRAWER_ROLE, effectiveWithdrawers[i]), "Staking withdrawer mismatch");
            require(
                access.getRoleMember(WITHDRAWER_ROLE, i) == effectiveWithdrawers[i], "Staking withdrawer order mismatch"
            );
        }

        require(access.getRoleMemberCount(ALLOCATOR_ROLE) == cfg.allocators.length, "Staking allocator count mismatch");
        for (uint256 i; i < cfg.allocators.length; ++i) {
            require(access.hasRole(ALLOCATOR_ROLE, cfg.allocators[i]), "Staking allocator mismatch");
            require(access.getRoleMember(ALLOCATOR_ROLE, i) == cfg.allocators[i], "Staking allocator order mismatch");
        }
    }

    /// @dev Require the counterfactual CREATE2 address to equal the adopted shell address.
    /// @param predicted Counterfactual address derived from factory, salt, and init code.
    /// @param observed Adopted Staking Diamond address.
    function requirePredictedShell(address predicted, address observed) internal pure {
        require(predicted == observed, "Staking shell identity mismatch");
    }

    /// @dev Return facet specs.
    /// @param art Deployment artifact addresses being serialized.
    /// @return specs Facet specification entries assembled by the helper.
    function _facetSpecs(DeploymentTypes.DeployArtifacts memory art)
        private
        pure
        returns (FacetSpec.Entry[] memory specs)
    {
        FacetSpec.Entry[] memory baseSpecs = FacetSpec.liveDefaultAdminBase(
            address(art.facets.cut),
            address(art.facets.loupe),
            address(art.facets.access),
            address(art.facets.pause),
            true
        );
        FacetSpec.Entry[] memory facetSpecs = FacetSelectors.specs(
            address(art.facets.token),
            address(art.facets.vault),
            address(art.facets.queue),
            address(art.facets.queueOperator),
            address(art.facets.queueSig),
            address(art.facets.custody),
            address(art.facets.sleeveRegistry),
            address(art.facets.fundManager),
            address(art.facets.lens)
        );
        specs = FacetSpec.concat(baseSpecs, facetSpecs);
    }
}
