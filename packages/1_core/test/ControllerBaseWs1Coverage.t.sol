// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";

import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";
import {ControllerBase} from "../src/facets/ControllerBase.sol";
import {RedemptionControllerBase} from "../src/facets/RedemptionControllerBase.sol";
import {ICoreRedemption} from "../src/interfaces/ICoreRedemption.sol";
import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {LibReserveLifecycleStorage} from "../src/libraries/LibReserveLifecycleStorage.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

contract Ws1CoverageDecimalsToken {
    bool private _reverts;
    uint8 private _decimals = 18;

    function setReverts(bool value) external {
        _reverts = value;
    }

    function setDecimals(uint8 value) external {
        _decimals = value;
    }

    function decimals() external view returns (uint8) {
        require(!_reverts, "decimals unavailable");
        return _decimals;
    }
}

contract ControllerBaseWs1Harness is ControllerBase {
    uint256 private _supply;

    function totalSupply() external view returns (uint256) {
        return _supply;
    }

    function configure(uint256 cygldRefGramsFp18, address treasury) external {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        cs.cygldRefGramsFp18 = cygldRefGramsFp18;
        cs.treasury = treasury;
        cs.maxTotalSupply = type(uint256).max;
    }

    function setSupply(uint256 value) external {
        _supply = value;
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

    function setInitialBasket(address[] memory assets, uint256[] memory targets, uint256[] memory goldRefs) external {
        _setInitialBasket(LibAppStorage.appStorage().controller, assets, targets, goldRefs);
    }

    function setGenericBasket(address[] memory assets, uint256[] memory targets, uint256[] memory goldRefs) external {
        _setBasket(LibAppStorage.appStorage().controller, assets, targets, goldRefs);
    }

    function prepareActivation(
        address transitionAsset,
        IRecoveryTypes.ReserveLifecycle sourceLifecycle,
        address[] memory assets,
        uint256[] memory targets,
        uint256[] memory goldRefs
    ) external view returns (uint256[] memory) {
        return _prepareBasketForAssetActivation(
            LibAppStorage.appStorage().controller, transitionAsset, sourceLifecycle, assets, targets, goldRefs
        )
        .conversions;
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

    function computeConversions(address[] memory assets, uint256[] memory goldRefs, uint256 cygldRefGramsFp18)
        external
        view
        returns (uint256[] memory)
    {
        return _computeConversions(assets, goldRefs, cygldRefGramsFp18).conversions;
    }

    function loadIssueContext() external view returns (IssueContext memory) {
        return _loadIssueContext();
    }

    function solveIssueExactIn(IssueContext calldata context, uint256[] calldata maxAmountsIn)
        external
        pure
        returns (uint256)
    {
        return _solveIssueExactIn(context, maxAmountsIn);
    }
}

contract RedemptionControllerBaseWs2Harness is RedemptionControllerBase {
    uint256 private _supply;

    function initializeHarness() external initializer {
        __AccessControlEnumerable_init();
        __Pausable_init();
    }

    function totalSupply() external view returns (uint256) {
        return _supply;
    }

    function configureLoadContext(
        address treasury,
        uint256 supply,
        address[] calldata healthyAssets,
        uint256[] calldata conversions,
        address[] calldata recoveryAssets,
        uint256[] calldata attached
    ) external {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        delete cs.basketAssets;
        delete cs.basketCygldPerUnitFp18;
        cs.treasury = treasury;
        cs.redemptionFeePpm = 1_000;
        for (uint256 i; i < healthyAssets.length; ++i) {
            cs.basketAssets.push(healthyAssets[i]);
            cs.basketCygldPerUnitFp18.push(conversions[i]);
            LibReserveLifecycleStorage.getLayout().records[healthyAssets[i]].lifecycle =
            IRecoveryTypes.ReserveLifecycle.Active;
        }

        LibRecoveryStorage.Layout storage rs = LibRecoveryStorage.getLayout();
        delete rs.coreAttachedRecoveryAssets;
        for (uint256 i; i < recoveryAssets.length; ++i) {
            address asset = recoveryAssets[i];
            rs.coreAttachedRecoveryAssets.push(asset);
            rs.pools[asset].impaired = true;
            rs.pools[asset].coreAttachedShares = attached[i];
            rs.pools[asset].referenceShares = attached[i];
            rs.pools[asset].referenceValueCygld = attached[i];
        }
        _supply = supply;
    }

    function setFeeExempt(address account) external {
        _grantRole(REDEMPTION_FEE_EXEMPT_ROLE, account);
    }

    function loadConfig(address account) external view returns (MixedRedemptionConfig memory) {
        return _loadMixedRedemptionConfig(account);
    }

    function observe(MixedRedemptionConfig calldata config) external view returns (MixedRedemptionContext memory) {
        return _observeMixedRedemption(config);
    }

    function requireOutputs(MixedRedemptionConfig calldata config) external pure {
        _requireMixedRedemptionOutputs(config);
    }

    function calculate(MixedRedemptionContext calldata context, uint256 grossCygldIn)
        external
        pure
        returns (ICoreRedemption.RedemptionQuote memory)
    {
        return _calculateMixedRedeemExactIn(context, grossCygldIn);
    }

    function solve(MixedRedemptionContext calldata context, ICoreRedemption.TokenMinimum[] calldata minimumOutputs)
        external
        pure
        returns (ICoreRedemption.RedemptionQuote memory)
    {
        return _solveMixedRedeemExactOut(context, minimumOutputs);
    }

    function accumulate(uint256 current, uint256 minimum, uint256 available, uint256 denominator, bool recoveryOutput)
        external
        pure
        returns (uint256)
    {
        return _accumulateRequiredNet(current, minimum, available, denominator, recoveryOutput);
    }

    function zeroQuote(MixedRedemptionConfig calldata config)
        external
        pure
        returns (ICoreRedemption.RedemptionQuote memory)
    {
        return _zeroMixedRedemptionQuote(config);
    }

    function validateDescriptors(
        MixedRedemptionConfig calldata config,
        ICoreRedemption.TokenMinimum[] calldata minimumOutputs
    ) external pure {
        _validateMixedRedemptionDescriptors(config, minimumOutputs);
    }

    function validateMinima(
        ICoreRedemption.RedemptionQuote calldata quote,
        ICoreRedemption.TokenMinimum[] calldata minimumOutputs
    ) external pure {
        _validateMixedRedemptionMinima(quote, minimumOutputs);
    }

    function allZero(ICoreRedemption.TokenMinimum[] calldata minimumOutputs) external pure returns (bool) {
        return _allMixedMinimumsZero(minimumOutputs);
    }

    function hasOutput(ICoreRedemption.RedemptionQuote calldata quote) external pure returns (bool) {
        return _hasMixedRedemptionOutput(quote);
    }
}

contract ControllerBaseWs1CoverageTest is Test {
    ControllerBaseWs1Harness private harness;
    Ws1CoverageDecimalsToken private tokenA;
    Ws1CoverageDecimalsToken private tokenB;
    Ws1CoverageDecimalsToken private tokenC;

    function setUp() public {
        harness = new ControllerBaseWs1Harness();
        tokenA = new Ws1CoverageDecimalsToken();
        tokenB = new Ws1CoverageDecimalsToken();
        tokenC = new Ws1CoverageDecimalsToken();
        harness.configure(1e18, address(0xB0B));
    }

    function testInitialBasketRejectsZeroTarget() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTargetMismatch.selector,
                address(tokenA),
                IRecoveryTypes.ReserveLifecycle.Active,
                0
            )
        );
        harness.setInitialBasket(_addresses(address(tokenA)), _uints(0), _uints(1e18));
    }

    function testProjectedShapeAndPreviousMembershipGuards() public {
        ControllerBase.LifecycleBasketProjection memory projection =
            _projection(address(tokenA), IRecoveryTypes.ReserveLifecycle.Active, 0, false);
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketLengthMismatch.selector, 1, 0));
        harness.prepareProjected(projection, _addresses(address(tokenA)), new uint256[](0), _uints(1e18));

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketGoldRefLengthMismatch.selector, 1, 0));
        harness.prepareProjected(projection, _addresses(address(tokenA)), _uints(1_000_000), new uint256[](0));

        harness.setRawBasket(
            _addresses(address(tokenA), address(tokenB)),
            _uints(500_000, 500_000),
            _uints(1e18, 1e18),
            _uints(1e18, 1e18)
        );
        harness.setLifecycle(address(tokenB), IRecoveryTypes.ReserveLifecycle.Active);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTransitionInvalid.selector,
                address(tokenB),
                IRecoveryTypes.ReserveLifecycle.Active,
                IRecoveryTypes.ReserveLifecycle.Inactive
            )
        );
        harness.prepareProjected(projection, _addresses(address(tokenA)), _uints(1_000_000), _uints(1e18));
    }

    function testProjectedTransitionRetentionGuard() public {
        ControllerBase.LifecycleBasketProjection memory projection =
            _projection(address(tokenA), IRecoveryTypes.ReserveLifecycle.Inactive, 0, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTransitionInvalid.selector,
                address(tokenA),
                IRecoveryTypes.ReserveLifecycle.Inactive,
                IRecoveryTypes.ReserveLifecycle.Active
            )
        );
        harness.prepareProjected(projection, _addresses(address(tokenA)), _uints(1_000_000), _uints(1e18));
    }

    function testProjectedElementGuards() public {
        ControllerBase.LifecycleBasketProjection memory projection =
            _projection(address(tokenA), IRecoveryTypes.ReserveLifecycle.Active, 0, false);

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketZeroAsset.selector, 1));
        harness.prepareProjected(
            projection, _addresses(address(tokenA), address(0)), _uints(1_000_000, 0), _uints(1e18, 1e18)
        );

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketZeroGoldRef.selector, 0));
        harness.prepareProjected(projection, _addresses(address(tokenA)), _uints(1_000_000), _uints(0));

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketDuplicateAsset.selector, address(tokenA)));
        harness.prepareProjected(
            projection, _addresses(address(tokenA), address(tokenA)), _uints(500_000, 500_000), _uints(1e18, 1e18)
        );

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketWeightsMismatch.selector, 1, 1_000_000));
        harness.prepareProjected(projection, _addresses(address(tokenA)), _uints(1), _uints(1e18));

        projection.enforceMinimumPositiveTargets = true;
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketInsufficientPositiveTargets.selector, 1, 2));
        harness.prepareProjected(projection, _addresses(address(tokenA)), _uints(1_000_000), _uints(1e18));
    }

    function testProjectedActiveConversionGuards() public {
        ControllerBase.LifecycleBasketProjection memory projection =
            _projection(address(tokenA), IRecoveryTypes.ReserveLifecycle.Active, 0, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTargetMismatch.selector,
                address(tokenA),
                IRecoveryTypes.ReserveLifecycle.Active,
                0
            )
        );
        harness.prepareProjected(projection, _addresses(address(tokenA)), _uints(0), _uints(1e18));

        tokenA.setReverts(true);
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketAssetDecimalsMissing.selector, address(tokenA)));
        harness.prepareProjected(projection, _addresses(address(tokenA)), _uints(1_000_000), _uints(1e18));

        tokenA.setReverts(false);
        harness.configure(type(uint256).max, address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketZeroConversion.selector, 0));
        harness.prepareProjected(projection, _addresses(address(tokenA)), _uints(1_000_000), _uints(1));
    }

    function testProjectedExitingAndInactiveConversionGuards() public {
        ControllerBase.LifecycleBasketProjection memory projection =
            _projection(address(tokenA), IRecoveryTypes.ReserveLifecycle.Exiting, 1e18, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTargetMismatch.selector,
                address(tokenA),
                IRecoveryTypes.ReserveLifecycle.Exiting,
                1
            )
        );
        harness.prepareProjected(projection, _addresses(address(tokenA)), _uints(1), _uints(1e18));

        projection.transitionConversion = 0;
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.ReserveActivationStateInvalid.selector, address(tokenA)));
        harness.prepareProjected(projection, _addresses(address(tokenA)), _uints(0), _uints(1e18));

        harness.setRawBasket(_addresses(address(tokenB)), _uints(0), _uints(2e18), _uints(7e18));
        harness.setLifecycle(address(tokenB), IRecoveryTypes.ReserveLifecycle.Exiting);
        projection = _projection(address(tokenA), IRecoveryTypes.ReserveLifecycle.Inactive, 0, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTargetMismatch.selector,
                address(tokenB),
                IRecoveryTypes.ReserveLifecycle.Exiting,
                0
            )
        );
        harness.prepareProjected(projection, _addresses(address(tokenB)), _uints(0), _uints(3e18));

        harness.setLifecycle(address(tokenB), IRecoveryTypes.ReserveLifecycle.Inactive);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTargetMismatch.selector,
                address(tokenB),
                IRecoveryTypes.ReserveLifecycle.Inactive,
                0
            )
        );
        harness.prepareProjected(projection, _addresses(address(tokenB)), _uints(0), _uints(2e18));
    }

    function testProjectedRejectsFreshNonTransitionMember() public {
        harness.setRawBasket(_addresses(address(tokenA)), _uints(1_000_000), _uints(1e18), _uints(1e18));
        harness.setLifecycle(address(tokenA), IRecoveryTypes.ReserveLifecycle.Active);
        ControllerBase.LifecycleBasketProjection memory projection =
            _projection(address(tokenB), IRecoveryTypes.ReserveLifecycle.Active, 0, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTransitionInvalid.selector,
                address(tokenC),
                IRecoveryTypes.ReserveLifecycle.Inactive,
                IRecoveryTypes.ReserveLifecycle.Active
            )
        );
        harness.prepareProjected(
            projection,
            _addresses(address(tokenA), address(tokenB), address(tokenC)),
            _uints(300_000, 300_000, 400_000),
            _uints(1e18, 1e18, 1e18)
        );
    }

    function testGenericTransitionRejectsImpossibleFreshMemberFromCorruptDuplicateState() public {
        harness.setRawBasket(
            _addresses(address(tokenA), address(tokenA)),
            _uints(500_000, 500_000),
            _uints(1e18, 1e18),
            _uints(1e18, 1e18)
        );
        harness.setLifecycle(address(tokenA), IRecoveryTypes.ReserveLifecycle.Active);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTransitionInvalid.selector,
                address(tokenB),
                IRecoveryTypes.ReserveLifecycle.Inactive,
                IRecoveryTypes.ReserveLifecycle.Active
            )
        );
        harness.setGenericBasket(
            _addresses(address(tokenA), address(tokenB)), _uints(500_000, 500_000), _uints(1e18, 1e18)
        );
    }

    function testGenericTransitionRejectsExitingAndInactiveMemberMismatch() public {
        harness.setRawBasket(_addresses(address(tokenA)), _uints(0), _uints(1e18), _uints(1e18));
        harness.setLifecycle(address(tokenA), IRecoveryTypes.ReserveLifecycle.Exiting);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTargetMismatch.selector,
                address(tokenA),
                IRecoveryTypes.ReserveLifecycle.Exiting,
                1_000_000
            )
        );
        harness.setGenericBasket(_addresses(address(tokenA)), _uints(1_000_000), _uints(1e18));

        harness.setLifecycle(address(tokenA), IRecoveryTypes.ReserveLifecycle.Inactive);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTargetMismatch.selector,
                address(tokenA),
                IRecoveryTypes.ReserveLifecycle.Inactive,
                1_000_000
            )
        );
        harness.setGenericBasket(_addresses(address(tokenA)), _uints(1_000_000), _uints(1e18));
    }

    function testActivationTransitionValidationGuards() public {
        harness.setRawBasket(_addresses(address(tokenA)), _uints(1_000_000), _uints(1e18), _uints(1e18));
        harness.setLifecycle(address(tokenA), IRecoveryTypes.ReserveLifecycle.Active);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTransitionInvalid.selector,
                address(tokenA),
                IRecoveryTypes.ReserveLifecycle.Inactive,
                IRecoveryTypes.ReserveLifecycle.Active
            )
        );
        harness.prepareActivation(
            address(tokenA),
            IRecoveryTypes.ReserveLifecycle.Inactive,
            _addresses(address(tokenA)),
            _uints(1_000_000),
            _uints(1e18)
        );

        harness.setRawBasket(
            _addresses(address(tokenA), address(tokenB)), _uints(0, 1_000_000), _uints(1e18, 1e18), _uints(1e18, 1e18)
        );
        harness.setLifecycle(address(tokenA), IRecoveryTypes.ReserveLifecycle.Exiting);
        harness.setLifecycle(address(tokenB), IRecoveryTypes.ReserveLifecycle.Active);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTransitionInvalid.selector,
                address(tokenB),
                IRecoveryTypes.ReserveLifecycle.Active,
                IRecoveryTypes.ReserveLifecycle.Inactive
            )
        );
        harness.prepareActivation(
            address(tokenA),
            IRecoveryTypes.ReserveLifecycle.Exiting,
            _addresses(address(tokenA)),
            _uints(1_000_000),
            _uints(1e18)
        );
    }

    function testActivationCandidateAndMembershipGuards() public {
        harness.setRawBasket(new address[](0), new uint256[](0), new uint256[](0), new uint256[](0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTargetMismatch.selector,
                address(tokenA),
                IRecoveryTypes.ReserveLifecycle.Active,
                0
            )
        );
        harness.prepareActivation(
            address(tokenA),
            IRecoveryTypes.ReserveLifecycle.Inactive,
            _addresses(address(tokenA)),
            _uints(0),
            _uints(1e18)
        );

        harness.setRawBasket(_addresses(address(tokenA)), _uints(1_000_000), _uints(1e18), _uints(1e18));
        harness.setLifecycle(address(tokenA), IRecoveryTypes.ReserveLifecycle.Active);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryTypes.ReserveLifecycleTransitionInvalid.selector,
                address(tokenC),
                IRecoveryTypes.ReserveLifecycle.Inactive,
                IRecoveryTypes.ReserveLifecycle.Active
            )
        );
        harness.prepareActivation(
            address(tokenB),
            IRecoveryTypes.ReserveLifecycle.Inactive,
            _addresses(address(tokenA), address(tokenB), address(tokenC)),
            _uints(300_000, 300_000, 400_000),
            _uints(1e18, 1e18, 1e18)
        );

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketAssetNotFound.selector, address(tokenB)));
        harness.prepareActivation(
            address(tokenB),
            IRecoveryTypes.ReserveLifecycle.Inactive,
            _addresses(address(tokenA)),
            _uints(1_000_000),
            _uints(1e18)
        );
    }

    function testComputeConversionsDirectGuards() public {
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketZeroAsset.selector, 0));
        harness.computeConversions(_addresses(address(0)), _uints(1e18), 1e18);

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketZeroGoldRef.selector, 0));
        harness.computeConversions(_addresses(address(tokenA)), _uints(0), 1e18);

        tokenA.setReverts(true);
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketAssetDecimalsMissing.selector, address(tokenA)));
        harness.computeConversions(_addresses(address(tokenA)), _uints(1e18), 1e18);

        tokenA.setReverts(false);
        harness.setLifecycle(address(tokenA), IRecoveryTypes.ReserveLifecycle.Exiting);
        harness.setRawBasket(new address[](0), new uint256[](0), new uint256[](0), new uint256[](0));
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.ReserveActivationStateInvalid.selector, address(tokenA)));
        harness.computeConversions(_addresses(address(tokenA)), _uints(1e18), 1e18);
    }

    function testActivationConversionsUseFrozenOtherAndRejectCorruptOrUnreadableState() public {
        harness.setRawBasket(_addresses(address(tokenA)), _uints(0), _uints(1e18), _uints(7e18));
        harness.setLifecycle(address(tokenA), IRecoveryTypes.ReserveLifecycle.Exiting);
        uint256[] memory conversions = harness.prepareActivation(
            address(tokenB),
            IRecoveryTypes.ReserveLifecycle.Inactive,
            _addresses(address(tokenA), address(tokenB)),
            _uints(0, 1_000_000),
            _uints(1e18, 1e18)
        );
        assertEq(conversions[0], 7e18);

        harness.setRawBasket(_addresses(address(tokenA)), _uints(0), _uints(1e18), new uint256[](0));
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.ReserveActivationStateInvalid.selector, address(tokenA)));
        harness.prepareActivation(
            address(tokenB),
            IRecoveryTypes.ReserveLifecycle.Inactive,
            _addresses(address(tokenA), address(tokenB)),
            _uints(0, 1_000_000),
            _uints(1e18, 1e18)
        );

        harness.setRawBasket(new address[](0), new uint256[](0), new uint256[](0), new uint256[](0));
        tokenB.setReverts(true);
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketAssetDecimalsMissing.selector, address(tokenB)));
        harness.prepareActivation(
            address(tokenB),
            IRecoveryTypes.ReserveLifecycle.Inactive,
            _addresses(address(tokenB)),
            _uints(1_000_000),
            _uints(1e18)
        );

        tokenB.setReverts(false);
        harness.configure(type(uint256).max, address(0xB0B));
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketZeroConversion.selector, 0));
        harness.prepareActivation(
            address(tokenB),
            IRecoveryTypes.ReserveLifecycle.Inactive,
            _addresses(address(tokenB)),
            _uints(1_000_000),
            _uints(1)
        );
    }

    function testLoadIssueContextRejectsAllZeroTargetsAfterBoundedScan() public {
        harness.setRawBasket(
            _addresses(address(tokenA), address(tokenB)), _uints(0, 0), _uints(1e18, 1e18), _uints(1e18, 1e18)
        );
        vm.expectRevert(ICoreTypes.BasketNotConfigured.selector);
        harness.loadIssueContext();
    }

    function testSolveIssueExactInUsesTighterCurrentRecoveryCap() public view {
        ControllerBase.IssueContext memory context;
        context.maxTotalSupply = 100;
        context.effectiveCygldSupplyCap = 20;
        context.supply = 10;
        context.orderedBasketAssets = _addresses(address(tokenA));
        context.targetsPpm = _uints(1_000_000);
        context.cygldPerUnitFp18 = _uints(1e18);

        assertEq(harness.solveIssueExactIn(context, _uints(100)), 10);
    }

    function _projection(
        address transitionAsset,
        IRecoveryTypes.ReserveLifecycle lifecycle,
        uint256 transitionConversion,
        bool enforceMinimumPositiveTargets
    ) private pure returns (ControllerBase.LifecycleBasketProjection memory projection) {
        projection = ControllerBase.LifecycleBasketProjection({
            transitionAsset: transitionAsset,
            lifecycle: lifecycle,
            transitionConversion: transitionConversion,
            economicRecoveryCount: 0,
            enforceMinimumPositiveTargets: enforceMinimumPositiveTargets
        });
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

    function _addresses(address a, address b, address c) private pure returns (address[] memory values) {
        values = new address[](3);
        values[0] = a;
        values[1] = b;
        values[2] = c;
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

    function _uints(uint256 a, uint256 b, uint256 c) private pure returns (uint256[] memory values) {
        values = new uint256[](3);
        values[0] = a;
        values[1] = b;
        values[2] = c;
    }
}

contract RedemptionControllerBaseWs2CoverageTest is Test {
    RedemptionControllerBaseWs2Harness private harness;
    MockERC20 private healthy;

    address private constant RECOVERY = address(0x2222);

    function setUp() public {
        harness = new RedemptionControllerBaseWs2Harness();
        harness.initializeHarness();
        healthy = new MockERC20("Healthy", "HLT", 18);
    }

    function testLoadConfigAndStructuralOutputBranches() public {
        address[] memory none = new address[](0);
        uint256[] memory noValues = new uint256[](0);
        harness.configureLoadContext(address(0), 10, none, noValues, _oneAddress(RECOVERY), _oneUint(5));
        vm.expectRevert(ICoreTypes.TreasuryNotSet.selector);
        harness.loadConfig(address(this));

        harness.configureLoadContext(address(0xB0B), 10, none, noValues, _oneAddress(RECOVERY), _oneUint(5));
        RedemptionControllerBase.MixedRedemptionConfig memory config = harness.loadConfig(address(this));
        assertEq(config.effectiveFeePpm, 1_000);
        assertEq(config.coreAttachedShares[0], 5);
        harness.requireOutputs(config);

        harness.setFeeExempt(address(this));
        config = harness.loadConfig(address(this));
        assertEq(config.effectiveFeePpm, 0);

        harness.configureLoadContext(address(0xB0B), 10, none, noValues, none, noValues);
        config = harness.loadConfig(address(this));
        vm.expectRevert(ICoreTypes.BasketNotConfigured.selector);
        harness.requireOutputs(config);
    }

    function testLoadContextCountsZeroAndPositiveHealthyCustody() public {
        healthy.mint(address(harness), 7);
        harness.configureLoadContext(
            address(0xB0B),
            5,
            _addresses(address(healthy), address(0x3333)),
            _uints(1e18, 1e18),
            _oneAddress(RECOVERY),
            _oneUint(3)
        );
        RedemptionControllerBase.MixedRedemptionContext memory context =
            harness.observe(harness.loadConfig(address(this)));
        assertEq(context.availableAmounts[0], 7);
        assertEq(context.availableAmounts[1], 0);
        assertEq(context.availableAmounts[2], 3);
        assertEq(context.denominator, 10);
    }

    function testExactInAllGuardAndOutputBranches() public {
        RedemptionControllerBase.MixedRedemptionContext memory context = _context(10, 10, 1, 1);
        vm.expectRevert(ICoreTypes.ValueMustBeGreaterThanZero.selector);
        harness.calculate(context, 0);
        vm.expectRevert(ICoreTypes.InsufficientCygldSupply.selector);
        harness.calculate(context, 11);

        context.denominator = 100;
        ICoreRedemption.RedemptionQuote memory quote = harness.calculate(context, 1);
        assertFalse(harness.hasOutput(quote));

        context.denominator = 1;
        quote = harness.calculate(context, 1);
        assertEq(quote.outputs[0].amount, 1);
        assertEq(quote.outputs[1].amount, 1);

        context.availableAmounts[0] = 0;
        quote = harness.calculate(context, 1);
        assertEq(quote.outputs[0].amount, 0);
        assertEq(quote.outputs[1].amount, 1);
    }

    function testExactOutZeroSupplyAndSuccessBranches() public {
        RedemptionControllerBase.MixedRedemptionContext memory context = _context(10, 10, 10, 10);
        ICoreRedemption.TokenMinimum[] memory minima = _minimums(0, 0);
        ICoreRedemption.RedemptionQuote memory zeroQuote = harness.zeroQuote(context.config);
        assertEq(zeroQuote.grossCygldIn, 0);
        assertEq(zeroQuote.outputs.length, 2);
        assertTrue(harness.allZero(minima));

        context.config.supply = 1;
        context.denominator = 2;
        context.availableAmounts[0] = 1;
        minima = _minimums(1, 0);
        vm.expectRevert(ICoreTypes.InsufficientCygldSupply.selector);
        harness.solve(context, minima);

        context = _context(10, 10, 10, 10);
        minima = _minimums(3, 4);
        assertFalse(harness.allZero(minima));
        ICoreRedemption.RedemptionQuote memory quote = harness.solve(context, minima);
        assertEq(quote.grossCygldIn, 4);
        assertGe(quote.outputs[0].amount, 3);
        assertGe(quote.outputs[1].amount, 4);
    }

    function testAccumulateAllBranches() public view {
        assertEq(harness.accumulate(7, 0, 0, 0, false), 7);
        assertEq(harness.accumulate(7, 0, 0, 0, true), 7);
        assertEq(harness.accumulate(7, 2, 10, 10, false), 7);
        assertEq(harness.accumulate(1, 2, 10, 10, false), 2);
    }

    function testExactOutClassifiesMixedAvailabilityShortages() public {
        RedemptionControllerBase.MixedRedemptionContext memory context = _context(100, 100, 10, 20);
        vm.expectRevert(ICoreTypes.InsufficientReserveBalance.selector);
        harness.solve(context, _minimums(11, 21));

        vm.expectRevert(ICoreTypes.InsufficientRecoveryShares.selector);
        harness.solve(context, _minimums(0, 21));

        context.availableAmounts[0] = 0;
        vm.expectRevert(ICoreTypes.InsufficientReserveBalance.selector);
        harness.solve(context, _minimums(1, 0));
    }

    function testExactOutClassifiesEveryLegWithoutAnErc20Prefix() public {
        RedemptionControllerBase.MixedRedemptionContext memory context = _context(100, 100, 10, 20);
        context.config.orderedBasketAssets = new address[](0);
        context.config.cygldPerUnitFp18 = new uint256[](0);
        context.config.orderedRecoveryAssets = _addresses(RECOVERY, address(0x3333));
        context.config.coreAttachedShares = _uints(10, 20);
        ICoreRedemption.TokenMinimum[] memory minima = _minimums(11, 0);
        minima[0].kind = ICoreRedemption.TokenKind.ERC1155;
        minima[0].token = address(harness);
        minima[0].id = uint256(uint160(RECOVERY));
        minima[1].id = uint256(uint160(address(0x3333)));

        vm.expectRevert(ICoreTypes.InsufficientRecoveryShares.selector);
        harness.solve(context, minima);

        minima[0].minimumAmount = 0;
        minima[1].minimumAmount = 21;
        vm.expectRevert(ICoreTypes.InsufficientRecoveryShares.selector);
        harness.solve(context, minima);
    }

    function testExactAvailabilityIsAllowedBeforeGrossSupplyAndFeeBounds() public {
        RedemptionControllerBase.MixedRedemptionContext memory context = _context(100, 100, 100, 100);
        ICoreRedemption.RedemptionQuote memory quote = harness.solve(context, _minimums(100, 100));
        assertEq(quote.grossCygldIn, 100);
        assertEq(quote.outputs[0].amount, 100);
        assertEq(quote.outputs[1].amount, 100);
        assertEq(harness.calculate(context, 100).grossCygldIn, 100);

        context.config.effectiveFeePpm = 10_000;
        vm.expectRevert(ICoreTypes.InsufficientCygldSupply.selector);
        harness.solve(context, _minimums(100, 100));
    }

    function testAccumulateRejectsUnavailableAndExcessMinimum() public {
        vm.expectRevert(ICoreTypes.InsufficientReserveBalance.selector);
        harness.accumulate(0, 1, 0, 1, false);
        vm.expectRevert(ICoreTypes.InsufficientReserveBalance.selector);
        harness.accumulate(0, 2, 1, 1, false);
        vm.expectRevert(ICoreTypes.InsufficientRecoveryShares.selector);
        harness.accumulate(0, 1, 0, 1, true);
        vm.expectRevert(ICoreTypes.InsufficientRecoveryShares.selector);
        harness.accumulate(0, 2, 1, 1, true);
    }

    function testDescriptorValidationEveryGuardAndSuccess() public {
        RedemptionControllerBase.MixedRedemptionConfig memory config = _context(10, 10, 10, 10).config;
        ICoreRedemption.TokenMinimum[] memory minima = new ICoreRedemption.TokenMinimum[](0);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreRedemption.RedemptionOutputsLengthMismatch.selector, uint256(0), uint256(2))
        );
        harness.validateDescriptors(config, minima);

        minima = _minimums(3, 4);
        minima[0].token = address(0xDEAD);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreRedemption.RedemptionOutputDescriptorMismatch.selector,
                uint256(0),
                ICoreRedemption.TokenKind.ERC20,
                address(0xDEAD),
                uint256(0),
                ICoreRedemption.TokenKind.ERC20,
                address(healthy),
                uint256(0)
            )
        );
        harness.validateDescriptors(config, minima);

        minima = _minimums(3, 4);
        minima[1].kind = ICoreRedemption.TokenKind.ERC20;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreRedemption.RedemptionOutputDescriptorMismatch.selector,
                uint256(1),
                ICoreRedemption.TokenKind.ERC20,
                address(harness),
                uint256(uint160(RECOVERY)),
                ICoreRedemption.TokenKind.ERC1155,
                address(harness),
                uint256(uint160(RECOVERY))
            )
        );
        harness.validateDescriptors(config, minima);

        minima = _minimums(3, 4);
        minima[1].id = 99;
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreRedemption.RedemptionOutputDescriptorMismatch.selector,
                uint256(1),
                ICoreRedemption.TokenKind.ERC1155,
                address(harness),
                uint256(99),
                ICoreRedemption.TokenKind.ERC1155,
                address(harness),
                uint256(uint160(RECOVERY))
            )
        );
        harness.validateDescriptors(config, minima);

        harness.validateDescriptors(config, _minimums(3, 4));
    }

    function testMinimaAndHasOutputBranches() public {
        ICoreRedemption.RedemptionQuote memory quote = _quote();
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreRedemption.RedemptionOutputBelowMinimum.selector, uint256(0), uint256(4), uint256(3)
            )
        );
        harness.validateMinima(quote, _minimums(4, 4));
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreRedemption.RedemptionOutputBelowMinimum.selector, uint256(1), uint256(5), uint256(4)
            )
        );
        harness.validateMinima(quote, _minimums(3, 5));
        harness.validateMinima(quote, _minimums(3, 4));

        assertTrue(harness.hasOutput(quote));
        quote.outputs[0].amount = 0;
        assertTrue(harness.hasOutput(quote));
        quote.outputs[1].amount = 0;
        assertFalse(harness.hasOutput(quote));
    }

    function _context(uint256 supply, uint256 denominator, uint256 healthyBalance, uint256 recoveryShares)
        private
        view
        returns (RedemptionControllerBase.MixedRedemptionContext memory context)
    {
        context.config.reserveAddr = address(harness);
        context.config.treasuryAddr = address(0xB0B);
        context.config.supply = supply;
        context.config.orderedBasketAssets = _oneAddress(address(healthy));
        context.config.cygldPerUnitFp18 = _oneUint(1e18);
        context.config.orderedRecoveryAssets = _oneAddress(RECOVERY);
        context.config.coreAttachedShares = _oneUint(recoveryShares);
        context.denominator = denominator;
        context.availableAmounts = _uints(healthyBalance, recoveryShares);
    }

    function _quote() private view returns (ICoreRedemption.RedemptionQuote memory quote) {
        quote.outputs = new ICoreRedemption.TokenAmount[](2);
        quote.outputs[0] = ICoreRedemption.TokenAmount({
            kind: ICoreRedemption.TokenKind.ERC20, token: address(healthy), id: 0, amount: 3
        });
        quote.outputs[1] = ICoreRedemption.TokenAmount({
            kind: ICoreRedemption.TokenKind.ERC1155, token: address(harness), id: uint256(uint160(RECOVERY)), amount: 4
        });
    }

    function _minimums(uint256 healthyMinimum, uint256 recoveryMinimum)
        private
        view
        returns (ICoreRedemption.TokenMinimum[] memory minima)
    {
        minima = new ICoreRedemption.TokenMinimum[](2);
        minima[0] = ICoreRedemption.TokenMinimum({
            kind: ICoreRedemption.TokenKind.ERC20, token: address(healthy), id: 0, minimumAmount: healthyMinimum
        });
        minima[1] = ICoreRedemption.TokenMinimum({
            kind: ICoreRedemption.TokenKind.ERC1155,
            token: address(harness),
            id: uint256(uint160(RECOVERY)),
            minimumAmount: recoveryMinimum
        });
    }

    function _oneAddress(address value) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _addresses(address a, address b) private pure returns (address[] memory values) {
        values = new address[](2);
        values[0] = a;
        values[1] = b;
    }

    function _oneUint(uint256 value) private pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function _uints(uint256 a, uint256 b) private pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = a;
        values[1] = b;
    }
}
