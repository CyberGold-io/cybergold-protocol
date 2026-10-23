// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DeployParams} from "../src/deploy/DeployParams.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {ICoreTypes} from "../src/interfaces/ICoreTypes.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";

contract CoreEnvExistsMock {
    mapping(bytes32 keyHash => bool exists) internal configured;

    function setExists(string calldata key, bool exists) external {
        configured[keccak256(bytes(key))] = exists;
    }

    function envExists(string calldata key) external view returns (bool) {
        return configured[keccak256(bytes(key))];
    }
}

contract CoreDeployParamsTest is Test {
    function testExecutionContextFailsClosedOutsideLocalDevelopment() public {
        CoreEnvExistsMock env = new CoreEnvExistsMock();
        DeployParams.Params memory params = DeployParams.fromProtocolConfig(_defaults());
        params.coreTreasury = address(0xBEEF);

        vm.chainId(10);
        vm.expectRevert(bytes("unsupported deployment chain"));
        this.validateExecutionContext(address(env), params);

        vm.chainId(31337);
        params.admin = address(0);
        vm.expectRevert(bytes("DEPLOY_ADMIN must be nonzero"));
        this.validateExecutionContext(address(env), params);
        params.admin = address(0xA11CE);
        params.safeWallet = address(0);
        vm.expectRevert(bytes("DEPLOY_SAFE_WALLET must be nonzero"));
        this.validateExecutionContext(address(env), params);
        params.safeWallet = address(0x5AFE);
        params.coreTreasury = address(0);
        vm.expectRevert(bytes("CORE_TREASURY must be nonzero"));
        this.validateExecutionContext(address(env), params);
        params.coreTreasury = address(0xBEEF);
        vm.chainId(1);
        vm.expectRevert(bytes("mainnet DEPLOY_ADMIN must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("DEPLOY_ADMIN", true);
        vm.expectRevert(bytes("mainnet DEPLOY_SAFE_WALLET must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("DEPLOY_SAFE_WALLET", true);
        params.safeWallet = address(0x5AFE);
        vm.expectRevert(bytes("mainnet CORE_TREASURY must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("CORE_TREASURY", true);
        vm.expectRevert(bytes("mainnet CORE_NAME must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("CORE_NAME", true);
        vm.expectRevert(bytes("mainnet CORE_SYMBOL must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("CORE_SYMBOL", true);
        vm.expectRevert(bytes("mainnet CORE_MAX_TOTAL_SUPPLY must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("CORE_MAX_TOTAL_SUPPLY", true);
        vm.expectRevert(bytes("mainnet CORE_ISSUANCE_FEE_PPM must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("CORE_ISSUANCE_FEE_PPM", true);
        vm.expectRevert(bytes("mainnet CORE_REDEMPTION_FEE_PPM must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("CORE_REDEMPTION_FEE_PPM", true);
        vm.expectRevert(bytes("mainnet CORE_BASKET_JSON must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("CORE_BASKET_JSON", true);
        vm.expectRevert(bytes("mainnet CORE_BASKET_JSON must be nonempty"));
        this.validateExecutionContext(address(env), params);
        params.basketConfigPath = "/sealed/core-basket.json";
        vm.expectRevert(bytes("mainnet CORE_DEPLOYMENT_CONFIG_HASH must be explicit"));
        this.validateExecutionContext(address(env), params);
        env.setExists("CORE_DEPLOYMENT_CONFIG_HASH", true);
        vm.expectRevert(bytes("CORE_DEPLOYMENT_CONFIG_HASH does not match resolved config"));
        this.validateExecutionContext(address(env), params);
        params.sealedConfigHash = this.deploymentConfigHash(params);

        params.admin = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        vm.expectRevert(bytes("development admin forbidden on mainnet"));
        this.validateExecutionContext(address(env), params);
        params.admin = address(0xA11CE);
        params.coreTreasury = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        vm.expectRevert(bytes("development treasury forbidden on mainnet"));
        this.validateExecutionContext(address(env), params);
        params.coreTreasury = address(0xBEEF);
        this.validateExecutionContext(address(env), params);

        params.issuanceFeePpm += 1;
        vm.expectRevert(bytes("CORE_DEPLOYMENT_CONFIG_HASH does not match resolved config"));
        this.validateExecutionContext(address(env), params);
    }

    function testFromEnvToConfigAndWriteJson() public {
        string memory basketPath = DeployParamsHelper.outPath(vm, "test-basket-config.json");
        // File and environment cheatcodes are required to exercise deployment configuration I/O.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(
            basketPath,
            '{"assets":["0x0000000000000000000000000000000000000101","0x0000000000000000000000000000000000000102"],'
            '"targetsPpm":[600000,400000],' '"goldRefGramsFp18":[1000000000000000000,2000000000000000000],'
            '"cygldRefGramsFp18":1500000000000000000}'
        );
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_ADMIN", "0x00000000000000000000000000000000000000a1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_SAFE_WALLET", "0x000000000000000000000000000000000000005a");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_TREASURY", "0x00000000000000000000000000000000000000b1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_NAME", "Env CyberGold");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_SYMBOL", "eCYGLD");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_MAX_TOTAL_SUPPLY", "123000000000000000000");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_ISSUANCE_FEE_PPM", "111");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_REDEMPTION_FEE_PPM", "222");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_BASKET_JSON", basketPath);

        DeployParams.Params memory params = DeployParams.fromEnv(vm);
        DeploymentTypes.DeployConfig memory cfg = DeployParams.toConfig(params);

        assertTrue(cfg.admin != address(0));
        assertEq(cfg.safeWallet, address(0x5A));
        assertEq(cfg.coreTreasury, address(0xB1));
        assertEq(cfg.name, "Env CyberGold");
        assertEq(cfg.symbol, "eCYGLD");
        assertEq(cfg.basketAssets.length, 2);
        assertEq(cfg.basketAssets[0], address(0x101));
        assertEq(cfg.basketTargetsPpm[1], 400_000);
        assertEq(cfg.basketGoldRefGramsFp18[1], 2 ether);
        assertEq(cfg.cygldRefGramsFp18, 1.5 ether);
        assertEq(cfg.maxTotalSupply, 123 ether);
        assertEq(cfg.issuanceFeePpm, 111);
        assertEq(cfg.redemptionFeePpm, 222);

        DeploymentTypes.DeployArtifacts memory art;
        string memory outPath = DeployParamsHelper.outPath(vm, "test-deploy-core.json");
        DeployParams.writeJson(vm, cfg, art, outPath);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory written = vm.readFile(outPath);
        assertEq(vm.parseJsonAddress(written, ".admin"), cfg.admin);
        assertEq(vm.parseJsonAddress(written, ".coreTreasury"), cfg.coreTreasury);
        assertFalse(vm.keyExistsJson(written, ".recoveryShareBaseUri"));
        assertFalse(vm.keyExistsJson(written, ".reentrancyFacet"));
        assertEq(vm.parseJsonUint(written, ".maxTotalSupply"), 123 ether);
    }

    function testFromProtocolConfigAndToConfigValidation() public {
        DeployParams.Params memory params = DeployParams.fromProtocolConfig(_defaults());
        DeploymentTypes.DeployConfig memory cfg = DeployParams.toConfig(params);

        assertEq(cfg.admin, address(0xA11CE));
        assertEq(cfg.coreTreasury, address(0));
        assertEq(cfg.name, "Default CyberGold");
        assertEq(cfg.symbol, "dCYGLD");
        assertEq(cfg.basketAssets.length, 2);
        assertEq(cfg.basketAssets[1], address(0xB));
        assertEq(cfg.basketTargetsPpm[0], 600_000);
        assertEq(cfg.basketGoldRefGramsFp18[1], 50 ether);
        assertEq(cfg.cygldRefGramsFp18, 1 ether);
        assertEq(cfg.maxTotalSupply, 250 ether);
        assertEq(cfg.issuanceFeePpm, 1_000);
        assertEq(cfg.redemptionFeePpm, 2_000);

        DeployParams.Params memory invalid;
        vm.expectRevert(bytes("basket empty"));
        this.toConfig(invalid);

        invalid.assets = new address[](1);
        invalid.targetsPpm = new uint256[](0);
        invalid.goldRefGramsFp18 = new uint256[](1);
        vm.expectRevert(bytes("basket length mismatch"));
        this.toConfig(invalid);

        invalid.targetsPpm = new uint256[](1);
        invalid.goldRefGramsFp18 = new uint256[](0);
        vm.expectRevert(bytes("basket length mismatch"));
        this.toConfig(invalid);

        invalid.goldRefGramsFp18 = new uint256[](1);
        invalid.targetsPpm[0] = 1_000_000;
        vm.expectRevert(bytes("basket requires at least two positive targets"));
        this.toConfig(invalid);

        invalid.assets = new address[](65);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreTypes.CombinedAssetLimitExceeded.selector, uint256(65), uint256(0), uint256(64))
        );
        this.toConfig(invalid);
    }

    function toConfig(DeployParams.Params memory params) external pure returns (DeploymentTypes.DeployConfig memory) {
        return DeployParams.toConfig(params);
    }

    function validateExecutionContext(address env, DeployParams.Params memory params) external view {
        DeployParams.validateExecutionContext(Vm(env), params);
    }

    function deploymentConfigHash(DeployParams.Params memory params) external view returns (bytes32) {
        return DeployParams.deploymentConfigHash(params);
    }

    function _defaults() private pure returns (DeployConfig.ProtocolConfig memory cfg) {
        cfg.admin = address(0xA11CE);
        cfg.safeWallet = address(0x5AFE);
        cfg.basket.name = "Default CyberGold";
        cfg.basket.symbol = "dCYGLD";
        cfg.basket.assets.addresses = new address[](2);
        cfg.basket.assets.addresses[0] = address(0xA);
        cfg.basket.assets.addresses[1] = address(0xB);
        cfg.basket.assets.targetsPpm = new uint256[](2);
        cfg.basket.assets.targetsPpm[0] = 600_000;
        cfg.basket.assets.targetsPpm[1] = 400_000;
        cfg.basket.assets.goldRefGramsFp18 = new uint256[](2);
        cfg.basket.assets.goldRefGramsFp18[0] = 100 ether;
        cfg.basket.assets.goldRefGramsFp18[1] = 50 ether;
        cfg.basket.cygldRefGramsFp18 = 1 ether;
        cfg.basket.maxTotalSupply = 250 ether;
        cfg.basket.issuanceFeePpm = 1_000;
        cfg.basket.redemptionFeePpm = 2_000;
    }
}
