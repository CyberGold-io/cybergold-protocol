// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SleeveBase} from "./SleeveBase.sol";

/// @notice Sleeve that delegates venue management to an external operator.
///         Assets are transferred out on allocate and must be returned manually before deallocate/harvest.
contract SleeveManual is SleeveBase {
    using SafeERC20 for IERC20;

    /// @notice Emitted when governance replaces the external asset operator.
    /// @param operator New operator authorized to receive allocated assets.
    event OperatorUpdated(address operator);

    /// @notice External operator that receives custody assets and must return them to this contract before unwind.
    address public operator;

    /// @notice Initialize the proxy with its complete committed launch configuration.
    /// @param stakingDiamond_ Staking Diamond that operates and controls the sleeve.
    /// @param asset_ Underlying asset token accepted by the sleeve.
    /// @param principalCap_ Initial maximum tracked principal; zero means uncapped.
    /// @param operator_ Operator address configured during initialization.
    /// @param operational_ Whether new allocations are enabled immediately after launch.
    /// @param paused_ Whether the Sleeve starts locally paused.
    function initialize(
        address stakingDiamond_,
        address asset_,
        uint256 principalCap_,
        address operator_,
        bool operational_,
        bool paused_
    ) external initializer {
        __SleeveBase_initLaunch(stakingDiamond_, asset_, principalCap_, operational_, paused_);
        _setOperator(operator_);
    }

    /// @notice Replace the external account authorized to manage assets off contract.
    /// @param newOperator Replacement manual sleeve operator.
    function setOperator(address newOperator) external onlyStakingDiamondAdmin {
        _setOperator(newOperator);
    }

    /// @dev Store a nonzero external operator and emit the replacement.
    /// @param newOperator Replacement manual sleeve operator.
    function _setOperator(address newOperator) internal {
        if (newOperator == address(0)) revert ZeroAddress();
        operator = newOperator;
        emit OperatorUpdated(newOperator);
    }

    /// @notice Return underlying currently held by the sleeve contract.
    /// @dev Assets held by the external operator are not observable and therefore are not included.
    /// @return On-contract underlying balance.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @dev Pull the requested underlying from Staking custody and transfer it to the external operator.
    /// @param assets Exact underlying amount transferred to the operator.
    /// @return used Underlying amount moved off contract and added to book principal.
    function _onAllocate(uint256 assets, bytes calldata) internal override returns (uint256 used) {
        _pullFromCustody(assets, address(this));
        IERC20(asset()).safeTransfer(operator, assets);
        return assets;
    }

    /// @dev Return up to the requested amount from underlying that the operator has first sent back on contract.
    /// @param assets Maximum underlying amount returned to Staking custody.
    /// @return returned On-contract underlying actually returned to Staking custody.
    function _onDeallocate(uint256 assets, bytes calldata) internal override returns (uint256 returned) {
        IERC20 token = IERC20(asset());
        uint256 balance = token.balanceOf(address(this));
        returned = balance > assets ? assets : balance;
        if (returned > 0) {
            _pushToCustody(returned);
        }
    }

    /// @dev Return any on-contract underlying above book principal to the Staking Diamond as profit.
    /// @return profit Excess underlying transferred to the Staking Diamond.
    function _onHarvest(bytes calldata) internal override returns (uint256 profit) {
        IERC20 token = IERC20(asset());
        uint256 balance = token.balanceOf(address(this));
        uint256 principal = principalAssets();

        if (balance <= principal) return 0;

        profit = balance - principal;
        token.safeTransfer(stakingDiamond, profit);
    }

    // Version-1 Manual state occupies one slot after SleeveBase; reserve the remainder of its 50-slot segment.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[49] private __gap;
}
