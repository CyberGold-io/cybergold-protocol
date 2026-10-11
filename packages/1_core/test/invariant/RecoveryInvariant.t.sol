// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {RecoveryShareFacet} from "../../src/facets/RecoveryShareFacet.sol";
import {LibRecoveryStorage} from "../../src/libraries/LibRecoveryStorage.sol";

contract InvariantRecoveryShareHarness is RecoveryShareFacet {
    function seedPool(address asset) external {
        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
        pool.impaired = true;
    }

    function issueFromController(address recipient, address asset, uint256 amount) external {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        assets[0] = asset;
        amounts[0] = amount;
        this.issueRecoveryShares(recipient, assets, amounts);
    }

    function burnFromController(address account, address asset, uint256 amount) external {
        this.burnRecoveryShares(account, asset, amount);
    }
}

contract RecoveryShareInvariantHandler is Test, ERC1155Holder {
    InvariantRecoveryShareHarness public immutable share;
    address public immutable asset;
    address public immutable sink;
    uint256 public immutable initialTotalShares;
    uint256 public coreAttachedShares;
    uint256 public cumulativeBurned;

    constructor(InvariantRecoveryShareHarness share_, address asset_, uint256 totalShares_) {
        share = share_;
        asset = asset_;
        sink = address(0xCAFE);
        initialTotalShares = totalShares_;
        coreAttachedShares = totalShares_;
    }

    function detach(uint256 seed) external {
        if (coreAttachedShares == 0) return;
        uint256 amount = bound(seed, 1, coreAttachedShares);
        coreAttachedShares -= amount;
        share.issueFromController(address(this), asset, amount);
    }

    function transfer(uint256 seed) external {
        uint256 id = uint256(uint160(asset));
        uint256 balance = share.balanceOf(address(this), id);
        if (balance == 0) return;
        uint256 amount = bound(seed, 1, balance);
        share.safeTransferFrom(address(this), sink, id, amount, "");
    }

    function burnHolder(uint256 seed) external {
        uint256 id = uint256(uint160(asset));
        uint256 balance = share.balanceOf(address(this), id);
        if (balance == 0) return;
        uint256 amount = bound(seed, 1, balance);
        share.burnFromController(address(this), asset, amount);
        cumulativeBurned += amount;
    }

    function burnSink(uint256 seed) external {
        uint256 id = uint256(uint160(asset));
        uint256 balance = share.balanceOf(sink, id);
        if (balance == 0) return;
        uint256 amount = bound(seed, 1, balance);
        share.burnFromController(sink, asset, amount);
        cumulativeBurned += amount;
    }
}

contract RecoveryShareInvariantTest is StdInvariant, Test {
    InvariantRecoveryShareHarness internal share;
    RecoveryShareInvariantHandler internal handler;
    address internal constant ASSET = address(0x1001);
    uint256 internal constant INITIAL_TOTAL = 1_000_000 ether;

    function setUp() public {
        share = new InvariantRecoveryShareHarness();
        share.seedPool(ASSET);
        handler = new RecoveryShareInvariantHandler(share, ASSET, INITIAL_TOTAL);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.detach.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.burnHolder.selector;
        selectors[3] = handler.burnSink.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantCorePlusExternalPlusBurnedEqualsInitialPoolShares() public view {
        uint256 supply = share.totalSupply(uint256(uint160(ASSET)));
        assertEq(handler.coreAttachedShares() + supply + handler.cumulativeBurned(), INITIAL_TOTAL);
    }

    function invariantExternalSupplyEqualsAllHolderBalances() public view {
        uint256 id = uint256(uint160(ASSET));
        uint256 balances = share.balanceOf(address(handler), id) + share.balanceOf(handler.sink(), id);
        assertEq(share.totalSupply(id), balances);
    }
}
