// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {RecoveryPoolSettlementFacet} from "../src/facets/RecoveryPoolSettlementFacet.sol";
import {ICoreRecovery} from "../src/interfaces/ICoreRecovery.sol";
import {ICoreRedemption} from "../src/interfaces/ICoreRedemption.sol";
import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibRecoveryShareStorage} from "../src/libraries/LibRecoveryShareStorage.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";
import {LibReserveLifecycleStorage} from "../src/libraries/LibReserveLifecycleStorage.sol";
import {LibReserve} from "../src/libraries/LibReserve.sol";
import {RecoveryPoolTestBase} from "./helpers/RecoveryPoolTestBase.t.sol";
import {BranchRebalanceHarness, ReserveBranchHarness} from "./mocks/BasketRegressionMocks.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

contract UnavailableBalanceToken {}

/// @dev Debits the payer exactly while crediting the reserve one unit short.
contract ReserveUndercreditInputToken is IERC20 {
    uint256 public override totalSupply;
    mapping(address account => uint256 balance) private _balances;
    mapping(address owner => mapping(address spender => uint256 amount)) public override allowance;

    function mint(address account, uint256 amount) external {
        _balances[account] += amount;
        totalSupply += amount;
        emit Transfer(address(0), account, amount);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[recipient] += amount;
        emit Transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[sender][msg.sender];
        if (allowed != type(uint256).max) allowance[sender][msg.sender] = allowed - amount;
        _balances[sender] -= amount;
        _balances[recipient] += amount - 1;
        totalSupply -= 1;
        emit Transfer(sender, recipient, amount - 1);
        return true;
    }
}

    contract MutableLifecycleRebalanceHarness is BranchRebalanceHarness {
        function setLifecycle(address asset, IRecoveryTypes.ReserveLifecycle lifecycle) external {
            LibReserveLifecycleStorage.getLayout().records[asset].lifecycle = lifecycle;
        }
    }

    contract RecoveryPoolGuardHarness is RecoveryPoolSettlementFacet {
        function seedResolvedPool(address asset, uint256 externalSupply) external {
            LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
            pool.impaired = false;
            pool.coreAttachedShares = 0;
            pool.redeemableRaw = externalSupply;
            LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))] = externalSupply;
        }

        function totalSupply(uint256 shareId) external view returns (uint256) {
            return LibRecoveryShareStorage.getLayout().supply[shareId];
        }

        function burnRecoveryShares(address, address asset, uint256 amount) external {
            LibRecoveryShareStorage.getLayout().supply[uint256(uint160(asset))] -= amount;
        }
    }

    contract WS1RebalanceAndReserveCoverageTest is Test {
        function test_rebalanceRejectsInexactReserveCreditAfterExactPayerDebit() public {
            BranchRebalanceHarness harness = new BranchRebalanceHarness();
            ReserveUndercreditInputToken input = new ReserveUndercreditInputToken();
            MockERC20 output = new MockERC20("Output", "OUT", 18);
            input.mint(address(this), 10);
            input.approve(address(harness), 10);

            vm.expectRevert(abi.encodeWithSelector(ICoreTypes.UnderDelivery.selector, address(input), 10, 9));
            harness.executeExternal(address(input), address(output), 10, 0);
        }

        function test_rebalanceExecutionRejectsUnreadableInputBalance() public {
            BranchRebalanceHarness harness = new BranchRebalanceHarness();
            UnavailableBalanceToken input = new UnavailableBalanceToken();
            MockERC20 output = new MockERC20("Output", "OUT", 18);

            vm.expectRevert(
                abi.encodeWithSelector(IRecoveryTypes.ReserveBalanceProbeUnavailable.selector, address(input))
            );
            harness.executeExternal(address(input), address(output), 1, 0);
        }

        function test_rebalanceQuoteRejectsUnreadableInputCustody() public {
            MutableLifecycleRebalanceHarness harness = new MutableLifecycleRebalanceHarness();
            UnavailableBalanceToken input = new UnavailableBalanceToken();
            MockERC20 output = new MockERC20("Output", "OUT", 18);
            harness.setBasketManual(
                _addresses(address(input), address(output)), _uints(500_000, 500_000), _uints(1e18, 1e18)
            );

            vm.expectRevert(
                abi.encodeWithSelector(IRecoveryTypes.ReserveBalanceProbeUnavailable.selector, address(input))
            );
            harness.previewRebalanceSwapExactIn(address(input), address(output), 1);
        }

        function test_rebalanceQuoteRejectsInactiveBasketInput() public {
            MutableLifecycleRebalanceHarness harness = new MutableLifecycleRebalanceHarness();
            MockERC20 input = new MockERC20("Input", "IN", 18);
            MockERC20 output = new MockERC20("Output", "OUT", 18);
            harness.setBasketManual(
                _addresses(address(input), address(output)), _uints(500_000, 500_000), _uints(1e18, 1e18)
            );
            harness.setLifecycle(address(input), IRecoveryTypes.ReserveLifecycle.Inactive);

            vm.expectRevert(
                abi.encodeWithSelector(
                    IRecoveryTypes.ReserveLifecycleInvalid.selector,
                    address(input),
                    IRecoveryTypes.ReserveLifecycle.Active,
                    IRecoveryTypes.ReserveLifecycle.Inactive
                )
            );
            harness.previewRebalanceSwapExactIn(address(input), address(output), 1);
        }

        function test_libReserveRejectsUnreadableReserveBalance() public {
            ReserveBranchHarness harness = new ReserveBranchHarness();
            UnavailableBalanceToken token = new UnavailableBalanceToken();

            vm.expectRevert(
                abi.encodeWithSelector(IRecoveryTypes.ReserveBalanceProbeUnavailable.selector, address(token))
            );
            harness.transferOutExternal(address(token), address(this), 1);
        }

        function _addresses(address first, address second) private pure returns (address[] memory values) {
            values = new address[](2);
            values[0] = first;
            values[1] = second;
        }

        function _uints(uint256 first, uint256 second) private pure returns (uint256[] memory values) {
            values = new uint256[](2);
            values[0] = first;
            values[1] = second;
        }
    }

    contract WS1RecoveryPoolSettlementGuardCoverageTest is Test {
        address private constant RECIPIENT = address(0xCAFE);

        function test_recoveryPoolSettlementRejectsZeroRecipientAssetAndShares() public {
            RecoveryPoolGuardHarness harness = new RecoveryPoolGuardHarness();
            MockERC20 asset = new MockERC20("Asset", "ASSET", 18);

            vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryRecipientInvalid.selector, address(0)));
            harness.redeemRecoveryShares(address(asset), 1, address(0), 0);

            vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryAssetInvalid.selector, address(0)));
            harness.redeemRecoveryShares(address(0), 1, RECIPIENT, 0);

            vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareAmountZero.selector, address(asset)));
            harness.redeemRecoveryShares(address(asset), 0, RECIPIENT, 0);
        }

        function test_recoveryPoolSettlementRejectsSharesAboveOrWithoutExternalSupply() public {
            RecoveryPoolGuardHarness harness = new RecoveryPoolGuardHarness();
            MockERC20 asset = new MockERC20("Asset", "ASSET", 18);
            harness.seedResolvedPool(address(asset), 1);

            vm.expectRevert(
                abi.encodeWithSelector(IRecoveryTypes.RecoveryShareSupplyInvariant.selector, address(asset), 1, 2)
            );
            harness.redeemRecoveryShares(address(asset), 2, RECIPIENT, 0);

            RecoveryPoolGuardHarness emptyHarness = new RecoveryPoolGuardHarness();
            vm.expectRevert(
                abi.encodeWithSelector(IRecoveryTypes.RecoveryShareSupplyInvariant.selector, address(asset), 0, 1)
            );
            emptyHarness.redeemRecoveryShares(address(asset), 1, RECIPIENT, 0);
        }
    }

    contract WS1IssuanceAndRecoveryRedemptionCoverageTest is RecoveryPoolTestBase {
        function setUp() public override {
            super.setUp();
            config.setIssuanceFeePpm(1_000, 0);
            config.setRedemptionFeePpm(1_000, 0);
            _seedReserveForRedemption();
            _activateRecovery(address(tokA));
        }

        function test_safeIssueRejectsZeroOutputDuringImpairment() public {
            vm.expectRevert(ICoreTypes.ValueMustBeGreaterThanZero.selector);
            issuance.safeIssue(0, new address[](0), new uint256[](0));
        }

        function test_mixedRedemptionRejectsMissingShareMintAtomically() public {
            ICoreRedemption.RedemptionQuote memory quote = preview.previewRedeemExactIn(0.5 ether);
            ICoreRedemption.TokenAmount memory recoveryOutput = quote.outputs[quote.outputs.length - 1];
            assertEq(uint256(recoveryOutput.kind), uint256(ICoreRedemption.TokenKind.ERC1155));
            assertGt(recoveryOutput.amount, 0);
            address[] memory recoveryAssets = new address[](1);
            recoveryAssets[0] = address(uint160(recoveryOutput.id));
            uint256[] memory recoveryAmounts = new uint256[](1);
            recoveryAmounts[0] = recoveryOutput.amount;
            vm.mockCall(
                diamond,
                abi.encodeCall(ICoreRecovery.issueRecoveryShares, (user, recoveryAssets, recoveryAmounts)),
                bytes("")
            );

            vm.expectRevert(
                abi.encodeWithSelector(
                    IRecoveryTypes.RecoveryShareSupplyInvariant.selector, address(tokA), recoveryOutput.amount, 0
                )
            );
            vm.prank(user);
            redemption.redeem(quote.grossCygldIn);
        }
    }
