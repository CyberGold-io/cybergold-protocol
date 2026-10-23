// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockStakingDiamond} from "../helpers/MockStakingDiamond.sol";
import {Sleeve4626} from "../../src/sleeves/Sleeve4626.sol";
import {MockVault4626} from "staking-mocks/MockVault4626.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {SleeveDeployerHelper} from "../../src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "../../src/deploy/SleeveRequestBuilder.sol";

contract DustVault4626 is MockVault4626 {
    constructor(IERC20 asset_) MockVault4626(asset_) {}

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        uint256 accepted = assets - 1;
        require(IERC20(asset()).transferFrom(msg.sender, address(this), accepted), "transfer failed");
        shares = accepted;
        _mint(receiver, shares);
    }
}

contract ZeroConvertVault4626 is MockVault4626 {
    bool internal zeroConversions;

    constructor(IERC20 asset_) MockVault4626(asset_) {}

    function setZeroConversions(bool value) external {
        zeroConversions = value;
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        if (zeroConversions) return 0;
        return super.convertToAssets(shares);
    }
}

contract InflatedPreviewVault4626 is MockVault4626 {
    bool internal inflatePreview;

    constructor(IERC20 asset_) MockVault4626(asset_) {}

    function setInflatePreview(bool value) external {
        inflatePreview = value;
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 preview = super.previewDeposit(assets);
        return inflatePreview ? preview + 1_000_000 ether : preview;
    }
}

