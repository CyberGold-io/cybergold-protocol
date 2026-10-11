// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {RecoveryPoolSettlementFacet} from "../src/facets/RecoveryPoolSettlementFacet.sol";
import {IRecoveryShareRedemptionCallback} from "../src/interfaces/IRecoveryShareRedemptionCallback.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibAccountCallbacks} from "../src/libraries/LibAccountCallbacks.sol";
import {LibRecoveryShareStorage} from "../src/libraries/LibRecoveryShareStorage.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {LibReserveLifecycleStorage} from "../src/libraries/LibReserveLifecycleStorage.sol";

contract RecoveryCallbackSettlementHarness is RecoveryPoolSettlementFacet {
    mapping(address asset => mapping(address account => uint256 shares)) private _balances;

    function seedPool(address asset, address holder, uint256 supply, uint256 nominalRaw) external {
        LibRecoveryStorage.RecoveryPool storage poolData = LibRecoveryStorage.getLayout().pools[asset];
        poolData.impaired = false;
        poolData.coreAttachedShares = 0;
        poolData.redeemableRaw = nominalRaw;
        LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))] = supply;
        _balances[asset][holder] = supply;
        LibReserveLifecycleStorage.getLayout().records[asset].lifecycle = IRecoveryTypes.ReserveLifecycle.Inactive;
    }

    function totalSupply(uint256 shareId) external view returns (uint256) {
        return LibRecoveryShareStorage.getLayout().supply[shareId];
    }

    function shareBalance(address asset, address account) external view returns (uint256) {
        return _balances[asset][account];
    }

    function poolRaw(address asset) external view returns (uint256) {
        return LibRecoveryStorage.getLayout().pools[asset].redeemableRaw;
    }

    function burnRecoveryShares(address account, address asset, uint256 amount) external {
        if (msg.sender != address(this)) revert RecoveryShareControllerOnly(msg.sender);
        _balances[asset][account] -= amount;
        LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))] -= amount;
    }
}

contract RecoveryCallbackAsset {
    mapping(address account => uint256 balance) private _balances;

    function mint(address account, uint256 amount) external {
        _balances[account] += amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[recipient] += amount;
        return true;
    }
}

