// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {LibAppStorage} from "../diamond/LibAppStorage.sol";

/// @notice Canonical hashing for expected-current basket administration.
library LibBasketConfig {
    /// @notice Hash the basket arrays stored in Core controller storage.
    /// @param cs Core controller storage containing the current basket arrays.
    /// @return Canonical hash used by expected-current basket mutations.
    function hash(LibAppStorage.ControllerStorage storage cs) internal view returns (bytes32) {
        // ABI encoding is required to keep the hash identical to the memory-array overload.
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(cs.basketAssets, cs.basketTargetsPpm, cs.basketGoldRefGramsFp18));
    }

    /// @notice Hash proposed basket arrays using the same encoding as stored configuration.
    /// @param assets Ordered basket asset addresses.
    /// @param targetsPpm Target weights corresponding to `assets`, in parts per million.
    /// @param goldRefGramsFp18 Gold reference grams corresponding to `assets`, in fp18.
    /// @return Canonical hash used by expected-current basket mutations.
    function hash(address[] memory assets, uint256[] memory targetsPpm, uint256[] memory goldRefGramsFp18)
        internal
        pure
        returns (bytes32)
    {
        // ABI encoding is part of the canonical basket-hash format.
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(assets, targetsPpm, goldRefGramsFp18));
    }
}
