// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {RecoveryPoolSettlementFacet} from "../src/facets/RecoveryPoolSettlementFacet.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibRecoveryPoolSettlement} from "../src/libraries/LibRecoveryPoolSettlement.sol";
import {LibRecoveryShareStorage} from "../src/libraries/LibRecoveryShareStorage.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {LibReserveLifecycleStorage} from "../src/libraries/LibReserveLifecycleStorage.sol";

contract RecoveryPoolSettlementHarness is RecoveryPoolSettlementFacet {
    mapping(address asset => mapping(address account => uint256 shares)) private _balances;
    bool private _corruptBurn;

    function seedPool(address asset, address holder, uint256 supply, uint256 nominalRaw) external {
        LibRecoveryStorage.RecoveryPool storage poolData = LibRecoveryStorage.getLayout().pools[asset];
        poolData.impaired = false;
        poolData.coreAttachedShares = 0;
        poolData.redeemableRaw = nominalRaw;
        LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))] = supply;
        _balances[asset][holder] = supply;
        LibReserveLifecycleStorage.getLayout().records[asset].lifecycle = IRecoveryTypes.ReserveLifecycle.Inactive;
    }

    function totalSupply(uint256 shareId) external view returns (uint256) {
        return LibRecoveryShareStorage.getLayout().supply[shareId];
    }

    function shareBalance(address asset, address account) external view returns (uint256) {
        return _balances[asset][account];
    }

    function burnRecoveryShares(address account, address asset, uint256 amount) external {
        if (msg.sender != address(this)) revert RecoveryShareControllerOnly(msg.sender);
        uint256 debited = _corruptBurn ? amount - 1 : amount;
        _balances[asset][account] -= debited;
        LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))] -= debited;
    }

    function pool(address asset) external view returns (LibRecoveryStorage.RecoveryPool memory) {
        return LibRecoveryStorage.getLayout().pools[asset];
    }

    function setPoolState(address asset, bool impaired, uint256 coreAttachedShares) external {
        LibRecoveryStorage.RecoveryPool storage poolData = LibRecoveryStorage.getLayout().pools[asset];
        poolData.impaired = impaired;
        poolData.coreAttachedShares = coreAttachedShares;
    }

    function setExitEntitlement(address asset, uint256 raw) external {
        LibReserveLifecycleStorage.getLayout().records[asset].lifecycle = IRecoveryTypes.ReserveLifecycle.Exiting;
        LibReserveLifecycleStorage.getLayout().records[asset].exitEntitlementRaw = raw;
    }

    function setCorruptBurn(bool value) external {
        _corruptBurn = value;
    }

    function preview(address asset, uint256 shares) external view returns (uint256) {
        LibRecoveryStorage.RecoveryPool storage poolData = LibRecoveryStorage.getLayout().pools[asset];
        uint256 supply = LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))];
        return LibRecoveryPoolSettlement.quote(asset, poolData, supply, shares).rawOut;
    }
}

contract ExactSettlementToken {
    mapping(address account => uint256 balance) internal _balances;

    function mint(address account, uint256 amount) external {
        _balances[account] += amount;
    }

    function balanceOf(address account) external view virtual returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) external virtual returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[recipient] += amount;
        return true;
    }
}

contract FeeOnTransferSettlementToken is ExactSettlementToken {
    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[recipient] += amount - 1;
        return true;
    }
}