contract RedemptionCallbackAccount is IRecoveryShareRedemptionCallback {
    enum ProbeMode {
        False,
        True,
        RevertWithData,
        EmptyRevert,
        EmptyReturn,
        ShortReturn,
        LongReturn,
        NoncanonicalTrue,
        OversizedReturn,
        OversizedRevert,
        ExactGasWindow,
        ExhaustGas
    }

    enum CallbackMode {
        Magic,
        PolicyRevert,
        EmptyRevert,
        EmptyReturn,
        ShortReturn,
        LongReturn,
        WrongMagic,
        NoncanonicalMagic,
        OversizedReturn,
        ObservePreState,
        ExhaustGas
    }

    error ProbeRejected();
    error RedemptionPolicyRejected();
    error RedemptionObserved(bytes32 observation);

    RecoveryCallbackSettlementHarness internal immutable _settlement;
    ProbeMode internal _probeMode;
    CallbackMode internal _callbackMode;

    constructor(RecoveryCallbackSettlementHarness settlement_) {
        _settlement = settlement_;
    }

    function configure(ProbeMode probeMode_, CallbackMode callbackMode_) external {
        _probeMode = probeMode_;
        _callbackMode = callbackMode_;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        ProbeMode mode = _probeMode;
        if (mode == ProbeMode.False) return false;
        if (mode == ProbeMode.True) {
            return interfaceId == type(IRecoveryShareRedemptionCallback).interfaceId;
        }
        if (mode == ProbeMode.RevertWithData) revert ProbeRejected();
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
                return(0, 1)
            }
        }
        if (mode == ProbeMode.LongReturn) {
            assembly {
                mstore(0, 1)
                mstore(0x20, 0)
                return(0, 0x40)
            }
        }
        if (mode == ProbeMode.NoncanonicalTrue) {
            assembly {
                mstore(0, 2)
                return(0, 0x20)
            }
        }
        if (mode == ProbeMode.OversizedReturn) {
            assembly {
                mstore(0, 1)
                return(0, 0x2000)
            }
        }
        if (mode == ProbeMode.OversizedRevert) {
            assembly {
                mstore(0, 1)
                revert(0, 0x2000)
            }
        }
        if (mode == ProbeMode.ExhaustGas) {
            assembly {
                invalid()
            }
        }

        uint256 observedGas = gasleft();
        return interfaceId == type(IRecoveryShareRedemptionCallback).interfaceId && observedGas <= 30_000
            && observedGas >= 27_000;
    }

    function onRecoveryShareRedemption(
        address impairedAsset,
        uint256 shares,
        address recipient,
        uint256 minRawOut,
        uint256 rawOut
    ) external view returns (bytes4 magic) {
        CallbackMode mode = _callbackMode;
        if (mode == CallbackMode.Magic) return this.onRecoveryShareRedemption.selector;
        if (mode == CallbackMode.PolicyRevert) revert RedemptionPolicyRejected();
        if (mode == CallbackMode.EmptyRevert) {
            assembly {
                revert(0, 0)
            }
        }
        if (mode == CallbackMode.EmptyReturn) {
            assembly {
                return(0, 0)
            }
        }
        if (mode == CallbackMode.ShortReturn) {
            assembly {
                mstore(0, 1)
                return(0, 0x1f)
            }
        }
        if (mode == CallbackMode.LongReturn) {
            assembly {
                mstore(0, 1)
                mstore(0x20, 0)
                return(0, 0x40)
            }
        }
        if (mode == CallbackMode.WrongMagic) return bytes4(0xdeadbeef);
        if (mode == CallbackMode.NoncanonicalMagic) {
            bytes32 returnedWord = bytes32(this.onRecoveryShareRedemption.selector) | bytes32(uint256(1));
            assembly {
                mstore(0, returnedWord)
                return(0, 0x20)
            }
        }
        if (mode == CallbackMode.OversizedReturn) {
            bytes4 selector = this.onRecoveryShareRedemption.selector;
            assembly {
                mstore(0, shl(224, selector))
                return(0, 0x2000)
            }
        }
        if (mode == CallbackMode.ObservePreState) {
            bytes32 operation = keccak256(abi.encode(impairedAsset, shares, recipient, minRawOut, rawOut));
            bytes32 state = keccak256(
                abi.encode(
                    _settlement.poolRaw(impairedAsset),
                    _settlement.totalSupply(uint256(uint160(impairedAsset))),
                    _settlement.shareBalance(impairedAsset, address(this))
                )
            );
            bytes32 observation = keccak256(abi.encode(operation, state));
            revert RedemptionObserved(observation);
        }

        for (;;) {}
    }

    function redeem(address asset, uint256 shares, address recipient, uint256 minRawOut)
        external
        returns (uint256 rawOut)
    {
        return _settlement.redeemRecoveryShares(asset, shares, recipient, minRawOut);
    }

    function redeemWithGas(address asset, uint256 shares, address recipient, uint256 minRawOut, uint256 gasLimit)
        external
        returns (bool success, bytes memory returnData)
    {
        (success, returnData) = address(_settlement).call{gas: gasLimit}(
            abi.encodeWithSelector(
                RecoveryPoolSettlementFacet.redeemRecoveryShares.selector, asset, shares, recipient, minRawOut
            )
        );
    }
}

