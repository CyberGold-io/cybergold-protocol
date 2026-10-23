// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

/// @notice EIP-7201 storage for exact aggregate CYGLD allowance exposure.
library LibAllowanceExposureStorage {
    // keccak256(abi.encode(uint256(keccak256("cybergold.core.allowance-exposure.storage.v1")) - 1))
    //     & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_LOCATION = 0x82979c3c1ff6a584fe415ff8f61e419cd1bd9aff948add55b5e9cebc19114600;

    /// @dev Exact unsigned 512-bit sum of every current allowance for one owner.
    struct AllowanceSum {
        uint256 low;
        uint256 high;
    }

    /// @dev Exact wide aggregate allowance sums by owner.
    struct Layout {
        mapping(address owner => AllowanceSum sum) allowanceSums;
    }

    function getLayout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_LOCATION;
        assembly {
            l.slot := slot
        }
    }

    /// @notice Replace one allowance in the exact aggregate without overflow or loss of reversibility.
    function replaceAllowance(AllowanceSum storage sum, uint256 previousValue, uint256 newValue) internal {
        if (previousValue == newValue) return;
        _subtract(sum, previousValue);
        _add(sum, newValue);
    }

    function _add(AllowanceSum storage sum, uint256 value) private {
        if (value == 0) return;
        uint256 previousLow = sum.low;
        unchecked {
            sum.low = previousLow + value;
            if (sum.low < previousLow) ++sum.high;
        }
    }

    function _subtract(AllowanceSum storage sum, uint256 value) private {
        if (value == 0) return;
        uint256 previousLow = sum.low;
        unchecked {
            if (previousLow < value) --sum.high;
            sum.low = previousLow - value;
        }
    }
}
