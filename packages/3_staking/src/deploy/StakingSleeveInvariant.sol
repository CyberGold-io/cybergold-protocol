// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {ISleeve} from "../sleeves/ISleeve.sol";
import {SleeveBase} from "../sleeves/SleeveBase.sol";
import {SleeveManual} from "../sleeves/SleeveManual.sol";
import {Sleeve4626} from "../sleeves/Sleeve4626.sol";
import {SleeveCurve} from "../sleeves/SleeveCurve.sol";
import {SleeveProxy, ISleeveProxy} from "../sleeves/SleeveProxy.sol";
import {SleeveDeployerHelper} from "./SleeveDeployerHelper.sol";

/// @notice Candidate-bound read-only verifier for exact first-party Sleeve launch state.
/// @dev Called before critical authority exists; its runtime code hash and metadata are part of the candidate.
contract StakingSleeveInvariant {
    /// @notice Version of this authenticated Sleeve-invariant module.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Namespace identifying this authenticated Sleeve-invariant module.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.staking.launch.sleeve-invariant");

    /// @notice Reverts when a deployed Sleeve differs from its committed launch request.
    /// @param index Position of the invalid Sleeve in the committed launch order.
    /// @param sleeve Sleeve proxy whose observed state violates the launch invariant.
    error StakingSleeveInvariantViolation(uint256 index, address sleeve);

    /// @notice Attest a deployed Sleeve's proxy identity, common state, and typed initialization state.
    /// @param stakingDiamond Staking Diamond that must control the Sleeve.
    /// @param index Position of the Sleeve in the committed launch order.
    /// @param sleeve Deterministic Sleeve proxy to inspect.
    /// @param request Exact typed request committed for the Sleeve.
    function requireSleeve(
        address stakingDiamond,
        uint256 index,
        address sleeve,
        SleeveDeployerHelper.SleeveRequest calldata request
    ) external view {
        if (
            sleeve.codehash != keccak256(type(SleeveProxy).runtimeCode)
                || ISleeveProxy(sleeve).implementation() != request.implementation
                || ISleeve(sleeve).stakingDiamond() != stakingDiamond || ISleeve(sleeve).asset() != request.asset
                || ISleeve(sleeve).principalAssets() != 0 || SleeveBase(sleeve).principalCap() != request.principalCap
                || SleeveBase(sleeve).operational() != request.initialOperational
                || SleeveBase(sleeve).paused() != request.initialPaused
        ) _fail(index, sleeve);

        if (request.initType == SleeveDeployerHelper.InitType.Basic) return;
        if (request.initType == SleeveDeployerHelper.InitType.Manual) {
            if (SleeveManual(sleeve).operator() != abi.decode(request.initArgs, (address))) _fail(index, sleeve);
            return;
        }
        if (request.initType == SleeveDeployerHelper.InitType.ERC4626) {
            if (address(Sleeve4626(sleeve).vault()) != abi.decode(request.initArgs, (address))) _fail(index, sleeve);
            return;
        }
        _requireCurve(index, sleeve, abi.decode(request.initArgs, (SleeveCurve.CurveLaunchParams)));
    }

    function _requireCurve(uint256 index, address sleeve, SleeveCurve.CurveLaunchParams memory params) private view {
        SleeveCurve curve = SleeveCurve(sleeve);
        SleeveCurve.CurveInitParams memory venue = params.venue;
        if (
            address(curve.otherAsset()) != venue.otherAsset || address(curve.curvePool()) != venue.pool
                || address(curve.lpToken()) != venue.pool || curve.underlyingIndex() != venue.underlyingIndex
                || curve.otherIndex() != venue.otherIndex || curve.targetOtherPpm() != venue.otherSharePpm
                || address(curve.gauge()) != venue.gauge || curve.priceReference() != venue.priceReference
                || curve.maxPriceDeviationBps() != venue.maxPriceDeviationBps
                || address(curve.cygldController()) != venue.cygldController
                || curve.basketSwapAdapter() != venue.basketSwapAdapter || curve.maxLpTokens() != params.maxLpTokens
                || curve.rewardSwapAdapter() != params.rewardSwapAdapter
        ) _fail(index, sleeve);

        address[] memory observedRewards = curve.rewardTokens();
        if (keccak256(abi.encode(observedRewards)) != keccak256(abi.encode(params.rewardTokens))) {
            _fail(index, sleeve);
        }
    }

    function _fail(uint256 index, address sleeve) private pure {
        revert StakingSleeveInvariantViolation(index, sleeve);
    }
}
