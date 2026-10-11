// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";

import {FunctionNotFound} from "diamond-infra/diamond/ProtocolDiamond.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {IDiamondEmergencyAuthority} from "diamond-infra/interfaces/IDiamondEmergencyAuthority.sol";

import {DeploymentHelper} from "staking/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "staking/deploy/DeploymentTypes.sol";
import {DiamondInit} from "staking/deploy/DiamondInit.sol";
import {StakingAuthorityInvariant} from "staking/deploy/StakingAuthorityInvariant.sol";
import {StakingSleeveInvariant} from "staking/deploy/StakingSleeveInvariant.sol";
import {StakingInterfaceInit} from "staking/deploy/StakingInterfaceInit.sol";
import {SleeveDeployerHelper} from "staking/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "staking/deploy/SleeveRequestBuilder.sol";
import {SleeveArtifactWriter} from "staking/deploy/SleeveArtifactWriter.sol";
import {StakingLaunchTypes, IStakingFinalizer} from "staking/deploy/StakingLaunchTypes.sol";
import {StakingFinalizerFacet} from "staking/facets/StakingFinalizerFacet.sol";
import {LensFacet} from "staking/facets/LensFacet.sol";
import {SleeveRegistryFacet} from "staking/facets/SleeveRegistryFacet.sol";
import {VaultFacet} from "staking/facets/VaultFacet.sol";
import {CustodyFacet} from "staking/facets/CustodyFacet.sol";
import {FundManagerFacet} from "staking/facets/FundManagerFacet.sol";
import {LibAppStorage} from "staking/diamond/LibAppStorage.sol";
import {StakingDiamond} from "staking/diamond/StakingDiamond.sol";
import {LibStakingLaunch} from "staking/libraries/LibStakingLaunch.sol";
import {ISleeve} from "staking/sleeves/ISleeve.sol";
import {SleeveBase} from "staking/sleeves/SleeveBase.sol";
import {SleeveManual} from "staking/sleeves/SleeveManual.sol";
import {Sleeve4626} from "staking/sleeves/Sleeve4626.sol";
import {SleeveCurve} from "staking/sleeves/SleeveCurve.sol";
import {ISleeveProxy} from "staking/sleeves/SleeveProxy.sol";

import {MockCyberGold} from "staking-mocks/MockCyberGold.sol";
import {MockCygldBasketController} from "staking-mocks/MockCygldBasketController.sol";
import {MockCurvePool, MockCurveGauge} from "staking-mocks/MockCurvePool.sol";
import {MockVault4626} from "staking-mocks/MockVault4626.sol";
import {MockSwapAdapter} from "staking-mocks/MockSwapAdapter.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";

contract CallbackSleeveImplementation {
    function initialize(address stakingDiamond, address, uint256) external {
        IAccessControl(stakingDiamond).grantRole(bytes32(0), address(this));
    }
}

contract EmptyDependency {}

