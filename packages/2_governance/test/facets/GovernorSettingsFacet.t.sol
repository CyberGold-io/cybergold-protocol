// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {GovernorTestBase} from "../helpers/GovernorTestBase.sol";
import {GovernorSettingsFacet} from "../../src/facets/GovernorSettingsFacet.sol";

contract GovernorSettingsFacetTest is GovernorTestBase {
    function test_initStoresSixPolicyValuesInOneNamespace() public {
        GovernorSettingsFacet settings = _newSettings();

        assertEq(settings.votingDelay(), 2 days);
        assertEq(settings.votingPeriod(), 5 days);
        assertEq(settings.proposalThresholdNumerator(), 100);
        assertEq(settings.quorumNumerator(), 8);
        assertEq(settings.executionDelay(), 2 days);
        assertEq(settings.executionGracePeriod(), 14 days);

        bytes32 policySlot = keccak256("cybergold.governance.policy.storage");
        assertNotEq(vm.load(address(settings), policySlot), bytes32(0));
        assertEq(vm.load(address(settings), keccak256("cybergold.governance.settings.storage")), bytes32(0));
        assertEq(vm.load(address(settings), keccak256("cybergold.governance.quorum.storage")), bytes32(0));
    }

    function test_governanceCanUpdateEveryPolicyWithExpectedCurrentBinding() public {
        GovernorSettingsFacet settings = _newSettings();

        vm.startPrank(address(settings));
        settings.setVotingDelay(2 days, 3 days);
        settings.setVotingPeriod(5 days, 6 days);
        settings.setProposalThresholdNumerator(100, 200);
        settings.setQuorumNumerator(8, 12);
        settings.setExecutionDelay(2 days, 3 days);
        settings.setExecutionGracePeriod(14 days, 10 days);
        vm.stopPrank();

        assertEq(settings.votingDelay(), 3 days);
        assertEq(settings.votingPeriod(), 6 days);
        assertEq(settings.proposalThresholdNumerator(), 200);
        assertEq(settings.quorumNumerator(), 12);
        assertEq(settings.executionDelay(), 3 days);
        assertEq(settings.executionGracePeriod(), 10 days);
    }

    function test_onlyGovernanceCanMutatePolicy() public {
        GovernorSettingsFacet settings = _newSettings();
        bytes memory expected =
            abi.encodeWithSelector(GovernorSettingsFacet.GovernorOnlyExecutor.selector, address(this));

        vm.expectRevert(expected);
        settings.setVotingDelay(2 days, 3 days);
        vm.expectRevert(expected);
        settings.setVotingPeriod(5 days, 6 days);
        vm.expectRevert(expected);
        settings.setProposalThresholdNumerator(100, 200);
        vm.expectRevert(expected);
        settings.setQuorumNumerator(8, 12);
        vm.expectRevert(expected);
        settings.setExecutionDelay(2 days, 3 days);
        vm.expectRevert(expected);
        settings.setExecutionGracePeriod(14 days, 10 days);
    }

    function test_settersRejectNoopBeforeCurrentMismatch() public {
        GovernorSettingsFacet settings = _newSettings();
        vm.startPrank(address(settings));

        vm.expectRevert(GovernorSettingsFacet.GovernorPolicyChangeNoop.selector);
        settings.setVotingDelay(3 days, 3 days);
        vm.expectRevert(GovernorSettingsFacet.GovernorPolicyChangeNoop.selector);
        settings.setVotingPeriod(6 days, 6 days);
        vm.expectRevert(GovernorSettingsFacet.GovernorPolicyChangeNoop.selector);
        settings.setProposalThresholdNumerator(200, 200);
        vm.expectRevert(GovernorSettingsFacet.GovernorPolicyChangeNoop.selector);
        settings.setQuorumNumerator(12, 12);
        vm.expectRevert(GovernorSettingsFacet.GovernorPolicyChangeNoop.selector);
        settings.setExecutionDelay(3 days, 3 days);
        vm.expectRevert(GovernorSettingsFacet.GovernorPolicyChangeNoop.selector);
        settings.setExecutionGracePeriod(10 days, 10 days);
    }

    function test_settersRejectStaleCurrentBeforeReplacementBounds() public {
        GovernorSettingsFacet settings = _newSettings();
        bytes memory expected = abi.encodeWithSelector(
            GovernorSettingsFacet.GovernorPolicyCurrentMismatch.selector, uint256(1), uint256(2 days)
        );

        vm.prank(address(settings));
        vm.expectRevert(expected);
        settings.setVotingDelay(1, 0);
    }

    function test_initRejectsEveryOutOfBoundsPolicy() public {
        _expectInitFailure(1 days - 1, 5 days, 100, 8, 2 days, 14 days, _invalidVotingDelay(1 days - 1));
        _expectInitFailure(2 days, 30 days + 1, 100, 8, 2 days, 14 days, _invalidVotingPeriod(30 days + 1));
        _expectInitFailure(
            2 days,
            5 days,
            0,
            8,
            2 days,
            14 days,
            abi.encodeWithSelector(
                GovernorSettingsFacet.GovernorInvalidProposalThresholdNumerator.selector,
                uint256(0),
                uint256(1),
                uint256(1_000_000_000)
            )
        );
        _expectInitFailure(
            2 days,
            5 days,
            100,
            0,
            2 days,
            14 days,
            abi.encodeWithSelector(
                GovernorSettingsFacet.GovernorInvalidQuorumNumerator.selector, uint256(0), uint256(1), uint256(50)
            )
        );
        _expectInitFailure(
            2 days,
            5 days,
            100,
            8,
            1 days - 1,
            14 days,
            abi.encodeWithSelector(
                GovernorSettingsFacet.GovernorInvalidExecutionDelay.selector,
                uint256(1 days - 1),
                uint256(1 days),
                uint256(30 days)
            )
        );
        _expectInitFailure(
            2 days,
            5 days,
            100,
            8,
            2 days,
            30 days + 1,
            abi.encodeWithSelector(
                GovernorSettingsFacet.GovernorInvalidExecutionGracePeriod.selector,
                uint256(30 days + 1),
                uint256(1 days),
                uint256(30 days)
            )
        );
    }

    function test_settersAcceptInclusiveBoundsAndRejectOutside() public {
        GovernorSettingsFacet settings = _newSettings();
        vm.startPrank(address(settings));

        vm.expectRevert(_invalidVotingDelay(1 days - 1));
        settings.setVotingDelay(2 days, uint48(1 days - 1));
        settings.setVotingDelay(2 days, 30 days);

        vm.expectRevert(_invalidVotingPeriod(1 days - 1));
        settings.setVotingPeriod(5 days, uint32(1 days - 1));
        settings.setVotingPeriod(5 days, 30 days);

        settings.setProposalThresholdNumerator(100, 1_000_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernorSettingsFacet.GovernorInvalidProposalThresholdNumerator.selector,
                uint256(1_000_000_001),
                uint256(1),
                uint256(1_000_000_000)
            )
        );
        settings.setProposalThresholdNumerator(1_000_000_000, 1_000_000_001);

        settings.setQuorumNumerator(8, 50);
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernorSettingsFacet.GovernorInvalidQuorumNumerator.selector, uint256(51), uint256(1), uint256(50)
            )
        );
        settings.setQuorumNumerator(50, 51);

        settings.setExecutionDelay(2 days, 30 days);
        settings.setExecutionGracePeriod(14 days, 1 days);
        vm.stopPrank();
    }

    function _newSettings() private returns (GovernorSettingsFacet settings) {
        settings = new GovernorSettingsFacet();
        _enterInitContext(address(settings));
        settings.initSettings(2 days, 5 days, 100, 8, 2 days, 14 days);
        _exitInitContext(address(settings));
    }

    function _expectInitFailure(
        uint256 votingDelay_,
        uint256 votingPeriod_,
        uint32 proposalThresholdNumerator_,
        uint8 quorumNumerator_,
        uint256 executionDelay_,
        uint256 executionGracePeriod_,
        bytes memory expectedRevert
    ) private {
        GovernorSettingsFacet settings = new GovernorSettingsFacet();
        _enterInitContext(address(settings));
        vm.expectRevert(expectedRevert);
        settings.initSettings(
            votingDelay_,
            votingPeriod_,
            proposalThresholdNumerator_,
            quorumNumerator_,
            executionDelay_,
            executionGracePeriod_
        );
    }

    function _invalidVotingDelay(uint256 requested) private pure returns (bytes memory) {
        return abi.encodeWithSelector(
            GovernorSettingsFacet.GovernorInvalidVotingDelay.selector, requested, uint256(1 days), uint256(30 days)
        );
    }

    function _invalidVotingPeriod(uint256 requested) private pure returns (bytes memory) {
        return abi.encodeWithSelector(
            GovernorSettingsFacet.GovernorVotingPeriodOutOfBounds.selector, requested, uint256(1 days), uint256(30 days)
        );
    }
}
