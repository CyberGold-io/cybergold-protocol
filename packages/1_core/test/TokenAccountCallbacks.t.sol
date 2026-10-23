// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";
import {TokenFacet} from "../src/facets/TokenFacet.sol";
import {ICygldApprovalCallback} from "../src/interfaces/ICygldApprovalCallback.sol";
import {ICygldOutflowCallback} from "../src/interfaces/ICygldOutflowCallback.sol";
import {LibAccountCallbacks} from "../src/libraries/LibAccountCallbacks.sol";
import {TokenAccountCallbackMock} from "./mocks/TokenAccountCallbackMock.sol";

contract TokenAccountCallbacksHarness is TokenFacet {
    function setMaxTotalSupplyForTest(uint256 maxTotalSupply) external {
        LibAppStorage.appStorage().controller.maxTotalSupply = maxTotalSupply;
    }

    function mintFromController(address to, uint256 amount) external {
        this.mint(to, amount);
    }

    function burnFromController(address from, uint256 amount) external {
        this.burn(from, amount);
    }
}

contract TokenAccountCallbacksTest is Test {
    TokenAccountCallbacksHarness internal facet;
    TokenAccountCallbackMock internal account;

    address internal constant RECIPIENT = address(0xABCD);
    address internal constant SPENDER = address(0xCAFE);

    bytes4 internal constant APPROVAL_INTERFACE_ID = type(ICygldApprovalCallback).interfaceId;
    bytes4 internal constant APPROVAL_CALLBACK = ICygldApprovalCallback.onCygldApprovalChange.selector;
    bytes4 internal constant OUTFLOW_INTERFACE_ID = type(ICygldOutflowCallback).interfaceId;
    bytes4 internal constant OUTFLOW_CALLBACK = ICygldOutflowCallback.onCygldOutflow.selector;

    bytes32 internal constant INIT_CONTEXT_SLOT = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
    bytes32 internal constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    function setUp() public {
        facet = new TokenAccountCallbacksHarness();
        account = new TokenAccountCallbackMock();
        _enterInitContext();
        facet.initToken("CyberGold", "CYGLD");
        _exitInitContext();
        facet.setMaxTotalSupplyForTest(type(uint256).max);
    }

    function testOutflowProbeFailuresFailOpenWithoutDispatchingCallback() public {
        facet.mintFromController(address(account), 20 ether);
        account.setCallbackMode(OUTFLOW_CALLBACK, TokenAccountCallbackMock.CallbackMode.RevertPolicy);

        TokenAccountCallbackMock.ProbeMode[] memory modes = new TokenAccountCallbackMock.ProbeMode[](9);
        modes[0] = TokenAccountCallbackMock.ProbeMode.CanonicalFalse;
        modes[1] = TokenAccountCallbackMock.ProbeMode.RevertEmpty;
        modes[2] = TokenAccountCallbackMock.ProbeMode.RevertData;
        modes[3] = TokenAccountCallbackMock.ProbeMode.ReturnEmpty;
        modes[4] = TokenAccountCallbackMock.ProbeMode.ReturnShort;
        modes[5] = TokenAccountCallbackMock.ProbeMode.ReturnLong;
        modes[6] = TokenAccountCallbackMock.ProbeMode.ReturnNonCanonical;
        modes[7] = TokenAccountCallbackMock.ProbeMode.ReturnOversized;
        modes[8] = TokenAccountCallbackMock.ProbeMode.GasHeavyFalse;

        for (uint256 i; i < modes.length; ++i) {
            account.setProbeMode(OUTFLOW_INTERFACE_ID, modes[i]);
            assertTrue(account.transferToken(address(facet), RECIPIENT, 1 ether));
        }

        assertEq(facet.balanceOf(address(account)), 11 ether);
        assertEq(facet.balanceOf(RECIPIENT), 9 ether);
    }

    function testApprovalProbeFailuresFailOpenWithoutDispatchingCallback() public {
        facet.mintFromController(address(account), 20 ether);
        account.setCallbackMode(APPROVAL_CALLBACK, TokenAccountCallbackMock.CallbackMode.RevertPolicy);

        TokenAccountCallbackMock.ProbeMode[] memory modes = new TokenAccountCallbackMock.ProbeMode[](9);
        modes[0] = TokenAccountCallbackMock.ProbeMode.CanonicalFalse;
        modes[1] = TokenAccountCallbackMock.ProbeMode.RevertEmpty;
        modes[2] = TokenAccountCallbackMock.ProbeMode.RevertData;
        modes[3] = TokenAccountCallbackMock.ProbeMode.ReturnEmpty;
        modes[4] = TokenAccountCallbackMock.ProbeMode.ReturnShort;
        modes[5] = TokenAccountCallbackMock.ProbeMode.ReturnLong;
        modes[6] = TokenAccountCallbackMock.ProbeMode.ReturnNonCanonical;
        modes[7] = TokenAccountCallbackMock.ProbeMode.ReturnOversized;
        modes[8] = TokenAccountCallbackMock.ProbeMode.GasHeavyFalse;

        for (uint256 i; i < modes.length; ++i) {
            account.setProbeMode(APPROVAL_INTERFACE_ID, modes[i]);
            assertTrue(account.approveToken(address(facet), SPENDER, i + 1));
        }

        assertEq(facet.allowance(address(account), SPENDER), modes.length);
        assertEq(facet.allowanceExposure(address(account)), modes.length);
    }

    function testCanonicalProbeDispatchesExactPostStateApprovalAndOutflowContexts() public {
        facet.mintFromController(address(account), 10 ether);
        account.setProbeMode(APPROVAL_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);
        account.setProbeMode(OUTFLOW_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);

        _expectApproval(SPENDER, 0, 3 ether, 10 ether, 3 ether, 3 ether);
        assertTrue(account.approveToken(address(facet), SPENDER, 3 ether));

        _expectOutflow(address(account), RECIPIENT, 2 ether, 8 ether, 3 ether, SPENDER, 3 ether, true);
        assertTrue(account.transferToken(address(facet), RECIPIENT, 2 ether));

        assertEq(facet.balanceOf(address(account)), 8 ether);
        assertEq(facet.balanceOf(RECIPIENT), 2 ether);
        assertEq(facet.allowanceExposure(address(account)), 3 ether);
    }

    function testCapabilityIsDiscoveredPerOperationAndCallbackRejectionRollsBack() public {
        facet.mintFromController(address(account), 3 ether);
        account.setCallbackMode(OUTFLOW_CALLBACK, TokenAccountCallbackMock.CallbackMode.RevertPolicy);

        account.setProbeMode(OUTFLOW_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalFalse);
        assertTrue(account.transferToken(address(facet), RECIPIENT, 1 ether));

        account.setProbeMode(OUTFLOW_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);
        _expectOutflow(address(account), RECIPIENT, 1 ether, 1 ether, 0, address(0), 0, false);
        vm.expectRevert(abi.encodeWithSelector(TokenAccountCallbackMock.PolicyRejected.selector, OUTFLOW_CALLBACK));
        account.transferToken(address(facet), RECIPIENT, 1 ether);

        assertEq(facet.balanceOf(address(account)), 2 ether);
        assertEq(facet.balanceOf(RECIPIENT), 1 ether);
    }

    function testFuzzCallbackCapabilityAndPolicySequencesAreRediscoveredAndAtomic(uint16 decisions, uint96 amountSeed)
        public
    {
        uint256 unit = bound(uint256(amountSeed), 1, 1e24);
        uint256 initialBalance = unit * 8;
        uint256 expectedBalance = initialBalance;
        uint256 expectedRecipientBalance;
        uint256 expectedAllowance;
        facet.mintFromController(address(account), initialBalance);

        for (uint256 i; i < 8; ++i) {
            bool supported = uint256(decisions) & (uint256(1) << (i * 2)) != 0;
            bool accepts = uint256(decisions) & (uint256(1) << (i * 2 + 1)) != 0;
            bytes4 interfaceId = i % 2 == 0 ? APPROVAL_INTERFACE_ID : OUTFLOW_INTERFACE_ID;
            bytes4 callback = i % 2 == 0 ? APPROVAL_CALLBACK : OUTFLOW_CALLBACK;
            account.setProbeMode(
                interfaceId,
                supported
                    ? TokenAccountCallbackMock.ProbeMode.CanonicalTrue
                    : TokenAccountCallbackMock.ProbeMode.CanonicalFalse
            );
            account.setCallbackMode(
                callback,
                accepts
                    ? TokenAccountCallbackMock.CallbackMode.ExactMagic
                    : TokenAccountCallbackMock.CallbackMode.RevertPolicy
            );

            bool success;
            bytes memory returnData;
            if (i % 2 == 0) {
                uint256 nextAllowance = unit * (i + 1);
                (success, returnData) = address(account)
                    .call(
                        abi.encodeCall(TokenAccountCallbackMock.approveToken, (address(facet), SPENDER, nextAllowance))
                    );
                if (!supported || accepts) expectedAllowance = nextAllowance;
            } else {
                (success, returnData) = address(account)
                    .call(abi.encodeCall(TokenAccountCallbackMock.transferToken, (address(facet), RECIPIENT, unit)));
                if (!supported || accepts) {
                    expectedBalance -= unit;
                    expectedRecipientBalance += unit;
                }
            }

            bool expectedSuccess = !supported || accepts;
            assertEq(success, expectedSuccess, "unexpected callback sequence result");
            if (expectedSuccess) {
                assertTrue(abi.decode(returnData, (bool)), "operation did not return true");
            } else {
                assertEq(_selector(returnData), TokenAccountCallbackMock.PolicyRejected.selector);
            }

            assertEq(facet.balanceOf(address(account)), expectedBalance);
            assertEq(facet.balanceOf(RECIPIENT), expectedRecipientBalance);
            assertEq(facet.balanceOf(address(account)) + facet.balanceOf(RECIPIENT), initialBalance);
            assertEq(facet.allowance(address(account), SPENDER), expectedAllowance);
            assertEq(facet.allowanceExposure(address(account)), _min(expectedAllowance, expectedBalance));
            assertEq(facet.totalSupply(), initialBalance);
        }
    }

    function testAdvertisedCallbackRequiresCanonicalMagicAndClassifiesFailures() public {
        facet.mintFromController(address(account), 2 ether);
        account.setProbeMode(APPROVAL_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);

        _assertRejectedApproval(
            TokenAccountCallbackMock.CallbackMode.RevertEmpty,
            abi.encodeWithSelector(
                LibAccountCallbacks.AccountCallbackFailed.selector, address(account), APPROVAL_CALLBACK
            )
        );
        _assertRejectedApproval(
            TokenAccountCallbackMock.CallbackMode.RevertPolicy,
            abi.encodeWithSelector(TokenAccountCallbackMock.PolicyRejected.selector, APPROVAL_CALLBACK)
        );
        _assertRejectedApproval(
            TokenAccountCallbackMock.CallbackMode.ReturnEmpty,
            abi.encodeWithSelector(
                LibAccountCallbacks.AccountCallbackReturnMalformed.selector, address(account), APPROVAL_CALLBACK, 0
            )
        );
        _assertRejectedApproval(
            TokenAccountCallbackMock.CallbackMode.ReturnShort,
            abi.encodeWithSelector(
                LibAccountCallbacks.AccountCallbackReturnMalformed.selector, address(account), APPROVAL_CALLBACK, 4
            )
        );
        _assertRejectedApproval(
            TokenAccountCallbackMock.CallbackMode.ReturnLong,
            abi.encodeWithSelector(
                LibAccountCallbacks.AccountCallbackReturnMalformed.selector, address(account), APPROVAL_CALLBACK, 64
            )
        );
        _assertRejectedApproval(
            TokenAccountCallbackMock.CallbackMode.ReturnOversized,
            abi.encodeWithSelector(
                LibAccountCallbacks.AccountCallbackReturnMalformed.selector, address(account), APPROVAL_CALLBACK, 4096
            )
        );
        _assertRejectedApproval(
            TokenAccountCallbackMock.CallbackMode.WrongMagic,
            abi.encodeWithSelector(
                LibAccountCallbacks.AccountCallbackMagicMismatch.selector,
                address(account),
                APPROVAL_CALLBACK,
                bytes32(uint256(0xBADC0DE))
            )
        );
    }

    function testAdvertisedCallbackOutOfGasIsClassifiedAndAtomic() public {
        facet.mintFromController(address(account), 2 ether);
        account.setProbeMode(APPROVAL_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);
        account.setCallbackMode(APPROVAL_CALLBACK, TokenAccountCallbackMock.CallbackMode.ExhaustGas);

        (bool success, bytes memory returnData) = address(account).call{gas: 2_000_000}(
            abi.encodeCall(TokenAccountCallbackMock.approveToken, (address(facet), SPENDER, 1 ether))
        );

        assertFalse(success);
        assertEq(_selector(returnData), LibAccountCallbacks.AccountCallbackFailed.selector);
        assertEq(facet.allowance(address(account), SPENDER), 0);
        assertEq(facet.allowanceExposure(address(account)), 0);
    }

    function testStaticCallbackContextRejectsSstoreLogAndNestedTokenMutation() public {
        facet.mintFromController(address(account), 2 ether);
        account.setProbeMode(APPROVAL_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);
        account.setCallbackExpectation(
            APPROVAL_CALLBACK,
            keccak256(
                abi.encodeCall(ICygldApprovalCallback.onCygldApprovalChange, (SPENDER, 0, 1 ether, 2 ether, 1 ether))
            ),
            address(facet),
            2 ether,
            1 ether,
            SPENDER,
            1 ether,
            true
        );

        TokenAccountCallbackMock.CallbackMode[3] memory modes = [
            TokenAccountCallbackMock.CallbackMode.AttemptSstore,
            TokenAccountCallbackMock.CallbackMode.AttemptLog,
            TokenAccountCallbackMock.CallbackMode.AttemptNestedTransfer
        ];
        for (uint256 i; i < modes.length; ++i) {
            account.setCallbackMode(APPROVAL_CALLBACK, modes[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    LibAccountCallbacks.AccountCallbackFailed.selector, address(account), APPROVAL_CALLBACK
                )
            );
            account.approveToken(address(facet), SPENDER, 1 ether);
            assertEq(facet.allowance(address(account), SPENDER), 0);
            assertEq(facet.allowanceExposure(address(account)), 0);
            assertEq(facet.balanceOf(address(account)), 2 ether);
            assertEq(facet.balanceOf(address(0xDEAD)), 0);
        }
    }

    function testApprovalCallbackFailureRollsBackRawAndAggregateAllowance() public {
        facet.mintFromController(address(account), 10 ether);
        account.setProbeMode(APPROVAL_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);
        account.setCallbackMode(APPROVAL_CALLBACK, TokenAccountCallbackMock.CallbackMode.RevertPolicy);
        _expectApproval(SPENDER, 0, 4 ether, 10 ether, 4 ether, 4 ether);

        vm.expectRevert(abi.encodeWithSelector(TokenAccountCallbackMock.PolicyRejected.selector, APPROVAL_CALLBACK));
        account.approveToken(address(facet), SPENDER, 4 ether);

        assertEq(facet.allowance(address(account), SPENDER), 0);
        assertEq(facet.allowanceExposure(address(account)), 0);
    }

    function testFiniteTransferFromRunsApprovalBeforeOutflowWithExactPostState() public {
        facet.mintFromController(address(account), 10 ether);
        assertTrue(account.approveToken(address(facet), SPENDER, 5 ether));

        account.setProbeMode(APPROVAL_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);
        account.setProbeMode(OUTFLOW_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);
        _expectApproval(SPENDER, 5 ether, 3 ether, 10 ether, 3 ether, 3 ether);
        _expectOutflow(SPENDER, RECIPIENT, 2 ether, 8 ether, 3 ether, SPENDER, 3 ether, true);

        vm.prank(SPENDER);
        assertTrue(facet.transferFrom(address(account), RECIPIENT, 2 ether));

        assertEq(facet.allowance(address(account), SPENDER), 3 ether);
        assertEq(facet.balanceOf(address(account)), 8 ether);
        assertEq(facet.balanceOf(RECIPIENT), 2 ether);
    }

    function testFiniteTransferFromOutflowRejectionRollsBackAllowanceAndBalances() public {
        facet.mintFromController(address(account), 10 ether);
        assertTrue(account.approveToken(address(facet), SPENDER, 5 ether));

        account.setProbeMode(APPROVAL_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);
        account.setProbeMode(OUTFLOW_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);
        account.setCallbackMode(OUTFLOW_CALLBACK, TokenAccountCallbackMock.CallbackMode.RevertPolicy);
        _expectApproval(SPENDER, 5 ether, 3 ether, 10 ether, 3 ether, 3 ether);
        _expectOutflow(SPENDER, RECIPIENT, 2 ether, 8 ether, 3 ether, SPENDER, 3 ether, true);

        vm.prank(SPENDER);
        vm.expectRevert(abi.encodeWithSelector(TokenAccountCallbackMock.PolicyRejected.selector, OUTFLOW_CALLBACK));
        // The expected revert makes a return-value assertion unreachable.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        facet.transferFrom(address(account), RECIPIENT, 2 ether);

        assertEq(facet.allowance(address(account), SPENDER), 5 ether);
        assertEq(facet.allowanceExposure(address(account)), 5 ether);
        assertEq(facet.balanceOf(address(account)), 10 ether);
        assertEq(facet.balanceOf(RECIPIENT), 0);
    }

    function testInfiniteTransferFromSkipsApprovalMutationCallback() public {
        facet.mintFromController(address(account), 10 ether);
        assertTrue(account.approveToken(address(facet), SPENDER, type(uint256).max));

        account.setProbeMode(APPROVAL_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);
        account.setProbeMode(OUTFLOW_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);
        account.setCallbackMode(APPROVAL_CALLBACK, TokenAccountCallbackMock.CallbackMode.RevertPolicy);
        _expectOutflow(SPENDER, RECIPIENT, 2 ether, 8 ether, 8 ether, SPENDER, type(uint256).max, true);

        vm.prank(SPENDER);
        assertTrue(facet.transferFrom(address(account), RECIPIENT, 2 ether));

        assertEq(facet.allowance(address(account), SPENDER), type(uint256).max);
        assertEq(facet.allowanceExposure(address(account)), 8 ether);
        assertEq(facet.balanceOf(address(account)), 8 ether);
    }

    function testBurnDispatchesOutflowAndPolicyRejectionIsAtomic() public {
        facet.mintFromController(address(account), 5 ether);
        account.setProbeMode(OUTFLOW_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);
        account.setCallbackMode(OUTFLOW_CALLBACK, TokenAccountCallbackMock.CallbackMode.RevertPolicy);
        _expectOutflow(address(facet), address(0), 2 ether, 3 ether, 0, address(0), 0, false);

        vm.expectRevert(abi.encodeWithSelector(TokenAccountCallbackMock.PolicyRejected.selector, OUTFLOW_CALLBACK));
        facet.burnFromController(address(account), 2 ether);
        assertEq(facet.balanceOf(address(account)), 5 ether);
        assertEq(facet.totalSupply(), 5 ether);

        account.setCallbackMode(OUTFLOW_CALLBACK, TokenAccountCallbackMock.CallbackMode.ExactMagic);
        facet.burnFromController(address(account), 2 ether);
        assertEq(facet.balanceOf(address(account)), 3 ether);
        assertEq(facet.totalSupply(), 3 ether);
    }

    function testSelfAndZeroTransfersSkipOutflowDiscovery() public {
        facet.mintFromController(address(account), 2 ether);
        account.setProbeMode(OUTFLOW_INTERFACE_ID, TokenAccountCallbackMock.ProbeMode.CanonicalTrue);
        account.setCallbackMode(OUTFLOW_CALLBACK, TokenAccountCallbackMock.CallbackMode.RevertPolicy);

        assertTrue(account.transferToken(address(facet), address(account), 1 ether));
        assertTrue(account.transferToken(address(facet), RECIPIENT, 0));
        assertEq(facet.balanceOf(address(account)), 2 ether);
        assertEq(facet.balanceOf(RECIPIENT), 0);
    }

    function _assertRejectedApproval(TokenAccountCallbackMock.CallbackMode mode, bytes memory expectedRevert) internal {
        account.setCallbackMode(APPROVAL_CALLBACK, mode);
        vm.expectRevert(expectedRevert);
        account.approveToken(address(facet), SPENDER, 1 ether);
        assertEq(facet.allowance(address(account), SPENDER), 0);
        assertEq(facet.allowanceExposure(address(account)), 0);
    }

    function _expectApproval(
        address spender,
        uint256 previousAllowance,
        uint256 newAllowance,
        uint256 balanceAfter,
        uint256 exposureAfter,
        uint256 rawAllowanceAfter
    ) internal {
        account.setCallbackExpectation(
            APPROVAL_CALLBACK,
            keccak256(
                abi.encodeCall(
                    ICygldApprovalCallback.onCygldApprovalChange,
                    (spender, previousAllowance, newAllowance, balanceAfter, exposureAfter)
                )
            ),
            address(facet),
            balanceAfter,
            exposureAfter,
            spender,
            rawAllowanceAfter,
            true
        );
    }

    function _expectOutflow(
        address operator,
        address recipient,
        uint256 amount,
        uint256 balanceAfter,
        uint256 exposureAfter,
        address allowanceSpender,
        uint256 rawAllowanceAfter,
        bool checkAllowance
    ) internal {
        account.setCallbackExpectation(
            OUTFLOW_CALLBACK,
            keccak256(
                abi.encodeCall(
                    ICygldOutflowCallback.onCygldOutflow, (operator, recipient, amount, balanceAfter, exposureAfter)
                )
            ),
            address(facet),
            balanceAfter,
            exposureAfter,
            allowanceSpender,
            rawAllowanceAfter,
            checkAllowance
        );
    }

    function _selector(bytes memory returnData) internal pure returns (bytes4 selector) {
        if (returnData.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(returnData, 0x20))
        }
    }

    function _min(uint256 first, uint256 second) internal pure returns (uint256) {
        return first < second ? first : second;
    }

    function _enterInitContext() internal {
        vm.store(address(facet), INIT_CONTEXT_SLOT, bytes32(uint256(1)));
        vm.store(address(facet), INITIALIZABLE_STORAGE, bytes32(uint256(1) << 64));
    }

    function _exitInitContext() internal {
        vm.store(address(facet), INIT_CONTEXT_SLOT, bytes32(0));
        vm.store(address(facet), INITIALIZABLE_STORAGE, bytes32(uint256(1)));
    }
}
