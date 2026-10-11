// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DeployParams} from "../src/deploy/DeployParams.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";

contract GovernanceEnvExistsMock {
    mapping(bytes32 keyHash => bool exists) internal configured;

    function setExists(string calldata key, bool exists) external {
        configured[keccak256(bytes(key))] = exists;
    }

    function envExists(string calldata key) external view returns (bool) {
        return configured[keccak256(bytes(key))];
    }
}

contract GovernanceDeployParamsTest is Test {
    function test_legacyEnvironmentNamesAreRejected() public {
        GovernanceEnvExistsMock env = new GovernanceEnvExistsMock();

        env.setExists("GOV_PROPOSAL_THRESHOLD", true);
        vm.expectRevert(bytes("legacy GOV_PROPOSAL_THRESHOLD is forbidden"));
        this.rejectLegacyEnvironment(address(env));

        env.setExists("GOV_PROPOSAL_THRESHOLD", false);
        env.setExists("GOV_QUORUM_FRACTION", true);
        vm.expectRevert(bytes("legacy GOV_QUORUM_FRACTION is forbidden"));
        this.rejectLegacyEnvironment(address(env));

        env.setExists("GOV_QUORUM_FRACTION", false);
        this.rejectLegacyEnvironment(address(env));
    }

    function test_executionContextFailsClosedOutsideLocalDevelopment() public {
        GovernanceEnvExistsMock env = new GovernanceEnvExistsMock();
        DeployParams.Params memory params = _validParams();

        vm.chainId(10);
        vm.expectRevert(bytes("unsupported deployment chain"));
        this.validateExecutionContext(address(env), params);

        vm.chainId(31337);
        params.constructorOwner = address(0);
        vm.expectRevert(bytes("GOV_CONSTRUCTOR_OWNER must be nonzero"));
        this.validateExecutionContext(address(env), params);
        params.constructorOwner = address(0xA11CE);
        params.safeWallet = address(0);
        vm.expectRevert(bytes("DEPLOY_SAFE_WALLET must be nonzero"));
        this.validateExecutionContext(address(env), params);
        params.safeWallet = address(0x5AFE);
        params.trustedCore = address(0);
        vm.expectRevert(bytes("GOV_TRUSTED_CORE must be nonzero"));
        this.validateExecutionContext(address(env), params);
        params.trustedCore = address(0xC0);
        params.tokenInitialSupply = 1 ether;
        params.tokenTreasurySupply = 0;
        params.tokenInitialHolder = address(0);
        vm.expectRevert(bytes("CYGOV_INITIAL_HOLDER must be nonzero"));
        this.validateExecutionContext(address(env), params);

        vm.chainId(1);
        params.tokenInitialSupply = 1_000 ether;
        params.tokenTreasurySupply = 500 ether;
        params.tokenInitialHolder = address(0xBEEF);
        vm.expectRevert(bytes("mainnet GOV_CONSTRUCTOR_OWNER must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("GOV_CONSTRUCTOR_OWNER", true);
        vm.expectRevert(bytes("mainnet DEPLOY_SAFE_WALLET must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("DEPLOY_SAFE_WALLET", true);
        vm.expectRevert(bytes("mainnet GOV_TRUSTED_CORE must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("GOV_TRUSTED_CORE", true);
        vm.expectRevert(bytes("mainnet GOV_EXECUTION_DELAY must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("GOV_EXECUTION_DELAY", true);
        vm.expectRevert(bytes("mainnet GOV_EXECUTION_GRACE_PERIOD must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("GOV_EXECUTION_GRACE_PERIOD", true);
        vm.expectRevert(bytes("mainnet GOV_NAME must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("GOV_NAME", true);
        vm.expectRevert(bytes("mainnet CYGOV_SYMBOL must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("CYGOV_SYMBOL", true);
        vm.expectRevert(bytes("mainnet CYGOV_INITIAL_HOLDER must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("CYGOV_INITIAL_HOLDER", true);
        vm.expectRevert(bytes("mainnet CYGOV_INITIAL_SUPPLY must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("CYGOV_INITIAL_SUPPLY", true);
        vm.expectRevert(bytes("mainnet CYGOV_TREASURY_SUPPLY must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("CYGOV_TREASURY_SUPPLY", true);
        vm.expectRevert(bytes("mainnet GOV_VOTING_DELAY must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("GOV_VOTING_DELAY", true);
        vm.expectRevert(bytes("mainnet GOV_VOTING_PERIOD must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("GOV_VOTING_PERIOD", true);
        vm.expectRevert(bytes("mainnet GOV_PROPOSAL_THRESHOLD_NUMERATOR must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("GOV_PROPOSAL_THRESHOLD_NUMERATOR", true);
        vm.expectRevert(bytes("mainnet GOV_QUORUM_NUMERATOR must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("GOV_QUORUM_NUMERATOR", true);
        vm.expectRevert(bytes("mainnet GOV_DEPLOYMENT_CONFIG_HASH must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("GOV_DEPLOYMENT_CONFIG_HASH", true);
        vm.expectRevert(bytes("GOV_DEPLOYMENT_CONFIG_HASH does not match resolved config"));
        this.validateExecutionContext(address(env), params);
        params.sealedConfigHash = this.deploymentConfigHash(params);

        params.constructorOwner = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        vm.expectRevert(bytes("development constructor owner forbidden on mainnet"));
        this.validateExecutionContext(address(env), params);
        params.constructorOwner = address(0xA11CE);
        params.tokenInitialHolder = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        vm.expectRevert(bytes("development initial holder forbidden on mainnet"));
        this.validateExecutionContext(address(env), params);
        params.tokenInitialHolder = address(0xBEEF);
        this.validateExecutionContext(address(env), params);

        params.quorumNumerator += 1;
        vm.expectRevert(bytes("GOV_DEPLOYMENT_CONFIG_HASH does not match resolved config"));
        this.validateExecutionContext(address(env), params);
    }

    function test_executionContextRejectsGracePeriodOutsideInclusiveBounds() public {
        GovernanceEnvExistsMock env = new GovernanceEnvExistsMock();
        DeployParams.Params memory params = _validParams();

        params.executionGracePeriod = 1 days - 1;
        vm.expectRevert(bytes("GOV_EXECUTION_GRACE_PERIOD must be between 1 and 30 days"));
        this.validateExecutionContext(address(env), params);

        params.executionGracePeriod = 30 days + 1;
        vm.expectRevert(bytes("GOV_EXECUTION_GRACE_PERIOD must be between 1 and 30 days"));
        this.validateExecutionContext(address(env), params);
    }

    function test_executionContextRejectsExecutionDelayOutsideInclusiveBounds() public {
        GovernanceEnvExistsMock env = new GovernanceEnvExistsMock();
        DeployParams.Params memory params = _validParams();

        params.executionDelay = 1 days - 1;
        vm.expectRevert(bytes("GOV_EXECUTION_DELAY must be between 1 and 30 days"));
        this.validateExecutionContext(address(env), params);

        params.executionDelay = 30 days + 1;
        vm.expectRevert(bytes("GOV_EXECUTION_DELAY must be between 1 and 30 days"));
        this.validateExecutionContext(address(env), params);
    }

    function test_executionContextRejectsVotingPolicyOutsideCompiledBounds() public {
        GovernanceEnvExistsMock env = new GovernanceEnvExistsMock();
        DeployParams.Params memory params = _validParams();

        params.votingDelay = 1 days - 1;
        vm.expectRevert(bytes("GOV_VOTING_DELAY must be between 1 and 30 days"));
        this.validateExecutionContext(address(env), params);
        params.votingDelay = 1 days;
        this.validateExecutionContext(address(env), params);
        params.votingDelay = 30 days;
        this.validateExecutionContext(address(env), params);
        params.votingDelay = 30 days + 1;
        vm.expectRevert(bytes("GOV_VOTING_DELAY must be between 1 and 30 days"));
        this.validateExecutionContext(address(env), params);
        params.votingDelay = 2 days;

        params.votingPeriod = 1 days - 1;
        vm.expectRevert(bytes("GOV_VOTING_PERIOD must be between 1 and 30 days"));
        this.validateExecutionContext(address(env), params);
        params.votingPeriod = 1 days;
        this.validateExecutionContext(address(env), params);
        params.votingPeriod = 30 days;
        this.validateExecutionContext(address(env), params);
        params.votingPeriod = 30 days + 1;
        vm.expectRevert(bytes("GOV_VOTING_PERIOD must be between 1 and 30 days"));
        this.validateExecutionContext(address(env), params);
        params.votingPeriod = 5 days;

        params.proposalThresholdNumerator = 0;
        vm.expectRevert(bytes("GOV_PROPOSAL_THRESHOLD_NUMERATOR must be between 1 and 1000000000"));
        this.validateExecutionContext(address(env), params);
        params.proposalThresholdNumerator = 1;
        this.validateExecutionContext(address(env), params);
        params.proposalThresholdNumerator = 1_000_000_000;
        this.validateExecutionContext(address(env), params);
        params.proposalThresholdNumerator = 1_000_000_001;
        vm.expectRevert(bytes("GOV_PROPOSAL_THRESHOLD_NUMERATOR must be between 1 and 1000000000"));
        this.validateExecutionContext(address(env), params);
        params.proposalThresholdNumerator = 100;

        params.quorumNumerator = 0;
        vm.expectRevert(bytes("GOV_QUORUM_NUMERATOR must be between 1 and 50"));
        this.validateExecutionContext(address(env), params);
        params.quorumNumerator = 1;
        this.validateExecutionContext(address(env), params);
        params.quorumNumerator = 50;
        this.validateExecutionContext(address(env), params);
        params.quorumNumerator = 51;
        vm.expectRevert(bytes("GOV_QUORUM_NUMERATOR must be between 1 and 50"));
        this.validateExecutionContext(address(env), params);
    }

    function test_executionContextDoesNotApplyAbsoluteReachabilityGuards() public {
        GovernanceEnvExistsMock env = new GovernanceEnvExistsMock();
        DeployParams.Params memory params = _validParams();

        params.tokenInitialSupply = 1;
        params.tokenTreasurySupply = type(uint128).max;
        params.proposalThresholdNumerator = 1_000_000_000;
        params.quorumNumerator = 50;
        this.validateExecutionContext(address(env), params);

        params.tokenInitialSupply = 0;
        vm.expectRevert(bytes("CYGOV_INITIAL_SUPPLY must be nonzero"));
        this.validateExecutionContext(address(env), params);
    }

    function test_executionContextAcceptsExactVotesSafeSupplyBoundary() public {
        GovernanceEnvExistsMock env = new GovernanceEnvExistsMock();
        DeployParams.Params memory params = _validParams();

        params.tokenInitialSupply = type(uint208).max - 1;
        params.tokenTreasurySupply = 1;
        this.validateExecutionContext(address(env), params);
    }

    function test_executionContextRejectsInitialSupplyAboveVotesSafeSupply() public {
        GovernanceEnvExistsMock env = new GovernanceEnvExistsMock();
        DeployParams.Params memory params = _validParams();

        params.tokenInitialSupply = uint256(type(uint208).max) + 1;
        params.tokenTreasurySupply = 0;
        vm.expectRevert(bytes("CYGOV_TOTAL_SUPPLY exceeds ERC20Votes safe supply"));
        this.validateExecutionContext(address(env), params);
    }

    function test_executionContextRejectsCombinedSupplyAboveVotesSafeSupply() public {
        GovernanceEnvExistsMock env = new GovernanceEnvExistsMock();
        DeployParams.Params memory params = _validParams();

        params.tokenInitialSupply = type(uint208).max;
        params.tokenTreasurySupply = 1;
        vm.expectRevert(bytes("CYGOV_TOTAL_SUPPLY exceeds ERC20Votes safe supply"));
        this.validateExecutionContext(address(env), params);
    }

    function test_fromEnv_toConfig_and_writeJson() public {
        // Environment mutations are required to exercise deployment parameter parsing.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("GOV_CONSTRUCTOR_OWNER", "0x00000000000000000000000000000000000000a3");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_SAFE_WALLET", "0x000000000000000000000000000000000000005a");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("GOV_TRUSTED_CORE", "0x00000000000000000000000000000000000000c0");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("GOV_EXECUTION_DELAY", "172800");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("GOV_EXECUTION_GRACE_PERIOD", "1209600");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("GOV_NAME", "Env Governance");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CYGOV_SYMBOL", "eCYGOV");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CYGOV_INITIAL_HOLDER", "0x0000000000000000000000000000000000000044");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CYGOV_INITIAL_SUPPLY", "1000000000000000000000");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CYGOV_TREASURY_SUPPLY", "2000000000000000000000");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("GOV_VOTING_DELAY", "172800");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("GOV_VOTING_PERIOD", "432000");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("GOV_PROPOSAL_THRESHOLD_NUMERATOR", "100");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("GOV_QUORUM_NUMERATOR", "15");

        DeployParams.Params memory params = DeployParams.fromEnv(vm);
        DeploymentTypes.DeployConfig memory cfg = DeployParams.toConfig(params);

        assertTrue(cfg.constructorOwner != address(0));
        assertEq(cfg.safeWallet, address(0x5A));
        assertEq(cfg.trustedCore, address(0xC0));
        assertEq(cfg.executionDelay, 2 days);
        assertEq(cfg.executionGracePeriod, 14 days);
        assertEq(cfg.name, "Env Governance");
        assertEq(cfg.tokenSymbol, "eCYGOV");
        assertEq(cfg.tokenInitialHolder, address(0x44));
        assertEq(cfg.tokenInitialSupply, 1_000 ether);
        assertEq(cfg.tokenTreasurySupply, 2_000 ether);
        assertEq(cfg.votingDelay, 2 days);
        assertEq(cfg.votingPeriod, 5 days);
        assertEq(cfg.proposalThresholdNumerator, 100);
        assertEq(cfg.quorumNumerator, 15);

        DeploymentTypes.DeployArtifacts memory art;
        string memory outPath = DeployParamsHelper.outPath(vm, "test-deploy-governance-package.json");
        DeployParams.writeJson(vm, cfg, art, outPath);
        // The test verifies the generated deployment artifact on disk.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory written = vm.readFile(outPath);
        assertEq(vm.parseJsonAddress(written, ".constructorOwner"), cfg.constructorOwner);
        assertFalse(vm.keyExistsJson(written, ".admin"));
        assertFalse(vm.keyExistsJson(written, ".reentrancyFacet"));
        assertEq(vm.parseJsonAddress(written, ".governanceDiamond"), address(0));
        assertEq(vm.parseJsonAddress(written, ".trustedCore"), address(0xC0));
        assertEq(vm.parseJsonUint(written, ".executionDelay"), 2 days);
        assertEq(vm.parseJsonUint(written, ".executionGracePeriod"), 14 days);
        assertEq(vm.parseJsonUint(written, ".proposalThresholdNumerator"), 100);
        assertEq(vm.parseJsonUint(written, ".quorumNumerator"), 15);
        assertGt(bytes(written).length, 0);
    }

    function validateExecutionContext(address env, DeployParams.Params memory params) external view {
        DeployParams.validateExecutionContext(Vm(env), params);
    }

    function rejectLegacyEnvironment(address env) external view {
        DeployParams.rejectLegacyEnvironment(Vm(env));
    }

    function deploymentConfigHash(DeployParams.Params memory params) external view returns (bytes32) {
        return DeployParams.deploymentConfigHash(params);
    }

    function _validParams() private pure returns (DeployParams.Params memory params) {
        params.constructorOwner = address(0xA11CE);
        params.safeWallet = address(0x5AFE);
        params.trustedCore = address(0xC0);
        params.executionDelay = 2 days;
        params.executionGracePeriod = 14 days;
        params.name = "CyberGold Governance";
        params.tokenSymbol = "CYGOV";
        params.tokenInitialHolder = address(0xBEEF);
        params.tokenInitialSupply = 1_000 ether;
        params.tokenTreasurySupply = 500 ether;
        params.votingDelay = 2 days;
        params.votingPeriod = 5 days;
        params.proposalThresholdNumerator = 100;
        params.quorumNumerator = 8;
    }
}
