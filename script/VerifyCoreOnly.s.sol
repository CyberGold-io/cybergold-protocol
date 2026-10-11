// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155MetadataURI} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {LensFacet as CoreLensFacet} from "packages/1_core/src/facets/LensFacet.sol";
import {CoreDiamond} from "packages/1_core/src/diamond/CoreDiamond.sol";
import {DeploymentHelper} from "packages/1_core/src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "packages/1_core/src/deploy/DeploymentTypes.sol";
import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {DiamondCutAccessFacet} from "diamond-infra/facets/DiamondCutAccessFacet.sol";
import {DiamondLoupeFacet} from "diamond-1/facets/DiamondLoupeFacet.sol";
import {ProtocolDiamondLoupeFacet} from "diamond-infra/facets/ProtocolDiamondLoupeFacet.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {ISafeWallet} from "diamond-infra/interfaces/ISafeWallet.sol";
import {TokenFacet} from "packages/1_core/src/facets/TokenFacet.sol";
import {IssuanceFacet} from "packages/1_core/src/facets/IssuanceFacet.sol";
import {RedemptionFacet} from "packages/1_core/src/facets/RedemptionFacet.sol";
import {RebalanceFacet} from "packages/1_core/src/facets/RebalanceFacet.sol";
import {PreviewFacet} from "packages/1_core/src/facets/PreviewFacet.sol";
import {BasketAdminFacet} from "packages/1_core/src/facets/BasketAdminFacet.sol";
import {ControllerConfigFacet} from "packages/1_core/src/facets/ControllerConfigFacet.sol";
import {ReserveLifecycleFacet} from "packages/1_core/src/facets/ReserveLifecycleFacet.sol";
import {RecoveryShareFacet} from "packages/1_core/src/facets/RecoveryShareFacet.sol";
import {RecoveryShareMetadataFacet} from "packages/1_core/src/facets/RecoveryShareMetadataFacet.sol";
import {RecoveryAdminFacet} from "packages/1_core/src/facets/RecoveryAdminFacet.sol";
import {RecoveryPoolSettlementFacet} from "packages/1_core/src/facets/RecoveryPoolSettlementFacet.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {CoreArtifacts} from "script/helpers/CoreArtifacts.sol";
import {JsonUtils} from "script/helpers/JsonUtils.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";
import {InitFacet} from "packages/1_core/src/facets/InitFacet.sol";
import {DiamondInit} from "packages/1_core/src/deploy/DiamondInit.sol";
import {CoreAuthorityInvariant} from "packages/1_core/src/deploy/CoreAuthorityInvariant.sol";
import {ICyberGoldCore} from "packages/1_core/src/interfaces/ICyberGoldCore.sol";
import {ICoreRedemption} from "packages/1_core/src/interfaces/ICoreRedemption.sol";
import {IRecoveryTypes} from "packages/1_core/src/interfaces/IRecoveryTypes.sol";
import {IRecoveryShareMetadata} from "packages/1_core/src/interfaces/IRecoveryShareMetadata.sol";