contract RecoveryPoolSettlementCallbacksTest is Test {
    address internal constant RECIPIENT = address(0xCAFE);

    function testNonAdvertisingContractAndEveryFailedProbePreserveOrdinaryRedemption() public {
        RedemptionCallbackAccount.ProbeMode[9] memory modes = [
            RedemptionCallbackAccount.ProbeMode.False,
            RedemptionCallbackAccount.ProbeMode.RevertWithData,
            RedemptionCallbackAccount.ProbeMode.EmptyRevert,
            RedemptionCallbackAccount.ProbeMode.EmptyReturn,
            RedemptionCallbackAccount.ProbeMode.ShortReturn,
            RedemptionCallbackAccount.ProbeMode.LongReturn,
            RedemptionCallbackAccount.ProbeMode.NoncanonicalTrue,
            RedemptionCallbackAccount.ProbeMode.OversizedReturn,
            RedemptionCallbackAccount.ProbeMode.OversizedRevert
        ];

        for (uint256 i; i < modes.length; ++i) {
            (
                RecoveryCallbackSettlementHarness settlement,
                RecoveryCallbackAsset asset,
                RedemptionCallbackAccount account
            ) = _seed();
            account.configure(modes[i], RedemptionCallbackAccount.CallbackMode.PolicyRevert);

            assertEq(account.redeem(address(asset), 2, RECIPIENT, 10), 20);
            assertEq(settlement.poolRaw(address(asset)), 80);
            assertEq(settlement.totalSupply(uint256(uint160(address(asset)))), 8);
            assertEq(settlement.shareBalance(address(asset), address(account)), 8);
            assertEq(asset.balanceOf(RECIPIENT), 20);
        }
    }

    function testExactProbeStipendOptsInWithinFrozenGasWindow() public {
        (RecoveryCallbackSettlementHarness settlement, RecoveryCallbackAsset asset, RedemptionCallbackAccount account) =
            _seed();
        account.configure(
            RedemptionCallbackAccount.ProbeMode.ExactGasWindow, RedemptionCallbackAccount.CallbackMode.PolicyRevert
        );

        vm.expectRevert(RedemptionCallbackAccount.RedemptionPolicyRejected.selector);
        account.redeem(address(asset), 2, RECIPIENT, 10);
        _assertUnchanged(settlement, asset, account);
    }

    function testAdvertisedCallbackReceivesExactContextBeforeEveryEffect() public {
        (RecoveryCallbackSettlementHarness settlement, RecoveryCallbackAsset asset, RedemptionCallbackAccount account) =
            _seed();
        account.configure(
            RedemptionCallbackAccount.ProbeMode.True, RedemptionCallbackAccount.CallbackMode.ObservePreState
        );

        bytes32 expectedOperation = keccak256(abi.encode(address(asset), 2, RECIPIENT, 19, 20));
        bytes32 expectedState = keccak256(abi.encode(uint256(100), uint256(10), uint256(10)));
        bytes32 expectedObservation = keccak256(abi.encode(expectedOperation, expectedState));
        vm.expectRevert(
            abi.encodeWithSelector(RedemptionCallbackAccount.RedemptionObserved.selector, expectedObservation)
        );
        account.redeem(address(asset), 2, RECIPIENT, 19);
        _assertUnchanged(settlement, asset, account);

        account.configure(RedemptionCallbackAccount.ProbeMode.True, RedemptionCallbackAccount.CallbackMode.Magic);
        assertEq(account.redeem(address(asset), 2, RECIPIENT, 19), 20);
        assertEq(settlement.poolRaw(address(asset)), 80);
        assertEq(settlement.shareBalance(address(asset), address(account)), 8);
        assertEq(asset.balanceOf(RECIPIENT), 20);
    }

    function testAdvertisedCallbackPolicyAndEmptyFailuresRollBack() public {
        (RecoveryCallbackSettlementHarness settlement, RecoveryCallbackAsset asset, RedemptionCallbackAccount account) =
            _seed();
        account.configure(RedemptionCallbackAccount.ProbeMode.True, RedemptionCallbackAccount.CallbackMode.PolicyRevert);
        vm.expectRevert(RedemptionCallbackAccount.RedemptionPolicyRejected.selector);
        account.redeem(address(asset), 2, RECIPIENT, 0);
        _assertUnchanged(settlement, asset, account);

        account.configure(RedemptionCallbackAccount.ProbeMode.True, RedemptionCallbackAccount.CallbackMode.EmptyRevert);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibAccountCallbacks.AccountCallbackFailed.selector,
                address(account),
                IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector
            )
        );
        account.redeem(address(asset), 2, RECIPIENT, 0);
        _assertUnchanged(settlement, asset, account);

        account.configure(RedemptionCallbackAccount.ProbeMode.True, RedemptionCallbackAccount.CallbackMode.ExhaustGas);
        (bool success, bytes memory returnData) = account.redeemWithGas(address(asset), 2, RECIPIENT, 0, 400_000);
        assertFalse(success);
        assertEq(
            returnData,
            abi.encodeWithSelector(
                LibAccountCallbacks.AccountCallbackFailed.selector,
                address(account),
                IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector
            )
        );
        _assertUnchanged(settlement, asset, account);
    }

    function testAdvertisedCallbackRejectsEveryMalformedSuccessfulReturnWithoutCopyingOversizedData() public {
        RedemptionCallbackAccount.CallbackMode[4] memory modes = [
            RedemptionCallbackAccount.CallbackMode.EmptyReturn,
            RedemptionCallbackAccount.CallbackMode.ShortReturn,
            RedemptionCallbackAccount.CallbackMode.LongReturn,
            RedemptionCallbackAccount.CallbackMode.OversizedReturn
        ];
        uint256[4] memory lengths = [uint256(0), uint256(31), uint256(64), uint256(8192)];

        for (uint256 i; i < modes.length; ++i) {
            (
                RecoveryCallbackSettlementHarness settlement,
                RecoveryCallbackAsset asset,
                RedemptionCallbackAccount account
            ) = _seed();
            account.configure(RedemptionCallbackAccount.ProbeMode.True, modes[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    LibAccountCallbacks.AccountCallbackReturnMalformed.selector,
                    address(account),
                    IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector,
                    lengths[i]
                )
            );
            account.redeem(address(asset), 2, RECIPIENT, 0);
            _assertUnchanged(settlement, asset, account);
        }
    }

    function testAdvertisedCallbackRejectsWrongMagicAndNoncanonicalPadding() public {
        (RecoveryCallbackSettlementHarness settlement, RecoveryCallbackAsset asset, RedemptionCallbackAccount account) =
            _seed();
        account.configure(RedemptionCallbackAccount.ProbeMode.True, RedemptionCallbackAccount.CallbackMode.WrongMagic);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibAccountCallbacks.AccountCallbackMagicMismatch.selector,
                address(account),
                IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector,
                bytes32(bytes4(0xdeadbeef))
            )
        );
        account.redeem(address(asset), 2, RECIPIENT, 0);
        _assertUnchanged(settlement, asset, account);

        bytes32 noncanonical =
            bytes32(IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector) | bytes32(uint256(1));
        account.configure(
            RedemptionCallbackAccount.ProbeMode.True, RedemptionCallbackAccount.CallbackMode.NoncanonicalMagic
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                LibAccountCallbacks.AccountCallbackMagicMismatch.selector,
                address(account),
                IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector,
                noncanonical
            )
        );
        account.redeem(address(asset), 2, RECIPIENT, 0);
        _assertUnchanged(settlement, asset, account);
    }

    function _seed()
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

    function _assertUnchanged(
        RecoveryCallbackSettlementHarness settlement,
        RecoveryCallbackAsset asset,
        RedemptionCallbackAccount account
    ) private view {
        assertEq(settlement.poolRaw(address(asset)), 100);
        assertEq(settlement.totalSupply(uint256(uint160(address(asset)))), 10);
        assertEq(settlement.shareBalance(address(asset), address(account)), 10);
        assertEq(asset.balanceOf(address(settlement)), 100);
        assertEq(asset.balanceOf(RECIPIENT), 0);
    }
}
