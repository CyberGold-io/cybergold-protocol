// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {RecoveryShareFacet} from "../src/facets/RecoveryShareFacet.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";

contract RecoveryShareFacetHarness is RecoveryShareFacet {
    function seedPool(address asset, bool impaired, uint256 redeemableRaw) external {
        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
        pool.impaired = impaired;
        pool.redeemableRaw = redeemableRaw;
    }

    function issueFromController(address to, address[] calldata assets, uint256[] calldata amounts) external {
        this.issueRecoveryShares(to, assets, amounts);
    }

    function burnFromController(address from, address asset, uint256 amount) external {
        this.burnRecoveryShares(from, asset, amount);
    }

    function pauseForTest() external {
        _pause();
    }
}

contract RecoveryShareFacetTest is Test {
    RecoveryShareFacetHarness internal facet;
    address internal constant ASSET_A = address(0x1001);
    address internal constant ASSET_B = address(0x1002);
    address internal constant USER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);

    function setUp() public {
        facet = new RecoveryShareFacetHarness();
        facet.seedPool(ASSET_A, true, 0);
        facet.seedPool(ASSET_B, true, 0);
    }

    function testFacetIdentityAndStandardErc1155Supply() public view {
        assertEq(facet.FACET_VERSION(), 1);
        assertEq(facet.FACET_NAMESPACE(), keccak256("cybergold.core.recovery-share"));
        assertEq(facet.totalSupply(uint256(uint160(ASSET_A))), 0);
        assertEq(facet.totalSupply(type(uint256).max), 0);
    }

    function testIssueIsControllerOnlyAndUsesStrictlyOrderedAssetDerivedIds() public {
        (address[] memory assets, uint256[] memory amounts) = _two(ASSET_A, ASSET_B, 2 ether, 3 ether);

        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareControllerOnly.selector, address(this)));
        facet.issueRecoveryShares(USER, assets, amounts);

        facet.issueFromController(USER, assets, amounts);
        uint256 idA = uint256(uint160(ASSET_A));
        uint256 idB = uint256(uint160(ASSET_B));
        assertEq(facet.totalSupply(idA), 2 ether);
        assertEq(facet.totalSupply(idB), 3 ether);
        assertEq(facet.balanceOf(USER, idA), 2 ether);
        assertEq(facet.balanceOf(USER, idB), 3 ether);

        (assets, amounts) = _two(ASSET_B, ASSET_A, 1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryShareAssetsNotAscending.selector, ASSET_B, ASSET_A)
        );
        facet.issueFromController(USER, assets, amounts);

        (assets, amounts) = _two(ASSET_A, ASSET_A, 1, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryShareAssetsNotAscending.selector, ASSET_A, ASSET_A)
        );
        facet.issueFromController(USER, assets, amounts);
    }

    function testCurrentPoolPredicatesAndImpairedStateGateIssuance() public {
        address unknown = address(0x7777);
        (address[] memory assets, uint256[] memory amounts) = _one(unknown, 1);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareUnknown.selector, unknown));
        facet.issueFromController(USER, assets, amounts);

        facet.seedPool(ASSET_A, false, 1);
        (assets, amounts) = _one(ASSET_A, 1);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolImpairmentInvalid.selector, ASSET_A, true, false)
        );
        facet.issueFromController(USER, assets, amounts);
    }

    function testTransfersPreserveSupplyAndRemainLiveWhilePaused() public {
        (address[] memory assets, uint256[] memory amounts) = _one(ASSET_A, 2 ether);
        facet.issueFromController(USER, assets, amounts);
        facet.pauseForTest();

        uint256 id = uint256(uint160(ASSET_A));
        vm.prank(USER);
        facet.safeTransferFrom(USER, RECIPIENT, id, 0.5 ether, "");
        assertEq(facet.totalSupply(id), 2 ether);
        assertEq(facet.balanceOf(USER, id), 1.5 ether);
        assertEq(facet.balanceOf(RECIPIENT, id), 0.5 ether);

        vm.expectRevert();
        facet.issueFromController(USER, assets, amounts);
        vm.expectRevert();
        facet.burnFromController(USER, ASSET_A, 1);
    }

    function testControllerBurnReducesBalanceAndSupplyExactly() public {
        (address[] memory assets, uint256[] memory amounts) = _one(ASSET_A, 2 ether);
        facet.issueFromController(USER, assets, amounts);

        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareControllerOnly.selector, address(this)));
        facet.burnRecoveryShares(USER, ASSET_A, 1);

        facet.burnFromController(USER, ASSET_A, 0.75 ether);
        uint256 id = uint256(uint160(ASSET_A));
        assertEq(facet.totalSupply(id), 1.25 ether);
        assertEq(facet.balanceOf(USER, id), 1.25 ether);
    }

    function testIssueAndBurnRejectInvalidInputs() public {
        (address[] memory assets, uint256[] memory amounts) = _one(ASSET_A, 1);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryRecipientInvalid.selector, address(0)));
        facet.issueFromController(address(0), assets, amounts);

        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareLengthMismatch.selector, 1, 0));
        facet.issueFromController(USER, assets, new uint256[](0));

        assets[0] = address(0);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryAssetInvalid.selector, address(0)));
        facet.issueFromController(USER, assets, amounts);

        (assets, amounts) = _one(ASSET_A, 0);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareAmountZero.selector, ASSET_A));
        facet.issueFromController(USER, assets, amounts);

        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryRecipientInvalid.selector, address(0)));
        facet.burnFromController(address(0), ASSET_A, 1);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryAssetInvalid.selector, address(0)));
        facet.burnFromController(USER, address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareAmountZero.selector, ASSET_A));
        facet.burnFromController(USER, ASSET_A, 0);

        address unknown = address(0x8888);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareUnknown.selector, unknown));
        facet.burnFromController(USER, unknown, 1);
    }

    function _one(address asset, uint256 amount)
        private
        pure
        returns (address[] memory assets, uint256[] memory amounts)
    {
        assets = new address[](1);
        amounts = new uint256[](1);
        assets[0] = asset;
        amounts[0] = amount;
    }

    function _two(address firstAsset, address secondAsset, uint256 firstAmount, uint256 secondAmount)
        private
        pure
        returns (address[] memory assets, uint256[] memory amounts)
    {
        assets = new address[](2);
        amounts = new uint256[](2);
        assets[0] = firstAsset;
        assets[1] = secondAsset;
        amounts[0] = firstAmount;
        amounts[1] = secondAmount;
    }
}
