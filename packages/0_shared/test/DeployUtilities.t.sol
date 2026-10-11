// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC1155MetadataURI} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";

import {FunctionNotFound} from "../src/diamond/ProtocolDiamond.sol";
import {BaseDiamondHelper} from "../src/deploy/BaseDiamondHelper.sol";
import {DeployParamsHelper} from "../src/deploy/DeployParamsHelper.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {FacetCutBuilder} from "../src/deploy/FacetCutBuilder.sol";
import {FacetSpec} from "../src/deploy/FacetSpec.sol";
import {InfraInit} from "../src/deploy/InfraInit.sol";
import {AccessControlFacet} from "../src/facets/AccessControlFacet.sol";
import {DiamondCutAccessFacet} from "../src/facets/DiamondCutAccessFacet.sol";
import {FacetVersionRegistry} from "../src/helpers/FacetVersionRegistry.sol";
import {InterfaceRetirementInit} from "../src/helpers/InterfaceRetirementInit.sol";
import {InitContext} from "../src/helpers/InitContext.sol";
import {ValidatedDiamondCut} from "../src/helpers/ValidatedDiamondCut.sol";
import {LibInterfaceInvariant} from "../src/libraries/LibInterfaceInvariant.sol";
import {StandardInterfaceManifests} from "../src/libraries/StandardInterfaceManifests.sol";

contract InitContextHarness is InitContext {
    function guarded() external view onlyInit returns (bool) {
        return true;
    }

    function setInitContext(bool enabled) external {
        bytes32 slot = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
        assembly {
            sstore(slot, enabled)
        }
    }
}

contract BaseDiamondHelperHarness {
    function deployDefaultAdminBase(bool includePause, bool includeReentrancy)
        external
        returns (FacetCutBuilder.DefaultAdminBaseFacets memory facets, FacetSpec.Entry[] memory specs)
    {
        facets = BaseDiamondHelper.deployDefaultAdminBaseFacets(includePause, includeReentrancy);
        specs = BaseDiamondHelper.defaultAdminBaseSpecs(facets, includePause);
    }
}

