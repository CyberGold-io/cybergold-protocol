// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {CoreRecoveryPrecisionInit} from "../src/initializers/CoreRecoveryPrecisionInit.sol";
import {RecoveryPoolTestBase} from "./helpers/RecoveryPoolTestBase.t.sol";

contract CoreRecoveryPrecisionInitTest is RecoveryPoolTestBase {
    CoreRecoveryPrecisionInit private initializer;

    function setUp() public override {
        super.setUp();
        initializer = new CoreRecoveryPrecisionInit();
        _pauseCoreForTest();
    }

    function testExistingBasketUpgradeRetainsNativePrecisionBeforeUnreadableImpairment() public {
        _clearPrecision(address(tokA));
        _clearPrecision(address(tokB));
        bytes32 basketBefore = lens.basketConfigHash();
        uint256 supplyBefore = token.totalSupply();
        _initializePrecision();
        assertEq(lens.recoveryPool(address(tokA)).shareDecimals, 18);
        assertEq(lens.recoveryPool(address(tokB)).shareDecimals, 6);
        assertEq(lens.basketConfigHash(), basketBefore);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(lens.outstandingRecoveryAssetCount(), 0);
        assertEq(lens.coreAttachedRecoveryAssets().length, 0);
        tokB.mint(diamond, 1_000_000);
        vm.mockCallRevert(address(tokB), abi.encodeCall(IERC20Metadata.decimals, ()), "metadata unavailable");
        _activateRecovery(address(tokB));
        assertEq(lens.recoveryPool(address(tokB)).shareDecimals, 6);
        assertEq(lens.recoveryPool(address(tokB)).referenceShares, 1_000_000);
    }

    function testUnreadableRequiredPrecisionRevertsWithoutPartialInitialization() public {
        _clearPrecision(address(tokA));
        _clearPrecision(address(tokB));
        vm.mockCallRevert(address(tokB), abi.encodeCall(IERC20Metadata.decimals, ()), "metadata unavailable");
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketAssetDecimalsMissing.selector, address(tokB)));
        _initializePrecision();
        assertEq(vm.load(diamond, _precisionSlot(address(tokA))), bytes32(0));
        assertEq(vm.load(diamond, _precisionSlot(address(tokB))), bytes32(0));
    }

    function testExistingPrecisionIsNotOverwrittenOrReprobed() public {
        vm.mockCallRevert(address(tokA), abi.encodeCall(IERC20Metadata.decimals, ()), "metadata unavailable");
        vm.mockCallRevert(address(tokB), abi.encodeCall(IERC20Metadata.decimals, ()), "metadata unavailable");
        _initializePrecision();
        assertEq(lens.recoveryPool(address(tokA)).shareDecimals, 18);
        assertEq(lens.recoveryPool(address(tokB)).shareDecimals, 6);
    }

    function _initializePrecision() private {
        IDiamondCut(diamond)
            .diamondCut(
                new IDiamond.FacetCut[](0), address(initializer), abi.encodeCall(CoreRecoveryPrecisionInit.init, ())
            );
    }

    function _clearPrecision(address asset) private {
        vm.store(diamond, _precisionSlot(asset), bytes32(0));
    }

    function _precisionSlot(address asset) private pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(asset, uint256(LibRecoveryStorage.storageLocation()) + 1))) + 7);
    }
}
