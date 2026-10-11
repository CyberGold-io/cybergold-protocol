// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {ICyberGoldCore} from "../src/interfaces/ICyberGoldCore.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";

contract ReleaseAbiConformanceTest is Test {
    function testGeneratedReleaseAbiMatchesDeployedCutAndIsNotAdvertisedAsOneGiantInterface() public {
        MockERC20 paxg = new MockERC20("PAX Gold", "PAXG", 18);
        MockERC20 xaut = new MockERC20("Tether Gold", "XAUT", 18);

        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = address(this);
        cfg.safeWallet = MockSafeWalletFactory.deploy(address(this));
        cfg.coreTreasury = address(0xBEEF);
        cfg.name = "CyberGold";
        cfg.symbol = "CYGLD";
        cfg.basketAssets = _addresses(address(paxg), address(xaut));
        cfg.basketTargetsPpm = _uints(600_000, 400_000);
        cfg.basketGoldRefGramsFp18 = _uints(31.1034768 ether, 31.1034768 ether);
        cfg.cygldRefGramsFp18 = 1 ether;
        cfg.maxTotalSupply = 250 ether;
        cfg.issuanceFeePpm = 1_000;
        cfg.redemptionFeePpm = 1_000;

        DeploymentTypes.DeployArtifacts memory deployed = DeploymentHelper.deploy(cfg);
        string memory abiPath = string.concat(vm.projectRoot(), "/generated/abi/CoreDiamond.json");
        if (!vm.exists(abiPath)) {
            abiPath = string.concat(vm.projectRoot(), "/../../generated/abi/CoreDiamond.json");
        }
        // Reading the generated release ABI is the purpose of this conformance test.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(abiPath);
        uint256[] memory selectorInts = abi.decode(vm.parseJson(json, ".selectorInts"), (uint256[]));
        bytes4[] memory expected = new bytes4[](selectorInts.length);
        for (uint256 i; i < selectorInts.length; ++i) {
            expected[i] = bytes4(uint32(selectorInts[i]));
        }
        bytes4 interfaceId = bytes4(uint32(vm.parseJsonUint(json, ".interfaceIdInt")));
        bool erc165Advertised = vm.parseJsonBool(json, ".interface.erc165Advertised");
        IDiamondLoupe loupe = IDiamondLoupe(address(deployed.diamond));

        uint256 installedCount;
        IDiamondLoupe.Facet[] memory facets = loupe.facets();
        for (uint256 i; i < facets.length; ++i) {
            installedCount += facets[i].functionSelectors.length;
        }
        assertEq(installedCount, expected.length, "release ABI/cut selector count");
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(loupe.facetAddress(expected[i]) != address(0), "release selector missing from cut");
            for (uint256 j = i + 1; j < expected.length; ++j) {
                assertTrue(expected[i] != expected[j], "duplicate release selector");
            }
        }
        assertFalse(erc165Advertised, "aggregate release interface metadata");
        assertFalse(
            IERC165(address(deployed.diamond)).supportsInterface(interfaceId), "aggregate release interface advertised"
        );
        assertEq(interfaceId, type(ICyberGoldCore).interfaceId, "generated Solidity interface id");
    }

    function _addresses(address a, address b) private pure returns (address[] memory values) {
        values = new address[](2);
        values[0] = a;
        values[1] = b;
    }

    function _uints(uint256 a, uint256 b) private pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = a;
        values[1] = b;
    }
}
