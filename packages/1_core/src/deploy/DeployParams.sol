// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {LibCoreAssetCardinality} from "../libraries/LibCoreAssetCardinality.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {DeploymentHelper} from "./DeploymentHelper.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";

/// @notice Centralized parameter builder for core/basket deployments.
library DeployParams {
    address internal constant ANVIL_DEFAULT_ACCOUNT = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    /// @notice Environment-derived deployment parameters.
    struct Params {
        address admin;
        address safeWallet;
        address coreTreasury;
        string name;
        string symbol;
        address[] assets;
        uint256[] targetsPpm;
        uint256[] goldRefGramsFp18;
        uint256 cygldRefGramsFp18;
        uint256 maxTotalSupply;
        uint256 issuanceFeePpm;
        uint256 redemptionFeePpm;
        string basketConfigPath;
        bytes32 sealedConfigHash;
    }

    /// @notice Load params from environment variables used by the package script.
    /// Canonical overrides: DEPLOY_ADMIN, DEPLOY_SAFE_WALLET, CORE_TREASURY, CORE_NAME, CORE_SYMBOL,
    /// CORE_MAX_TOTAL_SUPPLY, CORE_ISSUANCE_FEE_PPM, CORE_REDEMPTION_FEE_PPM,
    /// CORE_BASKET_JSON, and CORE_DEPLOYMENT_CONFIG_HASH.
    /// @param vm_ Foundry VM cheatcode handle used to read environment variables and config files.
    /// @return p Deployment parameters assembled from defaults and environment overrides.
    function fromEnv(Vm vm_) internal view returns (Params memory p) {
        DeployConfig.ProtocolConfig memory defaults = DeployConfig.loadProtocol(vm_);
        p = fromProtocolConfig(defaults);
        p.admin = DeployParamsHelper.envAddressOr(vm_, DeployParamsHelper.keys1("DEPLOY_ADMIN"), p.admin);
        p.safeWallet =
            DeployParamsHelper.envAddressOr(vm_, DeployParamsHelper.keys1("DEPLOY_SAFE_WALLET"), p.safeWallet);
        p.coreTreasury = DeployParamsHelper.envAddressOr(vm_, DeployParamsHelper.keys1("CORE_TREASURY"), p.coreTreasury);
        p.name = DeployParamsHelper.envStringOr(vm_, DeployParamsHelper.keys1("CORE_NAME"), p.name);
        p.symbol = DeployParamsHelper.envStringOr(vm_, DeployParamsHelper.keys1("CORE_SYMBOL"), p.symbol);
        p.maxTotalSupply =
            DeployParamsHelper.envUintOr(vm_, DeployParamsHelper.keys1("CORE_MAX_TOTAL_SUPPLY"), p.maxTotalSupply);
        p.issuanceFeePpm =
            DeployParamsHelper.envUintOr(vm_, DeployParamsHelper.keys1("CORE_ISSUANCE_FEE_PPM"), p.issuanceFeePpm);
        p.redemptionFeePpm =
            DeployParamsHelper.envUintOr(vm_, DeployParamsHelper.keys1("CORE_REDEMPTION_FEE_PPM"), p.redemptionFeePpm);

        string memory basketPath = DeployParamsHelper.envStringOr(vm_, DeployParamsHelper.keys1("CORE_BASKET_JSON"), "");
        p.basketConfigPath = basketPath;
        p.sealedConfigHash = vm_.envOr("CORE_DEPLOYMENT_CONFIG_HASH", bytes32(0));
        if (bytes(basketPath).length != 0) {
            // forge-lint: disable-next-line(unsafe-cheatcode)
            string memory json = vm_.readFile(basketPath);
            p.assets = abi.decode(vm_.parseJson(json, ".assets"), (address[]));
            p.targetsPpm = abi.decode(vm_.parseJson(json, ".targetsPpm"), (uint256[]));
            p.goldRefGramsFp18 = abi.decode(vm_.parseJson(json, ".goldRefGramsFp18"), (uint256[]));
            p.cygldRefGramsFp18 = abi.decode(vm_.parseJson(json, ".cygldRefGramsFp18"), (uint256));
        }
        validateExecutionContext(vm_, p);
    }

    /// @dev Fail closed for any direct non-local broadcast surface.
    /// @param vm_ Forge VM used to attest explicit environment variables.
    /// @param p Candidate deployment parameters to validate.
    function validateExecutionContext(Vm vm_, Params memory p) internal view {
        require(block.chainid == 1 || block.chainid == 31337, "unsupported deployment chain");
        require(p.admin != address(0), "DEPLOY_ADMIN must be nonzero");
        require(p.safeWallet != address(0), "DEPLOY_SAFE_WALLET must be nonzero");
        require(p.coreTreasury != address(0), "CORE_TREASURY must be nonzero");
        if (block.chainid != 1) return;

        require(vm_.envExists("DEPLOY_ADMIN"), "mainnet DEPLOY_ADMIN must be explicit");
        require(vm_.envExists("DEPLOY_SAFE_WALLET"), "mainnet DEPLOY_SAFE_WALLET must be explicit");
        require(vm_.envExists("CORE_TREASURY"), "mainnet CORE_TREASURY must be explicit");
        require(vm_.envExists("CORE_NAME"), "mainnet CORE_NAME must be explicit");
        require(vm_.envExists("CORE_SYMBOL"), "mainnet CORE_SYMBOL must be explicit");
        require(vm_.envExists("CORE_MAX_TOTAL_SUPPLY"), "mainnet CORE_MAX_TOTAL_SUPPLY must be explicit");
        require(vm_.envExists("CORE_ISSUANCE_FEE_PPM"), "mainnet CORE_ISSUANCE_FEE_PPM must be explicit");
        require(vm_.envExists("CORE_REDEMPTION_FEE_PPM"), "mainnet CORE_REDEMPTION_FEE_PPM must be explicit");
        require(vm_.envExists("CORE_BASKET_JSON"), "mainnet CORE_BASKET_JSON must be explicit");
        require(bytes(p.basketConfigPath).length != 0, "mainnet CORE_BASKET_JSON must be nonempty");
        require(vm_.envExists("CORE_DEPLOYMENT_CONFIG_HASH"), "mainnet CORE_DEPLOYMENT_CONFIG_HASH must be explicit");
        require(p.admin != ANVIL_DEFAULT_ACCOUNT, "development admin forbidden on mainnet");
        require(p.coreTreasury != ANVIL_DEFAULT_ACCOUNT, "development treasury forbidden on mainnet");
        require(
            p.sealedConfigHash == deploymentConfigHash(p), "CORE_DEPLOYMENT_CONFIG_HASH does not match resolved config"
        );
    }

    /// @notice Hash every resolved mainnet parameter and authority relationship.
    function deploymentConfigHash(Params memory p) internal view returns (bytes32) {
        bytes32 authoritiesHash = keccak256(abi.encode(p.admin, p.safeWallet, p.coreTreasury));
        bytes32 identityHash = keccak256(abi.encode(p.name, p.symbol));
        bytes32 basketHash = keccak256(abi.encode(p.assets, p.targetsPpm, p.goldRefGramsFp18, p.cygldRefGramsFp18));
        bytes32 economicsHash = keccak256(abi.encode(p.maxTotalSupply, p.issuanceFeePpm, p.redemptionFeePpm));
        return keccak256(
            abi.encode(
                "CYBERGOLD_CORE_DEPLOYMENT_CONFIG_V2",
                block.chainid,
                authoritiesHash,
                identityHash,
                basketHash,
                economicsHash,
                keccak256(bytes(p.basketConfigPath))
            )
        );
    }

    /// @dev Convert an already loaded aggregate Protocol configuration into Core deployment parameters.
    /// @param defaults Resolved aggregate Protocol configuration; this function performs no environment reads.
    /// @return p Core deployment parameters copied from `defaults`, with the treasury left unbound for stack wiring.
    function fromProtocolConfig(DeployConfig.ProtocolConfig memory defaults) internal pure returns (Params memory p) {
        p.admin = defaults.admin;
        p.safeWallet = defaults.safeWallet;
        p.coreTreasury = address(0);
        p.name = defaults.basket.name;
        p.symbol = defaults.basket.symbol;
        p.assets = defaults.basket.assets.addresses;
        p.targetsPpm = defaults.basket.assets.targetsPpm;
        p.goldRefGramsFp18 = defaults.basket.assets.goldRefGramsFp18;
        p.cygldRefGramsFp18 = defaults.basket.cygldRefGramsFp18;
        p.maxTotalSupply = defaults.basket.maxTotalSupply;
        p.issuanceFeePpm = defaults.basket.issuanceFeePpm;
        p.redemptionFeePpm = defaults.basket.redemptionFeePpm;
    }

    /// @dev Validate basket cardinality/shape and convert deployment parameters to the Core initializer config.
    /// @param p Core deployment parameters to validate and convert.
    /// @return cfg Validated Core initializer configuration.
    function toConfig(Params memory p) internal pure returns (DeploymentTypes.DeployConfig memory cfg) {
        LibCoreAssetCardinality.enforce(p.assets.length, 0);
        require(p.assets.length != 0, "basket empty");
        require(p.assets.length == p.targetsPpm.length, "basket length mismatch");
        require(p.assets.length == p.goldRefGramsFp18.length, "basket length mismatch");
        uint256 positiveTargetCount;
        for (uint256 i; i < p.targetsPpm.length; ++i) {
            if (p.targetsPpm[i] != 0) ++positiveTargetCount;
        }
        require(positiveTargetCount >= 2, "basket requires at least two positive targets");
        cfg.admin = p.admin;
        cfg.safeWallet = p.safeWallet;
        cfg.coreTreasury = p.coreTreasury;
        cfg.name = p.name;
        cfg.symbol = p.symbol;
        cfg.basketAssets = p.assets;
        cfg.basketTargetsPpm = p.targetsPpm;
        cfg.basketGoldRefGramsFp18 = p.goldRefGramsFp18;
        cfg.cygldRefGramsFp18 = p.cygldRefGramsFp18;
        cfg.maxTotalSupply = p.maxTotalSupply;
        cfg.issuanceFeePpm = p.issuanceFeePpm;
        cfg.redemptionFeePpm = p.redemptionFeePpm;
    }

    /// @notice Persist deployment outputs to disk for reproducibility.
    /// @param vm_ Foundry VM cheatcode handle used to serialize and write JSON.
    /// @param cfg Core deployment configuration being serialized.
    /// @param art Deployed diamond and facet artifact addresses.
    /// @param path Output path for the deployment JSON file.
    function writeJson(
        Vm vm_,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        string memory path
    ) internal {
        string memory label = "deploy";
        string memory out = DeployParamsHelper.baseJson(vm_, label, cfg.admin, address(art.diamondInit));
        out = vm_.serializeBytes32(label, "diamondInitCodeHash", address(art.diamondInit).codehash);
        out = vm_.serializeAddress(label, "authorityInvariant", address(art.authorityInvariant));
        out = vm_.serializeBytes32(label, "authorityInvariantCodeHash", address(art.authorityInvariant).codehash);
        out = vm_.serializeAddress(label, "safeWallet", cfg.safeWallet);
        out = vm_.serializeAddress(label, "coreDiamond", address(art.diamond));
        out = vm_.serializeAddress(label, "coreTreasury", cfg.coreTreasury);
        out = vm_.serializeAddress(label, "basketAssets", cfg.basketAssets);
        out = vm_.serializeUint(label, "basketTargetsPpm", cfg.basketTargetsPpm);
        out = vm_.serializeUint(label, "basketGoldRefGramsFp18", cfg.basketGoldRefGramsFp18);
        out = vm_.serializeUint(label, "cygldRefGramsFp18", cfg.cygldRefGramsFp18);
        out = vm_.serializeUint(label, "maxTotalSupply", cfg.maxTotalSupply);
        out = vm_.serializeUint(label, "issuanceFeePpm", cfg.issuanceFeePpm);
        out = vm_.serializeUint(label, "redemptionFeePpm", cfg.redemptionFeePpm);
        out = vm_.serializeAddress(label, "initFacet", address(art.facets.init));
        out = DeployParamsHelper.writeFacetsFromSpecs(vm_, label, DeploymentHelper.facetSpecs(art));
        vm_.writeJson(out, path);
    }
}
