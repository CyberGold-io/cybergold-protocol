// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";

import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";
import {ControllerBase} from "../src/facets/ControllerBase.sol";
import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {LibReserveLifecycleStorage} from "../src/libraries/LibReserveLifecycleStorage.sol";

contract MutableDecimalsToken {
    bool internal _reverts;

    function setReverts(bool value) external {
        _reverts = value;
    }

    function decimals() external view returns (uint8) {
        require(!_reverts, "no decimals");
        return 18;
    }
}

contract ControllerBaseLifecycleHarness is ControllerBase {
    uint256 public totalSupply;

    function configure(uint256 maxSupply) external {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        cs.treasury = address(0xB0B);
        cs.cygldRefGramsFp18 = 1e18;
        cs.maxTotalSupply = maxSupply;
    }

    function setRawBasket(
        address[] memory assets,
        uint256[] memory targets,
        uint256[] memory goldRefs,
        uint256[] memory conversions
    ) external {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        delete cs.basketAssets;
        delete cs.basketTargetsPpm;
        delete cs.basketGoldRefGramsFp18;
        delete cs.basketCygldPerUnitFp18;
        for (uint256 i; i < assets.length; ++i) {
            cs.basketAssets.push(assets[i]);
        }
        for (uint256 i; i < targets.length; ++i) {
            cs.basketTargetsPpm.push(targets[i]);
        }
        for (uint256 i; i < goldRefs.length; ++i) {
            cs.basketGoldRefGramsFp18.push(goldRefs[i]);
        }
        for (uint256 i; i < conversions.length; ++i) {
            cs.basketCygldPerUnitFp18.push(conversions[i]);
        }
    }

    function setLifecycle(address asset, IRecoveryTypes.ReserveLifecycle lifecycle) external {
        LibReserveLifecycleStorage.getLayout().records[asset].lifecycle = lifecycle;
    }

    function setEconomicCount(uint256 count) external {
        LibRecoveryStorage.Layout storage rs = LibRecoveryStorage.getLayout();
        delete rs.coreAttachedRecoveryAssets;
        for (uint256 i; i < count; ++i) {
            // Test callers keep `count` small, so `0x1000 + i` fits in 160 bits.
            // forge-lint: disable-next-line(unsafe-typecast)
            rs.coreAttachedRecoveryAssets.push(address(uint160(0x1000 + i)));
        }
    }

    function setInitialBasket(address[] memory assets, uint256[] memory targets, uint256[] memory goldRefs) external {
        _setInitialBasket(LibAppStorage.appStorage().controller, assets, targets, goldRefs);
    }

    function setGenericBasket(address[] memory assets, uint256[] memory targets, uint256[] memory goldRefs) external {
        _setBasket(LibAppStorage.appStorage().controller, assets, targets, goldRefs);
    }

    function prepareProjected(
        LifecycleBasketProjection memory projection,
        address[] memory assets,
        uint256[] memory targets,
        uint256[] memory goldRefs
    ) external view returns (uint256[] memory) {
        return _prepareLifecycleTransitionBasket(
            LibAppStorage.appStorage().controller, projection, assets, targets, goldRefs
        )
        .conversions;
    }
}

contract ControllerBaseLifecycleCoverageTest is Test {
    ControllerBaseLifecycleHarness internal harness;
    MutableDecimalsToken internal tokenA;
    MutableDecimalsToken internal tokenB;

    function setUp() public {
        harness = new ControllerBaseLifecycleHarness();
        tokenA = new MutableDecimalsToken();
        tokenB = new MutableDecimalsToken();
        harness.configure(1_000 ether);
    }

    function test_initialBasketUsesBoundedArrayValidation() public {
        harness.setEconomicCount(62);
        harness.setInitialBasket(
            _addresses(address(tokenA), address(tokenB)), _uints(500_000, 500_000), _uints(1e18, 1e18)
        );

        harness = new ControllerBaseLifecycleHarness();
        harness.configure(1_000 ether);
        harness.setEconomicCount(63);
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.CombinedAssetLimitExceeded.selector, 2, 63, 64));
        harness.setInitialBasket(
            _addresses(address(tokenA), address(tokenB)), _uints(500_000, 500_000), _uints(1e18, 1e18)
        );
    }

    function test_genericBasketRejectsMembershipChangeWithoutLifecycleTransition() public {
        harness.setLifecycle(address(tokenA), IRecoveryTypes.ReserveLifecycle.Active);
        harness.setRawBasket(_addresses(address(tokenA)), _uints(1_000_000), _uints(1e18), _uints(1e18));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTransitionInvalid.selector,
                address(tokenA),
                IRecoveryTypes.ReserveLifecycle.Active,
                IRecoveryTypes.ReserveLifecycle.Inactive
            )
        );
        harness.setGenericBasket(_addresses(address(tokenB)), _uints(1_000_000), _uints(1e18));
    }

    function test_projectedExitPreservesFrozenConversionWithoutMetadataProbe() public {
        harness.setLifecycle(address(tokenA), IRecoveryTypes.ReserveLifecycle.Active);
        harness.setRawBasket(_addresses(address(tokenA)), _uints(1_000_000), _uints(2e18), _uints(7e18));
        tokenA.setReverts(true);

        ControllerBase.LifecycleBasketProjection memory projection = ControllerBase.LifecycleBasketProjection({
            transitionAsset: address(tokenA),
            lifecycle: IRecoveryTypes.ReserveLifecycle.Exiting,
            transitionConversion: 0,
            economicRecoveryCount: 0,
            enforceMinimumPositiveTargets: false
        });
        uint256[] memory conversions =
            harness.prepareProjected(projection, _addresses(address(tokenA)), _uints(0), _uints(2e18));
        assertEq(conversions[0], 7e18);
    }

    function test_projectedResolutionUsesExplicitFrozenConversion() public {
        harness.setLifecycle(address(tokenA), IRecoveryTypes.ReserveLifecycle.Inactive);
        ControllerBase.LifecycleBasketProjection memory projection = ControllerBase.LifecycleBasketProjection({
            transitionAsset: address(tokenA),
            lifecycle: IRecoveryTypes.ReserveLifecycle.Exiting,
            transitionConversion: 9e18,
            economicRecoveryCount: 0,
            enforceMinimumPositiveTargets: false
        });
        uint256[] memory conversions =
            harness.prepareProjected(projection, _addresses(address(tokenA)), _uints(0), _uints(3e18));
        assertEq(conversions[0], 9e18);
    }

    function _addresses(address a) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = a;
    }

    function _addresses(address a, address b) private pure returns (address[] memory values) {
        values = new address[](2);
        values[0] = a;
        values[1] = b;
    }

    function _uints(uint256 a) private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = a;
    }

    function _uints(uint256 a, uint256 b) private pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = a;
        values[1] = b;
    }
}
