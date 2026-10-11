// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {InitContext} from "diamond-infra/helpers/InitContext.sol";

import {GovernorTestBase} from "../helpers/GovernorTestBase.sol";
import {TokenFacet} from "../../src/facets/TokenFacet.sol";

contract TokenFacetPauseHarness is TokenFacet {
    function mintForTest(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnForTest(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function pauseForTest() external {
        _pause();
    }
}

contract TokenFacetTest is GovernorTestBase {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    uint256 private constant HOLDER_PK = 0xA11CE;
    uint256 private constant DELEGATE_PK = 0xB0B;

    function test_initializer_requires_init_context() public {
        TokenFacet token = new TokenFacet();

        vm.expectRevert(abi.encodeWithSelector(InitContext.FacetInitCallerNotSelf.selector, address(this)));
        token.initToken("CyberGold Governance", "CYGOV", address(0), 0, 0);
    }

    function test_init_sets_metadata_and_initial_supply() public {
        address holder = vm.addr(HOLDER_PK);
        TokenFacet token = _newInitialized(holder, 1_000 ether);

        assertEq(token.name(), "CyberGold Governance");
        assertEq(token.symbol(), "CYGOV");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000 ether);
        assertEq(token.balanceOf(holder), 1_000 ether);
        assertEq(token.delegates(holder), holder);
        assertEq(token.getVotes(holder), 1_000 ether);
    }

    function test_init_allows_zero_supply() public {
        TokenFacet token = _newInitialized(address(0), 0);

        assertEq(token.name(), "CyberGold Governance");
        assertEq(token.symbol(), "CYGOV");
        assertEq(token.totalSupply(), 0);
    }

    function test_init_reverts_nonzero_supply_with_zero_holder() public {
        TokenFacet token = new TokenFacet();
        _enterInitContext(address(token));

        vm.expectRevert(TokenFacet.InitialHolderRequired.selector);
        token.initToken("CyberGold Governance", "CYGOV", address(0), 1, 0);
    }

    function test_transfer_approve_and_transferFrom() public {
        address holder = vm.addr(HOLDER_PK);
        address spender = address(0xCAFE);
        address recipient = address(0xBEEF);
        TokenFacet token = _newInitialized(holder, 100 ether);

        vm.prank(holder);
        assertTrue(token.transfer(recipient, 10 ether));
        assertEq(token.balanceOf(holder), 90 ether);
        assertEq(token.balanceOf(recipient), 10 ether);

        vm.prank(holder);
        assertTrue(token.approve(spender, 20 ether));
        assertEq(token.allowance(holder, spender), 20 ether);

        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, 15 ether));
        assertEq(token.allowance(holder, spender), 5 ether);
        assertEq(token.balanceOf(recipient), 25 ether);
    }

    function test_pause_blocksMintAndBurnButAllowsTransfers() public {
        address holder = vm.addr(HOLDER_PK);
        address recipient = address(0xBEEF);
        TokenFacetPauseHarness token = new TokenFacetPauseHarness();
        token.mintForTest(holder, 10 ether);
        token.pauseForTest();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        token.mintForTest(recipient, 1 ether);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        token.burnForTest(holder, 1 ether);

        vm.prank(holder);
        assertTrue(token.transfer(recipient, 1 ether));
        assertEq(token.balanceOf(holder), 9 ether);
        assertEq(token.balanceOf(recipient), 1 ether);
    }

    function test_permit_sets_allowance_and_consumes_nonce() public {
        address holder = vm.addr(HOLDER_PK);
        address spender = address(0xCAFE);
        TokenFacet token = _newInitialized(holder, 100 ether);
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = token.nonces(holder);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, 12 ether, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_PK, digest);

        token.permit(holder, spender, 12 ether, deadline, v, r, s);

        assertEq(token.allowance(holder, spender), 12 ether);
        assertEq(token.nonces(holder), nonce + 1);
    }

    function test_delegate_creates_checkpoints_and_transfer_moves_votes() public {
        address holder = vm.addr(HOLDER_PK);
        address recipient = vm.addr(DELEGATE_PK);
        TokenFacet token = _newInitialized(holder, 100 ether);

        vm.prank(holder);
        token.delegate(holder);
        assertEq(token.delegates(holder), holder);
        assertEq(token.getVotes(holder), 100 ether);

        vm.prank(holder);
        assertTrue(token.transfer(recipient, 30 ether));
        assertEq(token.getVotes(holder), 70 ether);
        assertEq(token.getVotes(recipient), 0);

        vm.prank(recipient);
        token.delegate(recipient);
        assertEq(token.getVotes(recipient), 30 ether);
    }

    function test_delegateBySig_works() public {
        address holder = vm.addr(HOLDER_PK);
        address delegatee = address(0xD1E6A7E);
        TokenFacet token = _newInitialized(holder, 100 ether);
        uint256 expiry = block.timestamp + 1 days;
        uint256 nonce = token.nonces(holder);

        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_PK, digest);

        token.delegateBySig(delegatee, nonce, expiry, v, r, s);

        assertEq(token.delegates(holder), delegatee);
        assertEq(token.getVotes(delegatee), 100 ether);
        assertEq(token.nonces(holder), nonce + 1);
    }

    function test_governanceDiamondCannotDelegateTreasuryVotes() public {
        address holder = vm.addr(HOLDER_PK);
        address delegatee = address(0xD1E6A7E);
        TokenFacet token = new TokenFacet();
        _enterInitContext(address(token));
        token.initToken("CyberGold Governance", "CYGOV", holder, 100 ether, 100 ether);
        _exitInitContext(address(token));

        vm.expectRevert(abi.encodeWithSelector(TokenFacet.GovernanceTreasuryDelegationForbidden.selector, delegatee));
        vm.prank(address(token));
        token.delegate(delegatee);

        assertEq(token.delegates(address(token)), address(0));
        assertEq(token.getVotes(delegatee), 0);
    }

    function test_governanceDiamondCanClearDelegationToZero() public {
        TokenFacet token = _newInitialized(vm.addr(HOLDER_PK), 100 ether);

        vm.prank(address(token));
        token.delegate(address(0));

        assertEq(token.delegates(address(token)), address(0));
    }

    function test_externalHolderCanDelegateToGovernanceDiamond() public {
        address holder = vm.addr(HOLDER_PK);
        TokenFacet token = _newInitialized(holder, 100 ether);

        vm.prank(holder);
        token.delegate(address(token));

        assertEq(token.delegates(holder), address(token));
        assertEq(token.getVotes(address(token)), 100 ether);
    }

    function test_past_votes_and_total_supply_use_timestamp_clock() public {
        address holder = vm.addr(HOLDER_PK);
        TokenFacet token = _newInitialized(holder, 100 ether);

        vm.prank(holder);
        token.delegate(holder);
        vm.warp(block.timestamp + 1);
        uint256 snapshotTimepoint = block.timestamp - 1;

        assertEq(token.clock(), uint48(block.timestamp));
        assertEq(token.CLOCK_MODE(), "mode=timestamp");
        assertEq(token.getPastVotes(holder, snapshotTimepoint), 100 ether);
        assertEq(token.getPastTotalSupply(snapshotTimepoint), 100 ether);
        assertEq(token.numCheckpoints(holder), 1);
        assertEq(token.checkpoints(holder, 0)._value, 100 ether);
    }

    function test_future_lookup_reverts() public {
        address holder = vm.addr(HOLDER_PK);
        TokenFacet token = _newInitialized(holder, 100 ether);

        vm.expectRevert();
        token.getPastVotes(holder, block.timestamp);

        vm.expectRevert();
        token.getPastTotalSupply(block.timestamp);
    }

    function test_initTokenCannotReplayAfterTheOuterInitializerCloses() public {
        address holder = vm.addr(HOLDER_PK);
        TokenFacet token = _newInitialized(holder, 100 ether);
        vm.store(address(token), INIT_CONTEXT_SLOT, bytes32(uint256(1)));

        vm.expectRevert();
        token.initToken("CyberGold Governance", "CYGOV", holder, 0, 0);

        vm.store(address(token), INIT_CONTEXT_SLOT, bytes32(0));
        assertEq(token.name(), "CyberGold Governance");
        assertEq(token.symbol(), "CYGOV");
        assertEq(token.totalSupply(), 100 ether);
    }

    function _newInitialized(address holder, uint256 supply) private returns (TokenFacet token) {
        token = new TokenFacet();
        _enterInitContext(address(token));
        token.initToken("CyberGold Governance", "CYGOV", holder, supply, 0);
        _exitInitContext(address(token));
    }

    function test_init_mints_distinct_holder_and_treasury_supplies() public {
        address holder = vm.addr(HOLDER_PK);
        TokenFacet token = new TokenFacet();
        _enterInitContext(address(token));
        token.initToken("CyberGold Governance", "CYGOV", holder, 1_000_000 ether, 1_000_000 ether);
        _exitInitContext(address(token));

        assertEq(token.balanceOf(holder), 1_000_000 ether);
        assertEq(token.balanceOf(address(token)), 1_000_000 ether);
        assertEq(token.totalSupply(), 2_000_000 ether);
    }
}
