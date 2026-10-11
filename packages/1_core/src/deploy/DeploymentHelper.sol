// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {DiamondArgs} from "diamond-1/Diamond.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {DiamondCutFacet as BootstrapDiamondCutFacet} from "diamond-1/facets/DiamondCutFacet.sol";

import {CoreDiamond} from "../diamond/CoreDiamond.sol";
import {DiamondInit} from "../deploy/DiamondInit.sol";
import {CoreAuthorityInvariant} from "../deploy/CoreAuthorityInvariant.sol";
import {BaseDiamondHelper} from "diamond-infra/deploy/BaseDiamondHelper.sol";
import {FacetSelectors as SharedFacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";
import {FacetCutBuilder} from "diamond-infra/deploy/FacetCutBuilder.sol";
import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";
import {TokenFacet} from "../facets/TokenFacet.sol";
import {InitFacet} from "../facets/InitFacet.sol";
import {IssuanceFacet} from "../facets/IssuanceFacet.sol";
import {RedemptionFacet} from "../facets/RedemptionFacet.sol";
import {RebalanceFacet} from "../facets/RebalanceFacet.sol";
import {PreviewFacet} from "../facets/PreviewFacet.sol";
import {BasketAdminFacet} from "../facets/BasketAdminFacet.sol";
import {ControllerConfigFacet} from "../facets/ControllerConfigFacet.sol";
import {LensFacet} from "../facets/LensFacet.sol";
import {ReserveLifecycleFacet} from "../facets/ReserveLifecycleFacet.sol";
import {RecoveryShareFacet} from "../facets/RecoveryShareFacet.sol";
import {RecoveryShareMetadataFacet} from "../facets/RecoveryShareMetadataFacet.sol";
import {RecoveryAdminFacet} from "../facets/RecoveryAdminFacet.sol";
import {RecoveryPoolSettlementFacet} from "../facets/RecoveryPoolSettlementFacet.sol";
import {FacetSelectors} from "./FacetSelectors.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";

/// @notice Shared deployment harness for the core diamond to avoid drift between scripts and tests.
library DeploymentHelper {
    /// @dev Deploy operation state.
    /// @param cfg Initializer or deployment config consumed by this function.
    /// @return out Deployed Core facets, initializer, and diamond.
    function deploy(DeploymentTypes.DeployConfig memory cfg)
        internal
        returns (DeploymentTypes.DeployArtifacts memory out)
    {
        require(cfg.admin != address(0), "DeploymentHelper: admin missing");
        out = _deployFacets(out);
        (IDiamond.FacetCut[] memory cut, DiamondArgs memory args) = _buildFullCutAndArgs(cfg, out);

        // Deploying the Diamond contract with facets and initializer.
        out.diamond = new CoreDiamond(cut, args);
    }

    /// @dev Deploy core shell.
    /// @param bootstrapOwner Temporary owner used to bootstrap a new diamond deployment.
    /// @param salt CREATE2 salt used to derive the deterministic shell address.
    /// @return diamond Diamond proxy address deployed by the helper.
    /// @return bootstrapDiamondCutFacet Bootstrap DiamondCut facet address used during deployment.
    function deployCoreShell(address bootstrapOwner, bytes32 salt)
        internal
        returns (CoreDiamond diamond, address bootstrapDiamondCutFacet)
    {
        return _deployCoreShell(bootstrapOwner, salt, address(this));
    }

    /// @dev Deploy an ordinary CREATE shell whose bootstrap owner can finalize it later.
    ///      Full-stack deployment uses this boundary so Governance can bind the Core
    ///      address before Core is finalized with Governance as its treasury.
    function deployCoreShell(address bootstrapOwner)
        internal
        returns (CoreDiamond diamond, address bootstrapDiamondCutFacet)
    {
        require(bootstrapOwner != address(0), "DeploymentHelper: bootstrap owner missing");

        BootstrapDiamondCutFacet cutFacet = new BootstrapDiamondCutFacet();
        bootstrapDiamondCutFacet = address(cutFacet);

        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: bootstrapDiamondCutFacet,
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: SharedFacetSelectors.cutSelectors()
        });

        DiamondArgs memory args = BaseDiamondHelper.buildArgs(bootstrapOwner, address(0), "");
        diamond = new CoreDiamond(cut, args);
    }

    /// @dev Foundry broadcasts salted creation through its configured CREATE2 deployer.
    function deployCoreShellFrom(address bootstrapOwner, bytes32 salt, address create2Deployer)
        internal
        returns (CoreDiamond diamond, address bootstrapDiamondCutFacet)
    {
        require(create2Deployer != address(0), "DeploymentHelper: CREATE2 deployer missing");
        return _deployCoreShell(bootstrapOwner, salt, create2Deployer);
    }

    function _deployCoreShell(address bootstrapOwner, bytes32 salt, address create2Deployer)
        private
        returns (CoreDiamond diamond, address bootstrapDiamondCutFacet)
    {
        require(bootstrapOwner != address(0), "DeploymentHelper: bootstrap owner missing");

        bytes32 bootstrapSalt = keccak256(abi.encodePacked("cybergold.core.bootstrapCut", salt));
        bootstrapDiamondCutFacet =
            _create2Address(create2Deployer, bootstrapSalt, keccak256(type(BootstrapDiamondCutFacet).creationCode));
        if (bootstrapDiamondCutFacet.code.length == 0) {
            BootstrapDiamondCutFacet cutFacet = new BootstrapDiamondCutFacet{salt: bootstrapSalt}();
            require(address(cutFacet) == bootstrapDiamondCutFacet, "DeploymentHelper: bootstrap address mismatch");
        } else {
            require(
                bootstrapDiamondCutFacet.codehash == keccak256(type(BootstrapDiamondCutFacet).runtimeCode),
                "DeploymentHelper: bootstrap runtime mismatch"
            );
        }
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: bootstrapDiamondCutFacet,
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: SharedFacetSelectors.cutSelectors()
        });

        DiamondArgs memory args = BaseDiamondHelper.buildArgs(bootstrapOwner, address(0), "");
        bytes memory diamondInitCode = bytes.concat(type(CoreDiamond).creationCode, abi.encode(cut, args));
        address diamondAddress = _create2Address(create2Deployer, salt, keccak256(diamondInitCode));
        if (diamondAddress.code.length == 0) {
            diamond = new CoreDiamond{salt: salt}(cut, args);
            require(address(diamond) == diamondAddress, "DeploymentHelper: diamond address mismatch");
        } else {
            require(
                diamondAddress.codehash == keccak256(type(CoreDiamond).runtimeCode),
                "DeploymentHelper: diamond runtime mismatch"
            );
            diamond = CoreDiamond(payable(diamondAddress));
        }
    }

    function _create2Address(address deployer, bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @dev Finalize existing.
    /// @param diamond Diamond proxy address being deployed, initialized, or serialized.
    /// @param cfg Initializer or deployment config consumed by this function.
    /// @return out Newly deployed Core facets bound to the supplied diamond.
    function finalizeExisting(CoreDiamond diamond, DeploymentTypes.DeployConfig memory cfg)
        internal
        returns (DeploymentTypes.DeployArtifacts memory out)
    {
        require(address(diamond) != address(0), "DeploymentHelper: diamond missing");
        require(cfg.admin != address(0), "DeploymentHelper: admin missing");

        out = _deployFacets(out);
        out.diamond = diamond;

        (IDiamond.FacetCut[] memory cut, DiamondArgs memory args) = _buildFullCutAndArgs(cfg, out);
        // The deterministic shell starts with the owner-gated diamond-1 cut facet.
        // Replace it with the normal AccessControl-gated cut facet during full initialization.
        cut[0].action = IDiamond.FacetCutAction.Replace;

        IDiamondCut(address(diamond)).diamondCut(cut, args.init, args.initCalldata);
    }

    /// @dev Deploy facets.
    /// @param out Deployment output struct or encoded payload being populated.
    /// @return Deployment artifact addresses produced by the helper.
    function _deployFacets(DeploymentTypes.DeployArtifacts memory out)
        private
        returns (DeploymentTypes.DeployArtifacts memory)
    {
        // Deploy the contracts corresponding to the facets.
        FacetCutBuilder.DefaultAdminBaseFacets memory base = BaseDiamondHelper.deployDefaultAdminBaseFacets(true, false);
        out.facets.cut = base.cut;
        out.facets.loupe = base.loupe;
        out.facets.access = base.access;
        out.facets.pause = base.pause;
        out.facets.token = new TokenFacet();
        out.facets.init = new InitFacet();
        out.facets.issuance = new IssuanceFacet();
        out.facets.redemption = new RedemptionFacet();
        out.facets.rebalance = new RebalanceFacet();
        out.facets.preview = new PreviewFacet();
        out.facets.basketAdmin = new BasketAdminFacet();
        out.facets.config = new ControllerConfigFacet();
        out.facets.lens = new LensFacet();
        out.facets.reserveLifecycle = new ReserveLifecycleFacet();
        out.facets.recoveryShare = new RecoveryShareFacet();
        out.facets.recoveryShareMetadata = new RecoveryShareMetadataFacet();
        out.facets.recoveryAdmin = new RecoveryAdminFacet();
        out.facets.recoveryPoolSettlement = new RecoveryPoolSettlementFacet();

        out.authorityInvariant = new CoreAuthorityInvariant();
        out.diamondInit = new DiamondInit();
        return out;
    }

    /// @dev Build full cut and args.
    /// @param cfg Initializer or deployment config consumed by this function.
    /// @param out Deployment output struct or encoded payload being populated.
    /// @return cut Diamond cut entries assembled from facet specs.
    /// @return args ABI-encoded initializer arguments for the diamond deployment.
    function _buildFullCutAndArgs(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory out)
        private
        view
        returns (IDiamond.FacetCut[] memory cut, DiamondArgs memory args)
    {
        cut = FacetSpec.buildCut(facetSpecs(out));

        DiamondInit.InitConfig memory initCfg = DiamondInit.InitConfig({
            admin: cfg.admin,
            safeWallet: cfg.safeWallet,
            authorityInvariant: address(out.authorityInvariant),
            authorityInvariantCodeHash: address(out.authorityInvariant).codehash,
            accessControlFacet: address(out.facets.access),
            pausableFacet: address(out.facets.pause),
            tokenFacet: address(out.facets.token),
            initFacet: address(out.facets.init),
            issuanceFacet: address(out.facets.issuance),
            redemptionFacet: address(out.facets.redemption),
            rebalanceFacet: address(out.facets.rebalance),
            previewFacet: address(out.facets.preview),
            basketAdminFacet: address(out.facets.basketAdmin),
            configFacet: address(out.facets.config),
            lensFacet: address(out.facets.lens),
            reserveLifecycleFacet: address(out.facets.reserveLifecycle),
            recoveryShareFacet: address(out.facets.recoveryShare),
            recoveryShareMetadataFacet: address(out.facets.recoveryShareMetadata),
            recoveryAdminFacet: address(out.facets.recoveryAdmin),
            recoveryPoolSettlementFacet: address(out.facets.recoveryPoolSettlement),
            coreTreasury: cfg.coreTreasury,
            basketAssets: cfg.basketAssets,
            basketTargetsPpm: cfg.basketTargetsPpm,
            basketGoldRefGramsFp18: cfg.basketGoldRefGramsFp18,
            cygldRefGramsFp18: cfg.cygldRefGramsFp18,
            maxTotalSupply: cfg.maxTotalSupply,
            issuanceFeePpm: cfg.issuanceFeePpm,
            redemptionFeePpm: cfg.redemptionFeePpm
        });

        args = BaseDiamondHelper.buildArgs(
            cfg.admin,
            address(out.diamondInit),
            abi.encodeWithSelector(DiamondInit.init.selector, initCfg, cfg.name, cfg.symbol)
        );
    }

    /// @notice Build the exact facet and selector specification for a deployed Core diamond.
    /// @param out Deployment artifacts containing all facet addresses.
    /// @return specs Complete expected facet specification in deterministic order.
    function facetSpecs(DeploymentTypes.DeployArtifacts memory out)
        internal
        pure
        returns (FacetSpec.Entry[] memory specs)
    {
        FacetSpec.Entry[] memory baseSpecs = FacetSpec.defaultAdminBase(
            address(out.facets.cut),
            address(out.facets.loupe),
            address(out.facets.access),
            address(out.facets.pause),
            true
        );
        FacetSpec.Entry[] memory productSpecs = _productFacetSpecs(out.facets);
        specs = FacetSpec.concat(baseSpecs, productSpecs);
    }

    function _productFacetSpecs(DeploymentTypes.Facets memory facets) private pure returns (FacetSpec.Entry[] memory) {
        address[] memory addresses_ = new address[](13);
        addresses_[0] = address(facets.token);
        addresses_[1] = address(facets.issuance);
        addresses_[2] = address(facets.redemption);
        addresses_[3] = address(facets.rebalance);
        addresses_[4] = address(facets.preview);
        addresses_[5] = address(facets.basketAdmin);
        addresses_[6] = address(facets.config);
        addresses_[7] = address(facets.lens);
        addresses_[8] = address(facets.reserveLifecycle);
        addresses_[9] = address(facets.recoveryShare);
        addresses_[10] = address(facets.recoveryShareMetadata);
        addresses_[11] = address(facets.recoveryAdmin);
        addresses_[12] = address(facets.recoveryPoolSettlement);
        return FacetSelectors.specs(addresses_);
    }
}
