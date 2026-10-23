// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";

import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {RecoveryShareFacet} from "../src/facets/RecoveryShareFacet.sol";
import {IRecoveryShareOutflowCallback} from "../src/interfaces/IRecoveryShareOutflowCallback.sol";
import {LibAccountCallbacks} from "../src/libraries/LibAccountCallbacks.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";

interface IRecoveryShareBalance {
    function balanceOf(address account, uint256 shareId) external view returns (uint256);
}

contract RecoveryShareCallbackHarness is RecoveryShareFacet {
    function seedPool(address asset) external {
        LibRecoveryStorage.getLayout().pools[asset].impaired = true;
    }

    function issueFromController(address to, address[] calldata assets, uint256[] calldata amounts) external {
        this.issueRecoveryShares(to, assets, amounts);
    }

    function burnFromController(address from, address asset, uint256 amount) external {
        this.burnRecoveryShares(from, asset, amount);
    }

    function rawMintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts) external {
        _mintBatch(to, ids, amounts, "");
    }

    function pauseForTest() external {
        _pause();
    }
}

contract RecoveryShareOrderedReceiver is IERC1155Receiver {
    address internal immutable CORE;
    address internal immutable EXPECTED_FROM;

    bool public accepted;

    constructor(address core, address expectedFrom) {
        CORE = core;
        EXPECTED_FROM = expectedFrom;
    }

    function onERC1155Received(address, address from, uint256, uint256, bytes calldata) external returns (bytes4) {
        require(msg.sender == CORE, "wrong core");
        require(from == EXPECTED_FROM, "wrong source");
        require(!accepted, "duplicate acceptance");
        accepted = true;
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address from, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        returns (bytes4)
    {
        require(msg.sender == CORE, "wrong core");
        require(from == EXPECTED_FROM, "wrong source");
        require(!accepted, "duplicate acceptance");
        accepted = true;
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract RecoveryShareReentrantReceiver is IERC1155Receiver {
    address internal immutable CORE;
    address internal immutable SINK;

    bool public sourceDrainSucceeded;
    bool public forwardedOwnBalance;
    bytes4 public sourceDrainRevertSelector;

    constructor(address core, address sink) {
        CORE = core;
        SINK = sink;
    }

    function onERC1155Received(address, address from, uint256 id, uint256 value, bytes calldata)
        external
        returns (bytes4)
    {
        require(msg.sender == CORE, "wrong core");

        (bool success, bytes memory returnData) =
            CORE.call(abi.encodeCall(IERC1155.safeTransferFrom, (from, SINK, id, value, "")));
        sourceDrainSucceeded = success;
        if (returnData.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(returnData, 0x20))
            }
            sourceDrainRevertSelector = selector;
        }

        IERC1155(CORE).safeTransferFrom(address(this), SINK, id, value, "");
        forwardedOwnBalance = true;
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract RecoveryShareCallbackAccount {
    enum ProbeMode {
        Unsupported,
        Supported,
        RevertWithData,
        EmptyRevert,
        EmptyReturn,
        ShortReturn,
        LongReturn,
        NonCanonical,
        OversizedReturn,
        ExhaustGas
    }

    enum CallbackMode {
        Correct,
        WrongMagic,
        NonCanonicalMagic,
        EmptySuccess,
        ShortReturn,
        LongReturn,
        OversizedReturn,
        EmptyRevert,
        RevertWithData,
        ExhaustGas
    }

    error RecoveryShareProbeRejected();
    error RecoverySharePolicyRejected(uint256 marker);
    error RecoveryShareCallbackSenderInvalid(address sender);
    error RecoveryShareCallbackContextInvalid(bytes32 field);
    error RecoveryShareAcceptanceAlreadyObserved(address receiver);

    address internal immutable CORE;

    ProbeMode internal probeMode;
    CallbackMode internal callbackMode;
    bool internal validateContext;
    address internal expectedOperator;
    address internal expectedRecipient;
    bytes32 internal expectedIdsHash;
    bytes32 internal expectedAmountsHash;
    bytes32 internal expectedBalancesHash;
    address internal expectedAcceptanceReceiver;

    constructor(address core) {
        CORE = core;
    }

    function setProbeMode(ProbeMode mode) external {
        probeMode = mode;
    }

    function setCallbackMode(CallbackMode mode) external {
        callbackMode = mode;
    }

    function setExpectation(
        address operator,
        address recipient,
        uint256[] calldata shareIds,
        uint256[] calldata amounts,
        uint256[] calldata expectedBalances,
        address acceptanceReceiver
    ) external {
        validateContext = true;
        expectedOperator = operator;
        expectedRecipient = recipient;
        expectedIdsHash = keccak256(abi.encode(shareIds));
        expectedAmountsHash = keccak256(abi.encode(amounts));
        expectedBalancesHash = keccak256(abi.encode(expectedBalances));
        expectedAcceptanceReceiver = acceptanceReceiver;
    }

    function clearExpectation() external {
        validateContext = false;
        expectedAcceptanceReceiver = address(0);
    }

    function approveOperator(address operator, bool approved) external {
        RecoveryShareFacet(CORE).setApprovalForAll(operator, approved);
    }

    function transferSingle(address recipient, uint256 shareId, uint256 amount) external {
        RecoveryShareFacet(CORE).safeTransferFrom(address(this), recipient, shareId, amount, "");
    }

    function transferBatch(address recipient, uint256[] calldata shareIds, uint256[] calldata amounts) external {
        RecoveryShareFacet(CORE).safeBatchTransferFrom(address(this), recipient, shareIds, amounts, "");
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        if (interfaceId != type(IRecoveryShareOutflowCallback).interfaceId) return false;

        ProbeMode mode = probeMode;
        if (mode == ProbeMode.Unsupported) return false;
        if (mode == ProbeMode.Supported) return true;
        if (mode == ProbeMode.RevertWithData) revert RecoveryShareProbeRejected();
        if (mode == ProbeMode.EmptyRevert) {
            assembly {
                revert(0, 0)
            }
        }
        if (mode == ProbeMode.EmptyReturn) {
            assembly {
                return(0, 0)
            }
        }
        if (mode == ProbeMode.ShortReturn) {
            assembly {
                mstore(0, 1)
                return(0, 0x1f)
            }
        }
        if (mode == ProbeMode.LongReturn) {
            assembly {
                mstore(0, 1)
                mstore(0x20, 0)
                return(0, 0x40)
            }
        }
        if (mode == ProbeMode.NonCanonical) {
            assembly {
                mstore(0, 2)
                return(0, 0x20)
            }
        }
        if (mode == ProbeMode.OversizedReturn) {
            assembly {
                mstore(0, 1)
                return(0, 0x8000)
            }
        }
        assembly {
            invalid()
        }
    }

    function onRecoveryShareOutflow(
        address operator,
        address recipient,
        uint256[] calldata shareIds,
        uint256[] calldata amounts
    ) external view returns (bytes4) {
        if (msg.sender != CORE) revert RecoveryShareCallbackSenderInvalid(msg.sender);
        if (validateContext) {
            if (operator != expectedOperator) revert RecoveryShareCallbackContextInvalid("operator");
            if (recipient != expectedRecipient) revert RecoveryShareCallbackContextInvalid("recipient");
            if (keccak256(abi.encode(shareIds)) != expectedIdsHash) {
                revert RecoveryShareCallbackContextInvalid("shareIds");
            }
            if (keccak256(abi.encode(amounts)) != expectedAmountsHash) {
                revert RecoveryShareCallbackContextInvalid("amounts");
            }

            uint256[] memory balances = new uint256[](shareIds.length);
            for (uint256 i; i < shareIds.length; ++i) {
                balances[i] = IRecoveryShareBalance(CORE).balanceOf(address(this), shareIds[i]);
            }
            if (keccak256(abi.encode(balances)) != expectedBalancesHash) {
                revert RecoveryShareCallbackContextInvalid("balances");
            }
            if (
                expectedAcceptanceReceiver != address(0)
                    && RecoveryShareOrderedReceiver(expectedAcceptanceReceiver).accepted()
            ) {
                revert RecoveryShareAcceptanceAlreadyObserved(expectedAcceptanceReceiver);
            }
        }

        CallbackMode mode = callbackMode;
        if (mode == CallbackMode.Correct) return IRecoveryShareOutflowCallback.onRecoveryShareOutflow.selector;
        if (mode == CallbackMode.WrongMagic) return bytes4(0xdeadbeef);
        if (mode == CallbackMode.NonCanonicalMagic) {
            bytes32 returnedWord =
                bytes32(IRecoveryShareOutflowCallback.onRecoveryShareOutflow.selector) | bytes32(uint256(1));
            assembly {
                mstore(0, returnedWord)
                return(0, 0x20)
            }
        }
        if (mode == CallbackMode.EmptySuccess) {
            assembly {
                return(0, 0)
            }
        }

        bytes32 callbackWord = bytes32(IRecoveryShareOutflowCallback.onRecoveryShareOutflow.selector);
        if (mode == CallbackMode.ShortReturn) {
            assembly {
                mstore(0, callbackWord)
                return(0, 0x1f)
            }
        }
        if (mode == CallbackMode.LongReturn) {
            assembly {
                mstore(0, callbackWord)
                mstore(0x20, 0)
                return(0, 0x40)
            }
        }
        if (mode == CallbackMode.OversizedReturn) {
            assembly {
                mstore(0, callbackWord)
                return(0, 0x8000)
            }
        }
        if (mode == CallbackMode.EmptyRevert) {
            assembly {
                revert(0, 0)
            }
        }
        if (mode == CallbackMode.RevertWithData) revert RecoverySharePolicyRejected(77);
        assembly {
            invalid()
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }
}

contract RecoveryShareCallbackTest is Test {
    RecoveryShareCallbackHarness internal facet;

    address internal constant ASSET_A = address(0x1001);
    address internal constant ASSET_B = address(0x1002);
    address internal constant USER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);

    uint256 internal constant ID_A = uint256(uint160(ASSET_A));
    uint256 internal constant ID_B = uint256(uint160(ASSET_B));
    bytes4 internal constant CALLBACK = IRecoveryShareOutflowCallback.onRecoveryShareOutflow.selector;
    bytes4 internal constant INTERFACE_ID = type(IRecoveryShareOutflowCallback).interfaceId;

    function setUp() public {
        facet = new RecoveryShareCallbackHarness();
        facet.seedPool(ASSET_A);
        facet.seedPool(ASSET_B);
    }

    function testExactInterfaceOptInUsesOneThirtyThousandGasProbeAndExactCallback() public {
        assertEq(INTERFACE_ID, bytes4(0xc723c768));
        assertEq(INTERFACE_ID, CALLBACK);

        RecoveryShareCallbackAccount account = _newAccount();
        _mintTwo(account, 5, 7);
        account.setProbeMode(RecoveryShareCallbackAccount.ProbeMode.Supported);

        uint256[] memory ids = _uints(ID_A, ID_B);
        uint256[] memory amounts = _uints(2, 3);
        uint256[] memory expectedBalances = _uints(3, 4);
        account.setExpectation(address(account), RECIPIENT, ids, amounts, expectedBalances, address(0));

        assertTrue(account.supportsInterface(INTERFACE_ID));
        assertFalse(account.supportsInterface(bytes4(0xffffffff)));

        bytes memory probe = abi.encodeCall(IERC165.supportsInterface, (INTERFACE_ID));
        bytes memory callbackCall = abi.encodeCall(
            IRecoveryShareOutflowCallback.onRecoveryShareOutflow, (address(account), RECIPIENT, ids, amounts)
        );
        vm.expectCall(address(account), 0, 30_000, probe, 1);
        vm.expectCall(address(account), callbackCall, 1);

        account.transferBatch(RECIPIENT, ids, amounts);

        assertEq(facet.balanceOf(address(account), ID_A), 3);
        assertEq(facet.balanceOf(address(account), ID_B), 4);
        assertEq(facet.balanceOf(RECIPIENT, ID_A), 2);
        assertEq(facet.balanceOf(RECIPIENT, ID_B), 3);
    }

    function testAllDiscoveryFailuresAreUnsupportedIncludingBoundedOversizedReturn() public {
        RecoveryShareCallbackAccount account = _newAccount();
        _mintOne(account, 20);
        account.setCallbackMode(RecoveryShareCallbackAccount.CallbackMode.RevertWithData);

        RecoveryShareCallbackAccount.ProbeMode[9] memory modes = [
            RecoveryShareCallbackAccount.ProbeMode.Unsupported,
            RecoveryShareCallbackAccount.ProbeMode.RevertWithData,
            RecoveryShareCallbackAccount.ProbeMode.EmptyRevert,
            RecoveryShareCallbackAccount.ProbeMode.EmptyReturn,
            RecoveryShareCallbackAccount.ProbeMode.ShortReturn,
            RecoveryShareCallbackAccount.ProbeMode.LongReturn,
            RecoveryShareCallbackAccount.ProbeMode.NonCanonical,
            RecoveryShareCallbackAccount.ProbeMode.OversizedReturn,
            RecoveryShareCallbackAccount.ProbeMode.ExhaustGas
        ];

        for (uint256 i; i < modes.length; ++i) {
            account.setProbeMode(modes[i]);
            account.transferSingle(RECIPIENT, ID_A, 1);
        }

        assertEq(facet.balanceOf(address(account), ID_A), 11);
        assertEq(facet.balanceOf(RECIPIENT, ID_A), 9);
    }

    function testCallbackCoversDirectOperatorSelfZeroAndEmptyMovements() public {
        RecoveryShareCallbackAccount account = _newAccount();
        _mintTwo(account, 10, 10);
        account.setProbeMode(RecoveryShareCallbackAccount.ProbeMode.Supported);

        uint256[] memory ids = _uints(ID_A);
        uint256[] memory amounts = _uints(2);
        account.setExpectation(address(account), RECIPIENT, ids, amounts, _uints(8), address(0));
        account.transferSingle(RECIPIENT, ID_A, 2);

        account.approveOperator(address(this), true);
        ids = _uints(ID_A, ID_B);
        amounts = _uints(1, 3);
        account.setExpectation(address(this), RECIPIENT, ids, amounts, _uints(7, 7), address(0));
        facet.safeBatchTransferFrom(address(account), RECIPIENT, ids, amounts, "");

        ids = _uints(ID_A);
        amounts = _uints(1);
        account.setExpectation(address(account), address(account), ids, amounts, _uints(7), address(0));
        account.transferSingle(address(account), ID_A, 1);

        amounts = _uints(0);
        account.setExpectation(address(account), RECIPIENT, ids, amounts, _uints(7), address(0));
        account.transferSingle(RECIPIENT, ID_A, 0);

        ids = new uint256[](0);
        amounts = new uint256[](0);
        account.setExpectation(address(account), RECIPIENT, ids, amounts, new uint256[](0), address(0));
        account.transferBatch(RECIPIENT, ids, amounts);

        assertEq(facet.balanceOf(address(account), ID_A), 7);
        assertEq(facet.balanceOf(address(account), ID_B), 7);
        assertEq(facet.balanceOf(RECIPIENT, ID_A), 3);
        assertEq(facet.balanceOf(RECIPIENT, ID_B), 3);
    }

    function testMintAndBurnNeverProbeOrDispatchAccountPolicy() public {
        RecoveryShareCallbackAccount account = _newAccount();
        account.setProbeMode(RecoveryShareCallbackAccount.ProbeMode.Supported);
        account.setCallbackMode(RecoveryShareCallbackAccount.CallbackMode.RevertWithData);

        bytes memory probe = abi.encodeCall(IERC165.supportsInterface, (INTERFACE_ID));
        vm.expectCall(address(account), probe, 0);
        _mintOne(account, 4);
        assertEq(facet.balanceOf(address(account), ID_A), 4);

        facet.burnFromController(address(account), ASSET_A, 1);
        assertEq(facet.balanceOf(address(account), ID_A), 3);
        assertEq(facet.totalSupply(ID_A), 3);
    }

    function testMalformedArraysRevertBeforeDiscovery() public {
        RecoveryShareCallbackAccount account = _newAccount();
        _mintOne(account, 4);
        account.setProbeMode(RecoveryShareCallbackAccount.ProbeMode.Supported);

        uint256[] memory ids = _uints(ID_A);
        uint256[] memory amounts = new uint256[](0);
        bytes memory probe = abi.encodeCall(IERC165.supportsInterface, (INTERFACE_ID));

        vm.expectCall(address(account), probe, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidArrayLength.selector, 1, 0));
        account.transferBatch(RECIPIENT, ids, amounts);

        assertEq(facet.balanceOf(address(account), ID_A), 4);
        assertEq(facet.balanceOf(RECIPIENT, ID_A), 0);
    }

    function testPausedSupplyChecksPauseBeforeInheritedLengthValidation() public {
        facet.pauseForTest();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        facet.rawMintBatch(USER, _uints(ID_A), new uint256[](0));
    }

    function testPausedNonSupplyMovementStillRunsPolicy() public {
        RecoveryShareCallbackAccount account = _newAccount();
        _mintOne(account, 3);
        account.setProbeMode(RecoveryShareCallbackAccount.ProbeMode.Supported);
        account.setExpectation(address(account), RECIPIENT, _uints(ID_A), _uints(1), _uints(2), address(0));

        facet.pauseForTest();
        account.transferSingle(RECIPIENT, ID_A, 1);

        assertEq(facet.balanceOf(address(account), ID_A), 2);
        assertEq(facet.balanceOf(RECIPIENT, ID_A), 1);
    }

    function testPolicyRunsAfterBalancesButBeforeRecipientAcceptance() public {
        RecoveryShareCallbackAccount account = _newAccount();
        _mintOne(account, 3);
        account.setProbeMode(RecoveryShareCallbackAccount.ProbeMode.Supported);
        RecoveryShareOrderedReceiver receiver = new RecoveryShareOrderedReceiver(address(facet), address(account));
        account.setExpectation(
            address(account), address(receiver), _uints(ID_A), _uints(1), _uints(2), address(receiver)
        );

        account.transferSingle(address(receiver), ID_A, 1);

        assertTrue(receiver.accepted());
        assertEq(facet.balanceOf(address(account), ID_A), 2);
        assertEq(facet.balanceOf(address(receiver), ID_A), 1);
    }

    function testRecipientReentrancyCannotDrainSourceAndPreservesNestedOwnTransfer() public {
        RecoveryShareCallbackAccount account = _newAccount();
        _mintOne(account, 3);
        account.setProbeMode(RecoveryShareCallbackAccount.ProbeMode.Supported);

        address sink = address(0xD00D);
        RecoveryShareReentrantReceiver receiver = new RecoveryShareReentrantReceiver(address(facet), sink);
        account.setExpectation(address(account), address(receiver), _uints(ID_A), _uints(1), _uints(2), address(0));

        account.transferSingle(address(receiver), ID_A, 1);

        assertFalse(receiver.sourceDrainSucceeded());
        assertEq(receiver.sourceDrainRevertSelector(), IERC1155Errors.ERC1155MissingApprovalForAll.selector);
        assertTrue(receiver.forwardedOwnBalance());
        assertEq(facet.balanceOf(address(account), ID_A), 2);
        assertEq(facet.balanceOf(address(receiver), ID_A), 0);
        assertEq(facet.balanceOf(sink, ID_A), 1);
        assertEq(facet.totalSupply(ID_A), 3);
    }

    function testCallbackWrongAndNonCanonicalMagicRollback() public {
        RecoveryShareCallbackAccount account = _advertisedAccountWithFourShares();

        account.setCallbackMode(RecoveryShareCallbackAccount.CallbackMode.WrongMagic);
        _expectFailedSingle(
            account,
            abi.encodeWithSelector(
                LibAccountCallbacks.AccountCallbackMagicMismatch.selector,
                address(account),
                CALLBACK,
                bytes32(bytes4(0xdeadbeef))
            )
        );

        account.setCallbackMode(RecoveryShareCallbackAccount.CallbackMode.NonCanonicalMagic);
        bytes32 nonCanonicalWord = bytes32(CALLBACK) | bytes32(uint256(1));
        _expectFailedSingle(
            account,
            abi.encodeWithSelector(
                LibAccountCallbacks.AccountCallbackMagicMismatch.selector, address(account), CALLBACK, nonCanonicalWord
            )
        );
    }

    function testCallbackMalformedReturnsIncludingBoundedOversizedReturnRollback() public {
        RecoveryShareCallbackAccount account = _advertisedAccountWithFourShares();

        account.setCallbackMode(RecoveryShareCallbackAccount.CallbackMode.EmptySuccess);
        _expectMalformedSingle(account, 0);

        account.setCallbackMode(RecoveryShareCallbackAccount.CallbackMode.ShortReturn);
        _expectMalformedSingle(account, 31);

        account.setCallbackMode(RecoveryShareCallbackAccount.CallbackMode.LongReturn);
        _expectMalformedSingle(account, 64);

        account.setCallbackMode(RecoveryShareCallbackAccount.CallbackMode.OversizedReturn);
        _expectMalformedSingle(account, 32_768);
    }

    function testCallbackEmptyAndNonemptyRevertsAreClassifiedAndRollback() public {
        RecoveryShareCallbackAccount account = _advertisedAccountWithFourShares();

        account.setCallbackMode(RecoveryShareCallbackAccount.CallbackMode.EmptyRevert);
        _expectFailedSingle(
            account,
            abi.encodeWithSelector(LibAccountCallbacks.AccountCallbackFailed.selector, address(account), CALLBACK)
        );

        account.setCallbackMode(RecoveryShareCallbackAccount.CallbackMode.RevertWithData);
        _expectFailedSingle(
            account, abi.encodeWithSelector(RecoveryShareCallbackAccount.RecoverySharePolicyRejected.selector, 77)
        );
    }

    function testCallbackOutOfGasIsEmptyFailureAndRollsBack() public {
        RecoveryShareCallbackAccount account = _advertisedAccountWithFourShares();
        account.setCallbackMode(RecoveryShareCallbackAccount.CallbackMode.ExhaustGas);

        vm.expectRevert(
            abi.encodeWithSelector(LibAccountCallbacks.AccountCallbackFailed.selector, address(account), CALLBACK)
        );
        account.transferSingle{gas: 400_000}(RECIPIENT, ID_A, 1);

        _assertUnchangedAfterFailure(account);
    }

    function testEoaSourceSkipsDiscovery() public {
        address[] memory assets = _addresses(ASSET_A);
        uint256[] memory amounts = _uints(2);
        facet.issueFromController(USER, assets, amounts);

        vm.prank(USER);
        facet.safeTransferFrom(USER, RECIPIENT, ID_A, 1, "");

        assertEq(facet.balanceOf(USER, ID_A), 1);
        assertEq(facet.balanceOf(RECIPIENT, ID_A), 1);
    }

    function _advertisedAccountWithFourShares() private returns (RecoveryShareCallbackAccount account) {
        account = _newAccount();
        _mintOne(account, 4);
        account.setProbeMode(RecoveryShareCallbackAccount.ProbeMode.Supported);
    }

    function _expectMalformedSingle(RecoveryShareCallbackAccount account, uint256 returnDataLength) private {
        _expectFailedSingle(
            account,
            abi.encodeWithSelector(
                LibAccountCallbacks.AccountCallbackReturnMalformed.selector,
                address(account),
                CALLBACK,
                returnDataLength
            )
        );
    }

    function _expectFailedSingle(RecoveryShareCallbackAccount account, bytes memory revertData) private {
        vm.expectRevert(revertData);
        account.transferSingle(RECIPIENT, ID_A, 1);
        _assertUnchangedAfterFailure(account);
    }

    function _assertUnchangedAfterFailure(RecoveryShareCallbackAccount account) private view {
        assertEq(facet.balanceOf(address(account), ID_A), 4);
        assertEq(facet.balanceOf(RECIPIENT, ID_A), 0);
        assertEq(facet.totalSupply(ID_A), 4);
    }

    function _newAccount() private returns (RecoveryShareCallbackAccount) {
        return new RecoveryShareCallbackAccount(address(facet));
    }

    function _mintOne(RecoveryShareCallbackAccount account, uint256 amount) private {
        facet.issueFromController(address(account), _addresses(ASSET_A), _uints(amount));
    }

    function _mintTwo(RecoveryShareCallbackAccount account, uint256 amountA, uint256 amountB) private {
        facet.issueFromController(address(account), _addresses(ASSET_A, ASSET_B), _uints(amountA, amountB));
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
        }
    }

    function _addresses(address value) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _addresses(address first, address second) private pure returns (address[] memory values) {
        values = new address[](2);
        values[0] = first;
        values[1] = second;
    }

    function _uints(uint256 value) private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _uints(uint256 first, uint256 second) private pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = first;
        values[1] = second;
    }
}
