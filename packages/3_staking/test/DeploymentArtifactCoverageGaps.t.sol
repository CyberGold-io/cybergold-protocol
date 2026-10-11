// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";

import {DeployParams} from "staking/deploy/DeployParams.sol";
import {DeploymentHelper} from "staking/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "staking/deploy/DeploymentTypes.sol";
import {DiamondInit} from "staking/deploy/DiamondInit.sol";
import {IStakingFinalizer, StakingLaunchTypes} from "staking/deploy/StakingLaunchTypes.sol";
import {SleeveArtifactWriter} from "staking/deploy/SleeveArtifactWriter.sol";
import {SleeveDeployerHelper} from "staking/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "staking/deploy/SleeveRequestBuilder.sol";
import {LibAppStorage} from "staking/diamond/LibAppStorage.sol";
import {FundManagerFacet} from "staking/facets/FundManagerFacet.sol";
import {LensFacet} from "staking/facets/LensFacet.sol";
import {SleeveRegistryFacet} from "staking/facets/SleeveRegistryFacet.sol";
import {LibStakingLaunch} from "staking/libraries/LibStakingLaunch.sol";
import {ISleeve} from "staking/sleeves/ISleeve.sol";
import {Sleeve4626} from "staking/sleeves/Sleeve4626.sol";
import {SleeveCurve} from "staking/sleeves/SleeveCurve.sol";
import {SleeveManual} from "staking/sleeves/SleeveManual.sol";
import {ISleeveProxy, SleeveProxy} from "staking/sleeves/SleeveProxy.sol";

import {MockCyberGold} from "staking-mocks/MockCyberGold.sol";
import {MockCygldBasketController} from "staking-mocks/MockCygldBasketController.sol";
import {MockCurveGauge, MockCurvePool} from "staking-mocks/MockCurvePool.sol";
import {MockSwapAdapter} from "staking-mocks/MockSwapAdapter.sol";
import {MockVault4626} from "staking-mocks/MockVault4626.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";

