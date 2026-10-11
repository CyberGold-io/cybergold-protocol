// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {StakingDiamond} from "packages/3_staking/src/diamond/StakingDiamond.sol";
import {VaultFacet} from "packages/3_staking/src/facets/VaultFacet.sol";
import {QueueFacet} from "packages/3_staking/src/facets/QueueFacet.sol";
import {FundManagerFacet} from "packages/3_staking/src/facets/FundManagerFacet.sol";
import {SleeveRegistryFacet} from "packages/3_staking/src/facets/SleeveRegistryFacet.sol";
import {CustodyFacet} from "packages/3_staking/src/facets/CustodyFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {StackConfigBuilder} from "script/helpers/StackConfigBuilder.sol";
import {ICyberGoldCore} from "packages/1_core/src/interfaces/ICyberGoldCore.sol";
import {MockSafeSingleton, MockSafeWallet} from "shared/helpers/MockSafeWallet.sol";
import {TestUtils} from "./TestUtils.sol";

struct DiamondStack {
    StakingDiamond diamond;
    VaultFacet vault;
    QueueFacet queue;
    FundManagerFacet fundManager;
    SleeveRegistryFacet registry;
    CustodyFacet custody;
    DefaultAdminAccessControlFacet access;
    PausableFacet pause;
    address[] sleeves;
    address[] sleeveAssets;
    bool[] sleeveApproved;
    address coreDiamond;
    address governanceDiamond;
}

/// @notice Shared helper to deploy the staking diamond stack for integration tests.
abstract contract DiamondStakingTestBase is Test {
    /// @notice Convenience builder for staking-only scenarios (no basket/governance).
    function stakingOnlyConfig(
        address admin,
        address pauser,
        address allocator,
        address coreDiamond,
        address governanceDiamond,
        uint256 performanceFeePpm
    ) internal returns (StackDeployer.StackConfig memory cfg) {
        DeployConfig.ProtocolConfig memory defaults = DeployConfig.loadProtocol(vm);
        defaults.safeWallet = _deploySafeWallet(admin, pauser, governanceDiamond);
        cfg = StackConfigBuilder.stakingOnlyConfig(
            defaults, allocator, coreDiamond, governanceDiamond, performanceFeePpm
        );
    }

    /// @notice Convenience builder for full-stack basket+staking deployments.
    function fullStackConfig(
        address admin,
        address pauser,
        address allocator,
        address[] memory assets,
        uint256[] memory targets,
        uint256[] memory goldRefs,
        uint256 cygldRefGramsFp18
    ) internal returns (StackDeployer.StackConfig memory cfg) {
        DeployConfig.ProtocolConfig memory defaults = DeployConfig.loadProtocol(vm);
        defaults.safeWallet = _deploySafeWallet(admin, pauser, address(0));
        cfg = StackConfigBuilder.fullStackConfig(
            defaults, admin, allocator, assets, targets, goldRefs, cygldRefGramsFp18, type(uint256).max
        );
        cfg.governance = StackConfigBuilder.governanceConfig(defaults, admin, 1 days, 1_000_000e18);
    }

    function _deploySafeWallet(address admin, address additionalOwner, address excludedOwner)
        private
        returns (address)
    {
        bool includeAdmin = admin != address(0) && admin != excludedOwner;
        bool includeAdditional =
            additionalOwner != address(0) && additionalOwner != excludedOwner && additionalOwner != admin;
        uint256 ownerCount = (includeAdmin ? 1 : 0) + (includeAdditional ? 1 : 0);
        if (ownerCount == 0) ownerCount = 1;

        address[] memory owners = new address[](ownerCount);
        uint256 next;
        if (includeAdmin) owners[next++] = admin;
        if (includeAdditional) owners[next++] = additionalOwner;
        if (next == 0) {
            address fallbackOwner = address(0x5AFE);
            if (fallbackOwner == excludedOwner) fallbackOwner = address(0x5AFF);
            owners[0] = fallbackOwner;
        }
        return address(new MockSafeWallet(address(new MockSafeSingleton()), owners, ownerCount));
    }

    function _loadInitialBasket()
        internal
        view
        returns (
            address[] memory assets,
            uint256[] memory targets,
            uint256[] memory goldRefs,
            uint256 cygldRefGramsFp18
        )
    {
        DeployConfig.ProtocolConfig memory cfg = DeployConfig.loadProtocol(vm);
        assets = cfg.basket.assets.addresses;
        targets = cfg.basket.assets.targetsPpm;
        goldRefs = cfg.basket.assets.goldRefGramsFp18;
        cygldRefGramsFp18 = cfg.basket.cygldRefGramsFp18;
    }

    function _primeBasketAssets(address controller, address[] memory assets, uint256 netCygldOut) internal {
        uint256 len = assets.length;
        (, uint256[] memory amountsIn, address[] memory orderedBasketAssets) =
            ICyberGoldCore(controller).previewIssueFromBasketExactOut(netCygldOut);
        require(len == amountsIn.length, "basket length mismatch");
        require(len == orderedBasketAssets.length, "ordered basket length mismatch");
        for (uint256 i; i < len; ++i) {
            require(assets[i] == orderedBasketAssets[i], "ordered basket mismatch");
            TestUtils.mintMock(assets[i], address(this), amountsIn[i]);
            IERC20(assets[i]).approve(controller, type(uint256).max);
        }
    }

    function deployStaking(StackDeployer.StackConfig memory cfg)
        internal
        returns (DiamondStack memory stack, StackDeployer.StackDeployed memory deployed)
    {
        deployed = StackDeployer.deployStack(cfg);

        if (!cfg.skipCore) {
            PausableFacet corePause = PausableFacet(deployed.coreDiamond);
            assertTrue(corePause.paused(), "Core must remain paused through stack deployment");
            vm.prank(corePause.safeWallet());
            corePause.unpause();
        }

        StakingDiamond diamond = deployed.staking.diamond;
        stack.diamond = diamond;
        stack.vault = VaultFacet(address(diamond));
        stack.queue = QueueFacet(address(diamond));
        stack.fundManager = FundManagerFacet(address(diamond));
        stack.registry = SleeveRegistryFacet(address(diamond));
        stack.custody = CustodyFacet(address(diamond));
        stack.access = DefaultAdminAccessControlFacet(address(diamond));
        stack.pause = PausableFacet(address(diamond));
        (stack.sleeves, stack.sleeveAssets, stack.sleeveApproved) = _flattenSleeves(deployed.sleeves);
        stack.coreDiamond = deployed.coreDiamond;
        stack.governanceDiamond = deployed.governanceDiamond;

        assertTrue(stack.pause.paused(), "Staking must remain paused through stack deployment");
    }

    /// @notice Model the Safe-only post-flight activation after launch checks pass.
    function _activateStaking(DiamondStack memory stack) internal {
        assertTrue(stack.pause.paused(), "Staking must await Safe post-flight activation");
        vm.prank(stack.pause.safeWallet());
        stack.pause.unpause();
        assertFalse(stack.pause.paused(), "Safe post-flight activation must unpause Staking");
    }

    function _flattenSleeves(SleeveDeployerHelper.SleeveDeployment[] memory sleeves)
        private
        pure
        returns (address[] memory addrs, address[] memory assets, bool[] memory approvals)
    {
        uint256 len = sleeves.length;
        addrs = new address[](len);
        assets = new address[](len);
        approvals = new bool[](len);
        for (uint256 i; i < len; ++i) {
            addrs[i] = sleeves[i].sleeve;
            assets[i] = sleeves[i].asset;
            approvals[i] = sleeves[i].approve;
        }
    }
}
