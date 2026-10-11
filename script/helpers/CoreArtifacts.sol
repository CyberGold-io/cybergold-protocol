// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";

import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {JsonUtils} from "script/helpers/JsonUtils.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";

library CoreArtifacts {
    struct Core {
        address admin;
        address safeWallet;
        address allocator;
        address coreDiamond;
        address coreTreasury;
        address governanceDiamond;
    }

    function load(Vm vm_) internal view returns (Core memory core) {
        DeployConfig.ProtocolConfig memory cfg = DeployConfig.loadProtocol(vm_);
        cfg = DeployConfig.applyProtocolEnvOverrides(vm_, cfg);

        string memory protocolPath = DeployParamsHelper.outPath(vm_, "deploy-protocol.json");
        string memory corePath = DeployParamsHelper.outPath(vm_, "deploy-core.json");
        string memory safePath = DeployParamsHelper.outPath(vm_, "deploy-safe.json");
        string memory governancePath = DeployParamsHelper.outPath(vm_, "deploy-governance.json");

        core.admin = _firstNonZero(
            vm_.envOr("CORE_ADMIN", address(0)),
            vm_.envOr("DEPLOY_ADMIN", address(0)),
            JsonUtils.loadAddressFromFile(vm_, protocolPath, ".admin"),
            JsonUtils.loadAddressFromFile(vm_, corePath, ".admin"),
            cfg.admin
        );
        core.safeWallet = _firstNonZero(
            vm_.envOr("DEPLOY_SAFE_WALLET", address(0)),
            JsonUtils.loadAddressFromFile(vm_, safePath, ".safe"),
            JsonUtils.loadAddressFromFile(vm_, corePath, ".safeWallet"),
            cfg.safeWallet,
            address(0)
        );
        core.allocator = _firstNonZero(
            vm_.envOr("DEPLOY_ALLOCATOR", address(0)),
            JsonUtils.loadAddressFromFile(vm_, protocolPath, ".allocator"),
            cfg.allocator,
            core.admin,
            address(0)
        );
        core.coreDiamond = _firstNonZero(
            vm_.envOr("CORE_DIAMOND_ADDRESS", address(0)),
            JsonUtils.loadAddressFromFile(vm_, protocolPath, ".coreDiamond"),
            JsonUtils.loadAddressFromFile(vm_, corePath, ".coreDiamond"),
            address(0),
            address(0)
        );
        core.coreTreasury = _firstNonZero(
            vm_.envOr("CORE_TREASURY", address(0)),
            JsonUtils.loadAddressFromFile(vm_, protocolPath, ".coreTreasury"),
            JsonUtils.loadAddressFromFile(vm_, corePath, ".coreTreasury"),
            address(0),
            address(0)
        );
        core.governanceDiamond = _firstNonZero(
            vm_.envOr("GOVERNANCE_DIAMOND", address(0)),
            JsonUtils.loadAddressFromFile(vm_, protocolPath, ".governanceDiamond"),
            JsonUtils.loadAddressFromFile(vm_, governancePath, ".governanceDiamond"),
            address(0),
            address(0)
        );
    }

    function requireCustody(Core memory core) internal pure {
        require(core.coreDiamond != address(0), "CoreArtifacts: core diamond missing");
        require(core.coreTreasury != address(0), "CoreArtifacts: core treasury missing");
    }

    function requireCore(Core memory core) internal pure {
        require(core.admin != address(0), "CoreArtifacts: admin missing");
        require(core.safeWallet != address(0), "CoreArtifacts: Safe wallet missing");
        require(core.coreDiamond != address(0), "CoreArtifacts: core diamond missing");
        require(core.coreTreasury != address(0), "CoreArtifacts: core treasury missing");
    }

    function _firstNonZero(address a, address b, address c, address d, address e) private pure returns (address) {
        if (a != address(0)) return a;
        if (b != address(0)) return b;
        if (c != address(0)) return c;
        if (d != address(0)) return d;
        return e;
    }
}
