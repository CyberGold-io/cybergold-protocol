// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

import {ControllerBase} from "../src/facets/ControllerBase.sol";
import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";

contract CoreFeeMathHarness is ControllerBase {
    function grossForNet(uint256 netCygldAmount, uint256 feePpm)
        external
        pure
        returns (uint256 grossCygldAmount, uint256 protocolFeeCygld)
    {
        return _grossForNet(netCygldAmount, feePpm);
    }

    function splitFee(uint256 grossCygldAmount, uint256 feePpm)
        external
        pure
        returns (uint256 netCygldAmount, uint256 protocolFeeCygld)
    {
        return _splitFee(grossCygldAmount, feePpm);
    }
}

contract FeeMathTest is Test {
    uint256 private constant PPM_DENOMINATOR = 1_000_000;
    uint256 private constant MAX_PROTOCOL_FEE_PPM = 10_000;

    // Foundry JSON object tuples are ABI-encoded in alphabetical key order.
    struct SuccessVector {
        uint256 feePpm;
        uint256 grossCygldOut;
        string name;
        uint256 netCygldOut;
        uint256 protocolFeeCygld;
    }

    struct RevertVector {
        uint256 feePpm;
        string name;
        uint256 netCygldOut;
        string reason;
    }

    CoreFeeMathHarness private harness;

    function setUp() public {
        harness = new CoreFeeMathHarness();
    }

    function test_grossForNet_matchesSharedGoldenVectors() public view {
        string memory json = _fixture();
        assertEq(vm.parseJsonUint(json, ".schemaVersion"), 1);
        assertEq(vm.parseJsonUint(json, ".denominator"), PPM_DENOMINATOR);

        SuccessVector[] memory vectors = abi.decode(vm.parseJson(json, ".success"), (SuccessVector[]));
        for (uint256 i; i < vectors.length; ++i) {
            SuccessVector memory vector = vectors[i];
            (uint256 grossCygldOut, uint256 protocolFeeCygld) = harness.grossForNet(vector.netCygldOut, vector.feePpm);
            assertEq(grossCygldOut, vector.grossCygldOut, vector.name);
            assertEq(protocolFeeCygld, vector.protocolFeeCygld, vector.name);

            (uint256 splitNetCygldOut, uint256 splitProtocolFeeCygld) = harness.splitFee(grossCygldOut, vector.feePpm);
            assertEq(splitNetCygldOut, vector.netCygldOut, vector.name);
            assertEq(splitProtocolFeeCygld, vector.protocolFeeCygld, vector.name);
        }
    }

    function test_grossForNet_matchesSharedRevertVectors() public {
        RevertVector[] memory vectors = abi.decode(vm.parseJson(_fixture(), ".reverts"), (RevertVector[]));
        for (uint256 i; i < vectors.length; ++i) {
            RevertVector memory vector = vectors[i];
            bytes32 reason = keccak256(bytes(vector.reason));
            if (reason == keccak256("zero-net")) {
                vm.expectRevert(ICoreTypes.ValueMustBeGreaterThanZero.selector);
            } else {
                assertEq(reason, keccak256("gross-overflow"), vector.name);
                vm.expectRevert(
                    abi.encodeWithSelector(ICoreTypes.ExactNetGrossOverflow.selector, vector.netCygldOut, vector.feePpm)
                );
            }
            harness.grossForNet(vector.netCygldOut, vector.feePpm);
        }
    }

    function test_grossForNet_rejectsFeeAboveProtocolMaximum() public {
        vm.expectRevert(ICoreTypes.FeeTooHigh.selector);
        harness.grossForNet(1 ether, MAX_PROTOCOL_FEE_PPM + 1);
    }

    function test_splitFee_isFullPrecisionAtUint256Maximum() public view {
        (uint256 netCygldAmount, uint256 protocolFeeCygld) = harness.splitFee(type(uint256).max, MAX_PROTOCOL_FEE_PPM);
        uint256 expectedFee = Math.mulDiv(type(uint256).max, MAX_PROTOCOL_FEE_PPM, PPM_DENOMINATOR, Math.Rounding.Floor);
        assertEq(protocolFeeCygld, expectedFee);
        assertEq(netCygldAmount, type(uint256).max - expectedFee);
    }

    function test_grossForNet_maximumFeasibleNetAndNextUnit() public {
        uint256[3] memory fees = [uint256(1), uint256(1_000), uint256(MAX_PROTOCOL_FEE_PPM)];
        for (uint256 i; i < fees.length; ++i) {
            uint256 feePpm = fees[i];
            (uint256 maximumNetCygld,) = harness.splitFee(type(uint256).max, feePpm);
            (uint256 canonicalGrossCygld, uint256 protocolFeeCygld) = harness.grossForNet(maximumNetCygld, feePpm);
            assertLe(canonicalGrossCygld, type(uint256).max);
            assertEq(canonicalGrossCygld, maximumNetCygld + protocolFeeCygld);
            (uint256 splitNetCygld,) = harness.splitFee(canonicalGrossCygld, feePpm);
            assertEq(splitNetCygld, maximumNetCygld);

            vm.expectRevert(
                abi.encodeWithSelector(ICoreTypes.ExactNetGrossOverflow.selector, maximumNetCygld + 1, feePpm)
            );
            harness.grossForNet(maximumNetCygld + 1, feePpm);
        }
    }

    function testFuzz_grossForNet_preservesSplitAndIsMinimal(uint256 grossSeed, uint256 rawFeePpm) public view {
        uint256 grossCygldAmount = bound(grossSeed, 1, type(uint256).max);
        uint256 feePpm = bound(rawFeePpm, 0, MAX_PROTOCOL_FEE_PPM);
        (uint256 requestedNetCygld,) = harness.splitFee(grossCygldAmount, feePpm);

        (uint256 canonicalGrossCygld, uint256 protocolFeeCygld) = harness.grossForNet(requestedNetCygld, feePpm);
        assertLe(canonicalGrossCygld, grossCygldAmount);
        assertEq(protocolFeeCygld, canonicalGrossCygld - requestedNetCygld);

        (uint256 canonicalNetCygld, uint256 splitProtocolFeeCygld) = harness.splitFee(canonicalGrossCygld, feePpm);
        assertEq(canonicalNetCygld, requestedNetCygld);
        assertEq(splitProtocolFeeCygld, protocolFeeCygld);

        (uint256 precedingNetCygld,) = harness.splitFee(canonicalGrossCygld - 1, feePpm);
        assertLt(precedingNetCygld, requestedNetCygld);
    }

    function testFuzz_grossForNet_isMonotonicInNet(uint256 rawNetA, uint256 rawNetB, uint256 rawFeePpm) public view {
        uint256 feePpm = bound(rawFeePpm, 0, MAX_PROTOCOL_FEE_PPM);
        (uint256 maximumNetCygld,) = harness.splitFee(type(uint256).max, feePpm);
        uint256 netA = bound(rawNetA, 1, maximumNetCygld);
        uint256 netB = bound(rawNetB, netA, maximumNetCygld);

        (uint256 grossA,) = harness.grossForNet(netA, feePpm);
        (uint256 grossB,) = harness.grossForNet(netB, feePpm);
        assertLe(grossA, grossB);
    }

    function testFuzz_grossForNet_isMonotonicInFee(uint256 rawNet, uint256 rawFeeA, uint256 rawFeeB) public view {
        uint256 feeA = bound(rawFeeA, 0, MAX_PROTOCOL_FEE_PPM);
        uint256 feeB = bound(rawFeeB, 0, MAX_PROTOCOL_FEE_PPM);
        if (feeA > feeB) (feeA, feeB) = (feeB, feeA);

        (uint256 maximumNetCygld,) = harness.splitFee(type(uint256).max, feeB);
        uint256 netCygldAmount = bound(rawNet, 1, maximumNetCygld);
        (uint256 grossA,) = harness.grossForNet(netCygldAmount, feeA);
        (uint256 grossB,) = harness.grossForNet(netCygldAmount, feeB);
        assertLe(grossA, grossB);
    }

    function _fixture() private view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/gross-for-net-vectors.json"));
    }
}
