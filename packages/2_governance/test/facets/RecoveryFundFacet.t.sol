// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ICygldApprovalCallback} from "cybergold-core/interfaces/ICygldApprovalCallback.sol";
import {ICygldOutflowCallback} from "cybergold-core/interfaces/ICygldOutflowCallback.sol";
import {IRecoveryShareOutflowCallback} from "cybergold-core/interfaces/IRecoveryShareOutflowCallback.sol";
import {IRecoveryShareRedemptionCallback} from "cybergold-core/interfaces/IRecoveryShareRedemptionCallback.sol";
import {IRecoveryTypes} from "cybergold-core/interfaces/IRecoveryTypes.sol";
import {IRecoveryFundTypes} from "../../src/interfaces/IRecoveryFundTypes.sol";
import {RecoveryFundBase} from "../../src/facets/RecoveryFundBase.sol";
import {RecoveryFundFacet} from "../../src/facets/RecoveryFundFacet.sol";
import {RecoveryFundLensFacet} from "../../src/facets/RecoveryFundLensFacet.sol";
import {LibRecoveryFundStorage} from "../../src/libraries/LibRecoveryFundStorage.sol";

contract RecoveryFundTestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IRecoveryFundTestMutation {
    function setAggregateCommitment(uint256 amount) external;
    function setFacility(
        address impairedAsset,
        uint64 generation,
        uint256 coverage,
        uint256 purchased,
        uint256 commitment
    ) external;
}