contract DeployUtilitiesTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant USER = address(0xBEEF);

    function testInitContextGuardCoversClosedAndOpenStates() public {
        InitContextHarness harness = new InitContextHarness();
        vm.expectRevert(abi.encodeWithSelector(InitContext.FacetInitCallerNotSelf.selector, address(this)));
        harness.guarded();
        harness.setInitContext(true);
        assertTrue(harness.guarded());
    }

    function testDeployParamsHelperKeysAndEnvFallbacks() public {
        string[] memory oneKey = DeployParamsHelper.keys1("CG_SHARED_ONE");
        assertEq(oneKey.length, 1);
        assertEq(oneKey[0], "CG_SHARED_ONE");

        string[] memory twoKeys = DeployParamsHelper.keys2("CG_SHARED_MISSING_ADDR", "CG_SHARED_ADDR");
        assertEq(twoKeys.length, 2);
        assertEq(twoKeys[1], "CG_SHARED_ADDR");

        string[] memory threeKeys =
            DeployParamsHelper.keys3("CG_SHARED_MISSING_STRING_A", "CG_SHARED_MISSING_STRING_B", "CG_SHARED_STRING");
        assertEq(threeKeys.length, 3);
        assertEq(threeKeys[2], "CG_SHARED_STRING");

        // These environment mutations are the behavior under test.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CG_SHARED_ADDR", "0x0000000000000000000000000000000000001234");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CG_SHARED_UINT", "42");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CG_SHARED_STRING", "configured");
        // Presence-aware reads must preserve every value in the represented type.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CG_SHARED_MAX_ADDR", "0xFfFfFfFFffFFfffFFfFFfFffFFFffffFfFFFfFfF");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CG_SHARED_MAX_UINT", vm.toString(type(uint256).max));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CG_SHARED_SENTINEL_LITERAL", "__missing__");

        assertEq(DeployParamsHelper.envAddressRequired(vm, twoKeys), address(0x1234));
        assertEq(
            DeployParamsHelper.envAddressOr(
                vm, DeployParamsHelper.keys1("CG_SHARED_MISSING_ADDR_DEFAULT"), address(0xCAFE)
            ),
            address(0xCAFE)
        );
        assertEq(
            DeployParamsHelper.envAddressOr(
                vm, DeployParamsHelper.keys2("CG_SHARED_MISSING_ADDR_B", "CG_SHARED_ADDR"), address(0xCAFE)
            ),
            address(0x1234)
        );

        assertEq(
            DeployParamsHelper.envUintRequired(
                vm, DeployParamsHelper.keys2("CG_SHARED_MISSING_UINT", "CG_SHARED_UINT")
            ),
            42
        );
        assertEq(DeployParamsHelper.envUintOr(vm, DeployParamsHelper.keys1("CG_SHARED_MISSING_UINT_DEFAULT"), 7), 7);
        assertEq(
            DeployParamsHelper.envUintOr(vm, DeployParamsHelper.keys2("CG_SHARED_MISSING_UINT_B", "CG_SHARED_UINT"), 7),
            42
        );

        assertEq(DeployParamsHelper.envStringRequired(vm, threeKeys), "configured");
        assertEq(
            DeployParamsHelper.envStringOr(
                vm, DeployParamsHelper.keys1("CG_SHARED_MISSING_STRING_DEFAULT"), "fallback"
            ),
            "fallback"
        );
        assertEq(
            DeployParamsHelper.envStringOr(
                vm, DeployParamsHelper.keys2("CG_SHARED_MISSING_STRING_C", "CG_SHARED_STRING"), "fallback"
            ),
            "configured"
        );
        assertEq(
            DeployParamsHelper.envAddressRequired(vm, DeployParamsHelper.keys1("CG_SHARED_MAX_ADDR")),
            address(type(uint160).max)
        );
        assertEq(
            DeployParamsHelper.envAddressOr(vm, DeployParamsHelper.keys1("CG_SHARED_MAX_ADDR"), address(0xCAFE)),
            address(type(uint160).max)
        );
        assertEq(
            DeployParamsHelper.envUintRequired(vm, DeployParamsHelper.keys1("CG_SHARED_MAX_UINT")), type(uint256).max
        );
        assertEq(DeployParamsHelper.envUintOr(vm, DeployParamsHelper.keys1("CG_SHARED_MAX_UINT"), 7), type(uint256).max);
        assertEq(
            DeployParamsHelper.envStringRequired(vm, DeployParamsHelper.keys1("CG_SHARED_SENTINEL_LITERAL")),
            "__missing__"
        );
        assertEq(
            DeployParamsHelper.envStringOr(vm, DeployParamsHelper.keys1("CG_SHARED_SENTINEL_LITERAL"), "fallback"),
            "__missing__"
        );

        vm.expectRevert(bytes("missing env address"));
        this.envAddressRequired(DeployParamsHelper.keys1("CG_SHARED_MISSING_REQUIRED_ADDR"));

        vm.expectRevert(bytes("missing env uint"));
        this.envUintRequired(DeployParamsHelper.keys1("CG_SHARED_MISSING_REQUIRED_UINT"));

        vm.expectRevert(bytes("missing env string"));
        this.envStringRequired(DeployParamsHelper.keys1("CG_SHARED_MISSING_REQUIRED_STRING"));
    }

    function testDeployParamsHelperJsonAndOutputPaths() public {
        string memory label = "shared";
        string memory json = DeployParamsHelper.baseJson(vm, label, ADMIN, address(0xD17));
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid);
        assertEq(vm.parseJsonAddress(json, ".admin"), ADMIN);
        assertEq(vm.parseJsonAddress(json, ".diamondInit"), address(0xD17));

        string[] memory names = DeployParamsHelper.keys2("cut", "access");
        address[] memory facets = new address[](2);
        facets[0] = address(0xC07);
        facets[1] = address(0xACC);
        json = DeployParamsHelper.writeFacets(vm, label, names, facets);
        assertTrue(bytes(json).length != 0);

        address[] memory mismatchedFacets = new address[](1);
        vm.expectRevert(bytes("facet length mismatch"));
        this.writeFacets(label, names, mismatchedFacets);

        FacetSpec.Entry[] memory specs = new FacetSpec.Entry[](1);
        specs[0] = FacetSpec.Entry({name: "reentrancy", facet: address(0xE11), selectors: new bytes4[](0)});
        json = DeployParamsHelper.writeFacetsFromSpecs(vm, label, specs);
        assertTrue(bytes(json).length != 0);

        // These environment mutations verify deployment output-path resolution.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_OUTPUT_DIR", "/tmp/cybergold-shared-out");
        assertEq(DeployParamsHelper.outDir(vm), "/tmp/cybergold-shared-out");

        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_PROTOCOL_PATH", "/tmp/deploy-protocol.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_CORE_PATH", "/tmp/deploy-core.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_CORE_SHELL_PATH", "/tmp/deploy-core-shell.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("WIRE_CORE_ROLES_PATH", "/tmp/wire-core-roles.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("VERIFY_CORE_ONLY_PATH", "/tmp/verify-core-only.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_STAKING_PATH", "/tmp/deploy-staking.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_STAKING_SLEEVES_PATH", "/tmp/deploy-staking-sleeves.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_GOVERNANCE_PATH", "/tmp/deploy-governance.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_SAFE_PATH", "/tmp/deploy-safe.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_HELPERS_PATH", "/tmp/deploy-helpers.json");

        assertEq(DeployParamsHelper.outPath(vm, "deploy-protocol.json"), "/tmp/deploy-protocol.json");
        assertEq(DeployParamsHelper.outPath(vm, "deploy-core.json"), "/tmp/deploy-core.json");
        assertEq(DeployParamsHelper.outPath(vm, "deploy-core-shell.json"), "/tmp/deploy-core-shell.json");
        assertEq(DeployParamsHelper.outPath(vm, "wire-core-roles.json"), "/tmp/wire-core-roles.json");
        assertEq(DeployParamsHelper.outPath(vm, "verify-core-only.json"), "/tmp/verify-core-only.json");
        assertEq(DeployParamsHelper.outPath(vm, "deploy-staking.json"), "/tmp/deploy-staking.json");
        assertEq(DeployParamsHelper.outPath(vm, "deploy-staking-sleeves.json"), "/tmp/deploy-staking-sleeves.json");
        assertEq(DeployParamsHelper.outPath(vm, "deploy-governance.json"), "/tmp/deploy-governance.json");
        assertEq(DeployParamsHelper.outPath(vm, "deploy-safe.json"), "/tmp/deploy-safe.json");
        assertEq(DeployParamsHelper.outPath(vm, "deploy-helpers.json"), "/tmp/deploy-helpers.json");
        assertEq(DeployParamsHelper.outPath(vm, "other.json"), "/tmp/cybergold-shared-out/other.json");
    }

    function testFacetBuildersProduceExpectedCutsAndSpecs() public {
        assertEq(FacetCutBuilder.baseFacetCount(false), 3);
        assertEq(FacetCutBuilder.baseFacetCount(true), 4);

        FacetCutBuilder.BaseFacets memory facets = FacetCutBuilder.deployBaseFacets(true, true);
        assertTrue(address(facets.cut) != address(0));
        assertTrue(address(facets.loupe) != address(0));
        assertTrue(address(facets.access) != address(0));
        assertTrue(address(facets.pause) != address(0));
        assertTrue(address(facets.reentrancy) != address(0));

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](4);
        uint256 next = FacetCutBuilder.addBaseCuts(cuts, 0, facets, true);
        assertEq(next, 4);
        assertEq(cuts[0].facetAddress, address(facets.cut));
        assertEq(cuts[0].functionSelectors.length, 1);
        assertEq(cuts[3].facetAddress, address(facets.pause));

        FacetSpec.Entry[] memory specs = FacetSpec.base(
            address(facets.cut), address(facets.loupe), address(facets.access), address(facets.pause), true
        );
        assertEq(specs.length, 4);
        FacetSpec.Entry[] memory liveSpecs = FacetSpec.liveBase(
            address(facets.cut), address(facets.loupe), address(facets.access), address(facets.pause), false
        );
        assertEq(liveSpecs.length, 3);
        assertEq(liveSpecs[0].selectors.length, 2);

        FacetCutBuilder.DefaultAdminBaseFacets memory defaultAdminFacets =
            FacetCutBuilder.deployDefaultAdminBaseFacets(true, false);
        FacetSpec.Entry[] memory defaultAdminSpecs = FacetSpec.defaultAdminBase(
            address(defaultAdminFacets.cut),
            address(defaultAdminFacets.loupe),
            address(defaultAdminFacets.access),
            address(defaultAdminFacets.pause),
            true
        );
        assertEq(defaultAdminSpecs.length, 4);
        assertEq(defaultAdminSpecs[2].selectors.length, 20);
        FacetSpec.Entry[] memory liveDefaultAdminSpecs = FacetSpec.liveDefaultAdminBase(
            address(defaultAdminFacets.cut),
            address(defaultAdminFacets.loupe),
            address(defaultAdminFacets.access),
            address(defaultAdminFacets.pause),
            false
        );
        assertEq(liveDefaultAdminSpecs.length, 3);
        assertEq(liveDefaultAdminSpecs[0].selectors.length, 2);

        FacetSpec.Entry[] memory extra = new FacetSpec.Entry[](1);
        extra[0] = FacetSpec.Entry({name: "extra", facet: address(0xE7A), selectors: new bytes4[](1)});
        extra[0].selectors[0] = bytes4(0x12345678);

        FacetSpec.Entry[] memory combined = FacetSpec.concat(specs, extra);
        assertEq(combined.length, 5);
        assertEq(combined[4].facet, address(0xE7A));

        IDiamond.FacetCut[] memory built = FacetSpec.buildCut(combined);
        assertEq(built.length, 5);
        assertEq(built[4].facetAddress, address(0xE7A));
        assertEq(built[4].functionSelectors[0], bytes4(0x12345678));
    }

    function testBaseDiamondHelperBuildsDefaultAdminFacetBundleAndSpecs() public {
        BaseDiamondHelperHarness harness = new BaseDiamondHelperHarness();
        (FacetCutBuilder.DefaultAdminBaseFacets memory facets, FacetSpec.Entry[] memory specs) =
            harness.deployDefaultAdminBase(true, true);

        assertTrue(address(facets.cut) != address(0));
        assertTrue(address(facets.loupe) != address(0));
        assertTrue(address(facets.access) != address(0));
        assertTrue(address(facets.pause) != address(0));
        assertTrue(address(facets.reentrancy) != address(0));
        assertEq(specs.length, 4);
        assertEq(specs[2].facet, address(facets.access));
        assertEq(specs[2].selectors.length, 20);
    }

    function testDiamondCutAccessRequiresUpgraderRoleAndAllowsAdminCut() public {
        address diamond = _deployDiamond(false, false);
        IDiamond.FacetCut[] memory noCuts = new IDiamond.FacetCut[](0);

        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondCutAccessFacet.AccessControlUnauthorizedAccount.selector, USER, keccak256("UPGRADER_ROLE")
            )
        );
        IDiamondCut(diamond).diamondCut(noCuts, address(0), "");

        vm.prank(ADMIN);
        IDiamondCut(diamond).diamondCut(noCuts, address(0), "");
    }

    function testProtocolDiamondLoupeEnumeratesFacetTopologyAndManifestSupport() public {
        address diamond = _deployDiamond(false, false);
        IDiamondLoupe loupe = IDiamondLoupe(diamond);

        IDiamondLoupe.Facet[] memory facets = loupe.facets();
        address[] memory facetAddresses = loupe.facetAddresses();
        assertEq(facets.length, 3);
        assertEq(facetAddresses.length, facets.length);

        uint256 selectorCount;
        for (uint256 i; i < facets.length; ++i) {
            assertEq(facetAddresses[i], facets[i].facetAddress);
            assertTrue(facets[i].facetAddress != address(0));
            assertTrue(facets[i].functionSelectors.length != 0);
            bytes4[] memory selectors = loupe.facetFunctionSelectors(facets[i].facetAddress);
            assertEq(selectors.length, facets[i].functionSelectors.length);
            for (uint256 j; j < selectors.length; ++j) {
                assertEq(selectors[j], facets[i].functionSelectors[j]);
            }
            selectorCount += facets[i].functionSelectors.length;
        }
        assertEq(selectorCount, 16);
        assertEq(loupe.facetFunctionSelectors(USER).length, 0);

        assertTrue(IERC165(diamond).supportsInterface(type(IDiamondLoupe).interfaceId));
        assertFalse(IERC165(diamond).supportsInterface(bytes4(0)));
        assertFalse(IERC165(diamond).supportsInterface(bytes4(0xffffffff)));
    }

    function testValidatedDiamondCutInstallsOnlyRegisteredNewerFacet() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet facet = new UpgradeProbeFacet();
        UpgradeInit init = new UpgradeInit();
        IDiamond.FacetCut[] memory cut = _upgradeProbeCut(address(facet));

        vm.prank(ADMIN);
        IDiamondCut(diamond).diamondCut(cut, address(init), abi.encodeCall(UpgradeInit.init, (address(facet))));

        assertEq(UpgradeProbeFacet(diamond).upgradeProbe(), keccak256("validated"));
    }

    function testValidatedDiamondCutAllowsOneFacetAcrossMultipleCutEntries() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet facet = new UpgradeProbeFacet();
        UpgradeInit init = new UpgradeInit();
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](2);
        bytes4[] memory first = new bytes4[](1);
        first[0] = UpgradeProbeFacet.upgradeProbe.selector;
        bytes4[] memory second = new bytes4[](1);
        second[0] = UpgradeProbeFacet.secondProbe.selector;
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(facet), action: IDiamond.FacetCutAction.Add, functionSelectors: first
        });
        cut[1] = IDiamond.FacetCut({
            facetAddress: address(facet), action: IDiamond.FacetCutAction.Add, functionSelectors: second
        });

        vm.prank(ADMIN);
        IDiamondCut(diamond).diamondCut(cut, address(init), abi.encodeCall(UpgradeInit.init, (address(facet))));

        assertEq(UpgradeProbeFacet(diamond).secondProbe(), keccak256("second"));
    }

    function testValidatedDiamondCutRejectsUnlistedInitializerTopologyMutation() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet facet = new UpgradeProbeFacet();
        UpgradeInit init = new UpgradeInit();
        address originalOwner = IDiamondLoupe(diamond).facetAddress(IAccessControl.grantRole.selector);

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutSelectorOwnerMismatch.selector,
                IAccessControl.grantRole.selector,
                originalOwner,
                address(facet)
            )
        );
        IDiamondCut(diamond)
            .diamondCut(
                _upgradeProbeCut(address(facet)),
                address(init),
                abi.encodeCall(
                    UpgradeInit.initAndHijack, (address(facet), IAccessControl.grantRole.selector, address(facet))
                )
            );
        assertTrue(IAccessControl(diamond).hasRole(bytes32(0), ADMIN));
    }

    function testValidatedDiamondCutRejectsAddWithoutInitializer() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet facet = new UpgradeProbeFacet();

        vm.prank(ADMIN);
        vm.expectRevert(ValidatedDiamondCut.DiamondCutInitializerRequired.selector);
        IDiamondCut(diamond).diamondCut(_upgradeProbeCut(address(facet)), address(0), "");
    }

    function testValidatedDiamondCutRejectsUnregisteredFacetVersion() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet facet = new UpgradeProbeFacet();
        UpgradeInit init = new UpgradeInit();
        bytes32 namespace = facet.FACET_NAMESPACE();
        uint64 version = facet.FACET_VERSION();

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutFacetVersionNotInitialized.selector, namespace, version, uint64(0)
            )
        );
        IDiamondCut(diamond)
            .diamondCut(_upgradeProbeCut(address(facet)), address(init), abi.encodeCall(UpgradeInit.noop, ()));
    }

    function testValidatedDiamondCutCoordinatorCannotBeRemoved() public {
        address diamond = _deployDiamond(false, false);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(0), action: IDiamond.FacetCutAction.Remove, functionSelectors: selectors
        });

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutCoordinatorImmutable.selector, IDiamondCut.diamondCut.selector
            )
        );
        IDiamondCut(diamond).diamondCut(cut, address(0), "");
    }

    function testValidatedDiamondCutPreservesAccessRecoverySelectors() public {
        address diamond = _deployDiamond(false, false);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IAccessControl.grantRole.selector;
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(0), action: IDiamond.FacetCutAction.Remove, functionSelectors: selectors
        });

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, IAccessControl.grantRole.selector
            )
        );
        IDiamondCut(diamond).diamondCut(cut, address(0), "");
        assertTrue(IAccessControl(diamond).hasRole(bytes32(0), ADMIN));
    }

    function testValidatedDiamondCutPreservesLoupeRecoverySelectors() public {
        address diamond = _deployDiamond(false, false);

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, IDiamondLoupe.facets.selector
            )
        );
        IDiamondCut(diamond).diamondCut(_singleRemoveCut(IDiamondLoupe.facets.selector), address(0), "");
    }

    function testValidatedDiamondCutRejectsEveryMalformedInitializerCombination() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet facet = new UpgradeProbeFacet();
        UpgradeInit init = new UpgradeInit();
        IDiamond.FacetCut[] memory noCuts = new IDiamond.FacetCut[](0);

        vm.prank(ADMIN);
        vm.expectRevert(ValidatedDiamondCut.DiamondCutInitializerCalldataTooShort.selector);
        IDiamondCut(diamond).diamondCut(_upgradeProbeCut(address(facet)), address(init), hex"010203");

        vm.prank(ADMIN);
        vm.expectRevert(ValidatedDiamondCut.DiamondCutUnexpectedInitializerCalldata.selector);
        IDiamondCut(diamond).diamondCut(noCuts, address(0), hex"01");

        vm.prank(ADMIN);
        vm.expectRevert(ValidatedDiamondCut.DiamondCutInitializerCalldataTooShort.selector);
        IDiamondCut(diamond).diamondCut(noCuts, address(init), hex"010203");
    }

    function testValidatedDiamondCutRejectsZeroFacetMetadata() public {
        address diamond = _deployDiamond(false, false);
        VersionedFacet zeroNamespace = new VersionedFacet(bytes32(0), 1);
        VersionedFacet zeroVersion = new VersionedFacet(keccak256("cybergold.shared.test.zero-version"), 0);

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutInvalidFacetMetadata.selector,
                address(zeroNamespace),
                bytes32(0),
                uint64(1)
            )
        );
        IDiamondCut(diamond).diamondCut(_singleCut(address(zeroNamespace), bytes4(0x11111111)), address(0), "");

        bytes32 zeroVersionNamespace = zeroVersion.FACET_NAMESPACE();
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutInvalidFacetMetadata.selector,
                address(zeroVersion),
                zeroVersionNamespace,
                uint64(0)
            )
        );
        IDiamondCut(diamond).diamondCut(_singleCut(address(zeroVersion), bytes4(0x22222222)), address(0), "");
    }

    function testValidatedDiamondCutRejectsConflictingNamespaceExpectations() public {
        address diamond = _deployDiamond(false, false);
        bytes32 namespace = keccak256("cybergold.shared.test.duplicate-namespace");
        VersionedFacet firstFacet = new VersionedFacet(namespace, 1);
        VersionedFacet secondFacet = new VersionedFacet(namespace, 1);
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](2);
        cut[0] = _singleCut(address(firstFacet), bytes4(0x11111111))[0];
        cut[1] = _singleCut(address(secondFacet), bytes4(0x22222222))[0];

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(ValidatedDiamondCut.DiamondCutDuplicateFacetNamespace.selector, namespace)
        );
        IDiamondCut(diamond).diamondCut(cut, address(0), "");
    }

    function testValidatedDiamondCutRejectsNonIncreasingFacetVersion() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet firstFacet = new UpgradeProbeFacet();
        UpgradeInit init = new UpgradeInit();

        vm.prank(ADMIN);
        IDiamondCut(diamond)
            .diamondCut(
                _upgradeProbeCut(address(firstFacet)),
                address(init),
                abi.encodeCall(UpgradeInit.init, (address(firstFacet)))
            );

        bytes32 namespace = firstFacet.FACET_NAMESPACE();
        uint64 version = firstFacet.FACET_VERSION();
        VersionedFacet staleFacet = new VersionedFacet(namespace, version);
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutFacetVersionNotIncreasing.selector, namespace, version, version
            )
        );
        IDiamondCut(diamond).diamondCut(_singleCut(address(staleFacet), bytes4(0x22222222)), address(0), "");
    }

    function testValidatedDiamondCutRejectsNestedInitializerCut() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet facet = new UpgradeProbeFacet();
        UpgradeInit init = new UpgradeInit();
        bytes32 upgraderRole = keccak256("UPGRADER_ROLE");

        vm.prank(ADMIN);
        IAccessControl(diamond).grantRole(upgraderRole, diamond);

        vm.prank(ADMIN);
        vm.expectRevert(ValidatedDiamondCut.DiamondCutReentrancy.selector);
        IDiamondCut(diamond)
            .diamondCut(
                _upgradeProbeCut(address(facet)),
                address(init),
                abi.encodeCall(UpgradeInit.initAndReenter, (address(facet)))
            );
    }

    function testValidatedDiamondCutRejectsEveryInterfaceInvariantLoss() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet facet = new UpgradeProbeFacet();
        UpgradeInit init = new UpgradeInit();

        _expectInterfaceRecoveryFailure(
            diamond, facet, init, type(IDiamondCut).interfaceId, IERC165.supportsInterface.selector
        );
        _expectInterfaceRecoveryFailure(
            diamond, facet, init, type(IDiamondLoupe).interfaceId, IERC165.supportsInterface.selector
        );
        _expectInterfaceRecoveryFailure(
            diamond, facet, init, type(IERC165).interfaceId, IERC165.supportsInterface.selector
        );
        _expectInterfaceRecoveryFailure(
            diamond, facet, init, type(IAccessControl).interfaceId, IERC165.supportsInterface.selector
        );
        _expectInterfaceRecoveryFailure(
            diamond, facet, init, type(IAccessControlEnumerable).interfaceId, IERC165.supportsInterface.selector
        );
    }

    function testValidatedDiamondCutRejectsCorruptedManifestAdvertisementsAtEachAuthorityLayer() public {
        UpgradeInit init = new UpgradeInit();
        IDiamond.FacetCut[] memory noCuts = new IDiamond.FacetCut[](0);

        address diamond = _deployDiamond(false, false);
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, IDiamondCut.diamondCut.selector
            )
        );
        IDiamondCut(diamond)
            .diamondCut(
                noCuts,
                address(init),
                abi.encodeCall(UpgradeInit.initAndSetManifestAdvertisement, (type(IERC165).interfaceId, false))
            );

        diamond = _deployDiamond(false, false);
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, IAccessControl.hasRole.selector
            )
        );
        IDiamondCut(diamond)
            .diamondCut(
                noCuts,
                address(init),
                abi.encodeCall(
                    UpgradeInit.initAndSetManifestAdvertisement, (type(IAccessControlEnumerable).interfaceId, false)
                )
            );
    }

    function testValidatedDiamondCutRejectsEveryRoleCountFailureMode() public {
        address diamond = _deployDiamond(false, false);
        UpgradeInit init = new UpgradeInit();

        for (uint8 mode; mode < 6; ++mode) {
            RoleCountFaultFacet facet = new RoleCountFaultFacet(mode);
            IDiamond.FacetCut[] memory cut =
                _singleReplaceCut(address(facet), IAccessControlEnumerable.getRoleMemberCount.selector);
            vm.prank(ADMIN);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector,
                    IAccessControlEnumerable.getRoleMemberCount.selector
                )
            );
            IDiamondCut(diamond).diamondCut(cut, address(init), abi.encodeCall(UpgradeInit.init, (address(facet))));
        }
    }

    function testValidatedDiamondCutRejectsOnlyZeroAddressRoleMembers() public {
        address diamond = _deployDiamond(false, false);
        UpgradeInit init = new UpgradeInit();
        ZeroRoleMemberFacet facet = new ZeroRoleMemberFacet();
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IAccessControlEnumerable.getRoleMemberCount.selector;
        selectors[1] = IAccessControlEnumerable.getRoleMember.selector;
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(facet), action: IDiamond.FacetCutAction.Replace, functionSelectors: selectors
        });

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector,
                IAccessControlEnumerable.getRoleMemberCount.selector
            )
        );
        IDiamondCut(diamond).diamondCut(cut, address(init), abi.encodeCall(UpgradeInit.init, (address(facet))));
    }

    function testValidatedDiamondCutRejectsMalformedRoleMemberResponses() public {
        address diamond = _deployDiamond(false, false);
        UpgradeInit init = new UpgradeInit();

        for (uint8 mode; mode < 2; ++mode) {
            RoleMemberFaultFacet facet = new RoleMemberFaultFacet(mode);
            IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
            bytes4[] memory selectors = new bytes4[](2);
            selectors[0] = IAccessControlEnumerable.getRoleMemberCount.selector;
            selectors[1] = IAccessControlEnumerable.getRoleMember.selector;
            cut[0] = IDiamond.FacetCut({
                facetAddress: address(facet), action: IDiamond.FacetCutAction.Replace, functionSelectors: selectors
            });

            vm.prank(ADMIN);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector,
                    IAccessControlEnumerable.getRoleMemberCount.selector
                )
            );
            IDiamondCut(diamond).diamondCut(cut, address(init), abi.encodeCall(UpgradeInit.init, (address(facet))));
        }
    }

    function testAdvertisedManifestRemovalRequiresAtomicRetirement() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet facet = new UpgradeProbeFacet();
        UpgradeInit init = new UpgradeInit();
        bytes4 interfaceId = 0x0badcafe;

        vm.prank(ADMIN);
        IDiamondCut(diamond)
            .diamondCut(
                _upgradeProbeCut(address(facet)),
                address(init),
                abi.encodeCall(
                    UpgradeInit.initAndRegisterInterface,
                    (address(facet), interfaceId, UpgradeProbeFacet.upgradeProbe.selector)
                )
            );

        IDiamond.FacetCut[] memory removal = _singleRemoveCut(UpgradeProbeFacet.upgradeProbe.selector);
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, UpgradeProbeFacet.upgradeProbe.selector
            )
        );
        IDiamondCut(diamond).diamondCut(removal, address(0), "");

        InterfaceRetirementInit retirement = new InterfaceRetirementInit();
        bytes4[] memory retired = new bytes4[](1);
        retired[0] = interfaceId;
        vm.prank(ADMIN);
        IDiamondCut(diamond)
            .diamondCut(
                removal, address(retirement), abi.encodeCall(InterfaceRetirementInit.retireInterfaces, (retired))
            );

        assertEq(IDiamondLoupe(diamond).facetAddress(UpgradeProbeFacet.upgradeProbe.selector), address(0));
        assertFalse(IERC165(diamond).supportsInterface(interfaceId));
    }

    function testInterfaceManifestLibraryValidationAndMissingSelectorStates() public {
        InterfaceInvariantHarness harness = new InterfaceInvariantHarness();
        bytes4 interfaceId = 0x12345678;
        bytes4 first = 0x11111111;
        bytes4 second = 0x22222222;
        bytes4[] memory empty = new bytes4[](0);

        vm.expectRevert(abi.encodeWithSelector(LibInterfaceInvariant.InterfaceManifestEmpty.selector, bytes4(0)));
        harness.register(bytes4(0), _selectors(first));

        vm.expectRevert(
            abi.encodeWithSelector(LibInterfaceInvariant.InterfaceManifestEmpty.selector, bytes4(0xffffffff))
        );
        harness.register(bytes4(0xffffffff), _selectors(first));

        vm.expectRevert(abi.encodeWithSelector(LibInterfaceInvariant.InterfaceManifestEmpty.selector, interfaceId));
        harness.register(interfaceId, empty);

        vm.expectRevert(
            abi.encodeWithSelector(
                LibInterfaceInvariant.InterfaceManifestInvalidSelector.selector, interfaceId, uint256(0)
            )
        );
        harness.register(interfaceId, _selectors(bytes4(0)));

        bytes4[] memory duplicate = new bytes4[](2);
        duplicate[0] = first;
        duplicate[1] = first;
        vm.expectRevert(
            abi.encodeWithSelector(
                LibInterfaceInvariant.InterfaceManifestDuplicateSelector.selector, interfaceId, first
            )
        );
        harness.register(interfaceId, duplicate);

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = first;
        selectors[1] = second;
        harness.register(interfaceId, selectors);
        assertEq(harness.registeredInterfaceCount(), 1);
        assertEq(harness.advertisedInterfaceCount(), 1);
        assertEq(harness.registeredInterfaceAt(0), interfaceId);
        assertTrue(harness.isRegistered(interfaceId));
        assertFalse(harness.isRegistered(bytes4(0x87654321)));
        assertTrue(harness.isAdvertised(interfaceId));
        assertFalse(harness.isAdvertised(bytes4(0)));
        assertFalse(harness.isAdvertised(bytes4(0xffffffff)));
        assertEq(harness.firstMissingAdvertisedSelector(), first);

        harness.setSupported(interfaceId, true);
        assertEq(harness.firstMissingAdvertisedSelector(), IERC165.supportsInterface.selector);
        harness.setSupported(interfaceId, false);
        harness.setInstalled(first, true);
        assertEq(harness.firstMissingAdvertisedSelector(), second);
        harness.setInstalled(second, true);
        assertEq(harness.firstMissingAdvertisedSelector(), bytes4(0));

        vm.expectRevert(
            abi.encodeWithSelector(LibInterfaceInvariant.InterfaceManifestAlreadyRegistered.selector, interfaceId)
        );
        harness.register(interfaceId, selectors);
    }

    function testInterfaceRetirementRejectsUnregisteredStillInstalledAndDuplicateRetirement() public {
        InterfaceInvariantHarness harness = new InterfaceInvariantHarness();
        bytes4 interfaceId = 0x76543210;
        bytes4 selector = 0x11111111;

        vm.expectRevert(
            abi.encodeWithSelector(LibInterfaceInvariant.InterfaceManifestNotRegistered.selector, interfaceId)
        );
        harness.retire(interfaceId);

        harness.register(interfaceId, _selectors(selector));
        harness.setInstalled(selector, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibInterfaceInvariant.InterfaceRetirementSelectorsStillInstalled.selector, interfaceId
            )
        );
        harness.retire(interfaceId);

        harness.setInstalled(selector, false);
        harness.retire(interfaceId);
        assertFalse(harness.isAdvertised(interfaceId));
        assertTrue(harness.isRegistered(interfaceId));
        assertEq(harness.advertisedInterfaceCount(), 0);
        vm.expectRevert(
            abi.encodeWithSelector(LibInterfaceInvariant.InterfaceManifestAlreadyRetired.selector, interfaceId)
        );
        harness.retire(interfaceId);
    }

    function testValidatedCutRejectsInvalidErc165Advertisement() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet facet = new UpgradeProbeFacet();
        UpgradeInit init = new UpgradeInit();
        IDiamond.FacetCut[] memory cut = _upgradeProbeCut(address(facet));

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, IERC165.supportsInterface.selector
            )
        );
        IDiamondCut(diamond)
            .diamondCut(
                cut,
                address(init),
                abi.encodeCall(UpgradeInit.initAndSetInterface, (address(facet), bytes4(0xffffffff), true))
            );
    }

    function testStandardInterfaceManifestsRegisterCompleteSelectorClosures() public {
        InterfaceInvariantHarness harness = new InterfaceInvariantHarness();
        harness.registerAccessControl();
        _assertManifest(harness, type(IAccessControl).interfaceId, _accessControlManifest());

        harness = new InterfaceInvariantHarness();
        harness.registerAccessControlEnumerable();
        _assertManifest(harness, type(IAccessControlEnumerable).interfaceId, _accessControlEnumerableManifest());

        harness = new InterfaceInvariantHarness();
        harness.registerAccessControlDefaultAdminRules();
        _assertManifest(
            harness, type(IAccessControlDefaultAdminRules).interfaceId, _accessControlDefaultAdminRulesManifest()
        );

        harness = new InterfaceInvariantHarness();
        harness.registerErc20();
        _assertManifest(harness, type(IERC20).interfaceId, _erc20Manifest());

        harness = new InterfaceInvariantHarness();
        harness.registerErc20Metadata();
        _assertManifest(harness, type(IERC20Metadata).interfaceId, _erc20MetadataManifest());

        harness = new InterfaceInvariantHarness();
        harness.registerErc20Permit();
        _assertManifest(harness, type(IERC20Permit).interfaceId, _erc20PermitManifest());

        harness = new InterfaceInvariantHarness();
        harness.registerErc1155();
        _assertManifest(harness, type(IERC1155).interfaceId, _erc1155Manifest());

        harness = new InterfaceInvariantHarness();
        harness.registerErc1155MetadataUri();
        _assertManifest(harness, type(IERC1155MetadataURI).interfaceId, _erc1155MetadataManifest());

        harness = new InterfaceInvariantHarness();
        harness.registerErc6372();
        _assertManifest(harness, type(IERC6372).interfaceId, _erc6372Manifest());

        harness = new InterfaceInvariantHarness();
        harness.registerErc721Receiver();
        _assertManifest(harness, type(IERC721Receiver).interfaceId, _erc721ReceiverManifest());

        harness = new InterfaceInvariantHarness();
        harness.registerErc1155Receiver();
        _assertManifest(harness, type(IERC1155Receiver).interfaceId, _erc1155ReceiverManifest());

        harness = new InterfaceInvariantHarness();
        harness.registerErc165();
        _assertManifest(harness, type(IERC165).interfaceId, _selectors(IERC165.supportsInterface.selector));

        harness = new InterfaceInvariantHarness();
        harness.registerDiamondCut();
        _assertManifest(harness, type(IDiamondCut).interfaceId, _selectors(IDiamondCut.diamondCut.selector));

        harness = new InterfaceInvariantHarness();
        harness.registerDiamondLoupe();
        bytes4[] memory loupe = new bytes4[](4);
        loupe[0] = IDiamondLoupe.facets.selector;
        loupe[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        loupe[2] = IDiamondLoupe.facetAddresses.selector;
        loupe[3] = IDiamondLoupe.facetAddress.selector;
        _assertManifest(harness, type(IDiamondLoupe).interfaceId, loupe);
    }

    function testValidatedDiamondCutRejectsEveryPostflightTopologyCorruption() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet facet = new UpgradeProbeFacet();
        UpgradeInit init = new UpgradeInit();
        IDiamond.FacetCut[] memory cut = _upgradeProbeCut(address(facet));

        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(ValidatedDiamondCut.DiamondCutSelectorCountMismatch.selector, 17, 18));
        IDiamondCut(diamond)
            .diamondCut(
                cut,
                address(init),
                abi.encodeCall(UpgradeInit.initAndAppendSelector, (address(facet), bytes4(0xAAAAAAAA)))
            );

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutSelectorOwnerMismatch.selector,
                UpgradeProbeFacet.upgradeProbe.selector,
                address(facet),
                USER
            )
        );
        IDiamondCut(diamond)
            .diamondCut(
                cut,
                address(init),
                abi.encodeCall(
                    UpgradeInit.initAndHijack, (address(facet), UpgradeProbeFacet.upgradeProbe.selector, USER)
                )
            );

        address accessFacet = IDiamondLoupe(diamond).facetAddress(IAccessControl.grantRole.selector);
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutSelectorOwnerMismatch.selector,
                IAccessControl.grantRole.selector,
                address(0),
                accessFacet
            )
        );
        IDiamondCut(diamond)
            .diamondCut(
                cut,
                address(init),
                abi.encodeCall(
                    UpgradeInit.initAndSetSelectorPosition,
                    (address(facet), IAccessControl.grantRole.selector, uint16(0))
                )
            );
    }

    function testProtocolDiamondRejectsUnknownSelectorWithoutValue() public {
        address diamond = _deployDiamond(false, false);
        bytes4 unknownSelector = bytes4(0xDEADBEEF);

        (bool ok, bytes memory err) = diamond.call(abi.encodeWithSelector(unknownSelector));

        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(FunctionNotFound.selector, unknownSelector));
    }

    function testInfraInitBubblesDelegateRevertData() public {
        InfraInit init = new InfraInit();
        RevertDataInitFacet target = new RevertDataInitFacet();
        InfraInit.InitConfig memory cfg;
        cfg.accessControlFacet = address(target);

        vm.expectRevert(RevertDataInitFacet.InitBoom.selector);
        init.init(cfg);
    }

    function testInfraInitWrapsEmptyDelegateRevert() public {
        InfraInit init = new InfraInit();
        EmptyRevertInitFacet target = new EmptyRevertInitFacet();
        InfraInit.InitConfig memory cfg;
        cfg.accessControlFacet = address(target);

        vm.expectRevert(
            abi.encodeWithSelector(
                InfraInit.FacetInitFailed.selector,
                address(target),
                abi.encodeWithSelector(AccessControlFacet.initAccessControl.selector, address(0))
            )
        );
        init.init(cfg);
    }

    function testFacetVersionRegistryRejectsDuplicateAndProbeFailure() public {
        FacetVersionRegistryHarness harness = new FacetVersionRegistryHarness();
        bytes32 namespace = keccak256("cybergold.shared.test.version");
        assertFalse(harness.isInstalled(address(0)));

        NoVersionFacet noVersion = new NoVersionFacet();
        assertFalse(harness.isInstalled(address(noVersion)));
        vm.expectRevert(
            abi.encodeWithSelector(FacetVersionRegistry.FacetVersionProbeFailed.selector, address(noVersion))
        );
        harness.probeMetadata(address(noVersion));

        VersionedFacet versioned = new VersionedFacet(namespace, 3);
        (bytes32 probedNamespace, uint64 probedVersion) = harness.probeMetadata(address(versioned));
        assertEq(probedNamespace, namespace);
        assertEq(probedVersion, 3);

        vm.expectRevert(
            abi.encodeWithSelector(FacetVersionRegistry.FacetRuntimeNotInstalled.selector, address(versioned))
        );
        harness.authorizeAndSet(address(versioned));

        VersionedFacet conflicting = new VersionedFacet(namespace, 3);
        harness.authorize(address(versioned));
        vm.expectRevert(
            abi.encodeWithSelector(FacetVersionRegistry.FacetRuntimeAuthorizationConflict.selector, namespace)
        );
        harness.authorize(address(conflicting));
    }

    function testLaunchFacetVersionRegistryRequiresUniqueNonzeroNamespaceAtExactVersionOne() public {
        FacetVersionRegistryHarness harness = new FacetVersionRegistryHarness();
        bytes32 namespace = keccak256("cybergold.shared.test.launch-version");

        VersionedFacet zeroNamespace = new VersionedFacet(bytes32(0), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FacetVersionRegistry.FacetLaunchMetadataInvalid.selector, address(zeroNamespace), bytes32(0), uint64(1)
            )
        );
        harness.registerLaunch(address(zeroNamespace));

        VersionedFacet zeroVersion = new VersionedFacet(namespace, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                FacetVersionRegistry.FacetLaunchMetadataInvalid.selector, address(zeroVersion), namespace, uint64(0)
            )
        );
        harness.registerLaunch(address(zeroVersion));

        VersionedFacet futureVersion = new VersionedFacet(namespace, 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                FacetVersionRegistry.FacetLaunchMetadataInvalid.selector, address(futureVersion), namespace, uint64(2)
            )
        );
        harness.registerLaunch(address(futureVersion));

        NoVersionFacet missingMetadata = new NoVersionFacet();
        vm.expectRevert(
            abi.encodeWithSelector(FacetVersionRegistry.FacetVersionProbeFailed.selector, address(missingMetadata))
        );
        harness.registerLaunch(address(missingMetadata));

        address eoa = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(FacetVersionRegistry.FacetVersionProbeFailed.selector, eoa));
        harness.registerLaunch(eoa);

        VersionedFacet launchFacet = new VersionedFacet(namespace, 1);
        vm.expectRevert(
            abi.encodeWithSelector(FacetVersionRegistry.FacetRuntimeNotInstalled.selector, address(launchFacet))
        );
        harness.registerLaunch(address(launchFacet));
        harness.install(address(launchFacet), bytes4(0x11111111));
        assertTrue(harness.isInstalled(address(launchFacet)));
        (bytes32 registeredNamespace, uint64 registeredVersion) = harness.registerLaunch(address(launchFacet));
        assertEq(registeredNamespace, namespace);
        assertEq(registeredVersion, 1);
        assertEq(harness.registeredRuntimeCodeHash(namespace), address(launchFacet).codehash);

        vm.expectRevert(
            abi.encodeWithSelector(
                FacetVersionRegistry.FacetInitVersionAlreadyInitialized.selector, namespace, uint64(1), uint64(1)
            )
        );
        harness.registerLaunch(address(launchFacet));

        (registeredNamespace, registeredVersion) = harness.probeMetadata(address(futureVersion));
        assertEq(registeredNamespace, namespace);
        assertEq(registeredVersion, 2);
    }

    function testValidatedDiamondCutRejectsHigherVersionWithUnchangedRuntime() public {
        address diamond = _deployDiamond(false, false);
        bytes32 namespace = keccak256("cybergold.shared.test.mutable-runtime");
        MutableMetadataFacet first = new MutableMetadataFacet(namespace, 1);
        MutableMetadataFacet second = new MutableMetadataFacet(namespace, 2);
        UpgradeInit init = new UpgradeInit();
        assertEq(address(first).codehash, address(second).codehash);

        vm.prank(ADMIN);
        IDiamondCut(diamond)
            .diamondCut(
                _singleCut(address(first), MutableMetadataFacet.upgradeProbe.selector),
                address(init),
                abi.encodeCall(UpgradeInit.init, (address(first)))
            );

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutFacetRuntimeUnchanged.selector, namespace, address(first).codehash
            )
        );
        IDiamondCut(diamond)
            .diamondCut(
                _singleReplaceCut(address(second), MutableMetadataFacet.upgradeProbe.selector),
                address(init),
                abi.encodeCall(UpgradeInit.init, (address(second)))
            );
    }

    function testValidatedDiamondCutRejectsCorruptedRegisteredRuntimeIdentity() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet facet = new UpgradeProbeFacet();
        UpgradeInit init = new UpgradeInit();
        bytes32 namespace = facet.FACET_NAMESPACE();
        bytes32 corruptedRuntimeCodeHash = keccak256("corrupted-runtime-code-hash");

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutFacetRuntimeNotInitialized.selector,
                namespace,
                address(facet).codehash,
                corruptedRuntimeCodeHash
            )
        );
        IDiamondCut(diamond)
            .diamondCut(
                _upgradeProbeCut(address(facet)),
                address(init),
                abi.encodeCall(UpgradeInit.initAndCorruptRuntimeCodeHash, (address(facet), corruptedRuntimeCodeHash))
            );
    }

    function testValidatedDiamondCutAllowsUnchangedSelectorWithNewerRuntime() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet first = new UpgradeProbeFacet();
        UpgradeProbeFacetV2 second = new UpgradeProbeFacetV2();
        UpgradeInit init = new UpgradeInit();

        vm.prank(ADMIN);
        IDiamondCut(diamond)
            .diamondCut(
                _upgradeProbeCut(address(first)), address(init), abi.encodeCall(UpgradeInit.init, (address(first)))
            );
        vm.prank(ADMIN);
        IDiamondCut(diamond)
            .diamondCut(
                _singleReplaceCut(address(second), UpgradeProbeFacet.upgradeProbe.selector),
                address(init),
                abi.encodeCall(UpgradeInit.init, (address(second)))
            );
        assertEq(UpgradeProbeFacetV2(diamond).upgradeProbe(), keccak256("validated-v2"));
    }

    function testValidatedDiamondCutRejectsInitializerOnlyAndExtraRuntimeVersionUpdates() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet facet = new UpgradeProbeFacet();
        UpgradeProbeFacetV2 extra = new UpgradeProbeFacetV2();
        UpgradeInit init = new UpgradeInit();
        IDiamond.FacetCut[] memory noCuts = new IDiamond.FacetCut[](0);
        bytes32 facetNamespace = facet.FACET_NAMESPACE();
        uint64 facetVersion = facet.FACET_VERSION();
        bytes32 extraNamespace = extra.FACET_NAMESPACE();
        uint64 extraVersion = extra.FACET_VERSION();

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                FacetVersionRegistry.FacetRuntimeUpgradeNotAuthorized.selector,
                address(facet),
                facetNamespace,
                facetVersion,
                address(facet).codehash
            )
        );
        IDiamondCut(diamond).diamondCut(noCuts, address(init), abi.encodeCall(UpgradeInit.init, (address(facet))));

        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                FacetVersionRegistry.FacetRuntimeUpgradeNotAuthorized.selector,
                address(extra),
                extraNamespace,
                extraVersion,
                address(extra).codehash
            )
        );
        IDiamondCut(diamond)
            .diamondCut(
                _upgradeProbeCut(address(facet)),
                address(init),
                abi.encodeCall(UpgradeInit.initTwo, (address(facet), address(extra)))
            );
        assertEq(IDiamondLoupe(diamond).facetAddress(UpgradeProbeFacet.upgradeProbe.selector), address(0));
    }

    function testValidatedDiamondCutRejectsRuntimeVersionRollback() public {
        address diamond = _deployDiamond(false, false);
        UpgradeProbeFacet first = new UpgradeProbeFacet();
        UpgradeProbeFacetV2 second = new UpgradeProbeFacetV2();
        UpgradeProbeFacetV1Alternative rollback = new UpgradeProbeFacetV1Alternative();
        UpgradeInit init = new UpgradeInit();

        vm.startPrank(ADMIN);
        IDiamondCut(diamond)
            .diamondCut(
                _upgradeProbeCut(address(first)), address(init), abi.encodeCall(UpgradeInit.init, (address(first)))
            );
        IDiamondCut(diamond)
            .diamondCut(
                _singleReplaceCut(address(second), UpgradeProbeFacet.upgradeProbe.selector),
                address(init),
                abi.encodeCall(UpgradeInit.init, (address(second)))
            );
        vm.expectRevert(
            abi.encodeWithSelector(
                ValidatedDiamondCut.DiamondCutFacetVersionNotIncreasing.selector,
                rollback.FACET_NAMESPACE(),
                uint64(2),
                uint64(1)
            )
        );
        IDiamondCut(diamond)
            .diamondCut(
                _singleReplaceCut(address(rollback), UpgradeProbeFacet.upgradeProbe.selector),
                address(init),
                abi.encodeCall(UpgradeInit.init, (address(rollback)))
            );
        vm.stopPrank();
    }

    function _deployDiamond(bool includePause, bool includeReentrancy) internal returns (address diamond) {
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = ADMIN;
        cfg.includePause = includePause;
        cfg.includeReentrancy = includeReentrancy;
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.deploy(cfg);
        diamond = address(art.diamond);
    }

    function _upgradeProbeCut(address facet) internal pure returns (IDiamond.FacetCut[] memory cut) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = UpgradeProbeFacet.upgradeProbe.selector;
        cut = new IDiamond.FacetCut[](1);
        cut[0] =
            IDiamond.FacetCut({facetAddress: facet, action: IDiamond.FacetCutAction.Add, functionSelectors: selectors});
    }

    function _singleCut(address facet, bytes4 selector) internal pure returns (IDiamond.FacetCut[] memory cut) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        cut = new IDiamond.FacetCut[](1);
        cut[0] =
            IDiamond.FacetCut({facetAddress: facet, action: IDiamond.FacetCutAction.Add, functionSelectors: selectors});
    }

    function _singleReplaceCut(address facet, bytes4 selector) internal pure returns (IDiamond.FacetCut[] memory cut) {
        cut = _singleCut(facet, selector);
        cut[0].action = IDiamond.FacetCutAction.Replace;
    }

    function _singleRemoveCut(bytes4 selector) internal pure returns (IDiamond.FacetCut[] memory cut) {
        cut = _singleCut(address(0), selector);
        cut[0].action = IDiamond.FacetCutAction.Remove;
    }

    function _selectors(bytes4 selector) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = selector;
    }

    function _assertManifest(InterfaceInvariantHarness harness, bytes4 interfaceId, bytes4[] memory selectors)
        internal
    {
        assertEq(harness.registeredInterfaceCount(), 1);
        assertTrue(harness.isAdvertised(interfaceId));
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(harness.firstMissingAdvertisedSelector(), selectors[i]);
            harness.setInstalled(selectors[i], true);
        }
        assertEq(harness.firstMissingAdvertisedSelector(), bytes4(0));
    }

    function _accessControlManifest() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = IERC165.supportsInterface.selector;
        selectors[1] = IAccessControl.hasRole.selector;
        selectors[2] = IAccessControl.getRoleAdmin.selector;
        selectors[3] = IAccessControl.grantRole.selector;
        selectors[4] = IAccessControl.revokeRole.selector;
        selectors[5] = IAccessControl.renounceRole.selector;
    }

    function _accessControlEnumerableManifest() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](8);
        selectors[0] = IERC165.supportsInterface.selector;
        selectors[1] = IAccessControl.hasRole.selector;
        selectors[2] = IAccessControl.getRoleAdmin.selector;
        selectors[3] = IAccessControl.grantRole.selector;
        selectors[4] = IAccessControl.revokeRole.selector;
        selectors[5] = IAccessControl.renounceRole.selector;
        selectors[6] = IAccessControlEnumerable.getRoleMember.selector;
        selectors[7] = IAccessControlEnumerable.getRoleMemberCount.selector;
    }

    function _accessControlDefaultAdminRulesManifest() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](16);
        bytes4[] memory accessSelectors = _accessControlManifest();
        for (uint256 i; i < accessSelectors.length; ++i) {
            selectors[i] = accessSelectors[i];
        }
        selectors[6] = IAccessControlDefaultAdminRules.defaultAdmin.selector;
        selectors[7] = IAccessControlDefaultAdminRules.pendingDefaultAdmin.selector;
        selectors[8] = IAccessControlDefaultAdminRules.defaultAdminDelay.selector;
        selectors[9] = IAccessControlDefaultAdminRules.pendingDefaultAdminDelay.selector;
        selectors[10] = IAccessControlDefaultAdminRules.defaultAdminDelayIncreaseWait.selector;
        selectors[11] = IAccessControlDefaultAdminRules.beginDefaultAdminTransfer.selector;
        selectors[12] = IAccessControlDefaultAdminRules.cancelDefaultAdminTransfer.selector;
        selectors[13] = IAccessControlDefaultAdminRules.acceptDefaultAdminTransfer.selector;
        selectors[14] = IAccessControlDefaultAdminRules.changeDefaultAdminDelay.selector;
        selectors[15] = IAccessControlDefaultAdminRules.rollbackDefaultAdminDelay.selector;
    }

    function _erc20Manifest() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = IERC20.totalSupply.selector;
        selectors[1] = IERC20.balanceOf.selector;
        selectors[2] = IERC20.transfer.selector;
        selectors[3] = IERC20.allowance.selector;
        selectors[4] = IERC20.approve.selector;
        selectors[5] = IERC20.transferFrom.selector;
    }

    function _erc20MetadataManifest() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        bytes4[] memory erc20Selectors = _erc20Manifest();
        for (uint256 i; i < erc20Selectors.length; ++i) {
            selectors[i] = erc20Selectors[i];
        }
        selectors[6] = IERC20Metadata.name.selector;
        selectors[7] = IERC20Metadata.symbol.selector;
        selectors[8] = IERC20Metadata.decimals.selector;
    }

    function _erc20PermitManifest() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IERC20Permit.permit.selector;
        selectors[1] = IERC20Permit.nonces.selector;
        selectors[2] = IERC20Permit.DOMAIN_SEPARATOR.selector;
    }

    function _erc1155Manifest() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = IERC165.supportsInterface.selector;
        selectors[1] = IERC1155.balanceOf.selector;
        selectors[2] = IERC1155.balanceOfBatch.selector;
        selectors[3] = IERC1155.setApprovalForAll.selector;
        selectors[4] = IERC1155.isApprovedForAll.selector;
        selectors[5] = IERC1155.safeTransferFrom.selector;
        selectors[6] = IERC1155.safeBatchTransferFrom.selector;
    }

    function _erc1155MetadataManifest() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](8);
        bytes4[] memory erc1155Selectors = _erc1155Manifest();
        for (uint256 i; i < erc1155Selectors.length; ++i) {
            selectors[i] = erc1155Selectors[i];
        }
        selectors[7] = IERC1155MetadataURI.uri.selector;
    }

    function _erc6372Manifest() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IERC6372.clock.selector;
        selectors[1] = IERC6372.CLOCK_MODE.selector;
    }

    function _erc721ReceiverManifest() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IERC721Receiver.onERC721Received.selector;
    }

    function _erc1155ReceiverManifest() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IERC165.supportsInterface.selector;
        selectors[1] = IERC1155Receiver.onERC1155Received.selector;
        selectors[2] = IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function _expectInterfaceRecoveryFailure(
        address diamond,
        UpgradeProbeFacet facet,
        UpgradeInit init,
        bytes4 interfaceId,
        bytes4 expectedSelector
    ) internal {
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(ValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, expectedSelector)
        );
        IDiamondCut(diamond)
            .diamondCut(
                _upgradeProbeCut(address(facet)),
                address(init),
                abi.encodeCall(UpgradeInit.initAndSetInterface, (address(facet), interfaceId, true))
            );
    }

    function envAddressRequired(string[] memory keys) external view returns (address) {
        return DeployParamsHelper.envAddressRequired(vm, keys);
    }

    function envUintRequired(string[] memory keys) external view returns (uint256) {
        return DeployParamsHelper.envUintRequired(vm, keys);
    }

    function envStringRequired(string[] memory keys) external view returns (string memory) {
        return DeployParamsHelper.envStringRequired(vm, keys);
    }

    function writeFacets(string memory label, string[] memory names, address[] memory facets)
        external
        returns (string memory)
    {
        return DeployParamsHelper.writeFacets(vm, label, names, facets);
    }
}

