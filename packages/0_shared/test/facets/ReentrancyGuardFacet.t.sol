// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {DiamondArgs} from "diamond-1/Diamond.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ProtocolDiamond} from "../../src/diamond/ProtocolDiamond.sol";
import {ReentrancyGuardFacet} from "diamond-infra/facets/ReentrancyGuardFacet.sol";
import {ReentrancyGuardInitializable} from "diamond-infra/helpers/ReentrancyGuardInitializable.sol";
import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";

interface ITransientGuardSecond {
    function guardedSecond() external returns (bool);
}

contract TransientGuardFirstFacet is ReentrancyGuardInitializable {
    function guardedFirstThenSecond() external nonReentrant {
        ITransientGuardSecond(address(this)).guardedSecond();
    }
}

contract TransientGuardSecondFacet is ReentrancyGuardInitializable {
    function guardedSecond() external nonReentrant returns (bool) {
        return true;
    }
}

contract ReentrancyGuardFacetTest is Test {
    bytes32 internal constant REENTRANCY_GUARD_STORAGE =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    address internal admin = address(0xA11CE);
    address internal attacker = address(0xBEEF);

    ReentrancyGuardFacet internal reentrancyFacet;
    address internal diamond;

    function setUp() public {
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = admin;
        cfg.includePause = false;
        cfg.includeReentrancy = true;
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.deploy(cfg);
        diamond = address(art.diamond);
        reentrancyFacet = ReentrancyGuardFacet(address(diamond));
    }

    function testInitGuardBlocksDirectCall() public {
        vm.expectRevert();
        ReentrancyGuardFacet(address(diamond)).initReentrancyGuard();
    }

    function test_init_leavesPersistentGuardSlotUnused() public view {
        assertEq(vm.load(diamond, REENTRANCY_GUARD_STORAGE), bytes32(0));
    }

    function test_init_cannotRunTwiceThroughDiamond() public {
        ReentrancyGuardFacet facet = ReentrancyGuardFacet(address(diamond));
        vm.expectRevert(); // calling again should fail due to FacetInitVersionAlreadyInitialized via registry
        vm.prank(admin);
        facet.initReentrancyGuard();
    }

    function test_transientGuardBlocksCrossFacetReentrancyAndClearsAfterCall() public {
        TransientGuardFirstFacet first = new TransientGuardFirstFacet();
        TransientGuardSecondFacet second = new TransientGuardSecondFacet();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](2);
        bytes4[] memory firstSelectors = new bytes4[](1);
        firstSelectors[0] = TransientGuardFirstFacet.guardedFirstThenSecond.selector;
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(first), action: IDiamond.FacetCutAction.Add, functionSelectors: firstSelectors
        });
        bytes4[] memory secondSelectors = new bytes4[](1);
        secondSelectors[0] = TransientGuardSecondFacet.guardedSecond.selector;
        cuts[1] = IDiamond.FacetCut({
            facetAddress: address(second), action: IDiamond.FacetCutAction.Add, functionSelectors: secondSelectors
        });

        DiamondArgs memory args = DiamondArgs({owner: admin, init: address(0), initCalldata: ""});
        address guardedDiamond = address(new ProtocolDiamond(cuts, args));

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        TransientGuardFirstFacet(guardedDiamond).guardedFirstThenSecond();

        assertTrue(TransientGuardSecondFacet(guardedDiamond).guardedSecond());
        assertTrue(TransientGuardSecondFacet(guardedDiamond).guardedSecond());
        assertEq(vm.load(guardedDiamond, REENTRANCY_GUARD_STORAGE), bytes32(0));
    }
}
