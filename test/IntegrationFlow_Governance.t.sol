// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";

import {StackDeployer} from "script/helpers/StackDeployer.sol";
import {SleeveDeployerHelper} from "packages/3_staking/src/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "packages/3_staking/src/deploy/SleeveRequestBuilder.sol";

import {ICyberGoldCore} from "packages/1_core/src/interfaces/ICyberGoldCore.sol";
import {AccessControlFacet} from "diamond-infra/facets/AccessControlFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {GovernorCoreFacet} from "packages/2_governance/src/facets/GovernorCoreFacet.sol";
import {GovernorSettingsFacet} from "packages/2_governance/src/facets/GovernorSettingsFacet.sol";
import {TokenFacet as GovernanceTokenFacet} from "packages/2_governance/src/facets/TokenFacet.sol";
import {RecoveryFundFacet} from "packages/2_governance/src/facets/RecoveryFundFacet.sol";
import {RecoveryFundLensFacet} from "packages/2_governance/src/facets/RecoveryFundLensFacet.sol";
import {ICyberGoldGovernance} from "packages/2_governance/src/interfaces/ICyberGoldGovernance.sol";
import {IRecoveryFundTypes} from "packages/2_governance/src/interfaces/IRecoveryFundTypes.sol";
import {LensFacet as CoreLensFacet} from "packages/1_core/src/facets/LensFacet.sol";
import {ICygldApprovalCallback} from "packages/1_core/src/interfaces/ICygldApprovalCallback.sol";
import {ICygldOutflowCallback} from "packages/1_core/src/interfaces/ICygldOutflowCallback.sol";
import {IRecoveryShareOutflowCallback} from "packages/1_core/src/interfaces/IRecoveryShareOutflowCallback.sol";
import {IRecoveryShareRedemptionCallback} from "packages/1_core/src/interfaces/IRecoveryShareRedemptionCallback.sol";
import {IRecoveryTypes} from "packages/1_core/src/interfaces/IRecoveryTypes.sol";
import {MocksDeployer} from "script/helpers/MocksDeployer.sol";
import {DeployedStack} from "script/helpers/DeployedStack.sol";
import {StackConfigBuilder} from "script/helpers/StackConfigBuilder.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeSingleton, MockSafeWallet} from "shared/helpers/MockSafeWallet.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";

interface IGovernorSettingsActions {
    function setVotingDelay(uint48 currentVotingDelay, uint48 newVotingDelay) external;
    function setVotingPeriod(uint32 currentVotingPeriod, uint32 newVotingPeriod) external;
    function setProposalThresholdNumerator(uint32 currentNumerator, uint32 newNumerator) external;
    function setExecutionDelay(uint48 currentExecutionDelay, uint48 newExecutionDelay) external;
    function setExecutionGracePeriod(uint48 currentExecutionGracePeriod, uint48 newExecutionGracePeriod) external;
}

contract GovernanceUpgradeProbeFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.governance.test.direct-execution-upgrade-probe");
    uint64 public constant FACET_VERSION = 1;

    function upgradeProbe() external pure returns (bytes32) {
        return keccak256("cybergold.governance.direct-execution-upgrade-probe");
    }
}

contract GovernanceUpgradeInit {
    function init(address) external pure {}
}

