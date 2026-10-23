// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";

import {DiamondArgs} from "diamond-1/Diamond.sol";
import {StakingDiamond} from "../src/diamond/StakingDiamond.sol";
import {AppStorageLayoutFacet} from "./facets/helpers/AppStorageLayoutFacet.sol";
import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";

contract AppStorageLayoutTest is Test {
    address internal admin = address(0xA11CE);

    StakingDiamond internal diamond;
    AppStorageLayoutFacet internal implementationFacet;

    function setUp() public {
        implementationFacet = new AppStorageLayoutFacet();

        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(implementationFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: layoutSelectors()
        });

        DiamondArgs memory args;
        args.owner = admin;

        diamond = new StakingDiamond(cut, args);
    }

    function testAppStorageSlotsAreAnchored() public {
        bytes32 base = keccak256("cybergold.staking.app.storage");
        assertEq(LibAppStorage.appStoragePosition(), base);

        address cygld = address(0x1111);
        uint256 feePpm = 555_555;
        uint256 queueHead = 42;
        AppStorageLayoutFacet diamondLayoutFacet = AppStorageLayoutFacet(address(diamond));
        diamondLayoutFacet.setSentinels(cygld, feePpm, queueHead);

        assertTrue(diamondLayoutFacet.vaultHealth());
        assertEq(diamondLayoutFacet.queueHeadId(), queueHead);
        assertEq(diamondLayoutFacet.fundManagerCygld(), cygld);
        assertEq(diamondLayoutFacet.fundManagerPerformanceFee(), feePpm);
    }

    function layoutSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = AppStorageLayoutFacet.setSentinels.selector;
        selectors[1] = AppStorageLayoutFacet.vaultHealth.selector;
        selectors[2] = AppStorageLayoutFacet.queueHeadId.selector;
        selectors[3] = AppStorageLayoutFacet.fundManagerCygld.selector;
        selectors[4] = AppStorageLayoutFacet.fundManagerPerformanceFee.selector;
    }
}
