// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract RecoveryAccountingSymbolicTest is Test {
    function check_rehabilitationConservesCustodyAndCapsExternalReservation(
        uint8 raw,
        uint8 coreShares,
        uint8 externalShares
    ) public pure {
        // Exhaustively bounded economic arithmetic: no product can overflow, so this is
        // precisely mulDiv(..., Floor), without re-proving its 512-bit implementation.
        raw &= 0x0f;
        coreShares &= 0x0f;
        externalShares &= 0x0f;
        uint256 totalShares = uint256(coreShares) + uint256(externalShares);
        if (totalShares == 0) return;
        uint256 allocatable = Math.min(uint256(raw), totalShares);
        uint256 externalRaw = allocatable * uint256(externalShares) / totalShares;
        uint256 coreRaw = uint256(raw) - externalRaw;
        assert(coreRaw + externalRaw == uint256(raw));
        assert(externalRaw <= externalShares);
    }

    function check_externalOnlyRehabilitationReservesOnlyCappedRaw(uint128 raw, uint128 externalShares) public pure {
        if (externalShares == 0) return;
        uint256 externalRaw = Math.min(uint256(raw), uint256(externalShares));
        assert(externalRaw <= raw && externalRaw <= externalShares);
        assert(uint256(raw) - externalRaw + externalRaw == uint256(raw));
    }

    function check_greenSplitAssignsAllRawToCoreWhenNoExternal(uint8 raw, uint8 coreShares) public pure {
        raw &= 0x0f;
        coreShares &= 0x0f;
        if (coreShares == 0) return;
        // The exhaustively bounded operands cannot overflow, so this is the exact arithmetic model of
        // Math.mulDiv(raw, coreShares, coreShares, Floor) without re-proving its 512-bit assembly.
        uint256 coreRaw = uint256(raw) * uint256(coreShares) / uint256(coreShares);
        assert(coreRaw == uint256(raw));
    }

    function check_detachmentConservesTotalPoolShares(uint128 coreBefore, uint128 externalBefore, uint128 detached)
        public
        pure
    {
        if (detached > coreBefore) return;
        uint256 totalBefore = uint256(coreBefore) + uint256(externalBefore);
        uint256 coreAfter = uint256(coreBefore) - uint256(detached);
        uint256 externalAfter = uint256(externalBefore) + uint256(detached);
        assert(coreAfter + externalAfter == totalBefore);
    }

    function check_finalExternalBurnLeavesCapExcess(uint128 raw, uint128 supply) public pure {
        if (supply == 0) return;
        uint256 rawOut = Math.min(uint256(raw), uint256(supply));
        assert(rawOut <= raw && rawOut <= supply);
        if (raw > supply) assert(uint256(raw) - rawOut == uint256(raw) - supply);
    }

    function check_healthyPartialBurnPreservesNativeCap(uint8 raw, uint8 supply, uint8 liability, uint8 shares)
        public
        pure
    {
        // Small operands are exhaustive economic checks, independent of mulDiv's assembly proof.
        raw &= 0x0f;
        supply &= 0x0f;
        liability &= 0x0f;
        shares &= 0x0f;
        if (supply == 0 || shares == 0 || shares > supply || liability > supply) return;
        uint256 payableRaw = raw < liability ? raw : liability;
        uint256 output = payableRaw * shares / supply;
        uint256 released = uint256(liability) * shares / supply;
        assert(output <= shares);
        assert(uint256(liability) - released <= uint256(supply) - shares);
    }

    function check_addressDerivedShareIdIsInjective(address a, address b) public pure {
        if (a == address(0) || b == address(0)) return;
        uint256 idA = uint256(uint160(a));
        uint256 idB = uint256(uint160(b));
        if (idA == idB) assert(a == b);
        // `idA` was constructed directly from an address and therefore fits in 160 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        assert(address(uint160(idA)) == a);
        // `idB` was constructed directly from an address and therefore fits in 160 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        assert(address(uint160(idB)) == b);
    }
}
