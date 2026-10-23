// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {IRecoveryShareOutflowCallback} from "cybergold-core/interfaces/IRecoveryShareOutflowCallback.sol";
import {RecoveryFundCoreMock, RecoveryFundTestRouter, RecoveryFundTestToken} from "../facets/RecoveryFundFacet.t.sol";
import {RecoveryFundFacet} from "../../src/facets/RecoveryFundFacet.sol";
import {RecoveryFundLensFacet} from "../../src/facets/RecoveryFundLensFacet.sol";
import {IRecoveryFundTypes} from "../../src/interfaces/IRecoveryFundTypes.sol";
import {LibRecoveryFundMath} from "../../src/libraries/LibRecoveryFundMath.sol";

contract RecoveryFundAccountingHandler is ERC1155Holder, IRecoveryShareOutflowCallback {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant INITIAL_CYGLD_BALANCE = 500 ether;
    uint256 internal constant GENERATION_COVERAGE = 100 ether;
    uint256 internal constant GENERATION_COMMITMENT = 95 ether;
    uint64 internal constant MAX_GENERATIONS = 4;
    address internal constant ALLOWANCE_SPENDER = address(0xA110);
    address internal constant OUTFLOW_RECIPIENT = address(0xB0B);

    RecoveryFundCoreMock public immutable core;
    RecoveryFundTestRouter public immutable router;
    RecoveryFundFacet public immutable fund;
    RecoveryFundLensFacet public immutable lens;
    RecoveryFundTestToken public immutable impaired;
    address public immutable impairedAsset;
    uint256 public immutable shareId;

    uint64 public currentGeneration = 1;
    uint256 public soldThisGeneration;
    uint256 public expectedGovernanceShares;
    uint256 public remainingCommitment = GENERATION_COMMITMENT;
    uint256 public cumulativeCygldPayout;
    uint256 public cumulativeDiscretionaryOutflow;
    uint256 public cumulativeRedeemedShares;
    uint256 public cumulativeRedeemedRaw;
    uint256 public failedOperationAttempts;
    bool public resolutionPrepared;
    bool public validOperationFailed;
    bool public failedOperationMutatedState;

    constructor(
        RecoveryFundCoreMock core_,
        RecoveryFundTestRouter router_,
        RecoveryFundLensFacet lens_,
        RecoveryFundTestToken impaired_
    ) {
        core = core_;
        router = router_;
        fund = RecoveryFundFacet(address(router_));
        lens = lens_;
        impaired = impaired_;
        impairedAsset = address(impaired_);
        shareId = uint256(uint160(address(impaired_)));
    }

    function purchase(uint256 seed) external {
        if (router.paused()) return;
        IRecoveryFundTypes.AssetRecoveryFundView memory facility = lens.assetRecoveryFund(impairedAsset);
        if (facility.coverageShares == 0) return;
        uint256 remaining = facility.coverageShares - facility.purchasedShares;
        if (remaining == 0) return;
        _purchase(1 + seed % remaining);
    }

    function exhaustFacility() external {
        if (router.paused()) return;
        IRecoveryFundTypes.AssetRecoveryFundView memory facility = lens.assetRecoveryFund(impairedAsset);
        if (facility.coverageShares == 0) return;
        uint256 remaining = facility.coverageShares - facility.purchasedShares;
        if (remaining != 0) _purchase(remaining);
    }

    function setSafeAllowance(uint256 seed) external {
        (uint256 balance,, uint256 committed) = lens.recoveryFundTreasuryStatus();
        uint256 maximum = balance - committed;
        uint256 allowance = router.paused() ? 0 : seed % (maximum + 1);
        try router.sovereignApproveCygld(address(core), ALLOWANCE_SPENDER, allowance) {}
        catch {
            validOperationFailed = true;
        }
    }

    function transferUncommittedCygld(uint256 seed) external {
        if (router.paused()) return;
        (uint256 balance, uint256 exposure, uint256 committed) = lens.recoveryFundTreasuryStatus();
        uint256 maximum = balance - exposure - committed;
        if (maximum == 0) return;
        uint256 amount = 1 + seed % maximum;
        try router.sovereignTransferCygld(address(core), OUTFLOW_RECIPIENT, amount) {
            cumulativeDiscretionaryOutflow += amount;
        } catch {
            validOperationFailed = true;
        }
    }

    function pause() external {
        if (!router.paused()) router.pauseGovernance();
    }

    function unpause() external {
        if (router.paused()) router.unpauseGovernance();
    }

    function attemptInvalidPurchase(uint256 seed) external {
        IRecoveryFundTypes.AssetRecoveryFundView memory facility = lens.assetRecoveryFund(impairedAsset);
        if (facility.coverageShares == 0 || core.balanceOf(address(this), shareId) == 0) return;

        bytes32 beforeHash = _accountingStateHash();
        uint256 variant = seed % 3;
        bytes memory callbackData;
        if (variant == 0) {
            uint64 staleGeneration = facility.generation == 0 ? 0 : facility.generation - 1;
            callbackData = abi.encode(
                IRecoveryFundTypes.RecoveryFundPurchaseCallback({
                    expectedGeneration: staleGeneration, minimumCygldOut: 0
                })
            );
        } else if (variant == 1) {
            callbackData = abi.encode(
                IRecoveryFundTypes.RecoveryFundPurchaseCallback({
                    expectedGeneration: facility.generation, minimumCygldOut: type(uint256).max
                })
            );
        } else {
            callbackData = hex"01";
        }

        try core.safeTransferFrom(address(this), address(router), shareId, 1, callbackData) {
            failedOperationMutatedState = true;
        } catch {
            ++failedOperationAttempts;
            if (_accountingStateHash() != beforeHash) failedOperationMutatedState = true;
        }
    }

    function attemptInsolventAllowance(uint256 seed) external {
        (uint256 balance,, uint256 committed) = lens.recoveryFundTreasuryStatus();
        uint256 maximum = balance - committed;
        uint256 attempted = maximum + 1 + seed % 3;
        bytes32 beforeHash = _accountingStateHash();
        try router.sovereignApproveCygld(address(core), ALLOWANCE_SPENDER, attempted) {
            failedOperationMutatedState = true;
        } catch {
            ++failedOperationAttempts;
            if (_accountingStateHash() != beforeHash) failedOperationMutatedState = true;
        }
    }

    function attemptInsolventOutflow() external {
        if (router.paused()) return;
        (uint256 balance, uint256 exposure, uint256 committed) = lens.recoveryFundTreasuryStatus();
        uint256 maximum = balance - exposure - committed;
        if (maximum == balance) return;
        bytes32 beforeHash = _accountingStateHash();
        try router.sovereignTransferCygld(address(core), OUTFLOW_RECIPIENT, maximum + 1) {
            failedOperationMutatedState = true;
        } catch {
            ++failedOperationAttempts;
            if (_accountingStateHash() != beforeHash) failedOperationMutatedState = true;
        }
    }

    function directCoreRedemption(uint256 seed) external {
        if (router.paused()) return;
        IRecoveryFundTypes.AssetRecoveryFundView memory facility = lens.assetRecoveryFund(impairedAsset);
        uint256 inventory = core.balanceOf(address(router), shareId);
        if (facility.coverageShares != 0 || inventory == 0) return;

        if (!resolutionPrepared) {
            impaired.mint(address(core), inventory);
            core.makeResolved(impairedAsset, inventory);
            resolutionPrepared = true;
        }

        uint256 shares = 1 + seed % inventory;
        uint256 rawBefore = impaired.balanceOf(address(router));
        try router.sovereignRedeemRecoveryShares(core, impairedAsset, shares, address(router), 1) returns (
            uint256 rawOut
        ) {
            cumulativeRedeemedShares += shares;
            cumulativeRedeemedRaw += rawOut;
            expectedGovernanceShares -= shares;
            if (impaired.balanceOf(address(router)) != rawBefore + rawOut) validOperationFailed = true;
            if (core.balanceOf(address(router), shareId) == 0) resolutionPrepared = false;
        } catch {
            validOperationFailed = true;
        }
    }

    function reactivate() external {
        if (router.paused() || resolutionPrepared || currentGeneration >= MAX_GENERATIONS) return;
        IRecoveryFundTypes.AssetRecoveryFundView memory facility = lens.assetRecoveryFund(impairedAsset);
        if (facility.coverageShares != 0 || core.balanceOf(address(router), shareId) != 0) return;

        (uint256 balance, uint256 exposure,) = lens.recoveryFundTreasuryStatus();
        if (balance - exposure < GENERATION_COMMITMENT) return;

        core.configurePool(impairedAsset, address(this), 0, GENERATION_COVERAGE, true, 0);
        IRecoveryFundTypes.AssetRecoveryFundActivation memory request = IRecoveryFundTypes.AssetRecoveryFundActivation({
            impairedAsset: impairedAsset,
            expectedNextGeneration: currentGeneration + 1,
            expectedCoverageShares: GENERATION_COVERAGE,
            cygldCommitment: GENERATION_COMMITMENT
        });
        VM.prank(address(router));
        try fund.activateAssetRecoveryFund(request) {
            ++currentGeneration;
            soldThisGeneration = 0;
            remainingCommitment = GENERATION_COMMITMENT;
        } catch {
            validOperationFailed = true;
        }
    }

    function attemptStaleGenerationAfterReactivation() external {
        IRecoveryFundTypes.AssetRecoveryFundView memory facility = lens.assetRecoveryFund(impairedAsset);
        if (
            facility.coverageShares == 0 || facility.generation < 2 || core.balanceOf(address(this), shareId) == 0
                || router.paused()
        ) return;
        bytes32 beforeHash = _accountingStateHash();
        bytes memory callbackData = abi.encode(
            IRecoveryFundTypes.RecoveryFundPurchaseCallback({
                expectedGeneration: facility.generation - 1, minimumCygldOut: 0
            })
        );
        try core.safeTransferFrom(address(this), address(router), shareId, 1, callbackData) {
            failedOperationMutatedState = true;
        } catch {
            ++failedOperationAttempts;
            if (_accountingStateHash() != beforeHash) failedOperationMutatedState = true;
        }
    }

    function onRecoveryShareOutflow(address, address, uint256[] calldata, uint256[] calldata)
        external
        pure
        returns (bytes4)
    {
        return IRecoveryShareOutflowCallback.onRecoveryShareOutflow.selector;
    }

    function _purchase(uint256 shares) private {
        IRecoveryFundTypes.AssetRecoveryFundView memory before_ = lens.assetRecoveryFund(impairedAsset);
        uint64 generation;
        uint256 payout;
        try lens.previewAssetRecoveryFundPurchase(impairedAsset, shares) returns (uint64 generation_, uint256 payout_) {
            generation = generation_;
            payout = payout_;
        } catch {
            return;
        }
        uint256 expectedPayout = LibRecoveryFundMath.payoutDelta(
            before_.initialCygldCommitment,
            before_.purchasedShares,
            before_.purchasedShares + shares,
            before_.coverageShares
        );
        if (payout != expectedPayout || generation != currentGeneration) {
            validOperationFailed = true;
            return;
        }
        try core.safeTransferFrom(
            address(this),
            address(router),
            shareId,
            shares,
            abi.encode(
                IRecoveryFundTypes.RecoveryFundPurchaseCallback({
                    expectedGeneration: generation, minimumCygldOut: payout
                })
            )
        ) {
            soldThisGeneration += shares;
            expectedGovernanceShares += shares;
            cumulativeCygldPayout += payout;
            remainingCommitment -= payout;
        } catch {
            validOperationFailed = true;
        }
    }

    function _accountingStateHash() private view returns (bytes32) {
        IRecoveryFundTypes.AssetRecoveryFundView memory facility = lens.assetRecoveryFund(impairedAsset);
        (uint256 balance, uint256 exposure, uint256 committed) = lens.recoveryFundTreasuryStatus();
        return keccak256(
            abi.encode(
                facility,
                balance,
                exposure,
                committed,
                core.allowance(address(router), ALLOWANCE_SPENDER),
                core.balanceOf(address(this)),
                core.balanceOf(address(this), shareId),
                core.balanceOf(address(router), shareId)
            )
        );
    }

    function initialCygldBalance() external pure returns (uint256) {
        return INITIAL_CYGLD_BALANCE;
    }

    function generationCoverage() external pure returns (uint256) {
        return GENERATION_COVERAGE;
    }

    function generationCommitment() external pure returns (uint256) {
        return GENERATION_COMMITMENT;
    }
}

