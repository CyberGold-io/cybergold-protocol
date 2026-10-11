// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {ICyberGoldGovernance} from "../src/interfaces/ICyberGoldGovernance.sol";

contract ReleaseAbiConformanceTest is Test {
    function testGeneratedReleaseAbiMatchesDeployedCutAndIsNotAdvertisedAsOneGiantInterface() public {
        DeploymentTypes.DeployArtifacts memory deployed = DeploymentHelper.deploy(
            DeploymentTypes.DeployConfig({
                constructorOwner: address(this),
                safeWallet: MockSafeWalletFactory.deploy(address(this)),
                trustedCore: address(this),
                executionDelay: 1 days,
                executionGracePeriod: 14 days,
                name: "CyberGold Governance",
                tokenSymbol: "CYGOV",
                tokenInitialHolder: address(this),
                tokenInitialSupply: 100 ether,
                tokenTreasurySupply: 50 ether,
                votingDelay: 1 days,
                votingPeriod: 1 weeks,
                proposalThresholdNumerator: 100,
                quorumNumerator: 8
            })
        );
        _assertReleaseConformance(address(deployed.diamond), "GovernanceDiamond.json");
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
        assertFalse(erc165Advertised, "aggregate release interface metadata");
        assertFalse(IERC165(diamond).supportsInterface(interfaceId), "aggregate release interface advertised");
        assertEq(interfaceId, type(ICyberGoldGovernance).interfaceId, "generated Solidity interface id");
    }
}
