// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

import {SleeveCurve} from "../../src/sleeves/SleeveCurve.sol";
import {ISleeve} from "../../src/sleeves/ISleeve.sol";
import {MockStakingDiamond} from "../helpers/MockStakingDiamond.sol";
import {MockCurvePool, MockCurveGauge} from "staking-mocks/MockCurvePool.sol";
import {MockSwapAdapter} from "staking-mocks/MockSwapAdapter.sol";
import {MockCygldBasketController} from "staking-mocks/MockCygldBasketController.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {SleeveDeployerHelper} from "../../src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "../../src/deploy/SleeveRequestBuilder.sol";

contract MutableBasketController {
    address[] internal _assets;
    uint256[] internal _conversions;

    function setBasket(address[] memory assets, uint256[] memory conversions) external {
        _assets = assets;
        _conversions = conversions;
    }

    function redeem(uint256 grossCygldIn) external view returns (ICoreRedemption.RedemptionQuote memory result) {
        result.grossCygldIn = grossCygldIn;
        result.netCygldIn = grossCygldIn;
        result.outputs = new ICoreRedemption.TokenAmount[](_assets.length);
        for (uint256 i; i < _assets.length; ++i) {
            result.outputs[i] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: _assets[i], id: 0, amount: 0
            });
        }
    }

    function basketAssets() external view returns (address[] memory) {
        return _assets;
    }

    function basketCygldPerUnitFp18() external view returns (uint256[] memory) {
        return _conversions;
    }
}

contract MalformedRedeemController {
    enum Malformation {
        None,
        MissingOutput,
        ExtraOutput,
        RecoveryOutput,
        WrongToken,
        NonzeroId,
        GrossInput,
        NetInput
    }

    address[] internal _assets;
    Malformation internal _malformation;

    constructor(address[] memory assets_) {
        _assets = assets_;
    }

    function setMalformation(Malformation malformation_) external {
        _malformation = malformation_;
    }

    function redeem(uint256 grossCygldIn) external view returns (ICoreRedemption.RedemptionQuote memory result) {
        result.grossCygldIn = _malformation == Malformation.GrossInput ? grossCygldIn + 1 : grossCygldIn;
        result.netCygldIn = _malformation == Malformation.NetInput ? grossCygldIn - 1 : grossCygldIn;

        uint256 outputCount = _assets.length;
        if (_malformation == Malformation.MissingOutput) --outputCount;
        if (_malformation == Malformation.ExtraOutput) ++outputCount;
        result.outputs = new ICoreRedemption.TokenAmount[](outputCount);

        for (uint256 i; i < outputCount; ++i) {
            address token = i < _assets.length ? _assets[i] : address(0xBAD);
            result.outputs[i] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: token, id: 0, amount: grossCygldIn
            });
        }

        if (outputCount != 0) {
            if (_malformation == Malformation.RecoveryOutput) {
                result.outputs[0].kind = ICoreRedemption.TokenKind.ERC1155;
            }
            if (_malformation == Malformation.WrongToken) result.outputs[0].token = address(0xBAD);
            if (_malformation == Malformation.NonzeroId) result.outputs[0].id = 1;
        }
    }

    function basketAssets() external view returns (address[] memory) {
        return _assets;
    }

    function basketCygldPerUnitFp18() external view returns (uint256[] memory conversions) {
        conversions = new uint256[](_assets.length);
        for (uint256 i; i < _assets.length; ++i) {
            conversions[i] = 1e18;
        }
    }
}

contract DryCurveGauge {
    function deposit(uint256) external {}

    function withdraw(uint256) external {}

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function claim_rewards(address) external {}
}

contract FalseReturnToken {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure returns (bool) {
        return false;
    }
}

contract SleeveCurveBranchHarness is SleeveCurve {
    function exposedTransfer(address token, address to, uint256 amount) external {
        _transfer(token, to, amount);
    }

    function exposedApprove(address token, address spender, uint256 amount) external {
        _approve(token, spender, amount);
    }

    function exposedIndexToUint(int128 value) external pure returns (uint256) {
        return _indexToUint(value);
    }
}

