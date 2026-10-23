// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";

import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {MocksDeployer} from "script/helpers/MocksDeployer.sol";
import {StackConfigBuilder} from "script/helpers/StackConfigBuilder.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "packages/3_staking/src/deploy/SleeveRequestBuilder.sol";

import {EtherNotAccepted} from "diamond-infra/diamond/ProtocolDiamond.sol";
import {LensFacet as CoreLensFacet} from "packages/1_core/src/facets/LensFacet.sol";
import {LensFacet as StakingLensFacet} from "packages/3_staking/src/facets/LensFacet.sol";
import {GovernorCoreFacet} from "packages/2_governance/src/facets/GovernorCoreFacet.sol";
import {MockSafeSingleton, MockSafeWallet} from "shared/helpers/MockSafeWallet.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";

contract IntegrationFlow_DiamondEtherGuards is Test {
    address internal admin = address(this);

    function test_protocolDiamondsRejectNativeEthEntryPoints() external {
        StackDeployer.StackDeployed memory deployed = _deployStack();

        _assertReceiveRejectsNativeEth(address(deployed.core.diamond));
        _assertReceiveRejectsNativeEth(address(deployed.staking.diamond));
        _assertReceiveRejectsNativeEth(address(deployed.governance.diamond));

        _assertFallbackRejectsValue(address(deployed.core.diamond), CoreLensFacet.maxTotalSupply.selector);
        _assertFallbackRejectsValue(address(deployed.staking.diamond), StakingLensFacet.systemState.selector);
        _assertFallbackRejectsValue(address(deployed.governance.diamond), GovernorCoreFacet.votingDelay.selector);
    }

    function _deployStack() private returns (StackDeployer.StackDeployed memory) {
        (address paxg, address xaut) = (new MocksDeployer()).deployAll();

        DeployConfig.ProtocolConfig memory defaults = DeployConfig.loadProtocol(vm);
        address[] memory owners = new address[](1);
        owners[0] = admin;
        defaults.safeWallet = address(new MockSafeWallet(address(new MockSafeSingleton()), owners, 1));
        StackDeployer.StackConfig memory cfg = StackConfigBuilder.baseStackConfig(defaults, admin, paxg, xaut);
        cfg.governance = StackConfigBuilder.governanceConfig(defaults, admin, 1 days, 1_000_000e18);
        cfg.staking.allocators = new address[](1);
        cfg.staking.allocators[0] = admin;
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(0), true, 0);
        cfg.sleeveAssetBindings = new StackDeployer.SleeveAssetBinding[](1);
        cfg.sleeveAssetBindings[0] = StackDeployer.SleeveAssetBinding.CoreDiamond;
        return StackDeployer.deployStack(cfg);
    }

    function _assertReceiveRejectsNativeEth(address diamond) private {
        vm.deal(address(this), address(this).balance + 1 wei);
        uint256 balanceBefore = diamond.balance;

        (bool ok, bytes memory err) = payable(diamond).call{value: 1 wei}("");

        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(EtherNotAccepted.selector));
        assertEq(diamond.balance, balanceBefore);
    }

    function _assertFallbackRejectsValue(address diamond, bytes4 selector) private {
        vm.deal(address(this), address(this).balance + 1 wei);
        uint256 balanceBefore = diamond.balance;

        (bool ok,) = diamond.call{value: 1 wei}(abi.encodeWithSelector(selector));

        assertFalse(ok);
        assertEq(diamond.balance, balanceBefore);
    }
}