contract CoverageGovernanceExecutor {
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

contract CoverageEnvExists {
    bool internal exists;

    function setExists(bool value) external {
        exists = value;
    }

    function envExists(string calldata key) external view returns (bool) {
        return exists && keccak256(bytes(key)) == keccak256("DEPLOY_SAFE_WALLET");
    }
}

contract DeploymentArtifactCoverageGapsTest is Test {
    bytes32 private constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 private constant STAKING_LAUNCH_STORAGE_SLOT =
        0xaf998c30b6bf758887c4f7ae3b9979a4920a749d595a880ba4118393868a6f00;
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");
    bytes32 private constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    struct TypedFixture {
        DeploymentTypes.DeployConfig cfg;
        DeploymentTypes.DeployArtifacts art;
        MockCyberGold core;
        address operator;
        MockVault4626 vault;
        MockCyberGold otherAsset;
        MockCurvePool pool;
        MockCurveGauge gauge;
        MockSwapAdapter rewardAdapter;
        MockSwapAdapter basketAdapter;
        MockCygldBasketController controller;
        address rewardToken;
    }

    function testExecutionContextCoversEveryRejectedField() public {
        CoverageEnvExists env = new CoverageEnvExists();
        DeployParams.Params memory p = _validParams();

        p.safeWallet = address(0);
        vm.expectRevert(bytes("DEPLOY_SAFE_WALLET must be nonzero"));
        this.validateExecutionContext(address(env), p);
        p.safeWallet = address(0x5AFE);

        p.coreDiamond = address(0);
        vm.expectRevert(bytes("STAKING_CORE_DIAMOND must be nonzero"));
        this.validateExecutionContext(address(env), p);
        p.coreDiamond = address(0xC0);

        p.governanceDiamond = address(0);
        vm.expectRevert(bytes("GOVERNANCE_DIAMOND must be nonzero"));
        this.validateExecutionContext(address(env), p);
        p.governanceDiamond = address(0xD0);

        p.create2Deployer = address(0);
        vm.expectRevert(bytes("STAKING_CREATE2_DEPLOYER must be nonzero"));
        this.validateExecutionContext(address(env), p);
        p.create2Deployer = address(0xC2);

        p.shellSalt = bytes32(0);
        vm.expectRevert(bytes("STAKING_SHELL_SALT must be nonzero"));
        this.validateExecutionContext(address(env), p);
        p.shellSalt = bytes32(uint256(1));

        p.allocators = new address[](0);
        vm.expectRevert(bytes("STAKING_ALLOCATORS must not be empty"));
        this.validateExecutionContext(address(env), p);
        p.allocators = new address[](1);
        p.allocators[0] = address(0xA1);

        p.sleeves = new SleeveDeployerHelper.SleeveRequest[](0);
        vm.expectRevert(bytes("STAKING_SLEEVES must not be empty"));
        this.validateExecutionContext(address(env), p);
        p.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);

        vm.chainId(1);
        vm.expectRevert(bytes("mainnet DEPLOY_SAFE_WALLET must be explicit"));
        this.validateExecutionContext(address(env), p);
        env.setExists(true);
        this.validateExecutionContext(address(env), p);
    }

    function testSleeveEnvironmentCoversEveryLengthAndEnumRejection() public {
        _setCanonicalSleeveEnv();

        vm.setEnv(
            "STAKING_SLEEVE_ASSETS",
            "0x0000000000000000000000000000000000000002,0x0000000000000000000000000000000000000003"
        );
        _expectSleevesFromEnvRevert("STAKING_SLEEVE_ASSETS length mismatch");
        _setCanonicalSleeveEnv();

        vm.setEnv("STAKING_SLEEVE_APPROVALS", "true,false");
        _expectSleevesFromEnvRevert("STAKING_SLEEVE_APPROVALS length mismatch");
        _setCanonicalSleeveEnv();

        vm.setEnv("STAKING_SLEEVE_OPERATIONAL", "true,false");
        _expectSleevesFromEnvRevert("STAKING_SLEEVE_OPERATIONAL length mismatch");
        _setCanonicalSleeveEnv();

        vm.setEnv("STAKING_SLEEVE_LOCAL_PAUSED", "false,true");
        _expectSleevesFromEnvRevert("STAKING_SLEEVE_LOCAL_PAUSED length mismatch");
        _setCanonicalSleeveEnv();

        vm.setEnv("STAKING_SLEEVE_PRINCIPAL_CAPS", "0,1");
        _expectSleevesFromEnvRevert("STAKING_SLEEVE_PRINCIPAL_CAPS length mismatch");
        _setCanonicalSleeveEnv();

        vm.setEnv("STAKING_SLEEVE_INIT_TYPES", "0,1");
        _expectSleevesFromEnvRevert("STAKING_SLEEVE_INIT_TYPES length mismatch");
        _setCanonicalSleeveEnv();

        vm.setEnv("STAKING_SLEEVE_INIT_ARGS", "0x,0x0000000000000000000000000000000000000000000000000000000000000000");
        _expectSleevesFromEnvRevert("STAKING_SLEEVE_INIT_ARGS length mismatch");
        _setCanonicalSleeveEnv();

        vm.setEnv("STAKING_SLEEVE_INIT_TYPES", "4");
        _expectSleevesFromEnvRevert("invalid Staking Sleeve init type");
    }

    function testWriteJsonCoversEnvelopeRejections() public {
        DeploymentTypes.DeployConfig memory cfg = _launchConfig("write-json-envelope");
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.prepare(cfg);
        art.sleeves = new SleeveDeployerHelper.SleeveDeployment[](1);

        vm.expectRevert(bytes("Staking deployment output path missing"));
        this.writeDeploymentJson(cfg, art, "", "sleeves.json");
        vm.expectRevert(bytes("Staking Sleeve output path missing"));
        this.writeDeploymentJson(cfg, art, "deploy.json", "");

        DeploymentTypes.DeployArtifacts memory bad = _cloneArtifacts(art);
        bad.sleeves = new SleeveDeployerHelper.SleeveDeployment[](0);
        vm.expectRevert(bytes("Staking Sleeve results empty"));
        this.writeDeploymentJson(cfg, bad, "deploy.json", "sleeves.json");

        DeploymentTypes.DeployConfig memory badCfg = _cloneConfig(cfg);
        badCfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](2);
        vm.expectRevert(bytes("Staking Sleeve result length mismatch"));
        this.writeDeploymentJson(badCfg, art, "deploy.json", "sleeves.json");

        bad = _cloneArtifacts(art);
        bad.finalization.initializer = address(0xBAD1);
        vm.expectRevert(bytes("Staking initializer identity mismatch"));
        this.writeDeploymentJson(cfg, bad, "deploy.json", "sleeves.json");

        bad = _cloneArtifacts(art);
        bad.diamondInit = DiamondInit(address(0xBAD2));
        bad.finalization.initializer = address(0xBAD2);
        vm.expectRevert(bytes("Staking initializer code missing"));
        this.writeDeploymentJson(cfg, bad, "deploy.json", "sleeves.json");

        bad = _cloneArtifacts(art);
        bad.finalization.initializerCodeHash = bytes32(uint256(1));
        vm.expectRevert(bytes("Staking initializer codehash mismatch"));
        this.writeDeploymentJson(cfg, bad, "deploy.json", "sleeves.json");

        bad = _cloneArtifacts(art);
        bad.finalization.initializerCalldata = bytes("");
        vm.expectRevert(bytes("Staking initializer calldata missing"));
        this.writeDeploymentJson(cfg, bad, "deploy.json", "sleeves.json");

        bad = _cloneArtifacts(art);
        bad.payloadHash = bytes32(uint256(1));
        vm.expectRevert(bytes("Staking finalization candidate mismatch"));
        this.writeDeploymentJson(cfg, bad, "deploy.json", "sleeves.json");

        bad = _cloneArtifacts(art);
        delete bad.authorityInvariant;
        vm.expectRevert(bytes("Staking authority invariant missing"));
        this.writeDeploymentJson(cfg, bad, "deploy.json", "sleeves.json");

        bad = _cloneArtifacts(art);
        delete bad.sleeveInvariant;
        vm.expectRevert(bytes("Staking Sleeve invariant missing"));
        this.writeDeploymentJson(cfg, bad, "deploy.json", "sleeves.json");

        bad = _cloneArtifacts(art);
        delete bad.interfaceInit;
        vm.expectRevert(bytes("Staking interface initializer missing"));
        this.writeDeploymentJson(cfg, bad, "deploy.json", "sleeves.json");

        vm.expectRevert(bytes("Staking shell identity mismatch"));
        this.requirePredictedShell(address(1), address(2));
    }

    function testDeployParamsCandidateEvidenceRejections() public {
        (DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art,) =
            _finalizedLaunch("candidate-evidence");
        cfg;
        address staking = address(art.diamond);
        bytes32 selectorLengthSlot = bytes32(uint256(DIAMOND_STORAGE_POSITION) + 1);
        uint256 snapshot = vm.snapshotState();

        vm.store(staking, selectorLengthSlot, bytes32(uint256(vm.load(staking, selectorLengthSlot)) + 1));
        _expectCandidateRevert(art, "Staking raw selector count mismatch");
        vm.revertToState(snapshot);

        bytes4 selector = DeploymentHelper.facetSpecs(art)[0].selectors[0];
        bytes32 selectorSlot = keccak256(abi.encode(selector, DIAMOND_STORAGE_POSITION));
        vm.store(staking, selectorSlot, bytes32(uint256(1)));
        _expectCandidateRevert(art, "Staking raw selector topology mismatch");
        vm.revertToState(snapshot);

        bytes32 selectorDataStart = keccak256(abi.encode(selectorLengthSlot));
        vm.store(staking, selectorDataStart, bytes32(uint256(vm.load(staking, selectorDataStart)) ^ 1));
        _expectCandidateRevert(art, "Staking raw selector array mismatch");
        vm.revertToState(snapshot);

        bytes32 bootstrapSlot =
            keccak256(abi.encode(IStakingFinalizer.finalizeStaking.selector, DIAMOND_STORAGE_POSITION));
        vm.store(staking, bootstrapSlot, bytes32(uint256(1)));
        _expectCandidateRevert(art, "Staking bootstrap selector raw state remains");
        vm.revertToState(snapshot);

        bytes32 ownerSelectorSlot = keccak256(abi.encode(IERC5313.owner.selector, DIAMOND_STORAGE_POSITION));
        vm.store(staking, ownerSelectorSlot, bytes32(uint256(1)));
        _expectCandidateRevert(art, "Staking owner selector raw state remains");
        vm.revertToState(snapshot);

        DeploymentTypes.DeployArtifacts memory bad = _cloneArtifacts(art);
        bad.finalization.facets[0].runtimeCodeHash = bytes32(uint256(1));
        _expectCandidateRevert(bad, "Staking observed facet codehash mismatch");

        bad = _cloneArtifacts(art);
        bad.finalization.facets[0].namespace = bytes32(uint256(1));
        _expectCandidateRevert(bad, "Staking observed facet metadata mismatch");

        bytes32 generationSlot =
            keccak256(abi.encode(art.finalization.facets[0].namespace, FACET_VERSION_REGISTRY_SLOT));
        vm.store(staking, generationSlot, bytes32(uint256(999)));
        _expectCandidateRevert(art, "Staking installed facet generation mismatch");
        vm.revertToState(snapshot);

        bad = _cloneArtifacts(art);
        bad.finalization.facets[0].facet = address(0xBEEF);
        _expectCandidateRevert(bad, "Staking facet namespace probe failed");
    }

    function testDeployParamsFinalizedLaunchRejections() public {
        (DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art,) =
            _finalizedLaunch("finalized-evidence");
        address staking = address(art.diamond);
        bytes memory launchCall = abi.encodeCall(LensFacet.stakingLaunchState, ());

        DeploymentTypes.DeployArtifacts memory bad = _cloneArtifacts(art);
        delete bad.diamond;
        _expectFinalizedRevert(cfg, bad, "Staking deployment missing");

        vm.mockCall(staking, launchCall, abi.encode(LibStakingLaunch.Phase.Committed, art.payloadHash));
        _expectFinalizedRevert(cfg, art, "Staking launch not finalized");
        vm.clearMockedCalls();

        vm.mockCall(staking, launchCall, abi.encode(LibStakingLaunch.Phase.Finalized, bytes32(uint256(1))));
        _expectFinalizedRevert(cfg, art, "Staking finalization hash mismatch");
        vm.clearMockedCalls();

        _mock(staking, abi.encodeWithSignature("paused()"), abi.encode(false));
        _expectFinalizedRevert(cfg, art, "Staking launch must remain paused");
        vm.clearMockedCalls();

        _mock(
            staking,
            abi.encodeCall(IDiamondLoupe.facetAddress, (IStakingFinalizer.finalizeStaking.selector)),
            abi.encode(address(1))
        );
        _expectFinalizedRevert(cfg, art, "Staking bootstrap selector remains");
        vm.clearMockedCalls();

        _mock(staking, abi.encodeCall(IDiamondLoupe.facetAddress, (IERC5313.owner.selector)), abi.encode(address(1)));
        _expectFinalizedRevert(cfg, art, "Staking owner selector remains");
        vm.clearMockedCalls();

        bytes4[] memory oneSelector = new bytes4[](1);
        oneSelector[0] = bytes4(uint32(1));
        _mock(
            staking,
            abi.encodeCall(IDiamondLoupe.facetFunctionSelectors, (address(art.authorityInvariant))),
            abi.encode(oneSelector)
        );
        _expectFinalizedRevert(cfg, art, "Staking authority invariant installed");
        vm.clearMockedCalls();

        _mock(
            staking,
            abi.encodeCall(IDiamondLoupe.facetFunctionSelectors, (address(art.sleeveInvariant))),
            abi.encode(oneSelector)
        );
        _expectFinalizedRevert(cfg, art, "Staking Sleeve invariant installed");
        vm.clearMockedCalls();

        _mock(
            staking,
            abi.encodeCall(IDiamondLoupe.facetFunctionSelectors, (address(art.interfaceInit))),
            abi.encode(oneSelector)
        );
        _expectFinalizedRevert(cfg, art, "Staking interface initializer installed");
        vm.clearMockedCalls();

        _mock(staking, abi.encodeCall(IERC165.supportsInterface, (type(IERC5313).interfaceId)), abi.encode(true));
        _expectFinalizedRevert(cfg, art, "Staking advertises IERC5313");
        vm.clearMockedCalls();

        uint256 snapshot = vm.snapshotState();
        vm.store(staking, STAKING_LAUNCH_STORAGE_SLOT, bytes32(uint256(uint8(LibStakingLaunch.Phase.Committed))));
        vm.mockCall(staking, launchCall, abi.encode(LibStakingLaunch.Phase.Finalized, art.payloadHash));
        _expectFinalizedRevert(cfg, art, "Staking raw launch phase mismatch");
        vm.clearMockedCalls();
        vm.revertToState(snapshot);

        vm.store(staking, bytes32(uint256(STAKING_LAUNCH_STORAGE_SLOT) + 1), bytes32(uint256(1)));
        _expectFinalizedRevert(cfg, art, "Staking live commitment remains");
        vm.revertToState(snapshot);

        vm.store(staking, bytes32(uint256(STAKING_LAUNCH_STORAGE_SLOT) + 2), bytes32(uint256(1)));
        _expectFinalizedRevert(cfg, art, "Staking active payload remains");
        vm.revertToState(snapshot);

        vm.store(staking, bytes32(uint256(STAKING_LAUNCH_STORAGE_SLOT) + 3), bytes32(uint256(1)));
        vm.mockCall(staking, launchCall, abi.encode(LibStakingLaunch.Phase.Finalized, art.payloadHash));
        _expectFinalizedRevert(cfg, art, "Staking raw finalization hash mismatch");
        vm.clearMockedCalls();
        vm.revertToState(snapshot);

        vm.store(staking, bytes32(uint256(STAKING_LAUNCH_STORAGE_SLOT) + 4), bytes32(uint256(1)));
        _expectFinalizedRevert(cfg, art, "Staking committed finalizer identity mismatch");
        vm.revertToState(snapshot);

        bytes32 ownerSlot = bytes32(uint256(keccak256("diamond.standard.diamond.storage")) + 3);
        vm.store(staking, ownerSlot, bytes32(uint256(1)));
        _expectFinalizedRevert(cfg, art, "Staking diamond owner remains");
        vm.revertToState(snapshot);

        _exerciseCriticalAuthorityFailures(cfg, art);
    }

    function testDeployParamsScalarAndOrdinaryRoleRejections() public {
        (DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art,) =
            _finalizedLaunch("scalar-role-evidence");
        address staking = address(art.diamond);

        _mock(staking, abi.encodeCall(IERC20Metadata.name, ()), abi.encode("wrong"));
        _expectScalarRevert(cfg, art, "Staking name mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeCall(IERC20Metadata.symbol, ()), abi.encode("wrong"));
        _expectScalarRevert(cfg, art, "Staking symbol mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeCall(IERC20.totalSupply, ()), abi.encode(uint256(1)));
        _expectScalarRevert(cfg, art, "Staking initial supply mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeCall(LensFacet.claimExpiry, ()), abi.encode(cfg.claimExpiry + 1));
        _expectScalarRevert(cfg, art, "Staking claim expiry mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeCall(LensFacet.headSweepLimit, ()), abi.encode(cfg.headSweepLimit + 1));
        _expectScalarRevert(cfg, art, "Staking head sweep mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeCall(LensFacet.autoProcessMax, ()), abi.encode(cfg.autoProcessMax + 1));
        _expectScalarRevert(cfg, art, "Staking auto process mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeCall(FundManagerFacet.cygld, ()), abi.encode(address(1)));
        _expectScalarRevert(cfg, art, "Staking Core asset mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeCall(FundManagerFacet.treasury, ()), abi.encode(address(1)));
        _expectScalarRevert(cfg, art, "Staking treasury mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeCall(FundManagerFacet.performanceFeePpm, ()), abi.encode(cfg.performanceFeePpm + 1));
        _expectScalarRevert(cfg, art, "Staking fee mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeCall(FundManagerFacet.swapAdapter, ()), abi.encode(address(1)));
        _expectScalarRevert(cfg, art, "Staking launch adapter mismatch");
        vm.clearMockedCalls();

        LensFacet.SystemState memory system = LensFacet(staking).systemState();
        LensFacet.SystemState memory badSystem = abi.decode(abi.encode(system), (LensFacet.SystemState));
        badSystem.asset = address(1);
        _mock(staking, abi.encodeCall(LensFacet.systemState, ()), abi.encode(badSystem));
        _expectScalarRevert(cfg, art, "Staking system asset mismatch");
        vm.clearMockedCalls();
        badSystem = abi.decode(abi.encode(system), (LensFacet.SystemState));
        badSystem.paused = false;
        _mock(staking, abi.encodeCall(LensFacet.systemState, ()), abi.encode(badSystem));
        _expectScalarRevert(cfg, art, "Staking system pause mismatch");
        vm.clearMockedCalls();
        badSystem = abi.decode(abi.encode(system), (LensFacet.SystemState));
        badSystem.fundManagerHealthy = false;
        _mock(staking, abi.encodeCall(LensFacet.systemState, ()), abi.encode(badSystem));
        _expectScalarRevert(cfg, art, "Staking fund manager unhealthy");
        vm.clearMockedCalls();

        _exerciseOrdinaryRoleFailures(cfg, art);
        address[] memory effective = this.requireOrdinaryRoles(cfg, art);
        assertEq(effective.length, 2);
        assertEq(effective[0], cfg.withdrawers[0]);
        assertEq(effective[1], art.sleeves[0].sleeve);
    }

    function testDeploymentHelperCoversInjectableFailurePostconditions() public {
        DeploymentTypes.DeployConfig memory cfg = _launchConfig("helper-gaps");

        DeploymentTypes.DeployConfig memory badCfg = _cloneConfig(cfg);
        badCfg.governanceDiamond = address(0);
        vm.expectRevert(DeploymentHelper.StakingDeploymentMissingGovernance.selector);
        this.prepare(badCfg);
        badCfg = _cloneConfig(cfg);
        badCfg.create2Deployer = address(0);
        vm.expectRevert(DeploymentHelper.StakingDeploymentMissingCreate2Deployer.selector);
        this.prepare(badCfg);
        badCfg = _cloneConfig(cfg);
        badCfg.shellSalt = bytes32(0);
        vm.expectRevert(DeploymentHelper.StakingDeploymentMissingShellSalt.selector);
        this.prepare(badCfg);

        DeploymentTypes.DeployArtifacts memory prepared = DeploymentHelper.prepare(cfg);
        badCfg = _cloneConfig(cfg);
        badCfg.create2Deployer = address(0);
        vm.expectRevert(DeploymentHelper.StakingDeploymentMissingCreate2Deployer.selector);
        this.adopt(badCfg, prepared);
        badCfg = _cloneConfig(cfg);
        badCfg.shellSalt = bytes32(0);
        vm.expectRevert(DeploymentHelper.StakingDeploymentMissingShellSalt.selector);
        this.adopt(badCfg, prepared);

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentHelper.StakingDeploymentAddressMismatch.selector, address(1), address(2))
        );
        this.requireExpectedAddress(address(1), address(2));

        DiamondInit.LaunchSleeve[] memory salts = new DiamondInit.LaunchSleeve[](1);
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentHelper.StakingDeploymentInvalidSleeveSalt.selector, 0, bytes32(0))
        );
        this.requireValidSleeveSalt(salts, 0, bytes32(0));
        salts[0].salt = bytes32(uint256(7));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentHelper.StakingDeploymentDuplicateSleeveSalt.selector, 0, 1, bytes32(uint256(7))
            )
        );
        this.requireValidSleeveSalt(salts, 1, bytes32(uint256(7)));

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentHelper.StakingDeploymentFacetMetadataInvalid.selector, address(0xBEEF))
        );
        this.expectFacet(address(0xBEEF));

        prepared = DeploymentHelper.deployCommittedShellLocal(cfg, prepared);
        address shell = address(prepared.diamond);
        bytes memory stateCall = abi.encodeCall(LensFacet.stakingLaunchState, ());
        vm.mockCall(shell, stateCall, hex"01");
        vm.expectRevert(abi.encodeWithSelector(DeploymentHelper.StakingDeploymentLaunchStateMismatch.selector, shell));
        this.finalizeCommitted(cfg, prepared);
        vm.clearMockedCalls();

        vm.mockCall(shell, stateCall, abi.encode(LibStakingLaunch.Phase.Committed, prepared.payloadHash));
        vm.expectRevert(abi.encodeWithSelector(DeploymentHelper.StakingDeploymentLaunchStateMismatch.selector, shell));
        this.finalizeCommitted(cfg, prepared);
        vm.clearMockedCalls();

        vm.mockCallRevert(shell, stateCall, hex"deadbeef");
        vm.expectRevert(abi.encodeWithSelector(DeploymentHelper.StakingDeploymentLaunchStateMismatch.selector, shell));
        this.finalizeCommitted(cfg, prepared);
        vm.clearMockedCalls();

        DeploymentTypes.DeployArtifacts memory bad = _cloneArtifacts(prepared);
        bad.payloadHash = bytes32(uint256(1));
        vm.expectRevert(DeploymentHelper.StakingDeploymentCandidateMismatch.selector);
        this.requireFinalizedCandidate(cfg, bad);

        bad = _cloneArtifacts(prepared);
        delete bad.diamond;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentHelper.StakingDeploymentAddressMismatch.selector,
                DeploymentHelper.predictedShell(cfg, bad),
                address(0)
            )
        );
        this.requireFinalizedCandidate(cfg, bad);
        prepared = DeploymentHelper.adoptCommittedShell(cfg, prepared);

        uint256 snapshot = vm.snapshotState();
        vm.etch(shell, hex"00");
        vm.expectRevert(abi.encodeWithSelector(DeploymentHelper.StakingDeploymentRuntimeMismatch.selector, shell));
        this.requireFinalizedCandidate(cfg, prepared);
        vm.revertToState(snapshot);

        (DeploymentTypes.DeployConfig memory finalizedCfg, DeploymentTypes.DeployArtifacts memory finalized,) =
            _finalizedLaunch("helper-finalized-gaps");
        vm.mockCall(
            address(finalized.diamond), stateCall, abi.encode(LibStakingLaunch.Phase.Committed, finalized.payloadHash)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentHelper.StakingDeploymentLaunchStateMismatch.selector, address(finalized.diamond)
            )
        );
        this.requireFinalizedCandidate(finalizedCfg, finalized);
        vm.clearMockedCalls();

        IDiamondLoupe.Facet[] memory observed = IDiamondLoupe(address(finalized.diamond)).facets();
        IDiamondLoupe.Facet[] memory empty = new IDiamondLoupe.Facet[](0);
        vm.mockCall(address(finalized.diamond), abi.encodeCall(IDiamondLoupe.facets, ()), abi.encode(empty));
        vm.expectRevert(DeploymentHelper.StakingDeploymentTopologyMismatch.selector);
        this.requireFinalizedTopology(finalized);
        vm.clearMockedCalls();
        observed[0].facetAddress = address(0xBEEF);
        vm.mockCall(address(finalized.diamond), abi.encodeCall(IDiamondLoupe.facets, ()), abi.encode(observed));
        vm.expectRevert(DeploymentHelper.StakingDeploymentTopologyMismatch.selector);
        this.requireFinalizedTopology(finalized);
        vm.clearMockedCalls();
    }

    function testSleeveDeployerCoversAllRejectedEncodings() public {
        SleeveDeployerHelper.SleeveRequest memory req = SleeveRequestBuilder.basic(address(1), address(2), true, 0);
        req.implementation = address(0);
        vm.expectRevert(SleeveDeployerHelper.SleeveImplementationMissing.selector);
        this.predictSleeve(req);
        req.implementation = address(1);
        req.asset = address(0);
        vm.expectRevert(SleeveDeployerHelper.SleeveAssetMissing.selector);
        this.predictSleeve(req);

        req = SleeveRequestBuilder.basic(address(1), address(2), true, 0);
        req.initArgs = hex"01";
        vm.expectRevert(SleeveDeployerHelper.SleeveInitDataNonCanonical.selector);
        this.buildInitializer(req);
        req.initArgs = bytes("");
        req.initialOperational = false;
        vm.expectRevert(abi.encodeWithSelector(SleeveDeployerHelper.SleeveBasicStateUnsupported.selector, false, false));
        this.buildInitializer(req);

        vm.expectRevert(SleeveDeployerHelper.SleeveInitDataNonCanonical.selector);
        this.buildManualInitializer(hex"01");
        vm.expectRevert(SleeveDeployerHelper.SleeveInitDataNonCanonical.selector);
        this.buildCurveInitializer(bytes(""));

        SleeveCurve.CurveLaunchParams memory curve = _curveParams();
        bytes memory trailing = bytes.concat(abi.encode(curve), bytes32(uint256(1)));
        vm.expectRevert(SleeveDeployerHelper.SleeveInitDataNonCanonical.selector);
        this.buildCurveInitializer(trailing);

        vm.expectRevert(SleeveDeployerHelper.SleeveInitDataMissing.selector);
        this.requireInitializerBuilt(bytes(""));
        vm.expectRevert(SleeveDeployerHelper.SleeveInitDataNonCanonical.selector);
        this.requireCanonicalAddressEncoding(abi.encode(address(1)), address(2));
    }

    function testSleeveWriterCoversEnvelopeAndCommittedCandidateRejections() public {
        DeploymentTypes.DeployConfig memory emptyCfg;
        DeploymentTypes.DeployArtifacts memory emptyArt;
        vm.expectRevert(bytes("Staking Sleeve output path missing"));
        this.writeSleeveJson(emptyCfg, emptyArt, "");
        vm.expectRevert(bytes("Staking Sleeve requests empty"));
        this.writeSleeveJson(emptyCfg, emptyArt, "sleeves.json");

        emptyCfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        vm.expectRevert(bytes("Staking Sleeve result length mismatch"));
        this.writeSleeveJson(emptyCfg, emptyArt, "sleeves.json");

        (DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art,) =
            _finalizedLaunch("sleeve-writer-envelope");
        DeploymentTypes.DeployArtifacts memory bad = _cloneArtifacts(art);
        bad.payloadHash = bytes32(uint256(1));
        _expectSleeveWriterRevert(cfg, bad, "Staking Sleeve finalization candidate mismatch");

        bad = _cloneArtifacts(art);
        bad.finalization.initializerCalldata = hex"010203";
        bad.payloadHash = LibStakingLaunch.payloadHash(bad.finalization);
        _expectSleeveWriterRevert(cfg, bad, "Staking initializer calldata malformed");

        bad = _cloneArtifacts(art);
        bad.finalization.initializerCalldata = bytes.concat(bytes4(0xdeadbeef), bytes32(0));
        bad.payloadHash = LibStakingLaunch.payloadHash(bad.finalization);
        _expectSleeveWriterRevert(cfg, bad, "Staking initializer selector mismatch");

        bad = _cloneArtifacts(art);
        DiamondInit.LaunchSleeve[] memory none = new DiamondInit.LaunchSleeve[](0);
        _replaceCommittedSleeves(bad, none);
        _expectSleeveWriterRevert(cfg, bad, "Staking committed Sleeve length mismatch");

        address[] memory wrongOrder = new address[](1);
        wrongOrder[0] = address(0xBEEF);
        vm.mockCall(address(art.diamond), abi.encodeCall(SleeveRegistryFacet.sleeves, ()), abi.encode(wrongOrder));
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve registry order mismatch");
        vm.clearMockedCalls();
        address[] memory noRegistered = new address[](0);
        vm.mockCall(address(art.diamond), abi.encodeCall(SleeveRegistryFacet.sleeves, ()), abi.encode(noRegistered));
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve registry count mismatch");
        vm.clearMockedCalls();

        DeploymentTypes.DeployConfig memory badCfg = _cloneConfig(cfg);
        badCfg.sleeves[0].approve = !badCfg.sleeves[0].approve;
        _expectSleeveWriterRevert(badCfg, art, "Staking committed Sleeve request mismatch");

        bad = _cloneArtifacts(art);
        DiamondInit.LaunchSleeve[] memory committed = _committedSleeves(bad);
        committed[0].salt = bytes32(uint256(committed[0].salt) + 1);
        _replaceCommittedSleeves(bad, committed);
        _expectSleeveWriterRevert(cfg, bad, "Staking committed Sleeve salt mismatch");

        bad = _cloneArtifacts(art);
        committed = _committedSleeves(bad);
        committed[0].implementationCodeHash = bytes32(uint256(1));
        _replaceCommittedSleeves(bad, committed);
        _expectSleeveWriterRevert(cfg, bad, "Staking Sleeve live implementation codehash mismatch");
    }

    function testSleeveWriterCoversGenericRuntimeRejections() public {
        (DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art,) =
            _finalizedLaunch("sleeve-writer-runtime");
        address staking = address(art.diamond);
        address sleeve = art.sleeves[0].sleeve;
        DeploymentTypes.DeployArtifacts memory bad;

        bad = _cloneArtifacts(art);
        bad.sleeves[0].sleeve = address(0xBEEF);
        _expectSleeveWriterRevert(cfg, bad, "Staking Sleeve address mismatch");
        bad = _cloneArtifacts(art);
        bad.sleeves[0].asset = address(0xBEEF);
        _expectSleeveWriterRevert(cfg, bad, "Staking Sleeve asset mismatch");
        bad = _cloneArtifacts(art);
        bad.sleeves[0].approve = !bad.sleeves[0].approve;
        _expectSleeveWriterRevert(cfg, bad, "Staking Sleeve approval mismatch");

        uint256 snapshot = vm.snapshotState();
        vm.etch(sleeve, bytes.concat(sleeve.code, hex"00"));
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve proxy mismatch");
        vm.revertToState(snapshot);
        vm.store(sleeve, ERC1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(0xBEEF)))));
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve raw implementation mismatch");
        vm.revertToState(snapshot);

        _mock(sleeve, abi.encodeCall(ISleeveProxy.implementation, ()), abi.encode(address(0xBEEF)));
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve proxy implementation view mismatch");
        vm.clearMockedCalls();

        LibAppStorage.SleeveConfig memory registry = SleeveRegistryFacet(staking).sleeveConfig(sleeve);
        LibAppStorage.SleeveConfig memory badRegistry = abi.decode(abi.encode(registry), (LibAppStorage.SleeveConfig));
        badRegistry.registered = false;
        _mockSleeveRegistry(staking, sleeve, badRegistry);
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve not registered");
        vm.clearMockedCalls();
        badRegistry = abi.decode(abi.encode(registry), (LibAppStorage.SleeveConfig));
        badRegistry.approved = !registry.approved;
        _mockSleeveRegistry(staking, sleeve, badRegistry);
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve registry approval mismatch");
        vm.clearMockedCalls();
        badRegistry = abi.decode(abi.encode(registry), (LibAppStorage.SleeveConfig));
        badRegistry.asset = address(0xBEEF);
        _mockSleeveRegistry(staking, sleeve, badRegistry);
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve registry asset mismatch");
        vm.clearMockedCalls();
        badRegistry = abi.decode(abi.encode(registry), (LibAppStorage.SleeveConfig));
        badRegistry.principalAssets = 1;
        _mockSleeveRegistry(staking, sleeve, badRegistry);
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve registry principal mismatch");
        vm.clearMockedCalls();

        _mock(sleeve, abi.encodeCall(ISleeve.stakingDiamond, ()), abi.encode(address(0xBEEF)));
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve controller mismatch");
        vm.clearMockedCalls();
        _mock(sleeve, abi.encodeCall(ISleeve.asset, ()), abi.encode(address(0xBEEF)));
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve runtime asset mismatch");
        vm.clearMockedCalls();
        _mock(sleeve, abi.encodeCall(ISleeve.principalAssets, ()), abi.encode(uint256(1)));
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve principal mismatch");
        vm.clearMockedCalls();
        _mock(sleeve, abi.encodeWithSignature("principalCap()"), abi.encode(cfg.sleeves[0].principalCap + 1));
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve cap mismatch");
        vm.clearMockedCalls();
        _mock(sleeve, abi.encodeWithSignature("operational()"), abi.encode(!cfg.sleeves[0].initialOperational));
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve operational mismatch");
        vm.clearMockedCalls();
        _mock(sleeve, abi.encodeWithSignature("paused()"), abi.encode(!cfg.sleeves[0].initialPaused));
        _expectSleeveWriterRevert(cfg, art, "Staking Sleeve local pause mismatch");
        vm.clearMockedCalls();

        _mock(sleeve, abi.encodeWithSignature("operator()"), abi.encode(address(0xBEEF)));
        _expectSleeveWriterRevert(cfg, art, "Staking Manual operator mismatch");
        vm.clearMockedCalls();
    }

    function testSleeveWriterCoversTypedRuntimeRejections() public {
        TypedFixture memory f = _typedFixture("sleeve-writer-typed");
        address erc4626 = f.art.sleeves[1].sleeve;
        address curve = f.art.sleeves[2].sleeve;
        SleeveCurve.CurveLaunchParams memory params =
            abi.decode(f.cfg.sleeves[2].initArgs, (SleeveCurve.CurveLaunchParams));

        _mock(erc4626, abi.encodeWithSignature("vault()"), abi.encode(address(0xBEEF)));
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking ERC4626 vault mismatch");
        vm.clearMockedCalls();

        _mock(curve, abi.encodeWithSignature("otherAsset()"), abi.encode(address(0xBEEF)));
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking Curve other asset mismatch");
        vm.clearMockedCalls();
        _mock(curve, abi.encodeWithSignature("curvePool()"), abi.encode(address(0xBEEF)));
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking Curve pool mismatch");
        vm.clearMockedCalls();
        _mock(curve, abi.encodeWithSignature("lpToken()"), abi.encode(address(0xBEEF)));
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking Curve LP token mismatch");
        vm.clearMockedCalls();
        _mock(curve, abi.encodeWithSignature("underlyingIndex()"), abi.encode(int128(9)));
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking Curve underlying index mismatch");
        vm.clearMockedCalls();
        _mock(curve, abi.encodeWithSignature("otherIndex()"), abi.encode(int128(9)));
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking Curve other index mismatch");
        vm.clearMockedCalls();
        _mock(curve, abi.encodeWithSignature("targetOtherPpm()"), abi.encode(uint32(params.venue.otherSharePpm + 1)));
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking Curve share mismatch");
        vm.clearMockedCalls();
        _mock(curve, abi.encodeWithSignature("gauge()"), abi.encode(address(0xBEEF)));
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking Curve gauge mismatch");
        vm.clearMockedCalls();
        _mock(curve, abi.encodeWithSignature("maxLpTokens()"), abi.encode(params.maxLpTokens + 1));
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking Curve LP cap mismatch");
        vm.clearMockedCalls();
        _mock(curve, abi.encodeWithSignature("priceReference()"), abi.encode(params.venue.priceReference + 1));
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking Curve price reference mismatch");
        vm.clearMockedCalls();
        _mock(
            curve,
            abi.encodeWithSignature("maxPriceDeviationBps()"),
            abi.encode(uint32(params.venue.maxPriceDeviationBps + 1))
        );
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking Curve price deviation mismatch");
        vm.clearMockedCalls();
        _mock(curve, abi.encodeWithSignature("rewardSwapAdapter()"), abi.encode(address(0xBEEF)));
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking Curve reward adapter mismatch");
        vm.clearMockedCalls();
        _mock(curve, abi.encodeWithSignature("cygldController()"), abi.encode(address(0xBEEF)));
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking Curve controller mismatch");
        vm.clearMockedCalls();
        _mock(curve, abi.encodeWithSignature("basketSwapAdapter()"), abi.encode(address(0xBEEF)));
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking Curve basket adapter mismatch");
        vm.clearMockedCalls();
        address[] memory wrongRewards = new address[](1);
        wrongRewards[0] = address(0xBEEF);
        _mock(curve, abi.encodeWithSignature("rewardTokens()"), abi.encode(wrongRewards));
        _expectSleeveWriterRevert(f.cfg, f.art, "Staking Curve reward tokens mismatch");
        vm.clearMockedCalls();
    }

    function _exerciseCriticalAuthorityFailures(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art
    ) private {
        address staking = address(art.diamond);
        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(staking);
        bytes32 adminRole = access.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = access.upgraderRole();

        _mock(staking, abi.encodeWithSignature("defaultAdmin()"), abi.encode(address(1)));
        _expectFinalizedRevert(cfg, art, "Staking Governance default admin mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeWithSignature("getRoleMemberCount(bytes32)", adminRole), abi.encode(2));
        _expectFinalizedRevert(cfg, art, "Staking default admin count mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeWithSignature("getRoleMember(bytes32,uint256)", adminRole, 0), abi.encode(address(1)));
        _expectFinalizedRevert(cfg, art, "Staking default admin member mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeWithSignature("getRoleMemberCount(bytes32)", upgraderRole), abi.encode(2));
        _expectFinalizedRevert(cfg, art, "Staking upgrader count mismatch");
        vm.clearMockedCalls();
        _mock(
            staking, abi.encodeWithSignature("getRoleMember(bytes32,uint256)", upgraderRole, 0), abi.encode(address(1))
        );
        _expectFinalizedRevert(cfg, art, "Staking upgrader member mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeWithSignature("getRoleAdmin(bytes32)", upgraderRole), abi.encode(bytes32(uint256(1))));
        _expectFinalizedRevert(cfg, art, "Staking upgrader admin mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeWithSignature("hasRole(bytes32,address)", adminRole, cfg.safeWallet), abi.encode(true));
        _expectFinalizedRevert(cfg, art, "Staking Safe retained default admin");
        vm.clearMockedCalls();
        _mock(
            staking, abi.encodeWithSignature("hasRole(bytes32,address)", upgraderRole, cfg.safeWallet), abi.encode(true)
        );
        _expectFinalizedRevert(cfg, art, "Staking Safe retained upgrader");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeWithSignature("defaultAdminDelay()"), abi.encode(uint48(1)));
        _expectFinalizedRevert(cfg, art, "Staking default admin delay mismatch");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeWithSignature("pendingDefaultAdmin()"), abi.encode(address(1), uint48(1)));
        _expectFinalizedRevert(cfg, art, "Staking pending default admin");
        vm.clearMockedCalls();
        _mock(staking, abi.encodeWithSignature("pendingDefaultAdminDelay()"), abi.encode(uint48(1), uint48(1)));
        _expectFinalizedRevert(cfg, art, "Staking pending admin delay");
        vm.clearMockedCalls();
    }

    function _exerciseOrdinaryRoleFailures(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art
    ) private {
        address staking = address(art.diamond);
        bytes32 adminRole = DefaultAdminAccessControlFacet(staking).DEFAULT_ADMIN_ROLE();

        _mock(
            staking, abi.encodeWithSignature("getRoleAdmin(bytes32)", WITHDRAWER_ROLE), abi.encode(bytes32(uint256(1)))
        );
        _expectRolesRevert(cfg, art, "Staking withdrawer admin mismatch");
        vm.clearMockedCalls();
        _mock(
            staking, abi.encodeWithSignature("getRoleAdmin(bytes32)", ALLOCATOR_ROLE), abi.encode(bytes32(uint256(1)))
        );
        _expectRolesRevert(cfg, art, "Staking allocator admin mismatch");
        vm.clearMockedCalls();

        uint256 withdrawerCount = cfg.withdrawers.length + art.sleeves.length;
        _mock(
            staking,
            abi.encodeWithSignature("getRoleMemberCount(bytes32)", WITHDRAWER_ROLE),
            abi.encode(withdrawerCount + 1)
        );
        _expectRolesRevert(cfg, art, "Staking withdrawer count mismatch");
        vm.clearMockedCalls();
        _mock(
            staking,
            abi.encodeWithSignature("hasRole(bytes32,address)", WITHDRAWER_ROLE, cfg.withdrawers[0]),
            abi.encode(false)
        );
        _expectRolesRevert(cfg, art, "Staking withdrawer mismatch");
        vm.clearMockedCalls();
        _mock(
            staking,
            abi.encodeWithSignature("getRoleMember(bytes32,uint256)", WITHDRAWER_ROLE, 0),
            abi.encode(address(1))
        );
        _expectRolesRevert(cfg, art, "Staking withdrawer order mismatch");
        vm.clearMockedCalls();

        _mock(
            staking,
            abi.encodeWithSignature("getRoleMemberCount(bytes32)", ALLOCATOR_ROLE),
            abi.encode(cfg.allocators.length + 1)
        );
        _expectRolesRevert(cfg, art, "Staking allocator count mismatch");
        vm.clearMockedCalls();
        _mock(
            staking,
            abi.encodeWithSignature("hasRole(bytes32,address)", ALLOCATOR_ROLE, cfg.allocators[0]),
            abi.encode(false)
        );
        _expectRolesRevert(cfg, art, "Staking allocator mismatch");
        vm.clearMockedCalls();
        _mock(
            staking,
            abi.encodeWithSignature("getRoleMember(bytes32,uint256)", ALLOCATOR_ROLE, 0),
            abi.encode(address(1))
        );
        _expectRolesRevert(cfg, art, "Staking allocator order mismatch");
        vm.clearMockedCalls();
        assertEq(DefaultAdminAccessControlFacet(staking).getRoleAdmin(WITHDRAWER_ROLE), adminRole);
    }

    function _validParams() private pure returns (DeployParams.Params memory p) {
        p.safeWallet = address(0x5AFE);
        p.coreDiamond = address(0xC0);
        p.governanceDiamond = address(0xD0);
        p.create2Deployer = address(0xC2);
        p.shellSalt = bytes32(uint256(1));
        p.allocators = new address[](1);
        p.allocators[0] = address(0xA1);
        p.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
    }

    function _setCanonicalSleeveEnv() private {
        vm.setEnv("STAKING_SLEEVE_IMPLEMENTATIONS", "0x0000000000000000000000000000000000000001");
        vm.setEnv("STAKING_SLEEVE_ASSETS", "0x0000000000000000000000000000000000000002");
        vm.setEnv("STAKING_SLEEVE_APPROVALS", "true");
        vm.setEnv("STAKING_SLEEVE_OPERATIONAL", "true");
        vm.setEnv("STAKING_SLEEVE_LOCAL_PAUSED", "false");
        vm.setEnv("STAKING_SLEEVE_PRINCIPAL_CAPS", "0");
        vm.setEnv("STAKING_SLEEVE_INIT_TYPES", "0");
        vm.setEnv("STAKING_SLEEVE_INIT_ARGS", "0x");
    }

    function _expectSleevesFromEnvRevert(string memory reason) private {
        vm.expectRevert(bytes(reason));
        this.sleevesFromEnv();
    }

    function _launchConfig(string memory saltLabel) private returns (DeploymentTypes.DeployConfig memory cfg) {
        MockCyberGold core = new MockCyberGold();
        CoverageGovernanceExecutor governance = new CoverageGovernanceExecutor();
        cfg.safeWallet = MockSafeWalletFactory.deploy(address(this));
        cfg.coreDiamond = address(core);
        cfg.governanceDiamond = address(governance);
        cfg.name = "Coverage Staking";
        cfg.symbol = "cSTK";
        cfg.claimExpiry = 11;
        cfg.headSweepLimit = 12;
        cfg.autoProcessMax = 13;
        cfg.performanceFeePpm = 14;
        cfg.fundManagerSwapAdapter = address(0xAD);
        cfg.withdrawers = new address[](1);
        cfg.withdrawers[0] = address(0xA11CE);
        cfg.allocators = new address[](1);
        cfg.allocators[0] = address(0xA110C);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] =
            SleeveRequestBuilder.manual(address(new SleeveManual()), address(core), address(0x0B0B), true, 17 ether);
        cfg.create2Deployer = address(this);
        cfg.shellSalt = keccak256(bytes(saltLabel));
    }

    function _finalizedLaunch(string memory saltLabel)
        private
        returns (
            DeploymentTypes.DeployConfig memory cfg,
            DeploymentTypes.DeployArtifacts memory art,
            CoverageGovernanceExecutor governance
        )
    {
        cfg = _launchConfig(saltLabel);
        governance = CoverageGovernanceExecutor(cfg.governanceDiamond);
        art = DeploymentHelper.prepare(cfg);
        art = DeploymentHelper.deployCommittedShellLocal(cfg, art);
        art = DeploymentHelper.finalizeCommitted(cfg, art);
    }

    function _typedFixture(string memory saltLabel) private returns (TypedFixture memory f) {
        (f.cfg, f.core,) = _typedConfig(saltLabel);
        f.operator = address(0x0B0B);
        f.vault = new MockVault4626(f.core);
        f.otherAsset = new MockCyberGold();
        f.pool = new MockCurvePool(address(f.core), address(f.otherAsset));
        f.gauge = new MockCurveGauge(IERC20(address(f.pool)));
        f.rewardAdapter = new MockSwapAdapter();
        f.basketAdapter = new MockSwapAdapter();
        f.rewardToken = address(new MockCyberGold());
        address[] memory basket = new address[](1);
        basket[0] = address(f.otherAsset);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1_000_000;
        uint256[] memory conversions = new uint256[](1);
        conversions[0] = 1e18;
        f.controller = new MockCygldBasketController(address(f.core), basket, weights, conversions);

        SleeveCurve.CurveLaunchParams memory curve = _curveParams();
        curve.venue.otherAsset = address(f.otherAsset);
        curve.venue.pool = address(f.pool);
        curve.venue.gauge = address(f.gauge);
        curve.venue.cygldController = address(f.controller);
        curve.venue.basketSwapAdapter = address(f.basketAdapter);
        curve.rewardSwapAdapter = address(f.rewardAdapter);
        curve.rewardTokens[0] = f.rewardToken;
        f.cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](3);
        f.cfg.sleeves[0] = SleeveRequestBuilder.manualWithState(
            address(new SleeveManual()), address(f.core), f.operator, true, 101 ether, false, true
        );
        f.cfg.sleeves[1] = SleeveRequestBuilder.erc4626WithState(
            address(new Sleeve4626()), address(f.core), address(f.vault), false, 202 ether, true, false
        );
        f.cfg.sleeves[2] = SleeveRequestBuilder.curveLaunch(
            address(new SleeveCurve()), address(f.core), curve, true, 303 ether, true, true
        );
        f.art = DeploymentHelper.prepare(f.cfg);
        f.art = DeploymentHelper.deployCommittedShellLocal(f.cfg, f.art);
        f.art = DeploymentHelper.finalizeCommitted(f.cfg, f.art);
    }

    function _typedConfig(string memory saltLabel)
        private
        returns (DeploymentTypes.DeployConfig memory cfg, MockCyberGold core, CoverageGovernanceExecutor governance)
    {
        cfg = _launchConfig(saltLabel);
        core = MockCyberGold(cfg.coreDiamond);
        governance = CoverageGovernanceExecutor(cfg.governanceDiamond);
    }

    function _curveParams() private pure returns (SleeveCurve.CurveLaunchParams memory params) {
        address[] memory rewards = new address[](1);
        rewards[0] = address(0xA11);
        params = SleeveCurve.CurveLaunchParams({
            venue: SleeveCurve.CurveInitParams({
                otherAsset: address(0x401),
                pool: address(0x402),
                underlyingIndex: 0,
                otherIndex: 1,
                otherSharePpm: 400_000,
                gauge: address(0x403),
                priceReference: 1e18,
                maxPriceDeviationBps: 500,
                cygldController: address(0x404),
                basketSwapAdapter: address(0x405)
            }),
            maxLpTokens: 404 ether,
            rewardSwapAdapter: address(0x406),
            rewardTokens: rewards
        });
    }

    function _cloneConfig(DeploymentTypes.DeployConfig memory cfg)
        private
        pure
        returns (DeploymentTypes.DeployConfig memory)
    {
        return abi.decode(abi.encode(cfg), (DeploymentTypes.DeployConfig));
    }

    function _cloneArtifacts(DeploymentTypes.DeployArtifacts memory art)
        private
        pure
        returns (DeploymentTypes.DeployArtifacts memory)
    {
        return abi.decode(abi.encode(art), (DeploymentTypes.DeployArtifacts));
    }

    function _committedSleeves(DeploymentTypes.DeployArtifacts memory art)
        private
        pure
        returns (DiamondInit.LaunchSleeve[] memory sleeves)
    {
        bytes memory calldata_ = art.finalization.initializerCalldata;
        bytes memory args = new bytes(calldata_.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = calldata_[i + 4];
        }
        (DiamondInit.InitConfig memory initCfg,,) = abi.decode(args, (DiamondInit.InitConfig, string, string));
        return initCfg.sleeves;
    }

    function _replaceCommittedSleeves(
        DeploymentTypes.DeployArtifacts memory art,
        DiamondInit.LaunchSleeve[] memory sleeves
    ) private pure {
        bytes memory calldata_ = art.finalization.initializerCalldata;
        bytes memory args = new bytes(calldata_.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = calldata_[i + 4];
        }
        (DiamondInit.InitConfig memory initCfg, string memory name_, string memory symbol_) =
            abi.decode(args, (DiamondInit.InitConfig, string, string));
        initCfg.sleeves = sleeves;
        art.finalization.initializerCalldata =
            abi.encodeWithSelector(DiamondInit.finalize.selector, initCfg, name_, symbol_);
        art.payloadHash = LibStakingLaunch.payloadHash(art.finalization);
    }

    function _mock(address target, bytes memory callData, bytes memory returnData) private {
        vm.mockCall(target, callData, returnData);
    }

    function _mockSleeveRegistry(address staking, address sleeve, LibAppStorage.SleeveConfig memory registry) private {
        _mock(staking, abi.encodeCall(SleeveRegistryFacet.sleeveConfig, (sleeve)), abi.encode(registry));
    }

    function _expectCandidateRevert(DeploymentTypes.DeployArtifacts memory art, string memory reason) private {
        vm.expectRevert(bytes(reason));
        this.requireCandidateEvidence(art);
    }

    function _expectFinalizedRevert(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        string memory reason
    ) private {
        vm.expectRevert(bytes(reason));
        this.requireFinalizedLaunch(cfg, art);
    }

    function _expectScalarRevert(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        string memory reason
    ) private {
        vm.expectRevert(bytes(reason));
        this.requireScalarLaunchState(cfg, art);
    }

    function _expectRolesRevert(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        string memory reason
    ) private {
        vm.expectRevert(bytes(reason));
        this.requireOrdinaryRoles(cfg, art);
    }

    function _expectSleeveWriterRevert(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        string memory reason
    ) private {
        vm.expectRevert(bytes(reason));
        this.writeSleeveJson(cfg, art, "unused-sleeves.json");
    }

    function validateExecutionContext(address env, DeployParams.Params memory p) external view {
        DeployParams.validateExecutionContext(Vm(env), p);
    }

    function sleevesFromEnv() external view returns (SleeveDeployerHelper.SleeveRequest[] memory) {
        return DeployParams.sleevesFromEnv(vm);
    }

    function writeDeploymentJson(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        string memory path,
        string memory sleevesPath
    ) external {
        DeployParams.writeJson(vm, cfg, art, path, sleevesPath);
    }

    function writeSleeveJson(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        string memory path
    ) external {
        SleeveArtifactWriter.writeJson(vm, cfg, art, path);
    }

    function requireCandidateEvidence(DeploymentTypes.DeployArtifacts memory art) external view {
        DeployParams._requireCandidateEvidence(vm, art);
    }

    function requireFinalizedLaunch(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art)
        external
        view
    {
        DeployParams._requireFinalizedLaunch(vm, cfg, art);
    }

    function requireScalarLaunchState(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art
    ) external view {
        DeployParams._requireScalarLaunchState(cfg, art);
    }

    function requireOrdinaryRoles(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art)
        external
        view
        returns (address[] memory)
    {
        return DeployParams._requireOrdinaryRoles(cfg, art);
    }

    function requirePredictedShell(address predicted, address observed) external pure {
        DeployParams.requirePredictedShell(predicted, observed);
    }

    function prepare(DeploymentTypes.DeployConfig memory cfg)
        external
        returns (DeploymentTypes.DeployArtifacts memory)
    {
        return DeploymentHelper.prepare(cfg);
    }

    function adopt(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art)
        external
        view
        returns (DeploymentTypes.DeployArtifacts memory)
    {
        return DeploymentHelper.adoptCommittedShell(cfg, art);
    }

    function finalizeCommitted(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory art)
        external
        returns (DeploymentTypes.DeployArtifacts memory)
    {
        return DeploymentHelper.finalizeCommitted(cfg, art);
    }

    function requireFinalizedCandidate(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art
    ) external view {
        DeploymentHelper.requireFinalizedCandidate(cfg, art);
    }

    function requireFinalizedTopology(DeploymentTypes.DeployArtifacts memory art) external view {
        DeploymentHelper._requireFinalizedTopology(art);
    }

    function requireExpectedAddress(address expected, address actual) external pure {
        DeploymentHelper.requireExpectedAddress(expected, actual);
    }

    function requireValidSleeveSalt(DiamondInit.LaunchSleeve[] memory sleeves, uint256 index, bytes32 salt)
        external
        pure
    {
        DeploymentHelper.requireValidSleeveSalt(sleeves, index, salt);
    }

    function expectFacet(address facet) external view returns (StakingLaunchTypes.FacetExpectation memory) {
        return DeploymentHelper._expectFacet(facet);
    }

    function predictSleeve(SleeveDeployerHelper.SleeveRequest memory req) external view returns (address) {
        return SleeveDeployerHelper.predictDeterministic(address(this), address(this), req, bytes32(uint256(1)));
    }

    function buildInitializer(SleeveDeployerHelper.SleeveRequest memory req) external pure returns (bytes memory) {
        return SleeveDeployerHelper._buildInitializer(req, address(1));
    }

    function buildManualInitializer(bytes memory data) external pure returns (bytes memory) {
        SleeveDeployerHelper.SleeveRequest memory req =
            SleeveRequestBuilder.manualWithState(address(1), address(2), address(3), true, 0, true, false);
        req.initArgs = data;
        return SleeveDeployerHelper._buildInitializer(req, address(1));
    }

    function buildCurveInitializer(bytes memory data) external pure returns (bytes memory) {
        SleeveDeployerHelper.SleeveRequest memory req;
        req.implementation = address(1);
        req.asset = address(2);
        req.initialOperational = true;
        req.initType = SleeveDeployerHelper.InitType.Curve;
        req.initArgs = data;
        return SleeveDeployerHelper._buildInitializer(req, address(1));
    }

    function requireInitializerBuilt(bytes memory data) external pure {
        SleeveDeployerHelper.requireInitializerBuilt(data);
    }

    function requireCanonicalAddressEncoding(bytes memory data, address value) external pure {
        SleeveDeployerHelper.requireCanonicalAddressEncoding(data, value);
    }
}
