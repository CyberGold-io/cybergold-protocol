// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockCurvePool is ERC20 {
    using SafeERC20 for IERC20;

    address[2] private _coins;
    uint256 public pricePerLp = 1e18; // underlying per LP (1e18 precision)

    constructor(address coin0, address coin1) ERC20("Mock Curve LP", "mCLP") {
        _coins[0] = coin0;
        _coins[1] = coin1;
    }

    function setPricePerLp(uint256 newPrice) external {
        pricePerLp = newPrice;
    }

    function coins(uint256 index) external view returns (address) {
        require(index < 2, "idx");
        return _coins[index];
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy, address receiver) external returns (uint256) {
        uint256 from = _indexToUint(i);
        uint256 to = _indexToUint(j);
        IERC20(_coins[from]).safeTransferFrom(msg.sender, address(this), dx);
        require(dx >= minDy, "slippage");
        IERC20(_coins[to]).safeTransfer(receiver, dx);
        return dx;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function add_liquidity(uint256[] calldata amounts, uint256 minMint, address receiver) external returns (uint256) {
        require(amounts.length == 2, "len");
        uint256 minted;
        for (uint256 i = 0; i < 2; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            IERC20(_coins[i]).safeTransferFrom(msg.sender, address(this), amount);
            minted += amount;
        }
        require(minted >= minMint, "mint");
        _mint(receiver, minted);
        return minted;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function remove_liquidity_one_coin(uint256 burnAmount, int128 i, uint256 minAmount, address receiver)
        external
        returns (uint256)
    {
        require(burnAmount > 0, "zero");
        _burn(msg.sender, burnAmount);
        uint256 payout = (burnAmount * pricePerLp) / 1e18;
        require(payout >= minAmount, "min");
        IERC20(_coins[_indexToUint(i)]).safeTransfer(receiver, payout);
        return burnAmount;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function calc_withdraw_one_coin(uint256 burnAmount, int128) external view returns (uint256) {
        return (burnAmount * pricePerLp) / 1e18;
    }

    function _indexToUint(int128 value) internal pure returns (uint256) {
        require(value >= 0 && value < 2, "idx");
        // safe: input is bounded between 0 and 1 so it always fits in uint128/uint256
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(uint128(value));
    }
}

contract MockCurveGauge {
    using SafeERC20 for IERC20;

    IERC20 public immutable LP_TOKEN;
    IERC20 public rewardToken;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public pendingRewards;

    constructor(IERC20 lpToken_) {
        LP_TOKEN = lpToken_;
    }

    function setRewardToken(address token) external {
        rewardToken = IERC20(token);
    }

    function seedRewards(address user, uint256 amount) external {
        require(address(rewardToken) != address(0), "reward not set");
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        pendingRewards[user] += amount;
    }

    function deposit(uint256 amount) external {
        LP_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        uint256 current = balanceOf[msg.sender];
        require(current >= amount, "bal");
        balanceOf[msg.sender] = current - amount;
        LP_TOKEN.safeTransfer(msg.sender, amount);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function claim_rewards(address account) external {
        if (address(rewardToken) == address(0)) return;
        uint256 owed = pendingRewards[account];
        if (owed == 0) return;
        pendingRewards[account] = 0;
        rewardToken.safeTransfer(account, owed);
    }
}
