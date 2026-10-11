// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";
import {DeployParams as StakingDeployParams} from "packages/3_staking/src/deploy/DeployParams.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {DeploymentTypes as GovTypes} from "packages/2_governance/src/deploy/DeploymentTypes.sol";
import {DeployParams as GovernanceDeployParams} from "packages/2_governance/src/deploy/DeployParams.sol";

/// @notice Shared builder helpers for stack configs across scripts/tests.
library StackConfigBuilder {
    error StakingLaunchBindingKindInvalid(uint256 index, uint256 value);
    error StakingLaunchBindingLengthMismatch(uint256 sleeves, uint256 bindings);
    error StakingLaunchAllocatorsEmpty();
    error StakingLaunchAllocatorMissing(uint256 index);
    error StakingLaunchAllocatorDuplicate(uint256 firstIndex, uint256 duplicateIndex);
    error StakingLaunchSleevesEmpty();
    error StakingLaunchSleeveImplementationMissing(uint256 index);
    error StakingLaunchExplicitAssetMissing(uint256 index);
    error StakingLaunchCoreBindingAssetMustBeZero(uint256 index, address asset);

    /// @notice Exact aggregate-launch inputs that cannot be inferred before Core exists.
    struct StakingLaunchConfig {
        address create2Deployer;
        bytes32 shellSalt;
        address fundManagerSwapAdapter;
        address[] allocators;
        SleeveDeployerHelper.SleeveRequest[] sleeves;
        StackDeployer.SleeveAssetBinding[] sleeveAssetBindings;
    }

    /// @notice Load the exact ordered Staking launch roster used by the aggregate Protocol script.
    /// @dev Every input is mandatory. Asset binding values are 0=Explicit and 1=CoreDiamond.
    function stakingLaunchFromEnv(Vm vm_) internal view returns (StakingLaunchConfig memory launch) {
        launch.create2Deployer =
            DeployParamsHelper.envAddressRequired(vm_, DeployParamsHelper.keys1("STAKING_CREATE2_DEPLOYER"));
        launch.shellSalt = vm_.envBytes32("STAKING_SHELL_SALT");
        launch.fundManagerSwapAdapter = vm_.envAddress("STAKING_FUND_MANAGER_SWAP_ADAPTER");
        launch.allocators = vm_.envAddress("STAKING_ALLOCATORS", ",");
        launch.sleeves = StakingDeployParams.sleevesFromEnv(vm_);

        uint256[] memory rawBindings = vm_.envUint("STAKING_SLEEVE_ASSET_BINDINGS", ",");
        launch.sleeveAssetBindings = sleeveAssetBindings(rawBindings);
        _validateStakingLaunch(launch);
    }

    /// @notice Convert serialized binding kinds into the exact typed launch order.
    function sleeveAssetBindings(uint256[] memory rawBindings)
        internal
        pure
        returns (StackDeployer.SleeveAssetBinding[] memory bindings)
    {
        bindings = new StackDeployer.SleeveAssetBinding[](rawBindings.length);
        for (uint256 i; i < rawBindings.length; ++i) {
            if (rawBindings[i] > uint256(StackDeployer.SleeveAssetBinding.CoreDiamond)) {
                revert StakingLaunchBindingKindInvalid(i, rawBindings[i]);
            }
            bindings[i] = StackDeployer.SleeveAssetBinding(rawBindings[i]);
        }
    }

    function fromProtocolConfig(
        DeployConfig.ProtocolConfig memory cfg,
        address bootstrapOwner,
        StakingLaunchConfig memory launch
    ) internal pure returns (StackDeployer.StackConfig memory sc) {
        require(bootstrapOwner != address(0), "StackConfigBuilder: bootstrap owner missing");
        _validateStakingLaunch(launch);
        GovernanceDeployParams.validateCygovSupply(
            cfg.governance.tokenInitialSupply, cfg.governance.tokenTreasurySupply
        );
        sc.skipCore = false;
        sc.skipGovernance = false;
        sc.bootstrapOwner = bootstrapOwner;
        sc.sleeves = launch.sleeves;
        sc.sleeveAssetBindings = launch.sleeveAssetBindings;

        sc.core.admin = cfg.admin;
        sc.core.safeWallet = cfg.safeWallet;
        sc.core.name = cfg.basket.name;
        sc.core.symbol = cfg.basket.symbol;
        sc.core.coreTreasury = address(0);
        sc.core.basketAssets = cfg.basket.assets.addresses;
        sc.core.basketTargetsPpm = cfg.basket.assets.targetsPpm;
        sc.core.basketGoldRefGramsFp18 = cfg.basket.assets.goldRefGramsFp18;
        sc.core.cygldRefGramsFp18 = cfg.basket.cygldRefGramsFp18;
        sc.core.maxTotalSupply = cfg.basket.maxTotalSupply;
        sc.core.issuanceFeePpm = cfg.basket.issuanceFeePpm;
        sc.core.redemptionFeePpm = cfg.basket.redemptionFeePpm;

        sc.staking.safeWallet = cfg.safeWallet;
        sc.staking.name = cfg.staking.name;
        sc.staking.symbol = cfg.staking.symbol;
        sc.staking.coreDiamond = address(0);
        sc.staking.governanceDiamond = address(0);
        sc.staking.withdrawers = cfg.staking.withdrawers;
        sc.staking.claimExpiry = cfg.queue.claimExpiry;
        sc.staking.headSweepLimit = cfg.queue.headSweepLimit;
        sc.staking.autoProcessMax = cfg.queue.autoProcessMax;
        sc.staking.performanceFeePpm = cfg.performanceFeePpm;
        sc.staking.fundManagerSwapAdapter = launch.fundManagerSwapAdapter;
        sc.staking.allocators = launch.allocators;
        sc.staking.create2Deployer = launch.create2Deployer;
        sc.staking.shellSalt = launch.shellSalt;

        sc.governance.constructorOwner = cfg.admin;
        sc.governance.safeWallet = cfg.safeWallet;
        sc.governance.executionDelay = cfg.governance.executionDelay;
        sc.governance.executionGracePeriod = cfg.governance.executionGracePeriod;
        sc.governance.name = cfg.governance.name;
        sc.governance.tokenSymbol = cfg.governance.tokenSymbol;
        sc.governance.tokenInitialHolder = cfg.governance.tokenInitialHolder;
        sc.governance.tokenInitialSupply = cfg.governance.tokenInitialSupply;
        sc.governance.tokenTreasurySupply = cfg.governance.tokenTreasurySupply;
        sc.governance.votingDelay = cfg.governance.votingDelay;
        sc.governance.votingPeriod = cfg.governance.votingPeriod;
        sc.governance.proposalThresholdNumerator = cfg.governance.proposalThresholdNumerator;
        sc.governance.quorumNumerator = cfg.governance.quorumNumerator;
    }

    function _validateStakingLaunch(StakingLaunchConfig memory launch) private pure {
        require(launch.create2Deployer != address(0), "StackConfigBuilder: Staking CREATE2 deployer missing");
        require(launch.shellSalt != bytes32(0), "StackConfigBuilder: Staking shell salt missing");
        uint256 allocatorCount = launch.allocators.length;
        if (allocatorCount == 0) revert StakingLaunchAllocatorsEmpty();
        for (uint256 i; i < allocatorCount; ++i) {
            if (launch.allocators[i] == address(0)) revert StakingLaunchAllocatorMissing(i);
            for (uint256 j; j < i; ++j) {
                if (launch.allocators[j] == launch.allocators[i]) {
                    revert StakingLaunchAllocatorDuplicate(j, i);
                }
            }
        }

        uint256 sleeveCount = launch.sleeves.length;
        if (sleeveCount == 0) revert StakingLaunchSleevesEmpty();
        if (launch.sleeveAssetBindings.length != sleeveCount) {
            revert StakingLaunchBindingLengthMismatch(sleeveCount, launch.sleeveAssetBindings.length);
        }
        for (uint256 i; i < sleeveCount; ++i) {
            SleeveDeployerHelper.SleeveRequest memory sleeve = launch.sleeves[i];
            if (sleeve.implementation == address(0)) revert StakingLaunchSleeveImplementationMissing(i);
            if (launch.sleeveAssetBindings[i] == StackDeployer.SleeveAssetBinding.Explicit) {
                if (sleeve.asset == address(0)) revert StakingLaunchExplicitAssetMissing(i);
            } else if (sleeve.asset != address(0)) {
                revert StakingLaunchCoreBindingAssetMustBeZero(i, sleeve.asset);
            }
        }
    }

    function baseStackConfig(DeployConfig.ProtocolConfig memory defaults, address admin, address paxg, address xaut)
        internal
        view
        returns (StackDeployer.StackConfig memory cfg)
    {
        require(defaults.basket.assets.targetsPpm.length == 2, "config asset length mismatch");
        cfg = fullStackConfig(
            defaults,
            admin,
            address(0),
            _arr2(paxg, xaut),
            _uarr2(defaults.basket.assets.targetsPpm[0], defaults.basket.assets.targetsPpm[1]),
            _uarr2(defaults.basket.assets.goldRefGramsFp18[0], defaults.basket.assets.goldRefGramsFp18[1]),
            defaults.basket.cygldRefGramsFp18,
            defaults.basket.maxTotalSupply
        );
    }

    function fullStackConfig(
        DeployConfig.ProtocolConfig memory defaults,
        address admin,
        address allocator,
        address[] memory assets,
        uint256[] memory targets,
        uint256[] memory goldRefs,
        uint256 cygldRefGramsFp18,
        uint256 maxTotalSupply
    ) internal view returns (StackDeployer.StackConfig memory cfg) {
        cfg.bootstrapOwner = address(this);

        cfg.core.admin = admin;
        cfg.core.safeWallet = defaults.safeWallet;
        cfg.core.name = defaults.basket.name;
        cfg.core.symbol = defaults.basket.symbol;
        cfg.core.basketAssets = assets;
        cfg.core.basketTargetsPpm = targets;
        cfg.core.basketGoldRefGramsFp18 = goldRefs;
        cfg.core.cygldRefGramsFp18 = cygldRefGramsFp18;
        cfg.core.maxTotalSupply = maxTotalSupply;
        cfg.core.issuanceFeePpm = defaults.basket.issuanceFeePpm;
        cfg.core.redemptionFeePpm = defaults.basket.redemptionFeePpm;

        cfg.staking.safeWallet = defaults.safeWallet;
        cfg.staking.name = defaults.staking.name;
        cfg.staking.symbol = defaults.staking.symbol;
        cfg.staking.claimExpiry = defaults.queue.claimExpiry;
        cfg.staking.headSweepLimit = defaults.queue.headSweepLimit;
        cfg.staking.autoProcessMax = defaults.queue.autoProcessMax;
        cfg.staking.performanceFeePpm = defaults.performanceFeePpm;
        cfg.staking.fundManagerSwapAdapter = address(0);
        cfg.staking.withdrawers = defaults.staking.withdrawers;
        if (allocator != address(0)) {
            cfg.staking.allocators = new address[](1);
            cfg.staking.allocators[0] = allocator;
        }
        cfg.staking.create2Deployer = address(this);
        cfg.staking.shellSalt = keccak256(abi.encode("CYBERGOLD_STAKING_LOCAL_STACK_V1", address(this)));
    }

    function stakingOnlyConfig(
        DeployConfig.ProtocolConfig memory defaults,
        address allocator,
        address coreDiamond,
        address governanceDiamond,
        uint256 performanceFeePpm
    ) internal view returns (StackDeployer.StackConfig memory cfg) {
        cfg.skipCore = true;
        cfg.skipGovernance = true;

        cfg.staking.safeWallet = defaults.safeWallet;
        cfg.staking.name = defaults.staking.name;
        cfg.staking.symbol = defaults.staking.symbol;
        cfg.staking.coreDiamond = coreDiamond;
        cfg.staking.governanceDiamond = governanceDiamond;
        cfg.staking.withdrawers = new address[](0);
        cfg.staking.claimExpiry = defaults.queue.claimExpiry;
        cfg.staking.headSweepLimit = defaults.queue.headSweepLimit;
        cfg.staking.autoProcessMax = defaults.queue.autoProcessMax;
        cfg.staking.performanceFeePpm = performanceFeePpm;
        cfg.staking.fundManagerSwapAdapter = address(0);
        if (allocator != address(0)) {
            cfg.staking.allocators = new address[](1);
            cfg.staking.allocators[0] = allocator;
        }
        cfg.staking.create2Deployer = address(this);
        cfg.staking.shellSalt =
            keccak256(abi.encode("CYBERGOLD_STAKING_LOCAL_ONLY_V1", address(this), coreDiamond, governanceDiamond));
    }

    function governanceConfig(
        DeployConfig.ProtocolConfig memory defaults,
        address admin,
        uint256 executionDelay,
        uint256 tokenInitialSupply
    ) internal pure returns (GovTypes.DeployConfig memory cfg) {
        require(tokenInitialSupply > 0, "governance external supply must be nonzero");
        GovernanceDeployParams.validateCygovSupply(tokenInitialSupply, defaults.governance.tokenTreasurySupply);
        cfg.constructorOwner = admin;
        cfg.safeWallet = defaults.safeWallet;
        cfg.executionDelay = executionDelay;
        cfg.executionGracePeriod = defaults.governance.executionGracePeriod;
        cfg.name = defaults.governance.name;
        cfg.tokenSymbol = defaults.governance.tokenSymbol;
        cfg.tokenInitialHolder = admin;
        cfg.tokenInitialSupply = tokenInitialSupply;
        cfg.tokenTreasurySupply = defaults.governance.tokenTreasurySupply;
        cfg.votingDelay = defaults.governance.votingDelay;
        cfg.votingPeriod = defaults.governance.votingPeriod;
        cfg.proposalThresholdNumerator = defaults.governance.proposalThresholdNumerator;
        cfg.quorumNumerator = defaults.governance.quorumNumerator;
    }

    function _arr2(address a, address b) private pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _uarr2(uint256 a, uint256 b) private pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }
}
