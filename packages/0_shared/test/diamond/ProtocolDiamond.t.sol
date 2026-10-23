// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {EtherNotAccepted} from "../../src/diamond/ProtocolDiamond.sol";
import {DeploymentHelper} from "../../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../../src/deploy/DeploymentTypes.sol";

contract ProtocolDiamondShellTest is Test {
    address internal admin = address(0xA11CE);
    address internal diamond;

    function setUp() public {
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = admin;
        cfg.includePause = false;
        cfg.includeReentrancy = false;
        DeploymentTypes.DeployArtifacts memory art = DeploymentHelper.deploy(cfg);
        diamond = address(art.diamond);
    }

    function test_receiveRejectsNativeEth() public {
        vm.deal(address(this), 1 ether);

        (bool ok, bytes memory err) = payable(diamond).call{value: 1 wei}("");

        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(EtherNotAccepted.selector));
        assertEq(diamond.balance, 0);
    }

    function test_fallbackRejectsValueEvenForKnownSelector() public {
        vm.deal(address(this), 1 ether);
        bytes memory callData = abi.encodeWithSelector(IAccessControl.hasRole.selector, bytes32(0), admin);

        (bool ok,) = diamond.call{value: 1 wei}(callData);

        assertFalse(ok);
        assertEq(diamond.balance, 0);
    }

    function test_fallbackRoutesKnownSelectorWithoutValue() public view {
        (bool ok, bytes memory result) = diamond.staticcall(
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(IAccessControl).interfaceId)
        );

        assertTrue(ok);
        assertTrue(abi.decode(result, (bool)));
    }
}
