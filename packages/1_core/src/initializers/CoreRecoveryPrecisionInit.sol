// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {ICoreTypes} from "../interfaces/ICoreTypes.sol";
import {LibRecoveryStorage} from "../libraries/LibRecoveryStorage.sol";

/// @notice Upgrade-only initialization of retained precision for an already-configured Core basket.
/// @dev Execute by delegatecall in the authorized upgrade initializer, never install as a facet.
///      This writes only appended metadata fields; it does not create, convert or enumerate claims.
contract CoreRecoveryPrecisionInit {
    /// @notice Retain missing native decimals before the new impairment selectors become usable.
    /// @dev The existing bounded basket is canonical. Capture all required metadata before writing;
    ///      do not infer precision from conversions, particularly frozen Exiting conversions.
    function init() external {
        address[] memory assets = LibAppStorage.appStorage().controller.basketAssets;
        uint8[] memory decimals = new uint8[](assets.length);
        bool[] memory missing = new bool[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            if (LibRecoveryStorage.getLayout().pools[assets[i]].decimalsKnown) continue;
            missing[i] = true;
            try IERC20Metadata(assets[i]).decimals() returns (uint8 value) {
                decimals[i] = value;
            } catch {
                revert ICoreTypes.BasketAssetDecimalsMissing(assets[i]);
            }
        }
        for (uint256 i; i < assets.length; ++i) {
            if (!missing[i]) continue;
            LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[assets[i]];
            pool.shareDecimals = decimals[i];
            pool.decimalsKnown = true;
        }
    }
}
