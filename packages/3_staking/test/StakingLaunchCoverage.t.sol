// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";

import {DeploymentHelper} from "staking/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "staking/deploy/DeploymentTypes.sol";
import {DiamondInit} from "staking/deploy/DiamondInit.sol";
import {SleeveDeployerHelper} from "staking/deploy/SleeveDeployerHelper.sol";
import {StakingAuthorityInvariant} from "staking/deploy/StakingAuthorityInvariant.sol";
import {StakingBootstrapInit} from "staking/deploy/StakingBootstrapInit.sol";
import {StakingInterfaceInit} from "staking/deploy/StakingInterfaceInit.sol";
import {StakingLaunchTypes, IStakingFinalizer} from "staking/deploy/StakingLaunchTypes.sol";
import {StakingFinalizerFacet} from "staking/facets/StakingFinalizerFacet.sol";
import {LibStakingLaunch} from "staking/libraries/LibStakingLaunch.sol";

import {MockCyberGold} from "staking-mocks/MockCyberGold.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";

contract LaunchCoverageGovernance {}

contract LaunchCoverageAuthorityMock {
    address public defaultAdmin;

    function setDefaultAdmin(address value) external {
        defaultAdmin = value;
    }

    function DEFAULT_ADMIN_ROLE() external pure returns (bytes32) {
        return bytes32(0);
    }

    function upgraderRole() external pure returns (bytes32) {
        return keccak256("UPGRADER_ROLE");
    }

    function pendingDefaultAdmin() external pure returns (address, uint48) {
        return (address(0), 0);
    }

    function pendingDefaultAdminDelay() external pure returns (uint48, uint48) {
        return (0, 0);
    }

    function getRoleMemberCount(bytes32) external pure returns (uint256) {
        return 0;
    }

    function getRoleAdmin(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    function defaultAdminDelay() external pure returns (uint48) {
        return 0;
    }

    function hasRole(bytes32, address) external pure returns (bool) {
        return false;
    }
}

contract LaunchCoverageDiamondInitHarness {
    function invoke(
        address initializer,
        DiamondInit.InitConfig calldata cfg,
        string calldata name_,
        string calldata symbol_
    ) external {
        LibStakingLaunch.Layout storage launch = LibStakingLaunch.getLayout();
        launch.phase = LibStakingLaunch.Phase.Finalizing;
        launch.activePayloadHash = keccak256("coverage-active-payload");
        launch.commitment = LibStakingLaunch.commitment(launch.activePayloadHash);
        (bool ok, bytes memory returndata) =
            initializer.delegatecall(abi.encodeWithSelector(DiamondInit.finalize.selector, cfg, name_, symbol_));
        if (!ok) _bubble(returndata);
    }

    function _bubble(bytes memory returndata) private pure {
        assembly {
            revert(add(returndata, 0x20), mload(returndata))
        }
    }
}

contract LaunchCoverageInterfaceHarness {
    bytes32 private constant INIT_CONTEXT_SLOT = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;

    function invoke(address initializer, address[13] calldata facets) external {
        _enterInitContext();
        _delegate(initializer, facets);
    }

    function installAndInvoke(
        address initializer,
        IDiamond.FacetCut[] calldata cuts,
        address[13] calldata facets,
        bool retainFinalizerMapping
    ) external {
        IDiamond.FacetCut[] memory copied = cuts;
        LibDiamond.diamondCut(copied, address(0), bytes(""));
        if (retainFinalizerMapping) {
            LibDiamond.diamondStorage()
            .facetAddressAndSelectorPosition[IStakingFinalizer.finalizeStaking.selector].facetAddress = address(0xF1);
        }
        _enterInitContext();
        _delegate(initializer, facets);
    }

    function _enterInitContext() private {
        bytes32 slot = INIT_CONTEXT_SLOT;
        assembly {
            sstore(slot, 1)
        }
    }

    function _delegate(address initializer, address[13] calldata facets) private {
        (bool ok, bytes memory returndata) =
            initializer.delegatecall(abi.encodeCall(StakingInterfaceInit.initialize, (facets)));
        if (!ok) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }
}

contract LaunchCoverageIncompleteInitializer {
    uint8 private immutable MODE;

    constructor(uint8 mode) {
        MODE = mode;
    }

    function finalize(DiamondInit.InitConfig calldata, string calldata, string calldata) external {
        if (MODE == 0) return;
        LibStakingLaunch.Layout storage launch = LibStakingLaunch.getLayout();
        launch.finalizationHash = launch.activePayloadHash;
        launch.activePayloadHash = bytes32(0);
        launch.commitment = bytes32(0);
        launch.phase = LibStakingLaunch.Phase.Finalized;
        LibDiamond.diamondStorage()
        .facetAddressAndSelectorPosition[IStakingFinalizer.finalizeStaking.selector].facetAddress = address(0xF1);
    }
}

contract LaunchCoverageEmptyReverterFacet {
    uint64 public constant FACET_VERSION = 1;
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.staking.coverage.empty-reverter");

    fallback() external {
        assembly {
            revert(0, 0)
        }
    }
}

contract StakingLaunchCoverageTest is Test {
    bytes32 private constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");
    bytes32 private constant STAKING_LAUNCH_STORAGE_SLOT =
        0xaf998c30b6bf758887c4f7ae3b9979a4920a749d595a880ba4118393868a6f00;
    address private constant SAFE_OWNER = address(0xA11CE);
    address private constant WITHDRAWER = address(0xB0B);
    address private constant ALLOCATOR = address(0xCAFE);

    function testBootstrapAndAuthorityInvariantFailureBranches() external {
        StakingBootstrapInit bootstrap = new StakingBootstrapInit();
        StakingFinalizerFacet finalizer = new StakingFinalizerFacet();

        vm.expectRevert(StakingBootstrapInit.InvalidBootstrapState.selector);
        bootstrap.initialize(bytes32(0), address(finalizer));
        vm.expectRevert(abi.encodeWithSelector(StakingBootstrapInit.InvalidFinalizer.selector, address(0)));
        bootstrap.initialize(bytes32(uint256(1)), address(0));
        vm.expectRevert(StakingBootstrapInit.InvalidBootstrapState.selector);
        bootstrap.initialize(bytes32(uint256(1)), address(finalizer));

        LaunchCoverageAuthorityMock authority = new LaunchCoverageAuthorityMock();
        StakingAuthorityInvariant authorityInvariant = new StakingAuthorityInvariant();
        authority.setDefaultAdmin(address(0xA));
        vm.expectRevert(StakingAuthorityInvariant.StakingCriticalAuthorityInvariant.selector);
        authorityInvariant.requireNoCriticalAuthority(address(authority), address(0xB), address(0xC));
    }

    function testFinalizerDirectPhaseAndPristineShellBranches() external {
        StakingFinalizerFacet finalizer = new StakingFinalizerFacet();
        StakingLaunchTypes.Finalization memory candidate = _emptyCandidate();
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingFinalizerFacet.StakingFinalizationInvalidPhase.selector, LibStakingLaunch.Phase.Uninitialized
            )
        );
        finalizer.finalizeStaking(candidate);

        vm.store(address(finalizer), STAKING_LAUNCH_STORAGE_SLOT, bytes32(uint256(LibStakingLaunch.Phase.Committed)));
        vm.expectRevert(StakingFinalizerFacet.StakingFinalizationInvalidShell.selector);
        finalizer.finalizeStaking(candidate);
    }

    function testFinalizerCommittedValidationMatrix() external {
        (DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory base) =
            _prepared(keccak256("coverage-finalizer-base"));
        address marker = address(new LaunchCoverageGovernance());
        bytes memory encodedBaseCandidate = abi.encode(base.finalization);
        for (uint8 mutation; mutation < 15; ++mutation) {
            StakingLaunchTypes.Finalization memory pristine =
                abi.decode(encodedBaseCandidate, (StakingLaunchTypes.Finalization));
            DeploymentTypes.DeployArtifacts memory attempt = base;
            attempt.finalization = this.mutateFinalizerCandidate(pristine, mutation, marker);
            attempt.payloadHash = LibStakingLaunch.payloadHash(attempt.finalization);
            cfg.shellSalt = keccak256(abi.encode("coverage-finalizer", mutation));
            attempt = DeploymentHelper.deployCommittedShellLocal(cfg, attempt);

            (bool ok, bytes memory returndata) =
                address(attempt.diamond).call(abi.encodeCall(IStakingFinalizer.finalizeStaking, (attempt.finalization)));
            assertFalse(ok);
            assertEq(_selector(returndata), _expectedFinalizerError(mutation));
        }
    }

    function testFinalizerIncompleteTerminalStateBranches() external {
        (DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory base) =
            _prepared(keccak256("coverage-incomplete-base"));
        bytes memory encodedBaseCandidate = abi.encode(base.finalization);
        for (uint8 mode; mode < 2; ++mode) {
            LaunchCoverageIncompleteInitializer initializer = new LaunchCoverageIncompleteInitializer(mode);
            DeploymentTypes.DeployArtifacts memory attempt = base;
            attempt.finalization = abi.decode(encodedBaseCandidate, (StakingLaunchTypes.Finalization));
            attempt.finalization.initializer = address(initializer);
            attempt.finalization.initializerCodeHash = address(initializer).codehash;
            attempt.payloadHash = LibStakingLaunch.payloadHash(attempt.finalization);
            cfg.shellSalt = keccak256(abi.encode("coverage-incomplete", mode));
            attempt = DeploymentHelper.deployCommittedShellLocal(cfg, attempt);

            vm.expectRevert(StakingFinalizerFacet.StakingFinalizationIncomplete.selector);
            IStakingFinalizer(address(attempt.diamond)).finalizeStaking(attempt.finalization);
        }
    }

    function testDiamondInitPreflightFailureMatrix() external {
        (, DeploymentTypes.DeployArtifacts memory out) = _prepared(keccak256("coverage-init-preflight"));
        (DiamondInit.InitConfig memory baseCfg, string memory name_, string memory symbol_) =
            this.decodeInitializer(out.finalization.initializerCalldata);
        LaunchCoverageDiamondInitHarness harness = new LaunchCoverageDiamondInitHarness();

        for (uint8 mutation; mutation < 14; ++mutation) {
            DiamondInit.InitConfig memory cfg = this.mutateInitConfig(baseCfg, mutation, address(harness));
            (bool ok, bytes memory returndata) = address(harness)
                .call(
                    abi.encodeCall(
                        LaunchCoverageDiamondInitHarness.invoke, (address(out.diamondInit), cfg, name_, symbol_)
                    )
                );
            assertFalse(ok);
            assertEq(_selector(returndata), _expectedInitError(mutation));
        }
    }

    function testDiamondInitRejectsOccupiedPredictedSleeve() external {
        (DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory out) =
            _prepared(keccak256("coverage-occupied-sleeve"));
        out = DeploymentHelper.deployCommittedShellLocal(cfg, out);
        address predicted = _predictedSleeve(cfg, out, 0);
        vm.etch(predicted, hex"00");

        vm.expectRevert(abi.encodeWithSelector(DiamondInit.StakingInitInvalidSleeve.selector, 0, predicted));
        IStakingFinalizer(address(out.diamond)).finalizeStaking(out.finalization);
    }

    function testDiamondInitWrapsEmptyDelegateRevert() external {
        (, DeploymentTypes.DeployArtifacts memory out) = _prepared(keccak256("coverage-empty-delegate"));
        (DiamondInit.InitConfig memory cfg, string memory name_, string memory symbol_) =
            this.decodeInitializer(out.finalization.initializerCalldata);
        LaunchCoverageEmptyReverterFacet emptyReverter = new LaunchCoverageEmptyReverterFacet();
        cfg.interfaceInit = address(emptyReverter);
        LaunchCoverageDiamondInitHarness harness = new LaunchCoverageDiamondInitHarness();

        (bool ok, bytes memory returndata) = address(harness)
            .call(
                abi.encodeCall(LaunchCoverageDiamondInitHarness.invoke, (address(out.diamondInit), cfg, name_, symbol_))
            );
        assertFalse(ok);
        assertEq(_selector(returndata), DiamondInit.FacetInitFailed.selector);
    }

    function testInterfaceInitializerDependencyCountAndTerminalSelectorBranches() external {
        (, DeploymentTypes.DeployArtifacts memory out) = _prepared(keccak256("coverage-interface"));
        (DiamondInit.InitConfig memory cfg,,) = this.decodeInitializer(out.finalization.initializerCalldata);
        address[13] memory facets = _interfaceFacets(cfg);

        LaunchCoverageInterfaceHarness zeroHarness = new LaunchCoverageInterfaceHarness();
        address[13] memory zeroFacets = facets;
        zeroFacets[7] = address(0);
        (bool ok, bytes memory returndata) = address(zeroHarness)
            .call(abi.encodeCall(LaunchCoverageInterfaceHarness.invoke, (address(out.interfaceInit), zeroFacets)));
        assertFalse(ok);
        assertEq(_selector(returndata), StakingInterfaceInit.StakingInitInvalidDependency.selector);

        facets = _interfaceFacets(cfg);
        IDiamond.FacetCut[] memory production = _productionCut(out.finalization.diamondCut);
        LaunchCoverageInterfaceHarness countHarness = new LaunchCoverageInterfaceHarness();
        bytes4[] memory originalLast = production[production.length - 1].functionSelectors;
        bytes4[] memory extended = new bytes4[](originalLast.length + 1);
        for (uint256 i; i < originalLast.length; ++i) {
            extended[i] = originalLast[i];
        }
        extended[originalLast.length] = bytes4(keccak256("coverageExtraSelector()"));
        production[production.length - 1].functionSelectors = extended;
        (ok, returndata) = address(countHarness)
            .call(
                abi.encodeCall(
                    LaunchCoverageInterfaceHarness.installAndInvoke,
                    (address(out.interfaceInit), production, facets, false)
                )
            );
        assertFalse(ok);
        assertEq(_selector(returndata), StakingInterfaceInit.StakingInitSelectorCountMismatch.selector);

        production = _productionCut(out.finalization.diamondCut);
        LaunchCoverageInterfaceHarness terminalHarness = new LaunchCoverageInterfaceHarness();
        (ok, returndata) = address(terminalHarness)
            .call(
                abi.encodeCall(
                    LaunchCoverageInterfaceHarness.installAndInvoke,
                    (address(out.interfaceInit), production, facets, true)
                )
            );
        assertFalse(ok);
        assertEq(_selector(returndata), StakingInterfaceInit.StakingInitSelectorCountMismatch.selector);
    }

    function mutateFinalizerCandidate(StakingLaunchTypes.Finalization calldata original, uint8 mutation, address marker)
        external
        pure
        returns (StakingLaunchTypes.Finalization memory candidate)
    {
        candidate = abi.decode(abi.encode(original), (StakingLaunchTypes.Finalization));
        if (mutation == 0) {
            candidate.initializer = address(0);
        } else if (mutation == 1) {
            candidate.diamondCut[1].functionSelectors = new bytes4[](0);
        } else if (mutation == 2) {
            candidate.diamondCut[1].functionSelectors[0] = IStakingFinalizer.finalizeStaking.selector;
        } else if (mutation == 3) {
            candidate.diamondCut[0].facetAddress = marker;
        } else if (mutation == 4) {
            candidate.diamondCut[1].action = IDiamond.FacetCutAction.Replace;
        } else if (mutation == 5) {
            candidate.diamondCut = new IDiamond.FacetCut[](0);
        } else if (mutation == 6) {
            candidate.diamondCut[1].facetAddress = marker;
        } else if (mutation == 7) {
            candidate.facets[0].runtimeCodeHash ^= bytes32(uint256(2));
        } else if (mutation == 8) {
            candidate.facets[1].namespace = candidate.facets[0].namespace;
        } else if (mutation == 9) {
            candidate.facets[0].namespace ^= bytes32(uint256(1));
        } else if (mutation == 10) {
            candidate.initializerCalldata = bytes.concat(candidate.initializerCalldata, hex"00");
        } else if (mutation == 11) {
            StakingLaunchTypes.FacetExpectation[] memory shortened =
                new StakingLaunchTypes.FacetExpectation[](candidate.facets.length - 1);
            for (uint256 i; i < shortened.length; ++i) {
                shortened[i] = candidate.facets[i];
            }
            candidate.facets = shortened;
        } else {
            (DiamondInit.InitConfig memory cfg, string memory name_, string memory symbol_) =
                abi.decode(original.initializerCalldata[4:], (DiamondInit.InitConfig, string, string));
            if (mutation == 12) cfg.interfaceInit = address(0);
            else if (mutation == 13) cfg.interfaceInit = cfg.sleeveInvariant;
            else if (mutation == 14) cfg.interfaceInit = marker;
            candidate.initializerCalldata = abi.encodeWithSelector(DiamondInit.finalize.selector, cfg, name_, symbol_);
        }
    }

    function mutateInitConfig(DiamondInit.InitConfig calldata original, uint8 mutation, address harness)
        external
        pure
        returns (DiamondInit.InitConfig memory cfg)
    {
        cfg = abi.decode(abi.encode(original), (DiamondInit.InitConfig));
        if (mutation == 0) {
            cfg.coreDiamond = address(0x1000);
        } else if (mutation == 1) {
            cfg.allocators = new address[](0);
        } else if (mutation == 2) {
            cfg.governanceDiamond = address(0x1002);
        } else if (mutation == 3) {
            cfg.authorityInvariant = address(0);
        } else if (mutation == 4) {
            cfg.sleeves = new DiamondInit.LaunchSleeve[](0);
        } else if (mutation == 5) {
            cfg.coreDiamond = cfg.governanceDiamond;
        } else if (mutation == 6) {
            cfg.coreDiamond = cfg.safeWallet;
        } else if (mutation == 7) {
            cfg.governanceDiamond = cfg.safeWallet;
        } else if (mutation == 8) {
            cfg.governanceDiamond = harness;
        } else if (mutation == 9) {
            cfg.coreDiamond = harness;
        } else if (mutation == 10) {
            cfg.safeWallet = harness;
        } else if (mutation == 11) {
            cfg.allocators = new address[](2);
            cfg.allocators[0] = ALLOCATOR;
            cfg.allocators[1] = ALLOCATOR;
        } else if (mutation == 12) {
            cfg.withdrawers[0] = address(0);
        } else if (mutation == 13) {
            cfg.withdrawers = new address[](2);
            cfg.withdrawers[0] = WITHDRAWER;
            cfg.withdrawers[1] = WITHDRAWER;
        }
    }

    function decodeInitializer(bytes calldata initializerCalldata)
        external
        pure
        returns (DiamondInit.InitConfig memory cfg, string memory name_, string memory symbol_)
    {
        (cfg, name_, symbol_) = abi.decode(initializerCalldata[4:], (DiamondInit.InitConfig, string, string));
    }

    function _prepared(bytes32 salt)
        private
        returns (DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory out)
    {
        MockCyberGold core = new MockCyberGold();
        cfg.safeWallet = MockSafeWalletFactory.deploy(SAFE_OWNER);
        cfg.name = "Staked CyberGold";
        cfg.symbol = "sCYGLD";
        cfg.coreDiamond = address(core);
        cfg.governanceDiamond = address(new LaunchCoverageGovernance());
        cfg.withdrawers = new address[](1);
        cfg.withdrawers[0] = WITHDRAWER;
        cfg.allocators = new address[](1);
        cfg.allocators[0] = ALLOCATOR;
        cfg.claimExpiry = 7 days;
        cfg.headSweepLimit = 32;
        cfg.autoProcessMax = 16;
        cfg.performanceFeePpm = 100_000;
        cfg.create2Deployer = address(this);
        cfg.shellSalt = salt;
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveDeployerHelper.SleeveRequest({
            implementation: address(new MockSleeve()),
            asset: address(core),
            approve: true,
            initialOperational: true,
            initialPaused: false,
            principalCap: 1_000 ether,
            initType: SleeveDeployerHelper.InitType.Basic,
            initArgs: bytes("")
        });
        out = DeploymentHelper.prepare(cfg);
    }

    function _emptyCandidate() private pure returns (StakingLaunchTypes.Finalization memory candidate) {
        candidate.diamondCut = new IDiamond.FacetCut[](0);
        candidate.facets = new StakingLaunchTypes.FacetExpectation[](0);
        candidate.initializerCalldata = bytes("");
    }

    function _expectedFinalizerError(uint8 mutation) private pure returns (bytes4) {
        if (mutation == 0) return StakingFinalizerFacet.StakingFinalizationInvalidInitializer.selector;
        if (mutation <= 5 || mutation == 11) return StakingFinalizerFacet.StakingFinalizationInvalidCut.selector;
        if (mutation <= 8 || mutation >= 12) return StakingFinalizerFacet.StakingFinalizationInvalidFacet.selector;
        if (mutation == 9) return StakingFinalizerFacet.StakingFinalizationFacetMetadataMismatch.selector;
        return StakingFinalizerFacet.StakingFinalizationInvalidInitializerCalldata.selector;
    }

    function _expectedInitError(uint8 mutation) private pure returns (bytes4) {
        if (mutation == 0 || mutation == 2 || mutation == 3) return DiamondInit.StakingInitInvalidDependency.selector;
        if (mutation == 1) return DiamondInit.StakingInitEmptyAllocators.selector;
        if (mutation == 4) return DiamondInit.StakingInitEmptySleeves.selector;
        if (mutation <= 10) return DiamondInit.StakingInitIdentityCollision.selector;
        if (mutation == 11) return DiamondInit.StakingInitInvalidAllocator.selector;
        return DiamondInit.StakingInitInvalidWithdrawer.selector;
    }

    function _selector(bytes memory returndata) private pure returns (bytes4 selector) {
        if (returndata.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(returndata, 0x20))
        }
    }

    function _interfaceFacets(DiamondInit.InitConfig memory cfg) private pure returns (address[13] memory facets) {
        facets[0] = cfg.cutFacet;
        facets[1] = cfg.loupeFacet;
        facets[2] = cfg.accessControlFacet;
        facets[3] = cfg.pausableFacet;
        facets[4] = cfg.tokenFacet;
        facets[5] = cfg.vaultFacet;
        facets[6] = cfg.queueFacet;
        facets[7] = cfg.queueOperatorFacet;
        facets[8] = cfg.queueSigFacet;
        facets[9] = cfg.custodyFacet;
        facets[10] = cfg.sleeveRegistryFacet;
        facets[11] = cfg.fundManagerFacet;
        facets[12] = cfg.lensFacet;
    }

    function _productionCut(IDiamond.FacetCut[] memory finalCut)
        private
        pure
        returns (IDiamond.FacetCut[] memory production)
    {
        IDiamond.FacetCut[] memory cloned = abi.decode(abi.encode(finalCut), (IDiamond.FacetCut[]));
        production = new IDiamond.FacetCut[](cloned.length - 1);
        for (uint256 i; i < production.length; ++i) {
            production[i] = cloned[i + 1];
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
}
