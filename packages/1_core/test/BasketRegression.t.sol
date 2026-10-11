// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {CoreDiamond} from "../src/diamond/CoreDiamond.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {ICoreRedemption} from "../src/interfaces/ICoreRedemption.sol";
import {InitFacet} from "../src/facets/InitFacet.sol";
import {LibReserve} from "../src/libraries/LibReserve.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {
    BasketSetHarness,
    BranchERC20,
    BranchIssuanceHarness,
    BranchPreviewHarness,
    BranchRebalanceHarness,
    BranchRedemptionHarness,
    ReserveBranchHarness
} from "./mocks/BasketRegressionMocks.sol";

contract BasketRegressionTest is Test {
    bytes32 internal constant INIT_CONTEXT_SLOT = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;

    function deployCoreShellExternal(address owner) external {
        DeploymentHelper.deployCoreShell(owner, bytes32(uint256(0xB45CE7)));
    }

    function finalizeExistingExternal(CoreDiamond diamond) external {
        DeploymentTypes.DeployConfig memory cfg;
        DeploymentHelper.finalizeExisting(diamond, cfg);
    }

    function testDeploymentHelperGuardBranches() public {
        vm.expectRevert(bytes("DeploymentHelper: bootstrap owner missing"));
        this.deployCoreShellExternal(address(0));

        vm.expectRevert(bytes("DeploymentHelper: diamond missing"));
        this.finalizeExistingExternal(CoreDiamond(payable(address(0))));

        (CoreDiamond shell,) = DeploymentHelper.deployCoreShell(address(this), bytes32(uint256(0xA11CE)));
        vm.expectRevert(bytes("DeploymentHelper: admin missing"));
        this.finalizeExistingExternal(shell);
    }

    function testInitFacetRejectsMissingTreasury() public {
        InitFacet init = new InitFacet();
        vm.store(address(init), INIT_CONTEXT_SLOT, bytes32(uint256(1)));

        InitFacet.ControllerInitConfig memory cfg;
        cfg.maxTotalSupply = 1;
        vm.expectRevert(ICoreTypes.TreasuryNotSet.selector);
        init.initController(cfg);
    }

    function testSetBasketValidationBranches() public {
        BasketSetHarness harness = new BasketSetHarness();
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);

        vm.expectRevert(ICoreTypes.BasketEmpty.selector);
        harness.setBasketExternal(new address[](0), new uint256[](0), new uint256[](0));

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketLengthMismatch.selector, 1, 0));
        harness.setBasketExternal(_addresses(address(tokenA)), new uint256[](0), _uints(1 ether));

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketGoldRefLengthMismatch.selector, 1, 0));
        harness.setBasketExternal(_addresses(address(tokenA)), _uints(1_000_000), new uint256[](0));

        vm.expectRevert(ICoreTypes.BasketZeroCygldRef.selector);
        harness.setBasketExternal(_addresses(address(tokenA)), _uints(1_000_000), _uints(1 ether));

        harness.setCygldRef(1 ether);
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketZeroAsset.selector, 0));
        harness.setBasketExternal(_addresses(address(0)), _uints(1_000_000), _uints(1 ether));

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketZeroGoldRef.selector, 0));
        harness.setBasketExternal(_addresses(address(tokenA)), _uints(1_000_000), _uints(0));

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketDuplicateAsset.selector, address(tokenA)));
        harness.setBasketExternal(
            _addresses2(address(tokenA), address(tokenA)), _uints2(500_000, 500_000), _uints2(1 ether, 1 ether)
        );

        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketWeightsMismatch.selector, 2, 1_000_000));
        harness.setBasketExternal(
            _addresses2(address(tokenA), address(tokenB)), _uints2(1, 1), _uints2(1 ether, 1 ether)
        );

        harness.setCygldRef(type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketZeroConversion.selector, 0));
        harness.setBasketExternal(
            _addresses2(address(tokenA), address(tokenB)), _uints2(500_000, 500_000), _uints2(1, 1)
        );
    }

    function testComputeHelpersRejectUnconfiguredBasket() public {
        BasketSetHarness harness = new BasketSetHarness();

        vm.expectRevert(ICoreTypes.BasketNotConfigured.selector);
        harness.computeIssuanceExternal(1);

        vm.expectRevert(ICoreTypes.BasketNotConfigured.selector);
        harness.computeRedemptionExternal(1, 1, address(harness));
    }

    function testIssuanceFacetUnconfiguredGuardBranches() public {
        BranchIssuanceHarness harness = new BranchIssuanceHarness();
        vm.expectRevert(ICoreTypes.TreasuryNotSet.selector);
        harness.issue(1);

        harness.setTreasury(address(0xB0B));
        vm.expectRevert(ICoreTypes.BasketNotConfigured.selector);
        harness.issue(1);
    }

    function testRedemptionFacetUnconfiguredGuardBranches() public {
        BranchRedemptionHarness harness = new BranchRedemptionHarness();

        vm.expectRevert(ICoreTypes.ValueMustBeGreaterThanZero.selector);
        harness.redeem(0);

        vm.expectRevert(ICoreTypes.TreasuryNotSet.selector);
        harness.redeem(1);

        harness.setTreasury(address(0xB0B));
        vm.expectRevert(ICoreTypes.InsufficientSupply.selector);
        harness.redeem(1);

        harness.setTotalSupply(1);
        vm.expectRevert(ICoreTypes.BasketNotConfigured.selector);
        harness.redeem(1);
    }

    function testPreviewIssueGuardBranches() public {
        BranchPreviewHarness harness = new BranchPreviewHarness();
        MockERC20 asset = new MockERC20("A", "A", 18);

        vm.expectRevert(ICoreTypes.ValueMustBeGreaterThanZero.selector);
        harness.previewIssueFromBasketExactOut(0);

        vm.expectRevert(ICoreTypes.TreasuryNotSet.selector);
        harness.previewIssueFromBasketExactOut(1);

        harness.setTreasury(address(0xB0B));
        harness.setMaxTotalSupply(100 ether);
        vm.expectRevert(ICoreTypes.BasketNotConfigured.selector);
        harness.previewIssueFromBasketExactOut(1);

        BranchPreviewHarness exactIn = new BranchPreviewHarness();
        vm.expectRevert(ICoreTypes.TreasuryNotSet.selector);
        exactIn.previewIssueFromBasketExactIn(new uint256[](0));

        exactIn.setTreasury(address(0xB0B));
        vm.expectRevert(ICoreTypes.BasketNotConfigured.selector);
        exactIn.previewIssueFromBasketExactIn(new uint256[](0));

        exactIn.setBasketManual(_addresses(address(asset)), _uints(1_000_000), _uints(1 ether));
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.BasketLengthMismatch.selector, 1, 0));
        exactIn.previewIssueFromBasketExactIn(new uint256[](0));

        exactIn.setMaxTotalSupply(100 ether);
        exactIn.previewIssueFromBasketExactIn(_uints(1));
    }

    function testPreviewRedeemGuardBranches() public {
        BranchPreviewHarness harness = new BranchPreviewHarness();

        vm.expectRevert(ICoreTypes.ValueMustBeGreaterThanZero.selector);
        harness.previewRedeemExactIn(0);

        vm.expectRevert(ICoreTypes.TreasuryNotSet.selector);
        harness.previewRedeemExactIn(1);

        harness.setTreasury(address(0xB0B));
        vm.expectRevert(ICoreTypes.InsufficientSupply.selector);
        harness.previewRedeemExactIn(1);
    }

    function testPreviewRedeemExactOutGuardBranches() public {
        MockERC20 asset = new MockERC20("A", "A", 18);

        BranchPreviewHarness harness = new BranchPreviewHarness();
        vm.expectRevert(ICoreTypes.TreasuryNotSet.selector);
        harness.previewRedeemExactOut(_minimum(address(asset), 1));

        harness.setTreasury(address(0xB0B));
        vm.expectRevert(ICoreTypes.BasketNotConfigured.selector);
        harness.previewRedeemExactOut(_minimum(address(asset), 1));

        harness.setBasketManual(_addresses(address(asset)), _uints(1_000_000), _uints(1 ether));
        vm.expectRevert(
            abi.encodeWithSelector(ICoreRedemption.RedemptionOutputsLengthMismatch.selector, uint256(0), uint256(1))
        );
        harness.previewRedeemExactOut(new ICoreRedemption.TokenMinimum[](0));

        vm.expectRevert(ICoreTypes.InsufficientSupply.selector);
        harness.previewRedeemExactOut(_minimum(address(asset), 1));

        harness.setTotalSupply(100);
        vm.expectRevert(ICoreTypes.InsufficientSupply.selector);
        harness.previewRedeemExactOut(_minimum(address(asset), 1));

        asset.mint(address(harness), 100);
        harness.setRedemptionFeePpm(10_000);
        vm.expectRevert(ICoreTypes.InsufficientSupply.selector);
        harness.previewRedeemExactOut(_minimum(address(asset), 100));
    }

    function testSharedRedemptionCalculationGuardBranches() public {
        BranchPreviewHarness harness = new BranchPreviewHarness();

        vm.expectRevert(ICoreTypes.ValueMustBeGreaterThanZero.selector);
        harness.calculateRedeemExactInExternal(1, 0);

        vm.expectRevert(ICoreTypes.InsufficientSupply.selector);
        harness.calculateRedeemExactInExternal(0, 1);

        vm.expectRevert(
            abi.encodeWithSelector(ICoreRedemption.RedemptionOutputsLengthMismatch.selector, uint256(0), uint256(1))
        );
        harness.solveRedeemExactOutExternal(1, new uint256[](0));
    }

    function testRebalanceQuoteGuardBranches() public {
        MockERC20 assetIn = new MockERC20("In", "IN", 18);
        MockERC20 assetOut = new MockERC20("Out", "OUT", 18);

        BranchRebalanceHarness emptyBasket = new BranchRebalanceHarness();
        vm.expectRevert(ICoreTypes.BasketNotConfigured.selector);
        emptyBasket.previewRebalanceSwapExactIn(address(assetIn), address(assetOut), 1);

        BranchRebalanceHarness tinyInput = _rebalanceHarness(assetIn, assetOut, 1, 1 ether, 0, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreTypes.RebalanceAmountTooSmallAfterConversion.selector, address(assetIn), 1)
        );
        tinyInput.previewRebalanceSwapExactIn(address(assetIn), address(assetOut), 1);

        BranchRebalanceHarness tinyOutput = _rebalanceHarness(assetIn, assetOut, 1 ether, 2 ether, 0, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreTypes.RebalanceAmountTooSmallAfterConversion.selector, address(assetOut), 1)
        );
        tinyOutput.previewRebalanceSwapExactIn(address(assetIn), address(assetOut), 1);

        BranchRebalanceHarness insufficient = _rebalanceHarness(assetIn, assetOut, 1 ether, 1 ether, 0, 1 ether);
        vm.expectRevert(ICoreTypes.InsufficientSupply.selector);
        insufficient.previewRebalanceSwapExactIn(address(assetIn), address(assetOut), 2 ether);
    }

    function testRebalanceExecutionBalanceMismatchBranches() public {
        BranchRebalanceHarness harness = new BranchRebalanceHarness();
        BranchERC20 input = new BranchERC20();
        BranchERC20 output = new BranchERC20();

        input.mint(address(harness), 10);
        input.mint(address(this), 1);
        input.approve(address(harness), type(uint256).max);
        input.setMode(1, address(harness), 2);
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.UnderDelivery.selector, address(input), 1, 0));
        harness.executeExternal(address(input), address(output), 1, 0);

        harness = new BranchRebalanceHarness();
        input = new BranchERC20();
        output = new BranchERC20();
        input.mint(address(this), 10);
        input.approve(address(harness), type(uint256).max);
        input.setMode(2, address(harness), 0);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreTypes.PayerDebitMismatch.selector, address(input), address(this), 10, 9)
        );
        harness.executeExternal(address(input), address(output), 10, 0);

        harness = new BranchRebalanceHarness();
        input = new BranchERC20();
        output = new BranchERC20();
        input.mint(address(this), 1);
        output.mint(address(harness), 10);
        input.approve(address(harness), type(uint256).max);
        output.setMode(3, address(harness), 2);
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.ReserveDebitMismatch.selector, address(output), 1, 0));
        harness.executeExternal(address(input), address(output), 1, 1);

        harness = new BranchRebalanceHarness();
        input = new BranchERC20();
        output = new BranchERC20();
        input.mint(address(this), 1);
        output.mint(address(harness), 10);
        input.approve(address(harness), type(uint256).max);
        output.setMode(4, address(harness), 0);
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.ReserveDebitMismatch.selector, address(output), 2, 1));
        harness.executeExternal(address(input), address(output), 1, 2);
    }

    function testLibReserveRejectsRecipientUnderCreditAndSuccessReturningNoop() public {
        ReserveBranchHarness harness = new ReserveBranchHarness();
        BranchERC20 output = new BranchERC20();
        address recipient = address(0xCAFE);

        output.mint(address(harness), 10);
        output.setMode(5, address(harness), 0);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreTypes.RecipientCreditMismatch.selector, address(output), recipient, 2, 1)
        );
        harness.transferOutExternal(address(output), recipient, 2);

        output.setMode(6, address(harness), 0);
        vm.expectRevert(abi.encodeWithSelector(ICoreTypes.ReserveDebitMismatch.selector, address(output), 2, 0));
        harness.transferOutExternal(address(output), recipient, 2);
    }

    function testLibReserveRejectsZeroAddresses() public {
        ReserveBranchHarness harness = new ReserveBranchHarness();

        vm.expectRevert(LibReserve.ReserveZeroAddress.selector);
        harness.transferOutExternal(address(0), address(this), 1);

        vm.expectRevert(LibReserve.ReserveZeroAddress.selector);
        harness.transferOutExternal(address(0xBEEF), address(0), 1);

        BranchERC20 token = new BranchERC20();
        harness.initialize(address(token));
        harness.transferOutExternal(address(token), address(this), 0);
    }

    function _rebalanceHarness(
        MockERC20 assetIn,
        MockERC20 assetOut,
        uint256 inConversion,
        uint256 outConversion,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal returns (BranchRebalanceHarness harness) {
        harness = new BranchRebalanceHarness();
        harness.setBasketManual(
            _addresses2(address(assetIn), address(assetOut)),
            _uints2(500_000, 500_000),
            _uints2(inConversion, outConversion)
        );
        if (reserveIn != 0) assetIn.mint(address(harness), reserveIn);
        if (reserveOut != 0) assetOut.mint(address(harness), reserveOut);
    }

    function _addresses(address a) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = a;
    }

    function _addresses2(address a, address b) internal pure returns (address[] memory values) {
        values = new address[](2);
        values[0] = a;
        values[1] = b;
    }

    function _uints(uint256 a) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = a;
    }

    function _uints2(uint256 a, uint256 b) internal pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = a;
        values[1] = b;
    }

    function _minimum(address asset, uint256 amount)
        internal
        pure
        returns (ICoreRedemption.TokenMinimum[] memory minimums)
    {
        minimums = new ICoreRedemption.TokenMinimum[](1);
        minimums[0] = ICoreRedemption.TokenMinimum({
            kind: ICoreRedemption.TokenKind.ERC20, token: asset, id: 0, minimumAmount: amount
        });
    }
}
