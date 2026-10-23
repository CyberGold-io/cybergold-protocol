// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LibAppStorage} from "../../src/diamond/LibAppStorage.sol";
import {ControllerBase} from "../../src/facets/ControllerBase.sol";
import {IssuanceFacet} from "../../src/facets/IssuanceFacet.sol";
import {PreviewFacet} from "../../src/facets/PreviewFacet.sol";
import {RebalanceFacet} from "../../src/facets/RebalanceFacet.sol";
import {RedemptionFacet} from "../../src/facets/RedemptionFacet.sol";
import {ICoreRedemption} from "../../src/interfaces/ICoreRedemption.sol";
import {LibReserve} from "../../src/libraries/LibReserve.sol";
import {LibReserveLifecycle} from "../../src/libraries/LibReserveLifecycle.sol";

contract BasketSetHarness is ControllerBase {
    function setCygldRef(uint256 cygldRefGramsFp18) external {
        LibAppStorage.appStorage().controller.cygldRefGramsFp18 = cygldRefGramsFp18;
    }

    function setBasketExternal(address[] memory assets, uint256[] memory weights, uint256[] memory goldRefs) external {
        _setInitialBasket(LibAppStorage.appStorage().controller, assets, weights, goldRefs);
    }

    function computeIssuanceExternal(uint256 grossCygldOut) external view returns (uint256[] memory) {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        if (cs.basketAssets.length == 0) revert BasketNotConfigured();
        IssueContext memory context;
        context.orderedBasketAssets = cs.basketAssets;
        context.targetsPpm = cs.basketTargetsPpm;
        context.cygldPerUnitFp18 = cs.basketCygldPerUnitFp18;
        return _computeIssuanceAmounts(context, grossCygldOut);
    }

    function computeRedemptionExternal(uint256 netCygldIn, uint256 supply, address reserve)
        external
        view
        returns (uint256[] memory)
    {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        if (cs.basketAssets.length == 0) revert BasketNotConfigured();
        netCygldIn;
        supply;
        reserve;
        return new uint256[](cs.basketAssets.length);
    }
}

contract BranchIssuanceHarness is IssuanceFacet {
    function setTreasury(address treasury) external {
        LibAppStorage.appStorage().controller.treasury = treasury;
    }
}

contract BranchRedemptionHarness is RedemptionFacet {
    uint256 public totalSupply;

    function setTreasury(address treasury) external {
        LibAppStorage.appStorage().controller.treasury = treasury;
    }

    function setTotalSupply(uint256 value) external {
        totalSupply = value;
    }

    function burn(address, uint256 amount) external {
        totalSupply -= amount;
    }

    function mint(address, uint256 amount) external {
        totalSupply += amount;
    }
}

contract BranchPreviewHarness is PreviewFacet {
    uint256 public totalSupply;

    function setTreasury(address treasury) external {
        LibAppStorage.appStorage().controller.treasury = treasury;
    }

    function setTotalSupply(uint256 value) external {
        totalSupply = value;
    }

    function setMaxTotalSupply(uint256 maxTotalSupply) external {
        LibAppStorage.appStorage().controller.maxTotalSupply = maxTotalSupply;
    }

    function setRedemptionFeePpm(uint256 redemptionFeePpm) external {
        LibAppStorage.appStorage().controller.redemptionFeePpm = redemptionFeePpm;
    }

    function setBasketManual(address[] memory assets, uint256[] memory weights, uint256[] memory conversions) external {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        delete cs.basketAssets;
        delete cs.basketTargetsPpm;
        delete cs.basketCygldPerUnitFp18;
        for (uint256 i; i < assets.length; ++i) {
            cs.basketAssets.push(assets[i]);
            cs.basketTargetsPpm.push(weights[i]);
            cs.basketCygldPerUnitFp18.push(conversions[i]);
            LibReserveLifecycle.initializeActive(assets[i]);
        }
    }

    function calculateRedeemExactInExternal(uint256 supply, uint256 grossCygldIn) external pure {
        MixedRedemptionContext memory context;
        context.config.supply = supply;
        _calculateMixedRedeemExactIn(context, grossCygldIn);
    }

    function solveRedeemExactOutExternal(uint256 basketLength, uint256[] calldata minAmountsOut) external pure {
        MixedRedemptionConfig memory config;
        config.orderedBasketAssets = new address[](basketLength);
        ICoreRedemption.TokenMinimum[] memory minimums = new ICoreRedemption.TokenMinimum[](minAmountsOut.length);
        _validateMixedRedemptionDescriptors(config, minimums);
    }
}