contract VerifyCoreOnly is Script {
    bytes32 internal constant RETIRED_REENTRANCY_GUARD_STORAGE_SLOT =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    bytes32 internal constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 internal constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");
    bytes32 internal constant RECOVERY_STORAGE_SLOT =
        0x9c93e9d30446027e39ff4d92a0e041074875ec5eab2dcf6938ecf6e407f2da00;

    struct CoreFacetArtifacts {
        address cut;
        address loupe;
        address access;
        address pause;
        address token;
        address issuance;
        address redemption;
        address rebalance;
        address preview;
        address basketAdmin;
        address config;
        address lens;
        address reserveLifecycle;
        address recoveryShare;
        address recoveryShareMetadata;
        address recoveryAdmin;
        address recoveryPoolSettlement;
        address init;
        address diamondInit;
        address authorityInvariant;
    }

    function run() external {
        DeployConfig.ProtocolConfig memory cfg = DeployConfig.loadProtocol(vm);
        CoreArtifacts.Core memory core = CoreArtifacts.load(vm);
        CoreArtifacts.requireCore(core);

        require(core.coreTreasury.code.length != 0, "VerifyCoreOnly: core treasury has no bytecode");
        require(core.coreDiamond.code.length != 0, "VerifyCoreOnly: core diamond has no bytecode");

        _verifyLocalDeployment(core.coreDiamond);
        _verifyOptionalSafe(core);
        _verifyControllerConfig(cfg, core);
        _verifyBasket(cfg, core.coreDiamond);
        _verifyExactNetIssuance(core.coreDiamond);
        _verifyRoles(core);
        _verifyInitializerState(core);
        _writeOutput(core);
        _logSummary(core);
    }

    function _verifyLocalDeployment(address coreDiamond) internal view {
        require(
            coreDiamond.codehash == keccak256(type(CoreDiamond).runtimeCode), "VerifyCoreOnly: diamond runtime mismatch"
        );
        CoreFacetArtifacts memory art = _loadFacetArtifacts();
        _verifyFacetCode(art.cut, keccak256(type(DiamondCutAccessFacet).runtimeCode), "cut");
        _verifyFacetCode(art.loupe, keccak256(type(ProtocolDiamondLoupeFacet).runtimeCode), "loupe");
        _verifyFacetCode(art.access, keccak256(type(DefaultAdminAccessControlFacet).runtimeCode), "access");
        _verifyFacetCode(art.pause, keccak256(type(PausableFacet).runtimeCode), "pause");
        _verifyFacetCode(art.token, keccak256(type(TokenFacet).runtimeCode), "token");
        _verifyFacetCode(art.issuance, keccak256(type(IssuanceFacet).runtimeCode), "issuance");
        _verifyFacetCode(art.redemption, keccak256(type(RedemptionFacet).runtimeCode), "redemption");
        _verifyFacetCode(art.rebalance, keccak256(type(RebalanceFacet).runtimeCode), "rebalance");
        _verifyFacetCode(art.preview, keccak256(type(PreviewFacet).runtimeCode), "preview");
        _verifyFacetCode(art.basketAdmin, keccak256(type(BasketAdminFacet).runtimeCode), "basketAdmin");
        _verifyFacetCode(art.config, keccak256(type(ControllerConfigFacet).runtimeCode), "config");
        _verifyFacetCode(art.lens, keccak256(type(CoreLensFacet).runtimeCode), "lens");
        _verifyFacetCode(art.reserveLifecycle, keccak256(type(ReserveLifecycleFacet).runtimeCode), "reserveLifecycle");
        _verifyFacetCode(art.recoveryShare, keccak256(type(RecoveryShareFacet).runtimeCode), "recoveryShare");
        _verifyFacetCode(
            art.recoveryShareMetadata, keccak256(type(RecoveryShareMetadataFacet).runtimeCode), "recoveryShareMetadata"
        );
        _verifyFacetCode(art.recoveryAdmin, keccak256(type(RecoveryAdminFacet).runtimeCode), "recoveryAdmin");
        _verifyFacetCode(
            art.recoveryPoolSettlement,
            keccak256(type(RecoveryPoolSettlementFacet).runtimeCode),
            "recoveryPoolSettlement"
        );
        _verifyFacetCode(art.init, keccak256(type(InitFacet).runtimeCode), "init");
        require(
            art.diamondInit.codehash == keccak256(type(DiamondInit).runtimeCode),
            "VerifyCoreOnly: init runtime mismatch"
        );
        _verifyFacetCode(
            art.authorityInvariant, keccak256(type(CoreAuthorityInvariant).runtimeCode), "authorityInvariant"
        );

        DeploymentTypes.DeployArtifacts memory deployed;
        deployed.facets.cut = DiamondCutAccessFacet(art.cut);
        deployed.facets.loupe = DiamondLoupeFacet(art.loupe);
        deployed.facets.access = DefaultAdminAccessControlFacet(art.access);
        deployed.facets.pause = PausableFacet(art.pause);
        deployed.facets.token = TokenFacet(art.token);
        deployed.facets.issuance = IssuanceFacet(art.issuance);
        deployed.facets.redemption = RedemptionFacet(art.redemption);
        deployed.facets.rebalance = RebalanceFacet(art.rebalance);
        deployed.facets.preview = PreviewFacet(art.preview);
        deployed.facets.basketAdmin = BasketAdminFacet(art.basketAdmin);
        deployed.facets.config = ControllerConfigFacet(art.config);
        deployed.facets.lens = CoreLensFacet(art.lens);
        deployed.facets.reserveLifecycle = ReserveLifecycleFacet(art.reserveLifecycle);
        deployed.facets.recoveryShare = RecoveryShareFacet(art.recoveryShare);
        deployed.facets.recoveryShareMetadata = RecoveryShareMetadataFacet(art.recoveryShareMetadata);
        deployed.facets.recoveryAdmin = RecoveryAdminFacet(art.recoveryAdmin);
        deployed.facets.recoveryPoolSettlement = RecoveryPoolSettlementFacet(art.recoveryPoolSettlement);

        FacetSpec.Entry[] memory specs = DeploymentHelper.facetSpecs(deployed);
        IDiamondLoupe loupe = IDiamondLoupe(coreDiamond);
        require(loupe.facetAddresses().length == specs.length, "VerifyCoreOnly: unexpected facet count");
        for (uint256 i; i < specs.length; ++i) {
            bytes4[] memory actualSelectors = loupe.facetFunctionSelectors(specs[i].facet);
            require(actualSelectors.length == specs[i].selectors.length, "VerifyCoreOnly: selector count mismatch");
            for (uint256 j; j < specs[i].selectors.length; ++j) {
                require(
                    loupe.facetAddress(specs[i].selectors[j]) == specs[i].facet,
                    "VerifyCoreOnly: selector mapping mismatch"
                );
            }
        }
    }

    function _loadFacetArtifacts() internal view returns (CoreFacetArtifacts memory art) {
        // Deployment verification intentionally reads the prior deployment artifact.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(DeployParamsHelper.outPath(vm, "deploy-core.json"));
        art.cut = vm.parseJsonAddress(json, ".[\"facet.cut\"]");
        art.loupe = vm.parseJsonAddress(json, ".[\"facet.loupe\"]");
        art.access = vm.parseJsonAddress(json, ".[\"facet.access\"]");
        art.pause = vm.parseJsonAddress(json, ".[\"facet.pause\"]");
        art.token = vm.parseJsonAddress(json, ".[\"facet.token\"]");
        art.issuance = vm.parseJsonAddress(json, ".[\"facet.issuance\"]");
        art.redemption = vm.parseJsonAddress(json, ".[\"facet.redemption\"]");
        art.rebalance = vm.parseJsonAddress(json, ".[\"facet.rebalance\"]");
        art.preview = vm.parseJsonAddress(json, ".[\"facet.preview\"]");
        art.basketAdmin = vm.parseJsonAddress(json, ".[\"facet.basketAdmin\"]");
        art.config = vm.parseJsonAddress(json, ".[\"facet.controllerConfig\"]");
        art.lens = vm.parseJsonAddress(json, ".[\"facet.lens\"]");
        art.reserveLifecycle = vm.parseJsonAddress(json, ".[\"facet.reserveLifecycle\"]");
        art.recoveryShare = vm.parseJsonAddress(json, ".[\"facet.recoveryShare\"]");
        art.recoveryShareMetadata = vm.parseJsonAddress(json, ".[\"facet.recoveryShareMetadata\"]");
        art.recoveryAdmin = vm.parseJsonAddress(json, ".[\"facet.recoveryAdmin\"]");
        art.recoveryPoolSettlement = vm.parseJsonAddress(json, ".[\"facet.recoveryPoolSettlement\"]");
        art.init = vm.parseJsonAddress(json, ".initFacet");
        art.diamondInit = vm.parseJsonAddress(json, ".diamondInit");
        art.authorityInvariant = vm.parseJsonAddress(json, ".authorityInvariant");
    }

    function _verifyFacetCode(address facet, bytes32 expectedCodehash, string memory label) internal view {
        require(facet.codehash == expectedCodehash, string.concat("VerifyCoreOnly: ", label, " facet runtime mismatch"));
    }

    function _verifyOptionalSafe(CoreArtifacts.Core memory core) internal view {
        address safe = JsonUtils.loadAddressFromFile(vm, DeployParamsHelper.outPath(vm, "deploy-safe.json"), ".safe");
        if (safe != address(0)) {
            require(core.safeWallet == safe, "VerifyCoreOnly: Core Safe does not match deployed Safe");
        }
    }

    function _verifyControllerConfig(DeployConfig.ProtocolConfig memory cfg, CoreArtifacts.Core memory core)
        internal
        view
    {
        CoreLensFacet lens = CoreLensFacet(core.coreDiamond);
        require(lens.treasury() == core.coreTreasury, "VerifyCoreOnly: treasury mismatch");

        IERC20Metadata metadata = IERC20Metadata(core.coreDiamond);
        require(
            keccak256(bytes(metadata.name())) == keccak256(bytes(cfg.basket.name)),
            "VerifyCoreOnly: token name mismatch"
        );
        require(
            keccak256(bytes(metadata.symbol())) == keccak256(bytes(cfg.basket.symbol)),
            "VerifyCoreOnly: token symbol mismatch"
        );
        require(lens.issuanceFeePpm() == cfg.basket.issuanceFeePpm, "VerifyCoreOnly: issuance fee mismatch");
        require(lens.redemptionFeePpm() == cfg.basket.redemptionFeePpm, "VerifyCoreOnly: redemption fee mismatch");
        require(lens.maxTotalSupply() == cfg.basket.maxTotalSupply, "VerifyCoreOnly: max supply mismatch");
        require(lens.cygldRefGramsFp18() == cfg.basket.cygldRefGramsFp18, "VerifyCoreOnly: CYGLD reference mismatch");
        _verifyLaunchMetadata(core.coreDiamond);
    }

    function _verifyBasket(DeployConfig.ProtocolConfig memory cfg, address coreDiamond) internal view {
        CoreLensFacet lens = CoreLensFacet(coreDiamond);
        address[] memory assets = lens.basketAssets();
        uint256[] memory targetsPpm = lens.basketTargetsPpm();
        uint256[] memory goldRefs = lens.basketGoldRefGramsFp18();
        uint256[] memory conversions = lens.basketCygldPerUnitFp18();

        require(assets.length == cfg.basket.assets.addresses.length, "VerifyCoreOnly: basket asset length mismatch");
        require(
            targetsPpm.length == cfg.basket.assets.targetsPpm.length, "VerifyCoreOnly: basket target length mismatch"
        );
        require(
            goldRefs.length == cfg.basket.assets.goldRefGramsFp18.length,
            "VerifyCoreOnly: basket gold reference length mismatch"
        );

        uint256 totalPpm;
        uint256 positiveTargetCount;
        for (uint256 i; i < assets.length; ++i) {
            require(assets[i] == cfg.basket.assets.addresses[i], "VerifyCoreOnly: basket asset mismatch");
            require(targetsPpm[i] == cfg.basket.assets.targetsPpm[i], "VerifyCoreOnly: basket target mismatch");
            require(
                goldRefs[i] == cfg.basket.assets.goldRefGramsFp18[i], "VerifyCoreOnly: basket gold reference mismatch"
            );
            totalPpm += targetsPpm[i];
            if (targetsPpm[i] != 0) ++positiveTargetCount;
            uint8 decimals = IERC20Metadata(assets[i]).decimals();
            require(
                conversions[i] == _computeCygldPerUnit(goldRefs[i], cfg.basket.cygldRefGramsFp18, decimals),
                "VerifyCoreOnly: basket conversion mismatch"
            );
            uint256 liveRaw = IERC20(assets[i]).balanceOf(coreDiamond);
            IRecoveryTypes.ReserveCustodyStatus memory custody = lens.reserveCustodyStatus(assets[i]);
            require(
                custody.lifecycle == IRecoveryTypes.ReserveLifecycle.Active, "VerifyCoreOnly: launch reserve not active"
            );
            require(custody.exitEntitlementRaw == 0, "VerifyCoreOnly: nonzero launch exit entitlement");
            require(!custody.poolImpaired, "VerifyCoreOnly: impaired launch reserve");
            require(custody.redeemablePoolRaw == 0, "VerifyCoreOnly: nonzero launch recovery pool");
            require(custody.coreAttachedShares == 0, "VerifyCoreOnly: nonzero launch attached shares");
            require(custody.externalShares == 0, "VerifyCoreOnly: nonzero launch external shares");
            require(custody.liveBalanceAvailable, "VerifyCoreOnly: launch reserve balance unavailable");
            require(custody.liveRawCustody == liveRaw, "VerifyCoreOnly: launch live custody mismatch");
            require(custody.activeAvailableRaw == liveRaw, "VerifyCoreOnly: launch available custody mismatch");
            require(custody.poolRawDeficit == 0, "VerifyCoreOnly: launch pool deficit");
            require(custody.exitEntitlementDeficitRaw == 0, "VerifyCoreOnly: launch exit deficit");
        }
        require(totalPpm == 1_000_000, "VerifyCoreOnly: basket target sum mismatch");
        require(positiveTargetCount >= 2, "VerifyCoreOnly: fewer than two positive-target reserves");
    }

    function _computeCygldPerUnit(uint256 goldRef, uint256 cygldRef, uint8 decimals) internal pure returns (uint256) {
        uint256 perToken = Math.mulDiv(goldRef, 1e18, cygldRef, Math.Rounding.Floor);
        if (decimals == 18) return perToken;
        if (decimals < 18) return perToken * (10 ** (18 - decimals));
        return perToken / (10 ** (decimals - 18));
    }

    function _verifyRoles(CoreArtifacts.Core memory core) internal view {
        DefaultAdminAccessControlFacet coreAccess = DefaultAdminAccessControlFacet(core.coreDiamond);
        PausableFacet pause = PausableFacet(core.coreDiamond);

        require(coreAccess.defaultAdmin() == core.safeWallet, "VerifyCoreOnly: default admin is not Safe");
        require(coreAccess.hasRole(bytes32(0), core.safeWallet), "VerifyCoreOnly: Core Safe admin mismatch");
        require(
            coreAccess.hasRole(coreAccess.upgraderRole(), core.safeWallet),
            "VerifyCoreOnly: Core Safe upgrader mismatch"
        );
        if (core.admin != core.safeWallet) {
            require(
                !coreAccess.hasRole(bytes32(0), core.admin), "VerifyCoreOnly: constructor admin retained admin role"
            );
            require(
                !coreAccess.hasRole(coreAccess.upgraderRole(), core.admin),
                "VerifyCoreOnly: constructor admin retained upgrader role"
            );
        }
        require(coreAccess.defaultAdminDelay() == 0, "VerifyCoreOnly: default-admin delay is not zero");
        (address pendingAdmin, uint48 pendingAdminSchedule) = coreAccess.pendingDefaultAdmin();
        require(
            pendingAdmin == address(0) && pendingAdminSchedule == 0, "VerifyCoreOnly: pending default-admin transfer"
        );
        (uint48 pendingDelay, uint48 pendingDelaySchedule) = coreAccess.pendingDefaultAdminDelay();
        require(pendingDelay == 0 && pendingDelaySchedule == 0, "VerifyCoreOnly: pending default-admin delay");
        require(
            coreAccess.getRoleAdmin(coreAccess.upgraderRole()) == bytes32(0),
            "VerifyCoreOnly: upgrader role admin mismatch"
        );
        require(pause.safeWallet() == core.safeWallet, "VerifyCoreOnly: Safe wallet mismatch");
        require(pause.canUnpause(core.safeWallet), "VerifyCoreOnly: Safe cannot unpause");
        require(!pause.canPause(core.safeWallet), "VerifyCoreOnly: Safe can pause");
        address[] memory owners = ISafeWallet(core.safeWallet).getOwners();
        require(owners.length != 0, "VerifyCoreOnly: Safe owners missing");
        for (uint256 i; i < owners.length; ++i) {
            require(pause.canPause(owners[i]), "VerifyCoreOnly: Safe owner cannot pause");
            require(!pause.canUnpause(owners[i]), "VerifyCoreOnly: Safe owner can unpause");
        }
        _requireExactSingletonRole(coreAccess, bytes32(0), core.safeWallet, "default admin");
        _requireExactSingletonRole(coreAccess, coreAccess.upgraderRole(), core.safeWallet, "upgrader");
        require(
            coreAccess.getRoleMemberCount(RedemptionFacet(core.coreDiamond).REDEMPTION_FEE_EXEMPT_ROLE()) == 0,
            "VerifyCoreOnly: unexpected fee exemption"
        );
    }

    function _requireExactSingletonRole(
        DefaultAdminAccessControlFacet access,
        bytes32 role,
        address expected,
        string memory label
    ) internal view {
        require(access.getRoleMemberCount(role) == 1, string.concat("VerifyCoreOnly: unexpected ", label, " count"));
        require(access.getRoleMember(role, 0) == expected, string.concat("VerifyCoreOnly: unexpected ", label));
    }

    function _verifyExactNetIssuance(address coreDiamond) internal view {
        uint256 requestedNetCygldOut = 1 ether;
        uint256 issuanceFeePpm = CoreLensFacet(coreDiamond).issuanceFeePpm();
        require(issuanceFeePpm > 0, "VerifyCoreOnly: issuance fee must exercise gross-up");

        (uint256 protocolFeeCygld, uint256[] memory amountsIn, address[] memory orderedBasketAssets) =
            PreviewFacet(coreDiamond).previewIssueFromBasketExactOut(requestedNetCygldOut);
        uint256 reconstructedGrossCygldOut = requestedNetCygldOut + protocolFeeCygld;
        uint256 expectedGrossCygldOut =
            Math.mulDiv(requestedNetCygldOut - 1, 1_000_000, 1_000_000 - issuanceFeePpm, Math.Rounding.Floor) + 1;

        require(protocolFeeCygld > 0, "VerifyCoreOnly: exact-net preview fee is zero");
        require(reconstructedGrossCygldOut > requestedNetCygldOut, "VerifyCoreOnly: gross-up not observed");
        require(reconstructedGrossCygldOut == expectedGrossCygldOut, "VerifyCoreOnly: noncanonical exact-net gross");
        require(amountsIn.length == orderedBasketAssets.length, "VerifyCoreOnly: preview amount/list length mismatch");
        address[] memory liveBasketAssets = CoreLensFacet(coreDiamond).basketAssets();
        require(
            orderedBasketAssets.length == liveBasketAssets.length, "VerifyCoreOnly: preview/live basket length mismatch"
        );
        for (uint256 i; i < liveBasketAssets.length; ++i) {
            require(orderedBasketAssets[i] == liveBasketAssets[i], "VerifyCoreOnly: preview/live basket mismatch");
        }
    }

    function _verifyInitializerState(CoreArtifacts.Core memory core) internal view {
        require(IERC20(core.coreDiamond).totalSupply() == 0, "VerifyCoreOnly: nonzero initial supply");
        require(PausableFacet(core.coreDiamond).paused(), "VerifyCoreOnly: core not paused at launch");
        require(
            uint256(vm.load(core.coreDiamond, RETIRED_REENTRANCY_GUARD_STORAGE_SLOT)) == 0,
            "VerifyCoreOnly: retired guard slot is nonzero"
        );
        bytes32 ownerSlot = bytes32(uint256(DIAMOND_STORAGE_POSITION) + 3);
        require(
            address(uint160(uint256(vm.load(core.coreDiamond, ownerSlot)))) == address(0),
            "VerifyCoreOnly: latent owner"
        );
        _verifyInterfaces(core.coreDiamond);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.upgrade.coordinator.access"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.access-control.default-admin-rules"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("openzeppelin.storage.Pausable"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("openzeppelin.storage.ReentrancyGuard"), 0);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.core.token"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.controller.init"), 0);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.controller.issuance"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.controller.redemption"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.controller.rebalance"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.controller.preview"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.controller.basket.admin"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.controller.config"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.core.lens"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.core.reserve-lifecycle"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.core.recovery-share"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.core.recovery-share-metadata"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.core.recovery-admin"), 1);
        _verifyFacetVersion(core.coreDiamond, keccak256("cybergold.core.recovery-pool-settlement"), 1);
        _verifyRecoverySeed(core.coreDiamond);
    }

    function _verifyRecoverySeed(address diamond) internal view {
        CoreLensFacet lens = CoreLensFacet(diamond);
        require(lens.coreAttachedRecoveryAssets().length == 0, "VerifyCoreOnly: Core-attached recovery set not empty");
        require(
            lens.effectiveCygldSupplyCap() == lens.maxTotalSupply(),
            "VerifyCoreOnly: empty recovery set does not preserve global cap"
        );
        require(
            uint256(vm.load(diamond, RECOVERY_STORAGE_SLOT)) == 0,
            "VerifyCoreOnly: stored Core-attached recovery set not empty"
        );
    }

    function _verifyInterfaces(address diamond) internal view {
        IERC165 interfaces = IERC165(diamond);
        require(interfaces.supportsInterface(type(IERC165).interfaceId), "VerifyCoreOnly: IERC165 missing");
        require(interfaces.supportsInterface(type(IDiamondCut).interfaceId), "VerifyCoreOnly: IDiamondCut missing");
        require(interfaces.supportsInterface(type(IDiamondLoupe).interfaceId), "VerifyCoreOnly: IDiamondLoupe missing");
        require(
            interfaces.supportsInterface(type(IAccessControl).interfaceId), "VerifyCoreOnly: IAccessControl missing"
        );
        require(
            interfaces.supportsInterface(type(IAccessControlEnumerable).interfaceId),
            "VerifyCoreOnly: IAccessControlEnumerable missing"
        );
        require(
            interfaces.supportsInterface(type(IAccessControlDefaultAdminRules).interfaceId),
            "VerifyCoreOnly: IAccessControlDefaultAdminRules missing"
        );
        require(!interfaces.supportsInterface(type(IERC5313).interfaceId), "VerifyCoreOnly: IERC5313 advertised");
        require(
            IDiamondLoupe(diamond).facetAddress(IERC5313.owner.selector) == address(0),
            "VerifyCoreOnly: owner selector installed"
        );
        require(interfaces.supportsInterface(type(IERC20).interfaceId), "VerifyCoreOnly: IERC20 missing");
        require(
            interfaces.supportsInterface(type(IERC20Metadata).interfaceId), "VerifyCoreOnly: IERC20Metadata missing"
        );
        require(interfaces.supportsInterface(type(IERC20Permit).interfaceId), "VerifyCoreOnly: IERC20Permit missing");
        require(interfaces.supportsInterface(type(IERC1155).interfaceId), "VerifyCoreOnly: IERC1155 missing");
        require(
            interfaces.supportsInterface(type(IERC1155MetadataURI).interfaceId),
            "VerifyCoreOnly: IERC1155MetadataURI missing"
        );
        require(
            !interfaces.supportsInterface(type(ICyberGoldCore).interfaceId),
            "VerifyCoreOnly: aggregate Core interface advertised"
        );
        require(
            interfaces.supportsInterface(type(ICoreRedemption).interfaceId),
            "VerifyCoreOnly: redemption interface missing"
        );
    }

    function _verifyLaunchMetadata(address diamond) internal view {
        string memory expected = string.concat(
            "https://cybergold.io/recovery-shares/",
            Strings.toString(block.chainid),
            "/",
            Strings.toHexString(diamond),
            "/collection.json"
        );
        require(
            keccak256(bytes(IRecoveryShareMetadata(diamond).contractURI())) == keccak256(bytes(expected)),
            "VerifyCoreOnly: collection metadata mismatch"
        );

        _requireMetadataRevert(diamond, 0, IRecoveryTypes.RecoveryShareIdInvalid.selector);
        _requireMetadataRevert(diamond, 1, IRecoveryTypes.RecoveryShareUnknown.selector);
    }

    function _requireMetadataRevert(address diamond, uint256 shareId, bytes4 expectedSelector) internal view {
        (bool ok, bytes memory revertData) =
            diamond.staticcall(abi.encodeWithSelector(IRecoveryShareMetadata.uri.selector, shareId));
        require(!ok && revertData.length >= 4, "VerifyCoreOnly: metadata unexpectedly succeeded");
        bytes4 actualSelector;
        assembly {
            actualSelector := mload(add(revertData, 0x20))
        }
        require(actualSelector == expectedSelector, "VerifyCoreOnly: metadata error mismatch");
    }

    function _verifyFacetVersion(address diamond, bytes32 namespace, uint64 expected) internal view {
        bytes32 slot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
        require(uint64(uint256(vm.load(diamond, slot))) == expected, "VerifyCoreOnly: facet version mismatch");
    }

    function _writeOutput(CoreArtifacts.Core memory core) internal {
        CoreLensFacet lens = CoreLensFacet(core.coreDiamond);
        string memory label = "verifyCoreOnly";
        string memory out = vm.serializeUint(label, "chainId", block.chainid);
        out = vm.serializeAddress(label, "admin", core.admin);
        out = vm.serializeAddress(label, "safeWallet", core.safeWallet);
        out = vm.serializeAddress(label, "coreDiamond", core.coreDiamond);
        out = vm.serializeAddress(label, "coreTreasury", core.coreTreasury);
        out = vm.serializeAddress(label, "governanceDiamond", core.governanceDiamond);
        out = vm.serializeUint(label, "issuanceFeePpm", lens.issuanceFeePpm());
        out = vm.serializeUint(label, "redemptionFeePpm", lens.redemptionFeePpm());
        out = vm.serializeUint(label, "maxTotalSupply", lens.maxTotalSupply());
        out = vm.serializeUint(label, "cygldRefGramsFp18", lens.cygldRefGramsFp18());
        out = vm.serializeBytes32(label, "basketConfigHash", lens.basketConfigHash());
        out = vm.serializeUint(label, "coreAttachedRecoveryAssetCount", lens.coreAttachedRecoveryAssets().length);
        out = vm.serializeUint(label, "effectiveCygldSupplyCap", lens.effectiveCygldSupplyCap());
        out = vm.serializeBool(label, "ok", true);
        vm.writeJson(out, DeployParamsHelper.outPath(vm, "verify-core-only.json"));
    }

    function _logSummary(CoreArtifacts.Core memory core) internal view {
        CoreLensFacet lens = CoreLensFacet(core.coreDiamond);
        console2.log("=== Core-only verification ===");
        console2.log("Admin", core.admin);
        console2.log("Safe wallet", core.safeWallet);
        console2.log("Core diamond", core.coreDiamond);
        console2.log("Core treasury", core.coreTreasury);
        console2.log("Governance diamond", core.governanceDiamond);
        console2.log("Issuance fee ppm", lens.issuanceFeePpm());
        console2.log("Redemption fee ppm", lens.redemptionFeePpm());
        console2.log("Max total supply", lens.maxTotalSupply());
        console2.log("Effective CYGLD supply cap", lens.effectiveCygldSupplyCap());
    }
}