contract RecoveryFundCoreMock is ERC20, ERC1155 {
    enum TransferHook {
        None,
        ExtraDebit,
        ShortCredit,
        PoolMutation,
        CommitmentMutation,
        FacilityMutation,
        AllowanceMutation,
        ShareBalanceViewMutation,
        ReferenceSharesMutation,
        ReferenceValueMutation,
        ShareDecimalsMutation
    }

    enum BalanceFault {
        None,
        CygldBalanceReverts,
        AllowanceExposureReverts
    }

    mapping(address asset => IRecoveryTypes.RecoveryPoolView pool) internal _pools;
    mapping(uint256 shareId => uint256 supply) internal _supply;
    mapping(address owner => uint256 exposure) internal _allowanceExposure;

    TransferHook internal _transferHook;
    BalanceFault internal _balanceFault;
    bool internal _invokeAccountCallbacks;
    address internal _hookRouter;
    address internal _hookAsset;
    uint256 internal _hookValue;
    uint256 internal _governanceBalanceViewDelta;
    uint256 internal _governanceBalanceViewDeduction;
    uint256 internal _reportedExternalSharesDelta;

    constructor() ERC20("Core CyberGold", "CYGLD") ERC1155("") {}

    function mintCygld(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnCygld(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function configurePool(
        address asset,
        address externalHolder,
        uint256 coreAttachedShares,
        uint256 externalShares,
        bool impaired,
        uint256 redeemableRaw
    ) external {
        uint256 shareId = uint256(uint160(asset));
        if (externalShares != 0) _mint(externalHolder, shareId, externalShares, "");
        _pools[asset] = IRecoveryTypes.RecoveryPoolView({
            impaired: impaired,
            coreAttachedShares: coreAttachedShares,
            externalShares: _supply[shareId],
            redeemableRaw: redeemableRaw,
            cygldPerAssetRawFp18: 0,
            cygldSupplyCap: 0,
            referenceShares: 1 ether,
            referenceValueCygld: 1 ether,
            shareDecimals: 18
        });
    }

    function setAllowanceExposure(address owner, uint256 exposure) external {
        _allowanceExposure[owner] = exposure;
    }

    function setRawAllowance(address owner, address spender, uint256 value) external {
        _approve(owner, spender, value);
    }

    function setInvokeAccountCallbacks(bool enabled) external {
        _invokeAccountCallbacks = enabled;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        uint256 current = allowance(msg.sender, spender);
        bool success = super.approve(spender, value);
        if (value >= current) {
            _allowanceExposure[msg.sender] += value - current;
        } else {
            uint256 reduction = current - value;
            uint256 exposure = _allowanceExposure[msg.sender];
            _allowanceExposure[msg.sender] = reduction >= exposure ? 0 : exposure - reduction;
        }
        if (_invokeAccountCallbacks && msg.sender.code.length != 0) {
            bytes4 magic = ICygldApprovalCallback(msg.sender)
                .onCygldApprovalChange(spender, current, value, balanceOf(msg.sender), _allowanceExposure[msg.sender]);
            require(magic == ICygldApprovalCallback.onCygldApprovalChange.selector, "approval magic");
        }
        return success;
    }

    function setBalanceFault(BalanceFault fault) external {
        _balanceFault = fault;
    }

    function configureTransferHook(TransferHook hook, address router, address asset, uint256 value) external {
        _transferHook = hook;
        _hookRouter = router;
        _hookAsset = asset;
        _hookValue = value;
        _governanceBalanceViewDelta = 0;
    }

    function setPoolCondition(address asset, bool impaired, uint256 coreAttachedShares) external {
        IRecoveryTypes.RecoveryPoolView storage pool = _pools[asset];
        pool.impaired = impaired;
        pool.coreAttachedShares = coreAttachedShares;
    }

    function setPoolReference(address asset, uint256 referenceShares, uint256 referenceValueCygld, uint8 decimals)
        external
    {
        IRecoveryTypes.RecoveryPoolView storage pool = _pools[asset];
        pool.referenceShares = referenceShares;
        pool.referenceValueCygld = referenceValueCygld;
        pool.shareDecimals = decimals;
    }

    function mintShares(address account, address asset, uint256 amount) external {
        _mint(account, uint256(uint160(asset)), amount, "");
    }

    function moveSharesWithoutCallback(address from, address to, address asset, uint256 amount) external {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory values = new uint256[](1);
        ids[0] = uint256(uint160(asset));
        values[0] = amount;
        _update(from, to, ids, values);
    }

    function burnShares(address account, address asset, uint256 amount) external {
        _burn(account, uint256(uint160(asset)), amount);
    }

    function makeResolved(address asset, uint256 redeemableRaw) external {
        IRecoveryTypes.RecoveryPoolView storage pool = _pools[asset];
        pool.impaired = false;
        pool.coreAttachedShares = 0;
        pool.redeemableRaw = redeemableRaw;
    }

    function setGovernanceBalanceViewDelta(address router, uint256 delta) external {
        _hookRouter = router;
        _governanceBalanceViewDelta = delta;
    }

    function setGovernanceBalanceViewDeduction(address router, uint256 deduction) external {
        _hookRouter = router;
        _governanceBalanceViewDeduction = deduction;
    }

    function setReportedExternalSharesDelta(uint256 delta) external {
        _reportedExternalSharesDelta = delta;
    }

    function recoveryPool(address asset) external view returns (IRecoveryTypes.RecoveryPoolView memory pool) {
        pool = _pools[asset];
        pool.externalShares = _supply[uint256(uint160(asset))] + _reportedExternalSharesDelta;
    }

    function totalSupply(uint256 shareId) external view returns (uint256) {
        return _supply[shareId];
    }

    function allowanceExposure(address owner) external view returns (uint256) {
        if (_balanceFault == BalanceFault.AllowanceExposureReverts) revert("allowance unavailable");
        return _allowanceExposure[owner];
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_balanceFault == BalanceFault.CygldBalanceReverts) revert("CYGLD unavailable");
        return super.balanceOf(account);
    }

    function balanceOf(address account, uint256 id) public view override returns (uint256) {
        uint256 balance = super.balanceOf(account, id);
        if (account == _hookRouter) {
            if (_governanceBalanceViewDeduction != 0) {
                if (_governanceBalanceViewDeduction >= balance) return 0;
                balance -= _governanceBalanceViewDeduction;
            }
            return balance + _governanceBalanceViewDelta;
        }
        return balance;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        if (_transferHook == TransferHook.ExtraDebit) {
            _burn(msg.sender, 1);
        } else if (_transferHook == TransferHook.ShortCredit) {
            _burn(to, 1);
        } else if (_transferHook == TransferHook.PoolMutation) {
            _pools[_hookAsset].cygldSupplyCap += 1;
        } else if (_transferHook == TransferHook.CommitmentMutation) {
            IRecoveryFundTestMutation(_hookRouter).setAggregateCommitment(_hookValue);
        } else if (_transferHook == TransferHook.FacilityMutation) {
            IRecoveryFundTestMutation(_hookRouter).setFacility(_hookAsset, 99, _hookValue, 0, _hookValue);
        } else if (_transferHook == TransferHook.AllowanceMutation) {
            _allowanceExposure[_hookRouter] = _hookValue;
        } else if (_transferHook == TransferHook.ShareBalanceViewMutation) {
            _governanceBalanceViewDelta = _hookValue;
        } else if (_transferHook == TransferHook.ReferenceSharesMutation) {
            _pools[_hookAsset].referenceShares += 1;
        } else if (_transferHook == TransferHook.ReferenceValueMutation) {
            _pools[_hookAsset].referenceValueCygld += 1;
        } else if (_transferHook == TransferHook.ShareDecimalsMutation) {
            _pools[_hookAsset].shareDecimals += 1;
        }
        if (_invokeAccountCallbacks && msg.sender.code.length != 0 && amount != 0 && msg.sender != to) {
            bytes4 magic = ICygldOutflowCallback(msg.sender)
                .onCygldOutflow(msg.sender, to, amount, balanceOf(msg.sender), _allowanceExposure[msg.sender]);
            require(magic == ICygldOutflowCallback.onCygldOutflow.selector, "outflow magic");
        }
        return success;
    }

    function previewRedeemRecoveryShares(address asset, uint256 shares) public view returns (uint256) {
        IRecoveryTypes.RecoveryPoolView storage pool = _pools[asset];
        uint256 supply = _supply[uint256(uint160(asset))];
        uint256 liveCustody = IERC20(asset).balanceOf(address(this));
        uint256 denominator = pool.impaired ? pool.coreAttachedShares + supply : supply;
        uint256 ceiling = pool.impaired ? denominator : pool.redeemableRaw;
        return Math.mulDiv(Math.min(liveCustody, ceiling), shares, denominator);
    }

    function redeemRecoveryShares(address asset, uint256 shares, address recipient, uint256 minRawOut)
        external
        returns (uint256 rawOut)
    {
        IRecoveryTypes.RecoveryPoolView storage pool = _pools[asset];
        rawOut = previewRedeemRecoveryShares(asset, shares);
        require(rawOut != 0 && rawOut >= minRawOut, "minimum");
        if (_invokeAccountCallbacks && msg.sender.code.length != 0) {
            bytes4 magic = IRecoveryShareRedemptionCallback(msg.sender)
                .onRecoveryShareRedemption(asset, shares, recipient, minRawOut, rawOut);
            require(magic == IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector, "redemption magic");
        }
        uint256 supply = _supply[uint256(uint160(asset))];
        uint256 liabilityReleased = pool.impaired ? 0 : Math.mulDiv(pool.redeemableRaw, shares, supply);
        pool.redeemableRaw -= liabilityReleased;
        _burn(msg.sender, uint256(uint160(asset)), shares);
        require(IERC20(asset).transfer(recipient, rawOut), "transfer");
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        super._update(from, to, ids, values);
        if (from == address(0) || to == address(0)) {
            for (uint256 i; i < ids.length;) {
                if (from == address(0)) _supply[ids[i]] += values[i];
                else _supply[ids[i]] -= values[i];
                unchecked {
                    ++i;
                }
            }
        } else if (_invokeAccountCallbacks && from.code.length != 0 && from != to) {
            bytes4 magic = IRecoveryShareOutflowCallback(from).onRecoveryShareOutflow(msg.sender, to, ids, values);
            require(magic == IRecoveryShareOutflowCallback.onRecoveryShareOutflow.selector, "share magic");
        }
    }
}

contract RecoveryFundUnrelated1155 is ERC1155("") {
    function mint(address to, uint256 id, uint256 amount, bytes memory data) external {
        _mint(to, id, amount, data);
    }
}

contract RecoveryFundBaseHarness is RecoveryFundBase {
    function seedCore(address core) external {
        LibRecoveryFundStorage.getLayout().trustedCore = core;
    }

    function load(address impairedAsset, uint256 shareId) external view returns (uint256 externalSupply) {
        if (_shareIdForAsset(impairedAsset) != shareId) revert RecoveryFundInvalidShareId(shareId);
        return _loadCoreSnapshot(impairedAsset).externalSupply;
    }
}

contract RecoveryFundTestRouter is PausableUpgradeable {
    address internal immutable _fundFacet = address(new RecoveryFundFacet());
    address internal immutable _lensFacet = address(new RecoveryFundLensFacet());

    function seed(address core) external {
        LibRecoveryFundStorage.getLayout().trustedCore = core;
    }

    function resetAsset(address asset) external {
        LibRecoveryFundStorage.Layout storage l = LibRecoveryFundStorage.getLayout();
        delete l.facilities[asset];
        delete l.totalCommittedCygld;
    }

    function setAggregateCommitment(uint256 amount) external {
        LibRecoveryFundStorage.getLayout().totalCommittedCygld = amount;
    }

    function setFacility(
        address impairedAsset,
        uint64 generation,
        uint256 coverage,
        uint256 purchased,
        uint256 commitment
    ) external {
        LibRecoveryFundStorage.Facility storage facility = LibRecoveryFundStorage.getLayout().facilities[impairedAsset];
        facility.generation = generation;
        facility.coverageShares = coverage;
        facility.purchasedShares = purchased;
        facility.initialCygldCommitment = commitment;
    }

    function sovereignTransferCygld(address core, address to, uint256 amount) external {
        require(IERC20(core).transfer(to, amount), "CYGLD transfer failed");
    }

    function sovereignApproveCygld(address core, address spender, uint256 amount) external {
        IERC20(core).approve(spender, amount);
    }

    function sovereignTransferRecoveryShares(address core, address to, uint256 shareId, uint256 shares) external {
        ERC1155(core).safeTransferFrom(address(this), to, shareId, shares, "");
    }

    function sovereignRedeemRecoveryShares(
        RecoveryFundCoreMock core,
        address impairedAsset,
        uint256 shares,
        address recipient,
        uint256 minRawOut
    ) external returns (uint256 rawOut) {
        return core.redeemRecoveryShares(impairedAsset, shares, recipient, minRawOut);
    }

    function pauseGovernance() external {
        _pause();
    }

    function unpauseGovernance() external {
        _unpause();
    }

    fallback() external {
        address target = _fundFacet;
        if (
            msg.sig == RecoveryFundLensFacet.assetRecoveryFund.selector
                || msg.sig == RecoveryFundLensFacet.previewAssetRecoveryFundPurchase.selector
                || msg.sig == RecoveryFundLensFacet.recoveryFundTreasuryStatus.selector
                || msg.sig == RecoveryFundLensFacet.acquiredRecoveryShares.selector
                || msg.sig == RecoveryFundLensFacet.trustedRecoveryFundCore.selector
        ) {
            target = _lensFacet;
        }
        assembly {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch success
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract RecoveryFundFacetTest is Test {
    address internal constant SELLER = address(0x51E11);
    address internal constant RECIPIENT = address(0xB0B);

    RecoveryFundCoreMock internal core;
    RecoveryFundTestRouter internal router;
    RecoveryFundFacet internal fund;
    RecoveryFundLensFacet internal lens;
    RecoveryFundTestToken internal impaired;
    uint256 internal shareId;

    function setUp() public {
        core = new RecoveryFundCoreMock();
        router = new RecoveryFundTestRouter();
        fund = RecoveryFundFacet(address(router));
        lens = RecoveryFundLensFacet(address(router));
        impaired = new RecoveryFundTestToken("Impaired", "BAD");
        shareId = uint256(uint160(address(impaired)));

        core.configurePool(address(impaired), SELLER, 0, 100 ether, true, 0);
        router.seed(address(core));
        core.mintCygld(address(router), 150 ether);
        _activate(address(impaired), 100 ether, 1, 95 ether);
    }

    function test_activationUsesFourFieldAssetKeyedRequestAndStoresLeanTerms() public view {
        IRecoveryFundTypes.AssetRecoveryFundActivation memory request = IRecoveryFundTypes.AssetRecoveryFundActivation({
            impairedAsset: address(impaired),
            expectedNextGeneration: 1,
            expectedCoverageShares: 100 ether,
            cygldCommitment: 95 ether
        });
        assertEq(abi.encode(request).length, 128);

        IRecoveryFundTypes.AssetRecoveryFundView memory facility = lens.assetRecoveryFund(address(impaired));
        assertEq(facility.generation, 1);
        assertEq(facility.coverageShares, 100 ether);
        assertEq(facility.purchasedShares, 0);
        assertEq(facility.initialCygldCommitment, 95 ether);

        (uint256 balance, uint256 exposure, uint256 committed) = lens.recoveryFundTreasuryStatus();
        assertEq(balance, 150 ether);
        assertEq(exposure, 0);
        assertEq(committed, 95 ether);
    }

    function test_activationEmitsAssetKeyedOutcome() public {
        _clearDefaultFacility();
        vm.expectEmit(true, true, false, true, address(router));
        emit IRecoveryFundTypes.AssetRecoveryFundActivated(address(impaired), 1, 100 ether, 95 ether);
        _activate(address(impaired), 100 ether, 1, 95 ether);
    }

    function test_activationRequiresGovernanceSelfCall() public {
        _clearDefaultFacility();
        IRecoveryFundTypes.AssetRecoveryFundActivation memory request = _activationRequest(address(impaired), 95 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundUnauthorizedSelfCall.selector, address(this))
        );
        fund.activateAssetRecoveryFund(request);
    }

    function test_activationRejectsCoverageGenerationAndCommitmentDrift() public {
        _clearDefaultFacility();

        IRecoveryFundTypes.AssetRecoveryFundActivation memory request = _activationRequest(address(impaired), 95 ether);
        request.expectedCoverageShares -= 1;
        _expectActivationPartialRevert(request, IRecoveryFundTypes.RecoveryFundCoverageMismatch.selector);

        request = _activationRequest(address(impaired), 95 ether);
        request.expectedNextGeneration = 2;
        _expectActivationPartialRevert(request, IRecoveryFundTypes.RecoveryFundGenerationMismatch.selector);

        request = _activationRequest(address(impaired), 0);
        _expectActivationPartialRevert(request, IRecoveryFundTypes.RecoveryFundCommitmentZero.selector);

        request = _activationRequest(address(impaired), 100 ether + 1);
        _expectActivationPartialRevert(request, IRecoveryFundTypes.RecoveryFundCommitmentExceedsReference.selector);
    }

    function test_activationTrustsCanonicalCorePoolAndRejectsGovernanceBalanceAboveSupply() public {
        _clearDefaultFacility();
        core.setPoolCondition(address(impaired), false, 1);
        _activate(address(impaired), 100 ether + 1, 1, 95 ether);
        assertEq(lens.assetRecoveryFund(address(impaired)).coverageShares, 100 ether + 1);

        _clearDefaultFacility();
        core.setPoolCondition(address(impaired), true, 0);
        core.setGovernanceBalanceViewDelta(address(router), 101 ether);
        _expectActivationPartialRevert(
            _activationRequestWithoutSnapshot(address(impaired), 1),
            IRecoveryFundTypes.RecoveryFundGovernanceBalanceExceedsExternalShares.selector
        );
    }

    function test_nativeSixDecimalSharesAcceptNumericallyLargerCygldCommitment() public {
        _clearDefaultFacility();
        core.burnShares(SELLER, address(impaired), 100 ether);
        core.mintShares(SELLER, address(impaired), 100e6);
        core.setPoolReference(address(impaired), 100e6, 100 ether, 6);

        _activate(address(impaired), 100e6, 1, 100 ether);
        _buy(address(impaired), 25e6, 1, 25 ether);
        _buy(address(impaired), 75e6, 1, 75 ether);

        assertEq(core.balanceOf(SELLER), 100 ether);
        assertEq(lens.acquiredRecoveryShares(address(impaired)), 100e6);
        assertEq(lens.assetRecoveryFund(address(impaired)).coverageShares, 0);
    }

    function test_twentyFourDecimalSharesUseExactCumulativeCygldAmounts() public {
        _clearDefaultFacility();
        core.burnShares(SELLER, address(impaired), 100 ether);
        core.mintShares(SELLER, address(impaired), 100e24);
        core.setPoolReference(address(impaired), 100e24, 100 ether, 24);
        _activate(address(impaired), 100e24, 1, 95 ether);
        _buy(address(impaired), 33e24, 1, 31.35 ether);
        _buy(address(impaired), 67e24, 1, 63.65 ether);
        assertEq(core.balanceOf(SELLER), 95 ether);
        assertEq(lens.acquiredRecoveryShares(address(impaired)), 100e24);
    }

    function test_newFacilityRequiresPositiveRetainedAnchors() public {
        _clearDefaultFacility();
        core.setPoolReference(address(impaired), 0, 0, 18);
        _expectActivationPartialRevert(
            _activationRequest(address(impaired), 1 ether), IRecoveryFundTypes.RecoveryFundReferenceUnavailable.selector
        );
        assertEq(lens.assetRecoveryFund(address(impaired)).coverageShares, 0);
        (,, uint256 committed) = lens.recoveryFundTreasuryStatus();
        assertEq(committed, 0);
    }

    function test_externalOnlyHealthyPoolUsesRetainedAnchorsWithoutLiveConversion() public {
        _clearDefaultFacility();
        core.makeResolved(address(impaired), 100 ether);
        core.setPoolReference(address(impaired), 100 ether, 150 ether, 18);
        _activate(address(impaired), 100 ether, 1, 150 ether);
        assertEq(lens.assetRecoveryFund(address(impaired)).initialCygldCommitment, 150 ether);
        assertEq(core.recoveryPool(address(impaired)).cygldPerAssetRawFp18, 0);
    }

    function test_oldFacilityRemainsFrozenAcrossRehabilitationReopeningAndNewShares() public {
        _clearDefaultFacility();
        core.setPoolReference(address(impaired), 100 ether, 200 ether, 18);
        _activate(address(impaired), 100 ether, 1, 150 ether);
        _buy(address(impaired), 10 ether, 1, 15 ether);
        core.makeResolved(address(impaired), 100 ether);
        core.setPoolReference(address(impaired), 100 ether, 50 ether, 18);
        // Today's new-facility ceiling is lower than the old promise. It does not reprice it.
        (uint64 generation, uint256 preview) = lens.previewAssetRecoveryFundPurchase(address(impaired), 10 ether);
        assertEq(generation, 1);
        assertEq(preview, 15 ether);
        _buy(address(impaired), 10 ether, 1, 15 ether);
        core.setPoolCondition(address(impaired), true, 20 ether);
        core.mintShares(RECIPIENT, address(impaired), 80 ether);
        vm.prank(RECIPIENT);
        core.safeTransferFrom(RECIPIENT, address(router), shareId, 80 ether, _callback(1, 120 ether));
        assertEq(core.balanceOf(RECIPIENT), 120 ether);
        assertEq(core.balanceOf(SELLER), 30 ether);
        assertEq(lens.assetRecoveryFund(address(impaired)).coverageShares, 0);
    }

    function test_activationAcceptsUnstoredReferenceCeilingAboveUint256() public {
        _clearDefaultFacility();
        core.burnShares(SELLER, address(impaired), 100 ether);
        core.mintShares(SELLER, address(impaired), type(uint256).max);
        core.setPoolReference(address(impaired), 1, 2, 18);
        _activate(address(impaired), type(uint256).max, 1, 1);
        assertEq(lens.assetRecoveryFund(address(impaired)).initialCygldCommitment, 1);
    }

    function test_referenceAndPrecisionMutationDuringPaymentRollBack() public {
        _expectHookRevert(
            RecoveryFundCoreMock.TransferHook.ReferenceSharesMutation,
            0,
            IRecoveryFundTypes.RecoveryFundCoreMutationDuringPurchase.selector
        );
        _expectHookRevert(
            RecoveryFundCoreMock.TransferHook.ReferenceValueMutation,
            0,
            IRecoveryFundTypes.RecoveryFundCoreMutationDuringPurchase.selector
        );
        _expectHookRevert(
            RecoveryFundCoreMock.TransferHook.ShareDecimalsMutation,
            0,
            IRecoveryFundTypes.RecoveryFundCoreMutationDuringPurchase.selector
        );
        IRecoveryTypes.RecoveryPoolView memory pool = core.recoveryPool(address(impaired));
        assertEq(pool.referenceShares, 1 ether);
        assertEq(pool.referenceValueCygld, 1 ether);
        assertEq(pool.shareDecimals, 18);
    }

    function test_impairedAcquiredShareBurnPreservesCoreInterestAndGovernanceCustody() public {
        core.setInvokeAccountCallbacks(true);
        core.setPoolCondition(address(impaired), true, 100 ether);
        impaired.mint(address(core), 100 ether);
        _buy(address(impaired), 20 ether, 1, 19 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundRedemptionRecipientInvalid.selector, RECIPIENT)
        );
        router.sovereignRedeemRecoveryShares(core, address(impaired), 20 ether, RECIPIENT, 10 ether);
        assertEq(lens.acquiredRecoveryShares(address(impaired)), 20 ether);
        assertEq(core.totalSupply(shareId), 100 ether);

        assertEq(
            router.sovereignRedeemRecoveryShares(core, address(impaired), 20 ether, address(router), 10 ether), 10 ether
        );
        assertEq(lens.acquiredRecoveryShares(address(impaired)), 0);
        assertEq(core.recoveryPool(address(impaired)).coreAttachedShares, 100 ether);
        assertEq(core.recoveryPool(address(impaired)).redeemableRaw, 0);
        assertEq(core.totalSupply(shareId), 80 ether);
        assertEq(impaired.balanceOf(address(router)), 10 ether);
        assertEq(impaired.balanceOf(address(core)), 90 ether);
        IRecoveryFundTypes.AssetRecoveryFundView memory facility = lens.assetRecoveryFund(address(impaired));
        assertEq(facility.coverageShares, 100 ether);
        assertEq(facility.purchasedShares, 20 ether);
        assertEq(facility.initialCygldCommitment, 95 ether);
    }

    function test_coreSnapshotRejectsWrongShareIdAndCorePoolSupplyMismatch() public {
        RecoveryFundBaseHarness harness = new RecoveryFundBaseHarness();
        harness.seedCore(address(core));

        vm.expectRevert(abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundInvalidShareId.selector, shareId + 1));
        harness.load(address(impaired), shareId + 1);

        core.setReportedExternalSharesDelta(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundPoolAccountingMismatch.selector, 100 ether + 1, 100 ether
            )
        );
        harness.load(address(impaired), shareId);
    }

    function test_activationRejectsZeroAssetAndZeroUncoveredInterest() public {
        vm.expectRevert(IRecoveryFundTypes.RecoveryFundZeroAddress.selector);
        lens.assetRecoveryFund(address(0));

        _clearDefaultFacility();
        core.moveSharesWithoutCallback(SELLER, address(router), address(impaired), 100 ether);
        _expectActivationPartialRevert(
            _activationRequest(address(impaired), 1), IRecoveryFundTypes.RecoveryFundZeroCoverage.selector
        );
    }

    function test_generationPreventsAbaAndAdvancesOnlyAfterExhaustion() public {
        _buy(address(impaired), 100 ether, 1, 95 ether);
        IRecoveryFundTypes.AssetRecoveryFundView memory exhausted = lens.assetRecoveryFund(address(impaired));
        assertEq(exhausted.generation, 1);
        assertEq(exhausted.coverageShares, 0);
        assertEq(exhausted.purchasedShares, 0);
        assertEq(exhausted.initialCygldCommitment, 0);

        core.mintShares(SELLER, address(impaired), 20 ether);
        core.mintCygld(address(router), 19 ether);
        _activate(address(impaired), 20 ether, 2, 19 ether);

        _expectBuyRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundGenerationMismatch.selector, uint64(1), uint64(2)),
            address(impaired),
            1 ether,
            1,
            0
        );
        _buy(address(impaired), 1 ether, 2, 0.95 ether);
    }

    function test_activeFacilityBlocksReplacementAndGenerationExhaustionFailsClosed() public {
        IRecoveryFundTypes.AssetRecoveryFundActivation memory activeRequest =
            _activationRequest(address(impaired), 95 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundFacilityAlreadyActive.selector, address(impaired), uint64(1)
            )
        );
        vm.prank(address(router));
        fund.activateAssetRecoveryFund(activeRequest);

        _clearDefaultFacility();
        router.setFacility(address(impaired), type(uint64).max, 0, 0, 0);
        IRecoveryFundTypes.AssetRecoveryFundActivation memory request = IRecoveryFundTypes.AssetRecoveryFundActivation({
            impairedAsset: address(impaired),
            expectedNextGeneration: type(uint64).max,
            expectedCoverageShares: 100 ether,
            cygldCommitment: 95 ether
        });
        _expectActivationPartialRevert(request, IRecoveryFundTypes.RecoveryFundGenerationExhausted.selector);
    }

    function test_callbackIsExactlySixtyFourBytesAndRejectsTrailingOrMalformedData() public {
        bytes memory canonical = _callback(1, 0);
        assertEq(canonical.length, 64);

        bytes memory shortData = new bytes(63);
        _expectTransferRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundCallbackMalformed.selector),
            address(impaired),
            1 ether,
            shortData
        );
        _expectTransferRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundCallbackMalformed.selector),
            address(impaired),
            1 ether,
            bytes.concat(canonical, hex"00")
        );
        _expectTransferAnyRevert(address(impaired), 1 ether, abi.encode(uint256(type(uint64).max) + 1, uint256(0)));
    }

    function test_purchasePaysSellerDirectlyAndEmitsAssetKeyedOutcome() public {
        uint256 sellerBefore = core.balanceOf(SELLER);
        vm.expectEmit(true, true, true, true, address(router));
        emit IRecoveryFundTypes.RecoverySharesPurchased(address(impaired), 1, SELLER, 10 ether, 9.5 ether);

        _buy(address(impaired), 10 ether, 1, 9.5 ether);

        assertEq(core.balanceOf(SELLER) - sellerBefore, 9.5 ether);
        assertEq(core.balanceOf(RECIPIENT), 0);
    }

    function test_untrustedBatchOperatorAndSelfTransfersAreRejected() public {
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundTrustedCoreCallbackOnly.selector, address(this))
        );
        fund.onERC1155Received(SELLER, SELLER, shareId, 1, _callback(1, 0));

        uint256[] memory ids = new uint256[](1);
        uint256[] memory values = new uint256[](1);
        ids[0] = shareId;
        values[0] = 1;
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundTrustedCoreCallbackOnly.selector, address(this))
        );
        fund.onERC1155BatchReceived(SELLER, SELLER, ids, values, "");

        vm.expectRevert(IRecoveryFundTypes.RecoveryFundTrustedCoreBatchRejected.selector);
        vm.prank(address(core));
        fund.onERC1155BatchReceived(SELLER, SELLER, ids, values, "");

        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundOperatorInvalid.selector, RECIPIENT, SELLER)
        );
        vm.prank(address(core));
        fund.onERC1155Received(RECIPIENT, SELLER, shareId, 1, _callback(1, 0));

        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundOperatorInvalid.selector, address(0), address(0))
        );
        vm.prank(address(core));
        fund.onERC1155Received(address(0), address(0), shareId, 1, _callback(1, 0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundOperatorInvalid.selector, address(router), address(router)
            )
        );
        vm.prank(address(core));
        fund.onERC1155Received(address(router), address(router), shareId, 1, _callback(1, 0));

        RecoveryFundUnrelated1155 unrelated = new RecoveryFundUnrelated1155();
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundTrustedCoreCallbackOnly.selector, address(unrelated))
        );
        unrelated.mint(address(router), 7, 1, "");
    }

    function test_callbackRejectsZeroAmountAndInvalidId() public {
        vm.expectRevert(IRecoveryFundTypes.RecoveryFundPurchaseAmountZero.selector);
        vm.prank(address(core));
        fund.onERC1155Received(SELLER, SELLER, shareId, 0, _callback(1, 0));

        vm.expectPartialRevert(IRecoveryFundTypes.RecoveryFundInvalidShareId.selector);
        vm.prank(address(core));
        fund.onERC1155Received(SELLER, SELLER, uint256(type(uint160).max) + 1, 1, _callback(1, 0));
    }

    function test_callbackRejectsInactiveFacilityAndInsufficientPostCreditBalance() public {
        _clearDefaultFacility();
        _expectBuyPartialRevert(
            IRecoveryFundTypes.RecoveryFundFacilityInactive.selector, address(impaired), 1 ether, 1, 0
        );

        _activate(address(impaired), 100 ether, 1, 95 ether);
        core.setGovernanceBalanceViewDeduction(address(router), 1 ether);
        _expectBuyPartialRevert(
            IRecoveryFundTypes.RecoveryFundShareBalanceMismatch.selector, address(impaired), 1 ether, 1, 0
        );
    }

    function test_liveInventoryIncludesPreexistingAndPurchasedCustody() public {
        _clearDefaultFacility();
        core.moveSharesWithoutCallback(SELLER, address(router), address(impaired), 7 ether);
        _activate(address(impaired), 93 ether, 1, 90 ether);

        _buy(address(impaired), 1 ether, 1, 0);
        assertEq(core.balanceOf(address(router), shareId), 8 ether);
        assertEq(lens.acquiredRecoveryShares(address(impaired)), 8 ether);
        assertEq(core.balanceOf(SELLER), uint256(90 ether) / 93);
    }

    function test_cumulativeFloorPayoutIsSplitOrderIndependentAndExhausts() public {
        _clearDefaultFacility();
        core.burnShares(SELLER, address(impaired), 93 ether);
        _activate(address(impaired), 7 ether, 1, 5);

        uint256 beforeSeller = core.balanceOf(SELLER);
        _buy(address(impaired), 2 ether, 1, 1);
        _buy(address(impaired), 2 ether, 1, 1);
        _buy(address(impaired), 3 ether, 1, 3);
        assertEq(core.balanceOf(SELLER) - beforeSeller, 5);

        IRecoveryFundTypes.AssetRecoveryFundView memory exhausted = lens.assetRecoveryFund(address(impaired));
        assertEq(exhausted.generation, 1);
        assertEq(exhausted.coverageShares, 0);
        assertEq(lens.acquiredRecoveryShares(address(impaired)), 7 ether);
        (,, uint256 committed) = lens.recoveryFundTreasuryStatus();
        assertEq(committed, 0);
    }

    function test_minimumZeroPayoutAndCapacityAreEnforced() public {
        _expectBuyRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundMinimumNotMet.selector, address(core), 1 ether, 0.95 ether
            ),
            address(impaired),
            1 ether,
            1,
            1 ether
        );
        core.mintShares(SELLER, address(impaired), 1 ether);
        _expectBuyRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundCapacityExceeded.selector, 101 ether, 100 ether),
            address(impaired),
            101 ether,
            1,
            0
        );

        _clearDefaultFacility();
        core.burnShares(SELLER, address(impaired), 100 ether);
        _activate(address(impaired), 1 ether, 1, 1);
        _expectBuyRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundPayoutZero.selector), address(impaired), 1, 1, 0
        );
    }

    function test_tightMultiFacilitySolvencyAndDynamicAllowanceFailClosed() public {
        RecoveryFundTestToken second = new RecoveryFundTestToken("Second", "BAD2");
        uint256 secondShareId = uint256(uint160(address(second)));
        core.configurePool(address(second), SELLER, 0, 55 ether, true, 0);
        _activate(address(second), 55 ether, 1, 55 ether);

        (uint256 balance, uint256 exposure, uint256 committed) = lens.recoveryFundTreasuryStatus();
        assertEq(balance, 150 ether);
        assertEq(exposure, 0);
        assertEq(committed, 150 ether);

        _buy(address(impaired), 10 ether, 1, 9.5 ether);
        (balance, exposure, committed) = lens.recoveryFundTreasuryStatus();
        assertEq(balance, 140.5 ether);
        assertEq(committed, 140.5 ether);

        core.setAllowanceExposure(address(router), 1);
        _expectBuyPartialRevert(
            IRecoveryFundTypes.RecoveryFundCygldCommitmentDeficit.selector, address(second), 1 ether, 1, 0
        );
        assertEq(core.balanceOf(SELLER, secondShareId), 55 ether);
    }

    function test_activationCountsAllFacilitiesAgainstAvailableTreasury() public {
        RecoveryFundTestToken second = new RecoveryFundTestToken("Second", "BAD2");
        core.configurePool(address(second), SELLER, 0, 56 ether, true, 0);
        IRecoveryFundTypes.AssetRecoveryFundActivation memory request = _activationRequest(address(second), 56 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundCygldCommitmentDeficit.selector, 150 ether, 0, 151 ether
            )
        );
        vm.prank(address(router));
        fund.activateAssetRecoveryFund(request);

        core.setAllowanceExposure(address(router), 10 ether);
        request.cygldCommitment = 46 ether;
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundCygldCommitmentDeficit.selector, 150 ether, 10 ether, 141 ether
            )
        );
        vm.prank(address(router));
        fund.activateAssetRecoveryFund(request);
    }

    function test_exactTransferAndEveryAccountedPostconditionFailAtomically() public {
        _expectHookRevert(
            RecoveryFundCoreMock.TransferHook.ExtraDebit, 0, IRecoveryFundTypes.RecoveryFundExactDebitMismatch.selector
        );
        _expectHookRevert(
            RecoveryFundCoreMock.TransferHook.ShortCredit,
            0,
            IRecoveryFundTypes.RecoveryFundExactCreditMismatch.selector
        );
        _expectHookRevert(
            RecoveryFundCoreMock.TransferHook.PoolMutation,
            0,
            IRecoveryFundTypes.RecoveryFundCoreMutationDuringPurchase.selector
        );
        _expectHookRevert(
            RecoveryFundCoreMock.TransferHook.CommitmentMutation,
            77,
            IRecoveryFundTypes.RecoveryFundCoreMutationDuringPurchase.selector
        );
        _expectHookRevert(
            RecoveryFundCoreMock.TransferHook.FacilityMutation,
            77,
            IRecoveryFundTypes.RecoveryFundCoreMutationDuringPurchase.selector
        );
        _expectHookRevert(
            RecoveryFundCoreMock.TransferHook.ShareBalanceViewMutation,
            1,
            IRecoveryFundTypes.RecoveryFundCoreMutationDuringPurchase.selector
        );
        _expectHookRevert(
            RecoveryFundCoreMock.TransferHook.AllowanceMutation,
            150 ether,
            IRecoveryFundTypes.RecoveryFundAllowanceAccountingInvalid.selector
        );
    }

    function test_assetKeyedLensesExposeOnlyCurrentState() public {
        RecoveryFundTestToken neverActivated = new RecoveryFundTestToken("Never", "NO");
        IRecoveryFundTypes.AssetRecoveryFundView memory facility = lens.assetRecoveryFund(address(impaired));
        IRecoveryFundTypes.AssetRecoveryFundView memory empty = lens.assetRecoveryFund(address(neverActivated));
        assertEq(facility.generation, 1);
        assertEq(facility.coverageShares, 100 ether);
        assertEq(empty.generation, 0);
        assertEq(empty.coverageShares, 0);

        (uint64 generation, uint256 amountOut) = lens.previewAssetRecoveryFundPurchase(address(impaired), 10 ether);
        assertEq(generation, 1);
        assertEq(amountOut, 9.5 ether);
        assertEq(lens.acquiredRecoveryShares(address(impaired)), 0);

        (bool oldIdLens,) = address(router).call(abi.encodeWithSignature("assetRecoveryFund(bytes32)", bytes32(0)));
        (bool oldActiveLens,) =
            address(router).call(abi.encodeWithSignature("activeAssetRecoveryFund(uint256)", shareId));
        assertFalse(oldIdLens);
        assertFalse(oldActiveLens);
    }

    function test_purchasePreviewRejectsEveryInvalidCurrentState() public {
        vm.expectRevert(IRecoveryFundTypes.RecoveryFundPurchaseAmountZero.selector);
        lens.previewAssetRecoveryFundPurchase(address(impaired), 0);

        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundCapacityExceeded.selector, 100 ether + 1, 100 ether)
        );
        lens.previewAssetRecoveryFundPurchase(address(impaired), 100 ether + 1);

        vm.expectRevert(IRecoveryFundTypes.RecoveryFundPayoutZero.selector);
        lens.previewAssetRecoveryFundPurchase(address(impaired), 1);

        _clearDefaultFacility();
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundFacilityInactive.selector, address(impaired), uint64(0)
            )
        );
        lens.previewAssetRecoveryFundPurchase(address(impaired), 1 ether);
    }

    function test_governancePauseGatesNewPurchasesAtomically() public {
        router.pauseGovernance();
        assertTrue(router.paused());

        IRecoveryFundTypes.AssetRecoveryFundActivation memory activeRequest =
            _activationRequest(address(impaired), 95 ether);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(address(router));
        fund.activateAssetRecoveryFund(activeRequest);

        (uint64 generation, uint256 amountOut) = lens.previewAssetRecoveryFundPurchase(address(impaired), 1 ether);
        assertEq(generation, 1);
        assertEq(amountOut, 0.95 ether);

        uint256 sellerSharesBefore = core.balanceOf(SELLER, shareId);
        uint256 governanceSharesBefore = core.balanceOf(address(router), shareId);
        uint256 sellerCygldBefore = core.balanceOf(SELLER);
        _expectBuyPartialRevert(PausableUpgradeable.EnforcedPause.selector, address(impaired), 1 ether, 1, 0);
        assertEq(core.balanceOf(SELLER, shareId), sellerSharesBefore);
        assertEq(core.balanceOf(address(router), shareId), governanceSharesBefore);
        assertEq(core.balanceOf(SELLER), sellerCygldBefore);
        assertEq(lens.acquiredRecoveryShares(address(impaired)), 0);
        IRecoveryFundTypes.AssetRecoveryFundView memory facility = lens.assetRecoveryFund(address(impaired));
        assertEq(facility.purchasedShares, 0);
        (,, uint256 committed) = lens.recoveryFundTreasuryStatus();
        assertEq(committed, 95 ether);

        router.unpauseGovernance();
        assertFalse(router.paused());
        _buy(address(impaired), 1 ether, 1, 0.95 ether);
    }

    function test_treasuryProbesAndAllowanceAccountingFailClosed() public {
        core.setAllowanceExposure(address(router), 151 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundAllowanceAccountingInvalid.selector, 150 ether, 151 ether
            )
        );
        lens.recoveryFundTreasuryStatus();

        core.setAllowanceExposure(address(router), 0);
        core.setBalanceFault(RecoveryFundCoreMock.BalanceFault.CygldBalanceReverts);
        vm.expectPartialRevert(IRecoveryFundTypes.RecoveryFundTokenBalanceProbeFailed.selector);
        lens.recoveryFundTreasuryStatus();

        core.setBalanceFault(RecoveryFundCoreMock.BalanceFault.AllowanceExposureReverts);
        vm.expectPartialRevert(IRecoveryFundTypes.RecoveryFundAllowanceExposureProbeFailed.selector);
        lens.recoveryFundTreasuryStatus();
    }

    function test_policyCallbacksApplyTheirPauseChecksBeforeOrAfterAuthentication() public {
        router.pauseGovernance();
        bytes memory expected =
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundTrustedCoreCallbackOnly.selector, address(this));
        uint256[] memory ids = new uint256[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        fund.onCygldOutflow(address(0), address(0), 0, 0, 0);

        vm.expectRevert(expected);
        fund.onCygldApprovalChange(address(0), 0, 0, 0, 0);

        vm.expectRevert(expected);
        fund.onRecoveryShareOutflow(address(0), address(0), ids, amounts);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        fund.onRecoveryShareRedemption(address(0), 0, address(0), 1, 0);
    }

    function test_cygldOutflowPolicyEnforcesPauseStrictPostStateAndSolvency() public {
        vm.prank(address(core));
        assertEq(
            fund.onCygldOutflow(address(router), RECIPIENT, 1 ether, 150 ether, 0),
            ICygldOutflowCallback.onCygldOutflow.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundCygldPostStateMismatch.selector, 149 ether, 150 ether, 0, 0
            )
        );
        vm.prank(address(core));
        fund.onCygldOutflow(address(router), RECIPIENT, 1 ether, 149 ether, 0);

        core.setAllowanceExposure(address(router), 56 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundCygldCommitmentDeficit.selector, 150 ether, 56 ether, 95 ether
            )
        );
        vm.prank(address(core));
        fund.onCygldOutflow(address(router), RECIPIENT, 1 ether, 150 ether, 56 ether);

        core.setAllowanceExposure(address(router), 151 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundAllowanceAccountingInvalid.selector, 150 ether, 151 ether
            )
        );
        vm.prank(address(core));
        fund.onCygldOutflow(address(router), RECIPIENT, 1 ether, 150 ether, 151 ether);

        core.setAllowanceExposure(address(router), 0);
        core.setBalanceFault(RecoveryFundCoreMock.BalanceFault.CygldBalanceReverts);
        router.pauseGovernance();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(address(core));
        fund.onCygldOutflow(address(router), RECIPIENT, 1 ether, 150 ether, 0);
    }

    function test_cygldOutflowStrictProbesRejectRevertsAndMalformedData() public {
        bytes memory balanceCall = abi.encodeCall(IERC20.balanceOf, (address(router)));
        vm.mockCallRevert(address(core), balanceCall, "balance unavailable");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundTokenBalanceProbeFailed.selector, address(core), address(router)
            )
        );
        vm.prank(address(core));
        fund.onCygldOutflow(address(router), RECIPIENT, 1, 150 ether, 0);
        vm.clearMockedCalls();

        vm.mockCall(address(core), balanceCall, hex"01");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundTokenBalanceProbeFailed.selector, address(core), address(router)
            )
        );
        vm.prank(address(core));
        fund.onCygldOutflow(address(router), RECIPIENT, 1, 150 ether, 0);
        vm.clearMockedCalls();

        bytes memory exposureCall = abi.encodeCall(RecoveryFundCoreMock.allowanceExposure, (address(router)));
        vm.mockCall(address(core), exposureCall, hex"01");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundAllowanceExposureProbeFailed.selector, address(core), address(router)
            )
        );
        vm.prank(address(core));
        fund.onCygldOutflow(address(router), RECIPIENT, 1, 150 ether, 0);
        vm.clearMockedCalls();
    }

    function test_approvalPolicyChecksRawAllowanceBeforePostStateAndPause() public {
        core.setRawAllowance(address(router), RECIPIENT, 10 ether);
        core.setAllowanceExposure(address(router), 10 ether);

        vm.prank(address(core));
        assertEq(
            fund.onCygldApprovalChange(RECIPIENT, 0, 10 ether, 150 ether, 10 ether),
            ICygldApprovalCallback.onCygldApprovalChange.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundAllowancePostStateMismatch.selector, RECIPIENT, 9 ether, 10 ether
            )
        );
        vm.prank(address(core));
        fund.onCygldApprovalChange(RECIPIENT, 0, 9 ether, 150 ether, 10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundCygldPostStateMismatch.selector, 149 ether, 150 ether, 10 ether, 10 ether
            )
        );
        vm.prank(address(core));
        fund.onCygldApprovalChange(RECIPIENT, 0, 10 ether, 149 ether, 10 ether);

        router.pauseGovernance();
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundAllowancePostStateMismatch.selector, RECIPIENT, 9 ether, 10 ether
            )
        );
        vm.prank(address(core));
        fund.onCygldApprovalChange(RECIPIENT, 0, 9 ether, 150 ether, 10 ether);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(address(core));
        fund.onCygldApprovalChange(RECIPIENT, 0, 10 ether, 150 ether, 10 ether);

        vm.prank(address(core));
        assertEq(
            fund.onCygldApprovalChange(RECIPIENT, 20 ether, 10 ether, 150 ether, 10 ether),
            ICygldApprovalCallback.onCygldApprovalChange.selector
        );
    }

    function test_approvalPolicyStrictAllowanceProbeRejectsRevertAndMalformedReturn() public {
        bytes memory allowanceCall = abi.encodeCall(IERC20.allowance, (address(router), RECIPIENT));

        vm.mockCallRevert(address(core), allowanceCall, "allowance unavailable");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundAllowanceProbeFailed.selector, address(core), address(router), RECIPIENT
            )
        );
        vm.prank(address(core));
        fund.onCygldApprovalChange(RECIPIENT, 0, 0, 150 ether, 0);
        vm.clearMockedCalls();

        vm.mockCall(address(core), allowanceCall, hex"01");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundAllowanceProbeFailed.selector, address(core), address(router), RECIPIENT
            )
        );
        vm.prank(address(core));
        fund.onCygldApprovalChange(RECIPIENT, 0, 0, 150 ether, 0);
        vm.clearMockedCalls();
    }

    function test_approvalPolicyFailsClosedOnAggregateAccountingAndSolvency() public {
        core.setRawAllowance(address(router), RECIPIENT, 10 ether);
        core.setAllowanceExposure(address(router), 56 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundCygldCommitmentDeficit.selector, 150 ether, 56 ether, 95 ether
            )
        );
        vm.prank(address(core));
        fund.onCygldApprovalChange(RECIPIENT, 20 ether, 10 ether, 150 ether, 56 ether);

        core.setAllowanceExposure(address(router), 151 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundAllowanceAccountingInvalid.selector, 150 ether, 151 ether
            )
        );
        vm.prank(address(core));
        fund.onCygldApprovalChange(RECIPIENT, 20 ether, 10 ether, 150 ether, 151 ether);
    }

    function test_recoveryShareOutflowPolicyIsAlwaysClosedAfterAuthentication() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = shareId;
        amounts[0] = 1 ether;

        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundRecoveryShareOutflowForbidden.selector, address(router), RECIPIENT
            )
        );
        vm.prank(address(core));
        fund.onRecoveryShareOutflow(address(router), RECIPIENT, ids, amounts);

        ids = new uint256[](0);
        amounts = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundRecoveryShareOutflowForbidden.selector, address(0), address(0)
            )
        );
        vm.prank(address(core));
        fund.onRecoveryShareOutflow(address(0), address(0), ids, amounts);
    }

    function test_recoveryShareRedemptionPolicyHasExactValidationOrderAndMagic() public {
        router.pauseGovernance();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(address(core));
        fund.onRecoveryShareRedemption(address(0), 0, address(0), 2, 1);
        router.unpauseGovernance();

        vm.expectRevert(IRecoveryFundTypes.RecoveryFundZeroAddress.selector);
        vm.prank(address(core));
        fund.onRecoveryShareRedemption(address(0), 0, address(0), 2, 1);

        vm.expectRevert(IRecoveryFundTypes.RecoveryFundPurchaseAmountZero.selector);
        vm.prank(address(core));
        fund.onRecoveryShareRedemption(address(impaired), 0, address(0), 2, 1);

        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundRedemptionRecipientInvalid.selector, RECIPIENT)
        );
        vm.prank(address(core));
        fund.onRecoveryShareRedemption(address(impaired), 1, RECIPIENT, 2, 1);

        vm.expectRevert(IRecoveryFundTypes.RecoveryFundRedemptionAmountZero.selector);
        vm.prank(address(core));
        fund.onRecoveryShareRedemption(address(impaired), 1, address(router), 2, 0);

        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundMinimumNotMet.selector, address(impaired), 2, 1)
        );
        vm.prank(address(core));
        fund.onRecoveryShareRedemption(address(impaired), 1, address(router), 2, 1);

        vm.prank(address(core));
        assertEq(
            fund.onRecoveryShareRedemption(address(impaired), 1, address(router), 1, 1),
            IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector
        );
    }

    function test_acquiredRecoverySharesUsesStrictLiveCoreCustody() public {
        core.moveSharesWithoutCallback(SELLER, address(router), address(impaired), 7 ether);
        assertEq(lens.acquiredRecoveryShares(address(impaired)), 7 ether);

        bytes memory balanceCall = abi.encodeCall(IERC1155.balanceOf, (address(router), shareId));
        vm.mockCallRevert(address(core), balanceCall, "share balance unavailable");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundShareBalanceProbeFailed.selector, address(core), address(router), shareId
            )
        );
        lens.acquiredRecoveryShares(address(impaired));
        vm.clearMockedCalls();

        vm.mockCall(address(core), balanceCall, hex"01");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundShareBalanceProbeFailed.selector, address(core), address(router), shareId
            )
        );
        lens.acquiredRecoveryShares(address(impaired));
        vm.clearMockedCalls();
    }

    function test_purchaseReducesCommitmentBeforeNestedCygldPolicyCallback() public {
        core.burnCygld(address(router), 55 ether);
        assertEq(core.balanceOf(address(router)), 95 ether);
        core.setInvokeAccountCallbacks(true);

        _buy(address(impaired), 10 ether, 1, 9.5 ether);

        assertEq(core.balanceOf(address(router)), 85.5 ether);
        assertEq(core.balanceOf(SELLER), 9.5 ether);
        (,, uint256 committed) = lens.recoveryFundTreasuryStatus();
        assertEq(committed, 85.5 ether);
    }

    function test_directCoreMutationsAreClosedByPoliciesWithoutLegacyWrapper() public {
        core.setInvokeAccountCallbacks(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundCygldCommitmentDeficit.selector, 150 ether, 60 ether, 95 ether
            )
        );
        router.sovereignApproveCygld(address(core), RECIPIENT, 60 ether);
        assertEq(core.allowance(address(router), RECIPIENT), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundCygldCommitmentDeficit.selector, 94 ether, 0, 95 ether
            )
        );
        router.sovereignTransferCygld(address(core), RECIPIENT, 56 ether);
        assertEq(core.balanceOf(address(router)), 150 ether);

        _buy(address(impaired), 2 ether, 1, 1.9 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundRecoveryShareOutflowForbidden.selector, address(router), RECIPIENT
            )
        );
        router.sovereignTransferRecoveryShares(address(core), RECIPIENT, shareId, 1 ether);
        assertEq(lens.acquiredRecoveryShares(address(impaired)), 2 ether);

        impaired.mint(address(core), 100 ether);
        core.makeResolved(address(impaired), 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IRecoveryFundTypes.RecoveryFundRedemptionRecipientInvalid.selector, RECIPIENT)
        );
        router.sovereignRedeemRecoveryShares(core, address(impaired), 1 ether, RECIPIENT, 0);

        assertEq(
            router.sovereignRedeemRecoveryShares(core, address(impaired), 1 ether, address(router), 1 ether), 1 ether
        );
        assertEq(lens.acquiredRecoveryShares(address(impaired)), 1 ether);

        (bool wrapperExists,) =
            address(router).call(abi.encodeWithSelector(bytes4(0xaefda6c0), address(impaired), 1 ether, 0));
        assertFalse(wrapperExists);
    }

    function test_optionalFundInitializerFacetErc165AndLegacyPauseSelectorsAreAbsent() public {
        (bool initOk,) = address(router).call(abi.encodeWithSignature("initRecoveryFund(address)", address(core)));
        (bool supportsInterfaceOk,) =
            address(router).staticcall(abi.encodeWithSignature("supportsInterface(bytes4)", bytes4(0x4e2312e0)));
        (bool pauseOk,) = address(router).call(abi.encodeWithSignature("pauseRecoveryFundPurchases()"));
        (bool unpauseOk,) = address(router).call(abi.encodeWithSignature("unpauseRecoveryFundPurchases()"));
        (bool pauseReadOk,) = address(router).staticcall(abi.encodeWithSignature("recoveryFundPurchasesPaused()"));
        assertFalse(initOk);
        assertFalse(supportsInterfaceOk);
        assertFalse(pauseOk);
        assertFalse(unpauseOk);
        assertFalse(pauseReadOk);
    }

    function _activate(address asset, uint256 expectedCoverageShares, uint64 expectedNextGeneration, uint256 commitment)
        internal
    {
        IRecoveryFundTypes.AssetRecoveryFundActivation memory request = IRecoveryFundTypes.AssetRecoveryFundActivation({
            impairedAsset: asset,
            expectedNextGeneration: expectedNextGeneration,
            expectedCoverageShares: expectedCoverageShares,
            cygldCommitment: commitment
        });
        vm.prank(address(router));
        fund.activateAssetRecoveryFund(request);
    }

    function _activationRequest(address asset, uint256 commitment)
        internal
        view
        returns (IRecoveryFundTypes.AssetRecoveryFundActivation memory request)
    {
        IRecoveryTypes.RecoveryPoolView memory pool = core.recoveryPool(asset);
        IRecoveryFundTypes.AssetRecoveryFundView memory facility = lens.assetRecoveryFund(asset);
        uint256 governanceBalance = core.balanceOf(address(router), uint256(uint160(asset)));
        request = IRecoveryFundTypes.AssetRecoveryFundActivation({
            impairedAsset: asset,
            expectedNextGeneration: facility.generation + 1,
            expectedCoverageShares: pool.coreAttachedShares + pool.externalShares - governanceBalance,
            cygldCommitment: commitment
        });
    }

    function _activationRequestWithoutSnapshot(address asset, uint256 commitment)
        internal
        pure
        returns (IRecoveryFundTypes.AssetRecoveryFundActivation memory request)
    {
        request = IRecoveryFundTypes.AssetRecoveryFundActivation({
            impairedAsset: asset, expectedNextGeneration: 1, expectedCoverageShares: 1, cygldCommitment: commitment
        });
    }

    function _callback(uint64 generation, uint256 minimumCygldOut) internal pure returns (bytes memory) {
        return abi.encode(
            IRecoveryFundTypes.RecoveryFundPurchaseCallback({
                expectedGeneration: generation, minimumCygldOut: minimumCygldOut
            })
        );
    }

    function _buy(address asset, uint256 shares, uint64 generation, uint256 minimumCygldOut) internal {
        vm.prank(SELLER);
        core.safeTransferFrom(
            SELLER, address(router), uint256(uint160(asset)), shares, _callback(generation, minimumCygldOut)
        );
    }

    function _expectBuyRevert(
        bytes memory reason,
        address asset,
        uint256 shares,
        uint64 generation,
        uint256 minimumCygldOut
    ) internal {
        vm.expectRevert(reason);
        vm.prank(SELLER);
        core.safeTransferFrom(
            SELLER, address(router), uint256(uint160(asset)), shares, _callback(generation, minimumCygldOut)
        );
    }

    function _expectBuyPartialRevert(
        bytes4 selector,
        address asset,
        uint256 shares,
        uint64 generation,
        uint256 minimumCygldOut
    ) internal {
        vm.expectPartialRevert(selector);
        vm.prank(SELLER);
        core.safeTransferFrom(
            SELLER, address(router), uint256(uint160(asset)), shares, _callback(generation, minimumCygldOut)
        );
    }

    function _expectTransferRevert(bytes memory reason, address asset, uint256 shares, bytes memory data) internal {
        uint256 id = uint256(uint160(asset));
        uint256 sellerBefore = core.balanceOf(SELLER, id);
        vm.expectRevert(reason);
        vm.prank(SELLER);
        core.safeTransferFrom(SELLER, address(router), id, shares, data);
        assertEq(core.balanceOf(SELLER, id), sellerBefore);
    }

    function _expectTransferAnyRevert(address asset, uint256 shares, bytes memory data) internal {
        uint256 id = uint256(uint160(asset));
        uint256 sellerBefore = core.balanceOf(SELLER, id);
        vm.expectRevert();
        vm.prank(SELLER);
        core.safeTransferFrom(SELLER, address(router), id, shares, data);
        assertEq(core.balanceOf(SELLER, id), sellerBefore);
    }

    function _expectActivationPartialRevert(
        IRecoveryFundTypes.AssetRecoveryFundActivation memory request,
        bytes4 selector
    ) internal {
        vm.expectPartialRevert(selector);
        vm.prank(address(router));
        fund.activateAssetRecoveryFund(request);
    }

    function _expectHookRevert(RecoveryFundCoreMock.TransferHook hook, uint256 value, bytes4 selector) internal {
        core.configureTransferHook(hook, address(router), address(impaired), value);
        uint256 sellerBefore = core.balanceOf(SELLER, shareId);
        vm.expectPartialRevert(selector);
        vm.prank(SELLER);
        core.safeTransferFrom(SELLER, address(router), shareId, 1 ether, _callback(1, 0));
        assertEq(core.balanceOf(SELLER, shareId), sellerBefore);
        assertEq(core.balanceOf(address(router), shareId), 0);
        assertEq(core.balanceOf(SELLER), 0);
        assertEq(lens.acquiredRecoveryShares(address(impaired)), 0);
        IRecoveryFundTypes.AssetRecoveryFundView memory facility = lens.assetRecoveryFund(address(impaired));
        assertEq(facility.generation, 1);
        assertEq(facility.coverageShares, 100 ether);
        assertEq(facility.purchasedShares, 0);
        assertEq(facility.initialCygldCommitment, 95 ether);
        (,, uint256 committed) = lens.recoveryFundTreasuryStatus();
        assertEq(committed, 95 ether);
        core.configureTransferHook(RecoveryFundCoreMock.TransferHook.None, address(router), address(impaired), 0);
    }

    function _clearDefaultFacility() internal {
        router.resetAsset(address(impaired));
    }
}
