// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {GovernorTestBase} from "../helpers/GovernorTestBase.sol";
import {GovernorSettingsFacet} from "../../src/facets/GovernorSettingsFacet.sol";
import {LibGovernorExternalSupply} from "../../src/libraries/LibGovernorExternalSupply.sol";

contract ExternalSupplyHarness {
    uint256 private _totalSupply;
    uint256 private _governanceBalance;

    function setSupply(uint256 totalSupply_, uint256 governanceBalance_) external {
        _totalSupply = totalSupply_;
        _governanceBalance = governanceBalance_;
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return account == address(this) ? _governanceBalance : 0;
    }

    function externalCygovSupply() external view returns (uint256) {
        return LibGovernorExternalSupply.externalCygovSupply();
    }
}

contract GovernorExternalSupplyPolicyTest is GovernorTestBase {
    function test_externalSupplySubtractsOnlyGovernanceBalance() public {
        ExternalSupplyHarness harness = new ExternalSupplyHarness();
        harness.setSupply(15_000_000 ether, 5_000_000 ether);

        assertEq(harness.externalCygovSupply(), 10_000_000 ether);
    }

    function test_externalSupplyFailsClosedForImpossibleGovernanceBalance() public {
        ExternalSupplyHarness harness = new ExternalSupplyHarness();
        harness.setSupply(1 ether, 1 ether + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                LibGovernorExternalSupply.GovernorInvalidTreasuryBalance.selector, 1 ether, 1 ether + 1
            )
        );
        harness.externalCygovSupply();
    }

    function test_thresholdPolicyUsesBoundedPartsPerBillionNumerator() public {
        GovernorSettingsFacet settings = new GovernorSettingsFacet();
        _enterInitContext(address(settings));
        settings.initSettings(2 days, 5 days, 100, 8, 2 days, 14 days);
        _exitInitContext(address(settings));

        assertEq(settings.proposalThresholdNumerator(), 100);

        vm.prank(address(settings));
        settings.setProposalThresholdNumerator(100, 250);
        assertEq(settings.proposalThresholdNumerator(), 250);
    }

    function test_quorumPolicySharesThePackedCurrentPolicyNamespace() public {
        GovernorSettingsFacet settings = new GovernorSettingsFacet();
        _enterInitContext(address(settings));
        settings.initSettings(2 days, 5 days, 100, 8, 2 days, 14 days);
        _exitInitContext(address(settings));

        assertEq(settings.quorumNumerator(), 8);

        vm.prank(address(settings));
        settings.setQuorumNumerator(8, 12);
        assertEq(settings.quorumNumerator(), 12);
    }
}
