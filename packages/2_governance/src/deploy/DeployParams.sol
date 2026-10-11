// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";
import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";
import {FacetSelectors} from "./FacetSelectors.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {LibGovernorBounds} from "../libraries/LibGovernorBounds.sol";

/// @notice Centralized parameter builder for governance deployments.
library DeployParams {
    address internal constant ANVIL_DEFAULT_ACCOUNT = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    /// @notice Environment-derived deployment parameters.
    struct Params {
        /// @dev Temporary diamond-shell owner; never receives a runtime Governance role.
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
        bytes32 sealedConfigHash;
    }

    /// @notice Load params from environment variables used by the package script.
    /// Env vars: GOV_CONSTRUCTOR_OWNER, DEPLOY_SAFE_WALLET, GOV_TRUSTED_CORE,
    /// GOV_EXECUTION_DELAY, GOV_EXECUTION_GRACE_PERIOD,
    /// GOV_NAME, CYGOV_SYMBOL,
    /// CYGOV_INITIAL_SUPPLY, CYGOV_TREASURY_SUPPLY, GOV_VOTING_DELAY,
    /// GOV_VOTING_PERIOD, GOV_PROPOSAL_THRESHOLD_NUMERATOR, GOV_QUORUM_NUMERATOR,
    /// and GOV_DEPLOYMENT_CONFIG_HASH.
    /// Every field is explicit on mainnet; CYGOV_INITIAL_HOLDER may be zero only when initial supply is zero.
    /// @param vm_ Foundry VM cheatcode handle used to read environment variables and config defaults.
    /// @return p Deployment parameters assembled from defaults and environment overrides.
    function fromEnv(Vm vm_) internal view returns (Params memory p) {
        DeployConfig.ProtocolConfig memory defaults = DeployConfig.loadProtocol(vm_);
        p.constructorOwner =
            DeployParamsHelper.envAddressOr(vm_, DeployParamsHelper.keys1("GOV_CONSTRUCTOR_OWNER"), defaults.admin);
        p.safeWallet =
            DeployParamsHelper.envAddressOr(vm_, DeployParamsHelper.keys1("DEPLOY_SAFE_WALLET"), defaults.safeWallet);
        p.trustedCore = DeployParamsHelper.envAddressOr(vm_, DeployParamsHelper.keys1("GOV_TRUSTED_CORE"), address(0));
        p.executionDelay = DeployParamsHelper.envUintOr(
            vm_, DeployParamsHelper.keys1("GOV_EXECUTION_DELAY"), defaults.governance.executionDelay
        );
        p.executionGracePeriod = DeployParamsHelper.envUintOr(
            vm_, DeployParamsHelper.keys1("GOV_EXECUTION_GRACE_PERIOD"), defaults.governance.executionGracePeriod
        );
        p.name = DeployParamsHelper.envStringOr(vm_, DeployParamsHelper.keys1("GOV_NAME"), defaults.governance.name);
        p.tokenSymbol = DeployParamsHelper.envStringOr(
            vm_, DeployParamsHelper.keys1("CYGOV_SYMBOL"), defaults.governance.tokenSymbol
        );
        p.tokenInitialHolder = DeployParamsHelper.envAddressOr(
            vm_, DeployParamsHelper.keys1("CYGOV_INITIAL_HOLDER"), defaults.governance.tokenInitialHolder
        );
        p.tokenInitialSupply = DeployParamsHelper.envUintOr(
            vm_, DeployParamsHelper.keys1("CYGOV_INITIAL_SUPPLY"), defaults.governance.tokenInitialSupply
        );
        p.tokenTreasurySupply = DeployParamsHelper.envUintOr(
            vm_, DeployParamsHelper.keys1("CYGOV_TREASURY_SUPPLY"), defaults.governance.tokenTreasurySupply
        );
        p.votingDelay = DeployParamsHelper.envUintOr(
            vm_, DeployParamsHelper.keys1("GOV_VOTING_DELAY"), defaults.governance.votingDelay
        );
        p.votingPeriod = DeployParamsHelper.envUintOr(
            vm_, DeployParamsHelper.keys1("GOV_VOTING_PERIOD"), defaults.governance.votingPeriod
        );
        rejectLegacyEnvironment(vm_);
        p.proposalThresholdNumerator = DeployParamsHelper.envUintOr(
            vm_,
            DeployParamsHelper.keys1("GOV_PROPOSAL_THRESHOLD_NUMERATOR"),
            defaults.governance.proposalThresholdNumerator
        );
        p.quorumNumerator = DeployParamsHelper.envUintOr(
            vm_, DeployParamsHelper.keys1("GOV_QUORUM_NUMERATOR"), defaults.governance.quorumNumerator
        );
        p.sealedConfigHash = vm_.envOr("GOV_DEPLOYMENT_CONFIG_HASH", bytes32(0));
        validateExecutionContext(vm_, p);
    }

    /// @dev Reject environment names whose units belong to the superseded policy.
    function rejectLegacyEnvironment(Vm vm_) internal view {
        require(!vm_.envExists("GOV_PROPOSAL_THRESHOLD"), "legacy GOV_PROPOSAL_THRESHOLD is forbidden");
        require(!vm_.envExists("GOV_QUORUM_FRACTION"), "legacy GOV_QUORUM_FRACTION is forbidden");
    }

    /// @dev Fail closed for any direct non-local broadcast surface.
    /// @param vm_ Forge VM used to attest explicit environment variables.
    /// @param p Candidate deployment parameters to validate.
    function validateExecutionContext(Vm vm_, Params memory p) internal view {
        require(block.chainid == 1 || block.chainid == 31337, "unsupported deployment chain");
        require(p.constructorOwner != address(0), "GOV_CONSTRUCTOR_OWNER must be nonzero");
        require(p.safeWallet != address(0), "DEPLOY_SAFE_WALLET must be nonzero");
        require(p.trustedCore != address(0), "GOV_TRUSTED_CORE must be nonzero");
        require(
            p.executionDelay >= 1 days && p.executionDelay <= 30 days,
            "GOV_EXECUTION_DELAY must be between 1 and 30 days"
        );
        require(
            p.executionGracePeriod >= 1 days && p.executionGracePeriod <= 30 days,
            "GOV_EXECUTION_GRACE_PERIOD must be between 1 and 30 days"
        );
        require(
            p.votingDelay >= LibGovernorBounds.MIN_VOTING_DELAY && p.votingDelay <= LibGovernorBounds.MAX_VOTING_DELAY,
            "GOV_VOTING_DELAY must be between 1 and 30 days"
        );
        require(
            p.votingPeriod >= LibGovernorBounds.MIN_VOTING_PERIOD
                && p.votingPeriod <= LibGovernorBounds.MAX_VOTING_PERIOD,
            "GOV_VOTING_PERIOD must be between 1 and 30 days"
        );
        require(
            p.proposalThresholdNumerator >= LibGovernorBounds.MIN_PROPOSAL_THRESHOLD_NUMERATOR
                && p.proposalThresholdNumerator <= LibGovernorBounds.MAX_PROPOSAL_THRESHOLD_NUMERATOR,
            "GOV_PROPOSAL_THRESHOLD_NUMERATOR must be between 1 and 1000000000"
        );
        require(
            p.quorumNumerator >= LibGovernorBounds.MIN_QUORUM_NUMERATOR
                && p.quorumNumerator <= LibGovernorBounds.MAX_QUORUM_NUMERATOR,
            "GOV_QUORUM_NUMERATOR must be between 1 and 50"
        );
        require(p.tokenInitialSupply > 0, "CYGOV_INITIAL_SUPPLY must be nonzero");
        validateCygovSupply(p.tokenInitialSupply, p.tokenTreasurySupply);
        require(p.tokenInitialHolder != address(0), "CYGOV_INITIAL_HOLDER must be nonzero");
        if (block.chainid != 1) return;

        require(vm_.envExists("GOV_CONSTRUCTOR_OWNER"), "mainnet GOV_CONSTRUCTOR_OWNER must be explicit");
        require(vm_.envExists("DEPLOY_SAFE_WALLET"), "mainnet DEPLOY_SAFE_WALLET must be explicit");
        require(vm_.envExists("GOV_TRUSTED_CORE"), "mainnet GOV_TRUSTED_CORE must be explicit");
        require(vm_.envExists("GOV_EXECUTION_DELAY"), "mainnet GOV_EXECUTION_DELAY must be explicit");
        require(vm_.envExists("GOV_EXECUTION_GRACE_PERIOD"), "mainnet GOV_EXECUTION_GRACE_PERIOD must be explicit");
        require(vm_.envExists("GOV_NAME"), "mainnet GOV_NAME must be explicit");
        require(vm_.envExists("CYGOV_SYMBOL"), "mainnet CYGOV_SYMBOL must be explicit");
        require(vm_.envExists("CYGOV_INITIAL_HOLDER"), "mainnet CYGOV_INITIAL_HOLDER must be explicit");
        require(vm_.envExists("CYGOV_INITIAL_SUPPLY"), "mainnet CYGOV_INITIAL_SUPPLY must be explicit");
        require(vm_.envExists("CYGOV_TREASURY_SUPPLY"), "mainnet CYGOV_TREASURY_SUPPLY must be explicit");
        require(vm_.envExists("GOV_VOTING_DELAY"), "mainnet GOV_VOTING_DELAY must be explicit");
        require(vm_.envExists("GOV_VOTING_PERIOD"), "mainnet GOV_VOTING_PERIOD must be explicit");
        require(
            vm_.envExists("GOV_PROPOSAL_THRESHOLD_NUMERATOR"),
            "mainnet GOV_PROPOSAL_THRESHOLD_NUMERATOR must be explicit"
        );
        require(vm_.envExists("GOV_QUORUM_NUMERATOR"), "mainnet GOV_QUORUM_NUMERATOR must be explicit");
        require(vm_.envExists("GOV_DEPLOYMENT_CONFIG_HASH"), "mainnet GOV_DEPLOYMENT_CONFIG_HASH must be explicit");
        require(p.constructorOwner != ANVIL_DEFAULT_ACCOUNT, "development constructor owner forbidden on mainnet");
        require(
            p.tokenInitialSupply == 0 || p.tokenInitialHolder != ANVIL_DEFAULT_ACCOUNT,
            "development initial holder forbidden on mainnet"
        );
        require(
            p.sealedConfigHash == deploymentConfigHash(p), "GOV_DEPLOYMENT_CONFIG_HASH does not match resolved config"
        );
    }

    /// @notice Validate the complete launch supply against ERC20Votes' checkpoint-safe supply ceiling.
    /// @dev The subtraction form avoids overflowing while checking `initialSupply + treasurySupply`.
    /// @param initialSupply CYGOV minted to the configured external holder at launch, in token base units.
    /// @param treasurySupply CYGOV minted to the Governance diamond treasury at launch, in token base units.
    function validateCygovSupply(uint256 initialSupply, uint256 treasurySupply) internal pure {
        uint256 maximum = type(uint208).max;
        require(
            initialSupply <= maximum && treasurySupply <= maximum - initialSupply,
            "CYGOV_TOTAL_SUPPLY exceeds ERC20Votes safe supply"
        );
    }

    /// @notice Hash every resolved mainnet parameter and authority relationship.
    function deploymentConfigHash(Params memory p) internal view returns (bytes32) {
        bytes32 authoritiesHash = keccak256(abi.encode(p.constructorOwner, p.safeWallet, p.trustedCore));
        bytes32 executorHash = keccak256(abi.encode(p.executionDelay, p.executionGracePeriod));
        bytes32 tokenHash = keccak256(
            abi.encode(p.name, p.tokenSymbol, p.tokenInitialHolder, p.tokenInitialSupply, p.tokenTreasurySupply)
        );
        bytes32 votingHash =
            keccak256(abi.encode(p.votingDelay, p.votingPeriod, p.proposalThresholdNumerator, p.quorumNumerator));
        return keccak256(
            abi.encode(
                "CYBERGOLD_GOVERNANCE_DEPLOYMENT_CONFIG_V1",
                block.chainid,
                authoritiesHash,
                executorHash,
                tokenHash,
                votingHash
            )
        );
    }

    /// @dev Return to config.
    /// @param p Deployment parameter struct being loaded or serialized.
    /// @return cfg Configuration view or deployment parameters assembled by the helper.
    function toConfig(Params memory p) internal pure returns (DeploymentTypes.DeployConfig memory cfg) {
        cfg.constructorOwner = p.constructorOwner;
        cfg.safeWallet = p.safeWallet;
        cfg.trustedCore = p.trustedCore;
        cfg.executionDelay = p.executionDelay;
        cfg.executionGracePeriod = p.executionGracePeriod;
        cfg.name = p.name;
        cfg.tokenSymbol = p.tokenSymbol;
        cfg.tokenInitialHolder = p.tokenInitialHolder;
        cfg.tokenInitialSupply = p.tokenInitialSupply;
        cfg.tokenTreasurySupply = p.tokenTreasurySupply;
        cfg.votingDelay = p.votingDelay;
        cfg.votingPeriod = p.votingPeriod;
        cfg.proposalThresholdNumerator = p.proposalThresholdNumerator;
        cfg.quorumNumerator = p.quorumNumerator;
    }

    /// @notice Persist deployment outputs to disk for reproducibility.
    /// @param vm_ Foundry VM cheatcode handle used to serialize and write JSON.
    /// @param cfg Governance deployment configuration being serialized.
    /// @param art Deployed diamond and facet artifact addresses.
    /// @param path Output path for the governance deployment JSON file.
    function writeJson(
        Vm vm_,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        string memory path
    ) internal {
        string memory label = "deploy";
        string memory out = vm_.serializeUint(label, "chainId", block.chainid);
        out = vm_.serializeAddress(label, "constructorOwner", cfg.constructorOwner);
        out = vm_.serializeAddress(label, "diamondInit", address(art.diamondInit));
        out = vm_.serializeAddress(label, "safeWallet", cfg.safeWallet);
        out = vm_.serializeAddress(label, "trustedCore", cfg.trustedCore);
        out = vm_.serializeAddress(label, "governanceDiamond", address(art.diamond));
        out = vm_.serializeUint(label, "executionDelay", cfg.executionDelay);
        out = vm_.serializeUint(label, "executionGracePeriod", cfg.executionGracePeriod);
        out = vm_.serializeUint(label, "proposalThresholdNumerator", cfg.proposalThresholdNumerator);
        out = vm_.serializeUint(label, "quorumNumerator", cfg.quorumNumerator);
        FacetSpec.Entry[] memory baseSpecs = FacetSpec.liveBase(
            address(art.facets.cut),
            address(art.facets.loupe),
            address(art.facets.access),
            address(art.facets.pause),
            true
        );
        FacetSpec.Entry[] memory facetSpecs = FacetSelectors.specs(
            address(art.facets.recoveryFund),
            address(art.facets.governorCore),
            address(art.facets.token),
            address(art.facets.treasury),
            address(art.facets.governorSettings),
            address(art.facets.recoveryFundLens)
        );
        FacetSpec.Entry[] memory specs = FacetSpec.concat(baseSpecs, facetSpecs);
        out = DeployParamsHelper.writeFacetsFromSpecs(vm_, label, specs);
        vm_.writeJson(out, path);
    }
}
