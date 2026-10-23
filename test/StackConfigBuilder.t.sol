// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {StackConfigBuilder} from "script/helpers/StackConfigBuilder.sol";
import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";

contract StackConfigBuilderHarness {
    function build(
        DeployConfig.ProtocolConfig memory protocol,
        address bootstrapOwner,
        StackConfigBuilder.StakingLaunchConfig memory launch
    ) external pure returns (StackDeployer.StackConfig memory) {
        return StackConfigBuilder.fromProtocolConfig(protocol, bootstrapOwner, launch);
    }

    function launchFromEnv(Vm vm_) external view returns (StackConfigBuilder.StakingLaunchConfig memory) {
        return StackConfigBuilder.stakingLaunchFromEnv(vm_);
    }

    function sleeveAssetBindings(uint256[] memory raw)
        external
        pure
        returns (StackDeployer.SleeveAssetBinding[] memory)
    {
        return StackConfigBuilder.sleeveAssetBindings(raw);
    }
}

contract StackConfigBuilderTest is Test {
    StackConfigBuilderHarness internal harness = new StackConfigBuilderHarness();

    function testFromProtocolConfigPreservesExplicitOrderedStakingLaunch() external view {
        address bootstrapOwner = address(0xB007);
        StackConfigBuilder.StakingLaunchConfig memory launch = _validLaunch();

        StackDeployer.StackConfig memory cfg = harness.build(
            DeployConfig.ProtocolConfig({
                admin: address(0),
                safeWallet: address(0),
                allocator: address(0),
                performanceFeePpm: 0,
                queue: DeployConfig.QueueConfig({claimExpiry: 0, headSweepLimit: 0, autoProcessMax: 0}),
                basket: _emptyBasket(),
                staking: DeployConfig.StakingConfig({name: "", symbol: "", withdrawers: new address[](0)}),
                governance: _emptyGovernance()
            }),
            bootstrapOwner,
            launch
        );

        assertEq(cfg.bootstrapOwner, bootstrapOwner);
        assertEq(cfg.staking.create2Deployer, launch.create2Deployer);
        assertEq(cfg.staking.shellSalt, launch.shellSalt);
        assertEq(cfg.staking.fundManagerSwapAdapter, launch.fundManagerSwapAdapter);
        assertEq(cfg.staking.allocators, launch.allocators);
        assertEq(cfg.sleeves.length, 2);
        assertEq(cfg.sleeves[0].implementation, address(0x501));
        assertEq(cfg.sleeves[0].asset, address(0xA11));
        assertEq(cfg.sleeves[1].implementation, address(0x502));
        assertEq(cfg.sleeves[1].asset, address(0));
        assertEq(uint256(cfg.sleeveAssetBindings[0]), uint256(StackDeployer.SleeveAssetBinding.Explicit));
        assertEq(uint256(cfg.sleeveAssetBindings[1]), uint256(StackDeployer.SleeveAssetBinding.CoreDiamond));
    }

    function testFromProtocolConfigRejectsMissingBootstrapCreate2AndSalt() external {
        StackConfigBuilder.StakingLaunchConfig memory launch = _validLaunch();
        DeployConfig.ProtocolConfig memory protocol;

        vm.expectRevert("StackConfigBuilder: bootstrap owner missing");
        harness.build(protocol, address(0), launch);

        launch.create2Deployer = address(0);
        vm.expectRevert("StackConfigBuilder: Staking CREATE2 deployer missing");
        harness.build(protocol, address(this), launch);

        launch = _validLaunch();
        launch.shellSalt = bytes32(0);
        vm.expectRevert("StackConfigBuilder: Staking shell salt missing");
        harness.build(protocol, address(this), launch);
    }

    function testFromProtocolConfigRejectsGovernanceSupplyAboveVotesSafeBoundary() external {
        StackConfigBuilder.StakingLaunchConfig memory launch = _validLaunch();
        DeployConfig.ProtocolConfig memory protocol;
        protocol.governance.tokenInitialSupply = type(uint208).max;
        protocol.governance.tokenTreasurySupply = 1;

        vm.expectRevert("CYGOV_TOTAL_SUPPLY exceeds ERC20Votes safe supply");
        harness.build(protocol, address(this), launch);
    }

    function testFromProtocolConfigRejectsEmptyMissingAndDuplicateAllocators() external {
        StackConfigBuilder.StakingLaunchConfig memory launch = _validLaunch();
        DeployConfig.ProtocolConfig memory protocol;

        launch.allocators = new address[](0);
        vm.expectRevert(StackConfigBuilder.StakingLaunchAllocatorsEmpty.selector);
        harness.build(protocol, address(this), launch);

        launch = _validLaunch();
        launch.allocators[1] = address(0);
        vm.expectRevert(abi.encodeWithSelector(StackConfigBuilder.StakingLaunchAllocatorMissing.selector, 1));
        harness.build(protocol, address(this), launch);

        launch = _validLaunch();
        launch.allocators[1] = launch.allocators[0];
        vm.expectRevert(abi.encodeWithSelector(StackConfigBuilder.StakingLaunchAllocatorDuplicate.selector, 0, 1));
        harness.build(protocol, address(this), launch);
    }

    function testFromProtocolConfigRejectsEmptyOrMalformedSleeveRoster() external {
        StackConfigBuilder.StakingLaunchConfig memory launch = _validLaunch();
        DeployConfig.ProtocolConfig memory protocol;

        launch.sleeves = new SleeveDeployerHelper.SleeveRequest[](0);
        launch.sleeveAssetBindings = new StackDeployer.SleeveAssetBinding[](0);
        vm.expectRevert(StackConfigBuilder.StakingLaunchSleevesEmpty.selector);
        harness.build(protocol, address(this), launch);

        launch = _validLaunch();
        launch.sleeveAssetBindings = new StackDeployer.SleeveAssetBinding[](1);
        vm.expectRevert(abi.encodeWithSelector(StackConfigBuilder.StakingLaunchBindingLengthMismatch.selector, 2, 1));
        harness.build(protocol, address(this), launch);

        launch = _validLaunch();
        launch.sleeves[0].implementation = address(0);
        vm.expectRevert(abi.encodeWithSelector(StackConfigBuilder.StakingLaunchSleeveImplementationMissing.selector, 0));
        harness.build(protocol, address(this), launch);

        launch = _validLaunch();
        launch.sleeves[0].asset = address(0);
        vm.expectRevert(abi.encodeWithSelector(StackConfigBuilder.StakingLaunchExplicitAssetMissing.selector, 0));
        harness.build(protocol, address(this), launch);

        launch = _validLaunch();
        launch.sleeves[1].asset = address(0xBAD);
        vm.expectRevert(
            abi.encodeWithSelector(
                StackConfigBuilder.StakingLaunchCoreBindingAssetMustBeZero.selector, 1, address(0xBAD)
            )
        );
        harness.build(protocol, address(this), launch);
    }

    function testStakingLaunchFromEnvParsesExactOrderedRosterAndBindings() external {
        _setLaunchEnv("0,1");

        StackConfigBuilder.StakingLaunchConfig memory launch = harness.launchFromEnv(vm);

        assertEq(launch.create2Deployer, address(0xC2));
        assertEq(launch.shellSalt, bytes32(uint256(1)));
        assertEq(launch.fundManagerSwapAdapter, address(0xF00D));
        assertEq(launch.allocators.length, 2);
        assertEq(launch.allocators[0], address(0xA1));
        assertEq(launch.allocators[1], address(0xA2));
        assertEq(launch.sleeves.length, 2);
        assertEq(launch.sleeves[0].implementation, address(0x501));
        assertEq(launch.sleeves[0].asset, address(0x601));
        assertEq(launch.sleeves[1].implementation, address(0x502));
        assertEq(launch.sleeves[1].asset, address(0));
        assertTrue(launch.sleeves[0].approve);
        assertFalse(launch.sleeves[1].approve);
        assertTrue(launch.sleeves[0].initialOperational);
        assertFalse(launch.sleeves[1].initialOperational);
        assertFalse(launch.sleeves[0].initialPaused);
        assertTrue(launch.sleeves[1].initialPaused);
        assertEq(launch.sleeves[0].principalCap, 7);
        assertEq(launch.sleeves[1].principalCap, 8);
        assertEq(uint256(launch.sleeveAssetBindings[0]), uint256(StackDeployer.SleeveAssetBinding.Explicit));
        assertEq(uint256(launch.sleeveAssetBindings[1]), uint256(StackDeployer.SleeveAssetBinding.CoreDiamond));
    }

    function testStakingLaunchFromEnvRejectsUnknownBindingKind() external {
        uint256[] memory rawBindings = new uint256[](2);
        rawBindings[0] = 0;
        rawBindings[1] = 2;

        vm.expectRevert(abi.encodeWithSelector(StackConfigBuilder.StakingLaunchBindingKindInvalid.selector, 1, 2));
        harness.sleeveAssetBindings(rawBindings);
    }

    function _validLaunch() private pure returns (StackConfigBuilder.StakingLaunchConfig memory launch) {
        launch.create2Deployer = address(0xC2);
        launch.shellSalt = keccak256("staking-shell-test");
        launch.fundManagerSwapAdapter = address(0xF00D);
        launch.allocators = new address[](2);
        launch.allocators[0] = address(0xA1);
        launch.allocators[1] = address(0xA2);
        launch.sleeves = new SleeveDeployerHelper.SleeveRequest[](2);
        launch.sleeves[0] = SleeveDeployerHelper.SleeveRequest({
            implementation: address(0x501),
            asset: address(0xA11),
            approve: true,
            initialOperational: true,
            initialPaused: false,
            principalCap: 7,
            initType: SleeveDeployerHelper.InitType.Basic,
            initArgs: ""
        });
        launch.sleeves[1] = SleeveDeployerHelper.SleeveRequest({
            implementation: address(0x502),
            asset: address(0),
            approve: false,
            initialOperational: true,
            initialPaused: false,
            principalCap: 8,
            initType: SleeveDeployerHelper.InitType.Basic,
            initArgs: ""
        });
        launch.sleeveAssetBindings = new StackDeployer.SleeveAssetBinding[](2);
        launch.sleeveAssetBindings[0] = StackDeployer.SleeveAssetBinding.Explicit;
        launch.sleeveAssetBindings[1] = StackDeployer.SleeveAssetBinding.CoreDiamond;
    }

    function _setLaunchEnv(string memory bindings) private {
        vm.setEnv("STAKING_CREATE2_DEPLOYER", "0x00000000000000000000000000000000000000c2");
        vm.setEnv("STAKING_SHELL_SALT", "0x0000000000000000000000000000000000000000000000000000000000000001");
        vm.setEnv("STAKING_FUND_MANAGER_SWAP_ADAPTER", "0x000000000000000000000000000000000000f00d");
        vm.setEnv(
            "STAKING_ALLOCATORS",
            "0x00000000000000000000000000000000000000a1,0x00000000000000000000000000000000000000a2"
        );
        vm.setEnv(
            "STAKING_SLEEVE_IMPLEMENTATIONS",
            "0x0000000000000000000000000000000000000501,0x0000000000000000000000000000000000000502"
        );
        vm.setEnv(
            "STAKING_SLEEVE_ASSETS",
            "0x0000000000000000000000000000000000000601,0x0000000000000000000000000000000000000000"
        );
        vm.setEnv("STAKING_SLEEVE_APPROVALS", "true,false");
        vm.setEnv("STAKING_SLEEVE_OPERATIONAL", "true,false");
        vm.setEnv("STAKING_SLEEVE_LOCAL_PAUSED", "false,true");
        vm.setEnv("STAKING_SLEEVE_PRINCIPAL_CAPS", "7,8");
        vm.setEnv("STAKING_SLEEVE_INIT_TYPES", "0,0");
        vm.setEnv("STAKING_SLEEVE_INIT_ARGS", "0x00,0x00");
        vm.setEnv("STAKING_SLEEVE_ASSET_BINDINGS", bindings);
    }

    function _emptyBasket() private pure returns (DeployConfig.BasketConfig memory basket) {
        basket.assets.names = new string[](0);
        basket.assets.symbols = new string[](0);
        basket.assets.addresses = new address[](0);
        basket.assets.targetsPpm = new uint256[](0);
        basket.assets.goldRefGramsFp18 = new uint256[](0);
    }

    function _emptyGovernance() private pure returns (DeployConfig.GovernanceConfig memory governance) {
        return governance;
    }
}