contract IntegrationFlow_Governance is Test {
    uint256 internal constant SIGNER_PK = 0xA11CE;
    uint256 internal constant MAX_COMBINED_CORE_ASSETS = 64;
    uint256 internal constant AUTHORITY_OPERATION_GAS_CEILING = 12_000_000;
    bytes4 internal constant ENFORCED_PAUSE_SELECTOR = bytes4(keccak256("EnforcedPause()"));
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");
    address internal admin = address(this);

    struct Stack {
        ICyberGoldCore controller;
        ICyberGoldCore token;
        address coreDiamond;
        address governanceDiamond;
        address safeWallet;
    }

    struct RecoveryScenario {
        address impairedAsset;
        address seller;
        uint256 impairedGoldRef;
        uint256 shareId;
        uint256 sellerShares;
    }

    function _deployStack() internal returns (Stack memory s) {
        (address paxgAddr, address xautAddr) = (new MocksDeployer()).deployAll();

        DeployConfig.ProtocolConfig memory defaults = DeployConfig.loadProtocol(vm);
        address[] memory owners = new address[](1);
        owners[0] = admin;
        defaults.safeWallet = address(new MockSafeWallet(address(new MockSafeSingleton()), owners, 1));
        StackDeployer.StackConfig memory cfg = StackConfigBuilder.baseStackConfig(defaults, admin, paxgAddr, xautAddr);
        cfg.governance = StackConfigBuilder.governanceConfig(defaults, admin, 1 days, 1_000_000e18);
        cfg = _withStakingLaunchRoster(cfg);

        StackDeployer.StackDeployed memory d = StackDeployer.deployStack(cfg);
        RecoveryFundLensFacet recoveryFund = RecoveryFundLensFacet(address(d.governance.diamond));
        assertEq(recoveryFund.trustedRecoveryFundCore(), d.coreDiamond, "Fund trusted Core");
        assertFalse(PausableFacet(address(d.governance.diamond)).paused(), "Governance starts unpaused");
        PausableFacet corePause = PausableFacet(d.coreDiamond);
        assertTrue(corePause.paused(), "Core must remain paused through stack deployment");
        vm.prank(defaults.safeWallet);
        corePause.unpause();

        IVotes votes = IVotes(address(d.governance.diamond));
        vm.prank(admin);
        votes.delegate(admin);
        vm.warp(block.timestamp + 1);

        s.controller = ICyberGoldCore(address(d.core.diamond));
        s.token = ICyberGoldCore(address(d.core.diamond));
        s.coreDiamond = d.coreDiamond;
        s.governanceDiamond = address(d.governance.diamond);
        s.safeWallet = defaults.safeWallet;
    }

    function _deployMaxCardinalityStack() internal returns (Stack memory s) {
        DeployConfig.ProtocolConfig memory defaults = DeployConfig.loadProtocol(vm);
        address[] memory owners = new address[](1);
        owners[0] = admin;
        defaults.safeWallet = address(new MockSafeWallet(address(new MockSafeSingleton()), owners, 1));

        address[] memory assets = new address[](MAX_COMBINED_CORE_ASSETS);
        uint256[] memory targets = new uint256[](MAX_COMBINED_CORE_ASSETS);
        uint256[] memory goldRefs = new uint256[](MAX_COMBINED_CORE_ASSETS);
        targets[0] = 1_000_000 - (MAX_COMBINED_CORE_ASSETS - 1);
        for (uint256 i; i < assets.length; ++i) {
            assets[i] = address(new MockERC20("Governance Cardinality Asset", "GCA", 18));
            if (i != 0) targets[i] = 1;
            goldRefs[i] = 1 ether;
        }

        StackDeployer.StackConfig memory cfg = StackConfigBuilder.fullStackConfig(
            defaults,
            admin,
            address(0),
            assets,
            targets,
            goldRefs,
            defaults.basket.cygldRefGramsFp18,
            defaults.basket.maxTotalSupply
        );
        cfg.governance = StackConfigBuilder.governanceConfig(defaults, admin, 1 days, 1_000_000e18);
        cfg = _withStakingLaunchRoster(cfg);
        StackDeployer.StackDeployed memory d = StackDeployer.deployStack(cfg);

        vm.prank(defaults.safeWallet);
        PausableFacet(d.coreDiamond).unpause();
        IVotes votes = IVotes(address(d.governance.diamond));
        vm.prank(admin);
        votes.delegate(admin);
        vm.warp(block.timestamp + 1);

        s.controller = ICyberGoldCore(d.coreDiamond);
        s.token = ICyberGoldCore(d.coreDiamond);
        s.coreDiamond = d.coreDiamond;
        s.governanceDiamond = address(d.governance.diamond);
        s.safeWallet = defaults.safeWallet;
    }

    function _withStakingLaunchRoster(StackDeployer.StackConfig memory cfg)
        private
        returns (StackDeployer.StackConfig memory)
    {
        cfg.staking.allocators = new address[](1);
        cfg.staking.allocators[0] = admin;
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(0), true, 0);
        cfg.sleeveAssetBindings = new StackDeployer.SleeveAssetBinding[](1);
        cfg.sleeveAssetBindings[0] = StackDeployer.SleeveAssetBinding.CoreDiamond;
        return cfg;
    }

    function _executeSingle(GovernorCoreFacet gov, address target, bytes memory data, string memory desc)
        internal
        returns (uint256 proposalId)
    {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = target;
        calldatas[0] = data;

        proposalId = _executeBatch(gov, targets, values, calldatas, desc);
    }

    function _executeBatch(
        GovernorCoreFacet gov,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory desc
    ) internal returns (uint256 proposalId) {
        proposalId = _passBatch(gov, targets, values, calldatas, desc);
        bytes32 descHash = keccak256(bytes(desc));
        vm.warp(gov.proposalEta(proposalId));
        gov.execute(targets, values, calldatas, descHash);
    }

    function _passBatch(
        GovernorCoreFacet gov,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory desc
    ) internal returns (uint256 proposalId) {
        proposalId = gov.propose(targets, values, calldatas, desc);
        vm.warp(gov.proposalSnapshot(proposalId) + 1);
        gov.castVote(proposalId, 1);
        vm.warp(gov.proposalDeadline(proposalId) + 1);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Queued));
        assertFalse(gov.proposalNeedsQueuing(proposalId));
    }

    function _singleCall(address target, bytes memory data)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = target;
        calldatas[0] = data;
    }

    function _beginCoreAuthorityHandover(Stack memory s) internal {
        DefaultAdminAccessControlFacet coreAccess = DefaultAdminAccessControlFacet(s.coreDiamond);
        bytes32 defaultAdminRole = coreAccess.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = coreAccess.upgraderRole();

        assertEq(coreAccess.defaultAdmin(), s.safeWallet, "Safe starts as Core default admin");
        assertEq(coreAccess.defaultAdminDelay(), 0, "Core transfer delay is fixed at zero");
        assertTrue(coreAccess.hasRole(defaultAdminRole, s.safeWallet), "Safe starts with Core default admin role");
        assertTrue(coreAccess.hasRole(upgraderRole, s.safeWallet), "Safe starts with Core upgrader role");
        assertFalse(coreAccess.hasRole(defaultAdminRole, s.governanceDiamond));
        assertFalse(coreAccess.hasRole(upgraderRole, s.governanceDiamond));

        vm.prank(s.safeWallet);
        coreAccess.beginDefaultAdminTransfer(s.governanceDiamond);

        (address pendingAdmin, uint48 acceptSchedule) = coreAccess.pendingDefaultAdmin();
        assertEq(pendingAdmin, s.governanceDiamond, "Governance is the explicit pending Core admin");
        assertEq(acceptSchedule, uint48(block.timestamp), "zero configured delay schedules the current timestamp");
    }

    function _coreAuthorityHandoverBatch(Stack memory s, bool appendDeliberateFailure)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        DefaultAdminAccessControlFacet coreAccess = DefaultAdminAccessControlFacet(s.coreDiamond);
        bytes32 upgraderRole = coreAccess.upgraderRole();
        uint256 callCount = appendDeliberateFailure ? 4 : 3;
        targets = new address[](callCount);
        values = new uint256[](callCount);
        calldatas = new bytes[](callCount);
        for (uint256 i; i < callCount; ++i) {
            targets[i] = s.coreDiamond;
        }

        // Keep this exact order: Governance accepts default admin, gives itself upgrade authority,
        // then removes the Safe's upgrade authority in the same Governor execution transaction.
        calldatas[0] = abi.encodeCall(IAccessControlDefaultAdminRules.acceptDefaultAdminTransfer, ());
        calldatas[1] = abi.encodeCall(IAccessControl.grantRole, (upgraderRole, s.governanceDiamond));
        calldatas[2] = abi.encodeCall(IAccessControl.revokeRole, (upgraderRole, s.safeWallet));
        if (appendDeliberateFailure) {
            calldatas[3] = abi.encodeCall(IAccessControlDefaultAdminRules.changeDefaultAdminDelay, (uint48(1)));
        }
    }

    function _executeCoreAuthorityHandover(Stack memory s, string memory description) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _coreAuthorityHandoverBatch(s, false);
        _executeBatch(GovernorCoreFacet(payable(s.governanceDiamond)), targets, values, calldatas, description);

        DefaultAdminAccessControlFacet coreAccess = DefaultAdminAccessControlFacet(s.coreDiamond);
        bytes32 defaultAdminRole = coreAccess.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = coreAccess.upgraderRole();
        assertEq(coreAccess.defaultAdmin(), s.governanceDiamond, "Governance accepted Core default admin");
        assertTrue(coreAccess.hasRole(defaultAdminRole, s.governanceDiamond));
        assertTrue(coreAccess.hasRole(upgraderRole, s.governanceDiamond));
        assertFalse(coreAccess.hasRole(defaultAdminRole, s.safeWallet));
        assertFalse(coreAccess.hasRole(upgraderRole, s.safeWallet));
        (address pendingAdmin, uint48 acceptSchedule) = coreAccess.pendingDefaultAdmin();
        assertEq(pendingAdmin, address(0));
        assertEq(acceptSchedule, 0);
    }

    function _issueCygld(Stack memory s, uint256 netCygldOut) internal {
        (, uint256[] memory amountsIn, address[] memory assets) =
            s.controller.previewIssueFromBasketExactOut(netCygldOut);
        assertEq(amountsIn.length, assets.length, "issuance quote lengths");
        for (uint256 i; i < assets.length; ++i) {
            MockERC20(assets[i]).mint(address(this), amountsIn[i]);
            IERC20(assets[i]).approve(s.coreDiamond, type(uint256).max);
        }
        (uint256 issuedNetCygldOut,,) = s.controller.issue(netCygldOut);
        assertEq(issuedNetCygldOut, netCygldOut, "exact CYGLD issuance");
    }

    function _pauseGovernance(Stack memory s) internal {
        vm.prank(admin);
        PausableFacet(s.governanceDiamond).pause();
        assertTrue(PausableFacet(s.governanceDiamond).paused(), "Governance paused");
    }

    function _unpauseGovernance(Stack memory s) internal {
        vm.prank(s.safeWallet);
        PausableFacet(s.governanceDiamond).unpause();
        assertFalse(PausableFacet(s.governanceDiamond).paused(), "Governance unpaused");
    }

    function _basketWithout(ICyberGoldCore core, address excluded)
        internal
        view
        returns (address[] memory assets, uint256[] memory targets, uint256[] memory goldRefs)
    {
        address[] memory currentAssets = core.basketAssets();
        uint256[] memory currentTargets = core.basketTargetsPpm();
        uint256[] memory currentGoldRefs = core.basketGoldRefGramsFp18();
        uint256 count;
        for (uint256 i; i < currentAssets.length; ++i) {
            if (currentAssets[i] != excluded) ++count;
        }

        assets = new address[](count);
        targets = new uint256[](count);
        goldRefs = new uint256[](count);
        uint256 writeIndex;
        uint256 positiveTotal;
        for (uint256 i; i < currentAssets.length; ++i) {
            if (currentAssets[i] == excluded) continue;
            assets[writeIndex] = currentAssets[i];
            targets[writeIndex] = currentTargets[i];
            goldRefs[writeIndex] = currentGoldRefs[i];
            positiveTotal += currentTargets[i];
            ++writeIndex;
        }
        if (count != 0 && positiveTotal != 0 && positiveTotal != 1_000_000) {
            for (uint256 i; i < targets.length; ++i) {
                if (targets[i] == 0) continue;
                targets[i] += 1_000_000 - positiveTotal;
                break;
            }
        }
    }

    function _activateCoreRecovery(Stack memory s, address impairedAsset) internal {
        IRecoveryTypes.RecoveryActivation memory request;
        request.impairedAsset = impairedAsset;
        request.expectedLifecycle = s.controller.reserveLifecycle(impairedAsset).lifecycle;
        request.expectedBasketHash = s.controller.basketConfigHash();
        IRecoveryTypes.RecoveryPoolView memory pool = s.controller.recoveryPool(impairedAsset);
        uint256 liveRaw = IERC20(impairedAsset).balanceOf(s.coreDiamond);
        request.expectedEntitlementRaw = liveRaw - pool.redeemableRaw;
        (request.replacementBasketAssets, request.replacementTargetsPpm, request.replacementGoldRefGramsFp18) =
            _basketWithout(s.controller, impairedAsset);
        request.cygldSupplyCap = s.controller.maxTotalSupply();

        vm.prank(s.safeWallet);
        s.controller.activateRecovery(request);
    }

    function _rehabilitateCoreRecovery(Stack memory s, RecoveryScenario memory scenario) internal {
        IRecoveryTypes.RecoveryPoolView memory pool = s.controller.recoveryPool(scenario.impairedAsset);
        IRecoveryTypes.RecoveryRehabilitation memory request;
        request.impairedAsset = scenario.impairedAsset;
        request.expectedBasketHash = s.controller.basketConfigHash();
        request.resultingBasketAssets = s.controller.basketAssets();
        request.resultingTargetsPpm = s.controller.basketTargetsPpm();
        request.resultingGoldRefGramsFp18 = s.controller.basketGoldRefGramsFp18();
        uint256 totalShares = pool.coreAttachedShares + pool.externalShares;
        uint256 custody = IERC20(scenario.impairedAsset).balanceOf(s.coreDiamond);
        uint256 externalRaw =
            totalShares == 0 ? 0 : Math.mulDiv(Math.min(custody, totalShares), pool.externalShares, totalShares);
        request.minimumTotalPoolRaw = custody;
        request.minimumCoreRaw = custody - externalRaw;
        request.minimumExternalRaw = externalRaw;
        // Rehabilitation restores Active membership even when all rights are external.
        {
            uint256 currentLength = request.resultingBasketAssets.length;
            address[] memory assets = new address[](currentLength + 1);
            uint256[] memory targets = new uint256[](currentLength + 1);
            uint256[] memory goldRefs = new uint256[](currentLength + 1);
            for (uint256 i; i < currentLength; ++i) {
                assets[i] = request.resultingBasketAssets[i];
                targets[i] = 1_000_000 / (currentLength + 1);
                goldRefs[i] = request.resultingGoldRefGramsFp18[i];
            }
            assets[currentLength] = scenario.impairedAsset;
            targets[currentLength] = 1_000_000 - currentLength * (1_000_000 / (currentLength + 1));
            goldRefs[currentLength] = scenario.impairedGoldRef;
            request.resultingBasketAssets = assets;
            request.resultingTargetsPpm = targets;
            request.resultingGoldRefGramsFp18 = goldRefs;
        }

        vm.prank(admin);
        PausableFacet(s.coreDiamond).pause();
        vm.prank(s.safeWallet);
        s.controller.rehabilitateRecoveryAsset(request);
        vm.prank(s.safeWallet);
        PausableFacet(s.coreDiamond).unpause();
    }

    function _assertProtectedAccountTopology(Stack memory s) internal view {
        IERC165 introspection = IERC165(s.governanceDiamond);
        assertTrue(introspection.supportsInterface(type(ICygldOutflowCallback).interfaceId), "CYGLD outflow policy");
        assertTrue(introspection.supportsInterface(type(ICygldApprovalCallback).interfaceId), "CYGLD approval policy");
        assertTrue(
            introspection.supportsInterface(type(IRecoveryShareOutflowCallback).interfaceId),
            "recovery-share outflow policy"
        );
        assertTrue(
            introspection.supportsInterface(type(IRecoveryShareRedemptionCallback).interfaceId),
            "recovery-share redemption policy"
        );

        IDiamondLoupe loupe = IDiamondLoupe(s.governanceDiamond);
        address recoveryFundFacet = loupe.facetAddress(RecoveryFundFacet.activateAssetRecoveryFund.selector);
        assertTrue(recoveryFundFacet != address(0), "Recovery Fund facet installed");
        assertEq(
            loupe.facetAddress(ICygldOutflowCallback.onCygldOutflow.selector),
            recoveryFundFacet,
            "CYGLD outflow selector owner"
        );
        assertEq(
            loupe.facetAddress(ICygldApprovalCallback.onCygldApprovalChange.selector),
            recoveryFundFacet,
            "CYGLD approval selector owner"
        );
        assertEq(
            loupe.facetAddress(IRecoveryShareOutflowCallback.onRecoveryShareOutflow.selector),
            recoveryFundFacet,
            "recovery-share outflow selector owner"
        );
        assertEq(
            loupe.facetAddress(IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector),
            recoveryFundFacet,
            "recovery-share redemption selector owner"
        );

        IDiamondLoupe.Facet[] memory facets = loupe.facets();
        uint256 selectorCount;
        for (uint256 i; i < facets.length; ++i) {
            selectorCount += facets[i].functionSelectors.length;
        }
        assertEq(facets.length, 10, "exact Governance facet count");
        assertEq(selectorCount, 98, "exact Governance selector count");
    }

    function _externalizeRecoveryInterest(Stack memory s) internal returns (RecoveryScenario memory scenario) {
        vm.startPrank(s.safeWallet);
        s.controller.setIssuanceFeePpm(s.controller.issuanceFeePpm(), 0);
        s.controller.setRedemptionFeePpm(s.controller.redemptionFeePpm(), 0);
        vm.stopPrank();

        _issueCygld(s, 200 ether);
        scenario.seller = address(0xA11CE);
        assertTrue(s.token.transfer(scenario.seller, s.token.balanceOf(address(this))));
        scenario.impairedAsset = s.controller.basketAssets()[0];
        scenario.impairedGoldRef = s.controller.basketGoldRefGramsFp18()[0];
        scenario.shareId = uint256(uint160(scenario.impairedAsset));
        _activateCoreRecovery(s, scenario.impairedAsset);

        uint256 sellerCygld = s.token.balanceOf(scenario.seller);
        vm.prank(scenario.seller);
        s.controller.redeem(sellerCygld);
        scenario.sellerShares = s.controller.balanceOf(scenario.seller, scenario.shareId);
        assertGt(scenario.sellerShares, 0, "seller received real recovery shares");
    }

    function _activateRecoveryFund(
        Stack memory s,
        GovernorCoreFacet gov,
        RecoveryFundLensFacet fundLens,
        RecoveryScenario memory scenario
    ) internal returns (uint64 generation, uint256 cygldOut, uint256 coverage) {
        _issueCygld(s, 200 ether);
        assertTrue(s.token.transfer(s.governanceDiamond, 150 ether));

        IRecoveryTypes.RecoveryPoolView memory pool = s.controller.recoveryPool(scenario.impairedAsset);
        coverage = pool.coreAttachedShares + s.controller.totalSupply(scenario.shareId)
            - s.controller.balanceOf(s.governanceDiamond, scenario.shareId);
        assertGe(coverage, scenario.sellerShares, "Fund covers seller and current Core interest");
        uint256 commitment = Math.mulDiv(coverage, pool.referenceValueCygld, pool.referenceShares);
        assertGe(s.token.balanceOf(s.governanceDiamond), commitment, "Governance can fund the typed reference ceiling");
        assertGt(commitment, coverage, "gold-token native shares need not satisfy raw M <= Q");

        IRecoveryFundTypes.AssetRecoveryFundActivation memory activation = IRecoveryFundTypes.AssetRecoveryFundActivation({
            impairedAsset: scenario.impairedAsset,
            expectedNextGeneration: 1,
            expectedCoverageShares: coverage,
            cygldCommitment: commitment
        });
        _executeSingle(
            gov,
            s.governanceDiamond,
            abi.encodeCall(RecoveryFundFacet.activateAssetRecoveryFund, (activation)),
            "Activate real impaired-asset Recovery Fund"
        );

        (generation, cygldOut) =
            fundLens.previewAssetRecoveryFundPurchase(scenario.impairedAsset, scenario.sellerShares);
        assertEq(generation, 1);
        assertEq(cygldOut, Math.mulDiv(commitment, scenario.sellerShares, coverage), "frozen typed-reference purchase");
    }

    function _sellRecoverySharesToFund(
        Stack memory s,
        RecoveryFundLensFacet fundLens,
        RecoveryScenario memory scenario,
        uint64 generation,
        uint256 cygldOut,
        uint256 coverage
    ) internal {
        uint256 sellerCygldBefore = s.token.balanceOf(scenario.seller);
        vm.prank(scenario.seller);
        s.controller
            .safeTransferFrom(
                scenario.seller,
                s.governanceDiamond,
                scenario.shareId,
                scenario.sellerShares,
                abi.encode(
                    IRecoveryFundTypes.RecoveryFundPurchaseCallback({
                        expectedGeneration: generation, minimumCygldOut: cygldOut
                    })
                )
            );
        assertEq(s.token.balanceOf(scenario.seller) - sellerCygldBefore, cygldOut, "seller paid atomically");
        assertEq(
            fundLens.acquiredRecoveryShares(scenario.impairedAsset),
            scenario.sellerShares,
            "lens reads live Core inventory"
        );
        assertEq(
            s.controller.balanceOf(s.governanceDiamond, scenario.shareId),
            scenario.sellerShares,
            "Core owns inventory source"
        );

        IRecoveryFundTypes.AssetRecoveryFundView memory exhausted = fundLens.assetRecoveryFund(scenario.impairedAsset);
        assertEq(exhausted.generation, 1);
        if (coverage == scenario.sellerShares) {
            assertEq(exhausted.coverageShares, 0, "full purchase exhausts facility");
            assertEq(exhausted.purchasedShares, 0);
            assertEq(exhausted.initialCygldCommitment, 0);
        } else {
            assertEq(exhausted.coverageShares, coverage, "active facility retains original coverage");
            assertEq(exhausted.purchasedShares, scenario.sellerShares, "purchase tracked cumulatively");
            IRecoveryTypes.RecoveryPoolView memory pool = s.controller.recoveryPool(scenario.impairedAsset);
            assertEq(
                exhausted.initialCygldCommitment,
                Math.mulDiv(coverage, pool.referenceValueCygld, pool.referenceShares),
                "commitment terms remain immutable"
            );
        }
    }

    function _rejectRecoveryShareDiversion(
        Stack memory s,
        RecoveryFundLensFacet fundLens,
        RecoveryScenario memory scenario,
        address divertedRecipient
    ) internal {
        vm.prank(s.governanceDiamond);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundRecoveryShareOutflowForbidden.selector,
                s.governanceDiamond,
                divertedRecipient
            )
        );
        s.controller.safeTransferFrom(s.governanceDiamond, divertedRecipient, scenario.shareId, 1, "");
        assertEq(
            fundLens.acquiredRecoveryShares(scenario.impairedAsset),
            scenario.sellerShares,
            "forbidden outflow rolled back"
        );
    }

    function _redeemProtectedRecoveryShares(
        Stack memory s,
        RecoveryFundLensFacet fundLens,
        RecoveryScenario memory scenario,
        address divertedRecipient,
        bool rehabilitate
    ) internal {
        if (rehabilitate) _rehabilitateCoreRecovery(s, scenario);
        uint256 rawOut = s.controller.previewRedeemRecoveryShares(scenario.impairedAsset, scenario.sellerShares);
        uint256 governanceRawBefore = IERC20(scenario.impairedAsset).balanceOf(s.governanceDiamond);
        uint256 poolRawBefore = s.controller.recoveryPool(scenario.impairedAsset).redeemableRaw;

        vm.prank(s.governanceDiamond);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRecoveryFundTypes.RecoveryFundRedemptionRecipientInvalid.selector, divertedRecipient
            )
        );
        s.controller.redeemRecoveryShares(scenario.impairedAsset, scenario.sellerShares, divertedRecipient, 0);
        assertEq(
            fundLens.acquiredRecoveryShares(scenario.impairedAsset),
            scenario.sellerShares,
            "diverted redemption share rollback"
        );
        assertEq(
            s.controller.recoveryPool(scenario.impairedAsset).redeemableRaw,
            poolRawBefore,
            "diverted redemption pool rollback"
        );

        vm.prank(s.governanceDiamond);
        uint256 paid = s.controller
        .redeemRecoveryShares(scenario.impairedAsset, scenario.sellerShares, s.governanceDiamond, rawOut);
        assertEq(paid, rawOut);
        assertEq(IERC20(scenario.impairedAsset).balanceOf(s.governanceDiamond) - governanceRawBefore, rawOut);
        assertEq(fundLens.acquiredRecoveryShares(scenario.impairedAsset), 0, "live inventory clears after redemption");
        assertEq(s.controller.balanceOf(s.governanceDiamond, scenario.shareId), 0);
        assertEq(s.controller.totalSupply(scenario.shareId), 0);
    }

    function test_deployedGovernanceCoreCygldPoliciesPreservePauseAtomicity() external {
        Stack memory s = _deployStack();
        _assertProtectedAccountTopology(s);
        GovernorCoreFacet gov = GovernorCoreFacet(payable(s.governanceDiamond));
        address recipient = address(0xCA11);
        address spender = address(0x5EED);

        _issueCygld(s, 200 ether);
        assertTrue(s.token.transfer(s.governanceDiamond, 150 ether));

        uint256 governanceBalance = s.token.balanceOf(s.governanceDiamond);
        _executeSingle(
            gov,
            s.coreDiamond,
            abi.encodeCall(ICyberGoldCore.transfer, (recipient, 25 ether)),
            "Transfer protected Governance CYGLD through Core"
        );
        assertEq(s.token.balanceOf(s.governanceDiamond), governanceBalance - 25 ether);
        assertEq(s.token.balanceOf(recipient), 25 ether);

        {
            (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
                _singleCall(s.coreDiamond, abi.encodeCall(ICyberGoldCore.transfer, (recipient, 10 ether)));
            string memory description = "Attempt protected Governance CYGLD transfer while paused";
            uint256 proposalId = _passBatch(gov, targets, values, calldatas, description);
            uint256 balanceBefore = s.token.balanceOf(s.governanceDiamond);
            uint256 recipientBefore = s.token.balanceOf(recipient);

            _pauseGovernance(s);
            vm.warp(gov.proposalEta(proposalId));
            vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
            gov.execute(targets, values, calldatas, keccak256(bytes(description)));
            assertEq(s.token.balanceOf(s.governanceDiamond), balanceBefore, "failed transfer source rollback");
            assertEq(s.token.balanceOf(recipient), recipientBefore, "failed transfer recipient rollback");
            assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

            _unpauseGovernance(s);
            gov.execute(targets, values, calldatas, keccak256(bytes(description)));
            assertEq(s.token.balanceOf(s.governanceDiamond), balanceBefore - 10 ether);
            assertEq(s.token.balanceOf(recipient), recipientBefore + 10 ether);
        }

        {
            (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
                _singleCall(s.coreDiamond, abi.encodeCall(ICyberGoldCore.approve, (spender, 80 ether)));
            string memory description = "Attempt protected Governance CYGLD approval increase while paused";
            uint256 proposalId = _passBatch(gov, targets, values, calldatas, description);

            _pauseGovernance(s);
            vm.warp(gov.proposalEta(proposalId));
            vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
            gov.execute(targets, values, calldatas, keccak256(bytes(description)));
            assertEq(s.token.allowance(s.governanceDiamond, spender), 0, "failed approval rollback");
            assertEq(s.token.allowanceExposure(s.governanceDiamond), 0, "failed exposure rollback");
            assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

            _unpauseGovernance(s);
            gov.execute(targets, values, calldatas, keccak256(bytes(description)));
            assertEq(s.token.allowance(s.governanceDiamond, spender), 80 ether);
            assertEq(s.token.allowanceExposure(s.governanceDiamond), 80 ether);
        }

        {
            uint256 sourceBefore = s.token.balanceOf(s.governanceDiamond);
            uint256 recipientBefore = s.token.balanceOf(recipient);
            _pauseGovernance(s);
            vm.prank(spender);
            vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
            s.token.transferFrom(s.governanceDiamond, recipient, 30 ether);
            assertEq(s.token.allowance(s.governanceDiamond, spender), 80 ether, "finite allowance rollback");
            assertEq(s.token.allowanceExposure(s.governanceDiamond), 80 ether, "finite exposure rollback");
            assertEq(s.token.balanceOf(s.governanceDiamond), sourceBefore, "finite source rollback");
            assertEq(s.token.balanceOf(recipient), recipientBefore, "finite recipient rollback");

            _unpauseGovernance(s);
            vm.prank(spender);
            assertTrue(s.token.transferFrom(s.governanceDiamond, recipient, 30 ether));
            assertEq(s.token.allowance(s.governanceDiamond, spender), 50 ether);
            assertEq(s.token.allowanceExposure(s.governanceDiamond), 50 ether);
        }

        _executeSingle(
            gov,
            s.coreDiamond,
            abi.encodeCall(ICyberGoldCore.approve, (spender, type(uint256).max)),
            "Grant protected Governance infinite CYGLD allowance"
        );
        {
            uint256 sourceBefore = s.token.balanceOf(s.governanceDiamond);
            uint256 recipientBefore = s.token.balanceOf(recipient);
            _pauseGovernance(s);
            vm.prank(spender);
            vm.expectRevert(ENFORCED_PAUSE_SELECTOR);
            s.token.transferFrom(s.governanceDiamond, recipient, 1 ether);
            assertEq(s.token.allowance(s.governanceDiamond, spender), type(uint256).max, "infinite allowance unchanged");
            assertEq(s.token.balanceOf(s.governanceDiamond), sourceBefore, "infinite source rollback");
            assertEq(s.token.balanceOf(recipient), recipientBefore, "infinite recipient rollback");

            _unpauseGovernance(s);
            vm.prank(spender);
            assertTrue(s.token.transferFrom(s.governanceDiamond, recipient, 1 ether));
            assertEq(s.token.allowance(s.governanceDiamond, spender), type(uint256).max);
        }

        _pauseGovernance(s);
        _executeSingle(
            gov,
            s.coreDiamond,
            abi.encodeCall(ICyberGoldCore.approve, (spender, 5 ether)),
            "Reduce protected Governance CYGLD allowance while paused"
        );
        assertEq(s.token.allowance(s.governanceDiamond, spender), 5 ether, "paused reduction remains available");
        assertEq(s.token.allowanceExposure(s.governanceDiamond), 5 ether);
        _unpauseGovernance(s);
    }

    function test_deployedRecoveryFundPurchaseAndProtectedCoreRedemption() external {
        _assertDeployedRecoveryFundPurchaseAndRedemption(true);
    }

    function test_deployedRecoveryFundPurchaseAndImmediateImpairedRedemption() external {
        _assertDeployedRecoveryFundPurchaseAndRedemption(false);
    }

    function _assertDeployedRecoveryFundPurchaseAndRedemption(bool rehabilitate) internal {
        Stack memory s = _deployStack();
        _assertProtectedAccountTopology(s);
        GovernorCoreFacet gov = GovernorCoreFacet(payable(s.governanceDiamond));
        RecoveryFundLensFacet fundLens = RecoveryFundLensFacet(s.governanceDiamond);
        RecoveryScenario memory scenario = _externalizeRecoveryInterest(s);
        (uint64 generation, uint256 cygldOut, uint256 coverage) = _activateRecoveryFund(s, gov, fundLens, scenario);
        _sellRecoverySharesToFund(s, fundLens, scenario, generation, cygldOut, coverage);

        address divertedRecipient = address(0xD1E7);
        _rejectRecoveryShareDiversion(s, fundLens, scenario, divertedRecipient);
        _redeemProtectedRecoveryShares(s, fundLens, scenario, divertedRecipient, rehabilitate);
    }

    function _assertGovernanceTreasuryWithdrawal(GovernorCoreFacet gov, address govDiamond) internal {
        MockERC20 asset = new MockERC20("Treasury Asset", "TAST", 18);
        address recipient = address(0xCAFE);
        asset.mint(govDiamond, 42 ether);

        vm.expectRevert();
        vm.prank(admin);
        ICyberGoldGovernance(govDiamond).treasuryWithdraw(address(asset), recipient, 25 ether);

        _executeSingle(
            gov,
            govDiamond,
            abi.encodeWithSelector(ICyberGoldGovernance.treasuryWithdraw.selector, address(asset), recipient, 25 ether),
            "Withdraw native treasury ERC20 asset"
        );

        assertEq(asset.balanceOf(recipient), 25 ether, "recipient received treasury assets");
        assertEq(asset.balanceOf(govDiamond), 17 ether, "treasury retained remainder");
    }

    function test_governanceSettingsSetters_updateActiveDiamondGetters() external {
        Stack memory s = _deployStack();
        address govDiamond = s.governanceDiamond;
        GovernorCoreFacet gov = GovernorCoreFacet(payable(govDiamond));

        uint256 initialDelay = gov.votingDelay();
        uint256 initialPeriod = gov.votingPeriod();
        uint256 initialThreshold = gov.proposalThreshold();
        uint256 initialThresholdNumerator = GovernorSettingsFacet(govDiamond).proposalThresholdNumerator();

        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory calldatas = new bytes[](3);
        targets[0] = govDiamond;
        targets[1] = govDiamond;
        targets[2] = govDiamond;
        // Default governance delays are far below uint48 and uint32 limits in this test deployment.
        calldatas[0] = abi.encodeWithSelector(
            IGovernorSettingsActions.setVotingDelay.selector,
            uint48(initialDelay), // forge-lint: disable-line(unsafe-typecast)
            uint48(initialDelay + 1) // forge-lint: disable-line(unsafe-typecast)
        );
        calldatas[1] = abi.encodeWithSelector(
            IGovernorSettingsActions.setVotingPeriod.selector,
            uint32(initialPeriod), // forge-lint: disable-line(unsafe-typecast)
            uint32(initialPeriod + 1) // forge-lint: disable-line(unsafe-typecast)
        );
        calldatas[2] = abi.encodeWithSelector(
            IGovernorSettingsActions.setProposalThresholdNumerator.selector,
            uint32(initialThresholdNumerator), // forge-lint: disable-line(unsafe-typecast)
            uint32(initialThresholdNumerator + 1) // forge-lint: disable-line(unsafe-typecast)
        );

        _executeBatch(gov, targets, values, calldatas, "Update governor settings through deployed diamond selectors");

        assertEq(gov.votingDelay(), initialDelay + 1, "active votingDelay getter updated");
        assertEq(gov.votingPeriod(), initialPeriod + 1, "active votingPeriod getter updated");
        assertEq(
            GovernorSettingsFacet(govDiamond).proposalThresholdNumerator(),
            initialThresholdNumerator + 1,
            "active proposal threshold numerator updated"
        );
        assertGt(gov.proposalThreshold(), initialThreshold, "dynamic proposal threshold getter updated");
    }

    function test_governanceExecutionGasAt64MemberCoreBasket() external {
        Stack memory s = _deployMaxCardinalityStack();
        GovernorCoreFacet gov = GovernorCoreFacet(payable(s.governanceDiamond));
        ICyberGoldCore core = ICyberGoldCore(s.coreDiamond);

        _beginCoreAuthorityHandover(s);
        _executeCoreAuthorityHandover(s, "Transfer maximal-basket Core authority to Governance");
        assertFalse(core.hasRole(bytes32(0), admin));
        assertTrue(core.hasRole(bytes32(0), s.governanceDiamond));

        address[] memory assets = core.basketAssets();
        uint256[] memory targets = core.basketTargetsPpm();
        uint256[] memory goldRefs = core.basketGoldRefGramsFp18();
        assertEq(assets.length, MAX_COMBINED_CORE_ASSETS);
        targets[0] -= 1;
        targets[1] += 1;

        (address[] memory proposalTargets, uint256[] memory values, bytes[] memory calldatas) = _singleCall(
            s.coreDiamond,
            abi.encodeCall(ICyberGoldCore.setBasket, (core.basketConfigHash(), assets, targets, goldRefs))
        );
        string memory description = "Governance-authorized legal 64-member Core basket mutation";
        uint256 proposalId = _passBatch(gov, proposalTargets, values, calldatas, description);
        vm.warp(gov.proposalEta(proposalId));

        uint256 gasStart = gasleft();
        gov.execute(proposalTargets, values, calldatas, keccak256(bytes(description)));
        uint256 gasUsed = gasStart - gasleft();
        emit log_named_uint("Governance execution gas for legal 64-member Core basket mutation", gasUsed);
        assertLt(gasUsed, AUTHORITY_OPERATION_GAS_CEILING);

        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
        assertEq(core.basketAssets(), assets);
        assertEq(core.basketTargetsPpm(), targets);
    }

    function test_coreDefaultAdminTransferCancellationPreservesSafeAuthority() external {
        Stack memory s = _deployStack();
        DefaultAdminAccessControlFacet coreAccess = DefaultAdminAccessControlFacet(s.coreDiamond);
        bytes32 defaultAdminRole = coreAccess.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = coreAccess.upgraderRole();

        _beginCoreAuthorityHandover(s);
        vm.prank(s.safeWallet);
        coreAccess.cancelDefaultAdminTransfer();

        (address pendingAdmin, uint48 acceptSchedule) = coreAccess.pendingDefaultAdmin();
        assertEq(pendingAdmin, address(0));
        assertEq(acceptSchedule, 0);
        assertEq(coreAccess.defaultAdmin(), s.safeWallet);
        assertTrue(coreAccess.hasRole(defaultAdminRole, s.safeWallet));
        assertTrue(coreAccess.hasRole(upgraderRole, s.safeWallet));
        assertFalse(coreAccess.hasRole(defaultAdminRole, s.governanceDiamond));
        assertFalse(coreAccess.hasRole(upgraderRole, s.governanceDiamond));

        vm.prank(s.governanceDiamond);
        vm.expectRevert();
        coreAccess.acceptDefaultAdminTransfer();
    }

    function test_failedCoreAuthorityBatchRollsBackAcceptanceAndRoleChanges() external {
        Stack memory s = _deployStack();
        DefaultAdminAccessControlFacet coreAccess = DefaultAdminAccessControlFacet(s.coreDiamond);
        bytes32 defaultAdminRole = coreAccess.DEFAULT_ADMIN_ROLE();
        bytes32 upgraderRole = coreAccess.upgraderRole();

        _beginCoreAuthorityHandover(s);
        (address pendingBefore, uint48 scheduleBefore) = coreAccess.pendingDefaultAdmin();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _coreAuthorityHandoverBatch(s, true);
        GovernorCoreFacet gov = GovernorCoreFacet(payable(s.governanceDiamond));
        string memory description = "Deliberately fail after the complete Core authority handover sequence";
        uint256 proposalId = _passBatch(gov, targets, values, calldatas, description);
        vm.warp(gov.proposalEta(proposalId));

        vm.expectRevert(DefaultAdminAccessControlFacet.DefaultAdminDelayImmutable.selector);
        gov.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Queued));
        assertEq(coreAccess.defaultAdmin(), s.safeWallet, "acceptance rolled back");
        assertTrue(coreAccess.hasRole(defaultAdminRole, s.safeWallet));
        assertTrue(coreAccess.hasRole(upgraderRole, s.safeWallet), "Safe upgrader revocation rolled back");
        assertFalse(coreAccess.hasRole(defaultAdminRole, s.governanceDiamond));
        assertFalse(coreAccess.hasRole(upgraderRole, s.governanceDiamond), "Governance upgrader grant rolled back");
        (address pendingAfter, uint48 scheduleAfter) = coreAccess.pendingDefaultAdmin();
        assertEq(pendingAfter, pendingBefore, "pending candidate survives reverted acceptance");
        assertEq(scheduleAfter, scheduleBefore, "pending schedule survives reverted acceptance");
    }

    function test_directGovernorExecution_executesGovernanceApprovedDiamondCut() external {
        Stack memory s = _deployStack();
        address govDiamond = s.governanceDiamond;
        GovernorCoreFacet gov = GovernorCoreFacet(payable(govDiamond));
        GovernanceUpgradeProbeFacet probe = new GovernanceUpgradeProbeFacet();
        GovernanceUpgradeInit upgradeInit = new GovernanceUpgradeInit();
        bytes4 selector = GovernanceUpgradeProbeFacet.upgradeProbe.selector;

        assertEq(IDiamondLoupe(govDiamond).facetAddress(selector), address(0), "probe starts uninstalled");

        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(probe), action: IDiamond.FacetCutAction.Add, functionSelectors: selectors
        });

        _executeSingle(
            gov,
            govDiamond,
            abi.encodeWithSelector(
                IDiamondCut.diamondCut.selector,
                cut,
                address(upgradeInit),
                abi.encodeCall(GovernanceUpgradeInit.init, (address(probe)))
            ),
            "Install recovery probe through queue-free Governor execution"
        );

        assertEq(IDiamondLoupe(govDiamond).facetAddress(selector), address(probe), "proposal installed probe facet");
        assertEq(
            GovernanceUpgradeProbeFacet(govDiamond).upgradeProbe(),
            keccak256("cybergold.governance.direct-execution-upgrade-probe")
        );

        uint256 executionDelayBeforeCanary = GovernorSettingsFacet(govDiamond).executionDelay();
        uint256 canaryProposalId = _executeSingle(
            gov,
            govDiamond,
            abi.encodeWithSelector(
                IGovernorSettingsActions.setExecutionDelay.selector,
                uint48(executionDelayBeforeCanary), // forge-lint: disable-line(unsafe-typecast)
                uint48(executionDelayBeforeCanary + 1) // forge-lint: disable-line(unsafe-typecast)
            ),
            "Post-cut execution-policy canary through a second Governance proposal"
        );
        assertEq(uint8(gov.state(canaryProposalId)), uint8(IGovernor.ProposalState.Executed));
        assertEq(
            GovernorSettingsFacet(govDiamond).executionDelay(),
            executionDelayBeforeCanary + 1,
            "canary updates the reviewed execution policy"
        );
    }

    function test_creationTimeWindowExpires_andExecutionRejects() external {
        Stack memory s = _deployStack();
        address govDiamond = s.governanceDiamond;
        GovernorCoreFacet gov = GovernorCoreFacet(payable(govDiamond));
        GovernorSettingsFacet settings = GovernorSettingsFacet(govDiamond);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = govDiamond;
        calldatas[0] =
            abi.encodeWithSelector(IGovernorSettingsActions.setVotingDelay.selector, uint48(2 days), uint48(3 days));
        string memory description = "Expire an approved settings operation";
        bytes32 descriptionHash = keccak256(bytes(description));

        uint256 proposalId = gov.propose(targets, values, calldatas, description);
        uint256 readyAt = gov.proposalDeadline(proposalId) + 1 + settings.executionDelay();
        uint256 expiresAt = readyAt + settings.executionGracePeriod();
        assertEq(gov.proposalEta(proposalId), readyAt);
        assertEq(gov.proposalExpiresAt(proposalId), expiresAt);

        vm.warp(gov.proposalSnapshot(proposalId) + 1);
        gov.castVote(proposalId, 1);
        vm.warp(gov.proposalDeadline(proposalId) + 1);

        vm.warp(expiresAt - 1);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        vm.warp(expiresAt);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Expired));
        vm.expectRevert();
        gov.execute(targets, values, calldatas, descriptionHash);

        assertEq(gov.votingDelay(), 2 days, "expired action did not mutate Governance settings");
    }

    function test_governanceGraceUpdateOnlyAffectsProposalsCreatedAfterExecution() external {
        Stack memory s = _deployStack();
        address govDiamond = s.governanceDiamond;
        GovernorCoreFacet gov = GovernorCoreFacet(payable(govDiamond));
        GovernorSettingsFacet settings = GovernorSettingsFacet(govDiamond);

        (address[] memory oldTargets, uint256[] memory oldValues, bytes[] memory oldCalldatas) = _singleCall(
            govDiamond,
            abi.encodeWithSelector(IGovernorSettingsActions.setVotingDelay.selector, uint48(2 days), uint48(3 days))
        );
        uint256 oldProposalId = _passBatch(
            gov, oldTargets, oldValues, oldCalldatas, "Create under the initial fourteen-day execution window"
        );
        uint256 oldExpiry = gov.proposalExpiresAt(oldProposalId);
        assertEq(oldExpiry, gov.proposalEta(oldProposalId) + 14 days);

        _executeSingle(
            gov,
            govDiamond,
            abi.encodeWithSelector(
                IGovernorSettingsActions.setExecutionGracePeriod.selector, uint48(14 days), uint48(1 days)
            ),
            "Set the execution grace period to its one-day lower bound"
        );
        assertEq(settings.executionGracePeriod(), 1 days);
        assertEq(gov.proposalExpiresAt(oldProposalId), oldExpiry, "existing proposal retained its expiry snapshot");

        (address[] memory newTargets, uint256[] memory newValues, bytes[] memory newCalldatas) = _singleCall(
            govDiamond,
            abi.encodeWithSelector(IGovernorSettingsActions.setVotingDelay.selector, uint48(2 days), uint48(4 days))
        );
        string memory newDescription = "Create under the updated one-day execution window";
        uint256 newProposalId = _passBatch(gov, newTargets, newValues, newCalldatas, newDescription);
        assertEq(gov.proposalExpiresAt(newProposalId), gov.proposalEta(newProposalId) + 1 days);

        vm.warp(gov.proposalEta(newProposalId));
        gov.execute(newTargets, newValues, newCalldatas, keccak256(bytes(newDescription)));
        assertEq(uint8(gov.state(newProposalId)), uint8(IGovernor.ProposalState.Executed));
        assertEq(gov.votingDelay(), 4 days);
    }

    function test_invalidGraceUpdateFailsDuringExecutionAndKeepsCurrentPolicy() external {
        Stack memory s = _deployStack();
        address govDiamond = s.governanceDiamond;
        GovernorCoreFacet gov = GovernorCoreFacet(payable(govDiamond));
        GovernorSettingsFacet settings = GovernorSettingsFacet(govDiamond);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleCall(
            govDiamond,
            abi.encodeWithSelector(
                IGovernorSettingsActions.setExecutionGracePeriod.selector, uint48(14 days), uint48(1 days - 1)
            )
        );
        string memory description = "Attempt an invalid execution grace period";
        uint256 proposalId = _passBatch(gov, targets, values, calldatas, description);
        uint256 expiresAt = gov.proposalExpiresAt(proposalId);

        vm.warp(gov.proposalEta(proposalId));
        vm.expectRevert(
            abi.encodeWithSelector(
                GovernorSettingsFacet.GovernorInvalidExecutionGracePeriod.selector,
                uint256(1 days - 1),
                uint256(1 days),
                uint256(30 days)
            )
        );
        gov.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertEq(settings.executionGracePeriod(), 14 days);
        assertEq(gov.proposalExpiresAt(proposalId), expiresAt);
        assertEq(uint8(gov.state(proposalId)), uint8(IGovernor.ProposalState.Queued));
    }

    function test_expiredActionCanOnlyProceedThroughFreshProposalAndVote() external {
        Stack memory s = _deployStack();
        address govDiamond = s.governanceDiamond;
        GovernorCoreFacet gov = GovernorCoreFacet(payable(govDiamond));
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _singleCall(
            govDiamond,
            abi.encodeWithSelector(IGovernorSettingsActions.setVotingDelay.selector, uint48(2 days), uint48(3 days))
        );

        uint256 staleProposalId =
            _passBatch(gov, targets, values, calldatas, "First authorization that will deliberately expire");
        vm.warp(gov.proposalExpiresAt(staleProposalId));
        assertEq(uint8(gov.state(staleProposalId)), uint8(IGovernor.ProposalState.Expired));

        string memory replacementDescription = "Fresh authorization for the formerly stale action";
        uint256 replacementProposalId = _passBatch(gov, targets, values, calldatas, replacementDescription);
        assertNotEq(replacementProposalId, staleProposalId);
        vm.warp(gov.proposalEta(replacementProposalId));
        gov.execute(targets, values, calldatas, keccak256(bytes(replacementDescription)));

        assertEq(uint8(gov.state(staleProposalId)), uint8(IGovernor.ProposalState.Expired));
        assertEq(uint8(gov.state(replacementProposalId)), uint8(IGovernor.ProposalState.Executed));
        assertEq(gov.votingDelay(), 3 days);
    }

    function test_permitDelegationAndBallotSignaturesShareOneNonceStream() external {
        Stack memory s = _deployStack();
        GovernorCoreFacet gov = GovernorCoreFacet(payable(s.governanceDiamond));
        GovernanceTokenFacet token = GovernanceTokenFacet(s.governanceDiamond);
        address signer = vm.addr(SIGNER_PK);
        address spender = address(0xCAFE);
        uint256 deadline = block.timestamp + 30 days;

        assertTrue(token.transfer(signer, 10 ether));
        vm.prank(signer);
        token.delegate(signer);
        vm.warp(block.timestamp + 1);

        (uint256 proposalId, bytes memory staleBallot) = _prepareSignedBallot(gov, token, signer, 0);
        assertEq(_usePermitNonce(token, signer, spender, deadline), 0);
        assertEq(token.nonces(signer), 1, "permit consumed the shared nonce");

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorInvalidSignature.selector, signer));
        gov.castVoteBySig(proposalId, 1, signer, staleBallot);
        assertEq(token.nonces(signer), 1, "reverted stale ballot did not consume a nonce");

        bytes memory ballot = _ballotSignature(gov, token, signer, proposalId, 1);
        gov.castVoteBySig(proposalId, 1, signer, ballot);
        assertEq(token.nonces(signer), 2, "ballot consumed the shared nonce");

        (uint8 stalePermitV, bytes32 stalePermitR, bytes32 stalePermitS) =
            _permitSignature(token, signer, spender, 2, deadline);
        assertEq(_useDelegationNonce(token, signer, spender, deadline), 2);
        assertEq(token.nonces(signer), 3, "delegation consumed the shared nonce");

        vm.expectRevert();
        token.permit(signer, spender, 1 ether, deadline, stalePermitV, stalePermitR, stalePermitS);
        assertEq(token.nonces(signer), 3, "reverted stale permit did not consume a nonce");
        assertEq(_usePermitNonce(token, signer, spender, deadline), 3);
        assertEq(token.nonces(signer), 4, "fresh permit used the nonce after delegation");
    }

    function _prepareSignedBallot(GovernorCoreFacet gov, GovernanceTokenFacet token, address signer, uint256 nonce)
        internal
        returns (uint256 proposalId, bytes memory signature)
    {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(0xBEEF);
        calldatas[0] = abi.encodeWithSignature("noop()");
        vm.prank(signer);
        proposalId = gov.propose(targets, values, calldatas, "Shared nonce ballot");
        vm.warp(block.timestamp + gov.votingDelay() + 1);
        signature = _ballotSignature(gov, token, signer, proposalId, nonce);
    }

    function _usePermitNonce(GovernanceTokenFacet token, address owner, address spender, uint256 deadline)
        internal
        returns (uint256 nonce)
    {
        nonce = token.nonces(owner);
        (uint8 v, bytes32 r, bytes32 s) = _permitSignature(token, owner, spender, nonce, deadline);
        token.permit(owner, spender, 1 ether, deadline, v, r, s);
    }

    function _permitSignature(
        GovernanceTokenFacet token,
        address owner,
        address spender,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, 1 ether, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(SIGNER_PK, digest);
    }

    function _useDelegationNonce(GovernanceTokenFacet token, address owner, address delegatee, uint256 expiry)
        internal
        returns (uint256 nonce)
    {
        nonce = token.nonces(owner);
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        token.delegateBySig(delegatee, nonce, expiry, v, r, s);
    }

    function _ballotSignature(
        GovernorCoreFacet gov,
        GovernanceTokenFacet token,
        address owner,
        uint256 proposalId,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(gov.BALLOT_TYPEHASH(), proposalId, uint8(1), owner, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_governance_proposal_lifecycle_setSplitFees_and_upgrade_auth() external {
        if (vm.envOr("USE_DEPLOYED", uint256(0)) == 1) {
            DeployedStack.Protocol memory p = DeployedStack.loadProtocol(vm);
            GovernorSettingsFacet settings = GovernorSettingsFacet(p.governanceDiamond);
            assertTrue(settings.executionDelay() >= 1 days);
            GovernorCoreFacet govDeployed = GovernorCoreFacet(payable(p.governanceDiamond));
            assertEq(govDeployed.clock(), uint48(block.timestamp));
            return;
        }

        Stack memory s = _deployStack();
        ICyberGoldCore controller = s.controller;
        address govDiamond = s.governanceDiamond;

        assertEq(s.coreDiamond, address(controller), "native reserve is core diamond");
        assertEq(CoreLensFacet(address(controller)).treasury(), govDiamond, "native treasury is governance diamond");

        // Hand Core authority to the already self-administered Governance diamond.
        AccessControlFacet govAccess = AccessControlFacet(govDiamond);
        _beginCoreAuthorityHandover(s);
        _executeCoreAuthorityHandover(s, "Accept Core administration and rotate upgrade authority atomically");
        assertTrue(govAccess.hasRole(govAccess.DEFAULT_ADMIN_ROLE(), govDiamond), "governance missing self admin");
        assertFalse(govAccess.hasRole(govAccess.DEFAULT_ADMIN_ROLE(), admin), "safe/admin retained governance admin");

        GovernorCoreFacet gov = GovernorCoreFacet(payable(govDiamond));
        address[] memory feeTargets = new address[](2);
        uint256[] memory feeValues = new uint256[](2);
        bytes[] memory feeCalldatas = new bytes[](2);
        feeTargets[0] = address(controller);
        feeTargets[1] = address(controller);
        feeCalldatas[0] = abi.encodeWithSelector(ICyberGoldCore.setIssuanceFeePpm.selector, 1_000, 5_000);
        feeCalldatas[1] = abi.encodeWithSelector(ICyberGoldCore.setRedemptionFeePpm.selector, 1_000, 4_000);

        _executeBatch(gov, feeTargets, feeValues, feeCalldatas, "Set CYGLD issuance/redemption fees");

        // Assert fees updated
        assertEq(controller.issuanceFeePpm(), 5_000, "issuance fee updated");
        assertEq(controller.redemptionFeePpm(), 4_000, "redemption fee updated");

        PausableFacet corePause = PausableFacet(address(controller));
        vm.prank(admin);
        corePause.pause();
        assertTrue(corePause.paused(), "core paused");

        vm.prank(s.safeWallet);
        corePause.unpause();

        assertFalse(corePause.paused(), "core unpaused by Safe wallet");

        _assertGovernanceTreasuryWithdrawal(gov, govDiamond);

        // Owner upgrade of governor/treasury not applicable to diamond facets; governance upgrades via diamond cuts.
    }
}
