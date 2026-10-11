// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {SleeveDeployerHelper} from "../src/deploy/SleeveDeployerHelper.sol";
import {ICyberGoldStaking} from "../src/interfaces/ICyberGoldStaking.sol";
import {LensFacet} from "../src/facets/LensFacet.sol";
import {MockCyberGold} from "staking-mocks/MockCyberGold.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";

contract ReleaseAbiConformanceTest is Test {
    function testGeneratedReleaseAbiMatchesDeployedCutAndRegisteredInterface() public {
        MockCyberGold cygld = new MockCyberGold();
        DeploymentTypes.DeployConfig memory cfg;
        cfg.safeWallet = MockSafeWalletFactory.deploy(address(0x5AFE));
        cfg.name = "Staked CyberGold";
        cfg.symbol = "sCYGLD";
        cfg.coreDiamond = address(cygld);
        cfg.governanceDiamond = address(this);
        cfg.withdrawers = new address[](0);
        cfg.allocators = new address[](1);
        cfg.allocators[0] = address(0xA110C8);
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveDeployerHelper.SleeveRequest({
            implementation: address(new MockSleeve()),
            asset: address(cygld),
            approve: true,
            initialOperational: true,
            initialPaused: false,
            principalCap: 1_000 ether,
            initType: SleeveDeployerHelper.InitType.Basic,
            initArgs: bytes("")
        });
        cfg.create2Deployer = address(this);
        cfg.shellSalt = keccak256("ReleaseAbiConformanceTest");
        cfg.claimExpiry = 30 days;
        cfg.headSweepLimit = 16;
        cfg.autoProcessMax = 16;
        cfg.performanceFeePpm = 100_000;

        DeploymentTypes.DeployArtifacts memory deployed = DeploymentHelper.prepare(cfg);
        deployed = DeploymentHelper.deployCommittedShellLocal(cfg, deployed);
        deployed = DeploymentHelper.finalizeCommitted(cfg, deployed);
        _assertReleaseConformance(address(deployed.diamond), "StakingDiamond.json");
    }

    function _assertReleaseConformance(address diamond, string memory fileName) private view {
        string memory abiPath = string.concat(vm.projectRoot(), "/generated/abi/", fileName);
        if (!vm.exists(abiPath)) abiPath = string.concat(vm.projectRoot(), "/../../generated/abi/", fileName);
        // Reading the generated release ABI is the purpose of this conformance test.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(abiPath);
        uint256[] memory selectorInts = abi.decode(vm.parseJson(json, ".selectorInts"), (uint256[]));
        bytes4 interfaceId = bytes4(uint32(vm.parseJsonUint(json, ".interfaceIdInt")));
        bool erc165Advertised = vm.parseJsonBool(json, ".interface.erc165Advertised");
        IDiamondLoupe loupe = IDiamondLoupe(diamond);

        uint256 installedCount;
        IDiamondLoupe.Facet[] memory facets = loupe.facets();
        for (uint256 i; i < facets.length; ++i) {
            installedCount += facets[i].functionSelectors.length;
        }
        assertEq(installedCount, selectorInts.length, "release ABI/cut selector count");
        for (uint256 i; i < selectorInts.length; ++i) {
            bytes4 selector = bytes4(uint32(selectorInts[i]));
            assertTrue(loupe.facetAddress(selector) != address(0), "release selector missing from cut");
            for (uint256 j = i + 1; j < selectorInts.length; ++j) {
                assertTrue(selector != bytes4(uint32(selectorInts[j])), "duplicate release selector");
            }
        }
        assertTrue(erc165Advertised, "Staking release metadata must advertise aggregate interface");
        assertEq(
            IERC165(diamond).supportsInterface(interfaceId), erc165Advertised, "release ERC-165 policy/runtime mismatch"
        );
        assertEq(interfaceId, type(ICyberGoldStaking).interfaceId, "generated Solidity interface id");
        assertTrue(
            IERC165(diamond).supportsInterface(type(IAccessControlDefaultAdminRules).interfaceId),
            "default-admin rules interface missing"
        );
        assertFalse(IERC165(diamond).supportsInterface(type(IERC5313).interfaceId), "IERC5313 advertised");
        assertEq(loupe.facetAddress(IERC5313.owner.selector), address(0), "owner selector installed");
        assertEq(loupe.facetAddress(bytes4(keccak256("enableTransfers()"))), address(0));
        assertEq(loupe.facetAddress(bytes4(keccak256("transfersEnabled()"))), address(0));
        assertTrue(loupe.facetAddress(LensFacet.stakingLaunchState.selector) != address(0));
    }
}