contract SleeveCurveTest is Test {
    MockERC20 internal cygld;
    MockERC20 internal paxg;
    MockERC20 internal xaut;
    MockCygldBasketController internal controller;
    MockCurvePool internal pool;
    MockCurveGauge internal gauge;
    MockStakingDiamond internal stakingDiamond;
    SleeveCurve internal sleeve;
    MockERC20 internal reward;
    MockSwapAdapter internal swapAdapter;
    MockSwapAdapter internal basketSwapAdapter;

    address internal admin = address(this);

    function setUp() public {
        cygld = new MockERC20("CyberGold", "CYGLD", 18);
        paxg = new MockERC20("PAX Gold", "PAXG", 18);
        xaut = new MockERC20("Tether Gold", "XAUT", 18);

        address[] memory basket = new address[](2);
        basket[0] = address(paxg);
        basket[1] = address(xaut);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 600_000;
        weights[1] = 400_000;
        uint256[] memory conversions = new uint256[](2);
        conversions[0] = 1e18;
        conversions[1] = 1e18;
        controller = new MockCygldBasketController(address(cygld), basket, weights, conversions);

        pool = new MockCurvePool(address(paxg), address(cygld));
        gauge = new MockCurveGauge(pool);
        basketSwapAdapter = new MockSwapAdapter();

        stakingDiamond = new MockStakingDiamond(admin, address(0x5AFE));

        sleeve = _deployCurveSleeve(address(gauge), 0, 0);

        _authorizeSleeve(sleeve);

        reward = new MockERC20("Reward", "RWD", 18);
        swapAdapter = new MockSwapAdapter();

        cygld.mint(address(pool), 1_000_000 ether);
        paxg.mint(address(pool), 1_000_000 ether);
        paxg.mint(address(controller), 1_000_000 ether);
        xaut.mint(address(controller), 1_000_000 ether);
    }

    function _allocParams(uint256 minLp) internal pure returns (bytes memory) {
        uint256[] memory minSwapOut = new uint256[](2);
        return abi.encode(SleeveCurve.AllocateParams({minLpMint: minLp, minBasketSwapOut: minSwapOut}));
    }

    function _deallocParams(uint256 lpAmount, uint256 minUnderlyingOut) internal pure returns (bytes memory) {
        return abi.encode(SleeveCurve.DeallocateParams({lpAmount: lpAmount, minUnderlyingOut: minUnderlyingOut}));
    }

    function _harvestParams(uint256 lpAmount, uint256 minUnderlyingOut) internal pure returns (bytes memory) {
        uint256[] memory empty = new uint256[](0);
        return abi.encode(
            SleeveCurve.HarvestParams({lpAmount: lpAmount, minUnderlyingOut: minUnderlyingOut, minRewardOut: empty})
        );
    }

    function _harvestParams(uint256 lpAmount, uint256 minUnderlyingOut, uint256[] memory minRewardOut)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            SleeveCurve.HarvestParams({
                lpAmount: lpAmount, minUnderlyingOut: minUnderlyingOut, minRewardOut: minRewardOut
            })
        );
    }

    function _deployCurveSleeve(address gaugeAddr, uint256 refPrice, uint32 devBps) internal returns (SleeveCurve sc) {
        SleeveCurve.CurveInitParams memory params = SleeveCurve.CurveInitParams({
            otherAsset: address(paxg),
            pool: address(pool),
            underlyingIndex: int128(1),
            otherIndex: int128(0),
            otherSharePpm: uint32(500_000),
            gauge: gaugeAddr,
            priceReference: refPrice,
            maxPriceDeviationBps: devBps,
            cygldController: address(controller),
            basketSwapAdapter: address(basketSwapAdapter)
        });
        address implementation = address(new SleeveCurve());
        SleeveDeployerHelper.SleeveRequest memory req =
            SleeveRequestBuilder.curve(implementation, address(cygld), params, true, 0);
        sc = SleeveCurve(
            SleeveDeployerHelper.deployDeterministic(
                address(stakingDiamond), req, keccak256(abi.encode(implementation, params))
            )
        );
    }

    function _authorizeSleeve(SleeveCurve sc) internal {
        stakingDiamond.setSleeveCaller(address(sc), true);
    }

    function _defaultCurveParams(address gaugeAddr) internal view returns (SleeveCurve.CurveInitParams memory params) {
        params = SleeveCurve.CurveInitParams({
            otherAsset: address(paxg),
            pool: address(pool),
            underlyingIndex: int128(1),
            otherIndex: int128(0),
            otherSharePpm: uint32(500_000),
            gauge: gaugeAddr,
            priceReference: 0,
            maxPriceDeviationBps: 0,
            cygldController: address(controller),
            basketSwapAdapter: address(basketSwapAdapter)
        });
    }

    function _launchParams(SleeveCurve.CurveInitParams memory venue)
        internal
        pure
        returns (SleeveCurve.CurveLaunchParams memory params)
    {
        params.venue = venue;
        params.rewardTokens = new address[](0);
    }

    function _singleAssetController(address asset) internal returns (MockCygldBasketController ctrl) {
        address[] memory basket = new address[](1);
        basket[0] = asset;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1_000_000;
        uint256[] memory conversions = new uint256[](1);
        conversions[0] = 1e18;
        ctrl = new MockCygldBasketController(address(cygld), basket, weights, conversions);
    }

    function test_initialize_revertsOnZeroCurveDependency() public {
        SleeveCurve.CurveInitParams memory params = _defaultCurveParams(address(gauge));
        params.cygldController = address(0);
        assertEq(params.cygldController, address(0));
        SleeveCurve implementation = new SleeveCurve();

        vm.expectRevert(ISleeve.ZeroAddress.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                SleeveCurve.initialize, (address(stakingDiamond), address(cygld), 0, _launchParams(params), true, false)
            )
        );
    }

    function test_initialize_revertsOnInvalidCurveParams() public {
        SleeveCurve.CurveInitParams memory params = _defaultCurveParams(address(gauge));
        SleeveCurve implementation = new SleeveCurve();

        params.underlyingIndex = int128(0);
        params.otherIndex = int128(0);
        vm.expectRevert(SleeveCurve.InvalidIndex.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                SleeveCurve.initialize, (address(stakingDiamond), address(cygld), 0, _launchParams(params), true, false)
            )
        );

        implementation = new SleeveCurve();
        params = _defaultCurveParams(address(gauge));
        params.otherSharePpm = uint32(1_000_000);
        vm.expectRevert(SleeveCurve.InvalidSplit.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                SleeveCurve.initialize, (address(stakingDiamond), address(cygld), 0, _launchParams(params), true, false)
            )
        );

        MockCurvePool sameAssetPool = new MockCurvePool(address(cygld), address(cygld));
        implementation = new SleeveCurve();
        params = _defaultCurveParams(address(gauge));
        params.pool = address(sameAssetPool);
        params.otherAsset = address(cygld);
        vm.expectRevert(SleeveCurve.InvalidIndex.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                SleeveCurve.initialize, (address(stakingDiamond), address(cygld), 0, _launchParams(params), true, false)
            )
        );

        implementation = new SleeveCurve();
        params = _defaultCurveParams(address(gauge));
        params.maxPriceDeviationBps = uint32(10_001);
        vm.expectRevert(SleeveCurve.InvalidSplit.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                SleeveCurve.initialize, (address(stakingDiamond), address(cygld), 0, _launchParams(params), true, false)
            )
        );

        implementation = new SleeveCurve();
        params = _defaultCurveParams(address(gauge));
        params.underlyingIndex = -1;
        vm.expectRevert(SleeveCurve.InvalidIndex.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                SleeveCurve.initialize, (address(stakingDiamond), address(cygld), 0, _launchParams(params), true, false)
            )
        );

        implementation = new SleeveCurve();
        params = _defaultCurveParams(address(gauge));
        params.otherIndex = -1;
        vm.expectRevert(SleeveCurve.InvalidIndex.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                SleeveCurve.initialize, (address(stakingDiamond), address(cygld), 0, _launchParams(params), true, false)
            )
        );

        implementation = new SleeveCurve();
        params = _defaultCurveParams(address(gauge));
        params.underlyingIndex = int128(0);
        params.otherIndex = int128(1);
        vm.expectRevert(SleeveCurve.InvalidIndex.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                SleeveCurve.initialize, (address(stakingDiamond), address(cygld), 0, _launchParams(params), true, false)
            )
        );

        implementation = new SleeveCurve();
        params = _defaultCurveParams(address(gauge));
        params.otherAsset = address(xaut);
        vm.expectRevert(SleeveCurve.InvalidIndex.selector);
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                SleeveCurve.initialize, (address(stakingDiamond), address(cygld), 0, _launchParams(params), true, false)
            )
        );
    }

    function test_adminSetTargetOtherPpm() public {
        vm.expectRevert(SleeveCurve.InvalidSplit.selector);
        sleeve.setTargetOtherPpm(1_000_000);

        vm.expectEmit(false, false, false, true);
        emit SleeveCurve.SplitUpdated(250_000);
        sleeve.setTargetOtherPpm(250_000);

        assertEq(sleeve.targetOtherPpm(), 250_000);
    }

    function test_initializeLeavesNoPersistentExternalAllowances() public view {
        assertEq(cygld.allowance(address(sleeve), address(pool)), 0, "underlying/pool allowance");
        assertEq(paxg.allowance(address(sleeve), address(pool)), 0, "other-asset/pool allowance");
        assertEq(pool.allowance(address(sleeve), address(pool)), 0, "LP/pool allowance");
        assertEq(cygld.allowance(address(sleeve), address(controller)), 0, "underlying/Core allowance");
        assertEq(pool.allowance(address(sleeve), address(gauge)), 0, "LP/gauge allowance");
    }

    function test_adminSetGaugeWithdrawsExistingStake() public {
        cygld.mint(address(stakingDiamond), 200 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(100 ether, _allocParams(1));

        assertEq(gauge.balanceOf(address(sleeve)), 100 ether);

        vm.expectEmit(false, false, false, true);
        emit SleeveCurve.GaugeUpdated(address(0));
        sleeve.setGauge(address(0));

        assertEq(address(sleeve.gauge()), address(0));
        assertEq(gauge.balanceOf(address(sleeve)), 0);
        assertEq(pool.balanceOf(address(sleeve)), 100 ether);
        assertEq(pool.allowance(address(sleeve), address(gauge)), 0);

        MockCurveGauge nextGauge = new MockCurveGauge(pool);
        sleeve.setGauge(address(nextGauge));
        assertEq(address(sleeve.gauge()), address(nextGauge));
        assertEq(pool.allowance(address(sleeve), address(nextGauge)), 0);
    }

    function test_adminSetCygldControllerBasketAdapterAndRewardTokens() public {
        MockCygldBasketController nextController = _singleAssetController(address(paxg));
        MockCygldBasketController missingOtherController = _singleAssetController(address(xaut));

        vm.expectRevert(ISleeve.ZeroAddress.selector);
        sleeve.setCygldController(address(0));

        vm.expectEmit(false, false, false, true);
        emit SleeveCurve.CygldControllerUpdated(address(nextController));
        sleeve.setCygldController(address(nextController));
        assertEq(address(sleeve.cygldController()), address(nextController));
        assertEq(cygld.allowance(address(sleeve), address(controller)), 0, "old Core allowance cleared");
        assertEq(cygld.allowance(address(sleeve), address(nextController)), 0, "new Core allowance not persistent");

        vm.expectRevert(SleeveCurve.OtherAssetNotInBasket.selector);
        sleeve.setCygldController(address(missingOtherController));

        vm.expectEmit(false, false, false, true);
        emit SleeveCurve.BasketSwapAdapterUpdated(address(0xCAFE));
        sleeve.setBasketSwapAdapter(address(0xCAFE));
        assertEq(sleeve.basketSwapAdapter(), address(0xCAFE));

        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        sleeve.setRewardTokens(tokens);
        address[] memory listed = sleeve.rewardTokens();
        assertEq(listed.length, 1);
        assertEq(listed[0], address(reward));

        tokens[0] = address(0);
        vm.expectRevert(ISleeve.ZeroAddress.selector);
        sleeve.setRewardTokens(tokens);

        tokens = new address[](2);
        tokens[0] = address(reward);
        tokens[1] = address(reward);
        vm.expectRevert(abi.encodeWithSelector(SleeveCurve.DuplicateRewardToken.selector, address(reward)));
        sleeve.setRewardTokens(tokens);
    }

    function test_allocate_swapsAndDeposits() public {
        cygld.mint(address(stakingDiamond), 1_000 ether);

        vm.prank(address(stakingDiamond));
        uint256 used = sleeve.allocate(600 ether, _allocParams(1));

        assertEq(used, 600 ether);
        assertEq(sleeve.principalAssets(), 600 ether);
        // gauge is set, so LPs are staked
        assertEq(pool.balanceOf(address(sleeve)), 0);
        assertEq(gauge.balanceOf(address(sleeve)), 600 ether);
        assertEq(cygld.balanceOf(address(stakingDiamond)), 400 ether);
        assertEq(cygld.balanceOf(address(controller)), 300 ether);
        assertEq(xaut.balanceOf(address(basketSwapAdapter)), 120 ether);
        assertEq(cygld.allowance(address(sleeve), address(controller)), 0, "Core allowance cleared");
        assertEq(cygld.allowance(address(sleeve), address(pool)), 0, "underlying/pool allowance cleared");
        assertEq(paxg.allowance(address(sleeve), address(pool)), 0, "other-asset/pool allowance cleared");
        assertEq(pool.allowance(address(sleeve), address(gauge)), 0, "LP/gauge allowance cleared");
        assertEq(xaut.allowance(address(sleeve), address(basketSwapAdapter)), 0, "basket adapter allowance cleared");
    }

    function test_allocate_stakesWhenGaugePresent() public {
        cygld.mint(address(stakingDiamond), 800 ether);

        vm.prank(address(stakingDiamond));
        sleeve.allocate(500 ether, _allocParams(1));

        assertEq(pool.balanceOf(address(sleeve)), 0);
        assertEq(gauge.balanceOf(address(sleeve)), 500 ether);
    }

    function test_deallocate_withdrawsSingleCoin() public {
        cygld.mint(address(stakingDiamond), 1_000 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(600 ether, _allocParams(1));

        vm.prank(address(stakingDiamond));
        uint256 returned = sleeve.deallocate(300 ether, _deallocParams(300 ether, 1));

        assertEq(returned, 300 ether);
        assertEq(cygld.balanceOf(address(stakingDiamond)), 700 ether);
        assertEq(sleeve.principalAssets(), 300 ether);
        assertEq(pool.allowance(address(sleeve), address(pool)), 0, "LP/pool allowance cleared");
        assertEq(pool.allowance(address(sleeve), address(gauge)), 0, "LP/gauge allowance remains clear");
    }

    function test_harvest_sendsProfitToStakingDiamond() public {
        cygld.mint(address(stakingDiamond), 900 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(600 ether, _allocParams(1));

        uint256 controllerBalanceBefore = cygld.balanceOf(address(stakingDiamond));
        vm.prank(address(stakingDiamond));
        uint256 profit = sleeve.harvest(_harvestParams(150 ether, 1));

        assertEq(profit, 150 ether);
        assertEq(cygld.balanceOf(address(stakingDiamond)) - controllerBalanceBefore, 150 ether);
        assertEq(pool.allowance(address(sleeve), address(pool)), 0, "LP/pool allowance cleared");
        assertEq(pool.allowance(address(sleeve), address(gauge)), 0, "LP/gauge allowance remains clear");
    }

    function test_totalAssets_countsLpAndIdle() public {
        cygld.mint(address(stakingDiamond), 900 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(600 ether, _allocParams(1));

        assertEq(sleeve.totalAssets(), 600 ether);
    }

    function test_totalAssets_convertsIdleOtherAssetToCygldUnits() public {
        controller.setBasketCygldPerUnitFp18(0, 31e18);
        paxg.mint(address(sleeve), 2 ether);

        assertEq(sleeve.totalAssets(), 62 ether);
    }

    function test_totalAssetsRevertsWhenOtherAssetLeavesBasket() public {
        MutableBasketController mutableController = new MutableBasketController();

        address[] memory basket = new address[](1);
        basket[0] = address(paxg);
        uint256[] memory conversions = new uint256[](1);
        conversions[0] = 1e18;
        mutableController.setBasket(basket, conversions);
        sleeve.setCygldController(address(mutableController));

        basket[0] = address(xaut);
        mutableController.setBasket(basket, conversions);
        paxg.mint(address(sleeve), 1 ether);

        vm.expectRevert(SleeveCurve.OtherAssetNotInBasket.selector);
        sleeve.totalAssets();
    }

    function test_totalAssetsRevertsOnBasketConversionLengthMismatch() public {
        MutableBasketController mutableController = new MutableBasketController();

        address[] memory basket = new address[](1);
        basket[0] = address(paxg);
        uint256[] memory conversions = new uint256[](0);
        mutableController.setBasket(basket, conversions);
        sleeve.setCygldController(address(mutableController));
        paxg.mint(address(sleeve), 1 ether);

        vm.expectRevert(SleeveCurve.BasketLengthMismatch.selector);
        sleeve.totalAssets();
    }

    function test_allocateAndDeallocateRejectMissingParams() public {
        vm.expectRevert(SleeveCurve.ParamsRequired.selector);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(1 ether, "");

        vm.expectRevert(SleeveCurve.ParamsRequired.selector);
        vm.prank(address(stakingDiamond));
        sleeve.deallocate(1 ether, "");

        vm.expectRevert(ISleeve.ZeroAmount.selector);
        vm.prank(address(stakingDiamond));
        sleeve.deallocate(1 ether, _deallocParams(0, 0));
    }

    function test_deallocatePrepareLpGuards() public {
        SleeveCurve noGauge = _deployCurveSleeve(address(0), 0, 0);
        vm.expectRevert(SleeveCurve.InsufficientLpBalance.selector);
        vm.prank(address(stakingDiamond));
        noGauge.deallocate(1 ether, _deallocParams(1 ether, 0));

        SleeveCurve.CurveInitParams memory params = _defaultCurveParams(address(new DryCurveGauge()));
        SleeveCurve dryGaugeSleeve = SleeveCurve(
            address(
                new ERC1967Proxy(
                    address(new SleeveCurve()),
                    abi.encodeCall(
                        SleeveCurve.initialize,
                        (address(stakingDiamond), address(cygld), 0, _launchParams(params), true, false)
                    )
                )
            )
        );

        vm.expectRevert(SleeveCurve.InsufficientLpBalance.selector);
        vm.prank(address(stakingDiamond));
        dryGaugeSleeve.deallocate(1 ether, _deallocParams(1 ether, 0));
    }

    function test_harvestRewardAdapterAndZeroBalanceBranches() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        sleeve.setRewardTokens(tokens);

        vm.expectRevert(SleeveCurve.RewardAdapterNotSet.selector);
        vm.prank(address(stakingDiamond));
        sleeve.harvest("");

        sleeve.setRewardSwapAdapter(address(swapAdapter));
        tokens = new address[](2);
        tokens[0] = address(xaut);
        tokens[1] = address(reward);
        sleeve.setRewardTokens(tokens);

        gauge.setRewardToken(address(reward));
        reward.mint(address(this), 100 ether);
        reward.approve(address(gauge), 100 ether);
        gauge.seedRewards(address(sleeve), 100 ether);

        vm.prank(address(stakingDiamond));
        assertEq(sleeve.harvest(""), 100 ether);
    }

    function test_unwrapToOtherAssetGuardBranches() public {
        cygld.mint(address(stakingDiamond), 300 ether);
        uint256[] memory shortMinOut = new uint256[](1);
        vm.expectRevert(SleeveCurve.MinOutLengthMismatch.selector);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(
            100 ether, abi.encode(SleeveCurve.AllocateParams({minLpMint: 0, minBasketSwapOut: shortMinOut}))
        );

        SleeveCurve mismatchSleeve = _deployCurveSleeve(address(gauge), 0, 0);
        _authorizeSleeve(mismatchSleeve);
        address[] memory basket = new address[](2);
        basket[0] = address(paxg);
        basket[1] = address(xaut);
        MalformedRedeemController malformedController = new MalformedRedeemController(basket);
        malformedController.setMalformation(MalformedRedeemController.Malformation.MissingOutput);
        mismatchSleeve.setCygldController(address(malformedController));
        cygld.mint(address(stakingDiamond), 100 ether);
        vm.expectRevert(SleeveCurve.BasketLengthMismatch.selector);
        vm.prank(address(stakingDiamond));
        mismatchSleeve.allocate(100 ether, _allocParams(0));

        SleeveCurve noAdapterSleeve = _deployCurveSleeve(address(gauge), 0, 0);
        _authorizeSleeve(noAdapterSleeve);
        noAdapterSleeve.setBasketSwapAdapter(address(0));
        cygld.mint(address(stakingDiamond), 100 ether);
        vm.expectRevert(SleeveCurve.BasketSwapAdapterNotSet.selector);
        vm.prank(address(stakingDiamond));
        noAdapterSleeve.allocate(100 ether, _allocParams(0));
    }

    function test_allocate_rejectsMalformedTypedCoreRedemption() public {
        address[] memory basket = new address[](2);
        basket[0] = address(paxg);
        basket[1] = address(xaut);
        MalformedRedeemController malformedController = new MalformedRedeemController(basket);
        sleeve.setCygldController(address(malformedController));
        cygld.mint(address(stakingDiamond), 100 ether);

        malformedController.setMalformation(MalformedRedeemController.Malformation.ExtraOutput);
        vm.expectRevert(SleeveCurve.BasketLengthMismatch.selector);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(100 ether, _allocParams(0));

        malformedController.setMalformation(MalformedRedeemController.Malformation.RecoveryOutput);
        vm.expectRevert(abi.encodeWithSelector(SleeveCurve.UnexpectedRedemptionOutput.selector, 0));
        vm.prank(address(stakingDiamond));
        sleeve.allocate(100 ether, _allocParams(0));

        malformedController.setMalformation(MalformedRedeemController.Malformation.WrongToken);
        vm.expectRevert(abi.encodeWithSelector(SleeveCurve.UnexpectedRedemptionOutput.selector, 0));
        vm.prank(address(stakingDiamond));
        sleeve.allocate(100 ether, _allocParams(0));

        malformedController.setMalformation(MalformedRedeemController.Malformation.NonzeroId);
        vm.expectRevert(abi.encodeWithSelector(SleeveCurve.UnexpectedRedemptionOutput.selector, 0));
        vm.prank(address(stakingDiamond));
        sleeve.allocate(100 ether, _allocParams(0));

        malformedController.setMalformation(MalformedRedeemController.Malformation.GrossInput);
        vm.expectRevert(
            abi.encodeWithSelector(SleeveCurve.RedemptionGrossInputMismatch.selector, 50 ether, 50 ether + 1)
        );
        vm.prank(address(stakingDiamond));
        sleeve.allocate(100 ether, _allocParams(0));

        malformedController.setMalformation(MalformedRedeemController.Malformation.NetInput);
        vm.expectRevert(abi.encodeWithSelector(SleeveCurve.RedemptionFeeCharged.selector, 0));
        vm.prank(address(stakingDiamond));
        sleeve.allocate(100 ether, _allocParams(0));
    }

    function test_transferApproveAndIndexHarnessBranches() public {
        SleeveCurveBranchHarness harness = new SleeveCurveBranchHarness();
        FalseReturnToken token = new FalseReturnToken();

        vm.expectRevert();
        harness.exposedTransfer(address(token), address(this), 1);

        vm.expectRevert();
        harness.exposedApprove(address(token), address(this), 1);

        vm.expectRevert(SleeveCurve.InvalidIndex.selector);
        harness.exposedIndexToUint(-1);
    }

    function test_allocate_respectsLpCap() public {
        sleeve.setMaxLpTokens(400 ether);
        cygld.mint(address(stakingDiamond), 1_000 ether);

        vm.expectRevert(abi.encodeWithSelector(SleeveCurve.LpCapExceeded.selector, 400 ether, 600 ether));
        vm.prank(address(stakingDiamond));
        sleeve.allocate(600 ether, _allocParams(1));
    }

    function test_allocate_priceGuardBlocksDeviation() public {
        SleeveCurve guarded = _deployCurveSleeve(address(gauge), 2e18, 100);

        cygld.mint(address(stakingDiamond), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(SleeveCurve.PriceOutOfBounds.selector, 1e18, 2e18));
        vm.prank(address(stakingDiamond));
        guarded.allocate(50 ether, _allocParams(1));
    }

    function test_harvest_claimsRewardsAndSwaps() public {
        cygld.mint(address(stakingDiamond), 800 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(400 ether, _allocParams(1));

        sleeve.setRewardSwapAdapter(address(swapAdapter));
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        sleeve.setRewardTokens(tokens);

        gauge.setRewardToken(address(reward));
        reward.mint(address(this), 100 ether);
        reward.approve(address(gauge), 100 ether);
        gauge.seedRewards(address(sleeve), 100 ether);

        swapAdapter.setRate(2e18); // convert reward -> PAXG *2

        uint256[] memory mins = new uint256[](1);
        mins[0] = 0;

        uint256 controllerBalanceBefore = cygld.balanceOf(address(stakingDiamond));
        vm.prank(address(stakingDiamond));
        uint256 profit = sleeve.harvest(_harvestParams(50 ether, 1, mins));

        // 50 CYGLD from LP + 200 CYGLD from rewards (100 * 2)
        assertEq(profit, 250 ether);
        assertEq(cygld.balanceOf(address(stakingDiamond)) - controllerBalanceBefore, 250 ether);
        assertEq(reward.allowance(address(sleeve), address(swapAdapter)), 0, "reward allowance cleared");
        assertEq(pool.allowance(address(sleeve), address(pool)), 0, "LP/pool allowance cleared");
        assertEq(pool.allowance(address(sleeve), address(gauge)), 0, "LP/gauge allowance remains clear");
    }

    function test_harvestWithoutLpTransfersRewards() public {
        sleeve.setRewardSwapAdapter(address(swapAdapter));
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        sleeve.setRewardTokens(tokens);

        gauge.setRewardToken(address(reward));
        reward.mint(address(this), 100 ether);
        reward.approve(address(gauge), 100 ether);
        gauge.seedRewards(address(sleeve), 100 ether);

        swapAdapter.setRate(2e18);

        vm.prank(address(stakingDiamond));
        uint256 profit = sleeve.harvest("");

        assertEq(profit, 200 ether);
        assertEq(cygld.balanceOf(address(stakingDiamond)), 200 ether);
        assertEq(reward.allowance(address(sleeve), address(swapAdapter)), 0, "reward allowance cleared");
    }

    function test_harvestRewards_usesObservedSwapOutput() public {
        sleeve.setRewardSwapAdapter(address(swapAdapter));
        address[] memory tokens = new address[](1);
        tokens[0] = address(reward);
        sleeve.setRewardTokens(tokens);

        gauge.setRewardToken(address(reward));
        reward.mint(address(this), 100 ether);
        reward.approve(address(gauge), 100 ether);
        gauge.seedRewards(address(sleeve), 100 ether);

        swapAdapter.setRate(2e18);
        swapAdapter.setReportedAmount(10_000 ether);

        vm.prank(address(stakingDiamond));
        uint256 profit = sleeve.harvest("");

        assertEq(profit, 200 ether);
        assertEq(cygld.balanceOf(address(stakingDiamond)), 200 ether);
    }

    function test_harvestWithoutLpAndRewardsReturnsZero() public {
        vm.prank(address(stakingDiamond));
        uint256 profit = sleeve.harvest("");

        assertEq(profit, 0);
    }

    function test_allocate_revertsWhenRedemptionChargesFee() public {
        controller.setRedemptionFeePpm(3_000);
        cygld.mint(address(stakingDiamond), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(SleeveCurve.RedemptionFeeCharged.selector, 0.15 ether));
        vm.prank(address(stakingDiamond));
        sleeve.allocate(100 ether, _allocParams(1));
    }
}
