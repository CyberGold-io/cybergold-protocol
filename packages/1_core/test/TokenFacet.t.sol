// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {TokenFacet} from "../src/facets/TokenFacet.sol";
import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";
import {LibSupplyCap} from "../src/libraries/LibSupplyCap.sol";

contract TokenFacetHarness is TokenFacet {
    function setMaxTotalSupplyForTest(uint256 maxTotalSupply) external {
        LibAppStorage.appStorage().controller.maxTotalSupply = maxTotalSupply;
    }

    function mintFromController(address to, uint256 amount) external {
        this.mint(to, amount);
    }

    function burnFromController(address from, uint256 amount) external {
        this.burn(from, amount);
    }

    function pauseForTest() external {
        _pause();
    }

    function unpauseForTest() external {
        _unpause();
    }
}

contract TokenFacetTest is Test {
    TokenFacetHarness internal facet;

    address internal user = address(0xBEEF);
    address internal recipient = address(0xABCD);
    address internal secondSpender = address(0xCAFE);

    bytes32 internal constant INIT_CONTEXT_SLOT = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
    bytes32 internal constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    function setUp() public {
        facet = new TokenFacetHarness();
        _enterInitContext();
        facet.initToken("CyberGold", "CYGLD");
        _exitInitContext();
        facet.setMaxTotalSupplyForTest(type(uint256).max);
    }

    function testInitSetsMetadataAndController() public {
        assertEq(facet.name(), "CyberGold");
        assertEq(facet.symbol(), "CYGLD");
        assertEq(facet.decimals(), 18);
        facet.mintFromController(user, 1);
    }

    function testInitTokenCannotReplayAfterTheOuterInitializerCloses() public {
        vm.store(address(facet), INIT_CONTEXT_SLOT, bytes32(uint256(1)));
        vm.expectRevert();
        facet.initToken("Mutated", "MUT");
        vm.store(address(facet), INIT_CONTEXT_SLOT, bytes32(0));
        assertEq(facet.name(), "CyberGold");
        assertEq(facet.symbol(), "CYGLD");
    }

    function testMintBurnOnlyController() public {
        vm.expectRevert(TokenFacet.ControllerOnly.selector);
        facet.mint(user, 1 ether);

        facet.mintFromController(user, 2 ether);
        assertEq(facet.balanceOf(user), 2 ether);
        assertEq(facet.totalSupply(), 2 ether);

        vm.expectRevert(TokenFacet.ControllerOnly.selector);
        facet.burn(user, 1 ether);

        facet.burnFromController(user, 1 ether);
        assertEq(facet.balanceOf(user), 1 ether);
        assertEq(facet.totalSupply(), 1 ether);
    }

    function testTransferAndAllowanceFlow() public {
        facet.mintFromController(user, 5 ether);

        vm.prank(user);
        facet.approve(recipient, 3 ether);
        assertEq(facet.allowance(user, recipient), 3 ether);
        assertEq(facet.allowanceExposure(user), 3 ether);
        assertEq(facet.unallowancedBalanceOf(user), 2 ether);

        vm.prank(recipient);
        assertTrue(facet.transferFrom(user, recipient, 2 ether));
        assertEq(facet.balanceOf(recipient), 2 ether);
        assertEq(facet.balanceOf(user), 3 ether);
        assertEq(facet.allowance(user, recipient), 1 ether);
        assertEq(facet.allowanceExposure(user), 1 ether);

        vm.prank(user);
        assertTrue(facet.transfer(recipient, 1 ether));
        assertEq(facet.balanceOf(recipient), 3 ether);
        assertEq(facet.balanceOf(user), 2 ether);
        assertEq(facet.unallowancedBalanceOf(user), 1 ether);
    }

    function testAggregateAllowanceTracksReplacementNoopAndRemoval() public {
        facet.mintFromController(user, 10 ether);

        vm.startPrank(user);
        facet.approve(recipient, 2 ether);
        facet.approve(secondSpender, 3 ether);
        facet.approve(recipient, 4 ether);
        facet.approve(recipient, 4 ether);
        vm.stopPrank();

        assertEq(facet.allowanceExposure(user), 7 ether);

        vm.prank(user);
        facet.approve(recipient, 0);
        assertEq(facet.allowanceExposure(user), 3 ether);

        vm.prank(user);
        facet.approve(secondSpender, 0);
        assertEq(facet.allowanceExposure(user), 0);
        assertEq(facet.unallowancedBalanceOf(user), 10 ether);
    }

    function testAllowanceExposureUsesExactWideSumAndCapsAtBalance() public {
        facet.mintFromController(user, 10 ether);

        vm.startPrank(user);
        facet.approve(recipient, type(uint256).max);
        facet.approve(secondSpender, type(uint256).max);
        vm.stopPrank();

        assertEq(facet.allowanceExposure(user), 10 ether);
        assertEq(facet.unallowancedBalanceOf(user), 0);

        vm.prank(user);
        facet.approve(recipient, 0);
        assertEq(facet.allowanceExposure(user), 10 ether);

        vm.prank(user);
        facet.approve(secondSpender, 0);
        assertEq(facet.allowanceExposure(user), 0);
        assertEq(facet.unallowancedBalanceOf(user), 10 ether);
    }

    function testPermitUpdatesAggregateAllowance() public {
        uint256 ownerKey = 0xA11CE;
        address owner = vm.addr(ownerKey);
        facet.mintFromController(owner, 5 ether);
        uint256 deadline = block.timestamp + 1 days;
        uint256 value = 2 ether;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                recipient,
                value,
                facet.nonces(owner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", facet.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        facet.permit(owner, recipient, value, deadline, v, r, s);

        assertEq(facet.allowance(owner, recipient), value);
        assertEq(facet.allowanceExposure(owner), value);
    }

    function testInfiniteAllowanceSpendDoesNotReduceAggregate() public {
        facet.mintFromController(user, 10 ether);
        vm.prank(user);
        facet.approve(recipient, type(uint256).max);

        vm.prank(recipient);
        assertTrue(facet.transferFrom(user, recipient, 1 ether));

        assertEq(facet.allowance(user, recipient), type(uint256).max);
        assertEq(facet.allowanceExposure(user), 9 ether);
        assertEq(facet.unallowancedBalanceOf(user), 0);
    }

    function testPauseBlocksControllerMintAndBurnButAllowsTransfers() public {
        facet.mintFromController(user, 2 ether);
        facet.pauseForTest();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        facet.mintFromController(recipient, 1 ether);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        facet.burnFromController(user, 1 ether);

        vm.prank(user);
        assertTrue(facet.transfer(recipient, 1 ether));
        assertEq(facet.balanceOf(user), 1 ether);
        assertEq(facet.balanceOf(recipient), 1 ether);

        facet.unpauseForTest();
        facet.burnFromController(user, 1 ether);
        assertEq(facet.balanceOf(user), 0);
    }

    function testMintRevertsAboveMaxTotalSupply() public {
        facet.setMaxTotalSupplyForTest(3 ether);

        facet.mintFromController(user, 2 ether);

        vm.expectRevert(abi.encodeWithSelector(LibSupplyCap.MaxTotalSupplyExceeded.selector, 2 ether, 2 ether, 3 ether));
        facet.mintFromController(user, 2 ether);
    }

    function _enterInitContext() internal {
        vm.store(address(facet), INIT_CONTEXT_SLOT, bytes32(uint256(1)));
        vm.store(address(facet), INITIALIZABLE_STORAGE, bytes32(uint256(1) << 64));
    }

    function _exitInitContext() internal {
        vm.store(address(facet), INIT_CONTEXT_SLOT, bytes32(0));
        vm.store(address(facet), INITIALIZABLE_STORAGE, bytes32(uint256(1)));
    }
}
