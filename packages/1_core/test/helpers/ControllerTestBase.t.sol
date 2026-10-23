// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";

import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";
import {BasketAdminFacet} from "../../src/facets/BasketAdminFacet.sol";
import {ControllerConfigFacet} from "../../src/facets/ControllerConfigFacet.sol";
import {IssuanceFacet} from "../../src/facets/IssuanceFacet.sol";
import {LensFacet} from "../../src/facets/LensFacet.sol";
import {PreviewFacet} from "../../src/facets/PreviewFacet.sol";
import {RebalanceFacet} from "../../src/facets/RebalanceFacet.sol";
import {RedemptionFacet} from "../../src/facets/RedemptionFacet.sol";
import {ReserveLifecycleFacet} from "../../src/facets/ReserveLifecycleFacet.sol";
import {TokenFacet} from "../../src/facets/TokenFacet.sol";
import {ICoreRedemption} from "../../src/interfaces/ICoreRedemption.sol";
import {IRecoveryTypes} from "../../src/interfaces/IRecoveryTypes.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";

abstract contract ControllerTestBase is Test {
    IssuanceFacet internal issuance;
    RedemptionFacet internal redemption;
    RebalanceFacet internal rebalance;
    ReserveLifecycleFacet internal testReserveLifecycle;
    LensFacet internal testRecoveryLens;
    PreviewFacet internal preview;
    BasketAdminFacet internal basketAdmin;
    ControllerConfigFacet internal config;
    LensFacet internal lens;
    TokenFacet internal token;
    address internal diamond;

    address internal reserve;
    MockERC20 internal tokA;
    MockERC20 internal tokB;

    address internal admin = address(this);
    address internal pauser = address(0xBEEF);
    address internal treasury = address(0xB0B);
    address internal user = address(0xABCD);

    uint256 internal constant CYGLD_REF_GRAMS_FP18 = 1e18;
    uint256 internal constant A_GOLD_REF_GRAMS_FP18 = 100 * 1e18;
    uint256 internal constant B_GOLD_REF_GRAMS_FP18 = 50 * 1e18;
    uint256 internal constant INITIAL_MAX_TOTAL_SUPPLY = 250 ether;

    function setUp() public virtual {
        tokA = new MockERC20("Gold A", "GLDA", 18);
        tokB = new MockERC20("Gold B", "GLDB", 6);

        address[] memory assets = new address[](2);
        assets[0] = address(tokA);
        assets[1] = address(tokB);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 600_000;
        weights[1] = 400_000;
        uint256[] memory goldRefs = new uint256[](2);
        goldRefs[0] = A_GOLD_REF_GRAMS_FP18;
        goldRefs[1] = B_GOLD_REF_GRAMS_FP18;

        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = admin;
        cfg.safeWallet = MockSafeWalletFactory.deploy(admin, pauser);
        cfg.name = "CyberGold";
        cfg.symbol = "CYGLD";
        cfg.coreTreasury = treasury;
        cfg.basketAssets = assets;
        cfg.basketTargetsPpm = weights;
        cfg.basketGoldRefGramsFp18 = goldRefs;
        cfg.cygldRefGramsFp18 = CYGLD_REF_GRAMS_FP18;
        cfg.maxTotalSupply = INITIAL_MAX_TOTAL_SUPPLY;
        cfg.issuanceFeePpm = 1_000;
        cfg.redemptionFeePpm = 1_000;

        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.deploy(cfg);
        diamond = address(art.diamond);
        reserve = diamond;
        issuance = IssuanceFacet(diamond);
        redemption = RedemptionFacet(diamond);
        rebalance = RebalanceFacet(diamond);
        testReserveLifecycle = ReserveLifecycleFacet(diamond);
        testRecoveryLens = LensFacet(diamond);
        preview = PreviewFacet(diamond);
        basketAdmin = BasketAdminFacet(diamond);
        config = ControllerConfigFacet(diamond);
        lens = LensFacet(diamond);
        token = TokenFacet(diamond);

        _handoffCoreAuthorityForTest(cfg.safeWallet);
        _unpauseCoreForTest();

        tokA.mint(user, 1_000 ether);
        tokB.mint(user, 2_000_000_000); // 2000 with 6 decimals
    }

    function _seedReserveForRedemption() internal {
        vm.startPrank(user);
        IERC20(address(tokA)).approve(diamond, type(uint256).max);
        IERC20(address(tokB)).approve(diamond, type(uint256).max);
        issuance.issue(1e18);
        vm.stopPrank();
    }

    function _setBasketForTest(address[] memory assets, uint256[] memory weights, uint256[] memory goldRefs) internal {
        bool wasPaused = PausableFacet(diamond).paused();
        if (!wasPaused) _pauseCoreForTest();

        _activateMissingTestReserves(assets, goldRefs);
        _inactivateUndesiredTestReserves(assets);
        _configureTestBasket(assets, weights, goldRefs);

        if (!wasPaused) _unpauseCoreForTest();
    }

    function _activateMissingTestReserves(address[] memory desiredAssets, uint256[] memory desiredGoldRefs) private {
        for (uint256 i; i < desiredAssets.length; ++i) {
            if (_testBasketPosition(desiredAssets[i]) != 0) continue;
            _activateTestReserve(desiredAssets[i], desiredGoldRefs[i]);
        }
    }

    function _activateTestReserve(address asset, uint256 goldRef) internal {
        testReserveLifecycle.activateAsset(_testAssetActivationRequest(asset, goldRef));
    }

    function _testAssetActivationRequest(address asset, uint256 goldRef)
        internal
        view
        returns (IRecoveryTypes.AssetActivationRequest memory request)
    {
        (address[] memory resultingAssets, uint256[] memory resultingWeights, uint256[] memory resultingGoldRefs) =
            _testActivationBasket(asset, goldRef);

        return _testAssetActivationRequestForBasket(asset, resultingAssets, resultingWeights, resultingGoldRefs);
    }

    function _testAssetActivationRequestForBasket(
        address asset,
        address[] memory resultingAssets,
        uint256[] memory resultingWeights,
        uint256[] memory resultingGoldRefs
    ) internal view returns (IRecoveryTypes.AssetActivationRequest memory request) {
        IRecoveryTypes.ReserveLifecycleView memory state = testRecoveryLens.reserveLifecycle(asset);
        uint256 liveRaw = IERC20(asset).balanceOf(diamond);
        uint256 poolRaw = testRecoveryLens.recoveryPool(asset).redeemableRaw;
        uint256 activeAvailableRaw = liveRaw > poolRaw ? liveRaw - poolRaw : 0;

        request = IRecoveryTypes.AssetActivationRequest({
            asset: asset,
            expectedLifecycle: state.lifecycle,
            expectedBasketHash: lens.basketConfigHash(),
            expectedActiveAvailableRaw: activeAvailableRaw,
            resultingBasketAssets: resultingAssets,
            resultingTargetsPpm: resultingWeights,
            resultingGoldRefGramsFp18: resultingGoldRefs
        });
    }

    function _testActivationBasket(address asset, uint256 goldRef)
        private
        view
        returns (
            address[] memory resultingAssets,
            uint256[] memory resultingWeights,
            uint256[] memory resultingGoldRefs
        )
    {
        address[] memory currentAssets = lens.basketAssets();
        uint256[] memory currentWeights = lens.basketTargetsPpm();
        uint256[] memory currentGoldRefs = lens.basketGoldRefGramsFp18();
        uint256 n = currentAssets.length;
        uint256 existingPosition = _testBasketPosition(asset);
        bool alreadyPresent = existingPosition != 0;
        uint256 resultingLength = alreadyPresent ? n : n + 1;
        resultingAssets = new address[](resultingLength);
        resultingWeights = new uint256[](resultingLength);
        resultingGoldRefs = new uint256[](resultingLength);
        uint256 donorIndex = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            resultingAssets[i] = currentAssets[i];
            resultingWeights[i] = currentWeights[i];
            resultingGoldRefs[i] = currentGoldRefs[i];
            if (currentAssets[i] != asset && donorIndex == type(uint256).max && currentWeights[i] > 1) {
                donorIndex = i;
            }
        }
        assertTrue(donorIndex != type(uint256).max, "test activation requires a positive-weight donor");
        resultingWeights[donorIndex] -= 1;
        uint256 candidateIndex = alreadyPresent ? existingPosition - 1 : n;
        resultingAssets[candidateIndex] = asset;
        resultingWeights[candidateIndex] = 1;
        resultingGoldRefs[candidateIndex] = goldRef;
    }

    function _inactivateUndesiredTestReserves(address[] memory desiredAssets) private {
        uint256 index;
        while (index < lens.basketAssets().length) {
            address asset = lens.basketAssets()[index];
            if (_containsTestAsset(desiredAssets, asset)) {
                ++index;
                continue;
            }

            IRecoveryTypes.ReserveLifecycleView memory state = testRecoveryLens.reserveLifecycle(asset);
            if (state.lifecycle == IRecoveryTypes.ReserveLifecycle.Active) {
                _beginTestReserveExit(asset);
                state = testRecoveryLens.reserveLifecycle(asset);
            }
            assertEq(uint256(state.lifecycle), uint256(IRecoveryTypes.ReserveLifecycle.Exiting));
            assertEq(state.exitEntitlementRaw, 0, "test helper cannot inactivate funded reserve");
            _finalizeTestReserveInactivation(asset);
        }
    }

    function _beginTestReserveExit(address asset) internal {
        address[] memory currentAssets = lens.basketAssets();
        uint256[] memory currentWeights = lens.basketTargetsPpm();
        uint256[] memory currentGoldRefs = lens.basketGoldRefGramsFp18();
        uint256 assetIndex = _testBasketPosition(asset) - 1;
        uint256 recipientIndex = type(uint256).max;
        for (uint256 i; i < currentAssets.length; ++i) {
            if (i != assetIndex && currentWeights[i] != 0) {
                recipientIndex = i;
                break;
            }
        }
        assertTrue(recipientIndex != type(uint256).max, "test exit requires a positive-weight recipient");
        currentWeights[recipientIndex] += currentWeights[assetIndex];
        currentWeights[assetIndex] = 0;

        testReserveLifecycle.beginReserveExit(
            IRecoveryTypes.ReserveExitRequest({
                asset: asset,
                expectedBasketHash: lens.basketConfigHash(),
                expectedExitEntitlementRaw: testRecoveryLens.reserveCustodyStatus(asset).activeAvailableRaw,
                resultingBasketAssets: currentAssets,
                resultingTargetsPpm: currentWeights,
                resultingGoldRefGramsFp18: currentGoldRefs
            })
        );
    }

    function _finalizeTestReserveInactivation(address asset) private {
        address[] memory currentAssets = lens.basketAssets();
        uint256[] memory currentWeights = lens.basketTargetsPpm();
        uint256[] memory currentGoldRefs = lens.basketGoldRefGramsFp18();
        uint256 n = currentAssets.length;
        address[] memory resultingAssets = new address[](n - 1);
        uint256[] memory resultingWeights = new uint256[](n - 1);
        uint256[] memory resultingGoldRefs = new uint256[](n - 1);
        uint256 writeIndex;
        for (uint256 i; i < n; ++i) {
            if (currentAssets[i] == asset) continue;
            resultingAssets[writeIndex] = currentAssets[i];
            resultingWeights[writeIndex] = currentWeights[i];
            resultingGoldRefs[writeIndex] = currentGoldRefs[i];
            ++writeIndex;
        }

        testReserveLifecycle.finalizeReserveInactivation(
            IRecoveryTypes.ReserveInactivationRequest({
                asset: asset,
                expectedBasketHash: lens.basketConfigHash(),
                resultingBasketAssets: resultingAssets,
                resultingTargetsPpm: resultingWeights,
                resultingGoldRefGramsFp18: resultingGoldRefs
            })
        );
    }

    function _configureTestBasket(address[] memory assets, uint256[] memory weights, uint256[] memory goldRefs)
        private
    {
        uint256 zeroTargets;
        for (uint256 i; i < weights.length; ++i) {
            if (weights[i] == 0) ++zeroTargets;
        }

        if (zeroTargets != 0) {
            uint256[] memory interimWeights = new uint256[](weights.length);
            uint256 donorIndex = type(uint256).max;
            for (uint256 i; i < weights.length; ++i) {
                interimWeights[i] = weights[i] == 0 ? 1 : weights[i];
                if (weights[i] > zeroTargets) donorIndex = i;
            }
            assertTrue(donorIndex != type(uint256).max, "test basket requires a positive-weight donor");
            interimWeights[donorIndex] -= zeroTargets;
            _setGenericTestBasketIfChanged(assets, interimWeights, goldRefs);

            for (uint256 i; i < weights.length; ++i) {
                if (weights[i] == 0) _beginTestReserveExit(assets[i]);
            }
        }

        _setGenericTestBasketIfChanged(assets, weights, goldRefs);
    }

    function _setGenericTestBasketIfChanged(
        address[] memory assets,
        uint256[] memory weights,
        uint256[] memory goldRefs
    ) private {
        bytes32 currentHash = lens.basketConfigHash();
        if (currentHash == keccak256(abi.encode(assets, weights, goldRefs))) return;
        basketAdmin.setBasket(currentHash, assets, weights, goldRefs);
    }

    function _containsTestAsset(address[] memory assets, address asset) private pure returns (bool) {
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == asset) return true;
        }
        return false;
    }

    function _testBasketPosition(address asset) internal view returns (uint256) {
        address[] memory assets = lens.basketAssets();
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == asset) return i + 1;
        }
        return 0;
    }

    function _pauseCoreForTest() internal {
        PausableFacet(diamond).pause();
    }

    /// @dev Most controller unit tests predate the production Safe-only launch topology and
    ///      intentionally exercise product-admin calls from this harness. Move both critical
    ///      roles through the public, invariant-preserving lifecycle after deployment; focused
    ///      deployment tests separately assert the untouched Safe-only launch state.
    function _handoffCoreAuthorityForTest(address launchSafe) internal {
        DefaultAdminAccessControlFacet access = DefaultAdminAccessControlFacet(diamond);
        bytes32 upgraderRole = access.upgraderRole();

        vm.prank(launchSafe);
        access.beginDefaultAdminTransfer(address(this));
        vm.warp(block.timestamp + 1);
        access.acceptDefaultAdminTransfer();

        access.grantRole(upgraderRole, address(this));
        access.revokeRole(upgraderRole, launchSafe);
    }

    function _unpauseCoreForTest() internal {
        vm.prank(PausableFacet(diamond).safeWallet());
        PausableFacet(diamond).unpause();
    }

    function _cygldPerUnitFp18(uint256 goldRefGramsFp18, uint8 decimals) internal pure returns (uint256) {
        uint256 cygldPerTokenFp18 = Math.mulDiv(goldRefGramsFp18, 1e18, CYGLD_REF_GRAMS_FP18, Math.Rounding.Floor);
        if (decimals == 18) {
            return cygldPerTokenFp18;
        }
        uint256 scale;
        if (decimals < 18) {
            scale = 10 ** (18 - decimals);
            return Math.mulDiv(cygldPerTokenFp18, scale, 1, Math.Rounding.Floor);
        }
        scale = 10 ** (decimals - 18);
        return Math.mulDiv(cygldPerTokenFp18, 1, scale, Math.Rounding.Floor);
    }

    function _coreMinimums(ICoreRedemption.RedemptionQuote memory quote)
        internal
        pure
        returns (ICoreRedemption.TokenMinimum[] memory minimums)
    {
        minimums = new ICoreRedemption.TokenMinimum[](quote.outputs.length);
        for (uint256 i; i < quote.outputs.length; ++i) {
            ICoreRedemption.TokenAmount memory output = quote.outputs[i];
            minimums[i] = ICoreRedemption.TokenMinimum({
                kind: output.kind, token: output.token, id: output.id, minimumAmount: output.amount
            });
        }
    }

    function _coreOutputAmounts(ICoreRedemption.RedemptionQuote memory quote)
        internal
        pure
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](quote.outputs.length);
        for (uint256 i; i < quote.outputs.length; ++i) {
            amounts[i] = quote.outputs[i].amount;
        }
    }
}
