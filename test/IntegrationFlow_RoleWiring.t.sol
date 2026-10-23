// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {MocksDeployer} from "script/helpers/MocksDeployer.sol";
import {DeployedStack} from "script/helpers/DeployedStack.sol";
import {StackConfigBuilder} from "script/helpers/StackConfigBuilder.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";

import {ICyberGoldCore} from "packages/1_core/src/interfaces/ICyberGoldCore.sol";
import {LensFacet as CoreLensFacet} from "packages/1_core/src/facets/LensFacet.sol";

import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {LensFacet as StakingLensFacet} from "packages/3_staking/src/facets/LensFacet.sol";
import {SleeveRegistryFacet} from "packages/3_staking/src/facets/SleeveRegistryFacet.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "packages/3_staking/src/deploy/SleeveRequestBuilder.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";

import {GovernorCoreFacet} from "packages/2_governance/src/facets/GovernorCoreFacet.sol";
import {GovernorSettingsFacet} from "packages/2_governance/src/facets/GovernorSettingsFacet.sol";
import {MockSafeSingleton, MockSafeWallet} from "shared/helpers/MockSafeWallet.sol";

interface ISafeOwners {
    function getOwners() external view returns (address[] memory);
}

contract IntegrationFlow_RoleWiring is Test {
    address internal admin = address(this);

    struct Stack {
        ICyberGoldCore controller;
        address coreDiamond;
        address governanceDiamond;
        address stakingDiamond;
        address safeWallet;
    }

    function test_atomic_launch_matches_authority_and_postflight_assumptions() external {
        bool useDeployed = vm.envOr("USE_DEPLOYED", uint256(0)) == 1;
        Stack memory s;
        Expectations memory expected;
        IVotes votes;

        if (useDeployed) {
            (s, expected, votes) = _loadDeployed();
        } else {
            (s, expected, votes) = _deployStack();
        }

        _assertCoreAssumptions(s, expected);
        _assertStakingAssumptions(s, expected);
        _assertGovernanceAssumptions(s, expected, votes);
        _assertEmergencyAuthority(s);
    }

    function test_zero_sleeve_asset_requires_explicit_core_binding() external {
        SleeveDeployerHelper.SleeveRequest[] memory sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(0), true, 0);
        StackDeployer.SleeveAssetBinding[] memory bindings = new StackDeployer.SleeveAssetBinding[](0);

        vm.expectRevert(abi.encodeWithSelector(StackDeployer.StackSleeveExplicitAssetMissing.selector, 0));
        this.bindSleeveAssets(sleeves, bindings, address(0xC0));

        bindings = new StackDeployer.SleeveAssetBinding[](1);
        bindings[0] = StackDeployer.SleeveAssetBinding.CoreDiamond;
        SleeveDeployerHelper.SleeveRequest[] memory resolved = this.bindSleeveAssets(sleeves, bindings, address(0xC0));
        assertEq(resolved[0].asset, address(0xC0), "typed Core binding");
    }

    function test_full_stack_always_binds_staking_to_the_just_deployed_core() external {
        StackDeployer.StackConfig memory cfg = _buildConfig();
        address staleConfiguredCore = address(0xDEAD);
        cfg.staking.coreDiamond = staleConfiguredCore;

        StackDeployer.StackDeployed memory deployed = StackDeployer.deployStack(cfg);
        StakingLensFacet.SystemState memory state = StakingLensFacet(deployed.stakingDiamond).systemState();

        assertTrue(deployed.coreDiamond != staleConfiguredCore, "test requires a distinct deployed Core");
        assertEq(state.asset, deployed.coreDiamond, "Staking asset must be the deployed Core");
        assertEq(deployed.sleeves[0].asset, deployed.coreDiamond, "Core-bound Sleeve must use deployed Core");
    }

    function bindSleeveAssets(
        SleeveDeployerHelper.SleeveRequest[] memory sleeves,
        StackDeployer.SleeveAssetBinding[] memory bindings,
        address coreDiamond
    ) external pure returns (SleeveDeployerHelper.SleeveRequest[] memory) {
        return StackDeployer.bindSleeveAssets(sleeves, bindings, coreDiamond);
    }

    struct Expectations {
        bool strict;
        uint256 basketSize;
        uint64 claimExpiry;
        uint256 headSweepLimit;
        uint256 autoProcessMax;
        uint256 govExecutionDelay;
        uint256 govExecutionGracePeriod;
        uint256 quorumNumerator;
    }

    function _loadDeployed() internal view returns (Stack memory s, Expectations memory expected, IVotes votes) {
        DeployedStack.Protocol memory p = DeployedStack.loadProtocol(vm);
        DeployedStack.Expectations memory exp = DeployedStack.loadExpectations(vm);

        s.controller = ICyberGoldCore(p.coreDiamond);
        s.coreDiamond = p.coreDiamond;
        s.governanceDiamond = p.governanceDiamond;
        s.stakingDiamond = p.stakingDiamond;
        s.safeWallet = DeployedStack.loadSafe(vm).safe;

        expected.strict = false;
        expected.claimExpiry = exp.claimExpiry;
        expected.headSweepLimit = exp.headSweepLimit;
        expected.autoProcessMax = exp.autoProcessMax;
        expected.govExecutionDelay = exp.govExecutionDelay;
        expected.govExecutionGracePeriod = exp.govExecutionGracePeriod;
        expected.quorumNumerator = exp.quorumNumerator;

        votes = IVotes(p.governanceDiamond);
    }

    function _deployStack() internal returns (Stack memory s, Expectations memory expected, IVotes votes) {
        StackDeployer.StackConfig memory cfg = _buildConfig();
        StackDeployer.StackDeployed memory d = StackDeployer.deployStack(cfg);

        votes = IVotes(address(d.governance.diamond));
        vm.prank(admin);
        votes.delegate(admin);
        vm.warp(block.timestamp + 1);

        s.controller = ICyberGoldCore(address(d.core.diamond));
        s.coreDiamond = d.coreDiamond;
        s.governanceDiamond = address(d.governance.diamond);
        s.stakingDiamond = address(d.staking.diamond);
        s.safeWallet = cfg.core.safeWallet;

        expected.strict = true;
        expected.basketSize = cfg.core.basketAssets.length;
        expected.claimExpiry = cfg.staking.claimExpiry;
        expected.headSweepLimit = cfg.staking.headSweepLimit;
        expected.autoProcessMax = cfg.staking.autoProcessMax;
        expected.govExecutionDelay = cfg.governance.executionDelay;
        expected.govExecutionGracePeriod = cfg.governance.executionGracePeriod;
        expected.quorumNumerator = cfg.governance.quorumNumerator;
    }

    function _buildConfig() internal returns (StackDeployer.StackConfig memory cfg) {
        (address paxg, address xaut) = (new MocksDeployer()).deployAll();

        DeployConfig.ProtocolConfig memory defaults = DeployConfig.loadProtocol(vm);
        address[] memory owners = new address[](1);
        owners[0] = admin;
        defaults.safeWallet = address(new MockSafeWallet(address(new MockSafeSingleton()), owners, 1));
        cfg = StackConfigBuilder.baseStackConfig(defaults, admin, paxg, xaut);
        cfg.governance = StackConfigBuilder.governanceConfig(defaults, admin, 1 days, 1_000_000e18);
        cfg.staking.allocators = new address[](1);
        cfg.staking.allocators[0] = admin;
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(0), true, 0);
        cfg.sleeveAssetBindings = new StackDeployer.SleeveAssetBinding[](1);
        cfg.sleeveAssetBindings[0] = StackDeployer.SleeveAssetBinding.CoreDiamond;
    }

    function _assertCoreAssumptions(Stack memory s, Expectations memory expected) internal view {
        CoreLensFacet coreLens = CoreLensFacet(address(s.controller));
        uint256 issueFee = coreLens.issuanceFeePpm();
        uint256 redeemFee = coreLens.redemptionFeePpm();

        uint256 basketSize = coreLens.basketAssets().length;
        if (expected.strict) {
            assertEq(basketSize, expected.basketSize, "basket size");
            assertEq(issueFee, 1_000, "issuance fee");
            assertEq(redeemFee, 1_000, "redemption fee");
        } else {
            assertTrue(basketSize > 0, "basket size");
        }
        assertEq(s.coreDiamond, address(s.controller), "native reserve/controller address");
        assertEq(coreLens.treasury(), s.governanceDiamond, "native treasury address");
    }

    function _assertStakingAssumptions(Stack memory s, Expectations memory expected) internal view {
        StakingLensFacet lens = StakingLensFacet(s.stakingDiamond);

        StakingLensFacet.SystemState memory sys = lens.systemState();
        assertTrue(sys.paused, "Staking must await Safe post-flight activation");
        assertGt(SleeveRegistryFacet(s.stakingDiamond).sleeves().length, 0, "atomic Sleeve roster");

        DefaultAdminAccessControlFacet authority = DefaultAdminAccessControlFacet(s.stakingDiamond);
        bytes32 defaultAdminRole = authority.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = authority.upgraderRole();
        assertEq(authority.defaultAdmin(), s.governanceDiamond, "Governance default admin");
        assertEq(authority.getRoleMemberCount(defaultAdminRole), 1, "single default admin");
        assertEq(authority.getRoleMember(defaultAdminRole, 0), s.governanceDiamond, "default admin member");
        assertEq(authority.getRoleMemberCount(upgraderRole), 1, "single upgrader");
        assertEq(authority.getRoleMember(upgraderRole, 0), s.governanceDiamond, "upgrader member");
        assertFalse(authority.hasRole(defaultAdminRole, s.safeWallet), "Safe must not be admin");
        assertFalse(authority.hasRole(upgraderRole, s.safeWallet), "Safe must not be upgrader");
        if (expected.strict) {
            assertEq(lens.headId(), 0, "queue headId");
            assertEq(lens.tailId(), 0, "queue tailId");
        }
        assertEq(uint256(lens.claimExpiry()), uint256(expected.claimExpiry), "queue claimExpiry");
        assertEq(lens.headSweepLimit(), expected.headSweepLimit, "queue headSweepLimit");
        assertEq(lens.autoProcessMax(), expected.autoProcessMax, "queue autoProcessMax");
    }

    function _assertGovernanceAssumptions(Stack memory s, Expectations memory expected, IVotes votes) internal view {
        GovernorSettingsFacet settings = GovernorSettingsFacet(s.governanceDiamond);
        if (expected.govExecutionDelay != 0) {
            assertEq(settings.executionDelay(), expected.govExecutionDelay, "governor execution delay");
        } else {
            assertTrue(settings.executionDelay() >= 1 days, "governor execution delay");
        }
        if (expected.govExecutionGracePeriod != 0) {
            assertEq(
                settings.executionGracePeriod(), expected.govExecutionGracePeriod, "governor execution grace period"
            );
        } else {
            assertTrue(settings.executionGracePeriod() >= 1 days, "governor execution grace period");
        }

        GovernorCoreFacet gov = GovernorCoreFacet(payable(s.governanceDiamond));
        assertEq(gov.clock(), uint48(block.timestamp), "governor clock");
        assertEq(address(votes), s.governanceDiamond, "vote token address");

        if (expected.quorumNumerator != 0) {
            assertEq(settings.quorumNumerator(), expected.quorumNumerator, "governor quorum numerator");
        } else {
            assertTrue(settings.quorumNumerator() >= 1, "governor quorum numerator");
        }
    }

    function _assertEmergencyAuthority(Stack memory s) internal view {
        address[] memory owners = ISafeOwners(s.safeWallet).getOwners();
        require(owners.length != 0, "safe owners missing");

        _assertSafeAuthority(address(s.controller), s.safeWallet, owners);
        _assertSafeAuthority(s.stakingDiamond, s.safeWallet, owners);
        _assertSafeAuthority(s.governanceDiamond, s.safeWallet, owners);
    }

    function _assertSafeAuthority(address target, address safeAddr, address[] memory owners) internal view {
        PausableFacet pause = PausableFacet(target);
        assertEq(pause.safeWallet(), safeAddr, "configured Safe wallet");
        assertFalse(pause.canPause(safeAddr), "Safe wallet should not pause");
        assertTrue(pause.canUnpause(safeAddr), "Safe wallet cannot unpause");
        for (uint256 i; i < owners.length; ++i) {
            assertTrue(pause.canPause(owners[i]), "Safe owner cannot pause");
            assertFalse(pause.canUnpause(owners[i]), "Safe owner should not unpause");
        }
    }
}
