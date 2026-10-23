// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

contract MockCygldBasketController {
    using SafeERC20 for IERC20;

    // Test mock keeps the production-facing `cygld()` getter shape.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IERC20 public immutable cygld;
    address[] private _basketAssets;
    uint256[] private _basketWeightsPpm;
    uint256[] private _basketCygldPerUnitFp18;
    uint256 public redemptionFeePpm;

    constructor(
        address cygld_,
        address[] memory assets_,
        uint256[] memory weightsPpm_,
        uint256[] memory cygldPerUnitFp18_
    ) {
        require(assets_.length == weightsPpm_.length && assets_.length == cygldPerUnitFp18_.length, "length");
        cygld = IERC20(cygld_);
        _basketAssets = assets_;
        _basketWeightsPpm = weightsPpm_;
        _basketCygldPerUnitFp18 = cygldPerUnitFp18_;
    }

    function setRedemptionFeePpm(uint256 feePpm) external {
        redemptionFeePpm = feePpm;
    }

    function setBasketCygldPerUnitFp18(uint256 index, uint256 conversion) external {
        _basketCygldPerUnitFp18[index] = conversion;
    }

    function basketAssets() external view returns (address[] memory) {
        return _basketAssets;
    }

    function basketCygldPerUnitFp18() external view returns (uint256[] memory) {
        return _basketCygldPerUnitFp18;
    }

    function redeem(uint256 grossCygldIn) external returns (ICoreRedemption.RedemptionQuote memory result) {
        result.grossCygldIn = grossCygldIn;
        result.protocolFeeCygld = (grossCygldIn * redemptionFeePpm) / 1_000_000;
        result.netCygldIn = grossCygldIn - result.protocolFeeCygld;
        cygld.safeTransferFrom(msg.sender, address(this), grossCygldIn);

        result.outputs = new ICoreRedemption.TokenAmount[](_basketAssets.length);
        for (uint256 i = 0; i < _basketAssets.length; ++i) {
            uint256 cygldValue = (result.netCygldIn * _basketWeightsPpm[i]) / 1_000_000;
            uint256 amountOut = (cygldValue * 1e18) / _basketCygldPerUnitFp18[i];
            result.outputs[i] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: _basketAssets[i], id: 0, amount: amountOut
            });
            IERC20(_basketAssets[i]).safeTransfer(msg.sender, amountOut);
        }
    }
}
