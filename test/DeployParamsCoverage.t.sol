// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";
import {DeployParams as CoreDeployParams} from "packages/1_core/src/deploy/DeployParams.sol";
import {DeploymentTypes as CoreTypes} from "packages/1_core/src/deploy/DeploymentTypes.sol";
import {DiamondInit as CoreDiamondInit} from "packages/1_core/src/deploy/DiamondInit.sol";
import {CoreAuthorityInvariant} from "packages/1_core/src/deploy/CoreAuthorityInvariant.sol";
import {DeployParams as StakingDeployParams} from "packages/3_staking/src/deploy/DeployParams.sol";
import {DeploymentTypes as StakingTypes} from "packages/3_staking/src/deploy/DeploymentTypes.sol";
import {DeploymentHelper as StakingDeploymentHelper} from "packages/3_staking/src/deploy/DeploymentHelper.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "packages/3_staking/src/deploy/SleeveRequestBuilder.sol";
import {SleeveManual} from "packages/3_staking/src/sleeves/SleeveManual.sol";
import {DeployParams as GovernanceDeployParams} from "packages/2_governance/src/deploy/DeployParams.sol";
import {DeploymentTypes as GovernanceTypes} from "packages/2_governance/src/deploy/DeploymentTypes.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";

contract DeployParamsHelperHarness {
    function envAddressRequired(Vm vm_, string[] memory keys) external view returns (address) {
        return DeployParamsHelper.envAddressRequired(vm_, keys);
    }

    function envAddressOr(Vm vm_, string[] memory keys, address defaultValue) external view returns (address) {
        return DeployParamsHelper.envAddressOr(vm_, keys, defaultValue);
    }

    function envUintRequired(Vm vm_, string[] memory keys) external view returns (uint256) {
        return DeployParamsHelper.envUintRequired(vm_, keys);
    }

    function envUintOr(Vm vm_, string[] memory keys, uint256 defaultValue) external view returns (uint256) {
        return DeployParamsHelper.envUintOr(vm_, keys, defaultValue);
    }

    function envStringRequired(Vm vm_, string[] memory keys) external view returns (string memory) {
        return DeployParamsHelper.envStringRequired(vm_, keys);
    }

    function envStringOr(Vm vm_, string[] memory keys, string memory defaultValue)
        external
        view
        returns (string memory)
    {
        return DeployParamsHelper.envStringOr(vm_, keys, defaultValue);
    }

    function outDir(Vm vm_) external view returns (string memory) {
        return DeployParamsHelper.outDir(vm_);
    }

    function outPath(Vm vm_, string memory filename) external view returns (string memory) {
        return DeployParamsHelper.outPath(vm_, filename);
    }

    function writeFacets(Vm vm_, string[] memory names, address[] memory facets) external returns (string memory) {
        return DeployParamsHelper.writeFacets(vm_, "facets", names, facets);
    }

    function writeFacetsFromSpecs(Vm vm_, FacetSpec.Entry[] memory specs) external returns (string memory) {
        return DeployParamsHelper.writeFacetsFromSpecs(vm_, "specs", specs);
    }
}

