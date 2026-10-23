// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeploymentHelper} from "packages/1_core/src/deploy/DeploymentHelper.sol";
import {CoreDiamond} from "packages/1_core/src/diamond/CoreDiamond.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";

contract DeployCoreDiamondShell is Script {
    function run() external returns (CoreDiamond diamond, address bootstrapDiamondCutFacet) {
        bytes32 salt = vm.envBytes32("CORE_DIAMOND_SALT");
        address bootstrapOwner = vm.envAddress("CORE_DIAMOND_BOOTSTRAP_OWNER");
        address create2Deployer = vm.envAddress("CORE_CREATE2_DEPLOYER");
        address expected = vm.envOr("CORE_DIAMOND_EXPECTED_ADDRESS", address(0));
        require(bootstrapOwner != address(0), "DeployCoreDiamondShell: bootstrap owner missing");

        (diamond, bootstrapDiamondCutFacet) =
            DeploymentHelper.deployCoreShellFrom(bootstrapOwner, salt, create2Deployer);

        if (expected != address(0)) {
            require(address(diamond) == expected, "DeployCoreDiamondShell: expected address mismatch");
        }

        _writeOutput(salt, bootstrapOwner, address(diamond), bootstrapDiamondCutFacet);
        console2.log("=== Core diamond shell deployment ===");
        console2.log("Core diamond shell", address(diamond));
        console2.log("Bootstrap DiamondCutFacet", bootstrapDiamondCutFacet);
        console2.log("Bootstrap owner", bootstrapOwner);
        console2.logBytes32(salt);
    }

    function _writeOutput(bytes32 salt, address bootstrapOwner, address diamond, address bootstrapDiamondCutFacet)
        private
    {
        string memory label = "deploy";
        string memory out = vm.serializeUint(label, "chainId", block.chainid);
        out = vm.serializeAddress(label, "coreDiamond", diamond);
        out = vm.serializeAddress(label, "bootstrapDiamondCutFacet", bootstrapDiamondCutFacet);
        out = vm.serializeAddress(label, "bootstrapOwner", bootstrapOwner);
        out = vm.serializeBytes32(label, "salt", salt);
        vm.writeJson(out, DeployParamsHelper.outPath(vm, "deploy-core-shell.json"));
    }
}
