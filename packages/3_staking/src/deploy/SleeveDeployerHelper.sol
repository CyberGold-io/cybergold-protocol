// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {SleeveCurve} from "../sleeves/SleeveCurve.sol";
import {SleeveManual} from "../sleeves/SleeveManual.sol";
import {Sleeve4626} from "../sleeves/Sleeve4626.sol";
import {SleeveProxy} from "../sleeves/SleeveProxy.sol";

/// @notice Package-local sleeve deployer used by scripts/tests to avoid duplicating logic.
library SleeveDeployerHelper {
    /// @notice Reverts when sleeve implementation missing.
    error SleeveImplementationMissing();
    /// @notice Reverts when sleeve asset missing.
    error SleeveAssetMissing();
    /// @notice Reverts when sleeve curve config missing.
    error SleeveCurveConfigMissing();
    /// @notice Reverts when sleeve init data missing.
    error SleeveInitDataMissing();
    /// @notice Reverts when typed Sleeve arguments have a non-canonical ABI encoding.
    error SleeveInitDataNonCanonical();
    /// @notice Reverts when the test-only Basic builder requests unsupported launch state.
    /// @param operational Requested initial operational state, which must be true for a Basic Sleeve.
    /// @param paused Requested initial local pause state, which must be false for a Basic Sleeve.
    error SleeveBasicStateUnsupported(bool operational, bool paused);
    /// @notice Enumerates init type states used by the staking diamond.
    enum InitType {
        Basic,
        Manual,
        ERC4626,
        Curve
    }

    /// @notice Requested sleeve implementation, asset, initialization, approval, and cap.
    struct SleeveRequest {
        address implementation;
        address asset;
        bool approve;
        bool initialOperational;
        bool initialPaused;
        uint256 principalCap;
        InitType initType;
        bytes initArgs;
    }

    /// @notice Deployed sleeve address and the registry metadata applied to it.
    struct SleeveDeployment {
        address sleeve;
        address asset;
        bool approve;
    }

    /// @dev Build and CREATE2-deploy one typed Sleeve proxy from the Staking Diamond context.
    function deployDeterministic(address stakingDiamond, SleeveRequest memory req, bytes32 salt)
        internal
        returns (address sleeve)
    {
        if (req.implementation == address(0)) revert SleeveImplementationMissing();
        if (req.asset == address(0)) revert SleeveAssetMissing();
        bytes memory initCalldata = _buildInitializer(req, stakingDiamond);
        sleeve = address(new SleeveProxy{salt: salt}(req.implementation, initCalldata));
    }

    /// @dev Predict the proxy address produced by `deployDeterministic`.
    function predictDeterministic(address deployer, address stakingDiamond, SleeveRequest memory req, bytes32 salt)
        internal
        pure
        returns (address predicted)
    {
        if (req.implementation == address(0)) revert SleeveImplementationMissing();
        if (req.asset == address(0)) revert SleeveAssetMissing();
        bytes memory initCalldata = _buildInitializer(req, stakingDiamond);
        bytes32 initCodeHash =
            keccak256(bytes.concat(type(SleeveProxy).creationCode, abi.encode(req.implementation, initCalldata)));
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @dev Build initializer.
    /// @param req Single sleeve deployment request being processed.
    /// @param stakingDiamond Shared Staking Diamond controller applied to the Sleeve.
    /// @return initCalldata Initializer calldata for a sleeve deployment request.
    function _buildInitializer(SleeveRequest memory req, address stakingDiamond)
        internal
        pure
        returns (bytes memory initCalldata)
    {
        if (req.initType == InitType.Basic) {
            if (req.initArgs.length != 0) revert SleeveInitDataNonCanonical();
            if (!req.initialOperational || req.initialPaused) {
                revert SleeveBasicStateUnsupported(req.initialOperational, req.initialPaused);
            }
            initCalldata = abi.encodeWithSignature(
                "initialize(address,address,uint256)", stakingDiamond, req.asset, req.principalCap
            );
        } else if (req.initType == InitType.Manual) {
            address operator = _decodeCanonicalAddress(req.initArgs);
            initCalldata = abi.encodeCall(
                SleeveManual.initialize,
                (stakingDiamond, req.asset, req.principalCap, operator, req.initialOperational, req.initialPaused)
            );
        } else if (req.initType == InitType.ERC4626) {
            address vault = _decodeCanonicalAddress(req.initArgs);
            initCalldata = abi.encodeCall(
                Sleeve4626.initialize,
                (stakingDiamond, req.asset, req.principalCap, vault, req.initialOperational, req.initialPaused)
            );
        } else {
            // `InitType` is a closed Solidity enum, so every remaining ABI-valid value is Curve.
            // Invalid in-memory enum words panic when read before control can reach this branch.
            SleeveCurve.CurveLaunchParams memory params = _decodeCanonicalCurveParams(req.initArgs);

            if (
                params.venue.pool == address(0) || params.venue.otherAsset == address(0)
                    || params.venue.cygldController == address(0)
            ) {
                revert SleeveCurveConfigMissing();
            }

            initCalldata = abi.encodeCall(
                SleeveCurve.initialize,
                (stakingDiamond, req.asset, req.principalCap, params, req.initialOperational, req.initialPaused)
            );
        }

        requireInitializerBuilt(initCalldata);
    }

    function _decodeCanonicalAddress(bytes memory data) private pure returns (address value) {
        if (data.length != 32) revert SleeveInitDataNonCanonical();
        value = abi.decode(data, (address));
        requireCanonicalAddressEncoding(data, value);
    }

    function _decodeCanonicalCurveParams(bytes memory data)
        private
        pure
        returns (SleeveCurve.CurveLaunchParams memory params)
    {
        if (data.length == 0) revert SleeveInitDataNonCanonical();
        params = abi.decode(data, (SleeveCurve.CurveLaunchParams));
        if (keccak256(data) != keccak256(abi.encode(params))) revert SleeveInitDataNonCanonical();
    }

    /// @dev Require that a handled initializer branch produced nonempty calldata.
    function requireInitializerBuilt(bytes memory initCalldata) internal pure {
        if (initCalldata.length == 0) revert SleeveInitDataMissing();
    }

    /// @dev Require an address argument to use the unique canonical ABI word encoding.
    function requireCanonicalAddressEncoding(bytes memory data, address value) internal pure {
        if (keccak256(data) != keccak256(abi.encode(value))) revert SleeveInitDataNonCanonical();
    }
}