contract FacetVersionRegistryHarness is FacetVersionRegistry {
    function install(address target, bytes4 selector) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.selectors.push(selector);
        ds.facetAddressAndSelectorPosition[selector].facetAddress = target;
    }

    function probeMetadata(address target) external view returns (bytes32 namespace, uint64 version) {
        return _facetVersion(target);
    }

    function authorizeAndSet(address target) external returns (bytes32 namespace, uint64 version) {
        (namespace, version) = _facetVersion(target);
        _authorizeFacetRuntimeUpgrade(target, namespace, version, target.codehash);
        return _checkAndSetFacetVersion(target);
    }

    function authorize(address target) external {
        (bytes32 namespace, uint64 version) = _facetVersion(target);
        _authorizeFacetRuntimeUpgrade(target, namespace, version, target.codehash);
    }

    function registerLaunch(address target) external returns (bytes32 namespace, uint64 version) {
        return _checkAndSetLaunchFacetVersion(target);
    }

    function registeredRuntimeCodeHash(bytes32 namespace) external view returns (bytes32) {
        return _registeredFacetRuntimeCodeHash(namespace);
    }

    function isInstalled(address target) external view returns (bool) {
        return _isInstalledFacet(target);
    }
}

contract VersionedFacet {
    bytes32 public immutable FACET_NAMESPACE;
    uint64 public immutable FACET_VERSION;

    constructor(bytes32 namespace, uint64 version) {
        FACET_NAMESPACE = namespace;
        FACET_VERSION = version;
    }
}

