// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {MockStakingDiamond} from "./helpers/MockStakingDiamond.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";
import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";
import {DeployParams} from "../src/deploy/DeployParams.sol";
import {DiamondInit} from "../src/deploy/DiamondInit.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {StakingLaunchTypes, IStakingFinalizer} from "../src/deploy/StakingLaunchTypes.sol";
import {SleeveDeployerHelper} from "../src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "../src/deploy/SleeveRequestBuilder.sol";
import {SleeveCurve} from "../src/sleeves/SleeveCurve.sol";
import {SleeveManual} from "../src/sleeves/SleeveManual.sol";
import {Sleeve4626} from "../src/sleeves/Sleeve4626.sol";
import {SleeveProxy} from "../src/sleeves/SleeveProxy.sol";
import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";
import {LibStakingLaunch} from "../src/libraries/LibStakingLaunch.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {StakingInitV2} from "./helpers/StakingInitV2.sol";

contract StakingEnvExistsMock {
    bool internal safeWalletExists;

    function setSafeWalletExists(bool exists) external {
        safeWalletExists = exists;
    }

    function envExists(string calldata key) external view returns (bool) {
        return safeWalletExists && keccak256(bytes(key)) == keccak256(bytes("DEPLOY_SAFE_WALLET"));
    }
}

contract DeploymentGovernance {
    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        (bool ok, bytes memory returndata) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        return returndata;
    }
}

contract PostFinalizationProbeFacet {
    bytes32 public constant FACET_NAMESPACE =
        keccak256("cybergold.staking.test.post-finalization-probe");
    uint64 public constant FACET_VERSION = 1;

    function marker() external pure returns (uint256) {
        return 2;
    }
}