contract RecoveryFundAccountingInvariantTest is StdInvariant, Test {
    RecoveryFundCoreMock internal core;
    RecoveryFundTestRouter internal router;
    RecoveryFundFacet internal fund;
    RecoveryFundLensFacet internal lens;
    RecoveryFundTestToken internal impaired;
    RecoveryFundAccountingHandler internal handler;
    uint256 internal shareId;

    function setUp() public {
        core = new RecoveryFundCoreMock();
        router = new RecoveryFundTestRouter();
        fund = RecoveryFundFacet(address(router));
        lens = RecoveryFundLensFacet(address(router));
        impaired = new RecoveryFundTestToken("Invariant Impaired", "IBAD");
        handler = new RecoveryFundAccountingHandler(core, router, lens, impaired);
        shareId = uint256(uint160(address(impaired)));

        core.configurePool(address(impaired), address(handler), 0, handler.generationCoverage(), true, 0);
        router.seed(address(core));
        core.mintCygld(address(router), handler.initialCygldBalance());
        IRecoveryFundTypes.AssetRecoveryFundActivation memory request = IRecoveryFundTypes.AssetRecoveryFundActivation({
            impairedAsset: address(impaired),
            expectedNextGeneration: 1,
            expectedCoverageShares: handler.generationCoverage(),
            cygldCommitment: handler.generationCommitment()
        });
        vm.prank(address(router));
        fund.activateAssetRecoveryFund(request);
        core.setInvokeAccountCallbacks(true);

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.purchase.selector;
        selectors[1] = handler.exhaustFacility.selector;
        selectors[2] = handler.setSafeAllowance.selector;
        selectors[3] = handler.transferUncommittedCygld.selector;
        selectors[4] = handler.pause.selector;
        selectors[5] = handler.unpause.selector;
        selectors[6] = handler.attemptInvalidPurchase.selector;
        selectors[7] = handler.attemptInsolventAllowance.selector;
        selectors[8] = handler.attemptInsolventOutflow.selector;
        selectors[9] = handler.directCoreRedemption.selector;
        selectors[10] = handler.reactivate.selector;
        selectors[11] = handler.attemptStaleGenerationAfterReactivation.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_treasuryAlwaysCoversAllowanceExposureAndCommitments() public view {
        (uint256 balance, uint256 exposure, uint256 committed) = lens.recoveryFundTreasuryStatus();
        assertGe(balance, exposure);
        assertGe(balance - exposure, committed);
        assertEq(committed, handler.remainingCommitment());
    }

    function invariant_facilityGenerationInventoryAndAbaStateRemainExact() public view {
        IRecoveryFundTypes.AssetRecoveryFundView memory facility = lens.assetRecoveryFund(address(impaired));
        assertEq(facility.generation, handler.currentGeneration());
        if (facility.coverageShares == 0) {
            assertEq(facility.purchasedShares, 0);
            assertEq(facility.initialCygldCommitment, 0);
            assertEq(handler.soldThisGeneration(), handler.generationCoverage());
            assertEq(handler.remainingCommitment(), 0);
        } else {
            assertEq(facility.coverageShares, handler.generationCoverage());
            assertEq(facility.purchasedShares, handler.soldThisGeneration());
            assertEq(facility.initialCygldCommitment, handler.generationCommitment());
        }

        assertEq(lens.acquiredRecoveryShares(address(impaired)), handler.expectedGovernanceShares());
        assertEq(
            core.balanceOf(address(handler), shareId) + core.balanceOf(address(router), shareId),
            core.totalSupply(shareId)
        );
    }

    function invariant_cumulativePayoutCommitmentAndDirectRedemptionLedgersBalance() public view {
        assertEq(core.balanceOf(address(handler)), handler.cumulativeCygldPayout());
        assertEq(
            core.balanceOf(address(router)) + handler.cumulativeCygldPayout()
                + handler.cumulativeDiscretionaryOutflow(),
            handler.initialCygldBalance()
        );
        assertEq(impaired.balanceOf(address(router)), handler.cumulativeRedeemedRaw());
        assertLe(handler.cumulativeRedeemedShares(), handler.currentGeneration() * handler.generationCoverage());
    }

    function invariant_failedCallbacksAndValidOperationsNeverCorruptState() public view {
        assertFalse(handler.failedOperationMutatedState());
        assertFalse(handler.validOperationFailed());
    }

    function test_handlerReachesReactivationDirectRedemptionAndAbaRollback() public {
        handler.attemptInvalidPurchase(0);
        assertEq(handler.failedOperationAttempts(), 1);

        handler.exhaustFacility();
        assertEq(handler.soldThisGeneration(), handler.generationCoverage());
        assertEq(handler.remainingCommitment(), 0);

        handler.directCoreRedemption(handler.generationCoverage() - 1);
        assertEq(handler.expectedGovernanceShares(), 0);
        assertEq(handler.cumulativeRedeemedShares(), handler.generationCoverage());
        assertEq(handler.cumulativeRedeemedRaw(), handler.generationCoverage());

        handler.reactivate();
        assertEq(handler.currentGeneration(), 2);
        assertEq(handler.remainingCommitment(), handler.generationCommitment());
        handler.attemptStaleGenerationAfterReactivation();
        assertEq(handler.failedOperationAttempts(), 2);

        assertFalse(handler.failedOperationMutatedState());
        assertFalse(handler.validOperationFailed());
    }
}
