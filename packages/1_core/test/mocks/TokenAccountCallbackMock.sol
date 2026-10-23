// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface ITokenAccountCallbackTarget {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface ITokenAccountCallbackView {
    function allowance(address owner, address spender) external view returns (uint256);
    function allowanceExposure(address owner) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice Token-specific adversarial account used to exercise bounded ERC-165 discovery and callbacks.
/// @dev The fallback deliberately exposes raw returndata shapes that Solidity functions cannot express.
contract TokenAccountCallbackMock {
    enum ProbeMode {
        CanonicalFalse,
        CanonicalTrue,
        RevertEmpty,
        RevertData,
        ReturnEmpty,
        ReturnShort,
        ReturnLong,
        ReturnNonCanonical,
        ReturnOversized,
        GasHeavyFalse,
        GasHeavyTrue,
        GasThresholdTrue,
        ExhaustGas
    }

    enum CallbackMode {
        ExactMagic,
        WrongMagic,
        ReturnEmpty,
        ReturnShort,
        ReturnLong,
        ReturnOversized,
        RevertEmpty,
        RevertPolicy,
        RevertOversized,
        ExhaustGas,
        AttemptSstore,
        AttemptLog,
        AttemptNestedTransfer
    }

    struct CallbackExpectation {
        bytes32 callHash;
        address token;
        address allowanceSpender;
        uint256 balance;
        uint256 exposure;
        uint256 allowance;
        bool checkAllowance;
        bool enabled;
    }

    error ProbeRejected(bytes4 interfaceId);
    error PolicyRejected(bytes4 callback);
    error UnexpectedCallback(bytes4 callback, bytes32 actualHash, bytes32 expectedHash);
    error UnexpectedCallbackCaller(bytes4 callback, address actual, address expected);
    error UnexpectedLiveValue(bytes4 callback, uint8 field, uint256 actual, uint256 expected);

    mapping(bytes4 interfaceId => ProbeMode mode) private _probeModes;
    mapping(bytes4 callback => CallbackMode mode) private _callbackModes;
    mapping(bytes4 callback => CallbackExpectation expectation) private _expectations;
    uint256 private _oversizedRevertLength;

    function setProbeMode(bytes4 interfaceId, ProbeMode mode) external {
        _probeModes[interfaceId] = mode;
    }

    function setCallbackMode(bytes4 callback, CallbackMode mode) external {
        _callbackModes[callback] = mode;
    }

    function setOversizedRevertLength(uint256 length) external {
        _oversizedRevertLength = length;
    }

    function setCallbackExpectation(
        bytes4 callback,
        bytes32 callHash,
        address token,
        uint256 balance,
        uint256 exposure,
        address allowanceSpender,
        uint256 allowance,
        bool checkAllowance
    ) external {
        _expectations[callback] = CallbackExpectation({
            callHash: callHash,
            token: token,
            allowanceSpender: allowanceSpender,
            balance: balance,
            exposure: exposure,
            allowance: allowance,
            checkAllowance: checkAllowance,
            enabled: true
        });
    }

    function clearCallbackExpectation(bytes4 callback) external {
        delete _expectations[callback];
    }

    function approveToken(address token, address spender, uint256 value) external returns (bool) {
        return ITokenAccountCallbackTarget(token).approve(spender, value);
    }

    function transferToken(address token, address recipient, uint256 amount) external returns (bool) {
        return ITokenAccountCallbackTarget(token).transfer(recipient, amount);
    }

    fallback(bytes calldata input) external returns (bytes memory output) {
        if (msg.sig == IERC165.supportsInterface.selector) {
            bytes4 interfaceId = abi.decode(input[4:], (bytes4));
            return _probeResponse(interfaceId, _probeModes[interfaceId]);
        }

        bytes4 callback = msg.sig;
        _validateExpectation(callback, input);
        CallbackMode mode = _callbackModes[callback];
        if (mode == CallbackMode.AttemptNestedTransfer) {
            require(
                ITokenAccountCallbackTarget(_expectations[callback].token).transfer(address(0xDEAD), 1),
                "nested transfer returned false"
            );
            return abi.encode(callback);
        }
        return _callbackResponse(callback, mode);
    }

    function _validateExpectation(bytes4 callback, bytes calldata input) private view {
        CallbackExpectation storage expectation = _expectations[callback];
        if (!expectation.enabled) return;

        bytes32 actualHash = keccak256(input);
        if (actualHash != expectation.callHash) {
            revert UnexpectedCallback(callback, actualHash, expectation.callHash);
        }
        if (msg.sender != expectation.token) {
            revert UnexpectedCallbackCaller(callback, msg.sender, expectation.token);
        }

        ITokenAccountCallbackView token = ITokenAccountCallbackView(expectation.token);
        uint256 actual = token.balanceOf(address(this));
        if (actual != expectation.balance) {
            revert UnexpectedLiveValue(callback, 0, actual, expectation.balance);
        }
        actual = token.allowanceExposure(address(this));
        if (actual != expectation.exposure) {
            revert UnexpectedLiveValue(callback, 1, actual, expectation.exposure);
        }
        if (expectation.checkAllowance) {
            actual = token.allowance(address(this), expectation.allowanceSpender);
            if (actual != expectation.allowance) {
                revert UnexpectedLiveValue(callback, 2, actual, expectation.allowance);
            }
        }
    }

    function _probeResponse(bytes4 interfaceId, ProbeMode mode) private view returns (bytes memory output) {
        if (mode == ProbeMode.CanonicalFalse) return abi.encode(false);
        if (mode == ProbeMode.CanonicalTrue) return abi.encode(true);
        if (mode == ProbeMode.RevertEmpty) {
            assembly {
                revert(0, 0)
            }
        }
        if (mode == ProbeMode.RevertData) revert ProbeRejected(interfaceId);
        if (mode == ProbeMode.ReturnEmpty) return new bytes(0);
        if (mode == ProbeMode.ReturnShort) return hex"01";
        if (mode == ProbeMode.ReturnLong) return abi.encode(true, true);
        if (mode == ProbeMode.ReturnNonCanonical) return abi.encode(uint256(2));
        if (mode == ProbeMode.ReturnOversized) return new bytes(4096);
        if (mode == ProbeMode.GasThresholdTrue) return abi.encode(gasleft() >= 25_000);
        if (mode == ProbeMode.ExhaustGas) {
            assembly {
                invalid()
            }
        }

        while (gasleft() > 2_000) {}
        return abi.encode(mode == ProbeMode.GasHeavyTrue);
    }

    function _callbackResponse(bytes4 callback, CallbackMode mode) private returns (bytes memory output) {
        if (mode == CallbackMode.ExactMagic) return abi.encode(callback);
        if (mode == CallbackMode.WrongMagic) return abi.encode(bytes32(uint256(0xBADC0DE)));
        if (mode == CallbackMode.ReturnEmpty) return new bytes(0);
        if (mode == CallbackMode.ReturnShort) return abi.encodePacked(callback);
        if (mode == CallbackMode.ReturnLong) return abi.encode(bytes32(callback), bytes32(uint256(1)));
        if (mode == CallbackMode.ReturnOversized) return new bytes(4096);
        if (mode == CallbackMode.RevertEmpty) {
            assembly {
                revert(0, 0)
            }
        }
        if (mode == CallbackMode.RevertPolicy) revert PolicyRejected(callback);
        if (mode == CallbackMode.RevertOversized) {
            uint256 length = _oversizedRevertLength;
            bytes memory revertData = new bytes(length);
            assembly ("memory-safe") {
                revert(add(revertData, 0x20), length)
            }
        }
        if (mode == CallbackMode.AttemptSstore) {
            assembly {
                sstore(0, 1)
            }
        }
        if (mode == CallbackMode.AttemptLog) {
            assembly {
                log0(0, 0)
            }
        }

        assembly {
            invalid()
        }
    }
}