contract DeployParamsCoverageTest is Test {
    DeployParamsHelperHarness internal helper;

    function setUp() public {
        helper = new DeployParamsHelperHarness();
    }

    function testDeployParamsHelperEnvFallbacksPathsAndFacetSerialization() public {
        // Environment mutations are required to exercise deployment parameter parsing and path selection.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DPH_ADDR_FALLBACK", "0x00000000000000000000000000000000000000a1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DPH_UINT_FALLBACK", "42");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DPH_STRING_FALLBACK", "configured");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_OUTPUT_DIR", "/tmp/cybergold-protocol-out");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_PROTOCOL_PATH", "/tmp/explicit-deploy-protocol.json");

        assertEq(
            helper.envAddressRequired(vm, DeployParamsHelper.keys2("DPH_ADDR_PRIMARY", "DPH_ADDR_FALLBACK")),
            address(0xA1)
        );
        assertEq(helper.envAddressOr(vm, DeployParamsHelper.keys1("DPH_ADDR_MISSING"), address(0xB2)), address(0xB2));
        assertEq(helper.envUintRequired(vm, DeployParamsHelper.keys1("DPH_UINT_FALLBACK")), 42);
        assertEq(helper.envUintOr(vm, DeployParamsHelper.keys1("DPH_UINT_MISSING"), 99), 99);
        assertEq(helper.envStringRequired(vm, DeployParamsHelper.keys1("DPH_STRING_FALLBACK")), "configured");
        assertEq(helper.envStringOr(vm, DeployParamsHelper.keys1("DPH_STRING_MISSING"), "default"), "default");
        assertEq(helper.outDir(vm), "/tmp/cybergold-protocol-out");
        assertEq(helper.outPath(vm, "deploy-protocol.json"), "/tmp/explicit-deploy-protocol.json");
        assertEq(helper.outPath(vm, "other.json"), "/tmp/cybergold-protocol-out/other.json");

        string[] memory names = new string[](2);
        names[0] = "cut";
        names[1] = "loupe";
        address[] memory facets = new address[](2);
        facets[0] = address(0xC001);
        facets[1] = address(0x1009);
        string memory facetsJson = helper.writeFacets(vm, names, facets);
        assertGt(bytes(facetsJson).length, 0);

        FacetSpec.Entry[] memory specs = new FacetSpec.Entry[](1);
        specs[0] = FacetSpec.Entry({name: "probe", facet: address(0xBEEF), selectors: new bytes4[](0)});
        string memory specsJson = helper.writeFacetsFromSpecs(vm, specs);
        assertGt(bytes(specsJson).length, 0);
    }

    function testDeployParamsHelperRequiredEnvAndFacetLengthReverts() public {
        vm.expectRevert(bytes("missing env address"));
        helper.envAddressRequired(vm, DeployParamsHelper.keys1("DPH_NEVER_SET_ADDRESS"));

        vm.expectRevert(bytes("missing env uint"));
        helper.envUintRequired(vm, DeployParamsHelper.keys1("DPH_NEVER_SET_UINT"));

        vm.expectRevert(bytes("missing env string"));
        helper.envStringRequired(vm, DeployParamsHelper.keys1("DPH_NEVER_SET_STRING"));

        string[] memory names = new string[](2);
        address[] memory facets = new address[](1);
        vm.expectRevert(bytes("facet length mismatch"));
        helper.writeFacets(vm, names, facets);
    }

    function testCoreDeployParamsFromEnvToConfigAndWriteJson() public {
        string memory basketPath = string.concat(vm.projectRoot(), "/out/test-basket-config.json");
        // File and environment cheatcodes are required to exercise deployment configuration I/O.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(
            basketPath,
            '{"assets":["0x0000000000000000000000000000000000000101","0x0000000000000000000000000000000000000102"],'
            '"targetsPpm":[600000,400000],' '"goldRefGramsFp18":[1000000000000000000,2000000000000000000],'
            '"cygldRefGramsFp18":1500000000000000000}'
        );
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_ADMIN", "0x00000000000000000000000000000000000000a1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_SAFE_WALLET", "0x00000000000000000000000000000000000005af");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_TREASURY", "0x00000000000000000000000000000000000000b1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_NAME", "Env CyberGold");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_SYMBOL", "eCYGLD");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_MAX_TOTAL_SUPPLY", "123000000000000000000");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_ISSUANCE_FEE_PPM", "111");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_REDEMPTION_FEE_PPM", "222");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_BASKET_JSON", basketPath);

        CoreDeployParams.Params memory params = CoreDeployParams.fromEnv(vm);
        CoreTypes.DeployConfig memory cfg = CoreDeployParams.toConfig(params);

        assertTrue(cfg.admin != address(0));
        assertEq(cfg.safeWallet, address(0x5AF));
        assertEq(cfg.coreTreasury, address(0xB1));
        assertEq(cfg.name, "Env CyberGold");
        assertEq(cfg.symbol, "eCYGLD");
        assertEq(cfg.basketAssets.length, 2);
        assertEq(cfg.basketAssets[0], address(0x101));
        assertEq(cfg.basketTargetsPpm[1], 400_000);
        assertEq(cfg.basketGoldRefGramsFp18[1], 2 ether);
        assertEq(cfg.cygldRefGramsFp18, 1.5 ether);
        assertEq(cfg.maxTotalSupply, 123 ether);
        assertEq(cfg.issuanceFeePpm, 111);
        assertEq(cfg.redemptionFeePpm, 222);

        CoreTypes.DeployArtifacts memory art;
        art.authorityInvariant = new CoreAuthorityInvariant();
        art.diamondInit = new CoreDiamondInit();
        string memory outPath = string.concat(vm.projectRoot(), "/out/test-deploy-core.json");
        CoreDeployParams.writeJson(vm, cfg, art, outPath);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory written = vm.readFile(outPath);
        assertEq(vm.parseJsonAddress(written, ".admin"), cfg.admin);
        assertEq(vm.parseJsonAddress(written, ".coreTreasury"), cfg.coreTreasury);
        assertEq(vm.parseJsonAddress(written, ".authorityInvariant"), address(art.authorityInvariant));
        assertEq(
            vm.parseJsonBytes32(written, ".authorityInvariantCodeHash"),
            keccak256(type(CoreAuthorityInvariant).runtimeCode)
        );
        assertEq(vm.parseJsonBytes32(written, ".diamondInitCodeHash"), keccak256(type(CoreDiamondInit).runtimeCode));
        assertFalse(vm.keyExistsJson(written, ".recoveryShareBaseUri"));
        assertFalse(vm.keyExistsJson(written, ".reentrancyFacet"));
        assertEq(vm.parseJsonUint(written, ".maxTotalSupply"), 123 ether);
    }

    function testCoreDeployParamsRejectInvalidArrayShapes() public {
        CoreDeployParams.Params memory params;
        vm.expectRevert(bytes("basket empty"));
        this.exposedCoreToConfig(params);

        params.assets = new address[](1);
        params.targetsPpm = new uint256[](0);
        params.goldRefGramsFp18 = new uint256[](1);
        vm.expectRevert(bytes("basket length mismatch"));
        this.exposedCoreToConfig(params);
    }

    function testStakingDeployParamsFromEnvToConfigAndWriteJson() public {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_SAFE_WALLET", "0x00000000000000000000000000000000000005af");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_CORE_DIAMOND", "0x00000000000000000000000000000000000000c2");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("GOVERNANCE_DIAMOND", "0x00000000000000000000000000000000000000d2");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(
            "STAKING_WITHDRAWERS",
            "0x0000000000000000000000000000000000000011,0x0000000000000000000000000000000000000022"
        );
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_NAME", "Env Staking");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SYMBOL", "eSTK");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_CLAIM_EXPIRY", "86400");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_HEAD_SWEEP_LIMIT", "7");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_AUTO_PROCESS_MAX", "8");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_PERFORMANCE_FEE_PPM", "30000");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_FUND_MANAGER_SWAP_ADAPTER", "0x00000000000000000000000000000000000000f1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_CREATE2_DEPLOYER", "0x00000000000000000000000000000000000000c3");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SHELL_SALT", "0x0000000000000000000000000000000000000000000000000000000000000001");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_ALLOCATORS", "0x00000000000000000000000000000000000000a1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SLEEVE_IMPLEMENTATIONS", "0x0000000000000000000000000000000000000501");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SLEEVE_ASSETS", "0x0000000000000000000000000000000000000502");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SLEEVE_APPROVALS", "true");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SLEEVE_OPERATIONAL", "true");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SLEEVE_LOCAL_PAUSED", "false");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SLEEVE_PRINCIPAL_CAPS", "0");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SLEEVE_INIT_TYPES", "1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SLEEVE_INIT_ARGS", "0x000000000000000000000000000000000000000000000000000000000000cafe");

        StakingDeployParams.Params memory params = StakingDeployParams.fromEnv(vm);
        StakingTypes.DeployConfig memory cfg = StakingDeployParams.toConfig(params);

        assertEq(cfg.safeWallet, address(0x5AF));
        assertEq(cfg.coreDiamond, address(0xC2));
        assertEq(cfg.governanceDiamond, address(0xD2));
        assertEq(cfg.create2Deployer, address(0xC3));
        assertEq(cfg.shellSalt, bytes32(uint256(1)));
        assertEq(cfg.withdrawers.length, 2);
        assertEq(cfg.withdrawers[1], address(0x22));
        assertEq(cfg.allocators.length, 1);
        assertEq(cfg.allocators[0], address(0xA1));
        assertEq(cfg.sleeves.length, 1);
        assertEq(cfg.name, "Env Staking");
        assertEq(cfg.symbol, "eSTK");
        assertEq(cfg.claimExpiry, 86_400);
        assertEq(cfg.headSweepLimit, 7);
        assertEq(cfg.autoProcessMax, 8);
        assertEq(cfg.performanceFeePpm, 30_000);
        assertEq(cfg.fundManagerSwapAdapter, address(0xF1));
        assertTrue(cfg.sleeves[0].initialOperational);
        assertFalse(cfg.sleeves[0].initialPaused);

        (StakingTypes.DeployConfig memory launchCfg, StakingTypes.DeployArtifacts memory art) =
            _finalizedStakingDeployment();
        string memory outPath = string.concat(vm.projectRoot(), "/out/test-deploy-staking.json");
        string memory sleevesPath = string.concat(vm.projectRoot(), "/out/test-deploy-staking-sleeves.json");
        StakingDeployParams.writeJson(vm, launchCfg, art, outPath, sleevesPath);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory written = vm.readFile(outPath);
        assertEq(vm.parseJsonAddress(written, ".stakingDiamond"), address(art.diamond));
        assertTrue(vm.parseJsonBool(written, ".finalized"));
        assertTrue(vm.parseJsonBool(written, ".paused"));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        assertGt(bytes(vm.readFile(sleevesPath)).length, 0);
    }

    function _finalizedStakingDeployment()
        private
        returns (StakingTypes.DeployConfig memory cfg, StakingTypes.DeployArtifacts memory art)
    {
        MockERC20 launchAsset = new MockERC20("CyberGold", "CYGLD", 18);
        cfg.safeWallet = MockSafeWalletFactory.deploy(address(0x5AFE));
        cfg.coreDiamond = address(launchAsset);
        cfg.governanceDiamond = address(this);
        cfg.name = "Env Staking";
        cfg.symbol = "eSTK";
        cfg.withdrawers = new address[](0);
        cfg.allocators = new address[](1);
        cfg.allocators[0] = address(this);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] =
            SleeveRequestBuilder.manual(address(new SleeveManual()), address(launchAsset), address(0xCAFE), true, 0);
        cfg.create2Deployer = address(this);
        cfg.shellSalt = keccak256("DeployParamsCoverageTest.writeJson");

        art = StakingDeploymentHelper.prepare(cfg);
        art = StakingDeploymentHelper.deployCommittedShellLocal(cfg, art);
        art = StakingDeploymentHelper.finalizeCommitted(cfg, art);
    }

    function testGovernanceDeployParamsFromEnvToConfigAndWriteJson() public {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_ADMIN", "0x00000000000000000000000000000000000000a3");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_SAFE_WALLET", "0x00000000000000000000000000000000000005af");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("GOV_TRUSTED_CORE", "0x00000000000000000000000000000000000000c3");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("GOV_EXECUTION_DELAY", "86400");
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

        GovernanceDeployParams.Params memory params = GovernanceDeployParams.fromEnv(vm);
        GovernanceTypes.DeployConfig memory cfg = GovernanceDeployParams.toConfig(params);

        assertTrue(cfg.constructorOwner != address(0));
        assertEq(cfg.safeWallet, address(0x5AF));
        assertEq(cfg.trustedCore, address(0xC3));
        assertEq(cfg.executionDelay, 1 days);
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

        GovernanceTypes.DeployArtifacts memory art;
        string memory outPath = string.concat(vm.projectRoot(), "/out/test-deploy-governance.json");
        GovernanceDeployParams.writeJson(vm, cfg, art, outPath);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory written = vm.readFile(outPath);
        assertEq(vm.parseJsonAddress(written, ".constructorOwner"), cfg.constructorOwner);
        assertFalse(vm.keyExistsJson(written, ".admin"));
        assertFalse(vm.keyExistsJson(written, ".reentrancyFacet"));
        assertEq(vm.parseJsonAddress(written, ".trustedCore"), cfg.trustedCore);
        assertEq(vm.parseJsonAddress(written, ".governanceDiamond"), address(0));
        assertEq(vm.parseJsonUint(written, ".executionDelay"), 1 days);
        assertEq(vm.parseJsonUint(written, ".executionGracePeriod"), 14 days);
        assertEq(vm.parseJsonUint(written, ".proposalThresholdNumerator"), 100);
        assertEq(vm.parseJsonUint(written, ".quorumNumerator"), 15);
    }

    function exposedCoreToConfig(CoreDeployParams.Params memory params)
        external
        pure
        returns (CoreTypes.DeployConfig memory)
    {
        return CoreDeployParams.toConfig(params);
    }
}