contract Sleeve4626Test is Test {
    MockERC20 internal asset;
    MockVault4626 internal vault;
    MockStakingDiamond internal stakingDiamond;
    Sleeve4626 internal sleeve;

    address internal admin = address(this);

    function setUp() public {
        asset = new MockERC20("Asset", "AST", 18);
        vault = new MockVault4626(asset);

        stakingDiamond = new MockStakingDiamond(admin, address(0x5AFE));

        SleeveDeployerHelper.SleeveRequest memory req =
            SleeveRequestBuilder.erc4626(address(new Sleeve4626()), address(asset), address(vault), true, 0);
        sleeve = Sleeve4626(
            SleeveDeployerHelper.deployDeterministic(
                address(stakingDiamond), req, keccak256("Sleeve4626Test")
            )
        );

        stakingDiamond.setSleeveCaller(address(sleeve), true);
    }

    function test_initialize_revertsOnVaultAssetMismatch() public {
        MockERC20 otherAsset = new MockERC20("Other", "OTH", 6);
        Sleeve4626 implementation = new Sleeve4626();

        vm.expectRevert(
            abi.encodeWithSelector(Sleeve4626.VaultAssetMismatch.selector, address(asset), address(otherAsset))
        );
        new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                Sleeve4626.initialize, (address(stakingDiamond), address(otherAsset), 0, address(vault), true, false)
            )
        );
    }

    function test_allocateDepositsIntoVault() public {
        asset.mint(address(stakingDiamond), 1_000 ether);

        vm.prank(address(stakingDiamond));
        uint256 used = sleeve.allocate(400 ether, "");

        assertEq(used, 400 ether);
        assertEq(sleeve.principalAssets(), 400 ether);
        assertEq(asset.balanceOf(address(stakingDiamond)), 600 ether);
        assertEq(IERC20(address(vault)).balanceOf(address(sleeve)), vault.convertToShares(400 ether));
        assertEq(asset.balanceOf(address(vault)), 400 ether);
        assertEq(sleeve.totalAssets(), 400 ether);
    }

    function test_allocateReturnsDustToCustodyAndExcludesPrincipal() public {
        DustVault4626 dustVault = new DustVault4626(asset);
        Sleeve4626 dustSleeve = _deploySleeveWithVault(address(dustVault));

        asset.mint(address(stakingDiamond), 10 ether);

        vm.prank(address(stakingDiamond));
        uint256 used = dustSleeve.allocate(10 ether, "");

        assertEq(used, 10 ether - 1);
        assertEq(dustSleeve.principalAssets(), used);
        assertEq(asset.balanceOf(address(stakingDiamond)), 1);
        assertEq(asset.balanceOf(address(dustSleeve)), 0);
    }

    function test_deallocateWithdrawsFromVault() public {
        asset.mint(address(stakingDiamond), 1_000 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(500 ether, "");

        vm.prank(address(stakingDiamond));
        uint256 returned = sleeve.deallocate(200 ether, "");

        assertEq(returned, 200 ether);
        assertEq(asset.balanceOf(address(stakingDiamond)), 700 ether);
        assertEq(sleeve.principalAssets(), 300 ether);
        assertEq(IERC20(address(vault)).balanceOf(address(sleeve)), vault.convertToShares(300 ether));
    }

    function test_deallocateUsesIdleAssetsBeforeVaultAndReturnsEarly() public {
        asset.mint(address(stakingDiamond), 100 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(100 ether, "");

        asset.mint(address(sleeve), 10 ether);

        vm.prank(address(stakingDiamond));
        uint256 returned = sleeve.deallocate(5 ether, "");

        assertEq(returned, 5 ether);
        assertEq(asset.balanceOf(address(stakingDiamond)), 5 ether);
        assertEq(asset.balanceOf(address(sleeve)), 5 ether);
        assertEq(IERC20(address(vault)).balanceOf(address(sleeve)), vault.convertToShares(100 ether));
    }

    function test_deallocateReturnsZeroWithoutIdleOrShares() public {
        vm.prank(address(stakingDiamond));
        uint256 returned = sleeve.deallocate(5 ether, "");

        assertEq(returned, 0);
        assertEq(sleeve.principalAssets(), 0);
    }

    function test_deallocateReturnsZeroWhenVaultAssetsAreZero() public {
        ZeroConvertVault4626 zeroVault = new ZeroConvertVault4626(asset);
        Sleeve4626 zeroSleeve = _deploySleeveWithVault(address(zeroVault));

        asset.mint(address(stakingDiamond), 100 ether);
        vm.prank(address(stakingDiamond));
        zeroSleeve.allocate(100 ether, "");

        zeroVault.setZeroConversions(true);

        vm.prank(address(stakingDiamond));
        uint256 returned = zeroSleeve.deallocate(10 ether, "");

        assertEq(returned, 0);
        assertEq(zeroSleeve.principalAssets(), 100 ether);
    }

    function test_deallocateCapsAtAvailableAssets() public {
        asset.mint(address(stakingDiamond), 800 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(300 ether, "");

        vm.prank(address(stakingDiamond));
        uint256 returned = sleeve.deallocate(600 ether, "");

        assertEq(returned, 300 ether);
        assertEq(sleeve.principalAssets(), 0);
        assertEq(asset.balanceOf(address(stakingDiamond)), 800 ether);
    }

    function test_totalAssetsIncludesIdle() public {
        asset.mint(address(stakingDiamond), 500 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(300 ether, "");

        asset.mint(address(sleeve), 50 ether);
        assertEq(sleeve.totalAssets(), 350 ether);
    }

    function test_harvestSendsProfit() public {
        asset.mint(address(stakingDiamond), 1_000 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(500 ether, "");

        asset.mint(address(this), 120 ether);
        asset.approve(address(vault), 120 ether);
        vault.donate(120 ether);

        uint256 controllerBalanceBefore = asset.balanceOf(address(stakingDiamond));

        vm.prank(address(stakingDiamond));
        uint256 profit = sleeve.harvest("");

        assertEq(profit, 120 ether);
        assertEq(asset.balanceOf(address(stakingDiamond)) - controllerBalanceBefore, 120 ether);
        assertEq(sleeve.principalAssets(), 500 ether);
        assertEq(IERC20(address(vault)).balanceOf(address(sleeve)), vault.convertToShares(500 ether));
    }

    function test_harvestNoProfitReturnsZero() public {
        asset.mint(address(stakingDiamond), 100 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(100 ether, "");

        vm.prank(address(stakingDiamond));
        uint256 profit = sleeve.harvest("");

        assertEq(profit, 0);
        assertEq(sleeve.principalAssets(), 100 ether);
    }

    function test_harvestIdleOnlyProfitReturnsAfterIdle() public {
        asset.mint(address(sleeve), 10 ether);

        vm.prank(address(stakingDiamond));
        uint256 profit = sleeve.harvest("");

        assertEq(profit, 10 ether);
        assertEq(asset.balanceOf(address(stakingDiamond)), 10 ether);
    }

    function test_harvestClipsPrincipalSharesWhenPreviewExceedsBalance() public {
        InflatedPreviewVault4626 inflatedVault = new InflatedPreviewVault4626(asset);
        Sleeve4626 inflatedSleeve = _deploySleeveWithVault(address(inflatedVault));

        asset.mint(address(stakingDiamond), 100 ether);
        vm.prank(address(stakingDiamond));
        inflatedSleeve.allocate(100 ether, "");

        asset.mint(address(this), 10 ether);
        asset.approve(address(inflatedVault), 10 ether);
        inflatedVault.donate(10 ether);
        inflatedVault.setInflatePreview(true);

        vm.prank(address(stakingDiamond));
        uint256 profit = inflatedSleeve.harvest("");

        assertEq(profit, 0);
        assertEq(asset.balanceOf(address(stakingDiamond)), 0);
    }

    function test_harvestUsesIdleBeforeRedeemingShares() public {
        asset.mint(address(stakingDiamond), 1_000 ether);
        vm.prank(address(stakingDiamond));
        sleeve.allocate(500 ether, "");

        asset.mint(address(sleeve), 40 ether);
        asset.mint(address(this), 60 ether);
        asset.approve(address(vault), 60 ether);
        vault.donate(60 ether);

        uint256 controllerBalanceBefore = asset.balanceOf(address(stakingDiamond));

        vm.prank(address(stakingDiamond));
        uint256 profit = sleeve.harvest("");

        assertEq(profit, 100 ether);
        assertEq(asset.balanceOf(address(stakingDiamond)) - controllerBalanceBefore, 100 ether);
        assertEq(sleeve.principalAssets(), 500 ether);
        // Only 60 assets should have been withdrawn from the vault, leaving principal backing intact.
        assertEq(IERC20(address(vault)).balanceOf(address(sleeve)), vault.convertToShares(500 ether));
    }

    function _deploySleeveWithVault(address vaultAddr) internal returns (Sleeve4626 proxy) {
        Sleeve4626 implementation = new Sleeve4626();
        proxy = Sleeve4626(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        Sleeve4626.initialize, (address(stakingDiamond), address(asset), 0, vaultAddr, true, false)
                    )
                )
            )
        );
        stakingDiamond.setSleeveCaller(address(proxy), true);
    }
}