contract NoVersionFacet {}

contract UpgradeProbeFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.test.upgrade.probe");
    uint64 public constant FACET_VERSION = 1;

    function upgradeProbe() external pure returns (bytes32) {
        return keccak256("validated");
    }

    function secondProbe() external pure returns (bytes32) {
        return keccak256("second");
    }
}

contract UpgradeProbeFacetV2 {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.test.upgrade.probe");
    uint64 public constant FACET_VERSION = 2;

    function upgradeProbe() external pure returns (bytes32) {
        return keccak256("validated-v2");
    }
}

contract UpgradeProbeFacetV1Alternative {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.test.upgrade.probe");
    uint64 public constant FACET_VERSION = 1;

    function upgradeProbe() external pure returns (bytes32) {
        return keccak256("rollback-runtime");
    }
}

contract MutableMetadataFacet {
    bytes32 public FACET_NAMESPACE;
    uint64 public FACET_VERSION;

    constructor(bytes32 namespace, uint64 version) {
        FACET_NAMESPACE = namespace;
        FACET_VERSION = version;
    }

    function upgradeProbe() external pure returns (bytes32) {
        return keccak256("mutable-runtime");
    }
}

contract UpgradeInit is FacetVersionRegistry {
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 private constant INTERFACE_SELECTOR_MANIFESTS_SLOT =
        0xff092d620461098e263264e3201620767bd3639a1424ca912571a18d26f5966e;

    function init(address facet) external {
        _checkAndSetFacetVersion(facet);
    }

    function noop() external pure {}

    function initTwo(address first, address second) external {
        _checkAndSetFacetVersion(first);
        _checkAndSetFacetVersion(second);
    }

    function initAndHijack(address facet, bytes4 selector, address newOwner) external {
        _checkAndSetFacetVersion(facet);
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress = newOwner;
    }

    function initAndReenter(address facet) external {
        _checkAndSetFacetVersion(facet);
        IDiamondCut.FacetCut[] memory noCuts = new IDiamondCut.FacetCut[](0);
        IDiamondCut(address(this)).diamondCut(noCuts, address(0), "");
    }

    function initAndSetInterface(address facet, bytes4 interfaceId, bool supported) external {
        _checkAndSetFacetVersion(facet);
        LibDiamond.diamondStorage().supportedInterfaces[interfaceId] = supported;
    }

    function initAndRegisterInterface(address facet, bytes4 interfaceId, bytes4 selector) external {
        _checkAndSetFacetVersion(facet);
        bytes4[][] memory groups = new bytes4[][](1);
        groups[0] = new bytes4[](1);
        groups[0][0] = selector;
        LibInterfaceInvariant.registerInterface(interfaceId, groups);
    }

    function initAndAppendSelector(address facet, bytes4 selector) external {
        _checkAndSetFacetVersion(facet);
        LibDiamond.diamondStorage().selectors.push(selector);
    }

    function initAndSetSelectorPosition(address facet, bytes4 selector, uint16 position) external {
        _checkAndSetFacetVersion(facet);
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].selectorPosition = position;
    }

    function initAndCorruptRuntimeCodeHash(address facet, bytes32 runtimeCodeHash) external {
        (bytes32 namespace,) = _checkAndSetFacetVersion(facet);
        bytes32 runtimeCodeHashesSlot = bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 1);
        bytes32 valueSlot = keccak256(abi.encode(namespace, runtimeCodeHashesSlot));
        assembly {
            sstore(valueSlot, runtimeCodeHash)
        }
    }

    function initAndSetManifestAdvertisement(bytes4 interfaceId, bool advertised) external {
        bytes32 advertisedSlot = bytes32(uint256(INTERFACE_SELECTOR_MANIFESTS_SLOT) + 2);
        bytes32 valueSlot = keccak256(abi.encode(interfaceId, advertisedSlot));
        assembly {
            sstore(valueSlot, advertised)
        }
    }
}