contract BranchRebalanceHarness is RebalanceFacet {
    function setBasketManual(address[] memory assets, uint256[] memory weights, uint256[] memory conversions) external {
        LibAppStorage.ControllerStorage storage cs = LibAppStorage.appStorage().controller;
        delete cs.basketAssets;
        delete cs.basketTargetsPpm;
        delete cs.basketCygldPerUnitFp18;
        for (uint256 i; i < assets.length; ++i) {
            cs.basketAssets.push(assets[i]);
            cs.basketTargetsPpm.push(weights[i]);
            cs.basketCygldPerUnitFp18.push(conversions[i]);
            LibReserveLifecycle.initializeActive(assets[i]);
        }
    }

    function executeExternal(address assetIn, address assetOut, uint256 amountIn, uint256 amountOut) external {
        LibReserveLifecycle.initializeActive(assetIn);
        LibReserveLifecycle.initializeActive(assetOut);
        RebalanceExecution memory exec;
        exec.reserveAddr = address(this);
        exec.assetIn = assetIn;
        exec.assetOut = assetOut;
        exec.amountIn = amountIn;
        exec.amountOut = amountOut;
        exec.preDeviations = new Deviation[](0);
        _executeRebalanceSwap(LibAppStorage.appStorage().controller, exec);
    }
}

contract ReserveBranchHarness {
    function initialize(address token) external {
        LibReserveLifecycle.initializeActive(token);
    }

    function transferOutExternal(address token, address to, uint256 amount) external {
        LibReserve.transferOut(token, to, amount);
    }
}

contract BranchERC20 is IERC20 {
    string public name = "Branch Token";
    string public symbol = "BRANCH";
    uint8 public decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) internal balances;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint8 public mode;
    address public watched;
    uint256 public delta;
    bool public toggled;

    function setMode(uint8 mode_, address watched_, uint256 delta_) external {
        mode = mode_;
        watched = watched_;
        delta = delta_;
    }

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function balanceOf(address account) external view override returns (uint256) {
        uint256 bal = balances[account];
        if (toggled && account == watched) {
            if (mode == 1) {
                return bal > delta ? bal - delta : 0;
            }
            if (mode == 3) {
                return bal + delta;
            }
        }
        return bal;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        if (mode == 5 && msg.sender == watched) {
            require(balances[msg.sender] >= amount, "balance");
            balances[msg.sender] -= amount;
            balances[to] += amount - 1;
            totalSupply -= 1;
            emit Transfer(msg.sender, to, amount - 1);
            return true;
        }
        if (mode == 6 && msg.sender == watched) return true;
        uint256 moved = amount;
        if (mode == 4 && msg.sender == watched) {
            moved = amount - 1;
        }
        _transfer(msg.sender, to, moved);
        if (mode == 3 && msg.sender == watched) {
            toggled = true;
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        uint256 moved = amount;
        if (mode == 2 && to == watched) {
            moved = amount - 1;
        }
        _transfer(from, to, moved);
        if (mode == 1 && to == watched) {
            toggled = true;
        }
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balances[from] >= amount, "balance");
        balances[from] -= amount;
        balances[to] += amount;
        emit Transfer(from, to, amount);
    }
}
