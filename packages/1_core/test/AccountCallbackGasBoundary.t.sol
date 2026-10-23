// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";

import {TokenAccountCallbacksHarness} from "./TokenAccountCallbacks.t.sol";
import {TokenAccountCallbackMock} from "./mocks/TokenAccountCallbackMock.sol";
import {RecoveryShareCallbackHarness, RecoveryShareCallbackAccount} from "./RecoveryShareCallback.t.sol";
import {
    RecoveryCallbackSettlementHarness,
    RecoveryCallbackAsset,
    RedemptionCallbackAccount
} from "./RecoveryPoolSettlementCallbacks.t.sol";

import {ICygldApprovalCallback} from "../src/interfaces/ICygldApprovalCallback.sol";
import {ICygldOutflowCallback} from "../src/interfaces/ICygldOutflowCallback.sol";

contract AccountCallbackGasBoundaryTest is Test {
    address internal constant RECIPIENT = address(0xCAFE);
    address internal constant SPENDER = address(0xB0B);
    address internal constant SHARE_ASSET = address(0x1001);
    uint256 internal constant SHARE_ID = uint256(uint160(SHARE_ASSET));
    uint256 internal constant MAX_TEST_CALL_GAS = 500_000;

    bytes32 internal constant INIT_CONTEXT_SLOT = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
    bytes32 internal constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    function testCygldOutflowUsesNaturalMinimumCallerGasWithoutCheckpoint() public {
        (TokenAccountCallbacksHarness token, TokenAccountCallbackMock account) = _tokenAccount();
        account.setProbeMode(type(ICygldOutflowCallback).interfaceId, TokenAccountCallbackMock.ProbeMode.CanonicalFalse);

        _assertNaturalMinimum(address(token), address(account), abi.encodeCall(token.transfer, (RECIPIENT, 1 ether)));
        assertEq(token.balanceOf(address(account)), 10 ether);
        assertEq(token.balanceOf(RECIPIENT), 0);
    }

    function testCygldApprovalUsesNaturalMinimumCallerGasWithoutCheckpoint() public {
        (TokenAccountCallbacksHarness token, TokenAccountCallbackMock account) = _tokenAccount();
        account.setProbeMode(
            type(ICygldApprovalCallback).interfaceId, TokenAccountCallbackMock.ProbeMode.CanonicalFalse
        );

        _assertNaturalMinimum(address(token), address(account), abi.encodeCall(token.approve, (SPENDER, 1 ether)));
        assertEq(token.allowance(address(account), SPENDER), 0);
        assertEq(token.allowanceExposure(address(account)), 0);
    }

    function testRecoveryShareOutflowUsesNaturalMinimumCallerGasWithoutCheckpoint() public {
        (RecoveryShareCallbackHarness shares, RecoveryShareCallbackAccount account) = _recoveryShareAccount();
        account.setProbeMode(RecoveryShareCallbackAccount.ProbeMode.Unsupported);

        _assertNaturalMinimum(
            address(shares),
            address(account),
            abi.encodeCall(shares.safeTransferFrom, (address(account), RECIPIENT, SHARE_ID, 1, ""))
        );
        assertEq(shares.balanceOf(address(account), SHARE_ID), 4);
        assertEq(shares.balanceOf(RECIPIENT, SHARE_ID), 0);
    }

    function testRecoveryShareRedemptionUsesNaturalMinimumCallerGasWithoutCheckpoint() public {
        (RecoveryCallbackSettlementHarness settlement, RecoveryCallbackAsset asset, RedemptionCallbackAccount account) =
            _redemptionAccount();
        account.configure(RedemptionCallbackAccount.ProbeMode.False, RedemptionCallbackAccount.CallbackMode.Magic);

        _assertNaturalMinimum(
            address(settlement),
            address(account),
            abi.encodeCall(settlement.redeemRecoveryShares, (address(asset), 2, RECIPIENT, 0))
        );
        _assertRedemptionUnchanged(settlement, asset, account);
    }

    function testPureProbeOogCannotBypassCygldOutflowAtomically() public {
        (TokenAccountCallbacksHarness token, TokenAccountCallbackMock account) = _tokenAccount();
        bytes memory callData = abi.encodeCall(token.transfer, (RECIPIENT, 1 ether));
        bytes4 interfaceId = type(ICygldOutflowCallback).interfaceId;

        account.setProbeMode(interfaceId, TokenAccountCallbackMock.ProbeMode.CanonicalFalse);
        uint256 cheapProbeMinimum = _minimumSuccessfulGas(address(token), address(account), callData);
        assertLt(cheapProbeMinimum, 30_000, "fixture must underfund the requested probe stipend");
        account.setProbeMode(interfaceId, TokenAccountCallbackMock.ProbeMode.ExhaustGas);
        _assertPureOogBoundary(address(token), address(account), callData, cheapProbeMinimum);

        assertEq(token.balanceOf(address(account)), 10 ether);
        assertEq(token.balanceOf(RECIPIENT), 0);
    }

    function testPureProbeOogCannotBypassCygldApprovalAtomically() public {
        (TokenAccountCallbacksHarness token, TokenAccountCallbackMock account) = _tokenAccount();
        bytes memory callData = abi.encodeCall(token.approve, (SPENDER, 1 ether));
        bytes4 interfaceId = type(ICygldApprovalCallback).interfaceId;

        account.setProbeMode(interfaceId, TokenAccountCallbackMock.ProbeMode.CanonicalFalse);
        uint256 cheapProbeMinimum = _minimumSuccessfulGas(address(token), address(account), callData);
        account.setProbeMode(interfaceId, TokenAccountCallbackMock.ProbeMode.ExhaustGas);
        _assertPureOogBoundary(address(token), address(account), callData, cheapProbeMinimum);

        assertEq(token.allowance(address(account), SPENDER), 0);
        assertEq(token.allowanceExposure(address(account)), 0);
    }

    function testPureProbeOogAtSecondFiniteTransferFromProbeIsAtomic() public {
        (TokenAccountCallbacksHarness token, TokenAccountCallbackMock account) = _tokenAccount();
        assertTrue(account.approveToken(address(token), SPENDER, 5 ether));
        bytes memory callData = abi.encodeCall(token.transferFrom, (address(account), RECIPIENT, 1 ether));
        bytes4 approvalInterface = type(ICygldApprovalCallback).interfaceId;
        bytes4 outflowInterface = type(ICygldOutflowCallback).interfaceId;

        account.setProbeMode(approvalInterface, TokenAccountCallbackMock.ProbeMode.CanonicalFalse);
        account.setProbeMode(outflowInterface, TokenAccountCallbackMock.ProbeMode.CanonicalFalse);
        uint256 cheapProbeMinimum = _minimumSuccessfulGas(address(token), SPENDER, callData);
        account.setProbeMode(outflowInterface, TokenAccountCallbackMock.ProbeMode.ExhaustGas);
        _assertPureOogBoundary(address(token), SPENDER, callData, cheapProbeMinimum);

        assertEq(token.allowance(address(account), SPENDER), 5 ether);
        assertEq(token.balanceOf(address(account)), 10 ether);
        assertEq(token.balanceOf(RECIPIENT), 0);
    }

    function testPureProbeOogCannotBypassRecoveryShareOutflowAtomically() public {
        (RecoveryShareCallbackHarness shares, RecoveryShareCallbackAccount account) = _recoveryShareAccount();
        bytes memory callData = abi.encodeCall(shares.safeTransferFrom, (address(account), RECIPIENT, SHARE_ID, 1, ""));

        account.setProbeMode(RecoveryShareCallbackAccount.ProbeMode.Unsupported);
        uint256 cheapProbeMinimum = _minimumSuccessfulGas(address(shares), address(account), callData);
        account.setProbeMode(RecoveryShareCallbackAccount.ProbeMode.ExhaustGas);
        _assertPureOogBoundary(address(shares), address(account), callData, cheapProbeMinimum);

        assertEq(shares.balanceOf(address(account), SHARE_ID), 4);
        assertEq(shares.balanceOf(RECIPIENT, SHARE_ID), 0);
    }

    function testPureProbeOogCannotBypassRecoveryShareRedemptionAtomically() public {
        (RecoveryCallbackSettlementHarness settlement, RecoveryCallbackAsset asset, RedemptionCallbackAccount account) =
            _redemptionAccount();
        bytes memory callData = abi.encodeCall(settlement.redeemRecoveryShares, (address(asset), 2, RECIPIENT, 0));

        account.configure(RedemptionCallbackAccount.ProbeMode.False, RedemptionCallbackAccount.CallbackMode.Magic);
        uint256 cheapProbeMinimum = _minimumSuccessfulGas(address(settlement), address(account), callData);
        account.configure(RedemptionCallbackAccount.ProbeMode.ExhaustGas, RedemptionCallbackAccount.CallbackMode.Magic);
        _assertPureOogBoundary(address(settlement), address(account), callData, cheapProbeMinimum);

        _assertRedemptionUnchanged(settlement, asset, account);
    }

    function testGasSensitiveLowBudgetFalseIsIntentionallyAuthoritative() public {
        (TokenAccountCallbacksHarness token, TokenAccountCallbackMock account) = _tokenAccount();
        bytes4 interfaceId = type(ICygldOutflowCallback).interfaceId;
        bytes4 callback = ICygldOutflowCallback.onCygldOutflow.selector;
        bytes memory callData = abi.encodeCall(token.transfer, (RECIPIENT, 1 ether));

        account.setProbeMode(interfaceId, TokenAccountCallbackMock.ProbeMode.CanonicalFalse);
        uint256 cheapProbeMinimum = _minimumSuccessfulGas(address(token), address(account), callData);
        account.setProbeMode(interfaceId, TokenAccountCallbackMock.ProbeMode.GasThresholdTrue);
        account.setCallbackMode(callback, TokenAccountCallbackMock.CallbackMode.RevertPolicy);

        uint256 lowBudgetSuccess;
        for (uint256 gasLimit = cheapProbeMinimum; gasLimit < cheapProbeMinimum + 40_000; gasLimit += 100) {
            (bool success,) = _callFromWithSnapshot(address(token), address(account), callData, gasLimit);
            if (success) {
                lowBudgetSuccess = gasLimit;
                break;
            }
        }
        assertNotEq(lowBudgetSuccess, 0, "expected a low-budget unsupported-result window");

        (bool highBudgetSuccess, bytes memory highBudgetReturn) =
            _callFromWithSnapshot(address(token), address(account), callData, MAX_TEST_CALL_GAS);
        assertFalse(highBudgetSuccess, "full-budget probe must advertise and dispatch");
        assertEq(_selector(highBudgetReturn), TokenAccountCallbackMock.PolicyRejected.selector);
        assertEq(token.balanceOf(address(account)), 10 ether);
        assertEq(token.balanceOf(RECIPIENT), 0);
    }

    function testAdvertisedCallbackBubblesExactOversizedRevertWithBoundedCallerChosenCost() public {
        (TokenAccountCallbacksHarness token, TokenAccountCallbackMock account) = _tokenAccount();
        account.setProbeMode(type(ICygldOutflowCallback).interfaceId, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);
        account.setCallbackMode(
            ICygldOutflowCallback.onCygldOutflow.selector, TokenAccountCallbackMock.CallbackMode.RevertOversized
        );

        (uint256 smallGas, bytes memory smallRevert) = _callOversizedPolicy(token, account, 4_096);
        (uint256 largeGas, bytes memory largeRevert) = _callOversizedPolicy(token, account, 65_536);

        assertEq(smallRevert.length, 4_096);
        assertEq(largeRevert.length, 65_536);
        assertEq(keccak256(smallRevert), keccak256(new bytes(4_096)));
        assertEq(keccak256(largeRevert), keccak256(new bytes(65_536)));
        assertGt(largeGas, smallGas, "larger exact revert must cost the initiating caller more gas");
        assertLt(smallGas, 1_000_000, "4 KiB policy revert characterization changed materially");
        assertLt(largeGas, 2_000_000, "64 KiB policy revert characterization changed materially");
        assertEq(token.balanceOf(address(account)), 10 ether);
        assertEq(token.balanceOf(RECIPIENT), 0);
    }

    function _assertNaturalMinimum(address target, address caller, bytes memory callData)
        private
        returns (uint256 minimum)
    {
        minimum = _minimumSuccessfulGas(target, caller, callData);
        (bool exactSuccess,) = _callFromWithSnapshot(target, caller, callData, minimum);
        assertTrue(exactSuccess, "exact natural minimum must complete");
        assertGt(minimum, 0);

        (bool oneLessSuccess,) = _callFromWithSnapshot(target, caller, callData, minimum - 1);
        assertFalse(oneLessSuccess, "one gas below the natural minimum must roll back");
    }

    function _assertPureOogBoundary(address target, address caller, bytes memory callData, uint256 cheapProbeMinimum)
        private
        returns (uint256 pureOogMinimum)
    {
        (bool bypassSuccess,) = _callFromWithSnapshot(target, caller, callData, cheapProbeMinimum);
        assertFalse(bypassSuccess, "pure probe OOG must not bypass at the cheap-probe minimum");

        pureOogMinimum = _minimumSuccessfulGas(target, caller, callData);
        assertGt(pureOogMinimum, cheapProbeMinimum, "consuming all probe gas must increase the natural minimum");

        (bool exactSuccess,) = _callFromWithSnapshot(target, caller, callData, pureOogMinimum);
        assertTrue(exactSuccess, "failed discovery is unsupported when enough execution gas remains");
        (bool oneLessSuccess,) = _callFromWithSnapshot(target, caller, callData, pureOogMinimum - 1);
        assertFalse(oneLessSuccess, "one gas below the pure-OOG minimum must roll back atomically");
    }

    function _minimumSuccessfulGas(address target, address caller, bytes memory callData)
        private
        returns (uint256 minimum)
    {
        uint256 low;
        uint256 high = MAX_TEST_CALL_GAS;
        (bool highSuccess,) = _callFromWithSnapshot(target, caller, callData, high);
        assertTrue(highSuccess, "maximum test gas must complete");

        while (low < high) {
            uint256 mid = (low + high) / 2;
            (bool success,) = _callFromWithSnapshot(target, caller, callData, mid);
            if (success) high = mid;
            else low = mid + 1;
        }
        return low;
    }

    function _callFromWithSnapshot(address target, address caller, bytes memory callData, uint256 gasLimit)
        private
        returns (bool success, bytes memory returnData)
    {
        uint256 snapshot = vm.snapshotState();
        vm.prank(caller);
        (success, returnData) = target.call{gas: gasLimit}(callData);
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function _tokenAccount() private returns (TokenAccountCallbacksHarness token, TokenAccountCallbackMock account) {
        token = new TokenAccountCallbacksHarness();
        account = new TokenAccountCallbackMock();
        vm.store(address(token), INIT_CONTEXT_SLOT, bytes32(uint256(1)));
        vm.store(address(token), INITIALIZABLE_STORAGE, bytes32(uint256(1) << 64));
        token.initToken("CyberGold", "CYGLD");
        vm.store(address(token), INIT_CONTEXT_SLOT, bytes32(0));
        vm.store(address(token), INITIALIZABLE_STORAGE, bytes32(uint256(1)));
        token.setMaxTotalSupplyForTest(type(uint256).max);
        token.mintFromController(address(account), 10 ether);
    }

    function _recoveryShareAccount()
        private
        returns (RecoveryShareCallbackHarness shares, RecoveryShareCallbackAccount account)
    {
        shares = new RecoveryShareCallbackHarness();
        shares.seedPool(SHARE_ASSET);
        account = new RecoveryShareCallbackAccount(address(shares));
        address[] memory assets = new address[](1);
        assets[0] = SHARE_ASSET;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 4;
        shares.issueFromController(address(account), assets, amounts);
    }

    function _redemptionAccount()
        private
        returns (
            RecoveryCallbackSettlementHarness settlement,
            RecoveryCallbackAsset asset,
            RedemptionCallbackAccount account
        )
    {
        settlement = new RecoveryCallbackSettlementHarness();
        asset = new RecoveryCallbackAsset();
        account = new RedemptionCallbackAccount(settlement);
        asset.mint(address(settlement), 100);
        settlement.seedPool(address(asset), address(account), 10, 100);
    }

    function _assertRedemptionUnchanged(
        RecoveryCallbackSettlementHarness settlement,
        RecoveryCallbackAsset asset,
        RedemptionCallbackAccount account
    ) private view {
        assertEq(settlement.shareBalance(address(asset), address(account)), 10);
        assertEq(settlement.poolRaw(address(asset)), 100);
        assertEq(asset.balanceOf(RECIPIENT), 0);
    }

    function _callOversizedPolicy(
        TokenAccountCallbacksHarness token,
        TokenAccountCallbackMock account,
        uint256 revertLength
    ) private returns (uint256 gasUsed, bytes memory returnData) {
        account.setOversizedRevertLength(revertLength);
        uint256 beforeGas = gasleft();
        (bool success, bytes memory observed) = address(account).call{gas: 5_000_000}(
            abi.encodeCall(TokenAccountCallbackMock.transferToken, (address(token), RECIPIENT, 1 ether))
        );
        gasUsed = beforeGas - gasleft();
        assertFalse(success);
        returnData = observed;
    }

    function _selector(bytes memory returnData) private pure returns (bytes4 selector) {
        if (returnData.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(returnData, 0x20))
        }
    }
}
