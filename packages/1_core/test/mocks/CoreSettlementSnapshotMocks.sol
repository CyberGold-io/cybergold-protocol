// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {LibAppStorage} from "../../src/diamond/LibAppStorage.sol";
import {RedemptionFacet} from "../../src/facets/RedemptionFacet.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";

interface ITotalSupplyView {
    function totalSupply() external view returns (uint256);
}

/// @dev First basket leg that mutates a later reserve and attempts a nested redemption during payout.
contract LaterReserveMutationToken is MockERC20 {
    address public core;
    MockERC20 public laterReserveToken;
    uint256 public donation;
    bool public armed;
    bool public callbackAttempted;
    bool public reentrantCallSucceeded;
    bytes4 public callbackRevertSelector;

    constructor() MockERC20("Callback Asset", "CALLBACK", 18) {}

    function arm(address core_, MockERC20 laterReserveToken_, uint256 donation_) external {
        core = core_;
        laterReserveToken = laterReserveToken_;
        donation = donation_;
        armed = true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool transferred = super.transfer(to, value);
        if (!armed || msg.sender != core) return transferred;

        armed = false;
        callbackAttempted = true;
        laterReserveToken.mint(core, donation);

        (bool success, bytes memory returnData) = core.call(abi.encodeWithSignature("redeem(uint256)", 1));
        reentrantCallSucceeded = success;
        if (!success && returnData.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(returnData, 0x20))
            }
            callbackRevertSelector = selector;
        }
        return transferred;
    }
}

/// @dev Reverts if Core first observes its reserve balance after the configured supply has changed.
contract PreBurnBalanceObservationToken is MockERC20 {
    error ReserveObservedAfterBurn(uint256 expectedSupply, uint256 actualSupply);

    address public immutable CORE;
    uint256 public immutable EXPECTED_SUPPLY;

    constructor(address core_, uint256 expectedSupply_) MockERC20("Pre-burn Observation Asset", "PREBURN", 18) {
        CORE = core_;
        EXPECTED_SUPPLY = expectedSupply_;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (account == CORE) {
            uint256 actualSupply = ITotalSupplyView(CORE).totalSupply();
            if (actualSupply != EXPECTED_SUPPLY) {
                revert ReserveObservedAfterBurn(EXPECTED_SUPPLY, actualSupply);
            }
        }
        return super.balanceOf(account);
    }
}

/// @dev Minimal direct RedemptionFacet harness used only to make pre-burn observation externally visible.
contract PreBurnRedemptionHarness is RedemptionFacet {
    error HarnessControllerOnly();

    uint256 public totalSupply;

    function configure(address treasury, address asset, uint256 supply) external {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        cs.treasury = treasury;
        cs.redemptionFeePpm = 0;
        cs.basketAssets.push(asset);
        cs.basketTargetsPpm.push(1_000_000);
        cs.basketGoldRefGramsFp18.push(1e18);
        cs.basketCygldPerUnitFp18.push(1e18);
        totalSupply = supply;
    }

    function burn(address, uint256 amount) external {
        if (msg.sender != address(this)) revert HarnessControllerOnly();
        totalSupply -= amount;
    }

    function mint(address, uint256 amount) external {
        if (msg.sender != address(this)) revert HarnessControllerOnly();
        totalSupply += amount;
    }
}