contract RoleCountFaultFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("openzeppelin.storage.AccessControl");
    uint64 public constant FACET_VERSION = 3;

    uint8 private immutable mode;

    constructor(uint8 mode_) {
        mode = mode_;
    }

    function getRoleMemberCount(bytes32 role) external view returns (uint256) {
        bool isAdmin = role == bytes32(0);
        if (mode == 0 || (mode == 3 && isAdmin)) revert();
        if (mode == 1 || (mode == 4 && isAdmin)) {
            assembly {
                return(0, 0)
            }
        }
        if ((mode == 2 && !isAdmin) || (mode == 5 && isAdmin)) return 0;
        return 1;
    }
}

contract ZeroRoleMemberFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("openzeppelin.storage.AccessControl");
    uint64 public constant FACET_VERSION = 3;

    function getRoleMemberCount(bytes32) external pure returns (uint256) {
        return 1;
    }

    function getRoleMember(bytes32, uint256) external pure returns (address) {
        return address(0);
    }
}

contract RoleMemberFaultFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("openzeppelin.storage.AccessControl");
    uint64 public constant FACET_VERSION = 3;

    uint8 private immutable mode;

    constructor(uint8 mode_) {
        mode = mode_;
    }

    function getRoleMemberCount(bytes32) external pure returns (uint256) {
        return 1;
    }

    function getRoleMember(bytes32, uint256) external view returns (address) {
        if (mode == 0) revert();
        assembly {
            return(0, 0)
        }
    }
}