contract GovernanceExecutor {
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

contract ForcedEtherSender {
    constructor() payable {}

    function force(address payable target) external {
        selfdestruct(target);
    }
}

contract SelfReplacingSleeveImplementation is SleeveBase {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address private immutable REPLACEMENT;

    constructor(address replacement) {
        REPLACEMENT = replacement;
    }

    function initialize(address stakingDiamond_, address asset_, uint256 principalCap_) external initializer {
        __SleeveBase_initLaunch(stakingDiamond_, asset_, principalCap_, true, false);
        address replacement = REPLACEMENT;
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            sstore(slot, replacement)
        }
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function _onAllocate(uint256 assets, bytes calldata) internal pure override returns (uint256) {
        return assets;
    }

    function _onDeallocate(uint256 assets, bytes calldata) internal pure override returns (uint256) {
        return assets;
    }

    function _onHarvest(bytes calldata) internal pure override returns (uint256) {
        return 0;
    }
}

contract TransientFailureSwitch {
    bool public shouldFail;

    function setShouldFail(bool value) external {
        shouldFail = value;
    }
}

contract TransientFailureSleeveImplementation is SleeveBase {
    error TransientSleeveFailure();

    TransientFailureSwitch private immutable FAILURE_SWITCH;

    constructor(TransientFailureSwitch failureSwitch_) {
        FAILURE_SWITCH = failureSwitch_;
    }

    function initialize(address stakingDiamond_, address asset_, uint256 principalCap_) external initializer {
        __SleeveBase_initLaunch(stakingDiamond_, asset_, principalCap_, true, false);
        if (FAILURE_SWITCH.shouldFail()) revert TransientSleeveFailure();
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function _onAllocate(uint256 assets, bytes calldata) internal pure override returns (uint256) {
        return assets;
    }

    function _onDeallocate(uint256 assets, bytes calldata) internal pure override returns (uint256) {
        return assets;
    }

    function _onHarvest(bytes calldata) internal pure override returns (uint256) {
        return 0;
    }
}

contract RecursiveFinalizerCallback {
    bytes private _relayCalldata;
    bool public enabled;

    function configure(bytes calldata relayCalldata_, bool enabled_) external {
        _relayCalldata = relayCalldata_;
        enabled = enabled_;
    }

    function setEnabled(bool enabled_) external {
        enabled = enabled_;
    }

    function reenter(address stakingDiamond) external {
        if (!enabled) return;
        (bool ok, bytes memory returndata) = stakingDiamond.call(_relayCalldata);
        if (!ok) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }
}

contract RecursiveFinalizerSleeveImplementation is SleeveBase {
    RecursiveFinalizerCallback private immutable CALLBACK;

    constructor(RecursiveFinalizerCallback callback_) {
        CALLBACK = callback_;
    }

    function initialize(address stakingDiamond_, address asset_, uint256 principalCap_) external initializer {
        __SleeveBase_initLaunch(stakingDiamond_, asset_, principalCap_, true, false);
        CALLBACK.reenter(stakingDiamond_);
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function _onAllocate(uint256 assets, bytes calldata) internal pure override returns (uint256) {
        return assets;
    }

    function _onDeallocate(uint256 assets, bytes calldata) internal pure override returns (uint256) {
        return assets;
    }

    function _onHarvest(bytes calldata) internal pure override returns (uint256) {
        return 0;
    }
}

contract StakingAtomicLaunchTest is Test {
    bytes32 internal constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");
    bytes32 internal constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 internal constant STAKING_LAUNCH_STORAGE_SLOT =
        0xaf998c30b6bf758887c4f7ae3b9979a4920a749d595a880ba4118393868a6f00;
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant OZ_PAUSABLE_STORAGE_SLOT =
        0xcd5ed15c6e187e77e9aee88184c21f4f2182ab5827cb3b7e07fbedcd63f03300;
    uint8 internal constant POST_SHELL_MUTATION_COUNT = 33;
    uint256 internal constant FAILURE_MATRIX_SLEEVE_COUNT = 3;
    address internal constant SAFE_OWNER = address(0xA11CE);
    address internal constant WITHDRAWER = address(0xB0B);
    address internal constant ALLOCATOR = address(0xCAFE);

    error InjectedSleeveBoundaryFailure(uint8 boundary, uint256 index);

    struct TypedLaunchFixture {
        DeploymentTypes.DeployConfig cfg;
        MockCyberGold core;
        address manualOperator;
        MockVault4626 vault;
        MockCyberGold otherAsset;
        MockCurvePool pool;
        MockCurveGauge gauge;
        MockCygldBasketController controller;
        MockSwapAdapter rewardAdapter;
        MockSwapAdapter basketAdapter;
        MockSwapAdapter fundManagerAdapter;
        address rewardToken;
    }

    function testCommittedShellExactRelayFinalizesAndReplayFails() external {
        (DeploymentTypes.DeployConfig memory cfg, MockCyberGold core, address governance) = _config(true);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        assertLe(address(out.diamondInit).code.length, 24_576);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        _assertPristineShell(out);

        vm.expectRevert(abi.encodeWithSelector(FunctionNotFound.selector, IDiamondLoupe.facets.selector));
        IDiamondLoupe(address(out.diamond)).facets();

        // The commitment hashes the full nested candidate. A one-byte calldata mutation
        // therefore stands in for every cut/facet/config field mutation at this boundary.
        StakingLaunchTypes.Finalization memory mutated = StakingLaunchTypes.Finalization({
            diamondCut: out.finalization.diamondCut,
            facets: out.finalization.facets,
            initializer: out.finalization.initializer,
            initializerCodeHash: out.finalization.initializerCodeHash,
            initializerCalldata: bytes.concat(out.finalization.initializerCalldata, hex"00")
        });
        vm.expectRevert(StakingFinalizerFacet.StakingFinalizationCommitmentMismatch.selector);
        IStakingFinalizer(address(out.diamond)).finalizeStaking(mutated);

        address relay = address(0xBEEF);
        uint256 gasBeforeFinalization = gasleft();
        vm.prank(relay);
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        uint256 finalizationGas = gasBeforeFinalization - gasleft();
        emit log_named_uint("atomic finalization gas", finalizationGas);
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) assertLt(finalizationGas, 15_000_000);
        out = DeploymentHelper.finalizeCommittedResults(cfg, out);
        _assertFinalizedLaunch(cfg, out, core, governance, relay);
        _activateAndAssertOnlyPauseChanged(cfg, out, governance);
        bytes32 operationalRole = keccak256("ATOMIC_LAUNCH_OPERATIONAL_TEST_ROLE");
        address operator = address(0x0B0B);
        GovernanceExecutor(governance)
            .execute(
                address(out.diamond),
                abi.encodeWithSelector(IAccessControl.grantRole.selector, operationalRole, operator)
            );
        assertTrue(IAccessControl(address(out.diamond)).hasRole(operationalRole, operator));

        vm.expectRevert(abi.encodeWithSelector(FunctionNotFound.selector, IStakingFinalizer.finalizeStaking.selector));
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
    }

    function testNonzeroFinalizationValueIsRejectedAndExactRetrySucceeds() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(true);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        address shell = address(out.diamond);

        vm.deal(address(this), 1);
        (bool ok,) = shell.call{value: 1}(abi.encodeCall(IStakingFinalizer.finalizeStaking, (out.finalization)));
        assertFalse(ok);
        assertEq(shell.balance, 0);
        _assertPristineShell(out);

        IStakingFinalizer(shell).finalizeStaking(out.finalization);
        out = DeploymentHelper.finalizeCommittedResults(cfg, out);
        _assertLaunchStorage(out, LibStakingLaunch.Phase.Finalized);
    }

    function testEveryPostShellCandidateMutationFailsTheCommitmentAndLeavesShellPristine() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(true);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        for (uint8 mutation; mutation < POST_SHELL_MUTATION_COUNT; ++mutation) {
            StakingLaunchTypes.Finalization memory mutated = this.mutateCommittedCandidate(out.finalization, mutation);
            assertNotEq(LibStakingLaunch.payloadHash(mutated), out.payloadHash);
            vm.expectRevert(StakingFinalizerFacet.StakingFinalizationCommitmentMismatch.selector);
            IStakingFinalizer(address(out.diamond)).finalizeStaking(mutated);
            _assertPristineShell(out);
        }

        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        out = DeploymentHelper.finalizeCommittedResults(cfg, out);
        _assertLaunchStorage(out, LibStakingLaunch.Phase.Finalized);
    }

    function testAllFirstPartySleeveTypesFinalizeWithExactTypedEvidence() external {
        TypedLaunchFixture memory fixture = _typedLaunchFixture();
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(fixture.cfg);
        out = DeploymentHelper.deployCommittedShellLocal(fixture.cfg, out);
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        out = DeploymentHelper.finalizeCommittedResults(fixture.cfg, out);

        _assertTypedSleeves(fixture, out);
        assertEq(FundManagerFacet(address(out.diamond)).swapAdapter(), address(fixture.fundManagerAdapter));

        // An unsolicited known-asset donation is observed by evidence but cannot censor it.
        fixture.core.mint(out.sleeves[0].sleeve, 7);
        string memory path = DeployParamsHelper.outPath(vm, "test-atomic-typed-sleeves.json");
        SleeveArtifactWriter.writeJson(vm, fixture.cfg, out, path);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory written = vm.readFile(path);
        _assertTypedSleeveEvidence(written, fixture, out);

        // A live valuation dependency may fail after a neutral finalization. Evidence remains
        // writable and records the failed observation instead of turning it into a launch veto.
        fixture.otherAsset.mint(out.sleeves[2].sleeve, 1);
        vm.mockCallRevert(
            address(fixture.controller),
            abi.encodeWithSelector(MockCygldBasketController.basketAssets.selector),
            abi.encode("valuation unavailable")
        );
        path = DeployParamsHelper.outPath(vm, "test-atomic-typed-sleeves-unhealthy.json");
        SleeveArtifactWriter.writeJson(vm, fixture.cfg, out, path);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        written = vm.readFile(path);
        bool[] memory healthy = vm.parseJsonBoolArray(written, ".observedSleeveTotalAssetsHealthy");
        uint256[] memory observed = vm.parseJsonUintArray(written, ".observedSleeveTotalAssets");
        assertFalse(healthy[2]);
        assertEq(observed[2], 0);
    }

    function testSleeveInvariantRejectsEveryTypedConfigurationMismatch() external {
        TypedLaunchFixture memory fixture = _typedLaunchFixture();
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(fixture.cfg);
        out = DeploymentHelper.deployCommittedShellLocal(fixture.cfg, out);
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        out = DeploymentHelper.finalizeCommittedResults(fixture.cfg, out);

        SleeveDeployerHelper.SleeveRequest memory request =
            abi.decode(abi.encode(fixture.cfg.sleeves[0]), (SleeveDeployerHelper.SleeveRequest));
        request.initArgs = abi.encode(address(0xBAD1));
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingSleeveInvariant.StakingSleeveInvariantViolation.selector, 0, out.sleeves[0].sleeve
            )
        );
        out.sleeveInvariant.requireSleeve(address(out.diamond), 0, out.sleeves[0].sleeve, request);

        request = abi.decode(abi.encode(fixture.cfg.sleeves[1]), (SleeveDeployerHelper.SleeveRequest));
        request.initArgs = abi.encode(address(0xBAD2));
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingSleeveInvariant.StakingSleeveInvariantViolation.selector, 1, out.sleeves[1].sleeve
            )
        );
        out.sleeveInvariant.requireSleeve(address(out.diamond), 1, out.sleeves[1].sleeve, request);

        request = abi.decode(abi.encode(fixture.cfg.sleeves[2]), (SleeveDeployerHelper.SleeveRequest));
        SleeveCurve.CurveLaunchParams memory curveParams = abi.decode(request.initArgs, (SleeveCurve.CurveLaunchParams));
        ++curveParams.maxLpTokens;
        request.initArgs = abi.encode(curveParams);
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingSleeveInvariant.StakingSleeveInvariantViolation.selector, 2, out.sleeves[2].sleeve
            )
        );
        out.sleeveInvariant.requireSleeve(address(out.diamond), 2, out.sleeves[2].sleeve, request);

        request = abi.decode(abi.encode(fixture.cfg.sleeves[2]), (SleeveDeployerHelper.SleeveRequest));
        curveParams = abi.decode(request.initArgs, (SleeveCurve.CurveLaunchParams));
        curveParams.rewardTokens[0] = address(0xBAD3);
        request.initArgs = abi.encode(curveParams);
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingSleeveInvariant.StakingSleeveInvariantViolation.selector, 2, out.sleeves[2].sleeve
            )
        );
        out.sleeveInvariant.requireSleeve(address(out.diamond), 2, out.sleeves[2].sleeve, request);
    }

    function testInvalidSafeRollsBackToCommittedShell() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(false);
        cfg.safeWallet = address(new EmptyDependency());
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        vm.expectRevert(abi.encodeWithSelector(PausableFacet.InvalidSafeWallet.selector, cfg.safeWallet));
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);

        vm.expectRevert(abi.encodeWithSelector(FunctionNotFound.selector, IDiamondLoupe.facets.selector));
        IDiamondLoupe(address(out.diamond)).facets();
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.InvalidSafeWallet.selector, cfg.safeWallet));
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
    }

    function testSleeveCallbackMutationRollsBackToCommittedShell() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(false);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveDeployerHelper.SleeveRequest({
            implementation: address(new CallbackSleeveImplementation()),
            asset: cfg.coreDiamond,
            approve: true,
            initialOperational: true,
            initialPaused: false,
            principalCap: 0,
            initType: SleeveDeployerHelper.InitType.Basic,
            initArgs: bytes("")
        });
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        vm.expectRevert();
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);

        vm.expectRevert(abi.encodeWithSelector(FunctionNotFound.selector, IDiamondLoupe.facets.selector));
        IDiamondLoupe(address(out.diamond)).facets();
        vm.expectRevert();
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
    }

    function testRecursiveFinalizerCallbackRollsBackAndExactRetrySucceeds() external {
        (DeploymentTypes.DeployConfig memory cfg, MockCyberGold core,) = _config(false);
        RecursiveFinalizerCallback callback = new RecursiveFinalizerCallback();
        cfg.sleeves[0] =
            _basicSleeve(address(new RecursiveFinalizerSleeveImplementation(callback)), address(core), true);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        address predictedSleeve = _predictedSleeve(cfg, out, 0);
        callback.configure(abi.encodeCall(IStakingFinalizer.finalizeStaking, (out.finalization)), true);

        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingDiamond.StakingMutationDuringFinalization.selector, IStakingFinalizer.finalizeStaking.selector
            )
        );
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        Vm.AccountAccess[] memory revertedAccesses = vm.stopAndReturnStateDiff();
        Vm.Log[] memory revertedTraceLogs = vm.getRecordedLogs();
        address[] memory revertedCreates = new address[](1);
        revertedCreates[0] = predictedSleeve;
        _assertAttemptFullyReverted(revertedAccesses, revertedTraceLogs, revertedCreates);
        assertEq(predictedSleeve.code.length, 0);
        _assertPristineShell(out);

        callback.setEnabled(false);
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        out = DeploymentHelper.finalizeCommittedResults(cfg, out);
        assertEq(out.sleeves[0].sleeve, predictedSleeve);
        _assertLaunchStorage(out, LibStakingLaunch.Phase.Finalized);
    }

    function testTransientFailureAtLaterSleeveRollsBackEarlierWorkAndExactRetrySucceeds() external {
        (DeploymentTypes.DeployConfig memory cfg, MockCyberGold core,) = _config(false);
        TransientFailureSwitch failureSwitch = new TransientFailureSwitch();
        failureSwitch.setShouldFail(true);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](2);
        cfg.sleeves[0] = _basicSleeve(address(new MockSleeve()), address(core), true);
        cfg.sleeves[1] =
            _basicSleeve(address(new TransientFailureSleeveImplementation(failureSwitch)), address(core), false);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        address firstPredicted = _predictedSleeve(cfg, out, 0);
        address secondPredicted = _predictedSleeve(cfg, out, 1);

        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.expectRevert(TransientFailureSleeveImplementation.TransientSleeveFailure.selector);
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        Vm.AccountAccess[] memory revertedAccesses = vm.stopAndReturnStateDiff();
        Vm.Log[] memory revertedTraceLogs = vm.getRecordedLogs();
        address[] memory revertedCreates = new address[](2);
        revertedCreates[0] = firstPredicted;
        revertedCreates[1] = secondPredicted;
        _assertAttemptFullyReverted(revertedAccesses, revertedTraceLogs, revertedCreates);
        assertTrue(_containsTopic(revertedTraceLogs, keccak256("PrincipalCapUpdated(uint256)")));
        assertEq(firstPredicted.code.length, 0);
        assertEq(secondPredicted.code.length, 0);
        _assertPristineShell(out);

        failureSwitch.setShouldFail(false);
        vm.recordLogs();
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        Vm.Log[] memory successfulLogs = vm.getRecordedLogs();
        assertGt(successfulLogs.length, 0);
        out = DeploymentHelper.finalizeCommittedResults(cfg, out);
        assertEq(out.sleeves[0].sleeve, firstPredicted);
        assertEq(out.sleeves[1].sleeve, secondPredicted);
        _assertLaunchStorage(out, LibStakingLaunch.Phase.Finalized);
    }

    function testEverySleeveIndexBeforeCreationFailureRollsBackAndExactRetrySucceeds() external {
        // "Before" is the implementation-codehash boundary immediately before CREATE2.
        // Each index is targeted independently so earlier creations must also roll back.
        for (uint256 index; index < FAILURE_MATRIX_SLEEVE_COUNT; ++index) {
            _assertBeforeSleeveCreationFailureAndRetry(index);
        }
    }

    function testEverySleeveIndexDuringCreationFailureRollsBackAndExactRetrySucceeds() external {
        // "During" is the proxy constructor's delegated Sleeve initializer. The same
        // committed relay is retried after clearing only the transient external switch.
        for (uint256 index; index < FAILURE_MATRIX_SLEEVE_COUNT; ++index) {
            _assertDuringSleeveCreationFailureAndRetry(index);
        }
    }

    function testEverySleeveIndexAfterCreationInvariantFailureRollsBackAndExactRetrySucceeds() external {
        // "After" is the per-index candidate-bound invariant immediately after CREATE2.
        // Registry initialization is later and cannot begin until every indexed check passes.
        for (uint256 index; index < FAILURE_MATRIX_SLEEVE_COUNT; ++index) {
            _assertAfterSleeveCreationFailureAndRetry(index);
        }
    }

    function testShellTokenDonationDoesNotBlockFinalizationOrCreateAccounting() external {
        (DeploymentTypes.DeployConfig memory cfg, MockCyberGold core, address governance) = _config(false);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        core.mint(address(out.diamond), 1);

        address relay = address(0xD057);
        vm.prank(relay);
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        out = DeploymentHelper.finalizeCommittedResults(cfg, out);

        assertEq(core.balanceOf(address(out.diamond)), 1);
        _assertDonationNeutralAccounting(cfg, out, core, governance, relay);
    }

    function testPrepareRejectsEmptyProductionRosters() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(true);
        cfg.allocators = new address[](0);
        vm.expectRevert(DeploymentHelper.StakingDeploymentEmptyAllocators.selector);
        this.prepareConfig(cfg);

        (cfg,,) = _config(true);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](0);
        vm.expectRevert(DeploymentHelper.StakingDeploymentEmptySleeves.selector);
        this.prepareConfig(cfg);
    }

    function testPrepareRejectsDuplicateSleeveRequestsAndIdentityCollisions() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(true);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](2);
        cfg.sleeves[0] = _basicSleeve(address(new MockSleeve()), cfg.coreDiamond, true);
        cfg.sleeves[1] = cfg.sleeves[0];
        vm.expectRevert(abi.encodeWithSelector(DeploymentHelper.StakingDeploymentDuplicateSleeve.selector, 0, 1));
        this.prepareConfig(cfg);

        (cfg,,) = _config(true);
        cfg.governanceDiamond = cfg.coreDiamond;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentHelper.StakingDeploymentIdentityCollision.selector, cfg.coreDiamond, cfg.governanceDiamond
            )
        );
        this.prepareConfig(cfg);

        (cfg,,) = _config(true);
        cfg.safeWallet = cfg.coreDiamond;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentHelper.StakingDeploymentIdentityCollision.selector, cfg.coreDiamond, cfg.safeWallet
            )
        );
        this.prepareConfig(cfg);

        (cfg,,) = _config(true);
        cfg.safeWallet = cfg.governanceDiamond;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentHelper.StakingDeploymentIdentityCollision.selector, cfg.governanceDiamond, cfg.safeWallet
            )
        );
        this.prepareConfig(cfg);
    }

    function testPrepareRejectsInvalidDependenciesRostersAndTypedSleeves() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(true);
        cfg.coreDiamond = address(0xC0DE);
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentHelper.StakingDeploymentInvalidDependency.selector, cfg.coreDiamond)
        );
        this.prepareConfig(cfg);

        (cfg,,) = _config(true);
        cfg.governanceDiamond = address(0x600D);
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentHelper.StakingDeploymentInvalidDependency.selector, cfg.governanceDiamond)
        );
        this.prepareConfig(cfg);

        (cfg,,) = _config(true);
        cfg.allocators[0] = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentHelper.StakingDeploymentInvalidAllocator.selector, 0, address(0))
        );
        this.prepareConfig(cfg);

        (cfg,,) = _config(true);
        cfg.allocators = new address[](2);
        cfg.allocators[0] = ALLOCATOR;
        cfg.allocators[1] = ALLOCATOR;
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentHelper.StakingDeploymentInvalidAllocator.selector, 1, ALLOCATOR)
        );
        this.prepareConfig(cfg);

        (cfg,,) = _config(true);
        cfg.withdrawers[0] = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentHelper.StakingDeploymentInvalidWithdrawer.selector, 0, address(0))
        );
        this.prepareConfig(cfg);

        (cfg,,) = _config(true);
        cfg.withdrawers = new address[](2);
        cfg.withdrawers[0] = WITHDRAWER;
        cfg.withdrawers[1] = WITHDRAWER;
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentHelper.StakingDeploymentInvalidWithdrawer.selector, 1, WITHDRAWER)
        );
        this.prepareConfig(cfg);

        (cfg,,) = _config(true);
        cfg.sleeves[0].implementation = address(0x51EE);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentHelper.StakingDeploymentInvalidSleeveImplementation.selector, 0, cfg.sleeves[0].implementation
            )
        );
        this.prepareConfig(cfg);

        (cfg,,) = _config(true);
        cfg.sleeves[0].implementation = address(new SleeveManual());
        cfg.sleeves[0].initType = SleeveDeployerHelper.InitType.Manual;
        cfg.sleeves[0].initArgs = hex"01";
        vm.expectRevert(SleeveDeployerHelper.SleeveInitDataNonCanonical.selector);
        this.prepareConfig(cfg);
    }

    function testPredictedShellIdentityCollisionsAreRejected() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentHelper.StakingDeploymentIdentityCollision.selector, cfg.coreDiamond, cfg.coreDiamond
            )
        );
        this.requireDistinctLaunchIdentities(cfg, cfg.coreDiamond);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentHelper.StakingDeploymentIdentityCollision.selector,
                cfg.governanceDiamond,
                cfg.governanceDiamond
            )
        );
        this.requireDistinctLaunchIdentities(cfg, cfg.governanceDiamond);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentHelper.StakingDeploymentIdentityCollision.selector, cfg.safeWallet, cfg.safeWallet
            )
        );
        this.requireDistinctLaunchIdentities(cfg, cfg.safeWallet);
    }

    function testCommittedInvalidAllocatorRollsBackCommittedShell() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(true);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out.finalization.initializerCalldata =
            this.mutateInitializerAllocator(out.finalization.initializerCalldata, address(0));
        out.payloadHash = LibStakingLaunch.payloadHash(out.finalization);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        vm.expectRevert(abi.encodeWithSelector(DiamondInit.StakingInitInvalidAllocator.selector, 0, address(0)));
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        _assertPristineShell(out);
    }

    function testGovernanceSafeOwnerOverlapRollsBackCommittedShell() external {
        (DeploymentTypes.DeployConfig memory cfg,, address governance) = _config(true);
        cfg.safeWallet = MockSafeWalletFactory.deploy(governance);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        vm.expectRevert(abi.encodeWithSelector(DiamondInit.StakingInitGovernanceIsSafeOwner.selector, governance));
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        _assertPristineShell(out);
    }

    function testCommittedZeroSleeveBaseSaltRollsBackCommittedShell() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(true);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out.finalization.initializerCalldata = this.mutateInitializerSleeves(out.finalization.initializerCalldata, 0);
        out.payloadHash = LibStakingLaunch.payloadHash(out.finalization);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        vm.expectRevert(abi.encodeWithSelector(DiamondInit.StakingInitInvalidSleeveSalt.selector, 0, bytes32(0)));
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        _assertPristineShell(out);
    }

    function testCommittedDuplicateSleeveBaseSaltRollsBackCommittedShell() external {
        (DeploymentTypes.DeployConfig memory cfg, MockCyberGold core,) = _config(true);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](2);
        cfg.sleeves[0] = _basicSleeve(address(new MockSleeve()), address(core), true);
        cfg.sleeves[1] = _basicSleeve(address(new MockSleeve()), address(core), false);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out.finalization.initializerCalldata = this.mutateInitializerSleeves(out.finalization.initializerCalldata, 1);
        out.payloadHash = LibStakingLaunch.payloadHash(out.finalization);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        DiamondInit.InitConfig memory initCfg = this.decodeInitializer(out.finalization.initializerCalldata);

        vm.expectRevert(
            abi.encodeWithSelector(DiamondInit.StakingInitDuplicateSleeveSalt.selector, 0, 1, initCfg.sleeves[0].salt)
        );
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        _assertPristineShell(out);
    }

    function testCommittedDuplicateSleeveRequestRollsBackCommittedShell() external {
        (DeploymentTypes.DeployConfig memory cfg, MockCyberGold core,) = _config(true);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](2);
        cfg.sleeves[0] = _basicSleeve(address(new MockSleeve()), address(core), true);
        cfg.sleeves[1] = _basicSleeve(address(new MockSleeve()), address(core), false);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out.finalization.initializerCalldata = this.mutateInitializerSleeves(out.finalization.initializerCalldata, 2);
        out.payloadHash = LibStakingLaunch.payloadHash(out.finalization);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        vm.expectRevert(abi.encodeWithSelector(DiamondInit.StakingInitDuplicateSleeve.selector, 0, 1));
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        _assertPristineShell(out);
    }

    function testTransientLateAuthorityInvariantFailureRollsBackSleevesRolesAndExactRetrySucceeds() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(true);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        address predictedSleeve = _predictedSleeve(cfg, out, 0);
        bytes memory invariantCall = abi.encodeCall(
            StakingAuthorityInvariant.requireNoCriticalAuthority,
            (address(out.diamond), cfg.governanceDiamond, cfg.safeWallet)
        );
        vm.mockCallRevert(
            address(out.authorityInvariant),
            invariantCall,
            abi.encodeWithSelector(StakingAuthorityInvariant.StakingCriticalAuthorityInvariant.selector)
        );

        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.expectRevert(StakingAuthorityInvariant.StakingCriticalAuthorityInvariant.selector);
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        Vm.AccountAccess[] memory revertedAccesses = vm.stopAndReturnStateDiff();
        Vm.Log[] memory revertedTraceLogs = vm.getRecordedLogs();
        address[] memory revertedCreates = new address[](1);
        revertedCreates[0] = predictedSleeve;
        _assertAttemptFullyReverted(revertedAccesses, revertedTraceLogs, revertedCreates);
        assertTrue(_containsTopic(revertedTraceLogs, keccak256("SleeveRegistered(address,address)")));
        assertTrue(_containsTopic(revertedTraceLogs, keccak256("RoleGranted(bytes32,address,address)")));
        assertEq(predictedSleeve.code.length, 0);
        _assertPristineShell(out);

        vm.clearMockedCalls();
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        out = DeploymentHelper.finalizeCommittedResults(cfg, out);
        assertEq(out.sleeves[0].sleeve, predictedSleeve);
        (, bytes32 finalizationHash) = LensFacet(address(out.diamond)).stakingLaunchState();
        assertEq(finalizationHash, out.payloadHash);
    }

    function testChainDomainGuardAndForcedEtherDonationStillFinalizes() external {
        (DeploymentTypes.DeployConfig memory cfg, MockCyberGold core, address governance) = _config(true);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        address predictedShell = DeploymentHelper.predictedShell(cfg, out);
        vm.deal(address(this), 1);
        ForcedEtherSender sender = new ForcedEtherSender{value: 1}();
        sender.force(payable(predictedShell));
        assertEq(predictedShell.balance, 1);

        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        address shell = address(out.diamond);
        assertEq(shell, predictedShell);
        assertEq(shell.balance, 1);
        uint256 originalChainId = block.chainid;
        bytes32 expectedCommitment = LibStakingLaunch.commitmentFor(originalChainId, shell, out.payloadHash);
        assertEq(vm.load(shell, bytes32(uint256(STAKING_LAUNCH_STORAGE_SLOT) + 1)), expectedCommitment);

        vm.chainId(originalChainId + 1);
        vm.expectRevert(StakingFinalizerFacet.StakingFinalizationCommitmentMismatch.selector);
        IStakingFinalizer(shell).finalizeStaking(out.finalization);
        vm.chainId(originalChainId);
        _assertPristineShell(out);

        address relay = address(0xD057);
        vm.prank(relay);
        IStakingFinalizer(shell).finalizeStaking(out.finalization);
        out = DeploymentHelper.finalizeCommittedResults(cfg, out);
        assertEq(shell.balance, 1);
        _assertDonationNeutralAccounting(cfg, out, core, governance, relay);
    }

    function testCounterfactualSleeveDonationDoesNotBlockOrCreatePrincipal() external {
        (DeploymentTypes.DeployConfig memory cfg, MockCyberGold core, address governance) = _config(true);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](2);
        cfg.sleeves[0] = _basicSleeve(address(new MockSleeve()), address(core), true);
        cfg.sleeves[1] = _basicSleeve(address(new MockSleeve()), address(core), false);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        address first = _predictedSleeve(cfg, out, 0);
        address second = _predictedSleeve(cfg, out, 1);
        core.mint(second, 1);

        address relay = address(0xD057);
        vm.prank(relay);
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        out = DeploymentHelper.finalizeCommittedResults(cfg, out);
        assertEq(out.sleeves.length, 2);
        assertEq(out.sleeves[0].sleeve, first);
        assertEq(out.sleeves[1].sleeve, second);
        assertGt(first.code.length, 0);
        assertGt(second.code.length, 0);
        assertEq(core.balanceOf(first), 0);
        assertEq(core.balanceOf(second), 1);
        _assertDonationNeutralAccounting(cfg, out, core, governance, relay);
    }

    function testCounterfactualCurveOtherAssetDonationDoesNotBlockFinalization() external {
        (DeploymentTypes.DeployConfig memory cfg, MockCyberGold core, address governance) = _config(false);
        MockCyberGold otherAsset = new MockCyberGold();
        MockCurvePool poolToken = new MockCurvePool(address(core), address(otherAsset));
        address[] memory basket = new address[](1);
        basket[0] = address(otherAsset);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1_000_000;
        uint256[] memory conversions = new uint256[](1);
        conversions[0] = 1e18;
        MockCygldBasketController controller =
            new MockCygldBasketController(address(core), basket, weights, conversions);
        SleeveCurve.CurveInitParams memory params = SleeveCurve.CurveInitParams({
            otherAsset: address(otherAsset),
            pool: address(poolToken),
            underlyingIndex: 0,
            otherIndex: 1,
            otherSharePpm: 500_000,
            gauge: address(0),
            priceReference: 0,
            maxPriceDeviationBps: 0,
            cygldController: address(controller),
            basketSwapAdapter: address(0)
        });
        cfg.sleeves[0] = SleeveDeployerHelper.SleeveRequest({
            implementation: address(new SleeveCurve()),
            asset: address(core),
            approve: true,
            initialOperational: true,
            initialPaused: false,
            principalCap: 1_000 ether,
            initType: SleeveDeployerHelper.InitType.Curve,
            initArgs: abi.encode(
                SleeveCurve.CurveLaunchParams({
                    venue: params, maxLpTokens: 0, rewardSwapAdapter: address(0), rewardTokens: new address[](0)
                })
            )
        });
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        address predicted = _predictedSleeve(cfg, out, 0);
        otherAsset.mint(predicted, 1);

        address relay = address(0xD057);
        vm.prank(relay);
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        out = DeploymentHelper.finalizeCommittedResults(cfg, out);
        assertEq(out.sleeves[0].sleeve, predicted);
        assertEq(otherAsset.balanceOf(predicted), 1);
        _assertDonationNeutralAccounting(cfg, out, core, governance, relay);
    }

    function testSelfReplacingSleeveImplementationRollsBackCommittedShell() external {
        (DeploymentTypes.DeployConfig memory cfg, MockCyberGold core,) = _config(false);
        MockSleeve replacement = new MockSleeve();
        SelfReplacingSleeveImplementation candidate = new SelfReplacingSleeveImplementation(address(replacement));
        cfg.sleeves[0] = _basicSleeve(address(candidate), address(core), true);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        address predicted = _predictedSleeve(cfg, out, 0);

        vm.expectRevert(
            abi.encodeWithSelector(StakingSleeveInvariant.StakingSleeveInvariantViolation.selector, 0, predicted)
        );
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        assertEq(predicted.code.length, 0);
        _assertPristineShell(out);
    }

    function testCommittedWrongInitializerSelectorIsRejectedBeforeCut() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(false);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out.finalization.initializerCalldata[0] = bytes1(uint8(out.finalization.initializerCalldata[0]) ^ 1);
        out.payloadHash = LibStakingLaunch.payloadHash(out.finalization);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        vm.expectRevert(StakingFinalizerFacet.StakingFinalizationInvalidInitializerCalldata.selector);
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        _assertPristineShell(out);
    }

    function testNonCanonicalOuterFinalizationCalldataIsRejectedBeforeCut() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(false);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        bytes memory canonical = abi.encodeCall(IStakingFinalizer.finalizeStaking, (out.finalization));
        (bool ok, bytes memory returndata) = address(out.diamond).call(bytes.concat(canonical, hex"00"));
        assertFalse(ok);
        assertEq(
            returndata, abi.encodeWithSelector(StakingFinalizerFacet.StakingFinalizationInvalidRelayCalldata.selector)
        );
        _assertPristineShell(out);

        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        out = DeploymentHelper.finalizeCommittedResults(cfg, out);
        (LibStakingLaunch.Phase phase,) = LensFacet(address(out.diamond)).stakingLaunchState();
        assertEq(uint8(phase), uint8(LibStakingLaunch.Phase.Finalized));
    }

    function testCommittedReorderedProductionSelectorsRollsBackCommittedShell() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(false);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        bool reordered;
        bytes4 expectedSelector;
        bytes4 actualSelector;
        uint256 selectorCursor;
        for (uint256 i = 1; i < out.finalization.diamondCut.length; ++i) {
            bytes4[] memory selectors = out.finalization.diamondCut[i].functionSelectors;
            if (selectors.length < 2) {
                selectorCursor += selectors.length;
                continue;
            }
            expectedSelector = selectors[0];
            actualSelector = selectors[1];
            (selectors[0], selectors[1]) = (selectors[1], selectors[0]);
            reordered = true;
            break;
        }
        assertTrue(reordered);
        out.payloadHash = LibStakingLaunch.payloadHash(out.finalization);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        vm.expectRevert(
            abi.encodeWithSelector(
                StakingInterfaceInit.StakingInitSelectorOrderMismatch.selector,
                selectorCursor,
                expectedSelector,
                actualSelector
            )
        );
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        _assertPristineShell(out);
    }

    function testCommittedAlternateFacetCutIsRejectedAndRollsBack() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(false);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        address expectedOwner = out.finalization.diamondCut[1].facetAddress;
        address alternateOwner = out.finalization.diamondCut[2].facetAddress;
        bytes4 selector = out.finalization.diamondCut[1].functionSelectors[0];
        out.finalization.diamondCut[1].facetAddress = alternateOwner;
        out.payloadHash = LibStakingLaunch.payloadHash(out.finalization);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        vm.expectRevert(
            abi.encodeWithSelector(
                StakingInterfaceInit.StakingInitSelectorOwnerMismatch.selector, selector, expectedOwner, alternateOwner
            )
        );
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        _assertPristineShell(out);
    }

    function testCommittedIntermediateCutIsRejectedAndRollsBack() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(false);
        cfg.shellSalt = keccak256("staking-atomic-intermediate-cut");
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        IDiamond.FacetCut[] memory intermediateCut = new IDiamond.FacetCut[](2);
        intermediateCut[0] = out.finalization.diamondCut[0];
        intermediateCut[1] = out.finalization.diamondCut[1];
        out.finalization.diamondCut = intermediateCut;
        out.payloadHash = LibStakingLaunch.payloadHash(out.finalization);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        vm.expectRevert();
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        _assertPristineShell(out);
    }

    function testCommittedUnboundInitDependencyIsRejectedBeforeCut() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(false);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        StakingInterfaceInit alternate = new StakingInterfaceInit();
        uint256 index = out.finalization.facets.length - 1;
        out.finalization.facets[index] = StakingLaunchTypes.FacetExpectation({
            facet: address(alternate),
            runtimeCodeHash: address(alternate).codehash,
            namespace: alternate.FACET_NAMESPACE()
        });
        out.payloadHash = LibStakingLaunch.payloadHash(out.finalization);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        vm.expectRevert(
            abi.encodeWithSelector(
                StakingFinalizerFacet.StakingFinalizationInvalidFacet.selector, address(out.interfaceInit)
            )
        );
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        _assertPristineShell(out);
    }

    function testCommittedUnboundSleeveInvariantIsRejectedBeforeCut() external {
        (DeploymentTypes.DeployConfig memory cfg,,) = _config(false);
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        StakingSleeveInvariant alternate = new StakingSleeveInvariant();
        uint256 index = out.finalization.facets.length - 2;
        out.finalization.facets[index] = StakingLaunchTypes.FacetExpectation({
            facet: address(alternate),
            runtimeCodeHash: address(alternate).codehash,
            namespace: alternate.FACET_NAMESPACE()
        });
        out.payloadHash = LibStakingLaunch.payloadHash(out.finalization);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);

        vm.expectRevert(
            abi.encodeWithSelector(
                StakingFinalizerFacet.StakingFinalizationInvalidFacet.selector, address(out.sleeveInvariant)
            )
        );
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        _assertPristineShell(out);
    }

    function _typedLaunchFixture() private returns (TypedLaunchFixture memory fixture) {
        (fixture.cfg, fixture.core,) = _config(false);
        fixture.manualOperator = address(0x0B0B);
        fixture.vault = new MockVault4626(fixture.core);
        fixture.otherAsset = new MockCyberGold();
        fixture.pool = new MockCurvePool(address(fixture.core), address(fixture.otherAsset));
        fixture.gauge = new MockCurveGauge(IERC20(address(fixture.pool)));
        fixture.rewardAdapter = new MockSwapAdapter();
        fixture.basketAdapter = new MockSwapAdapter();
        fixture.fundManagerAdapter = new MockSwapAdapter();
        fixture.rewardToken = address(new MockCyberGold());

        address[] memory basket = new address[](1);
        basket[0] = address(fixture.otherAsset);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1_000_000;
        uint256[] memory conversions = new uint256[](1);
        conversions[0] = 1e18;
        fixture.controller = new MockCygldBasketController(address(fixture.core), basket, weights, conversions);

        SleeveCurve.CurveInitParams memory venue = SleeveCurve.CurveInitParams({
            otherAsset: address(fixture.otherAsset),
            pool: address(fixture.pool),
            underlyingIndex: 0,
            otherIndex: 1,
            otherSharePpm: 400_000,
            gauge: address(fixture.gauge),
            priceReference: 1e18,
            maxPriceDeviationBps: 500,
            cygldController: address(fixture.controller),
            basketSwapAdapter: address(fixture.basketAdapter)
        });
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = fixture.rewardToken;
        SleeveCurve.CurveLaunchParams memory curveParams = SleeveCurve.CurveLaunchParams({
            venue: venue,
            maxLpTokens: 404 ether,
            rewardSwapAdapter: address(fixture.rewardAdapter),
            rewardTokens: rewardTokens
        });

        fixture.cfg.fundManagerSwapAdapter = address(fixture.fundManagerAdapter);
        fixture.cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](3);
        fixture.cfg.sleeves[0] = SleeveRequestBuilder.manualWithState(
            address(new SleeveManual()), address(fixture.core), fixture.manualOperator, true, 101 ether, false, true
        );
        fixture.cfg.sleeves[1] = SleeveRequestBuilder.erc4626WithState(
            address(new Sleeve4626()), address(fixture.core), address(fixture.vault), false, 202 ether, true, false
        );
        fixture.cfg.sleeves[2] = SleeveRequestBuilder.curveLaunch(
            address(new SleeveCurve()), address(fixture.core), curveParams, true, 303 ether, true, true
        );
    }

    function _assertTypedSleeves(TypedLaunchFixture memory fixture, DeploymentTypes.DeployArtifacts memory out)
        private
        view
    {
        assertEq(out.sleeves.length, 3);
        SleeveManual manual = SleeveManual(out.sleeves[0].sleeve);
        assertEq(manual.operator(), fixture.manualOperator);
        assertEq(manual.principalCap(), 101 ether);
        assertFalse(manual.operational());
        assertTrue(manual.paused());

        Sleeve4626 erc4626 = Sleeve4626(out.sleeves[1].sleeve);
        assertEq(address(erc4626.vault()), address(fixture.vault));
        assertEq(erc4626.principalCap(), 202 ether);
        assertTrue(erc4626.operational());
        assertFalse(erc4626.paused());

        SleeveCurve curve = SleeveCurve(out.sleeves[2].sleeve);
        assertEq(address(curve.otherAsset()), address(fixture.otherAsset));
        assertEq(address(curve.curvePool()), address(fixture.pool));
        assertEq(address(curve.lpToken()), address(fixture.pool));
        assertEq(curve.underlyingIndex(), 0);
        assertEq(curve.otherIndex(), 1);
        assertEq(curve.targetOtherPpm(), 400_000);
        assertEq(address(curve.gauge()), address(fixture.gauge));
        assertEq(curve.maxLpTokens(), 404 ether);
        assertEq(curve.priceReference(), 1e18);
        assertEq(curve.maxPriceDeviationBps(), 500);
        assertEq(curve.rewardSwapAdapter(), address(fixture.rewardAdapter));
        assertEq(address(curve.cygldController()), address(fixture.controller));
        assertEq(curve.basketSwapAdapter(), address(fixture.basketAdapter));
        assertEq(curve.principalCap(), 303 ether);
        assertTrue(curve.operational());
        assertTrue(curve.paused());
        address[] memory rewards = curve.rewardTokens();
        assertEq(rewards.length, 1);
        assertEq(rewards[0], fixture.rewardToken);

        for (uint256 i; i < out.sleeves.length; ++i) {
            address sleeve = out.sleeves[i].sleeve;
            assertEq(ISleeveProxy(sleeve).implementation(), fixture.cfg.sleeves[i].implementation);
            assertEq(
                address(uint160(uint256(vm.load(sleeve, ERC1967_IMPLEMENTATION_SLOT)))),
                fixture.cfg.sleeves[i].implementation
            );
            assertEq(ISleeve(sleeve).principalAssets(), 0);
        }
    }

    function _assertTypedSleeveEvidence(
        string memory written,
        TypedLaunchFixture memory fixture,
        DeploymentTypes.DeployArtifacts memory out
    ) private view {
        address[] memory values = vm.parseJsonAddressArray(written, ".manualOperators");
        assertEq(values[0], fixture.manualOperator);
        values = vm.parseJsonAddressArray(written, ".erc4626Vaults");
        assertEq(values[1], address(fixture.vault));
        values = vm.parseJsonAddressArray(written, ".curvePools");
        assertEq(values[2], address(fixture.pool));
        values = vm.parseJsonAddressArray(written, ".curveLpTokens");
        assertEq(values[2], address(fixture.pool));
        values = vm.parseJsonAddressArray(written, ".curveRewardSwapAdapters");
        assertEq(values[2], address(fixture.rewardAdapter));
        values = vm.parseJsonAddressArray(written, ".curveCygldControllers");
        assertEq(values[2], address(fixture.controller));
        values = vm.parseJsonAddressArray(written, ".curveBasketSwapAdapters");
        assertEq(values[2], address(fixture.basketAdapter));

        uint256[] memory uints = vm.parseJsonUintArray(written, ".curveMaxLpTokens");
        assertEq(uints[2], 404 ether);
        uints = vm.parseJsonUintArray(written, ".curvePriceReferences");
        assertEq(uints[2], 1e18);
        uints = vm.parseJsonUintArray(written, ".curveMaxPriceDeviationBps");
        assertEq(uints[2], 500);
        uints = vm.parseJsonUintArray(written, ".observedSleeveTotalAssets");
        assertEq(uints[0], 7);
        bool[] memory flags = vm.parseJsonBoolArray(written, ".observedSleeveTotalAssetsHealthy");
        assertTrue(flags[0]);
        flags = vm.parseJsonBoolArray(written, ".requestedOperational");
        assertFalse(flags[0]);
        assertTrue(flags[1]);
        flags = vm.parseJsonBoolArray(written, ".requestedLocalPaused");
        assertTrue(flags[0]);
        assertFalse(flags[1]);
        assertTrue(flags[2]);

        bytes[] memory rewardLists = vm.parseJsonBytesArray(written, ".curveRewardTokens");
        address[] memory rewards = abi.decode(rewardLists[2], (address[]));
        assertEq(rewards.length, 1);
        assertEq(rewards[0], fixture.rewardToken);
        bytes32[] memory committed = vm.parseJsonBytes32Array(written, ".committedImplementationCodeHashes");
        bytes32[] memory observed = vm.parseJsonBytes32Array(written, ".observedImplementationCodeHashes");
        for (uint256 i; i < out.sleeves.length; ++i) {
            assertEq(committed[i], fixture.cfg.sleeves[i].implementation.codehash);
            assertEq(observed[i], committed[i]);
        }
    }

    function _config(bool withSleeve)
        private
        returns (DeploymentTypes.DeployConfig memory cfg, MockCyberGold core, address governance)
    {
        core = new MockCyberGold();
        governance = address(new GovernanceExecutor());
        cfg.safeWallet = MockSafeWalletFactory.deploy(SAFE_OWNER);
        cfg.name = "Staked CyberGold";
        cfg.symbol = "sCYGLD";
        cfg.coreDiamond = address(core);
        cfg.governanceDiamond = governance;
        cfg.withdrawers = new address[](1);
        cfg.withdrawers[0] = WITHDRAWER;
        cfg.allocators = new address[](1);
        cfg.allocators[0] = ALLOCATOR;
        cfg.claimExpiry = 7 days;
        cfg.headSweepLimit = 32;
        cfg.autoProcessMax = 16;
        cfg.performanceFeePpm = 100_000;
        cfg.create2Deployer = address(this);
        cfg.shellSalt = keccak256("staking-atomic-launch-test");
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveDeployerHelper.SleeveRequest({
            implementation: address(new MockSleeve()),
            asset: address(core),
            approve: withSleeve,
            initialOperational: true,
            initialPaused: false,
            principalCap: 1_000 ether,
            initType: SleeveDeployerHelper.InitType.Basic,
            initArgs: bytes("")
        });
    }

    function _assertPristineShell(DeploymentTypes.DeployArtifacts memory out) private view {
        address shell = address(out.diamond);
        _assertLaunchStorage(out, LibStakingLaunch.Phase.Committed);
        bytes32 selectorLengthSlot = bytes32(uint256(DIAMOND_STORAGE_POSITION) + 1);
        bytes32 ownerSlot = bytes32(uint256(DIAMOND_STORAGE_POSITION) + 3);
        bytes32 finalizerSlot =
            keccak256(abi.encode(IStakingFinalizer.finalizeStaking.selector, DIAMOND_STORAGE_POSITION));
        assertEq(uint256(vm.load(shell, selectorLengthSlot)), 1);
        assertEq(address(uint160(uint256(vm.load(shell, ownerSlot)))), address(0));
        assertEq(address(uint160(uint256(vm.load(shell, finalizerSlot)))), address(out.facets.finalizer));
    }

    function prepareConfig(DeploymentTypes.DeployConfig memory cfg) external returns (bytes32 payloadHash) {
        return DeploymentHelper.prepare(cfg).payloadHash;
    }

    function requireDistinctLaunchIdentities(DeploymentTypes.DeployConfig memory cfg, address predicted) external pure {
        DeploymentHelper.requireDistinctLaunchIdentities(cfg, predicted);
    }

    function mutateCommittedCandidate(StakingLaunchTypes.Finalization calldata candidate, uint8 mutation)
        external
        pure
        returns (StakingLaunchTypes.Finalization memory mutated)
    {
        mutated = abi.decode(abi.encode(candidate), (StakingLaunchTypes.Finalization));
        if (mutation == 0) {
            mutated.facets[0].runtimeCodeHash ^= bytes32(uint256(1));
            return mutated;
        }
        if (mutation == 1) {
            mutated.initializer = address(0x1111);
            return mutated;
        }
        if (mutation == 2) {
            mutated.initializerCodeHash ^= bytes32(uint256(1));
            return mutated;
        }
        if (mutation == 3) {
            mutated.initializerCalldata = bytes.concat(mutated.initializerCalldata, hex"00");
            return mutated;
        }

        (DiamondInit.InitConfig memory cfg, string memory name_, string memory symbol_) =
            abi.decode(candidate.initializerCalldata[4:], (DiamondInit.InitConfig, string, string));
        if (mutation == 4) {
            cfg.safeWallet = address(0x1004);
        } else if (mutation == 5) {
            cfg.coreDiamond = address(0x1005);
        } else if (mutation == 6) {
            cfg.governanceDiamond = address(0x1006);
        } else if (mutation == 7) {
            cfg.withdrawers[0] = address(0x1007);
        } else if (mutation == 8) {
            cfg.allocators[0] = address(0x1008);
        } else if (mutation == 9) {
            ++cfg.claimExpiry;
        } else if (mutation == 10) {
            ++cfg.headSweepLimit;
        } else if (mutation == 11) {
            ++cfg.autoProcessMax;
        } else if (mutation == 12) {
            ++cfg.performanceFeePpm;
        } else if (mutation == 13) {
            cfg.fundManagerSwapAdapter = address(0x1013);
        } else if (mutation == 14) {
            name_ = string.concat(name_, " mutated");
        } else if (mutation == 15) {
            symbol_ = string.concat(symbol_, "X");
        } else if (mutation == 16) {
            cfg.sleeves[0].request.implementation = address(0x1016);
        } else if (mutation == 17) {
            cfg.sleeves[0].implementationCodeHash ^= bytes32(uint256(1));
        } else if (mutation == 18) {
            cfg.sleeves[0].request.asset = address(0x1018);
        } else if (mutation == 19) {
            ++cfg.sleeves[0].request.principalCap;
        } else if (mutation == 20) {
            cfg.sleeves[0].request.approve = !cfg.sleeves[0].request.approve;
        } else if (mutation == 21) {
            cfg.sleeves[0].request.initialOperational = !cfg.sleeves[0].request.initialOperational;
        } else if (mutation == 22) {
            cfg.sleeves[0].request.initialPaused = !cfg.sleeves[0].request.initialPaused;
        } else if (mutation == 23) {
            cfg.sleeves[0].request.initType = SleeveDeployerHelper.InitType.Manual;
        } else if (mutation == 24) {
            cfg.sleeves[0].request.initArgs = abi.encode(address(0x1024));
        } else if (mutation == 25) {
            cfg.sleeves[0].salt ^= bytes32(uint256(1));
        } else if (mutation == 26) {
            // FacetExpectation.facet.
            mutated.facets[0].facet = address(0x1026);
            return mutated;
        } else if (mutation == 27) {
            // FacetExpectation.namespace.
            mutated.facets[0].namespace ^= bytes32(uint256(1));
            return mutated;
        } else if (mutation == 28) {
            // A second independent FacetExpectation.runtimeCodeHash mutation.
            mutated.facets[0].runtimeCodeHash ^= bytes32(uint256(2));
            return mutated;
        } else if (mutation == 29) {
            // FacetCut selector value.
            mutated.diamondCut[0].functionSelectors[0] ^= bytes4(uint32(1));
            return mutated;
        } else if (mutation == 30) {
            // FacetCut selector order within one production facet.
            for (uint256 i = 1; i < mutated.diamondCut.length; ++i) {
                if (mutated.diamondCut[i].functionSelectors.length < 2) continue;
                (mutated.diamondCut[i].functionSelectors[0], mutated.diamondCut[i].functionSelectors[1]) =
                (mutated.diamondCut[i].functionSelectors[1], mutated.diamondCut[i].functionSelectors[0]);
                return mutated;
            }
            revert("missing reorderable cut");
        } else if (mutation == 31) {
            // FacetCut selector owner.
            mutated.diamondCut[1].facetAddress = address(0x1031);
            return mutated;
        } else if (mutation == 32) {
            // FacetCut action (production cuts are Add).
            mutated.diamondCut[1].action = IDiamond.FacetCutAction.Replace;
            return mutated;
        } else {
            revert("unknown post-shell mutation");
        }
        mutated.initializerCalldata = abi.encodeWithSelector(DiamondInit.finalize.selector, cfg, name_, symbol_);
    }

    function decodeInitializer(bytes calldata initializerCalldata)
        external
        pure
        returns (DiamondInit.InitConfig memory cfg)
    {
        (cfg,,) = abi.decode(initializerCalldata[4:], (DiamondInit.InitConfig, string, string));
    }

    function mutateInitializerSleeves(bytes calldata initializerCalldata, uint8 mutation)
        external
        pure
        returns (bytes memory)
    {
        (DiamondInit.InitConfig memory cfg, string memory name_, string memory symbol_) =
            abi.decode(initializerCalldata[4:], (DiamondInit.InitConfig, string, string));
        if (mutation == 0) {
            cfg.sleeves[0].salt = bytes32(0);
        } else if (mutation == 1) {
            cfg.sleeves[1].salt = cfg.sleeves[0].salt;
        } else {
            cfg.sleeves[1].request = cfg.sleeves[0].request;
        }
        return abi.encodeWithSelector(DiamondInit.finalize.selector, cfg, name_, symbol_);
    }

    function mutateInitializerAllocator(bytes calldata initializerCalldata, address allocator)
        external
        pure
        returns (bytes memory)
    {
        (DiamondInit.InitConfig memory cfg, string memory name_, string memory symbol_) =
            abi.decode(initializerCalldata[4:], (DiamondInit.InitConfig, string, string));
        cfg.allocators[0] = allocator;
        return abi.encodeWithSelector(DiamondInit.finalize.selector, cfg, name_, symbol_);
    }

    function _assertFinalizedLaunch(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory out,
        MockCyberGold core,
        address governance,
        address relay
    ) private view {
        address staking = address(out.diamond);
        _assertLaunchStorage(out, LibStakingLaunch.Phase.Finalized);
        bytes32 upgraderRole = DefaultAdminAccessControlFacet(staking).upgraderRole();
        assertEq(IAccessControlDefaultAdminRules(staking).defaultAdmin(), governance);
        assertTrue(IAccessControl(staking).hasRole(bytes32(0), governance));
        assertTrue(IAccessControl(staking).hasRole(upgraderRole, governance));
        _assertNoCriticalRole(staking, cfg.safeWallet, upgraderRole);
        _assertNoCriticalRole(staking, address(this), upgraderRole);
        _assertNoCriticalRole(staking, relay, upgraderRole);
        assertTrue(PausableFacet(staking).paused());
        assertEq(IDiamondEmergencyAuthority(staking).safeWallet(), cfg.safeWallet);
        assertTrue(IDiamondEmergencyAuthority(staking).canPause(SAFE_OWNER));
        assertTrue(IDiamondEmergencyAuthority(staking).canUnpause(cfg.safeWallet));
        assertFalse(IDiamondEmergencyAuthority(staking).canUnpause(SAFE_OWNER));
        assertEq(VaultFacet(staking).totalSupply(), 0);
        assertEq(core.balanceOf(staking), 0);

        (LibStakingLaunch.Phase phase, bytes32 finalizationHash) = LensFacet(staking).stakingLaunchState();
        assertEq(uint8(phase), uint8(LibStakingLaunch.Phase.Finalized));
        assertEq(finalizationHash, out.payloadHash);
        assertEq(out.sleeves.length, 1);
        address sleeve = out.sleeves[0].sleeve;
        assertGt(sleeve.code.length, 0);
        assertEq(MockSleeve(sleeve).stakingDiamond(), staking);
        assertEq(MockSleeve(sleeve).asset(), address(core));
        assertEq(MockSleeve(sleeve).principalAssets(), 0);
        address[] memory registered = SleeveRegistryFacet(staking).sleeves();
        assertEq(registered.length, 1);
        assertEq(registered[0], sleeve);
        LibAppStorage.SleeveConfig memory sleeveCfg = SleeveRegistryFacet(staking).sleeveConfig(sleeve);
        assertTrue(sleeveCfg.registered);
        assertTrue(sleeveCfg.approved);
        assertEq(sleeveCfg.asset, address(core));
        _assertFinalAuthoritySurface(cfg, out, governance);
        _assertInitOnlyRuntimeUnregistered(staking, out.facets.reentrancy.FACET_NAMESPACE());
        _assertInitOnlyRuntimeUnregistered(staking, out.authorityInvariant.FACET_NAMESPACE());
        _assertInitOnlyRuntimeUnregistered(staking, out.sleeveInvariant.FACET_NAMESPACE());
        _assertInitOnlyRuntimeUnregistered(staking, out.interfaceInit.FACET_NAMESPACE());
    }

    function _assertInitOnlyRuntimeUnregistered(address staking, bytes32 namespace) internal view {
        bytes32 generationSlot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
        assertEq(uint256(vm.load(staking, generationSlot)), 0);
    }

    function _assertDonationNeutralAccounting(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory out,
        MockCyberGold core,
        address governance,
        address relay
    ) private view {
        address staking = address(out.diamond);
        _assertLaunchStorage(out, LibStakingLaunch.Phase.Finalized);
        assertEq(VaultFacet(staking).totalSupply(), 0);
        assertEq(VaultFacet(staking).balanceOf(address(this)), 0);
        assertEq(VaultFacet(staking).balanceOf(relay), 0);
        assertEq(LensFacet(staking).headId(), 0);
        assertEq(LensFacet(staking).tailId(), 0);
        assertEq(LensFacet(staking).readyBoundaryId(), 0);
        assertEq(LensFacet(staking).claimableSharesTotal(), 0);
        assertEq(FundManagerFacet(staking).principalPerAsset(address(core)), 0);

        address[] memory registered = SleeveRegistryFacet(staking).sleeves();
        assertEq(registered.length, out.sleeves.length);
        for (uint256 i; i < registered.length; ++i) {
            assertEq(registered[i], out.sleeves[i].sleeve);
            assertEq(ISleeve(registered[i]).principalAssets(), 0);
            LibAppStorage.SleeveConfig memory sleeveCfg = SleeveRegistryFacet(staking).sleeveConfig(registered[i]);
            assertEq(sleeveCfg.principalAssets, 0);
            assertEq(sleeveCfg.asset, address(core));
        }

        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(staking);
        bytes32 upgraderRole = access.upgraderRole();
        assertEq(access.getRoleMemberCount(bytes32(0)), 1);
        assertEq(access.getRoleMember(bytes32(0), 0), governance);
        assertEq(access.getRoleMemberCount(upgraderRole), 1);
        assertEq(access.getRoleMember(upgraderRole, 0), governance);
        _assertNoCriticalRole(staking, cfg.safeWallet, upgraderRole);
        _assertNoCriticalRole(staking, address(this), upgraderRole);
        _assertNoCriticalRole(staking, relay, upgraderRole);
        _assertFinalAuthoritySurface(cfg, out, governance);
    }

    function _activateAndAssertOnlyPauseChanged(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory out,
        address governance
    ) private {
        address staking = address(out.diamond);
        address sleeveBeforeActivation = out.sleeves[0].sleeve;
        (, bytes32 launchHashBeforeActivation) = LensFacet(staking).stakingLaunchState();
        _expectUnpauseRejected(staking, SAFE_OWNER);
        _expectUnpauseRejected(staking, address(0xBAD));
        _expectUnpauseRejected(staking, governance);
        assertEq(uint256(vm.load(staking, OZ_PAUSABLE_STORAGE_SLOT)), 1);
        vm.record();
        vm.prank(cfg.safeWallet);
        PausableFacet(staking).unpause();
        (, bytes32[] memory writtenSlots) = vm.accesses(staking);
        assertEq(writtenSlots.length, 1);
        assertEq(writtenSlots[0], OZ_PAUSABLE_STORAGE_SLOT);
        assertEq(uint256(vm.load(staking, OZ_PAUSABLE_STORAGE_SLOT)), 0);

        bytes32 upgraderRole = DefaultAdminAccessControlFacet(staking).upgraderRole();
        assertFalse(PausableFacet(staking).paused());
        assertEq(IAccessControlDefaultAdminRules(staking).defaultAdmin(), governance);
        assertTrue(IAccessControl(staking).hasRole(bytes32(0), governance));
        assertTrue(IAccessControl(staking).hasRole(upgraderRole, governance));
        assertEq(VaultFacet(staking).totalSupply(), 0);
        (LibStakingLaunch.Phase phase, bytes32 finalizationHash) = LensFacet(staking).stakingLaunchState();
        assertEq(uint8(phase), uint8(LibStakingLaunch.Phase.Finalized));
        assertEq(finalizationHash, launchHashBeforeActivation);
        address[] memory registered = SleeveRegistryFacet(staking).sleeves();
        assertEq(registered.length, 1);
        assertEq(registered[0], sleeveBeforeActivation);
    }

    function _expectUnpauseRejected(address staking, address caller) private {
        vm.expectRevert(abi.encodeWithSelector(PausableFacet.EmergencyAuthorityUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        PausableFacet(staking).unpause();
    }

    function _assertAttemptFullyReverted(
        Vm.AccountAccess[] memory accesses,
        Vm.Log[] memory traceLogs,
        address[] memory expectedCreates
    ) private pure {
        bool sawRevertedWrite;
        bool[] memory sawCreate = new bool[](expectedCreates.length);
        for (uint256 i; i < accesses.length; ++i) {
            Vm.AccountAccess memory access = accesses[i];
            for (uint256 j; j < access.storageAccesses.length; ++j) {
                Vm.StorageAccess memory storageAccess = access.storageAccesses[j];
                if (!storageAccess.isWrite) continue;
                assertTrue(storageAccess.reverted);
                sawRevertedWrite = true;
            }
            if (access.kind != VmSafe.AccountAccessKind.Create) continue;
            for (uint256 j; j < expectedCreates.length; ++j) {
                if (access.account == expectedCreates[j]) {
                    assertTrue(access.reverted);
                    sawCreate[j] = true;
                }
            }
        }
        assertTrue(sawRevertedWrite);
        for (uint256 i; i < sawCreate.length; ++i) {
            assertTrue(sawCreate[i]);
        }

        // Foundry exposes LOG opcodes from reverted subcalls in trace recording. Prove that
        // every emitter belongs to a reverted context and that the terminal success event was
        // never reached; no trace log can survive into an Ethereum receipt for this attempt.
        assertGt(traceLogs.length, 0);
        bytes32 finalizedTopic = keccak256("StakingFinalized(bytes32,address)");
        for (uint256 i; i < traceLogs.length; ++i) {
            bool revertedEmitter;
            for (uint256 j; j < accesses.length; ++j) {
                if (
                    accesses[j].reverted
                        && (accesses[j].account == traceLogs[i].emitter || accesses[j].accessor == traceLogs[i].emitter)
                ) {
                    revertedEmitter = true;
                    break;
                }
            }
            assertTrue(revertedEmitter);
            if (traceLogs[i].topics.length != 0) assertNotEq(traceLogs[i].topics[0], finalizedTopic);
        }
    }

    function _containsTopic(Vm.Log[] memory logs, bytes32 topic) private pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    function _assertNoCriticalRole(address staking, address account, bytes32 upgraderRole) private view {
        assertFalse(IAccessControl(staking).hasRole(bytes32(0), account));
        assertFalse(IAccessControl(staking).hasRole(upgraderRole, account));
    }

    function _assertLaunchStorage(DeploymentTypes.DeployArtifacts memory out, LibStakingLaunch.Phase expectedPhase)
        private
        view
    {
        bytes32 derivedSlot = bytes32(
            uint256(keccak256(abi.encode(uint256(keccak256("cybergold.staking.atomic.launch")) - 1))) & ~uint256(0xff)
        );
        assertEq(derivedSlot, STAKING_LAUNCH_STORAGE_SLOT);
        address staking = address(out.diamond);
        assertEq(uint8(uint256(vm.load(staking, STAKING_LAUNCH_STORAGE_SLOT))), uint8(expectedPhase));
        bytes32 commitment = vm.load(staking, bytes32(uint256(STAKING_LAUNCH_STORAGE_SLOT) + 1));
        bytes32 activePayloadHash = vm.load(staking, bytes32(uint256(STAKING_LAUNCH_STORAGE_SLOT) + 2));
        bytes32 finalizationHash = vm.load(staking, bytes32(uint256(STAKING_LAUNCH_STORAGE_SLOT) + 3));
        address finalizerIdentity =
            address(uint160(uint256(vm.load(staking, bytes32(uint256(STAKING_LAUNCH_STORAGE_SLOT) + 4)))));
        if (expectedPhase == LibStakingLaunch.Phase.Committed) {
            assertEq(commitment, LibStakingLaunch.commitmentFor(block.chainid, staking, out.payloadHash));
            assertEq(activePayloadHash, bytes32(0));
            assertEq(finalizationHash, bytes32(0));
        } else {
            assertEq(commitment, bytes32(0));
            assertEq(activePayloadHash, bytes32(0));
            assertEq(finalizationHash, out.payloadHash);
        }
        assertEq(finalizerIdentity, address(out.facets.finalizer));
    }

    function _assertFinalAuthoritySurface(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory out,
        address governance
    ) private view {
        address staking = address(out.diamond);
        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(staking);
        assertEq(access.defaultAdminDelay(), 0);
        (address pendingAdmin, uint48 pendingAdminSchedule) = access.pendingDefaultAdmin();
        assertEq(pendingAdmin, address(0));
        assertEq(pendingAdminSchedule, 0);
        (uint48 pendingDelay, uint48 pendingDelaySchedule) = access.pendingDefaultAdminDelay();
        assertEq(pendingDelay, 0);
        assertEq(pendingDelaySchedule, 0);
        assertEq(IDiamondLoupe(staking).facetAddress(IStakingFinalizer.finalizeStaking.selector), address(0));
        assertEq(IDiamondLoupe(staking).facetAddress(IERC5313.owner.selector), address(0));
        assertFalse(IERC165(staking).supportsInterface(type(IERC5313).interfaceId));
        bytes32 ownerSlot = bytes32(uint256(DIAMOND_STORAGE_POSITION) + 3);
        assertEq(address(uint160(uint256(vm.load(staking, ownerSlot)))), address(0));

        _assertOrdinaryRoles(cfg, out, staking);
        assertTrue(access.hasRole(bytes32(0), governance));
    }

    function _assertOrdinaryRoles(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory out,
        address staking
    ) private view {
        IAccessControlEnumerable access = IAccessControlEnumerable(staking);
        bytes32 withdrawerRole = CustodyFacet(staking).WITHDRAWER_ROLE();
        bytes32 allocatorRole = FundManagerFacet(staking).ALLOCATOR_ROLE();
        assertEq(access.getRoleAdmin(withdrawerRole), bytes32(0));
        assertEq(access.getRoleAdmin(allocatorRole), bytes32(0));
        assertEq(access.getRoleMemberCount(withdrawerRole), cfg.withdrawers.length + out.sleeves.length);
        for (uint256 i; i < cfg.withdrawers.length; ++i) {
            assertEq(access.getRoleMember(withdrawerRole, i), cfg.withdrawers[i]);
        }
        for (uint256 i; i < out.sleeves.length; ++i) {
            assertEq(access.getRoleMember(withdrawerRole, cfg.withdrawers.length + i), out.sleeves[i].sleeve);
        }
        assertEq(access.getRoleMemberCount(allocatorRole), cfg.allocators.length);
        for (uint256 i; i < cfg.allocators.length; ++i) {
            assertEq(access.getRoleMember(allocatorRole, i), cfg.allocators[i]);
        }
    }

    function _predictedSleeve(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory out,
        uint256 index
    ) private pure returns (address) {
        bytes32 requestHash = keccak256(abi.encode(cfg.sleeves[index]));
        bytes32 baseSalt = LibStakingLaunch.sleeveBaseSalt(cfg.shellSalt, index, requestHash);
        bytes32 effectiveSalt = LibStakingLaunch.sleeveSalt(out.payloadHash, baseSalt, index);
        return SleeveDeployerHelper.predictDeterministic(
            address(out.diamond), address(out.diamond), cfg.sleeves[index], effectiveSalt
        );
    }

    function _assertBeforeSleeveCreationFailureAndRetry(uint256 targetIndex) private {
        DeploymentTypes.DeployConfig memory cfg =
            _failureMatrixConfig(keccak256("before-sleeve-create"), targetIndex, address(0));
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        address[] memory predicted = _predictedSleeves(cfg, out);
        address targetImplementation = cfg.sleeves[targetIndex].implementation;
        bytes memory originalRuntime = targetImplementation.code;
        bytes32 exactRelayHash = keccak256(abi.encodeCall(IStakingFinalizer.finalizeStaking, (out.finalization)));

        vm.etch(targetImplementation, hex"00");
        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondInit.StakingInitSleeveImplementationMismatch.selector, targetIndex, targetImplementation
            )
        );
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        Vm.AccountAccess[] memory revertedAccesses = vm.stopAndReturnStateDiff();
        Vm.Log[] memory revertedTraceLogs = vm.getRecordedLogs();
        _assertAttemptFullyReverted(revertedAccesses, revertedTraceLogs, _prefix(predicted, targetIndex));
        _assertPredictedSleevesAbsent(predicted);
        _assertPristineShell(out);

        vm.etch(targetImplementation, originalRuntime);
        assertEq(keccak256(abi.encodeCall(IStakingFinalizer.finalizeStaking, (out.finalization))), exactRelayHash);
        _finalizeMatrixRetry(cfg, out, predicted);
    }

    function _assertDuringSleeveCreationFailureAndRetry(uint256 targetIndex) private {
        TransientFailureSwitch failureSwitch = new TransientFailureSwitch();
        failureSwitch.setShouldFail(true);
        DeploymentTypes.DeployConfig memory cfg =
            _failureMatrixConfig(keccak256("during-sleeve-create"), targetIndex, address(failureSwitch));
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        address[] memory predicted = _predictedSleeves(cfg, out);
        bytes32 exactRelayHash = keccak256(abi.encodeCall(IStakingFinalizer.finalizeStaking, (out.finalization)));

        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.expectRevert(TransientFailureSleeveImplementation.TransientSleeveFailure.selector);
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        Vm.AccountAccess[] memory revertedAccesses = vm.stopAndReturnStateDiff();
        Vm.Log[] memory revertedTraceLogs = vm.getRecordedLogs();
        _assertAttemptFullyReverted(revertedAccesses, revertedTraceLogs, _prefix(predicted, targetIndex + 1));
        _assertPredictedSleevesAbsent(predicted);
        _assertPristineShell(out);

        failureSwitch.setShouldFail(false);
        assertEq(keccak256(abi.encodeCall(IStakingFinalizer.finalizeStaking, (out.finalization))), exactRelayHash);
        _finalizeMatrixRetry(cfg, out, predicted);
    }

    function _assertAfterSleeveCreationFailureAndRetry(uint256 targetIndex) private {
        DeploymentTypes.DeployConfig memory cfg =
            _failureMatrixConfig(keccak256("after-sleeve-create"), targetIndex, address(0));
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        address[] memory predicted = _predictedSleeves(cfg, out);
        bytes32 exactRelayHash = keccak256(abi.encodeCall(IStakingFinalizer.finalizeStaking, (out.finalization)));
        bytes memory injectedRevert =
            abi.encodeWithSelector(InjectedSleeveBoundaryFailure.selector, uint8(2), targetIndex);
        bytes memory invariantCall = abi.encodeCall(
            StakingSleeveInvariant.requireSleeve,
            (address(out.diamond), targetIndex, predicted[targetIndex], cfg.sleeves[targetIndex])
        );
        vm.mockCallRevert(address(out.sleeveInvariant), invariantCall, injectedRevert);

        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.expectRevert(injectedRevert);
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        Vm.AccountAccess[] memory revertedAccesses = vm.stopAndReturnStateDiff();
        Vm.Log[] memory revertedTraceLogs = vm.getRecordedLogs();
        _assertAttemptFullyReverted(revertedAccesses, revertedTraceLogs, _prefix(predicted, targetIndex + 1));
        _assertPredictedSleevesAbsent(predicted);
        _assertPristineShell(out);

        vm.clearMockedCalls();
        assertEq(keccak256(abi.encodeCall(IStakingFinalizer.finalizeStaking, (out.finalization))), exactRelayHash);
        _finalizeMatrixRetry(cfg, out, predicted);
    }

    function _failureMatrixConfig(bytes32 boundary, uint256 targetIndex, address transientSwitch)
        private
        returns (DeploymentTypes.DeployConfig memory cfg)
    {
        MockCyberGold core;
        (cfg, core,) = _config(false);
        cfg.shellSalt = keccak256(abi.encode(boundary, targetIndex));
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](FAILURE_MATRIX_SLEEVE_COUNT);
        for (uint256 i; i < FAILURE_MATRIX_SLEEVE_COUNT; ++i) {
            address implementation;
            if (i == targetIndex && transientSwitch != address(0)) {
                implementation =
                    address(new TransientFailureSleeveImplementation(TransientFailureSwitch(transientSwitch)));
            } else {
                implementation = address(new MockSleeve());
            }
            cfg.sleeves[i] = _basicSleeve(implementation, address(core), i % 2 == 0);
            cfg.sleeves[i].principalCap += i;
        }
    }

    function _predictedSleeves(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory out)
        private
        pure
        returns (address[] memory predicted)
    {
        predicted = new address[](cfg.sleeves.length);
        for (uint256 i; i < predicted.length; ++i) {
            predicted[i] = _predictedSleeve(cfg, out, i);
        }
    }

    function _prefix(address[] memory values, uint256 length) private pure returns (address[] memory prefix) {
        prefix = new address[](length);
        for (uint256 i; i < length; ++i) {
            prefix[i] = values[i];
        }
    }

    function _assertPredictedSleevesAbsent(address[] memory predicted) private view {
        for (uint256 i; i < predicted.length; ++i) {
            assertEq(predicted[i].code.length, 0);
        }
    }

    function _finalizeMatrixRetry(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory out,
        address[] memory predicted
    ) private {
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
        out = DeploymentHelper.finalizeCommittedResults(cfg, out);
        assertEq(out.sleeves.length, predicted.length);
        for (uint256 i; i < predicted.length; ++i) {
            assertEq(out.sleeves[i].sleeve, predicted[i]);
            assertGt(predicted[i].code.length, 0);
        }
        _assertLaunchStorage(out, LibStakingLaunch.Phase.Finalized);
    }

    function _basicSleeve(address implementation, address asset, bool approve)
        private
        pure
        returns (SleeveDeployerHelper.SleeveRequest memory)
    {
        return SleeveDeployerHelper.SleeveRequest({
            implementation: implementation,
            asset: asset,
            approve: approve,
            initialOperational: true,
            initialPaused: false,
            principalCap: 1_000 ether,
            initType: SleeveDeployerHelper.InitType.Basic,
            initArgs: bytes("")
        });
    }
}