contract StakingDeployAndCustodyCoverageTest is Test {
    bytes32 private constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    uint256 private constant SELECTOR_BEARING_FACET_COUNT = 13;
    address internal admin = address(this);
    address internal stakingDiamond = address(0xF00D);
    address internal operator = address(0xCAFE);

    function testDeployParamsRequireSafeAndExplicitMainnetInput() public {
        StakingEnvExistsMock env = new StakingEnvExistsMock();
        DeployParams.Params memory params;
        vm.expectRevert(bytes("DEPLOY_SAFE_WALLET must be nonzero"));
        this.validateExecutionContext(address(env), params);

        params.safeWallet = address(0x5AFE);
        params.coreDiamond = address(0xC0);
        params.governanceDiamond = address(0xD0);
        params.create2Deployer = address(0xC2);
        params.shellSalt = bytes32(uint256(1));
        params.allocators = new address[](1);
        params.allocators[0] = address(0xA11);
        params.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        vm.chainId(31337);
        this.validateExecutionContext(address(env), params);

        vm.chainId(1);
        vm.expectRevert(bytes("mainnet DEPLOY_SAFE_WALLET must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setSafeWalletExists(true);
        this.validateExecutionContext(address(env), params);
    }

    function testDeployParamsFromEnvToConfigAndWriteJson() public {
        // Environment mutations are required to exercise deployment parameter parsing.
        vm.setEnv("DEPLOY_SAFE_WALLET", "0x00000000000000000000000000000000000005af");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_CORE_DIAMOND", "0x00000000000000000000000000000000000000c0");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("GOVERNANCE_DIAMOND", "0x00000000000000000000000000000000000000d0");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_NAME", "Env Staking");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SYMBOL", "eSTK");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_CLAIM_EXPIRY", "11");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_HEAD_SWEEP_LIMIT", "12");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_AUTO_PROCESS_MAX", "13");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_PERFORMANCE_FEE_PPM", "14000");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_FUND_MANAGER_SWAP_ADAPTER", "0x00000000000000000000000000000000000000f1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_CREATE2_DEPLOYER", "0x00000000000000000000000000000000000000c2");
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
        vm.setEnv("STAKING_SLEEVE_OPERATIONAL", "false");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SLEEVE_LOCAL_PAUSED", "true");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SLEEVE_PRINCIPAL_CAPS", "0");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SLEEVE_INIT_TYPES", "1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("STAKING_SLEEVE_INIT_ARGS", "0x000000000000000000000000000000000000000000000000000000000000cafe");

        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(
            "STAKING_WITHDRAWERS",
            "0x00000000000000000000000000000000000000e1,0x00000000000000000000000000000000000000e2"
        );
        DeployParams.Params memory params = DeployParams.fromEnv(vm);
        DeploymentTypes.DeployConfig memory cfg = DeployParams.toConfig(params);

        assertEq(cfg.safeWallet, address(0x5AF));
        assertEq(cfg.coreDiamond, address(0xC0));
        assertEq(cfg.governanceDiamond, address(0xD0));
        assertEq(cfg.create2Deployer, address(0xC2));
        assertEq(cfg.shellSalt, bytes32(uint256(1)));
        assertEq(cfg.name, "Env Staking");
        assertEq(cfg.symbol, "eSTK");
        assertEq(cfg.claimExpiry, 11);
        assertEq(cfg.headSweepLimit, 12);
        assertEq(cfg.autoProcessMax, 13);
        assertEq(cfg.performanceFeePpm, 14_000);
        assertEq(cfg.fundManagerSwapAdapter, address(0xF1));
        assertEq(cfg.withdrawers.length, 2);
        assertEq(cfg.withdrawers[1], address(0xE2));
        assertEq(cfg.allocators.length, 1);
        assertEq(cfg.sleeves.length, 1);
        assertFalse(cfg.sleeves[0].initialOperational);
        assertTrue(cfg.sleeves[0].initialPaused);

        MockERC20 launchAsset = new MockERC20("CyberGold", "CYGLD", 18);
        DeploymentGovernance governance = new DeploymentGovernance();
        DeploymentTypes.DeployConfig memory launchCfg;
        launchCfg.safeWallet = MockSafeWalletFactory.deploy(address(this));
        launchCfg.coreDiamond = address(launchAsset);
        launchCfg.governanceDiamond = address(governance);
        launchCfg.name = "Env Staking";
        launchCfg.symbol = "eSTK";
        launchCfg.withdrawers = new address[](0);
        launchCfg.allocators = new address[](1);
        launchCfg.allocators[0] = address(this);
        launchCfg.fundManagerSwapAdapter = address(0xAD);
        launchCfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        launchCfg.sleeves[0] =
            SleeveRequestBuilder.manual(address(new SleeveManual()), address(launchAsset), operator, true, 0);
        launchCfg.create2Deployer = address(this);
        launchCfg.shellSalt = keccak256("StakingDeployAndCustodyCoverageTest.writeJson");
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.prepare(launchCfg);
        string memory preparedPath = DeployParamsHelper.outPath(vm, "test-prepare-staking.json");
        DeployParams.writePreparedJson(vm, launchCfg, art, "55df1efe8c01622e77b54bff713a84e0ce834bfb", preparedPath);
        _assertPreparedEvidence(vm.readFile(preparedPath), launchCfg, art);
        art = DeploymentHelper.deployCommittedShellLocal(launchCfg, art);
        art = DeploymentHelper.finalizeCommitted(launchCfg, art);

        string memory outPath = DeployParamsHelper.outPath(vm, "test-deploy-staking.json");
        string memory sleevesPath = DeployParamsHelper.outPath(vm, "test-deploy-staking-sleeves.json");
        DeployParams.writeJson(vm, launchCfg, art, outPath, sleevesPath);

        // The test verifies the generated deployment artifacts on disk.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory written = vm.readFile(outPath);
        _assertDeploymentEvidence(written, launchCfg, art);

        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory sleeveWritten = vm.readFile(sleevesPath);
        _assertSleeveEvidence(sleeveWritten, launchCfg, art);
    }

    function testWriteJsonRejectsEmptySleeveArtifacts() public {
        DeploymentTypes.DeployConfig memory cfg;
        DeploymentTypes.DeployArtifacts memory art;
        vm.expectRevert(bytes("Staking Sleeve results empty"));
        this.writeDeploymentJson(cfg, art);
    }

    function testWritePreparedJsonRejectsInvalidEnvelope() public {
        (DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art,) =
            _preparedLaunch("prepared-empty-path");
        vm.expectRevert(bytes("Staking prepared output path missing"));
        this.writePreparedJson(cfg, art, "55df1efe8c01622e77b54bff713a84e0ce834bfb", "");

        (cfg, art,) = _preparedLaunch("prepared-bad-commit");
        vm.expectRevert(bytes("Staking Protocol commit must be 40 hex characters"));
        this.writePreparedJson(cfg, art, "short", "unused-prepared.json");

        (cfg, art,) = _preparedLaunch("prepared-initializer-mismatch");
        art.diamondInit = DiamondInit(address(1));
        vm.expectRevert(bytes("Staking prepared initializer mismatch"));
        this.writePreparedJson(cfg, art, "55df1efe8c01622e77b54bff713a84e0ce834bfb", "unused-prepared.json");

        (cfg, art,) = _preparedLaunch("prepared-initializer-codehash");
        art.finalization.initializerCodeHash = bytes32(uint256(1));
        vm.expectRevert(bytes("Staking prepared initializer codehash mismatch"));
        this.writePreparedJson(cfg, art, "55df1efe8c01622e77b54bff713a84e0ce834bfb", "unused-prepared.json");

        (cfg, art,) = _preparedLaunch("prepared-payload");
        art.payloadHash = bytes32(uint256(1));
        vm.expectRevert(bytes("Staking prepared finalization candidate mismatch"));
        this.writePreparedJson(cfg, art, "55df1efe8c01622e77b54bff713a84e0ce834bfb", "unused-prepared.json");

        (cfg, art,) = _preparedLaunch("prepared-facet-count");
        art.finalization.facets = new StakingLaunchTypes.FacetExpectation[](0);
        art.payloadHash = LibStakingLaunch.payloadHash(art.finalization);
        vm.expectRevert(bytes("Staking prepared facet expectation count mismatch"));
        this.writePreparedJson(cfg, art, "55df1efe8c01622e77b54bff713a84e0ce834bfb", "unused-prepared.json");

        (cfg, art,) = _preparedLaunch("prepared-empty-sleeves");
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](0);
        vm.expectRevert(bytes("Staking prepared Sleeves empty"));
        this.writePreparedJson(cfg, art, "55df1efe8c01622e77b54bff713a84e0ce834bfb", "unused-prepared.json");

        (cfg, art,) = _preparedLaunch("prepared-occupied-shell");
        vm.etch(DeploymentHelper.predictedShell(cfg, art), hex"00");
        vm.expectRevert(bytes("Staking prepared shell already has code"));
        this.writePreparedJson(cfg, art, "55df1efe8c01622e77b54bff713a84e0ce834bfb", "unused-prepared.json");
    }

    function testFinalizedCandidateAttestationRejectsPostFinalizationCut() public {
        (
            DeploymentTypes.DeployConfig memory cfg,
            DeploymentTypes.DeployArtifacts memory art,
            DeploymentGovernance governance
        ) = _finalizedLaunch("post-finalization-cut");

        PostFinalizationProbeFacet addedFacet = new PostFinalizationProbeFacet();
        StakingInitV2 upgradeInit = new StakingInitV2();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PostFinalizationProbeFacet.marker.selector;
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(addedFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: selectors
        });
        governance.execute(
            address(art.diamond),
            abi.encodeCall(
                IDiamondCut.diamondCut,
                (cut, address(upgradeInit), abi.encodeCall(StakingInitV2.init, (address(addedFacet))))
            )
        );

        vm.expectRevert(DeploymentHelper.StakingDeploymentTopologyMismatch.selector);
        this.finalizeCommittedResults(cfg, art);
    }

    function testFinalizedCandidateAttestationRejectsFacetCodehashDrift() public {
        (DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art,) =
            _finalizedLaunch("facet-codehash-drift");
        address facet = address(art.facets.token);
        vm.etch(facet, bytes.concat(facet.code, hex"00"));

        vm.expectRevert(DeploymentHelper.StakingDeploymentCandidateMismatch.selector);
        this.finalizeCommittedResults(cfg, art);
    }

    function testDeploymentEvidenceRejectsRawInstalledGenerationDrift() public {
        (DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art,) =
            _finalizedLaunch("version-drift");
        bytes32 namespace = art.finalization.facets[0].namespace;
        bytes32 generationSlot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
        vm.store(address(art.diamond), generationSlot, bytes32(uint256(2)));

        vm.expectRevert(bytes("Staking installed facet generation mismatch"));
        this.writeDeploymentJson(cfg, art);
    }

    function testDeploymentEvidenceRejectsRawSelectorPositionDrift() public {
        (DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art,) =
            _finalizedLaunch("selector-position-drift");
        bytes4 selector = art.finalization.diamondCut[1].functionSelectors[0];
        address owner = art.finalization.diamondCut[1].facetAddress;
        bytes32 selectorSlot = keccak256(abi.encode(selector, DIAMOND_STORAGE_POSITION));
        vm.store(address(art.diamond), selectorSlot, bytes32(uint256(uint160(owner)) | (uint256(1) << 160)));

        vm.expectRevert(bytes("Staking raw selector topology mismatch"));
        this.writeDeploymentJson(cfg, art);
    }

    function testDeploymentEvidenceRejectsRawSelectorArrayInterleaving() public {
        (DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art,) =
            _finalizedLaunch("selector-array-interleaving");
        FacetSpec.Entry[] memory specs = DeploymentHelper.facetSpecs(art);
        assertEq(specs[0].selectors.length, 2);
        assertEq(specs[1].selectors.length, 5);
        assertGt(specs[2].selectors.length, 1);

        // Preserve every facet's filtered selector order while interleaving the first
        // access selector inside the loupe group. The public loupe remains semantically
        // identical, so only raw packed-array attestation detects this corruption.
        bytes4[8] memory interleaved;
        interleaved[0] = specs[0].selectors[0];
        interleaved[1] = specs[0].selectors[1];
        interleaved[2] = specs[1].selectors[0];
        interleaved[3] = specs[2].selectors[0];
        interleaved[4] = specs[1].selectors[1];
        interleaved[5] = specs[1].selectors[2];
        interleaved[6] = specs[1].selectors[3];
        interleaved[7] = specs[1].selectors[4];
        uint256 packedWord;
        for (uint256 i; i < interleaved.length; ++i) {
            packedWord |= uint256(uint32(interleaved[i])) << (i * 32);
        }
        bytes32 selectorLengthSlot = bytes32(uint256(DIAMOND_STORAGE_POSITION) + 1);
        bytes32 selectorDataStart = keccak256(abi.encode(selectorLengthSlot));
        vm.store(address(art.diamond), selectorDataStart, bytes32(packedWord));

        vm.expectRevert(bytes("Staking raw selector array mismatch"));
        this.writeDeploymentJson(cfg, art);
    }

    function testSleeveRequestBuildersAndInitializerBranches() public {
        SleeveDeployerHelper.SleeveRequest memory basic =
            SleeveRequestBuilder.basic(address(0x100), address(0x101), true, 0);
        assertEq(
            SleeveDeployerHelper._buildInitializer(basic, stakingDiamond),
            abi.encodeWithSignature("initialize(address,address,uint256)", stakingDiamond, address(0x101), 0)
        );

        SleeveDeployerHelper.SleeveRequest memory manual =
            SleeveRequestBuilder.manual(address(0x200), address(0x201), operator, false, 7);
        assertEq(
            SleeveDeployerHelper._buildInitializer(manual, stakingDiamond),
            abi.encodeCall(SleeveManual.initialize, (stakingDiamond, address(0x201), 7, operator, true, false))
        );

        SleeveDeployerHelper.SleeveRequest memory erc4626 =
            SleeveRequestBuilder.erc4626(address(0x300), address(0x301), address(0x302), true, 0);
        assertEq(
            SleeveDeployerHelper._buildInitializer(erc4626, stakingDiamond),
            abi.encodeCall(Sleeve4626.initialize, (stakingDiamond, address(0x301), 0, address(0x302), true, false))
        );

        SleeveCurve.CurveInitParams memory curveParams = SleeveCurve.CurveInitParams({
            otherAsset: address(0x401),
            pool: address(0x402),
            underlyingIndex: 0,
            otherIndex: 1,
            otherSharePpm: 100,
            gauge: address(0),
            priceReference: 0,
            maxPriceDeviationBps: 0,
            cygldController: address(0x403),
            basketSwapAdapter: address(0x404)
        });
        SleeveDeployerHelper.SleeveRequest memory curve =
            SleeveRequestBuilder.curve(address(0x400), address(0x405), curveParams, true, 0);
        SleeveCurve.CurveLaunchParams memory curveLaunchParams = SleeveCurve.CurveLaunchParams({
            venue: curveParams, maxLpTokens: 0, rewardSwapAdapter: address(0), rewardTokens: new address[](0)
        });
        assertEq(
            SleeveDeployerHelper._buildInitializer(curve, stakingDiamond),
            abi.encodeCall(SleeveCurve.initialize, (stakingDiamond, address(0x405), 0, curveLaunchParams, true, false))
        );

        curveParams.pool = address(0);
        SleeveDeployerHelper.SleeveRequest memory invalidCurve =
            SleeveRequestBuilder.curve(address(0x400), address(0x405), curveParams, true, 0);
        vm.expectRevert(SleeveDeployerHelper.SleeveCurveConfigMissing.selector);
        this.buildInitializer(invalidCurve, stakingDiamond);
    }

    function testSleeveDeployValidatesRequestsAndAppliesPrincipalCap() public {
        MockStakingDiamond controller = new MockStakingDiamond(admin, address(0x5AFE));
        MockERC20 asset = new MockERC20("CyberGold", "CYGLD", 18);

        SleeveDeployerHelper.SleeveRequest memory invalid =
            SleeveRequestBuilder.manual(address(0), address(asset), operator, true, 0);
        vm.expectRevert(SleeveDeployerHelper.SleeveImplementationMissing.selector);
        this.deploySleeve(address(controller), invalid, bytes32(uint256(1)));

        invalid = SleeveRequestBuilder.manual(address(new SleeveManual()), address(0), operator, true, 0);
        vm.expectRevert(SleeveDeployerHelper.SleeveAssetMissing.selector);
        this.deploySleeve(address(controller), invalid, bytes32(uint256(2)));

        SleeveDeployerHelper.SleeveRequest memory req =
            SleeveRequestBuilder.manual(address(new SleeveManual()), address(asset), operator, true, 123 ether);
        bytes32 salt = keccak256("deterministic-manual-sleeve");
        address predicted = SleeveDeployerHelper.predictDeterministic(address(this), address(controller), req, salt);
        address deployed = SleeveDeployerHelper.deployDeterministic(address(controller), req, salt);

        assertEq(deployed, predicted);
        assertEq(SleeveManual(deployed).asset(), address(asset));
        assertEq(SleeveManual(deployed).principalCap(), 123 ether);
        assertEq(SleeveManual(deployed).operator(), operator);

        vm.deal(address(this), 2 wei);
        (bool receiveOk, bytes memory receiveData) = deployed.call{value: 1 wei}("");
        assertFalse(receiveOk, "Sleeve proxy accepted empty-calldata native value");
        assertEq(receiveData, abi.encodeWithSelector(SleeveProxy.SleeveNativeValueNotAccepted.selector));

        (bool fallbackOk, bytes memory fallbackData) = deployed.call{value: 1 wei}(hex"deadbeef");
        assertFalse(fallbackOk, "Sleeve proxy accepted fallback native value");
        assertEq(fallbackData, abi.encodeWithSelector(SleeveProxy.SleeveNativeValueNotAccepted.selector));
    }

    function testLibAppStoragePosition() public pure {
        assertEq(LibAppStorage.appStoragePosition(), keccak256("cybergold.staking.app.storage"));
    }

    function testDiamondInitCannotBeCalledOutsideCommittedFinalization() public {
        DiamondInit init = new DiamondInit();
        DiamondInit.InitConfig memory cfg;
        vm.expectRevert(DiamondInit.StakingInitInvalidLaunchState.selector);
        init.finalize(cfg, "Wrapped Staked CYGLD", "wstCYGLD");
    }

    function _assertPreparedEvidence(
        string memory written,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art
    ) private view {
        assertEq(vm.parseJsonString(written, ".schemaVersion"), "1.0");
        assertEq(vm.parseJsonString(written, ".kind"), "cybergold-staking-prepared-launch");
        assertEq(vm.parseJsonString(written, ".protocolCommit"), "55df1efe8c01622e77b54bff713a84e0ce834bfb");
        assertEq(vm.parseJsonString(written, ".compilerVersion"), "0.8.38");
        assertEq(vm.parseJsonString(written, ".compilerProfile"), "default");
        assertEq(vm.parseJsonUint(written, ".compilerOptimizerRuns"), 100);
        assertEq(vm.parseJsonUint(written, ".chainId"), block.chainid);
        assertEq(vm.parseJsonAddress(written, ".factory"), cfg.create2Deployer);
        assertEq(vm.parseJsonBytes32(written, ".factoryRuntimeCodeHash"), cfg.create2Deployer.codehash);
        assertEq(vm.parseJsonString(written, ".factoryCalldataPolicy"), "raw-salt-concatenated-with-init-code");
        assertEq(vm.parseJsonBytes32(written, ".shellSalt"), cfg.shellSalt);
        assertEq(vm.parseJsonBytes(written, ".shellInitCode"), DeploymentHelper.shellInitCode(art));
        assertEq(vm.parseJsonBytes32(written, ".shellInitCodeHash"), DeploymentHelper.shellInitCodeHash(art));
        assertEq(vm.parseJsonAddress(written, ".predictedShell"), DeploymentHelper.predictedShell(cfg, art));
        assertEq(vm.parseJsonAddress(written, ".initialOwner"), address(0));
        assertEq(vm.parseJsonUint(written, ".initialSelectorCount"), 1);
        assertEq(vm.parseJsonAddress(written, ".bootstrapInit"), address(art.bootstrapInit));
        assertEq(vm.parseJsonAddress(written, ".finalizerFacet"), address(art.facets.finalizer));
        assertEq(vm.parseJsonBytes(written, ".finalizationCandidate"), abi.encode(art.finalization));
        assertEq(vm.parseJsonBytes32(written, ".payloadHash"), art.payloadHash);
        assertEq(vm.parseJsonBytes(written, ".finalizationCalldata"), DeploymentHelper.finalizationCalldata(art));
        assertEq(
            vm.parseJsonBytes32(written, ".finalizationCalldataHash"), DeploymentHelper.finalizationCalldataHash(art)
        );
        assertEq(vm.parseJsonUint(written, ".finalizationValue"), 0);
        assertEq(vm.parseJsonAddress(written, ".initializer"), address(art.diamondInit));
        assertEq(vm.parseJsonBytes(written, ".initializerCalldata"), art.finalization.initializerCalldata);
        assertEq(vm.parseJsonAddress(written, ".safeWallet"), cfg.safeWallet);
        assertEq(vm.parseJsonAddress(written, ".coreDiamond"), cfg.coreDiamond);
        assertEq(vm.parseJsonAddress(written, ".governanceDiamond"), cfg.governanceDiamond);
        assertEq(vm.parseJsonAddressArray(written, ".withdrawers"), cfg.withdrawers);
        assertEq(vm.parseJsonAddressArray(written, ".allocators"), cfg.allocators);

        string[] memory names = vm.parseJsonStringArray(written, ".facetExpectationNames");
        address[] memory addresses = vm.parseJsonAddressArray(written, ".facetExpectationAddresses");
        bytes32[] memory codeHashes = vm.parseJsonBytes32Array(written, ".facetExpectationRuntimeCodeHashes");
        bytes32[] memory namespaces = vm.parseJsonBytes32Array(written, ".facetExpectationNamespaces");
        uint256[] memory generations =
            vm.parseJsonUintArray(written, ".facetExpectationInstalledGenerations");
        bool[] memory selectorBearing = vm.parseJsonBoolArray(written, ".facetExpectationSelectorBearing");
        assertEq(names.length, 17);
        assertEq(names[0], "cutFacet");
        assertEq(names[16], "interfaceInit");
        for (uint256 i; i < names.length; ++i) {
            assertEq(addresses[i], art.finalization.facets[i].facet);
            assertEq(codeHashes[i], art.finalization.facets[i].runtimeCodeHash);
            assertEq(namespaces[i], art.finalization.facets[i].namespace);
            assertEq(generations[i], i < 13 ? 1 : 0);
            assertEq(selectorBearing[i], i < 13);
        }

        assertEq(vm.parseJsonUint(written, ".sleeveCount"), cfg.sleeves.length);
        assertEq(vm.parseJsonBytes(written, ".sleeveProxyCreationCode"), type(SleeveProxy).creationCode);
        assertEq(vm.parseJsonBytes32(written, ".sleeveProxyRuntimeCodeHash"), keccak256(type(SleeveProxy).runtimeCode));
        address[] memory implementations = vm.parseJsonAddressArray(written, ".sleeveImplementations");
        bytes[] memory requests = vm.parseJsonBytesArray(written, ".sleeveRequestAbi");
        bytes32[] memory requestHashes = vm.parseJsonBytes32Array(written, ".sleeveRequestHashes");
        bytes32[] memory proxyHashes = vm.parseJsonBytes32Array(written, ".sleeveProxyInitCodeHashes");
        address[] memory predicted = vm.parseJsonAddressArray(written, ".sleevePredictedAddresses");
        assertEq(implementations[0], cfg.sleeves[0].implementation);
        assertEq(requests[0], abi.encode(cfg.sleeves[0]));
        assertEq(requestHashes[0], keccak256(requests[0]));
        assertTrue(proxyHashes[0] != bytes32(0));
        assertTrue(predicted[0] != address(0));
    }

    function _assertDeploymentEvidence(
        string memory written,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art
    ) private view {
        assertEq(vm.parseJsonUint(written, ".chainId"), block.chainid);
        assertEq(vm.parseJsonAddress(written, ".create2Deployer"), cfg.create2Deployer);
        assertEq(vm.parseJsonBytes32(written, ".shellSalt"), cfg.shellSalt);
        assertEq(vm.parseJsonBytes32(written, ".shellInitCodeHash"), DeploymentHelper.shellInitCodeHash(art));
        assertEq(vm.parseJsonAddress(written, ".predictedShell"), address(art.diamond));
        assertEq(vm.parseJsonAddress(written, ".committedShell"), address(art.diamond));
        assertEq(
            vm.parseJsonBytes32(written, ".shellCommitment"),
            LibStakingLaunch.commitmentFor(block.chainid, address(art.diamond), art.payloadHash)
        );
        assertEq(vm.parseJsonBytes32(written, ".diamondRuntimeCodeHash"), address(art.diamond).codehash);
        assertEq(vm.parseJsonAddress(written, ".bootstrapInit"), address(art.bootstrapInit));
        assertEq(vm.parseJsonBytes32(written, ".bootstrapInitCodeHash"), address(art.bootstrapInit).codehash);
        assertEq(vm.parseJsonAddress(written, ".finalizerFacet"), address(art.facets.finalizer));
        assertEq(vm.parseJsonBytes32(written, ".finalizerFacetCodeHash"), address(art.facets.finalizer).codehash);
        assertEq(
            vm.parseJsonBytes32(written, ".finalizerSelector"), bytes32(IStakingFinalizer.finalizeStaking.selector)
        );
        assertEq(vm.parseJsonString(written, ".finalizerPolicy"), "permissionless-exact-committed-candidate");
        assertFalse(vm.parseJsonBool(written, ".finalizerSelectorInstalled"));
        assertEq(vm.parseJsonAddress(written, ".authorityInvariant"), address(art.authorityInvariant));
        assertEq(vm.parseJsonBytes32(written, ".authorityInvariantCodeHash"), address(art.authorityInvariant).codehash);
        assertEq(vm.parseJsonBytes32(written, ".authorityInvariantNamespace"), art.authorityInvariant.FACET_NAMESPACE());
        assertEq(vm.parseJsonAddress(written, ".sleeveInvariant"), address(art.sleeveInvariant));
        assertEq(vm.parseJsonBytes32(written, ".sleeveInvariantCodeHash"), address(art.sleeveInvariant).codehash);
        assertEq(vm.parseJsonBytes32(written, ".sleeveInvariantNamespace"), art.sleeveInvariant.FACET_NAMESPACE());
        assertEq(vm.parseJsonAddress(written, ".interfaceInit"), address(art.interfaceInit));
        assertEq(vm.parseJsonBytes32(written, ".interfaceInitCodeHash"), address(art.interfaceInit).codehash);
        assertEq(vm.parseJsonBytes32(written, ".interfaceInitNamespace"), art.interfaceInit.FACET_NAMESPACE());
        assertEq(vm.parseJsonAddress(written, ".diamondInit"), address(art.diamondInit));
        assertEq(vm.parseJsonAddress(written, ".initializer"), art.finalization.initializer);
        assertEq(vm.parseJsonBytes32(written, ".initializerCodeHash"), art.finalization.initializerCodeHash);
        assertEq(vm.parseJsonBytes(written, ".initializerCalldata"), art.finalization.initializerCalldata);
        assertEq(
            vm.parseJsonBytes32(written, ".initializerCalldataHash"), keccak256(art.finalization.initializerCalldata)
        );
        assertEq(vm.parseJsonBytes(written, ".finalizationCandidate"), abi.encode(art.finalization));
        assertEq(vm.parseJsonBytes(written, ".finalizationCalldata"), DeploymentHelper.finalizationCalldata(art));
        assertEq(
            vm.parseJsonBytes32(written, ".finalizationCalldataHash"), DeploymentHelper.finalizationCalldataHash(art)
        );
        assertEq(vm.parseJsonUint(written, ".finalizationValue"), 0);
        assertEq(
            vm.parseJsonBytes32(written, ".finalizationCutHash"), keccak256(abi.encode(art.finalization.diamondCut))
        );
        assertEq(
            vm.parseJsonBytes32(written, ".finalizationFacetExpectationsHash"),
            keccak256(abi.encode(art.finalization.facets))
        );
        assertEq(vm.parseJsonUint(written, ".finalizationCutCount"), art.finalization.diamondCut.length);
        assertEq(vm.parseJsonUint(written, ".finalizationFacetExpectationCount"), art.finalization.facets.length);
        assertEq(vm.parseJsonBytes32(written, ".payloadHash"), art.payloadHash);
        assertEq(vm.parseJsonBytes32(written, ".finalizationHash"), art.payloadHash);
        assertEq(vm.parseJsonUint(written, ".launchPhase"), uint8(LibStakingLaunch.Phase.Finalized));
        assertTrue(vm.parseJsonBool(written, ".finalized"));
        assertTrue(vm.parseJsonBool(written, ".paused"));
        assertEq(vm.parseJsonAddress(written, ".diamondOwner"), address(0));
        assertEq(vm.parseJsonAddress(written, ".bootstrapSelectorOwner"), address(0));
        assertEq(vm.parseJsonAddress(written, ".ownerSelectorOwner"), address(0));
        assertFalse(vm.parseJsonBool(written, ".erc5313Supported"));
        assertEq(vm.parseJsonUint(written, ".initialShareSupply"), 0);
        assertEq(vm.parseJsonBytes32(written, ".liveCommitment"), bytes32(0));
        assertEq(vm.parseJsonBytes32(written, ".activePayloadHash"), bytes32(0));
        assertEq(vm.parseJsonAddress(written, ".committedFinalizerFacet"), address(art.facets.finalizer));
        assertEq(vm.parseJsonAddress(written, ".safeWallet"), cfg.safeWallet);
        assertEq(vm.parseJsonAddress(written, ".stakingDiamond"), address(art.diamond));
        assertEq(vm.parseJsonAddress(written, ".coreDiamond"), cfg.coreDiamond);
        assertEq(vm.parseJsonAddress(written, ".governanceDiamond"), cfg.governanceDiamond);
        assertEq(vm.parseJsonString(written, ".name"), cfg.name);
        assertEq(vm.parseJsonString(written, ".symbol"), cfg.symbol);
        assertEq(vm.parseJsonUint(written, ".claimExpiry"), cfg.claimExpiry);
        assertEq(vm.parseJsonUint(written, ".headSweepLimit"), cfg.headSweepLimit);
        assertEq(vm.parseJsonUint(written, ".autoProcessMax"), cfg.autoProcessMax);
        assertEq(vm.parseJsonUint(written, ".performanceFeePpm"), cfg.performanceFeePpm);
        assertEq(vm.parseJsonAddress(written, ".fundManagerSwapAdapter"), cfg.fundManagerSwapAdapter);
        assertEq(vm.parseJsonAddressArray(written, ".withdrawers"), cfg.withdrawers);
        assertEq(vm.parseJsonAddressArray(written, ".allocators"), cfg.allocators);
        assertEq(vm.parseJsonBytes32(written, ".withdrawerRole"), keccak256("WITHDRAWER_ROLE"));
        assertEq(vm.parseJsonBytes32(written, ".allocatorRole"), keccak256("ALLOCATOR_ROLE"));
        address[] memory effectiveWithdrawers = vm.parseJsonAddressArray(written, ".effectiveWithdrawers");
        assertEq(effectiveWithdrawers.length, art.sleeves.length);
        assertEq(effectiveWithdrawers[0], art.sleeves[0].sleeve);
        assertEq(vm.parseJsonAddressArray(written, ".allocatorRoleMembers"), cfg.allocators);
        assertEq(vm.parseJsonUint(written, ".sleeveCount"), art.sleeves.length);
        _assertCandidateEvidence(written, art);
        for (uint256 i; i < art.finalization.facets.length; ++i) {
            uint64 expectedInstalledGeneration = i < SELECTOR_BEARING_FACET_COUNT ? 1 : 0;
            _assertLiveFacetRegistration(
                address(art.diamond), art.finalization.facets[i].namespace, expectedInstalledGeneration
            );
        }
    }

    function _assertCandidateEvidence(string memory written, DeploymentTypes.DeployArtifacts memory art) private pure {
        FacetSpec.Entry[] memory specs = DeploymentHelper.facetSpecs(art);
        bytes32[] memory selectors = vm.parseJsonBytes32Array(written, ".observedSelectors");
        address[] memory owners = vm.parseJsonAddressArray(written, ".observedSelectorOwners");
        uint256[] memory positions = vm.parseJsonUintArray(written, ".observedSelectorPositions");
        uint256 cursor;
        for (uint256 i; i < specs.length; ++i) {
            for (uint256 j; j < specs[i].selectors.length; ++j) {
                assertEq(selectors[cursor], bytes32(specs[i].selectors[j]));
                assertEq(owners[cursor], specs[i].facet);
                assertEq(positions[cursor], cursor);
                ++cursor;
            }
        }
        assertEq(selectors.length, cursor);
        assertEq(owners.length, cursor);
        assertEq(positions.length, cursor);
        assertEq(
            vm.parseJsonBytes32(written, ".observedSelectorTopologyHash"),
            keccak256(abi.encode(selectors, owners, positions))
        );

        address[] memory facets = vm.parseJsonAddressArray(written, ".observedFacetAddresses");
        bytes32[] memory codeHashes = vm.parseJsonBytes32Array(written, ".observedFacetRuntimeCodeHashes");
        bytes32[] memory namespaces = vm.parseJsonBytes32Array(written, ".observedFacetNamespaces");
        uint256[] memory installedGenerations =
            vm.parseJsonUintArray(written, ".observedInstalledFacetGenerations");
        assertEq(facets.length, art.finalization.facets.length);
        for (uint256 i; i < facets.length; ++i) {
            assertEq(facets[i], art.finalization.facets[i].facet);
            assertEq(codeHashes[i], art.finalization.facets[i].runtimeCodeHash);
            assertEq(namespaces[i], art.finalization.facets[i].namespace);
            uint256 expectedInstalledGeneration = i < SELECTOR_BEARING_FACET_COUNT ? 1 : 0;
            assertEq(installedGenerations[i], expectedInstalledGeneration);
        }
        assertEq(
            vm.parseJsonBytes32(written, ".observedFacetEvidenceHash"),
            keccak256(abi.encode(facets, codeHashes, namespaces))
        );
        assertEq(
            vm.parseJsonBytes32(written, ".observedInstalledFacetGenerationsHash"),
            keccak256(abi.encode(namespaces, installedGenerations))
        );
    }

    function _assertLiveFacetRegistration(address target, bytes32 namespace, uint64 expectedGeneration)
        private
        view
    {
        bytes32 generationSlot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
        bytes32 legacyRuntimeHashSlot =
            keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 1)));
        bytes32 pendingFacetSlot =
            keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 2)));
        bytes32 pendingVersionSlot =
            keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 3)));
        bytes32 pendingRuntimeHashSlot =
            keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 4)));

        assertEq(uint64(uint256(vm.load(target, generationSlot))), expectedGeneration);
        assertEq(vm.load(target, legacyRuntimeHashSlot), bytes32(0));
        assertEq(vm.load(target, pendingFacetSlot), bytes32(0));
        assertEq(vm.load(target, pendingVersionSlot), bytes32(0));
        assertEq(vm.load(target, pendingRuntimeHashSlot), bytes32(0));
    }

    function _assertSleeveEvidence(
        string memory written,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art
    ) private view {
        SleeveDeployerHelper.SleeveRequest memory request = cfg.sleeves[0];
        SleeveDeployerHelper.SleeveDeployment memory result = art.sleeves[0];
        bytes32 requestHash = keccak256(abi.encode(request));
        bytes32 baseSalt = LibStakingLaunch.sleeveBaseSalt(cfg.shellSalt, 0, requestHash);
        bytes32 effectiveSalt = LibStakingLaunch.sleeveSalt(art.payloadHash, baseSalt, 0);

        assertEq(vm.parseJsonUint(written, ".chainId"), block.chainid);
        assertEq(vm.parseJsonAddress(written, ".stakingDiamond"), address(art.diamond));
        assertEq(vm.parseJsonAddress(written, ".controller"), address(art.diamond));
        assertEq(vm.parseJsonBytes32(written, ".payloadHash"), art.payloadHash);
        assertEq(
            vm.parseJsonBytes32(written, ".implementationSlot"),
            bytes32(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)
        );
        assertEq(vm.parseJsonUint(written, ".count"), 1);

        _assertSleeveIdentity(written, request, result, address(art.diamond));
        _assertSleeveConfig(written, request);
        _assertSleeveCommitments(written, request, requestHash, baseSalt, effectiveSalt, address(art.diamond));
    }

    function _assertSleeveIdentity(
        string memory written,
        SleeveDeployerHelper.SleeveRequest memory request,
        SleeveDeployerHelper.SleeveDeployment memory result,
        address controller
    ) private view {
        address[] memory addresses = vm.parseJsonAddressArray(written, ".sleeves");
        assertEq(addresses.length, 1);
        assertEq(addresses[0], result.sleeve);
        addresses = vm.parseJsonAddressArray(written, ".controllers");
        assertEq(addresses.length, 1);
        assertEq(addresses[0], controller);
        addresses = vm.parseJsonAddressArray(written, ".implementations");
        assertEq(addresses.length, 1);
        assertEq(addresses[0], request.implementation);
        addresses = vm.parseJsonAddressArray(written, ".proxyImplementations");
        assertEq(addresses.length, 1);
        assertEq(addresses[0], request.implementation);
        addresses = vm.parseJsonAddressArray(written, ".assets");
        assertEq(addresses.length, 1);
        assertEq(addresses[0], request.asset);
        addresses = vm.parseJsonAddressArray(written, ".sleeveControllers");
        assertEq(addresses.length, 1);
        assertEq(addresses[0], controller);
        addresses = vm.parseJsonAddressArray(written, ".sleeveAssets");
        assertEq(addresses.length, 1);
        assertEq(addresses[0], request.asset);

        bytes32[] memory hashes = vm.parseJsonBytes32Array(written, ".committedImplementationCodeHashes");
        assertEq(hashes.length, 1);
        assertEq(hashes[0], request.implementation.codehash);
        hashes = vm.parseJsonBytes32Array(written, ".observedImplementationCodeHashes");
        assertEq(hashes.length, 1);
        assertEq(hashes[0], request.implementation.codehash);
        hashes = vm.parseJsonBytes32Array(written, ".proxyRuntimeCodeHashes");
        assertEq(hashes.length, 1);
        assertEq(hashes[0], result.sleeve.codehash);
    }

    function _assertSleeveConfig(string memory written, SleeveDeployerHelper.SleeveRequest memory request)
        private
        pure
    {
        bool[] memory approvals = vm.parseJsonBoolArray(written, ".approvals");
        assertEq(approvals.length, 1);
        assertEq(approvals[0], request.approve);
        bool[] memory requested = vm.parseJsonBoolArray(written, ".requestedOperational");
        assertEq(requested[0], request.initialOperational);
        requested = vm.parseJsonBoolArray(written, ".requestedLocalPaused");
        assertEq(requested[0], request.initialPaused);
        uint256[] memory values = vm.parseJsonUintArray(written, ".principalCaps");
        assertEq(values.length, 1);
        assertEq(values[0], request.principalCap);
        values = vm.parseJsonUintArray(written, ".initTypes");
        assertEq(values.length, 1);
        assertEq(values[0], uint256(request.initType));
        bytes[] memory data = vm.parseJsonBytesArray(written, ".initArgs");
        assertEq(data.length, 1);
        assertEq(data[0], request.initArgs);

        bool[] memory flags = vm.parseJsonBoolArray(written, ".registryRegistered");
        assertEq(flags.length, 1);
        assertTrue(flags[0]);
        flags = vm.parseJsonBoolArray(written, ".registryApprovals");
        assertEq(flags.length, 1);
        assertEq(flags[0], request.approve);
        address[] memory assets = vm.parseJsonAddressArray(written, ".registryAssets");
        assertEq(assets.length, 1);
        assertEq(assets[0], request.asset);
        values = vm.parseJsonUintArray(written, ".registryPrincipalAssets");
        assertEq(values.length, 1);
        assertEq(values[0], 0);
        values = vm.parseJsonUintArray(written, ".sleevePrincipalAssets");
        assertEq(values.length, 1);
        assertEq(values[0], 0);
        values = vm.parseJsonUintArray(written, ".observedSleeveTotalAssets");
        assertEq(values.length, 1);
        assertEq(values[0], 0);
        flags = vm.parseJsonBoolArray(written, ".observedSleeveTotalAssetsHealthy");
        assertTrue(flags[0]);
        flags = vm.parseJsonBoolArray(written, ".sleeveOperational");
        assertEq(flags.length, 1);
        assertTrue(flags[0]);
        flags = vm.parseJsonBoolArray(written, ".sleevePaused");
        assertEq(flags.length, 1);
        assertFalse(flags[0]);
        address[] memory operators = vm.parseJsonAddressArray(written, ".manualOperators");
        assertEq(operators[0], abi.decode(request.initArgs, (address)));
    }

    function _assertSleeveCommitments(
        string memory written,
        SleeveDeployerHelper.SleeveRequest memory request,
        bytes32 requestHash,
        bytes32 baseSalt,
        bytes32 effectiveSalt,
        address controller
    ) private pure {
        bytes32[] memory hashes = vm.parseJsonBytes32Array(written, ".initArgsHashes");
        assertEq(hashes.length, 1);
        assertEq(hashes[0], keccak256(request.initArgs));
        hashes = vm.parseJsonBytes32Array(written, ".requestHashes");
        assertEq(hashes.length, 1);
        assertEq(hashes[0], requestHash);
        hashes = vm.parseJsonBytes32Array(written, ".baseSalts");
        assertEq(hashes.length, 1);
        assertEq(hashes[0], baseSalt);
        hashes = vm.parseJsonBytes32Array(written, ".effectiveSalts");
        assertEq(hashes.length, 1);
        assertEq(hashes[0], effectiveSalt);
        hashes = vm.parseJsonBytes32Array(written, ".initCalldataHashes");
        assertEq(hashes.length, 1);
        assertEq(hashes[0], keccak256(SleeveDeployerHelper._buildInitializer(request, controller)));
    }

    function _finalizedLaunch(string memory saltLabel)
        private
        returns (
            DeploymentTypes.DeployConfig memory cfg,
            DeploymentTypes.DeployArtifacts memory art,
            DeploymentGovernance governance
        )
    {
        (cfg, art, governance) = _preparedLaunch(saltLabel);
        art = DeploymentHelper.deployCommittedShellLocal(cfg, art);
        art = DeploymentHelper.finalizeCommitted(cfg, art);
    }

    function _preparedLaunch(string memory saltLabel)
        private
        returns (
            DeploymentTypes.DeployConfig memory cfg,
            DeploymentTypes.DeployArtifacts memory art,
            DeploymentGovernance governance
        )
    {
        MockERC20 launchAsset = new MockERC20("CyberGold", "CYGLD", 18);
        governance = new DeploymentGovernance();
        cfg.safeWallet = MockSafeWalletFactory.deploy(address(this));
        cfg.coreDiamond = address(launchAsset);
        cfg.governanceDiamond = address(governance);
        cfg.name = "Attested Staking";
        cfg.symbol = "aSTK";
        cfg.allocators = new address[](1);
        cfg.allocators[0] = address(this);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] =
            SleeveRequestBuilder.manual(address(new SleeveManual()), address(launchAsset), operator, true, 0);
        cfg.create2Deployer = address(this);
        cfg.shellSalt = keccak256(bytes(saltLabel));

        art = DeploymentHelper.prepare(cfg);
    }

    function finalizeCommittedResults(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art
    ) external view returns (DeploymentTypes.DeployArtifacts memory) {
        return DeploymentHelper.finalizeCommittedResults(cfg, art);
    }

    function buildInitializer(SleeveDeployerHelper.SleeveRequest memory req, address controller)
        external
        pure
        returns (bytes memory)
    {
        return SleeveDeployerHelper._buildInitializer(req, controller);
    }

    function deploySleeve(address controller, SleeveDeployerHelper.SleeveRequest memory req, bytes32 salt)
        external
        returns (address)
    {
        return SleeveDeployerHelper.deployDeterministic(controller, req, salt);
    }

    function writeDeploymentJson(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art)
        external
    {
        DeployParams.writeJson(vm, cfg, art, "unused-staking.json", "unused-staking-sleeves.json");
    }

    function writePreparedJson(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        string memory protocolCommit,
        string memory path
    ) external {
        DeployParams.writePreparedJson(vm, cfg, art, protocolCommit, path);
    }

    function validateExecutionContext(address env, DeployParams.Params memory params) external view {
        DeployParams.validateExecutionContext(Vm(env), params);
    }
}