contract MissingBalanceProbeSettlementToken {
    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract RecoveryPoolSettlementUnitTest is Test {
    address internal constant HOLDER = address(0xBEEF);
    address internal constant RECIPIENT = address(0xCAFE);

    function test_deficitSettlementHaircutsLivePayoutAndReleasesNominalLiability() public {
        (RecoveryPoolSettlementHarness settlement, ExactSettlementToken asset) = _seed(1_000, 1_000, 600);
        settlement.setExitEntitlement(address(asset), 400);

        vm.prank(HOLDER);
        assertEq(settlement.redeemRecoveryShares(address(asset), 250, RECIPIENT, 0), 150);
        assertEq(settlement.pool(address(asset)).redeemableRaw, 750);
        assertEq(settlement.totalSupply(uint256(uint160(address(asset)))), 750);
        assertEq(asset.balanceOf(address(settlement)), 450);
        assertEq(asset.balanceOf(RECIPIENT), 150);

        vm.prank(HOLDER);
        assertEq(settlement.redeemRecoveryShares(address(asset), 750, RECIPIENT, 0), 450);
        assertEq(settlement.pool(address(asset)).redeemableRaw, 0);
        assertEq(settlement.totalSupply(uint256(uint160(address(asset)))), 0);
        assertEq(asset.balanceOf(RECIPIENT), 600);
    }

    function test_finalHolderClearsNominalRemainderSeparatelyFromPayout() public {
        (RecoveryPoolSettlementHarness settlement, ExactSettlementToken asset) = _seed(12, 11, 10);
        vm.prank(HOLDER);
        assertEq(settlement.redeemRecoveryShares(address(asset), 2, RECIPIENT, 0), 1);
        assertEq(settlement.pool(address(asset)).redeemableRaw, 10);
        vm.prank(HOLDER);
        assertEq(settlement.redeemRecoveryShares(address(asset), 10, RECIPIENT, 0), 9);
        assertEq(settlement.pool(address(asset)).redeemableRaw, 0);
    }

    function test_surplusIsCappedAtNominalLiability() public {
        (RecoveryPoolSettlementHarness settlement, ExactSettlementToken asset) = _seed(1_000, 1_000, 1_200);
        vm.prank(HOLDER);
        assertEq(settlement.redeemRecoveryShares(address(asset), 250, RECIPIENT, 0), 250);
        assertEq(settlement.pool(address(asset)).redeemableRaw, 750);
        assertEq(asset.balanceOf(address(settlement)), 950);
    }

    function test_laterDonationBenefitsOnlyRemainingShares() public {
        (RecoveryPoolSettlementHarness settlement, ExactSettlementToken asset) = _seed(1_000, 1_000, 600);
        vm.prank(HOLDER);
        assertEq(settlement.redeemRecoveryShares(address(asset), 250, RECIPIENT, 0), 150);
        asset.mint(address(settlement), 300);
        vm.prank(HOLDER);
        assertEq(settlement.redeemRecoveryShares(address(asset), 750, RECIPIENT, 0), 750);
    }

    function test_unreadablePreviewIsZeroAndExecutionRollsBack() public {
        RecoveryPoolSettlementHarness settlement = new RecoveryPoolSettlementHarness();
        MissingBalanceProbeSettlementToken asset = new MissingBalanceProbeSettlementToken();
        settlement.seedPool(address(asset), HOLDER, 10, 10);
        assertEq(settlement.preview(address(asset), 1), 0);
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.ReserveBalanceProbeUnavailable.selector, address(asset)));
        settlement.redeemRecoveryShares(address(asset), 1, RECIPIENT, 0);
        assertEq(settlement.pool(address(asset)).redeemableRaw, 10);
        assertEq(settlement.shareBalance(address(asset), HOLDER), 10);
    }

    function test_zeroRealizableOutputRevertsBeforeBurn() public {
        (RecoveryPoolSettlementHarness settlement, ExactSettlementToken asset) = _seed(10, 10, 0);
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareOutputZero.selector, address(asset), 1));
        settlement.redeemRecoveryShares(address(asset), 1, RECIPIENT, 0);
        assertEq(settlement.shareBalance(address(asset), HOLDER), 10);
        assertEq(settlement.pool(address(asset)).redeemableRaw, 10);
    }

    function test_resolvedPoolPredicatesAndMinimumAreCurrentStateGuards() public {
        (RecoveryPoolSettlementHarness settlement, ExactSettlementToken asset) = _seed(10, 10, 10);
        settlement.setPoolState(address(asset), true, 0);
        assertEq(settlement.preview(address(asset), 1), 1);
        settlement.setPoolState(address(asset), false, 1);
        vm.prank(HOLDER);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryPoolAccountingInvariant.selector, address(asset), 0, 1)
        );
        settlement.redeemRecoveryShares(address(asset), 1, RECIPIENT, 0);
        settlement.setPoolState(address(asset), false, 0);
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryMinimumNotMet.selector, 2, 1));
        settlement.redeemRecoveryShares(address(asset), 1, RECIPIENT, 2);
    }

    function test_inexactDeliveryAndCorruptBurnRollBackEverything() public {
        RecoveryPoolSettlementHarness inexact = new RecoveryPoolSettlementHarness();
        FeeOnTransferSettlementToken feeAsset = new FeeOnTransferSettlementToken();
        feeAsset.mint(address(inexact), 10);
        inexact.seedPool(address(feeAsset), HOLDER, 10, 10);
        vm.prank(HOLDER);
        vm.expectRevert();
        inexact.redeemRecoveryShares(address(feeAsset), 5, RECIPIENT, 0);
        assertEq(inexact.pool(address(feeAsset)).redeemableRaw, 10);
        assertEq(inexact.shareBalance(address(feeAsset), HOLDER), 10);

        (RecoveryPoolSettlementHarness corrupt, ExactSettlementToken exact) = _seed(10, 10, 10);
        corrupt.setCorruptBurn(true);
        vm.prank(HOLDER);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryTypes.RecoveryShareSupplyInvariant.selector, address(exact), 5, 6)
        );
        corrupt.redeemRecoveryShares(address(exact), 5, RECIPIENT, 0);
        assertEq(corrupt.pool(address(exact)).redeemableRaw, 10);
    }

    function test_eventReportsLiabilityReleasedSeparately() public {
        (RecoveryPoolSettlementHarness settlement, ExactSettlementToken asset) = _seed(1_000, 1_000, 600);
        vm.recordLogs();
        vm.prank(HOLDER);
        settlement.redeemRecoveryShares(address(asset), 250, RECIPIENT, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory redeemed = logs[0];
        assertEq(
            redeemed.topics[0], keccak256("RecoverySharesRedeemed(address,address,address,uint256,uint256,uint256)")
        );
        assertEq(redeemed.data, abi.encode(uint256(250), uint256(250), uint256(150)));
    }

    function _seed(uint256 supply, uint256 nominalRaw, uint256 liveRaw)
        private
        returns (RecoveryPoolSettlementHarness settlement, ExactSettlementToken asset)
    {
        assertLe(nominalRaw, supply, "healthy nominal liability must fit native share cap");
        settlement = new RecoveryPoolSettlementHarness();
        asset = new ExactSettlementToken();
        asset.mint(address(settlement), liveRaw);
        settlement.seedPool(address(asset), HOLDER, supply, nominalRaw);
    }
}
