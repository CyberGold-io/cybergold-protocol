// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {SleeveDeployerHelper} from "./SleeveDeployerHelper.sol";
import {SleeveCurve} from "../sleeves/SleeveCurve.sol";

/// @notice Helper functions to construct sleeve requests for deployment/testing.
library SleeveRequestBuilder {
    using SleeveRequestBuilder for SleeveDeployerHelper.SleeveRequest;

    /// @dev Return basic.
    /// @param implementation Implementation address reported by an upgrade event.
    /// @param asset Underlying ERC-20 assigned to the basic sleeve.
    /// @param approve Whether the sleeve is approved immediately after deployment.
    /// @param principalCap Maximum principal that may remain allocated in the sleeve.
    /// @return Sleeve deployment request assembled for scripts and tests.
    function basic(address implementation, address asset, bool approve, uint256 principalCap)
        internal
        pure
        returns (SleeveDeployerHelper.SleeveRequest memory)
    {
        return SleeveDeployerHelper.SleeveRequest({
            implementation: implementation,
            asset: asset,
            approve: approve,
            initialOperational: true,
            initialPaused: false,
            principalCap: principalCap,
            initType: SleeveDeployerHelper.InitType.Basic,
            initArgs: ""
        });
    }

    /// @dev Return manual.
    /// @param implementation Implementation address reported by an upgrade event.
    /// @param asset Underlying ERC-20 assigned to the manually operated sleeve.
    /// @param operator Operator address being authorized or queried.
    /// @param approve Whether the sleeve is approved immediately after deployment.
    /// @param principalCap Maximum principal that may remain allocated in the sleeve.
    /// @return Sleeve deployment request assembled for scripts and tests.
    function manual(address implementation, address asset, address operator, bool approve, uint256 principalCap)
        internal
        pure
        returns (SleeveDeployerHelper.SleeveRequest memory)
    {
        return manualWithState(implementation, asset, operator, approve, principalCap, true, false);
    }

    /// @dev Construct a Manual request with exact launch operational and local-pause state.
    function manualWithState(
        address implementation,
        address asset,
        address operator,
        bool approve,
        uint256 principalCap,
        bool initialOperational,
        bool initialPaused
    ) internal pure returns (SleeveDeployerHelper.SleeveRequest memory) {
        return SleeveDeployerHelper.SleeveRequest({
            implementation: implementation,
            asset: asset,
            approve: approve,
            initialOperational: initialOperational,
            initialPaused: initialPaused,
            principalCap: principalCap,
            initType: SleeveDeployerHelper.InitType.Manual,
            initArgs: abi.encode(operator)
        });
    }

    /// @dev Return erc4626.
    /// @param implementation Implementation address reported by an upgrade event.
    /// @param asset Underlying ERC-20 deposited into the external ERC-4626 vault.
    /// @param vault Vault facet address used by staking deployment helpers.
    /// @param approve Whether the sleeve is approved immediately after deployment.
    /// @param principalCap Maximum principal that may remain allocated in the sleeve.
    /// @return Sleeve deployment request assembled for scripts and tests.
    function erc4626(address implementation, address asset, address vault, bool approve, uint256 principalCap)
        internal
        pure
        returns (SleeveDeployerHelper.SleeveRequest memory)
    {
        return erc4626WithState(implementation, asset, vault, approve, principalCap, true, false);
    }

    /// @dev Construct an ERC-4626 request with exact launch operational and local-pause state.
    function erc4626WithState(
        address implementation,
        address asset,
        address vault,
        bool approve,
        uint256 principalCap,
        bool initialOperational,
        bool initialPaused
    ) internal pure returns (SleeveDeployerHelper.SleeveRequest memory) {
        return SleeveDeployerHelper.SleeveRequest({
            implementation: implementation,
            asset: asset,
            approve: approve,
            initialOperational: initialOperational,
            initialPaused: initialPaused,
            principalCap: principalCap,
            initType: SleeveDeployerHelper.InitType.ERC4626,
            initArgs: abi.encode(vault)
        });
    }

    /// @dev Return curve.
    /// @param implementation Implementation address reported by an upgrade event.
    /// @param asset Underlying ERC-20 paired in the Curve sleeve.
    /// @param params Curve sleeve initialization parameters encoded into the deployment request.
    /// @param approve Whether the sleeve is approved immediately after deployment.
    /// @param principalCap Maximum principal that may remain allocated in the sleeve.
    /// @return Sleeve deployment request assembled for scripts and tests.
    function curve(
        address implementation,
        address asset,
        SleeveCurve.CurveInitParams memory params,
        bool approve,
        uint256 principalCap
    ) internal pure returns (SleeveDeployerHelper.SleeveRequest memory) {
        SleeveCurve.CurveLaunchParams memory launchParams = SleeveCurve.CurveLaunchParams({
            venue: params,
            maxLpTokens: 0,
            rewardSwapAdapter: address(0),
            rewardTokens: new address[](0)
        });
        return curveLaunch(implementation, asset, launchParams, approve, principalCap, true, false);
    }

    /// @dev Construct a complete Curve request with exact launch state and typed configuration.
    function curveLaunch(
        address implementation,
        address asset,
        SleeveCurve.CurveLaunchParams memory params,
        bool approve,
        uint256 principalCap,
        bool initialOperational,
        bool initialPaused
    ) internal pure returns (SleeveDeployerHelper.SleeveRequest memory) {
        return SleeveDeployerHelper.SleeveRequest({
            implementation: implementation,
            asset: asset,
            approve: approve,
            initialOperational: initialOperational,
            initialPaused: initialPaused,
            principalCap: principalCap,
            initType: SleeveDeployerHelper.InitType.Curve,
            initArgs: abi.encode(params)
        });
    }

}