contract InterfaceInvariantHarness {
    function registerErc165() external {
        StandardInterfaceManifests.registerErc165();
    }

    function registerDiamondCut() external {
        StandardInterfaceManifests.registerDiamondCut();
    }

    function registerDiamondLoupe() external {
        StandardInterfaceManifests.registerDiamondLoupe();
    }

    function registerAccessControl() external {
        StandardInterfaceManifests.registerAccessControl();
    }

    function registerAccessControlEnumerable() external {
        StandardInterfaceManifests.registerAccessControlEnumerable();
    }

    function registerAccessControlDefaultAdminRules() external {
        StandardInterfaceManifests.registerAccessControlDefaultAdminRules();
    }

    function registerErc20() external {
        StandardInterfaceManifests.registerErc20();
    }

    function registerErc20Metadata() external {
        StandardInterfaceManifests.registerErc20Metadata();
    }

    function registerErc20Permit() external {
        StandardInterfaceManifests.registerErc20Permit();
    }

    function registerErc1155() external {
        StandardInterfaceManifests.registerErc1155();
    }

    function registerErc1155MetadataUri() external {
        StandardInterfaceManifests.registerErc1155MetadataUri();
    }

    function registerErc6372() external {
        StandardInterfaceManifests.registerErc6372();
    }

    function registerErc721Receiver() external {
        StandardInterfaceManifests.registerErc721Receiver();
    }

    function registerErc1155Receiver() external {
        StandardInterfaceManifests.registerErc1155Receiver();
    }

    function register(bytes4 interfaceId, bytes4[] memory selectors) external {
        bytes4[][] memory groups = new bytes4[][](1);
        groups[0] = selectors;
        LibInterfaceInvariant.registerInterface(interfaceId, groups);
    }

    function setSupported(bytes4 interfaceId, bool supported) external {
        LibDiamond.diamondStorage().supportedInterfaces[interfaceId] = supported;
    }

    function setInstalled(bytes4 selector, bool installed) external {
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress =
            installed ? address(this) : address(0);
    }

    function firstMissingAdvertisedSelector() external view returns (bytes4) {
        return LibInterfaceInvariant.firstMissingAdvertisedSelector();
    }

    function isAdvertised(bytes4 interfaceId) external view returns (bool) {
        return LibInterfaceInvariant.isAdvertised(interfaceId);
    }

    function isRegistered(bytes4 interfaceId) external view returns (bool) {
        return LibInterfaceInvariant.isRegistered(interfaceId);
    }

    function retire(bytes4 interfaceId) external {
        LibInterfaceInvariant.retireInterface(interfaceId);
    }

    function registeredInterfaceCount() external view returns (uint256) {
        return LibInterfaceInvariant.registeredInterfaceCount();
    }

    function advertisedInterfaceCount() external view returns (uint256) {
        return LibInterfaceInvariant.advertisedInterfaceCount();
    }

    function registeredInterfaceAt(uint256 index) external view returns (bytes4) {
        return LibInterfaceInvariant.registeredInterfaceAt(index);
    }
}

contract RevertDataInitFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.test.revert-data");
    uint64 public constant FACET_VERSION = 1;

    error InitBoom();

    function initAccessControl(address) external pure {
        revert InitBoom();
    }
}

contract EmptyRevertInitFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.shared.test.empty-revert");
    uint64 public constant FACET_VERSION = 1;

    function initAccessControl(address) external pure {
        assembly {
            revert(0, 0)
        }
    }
}
