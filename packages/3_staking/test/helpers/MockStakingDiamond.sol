// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Test-only Staking Diamond authority and custody surface used to isolate Sleeve behavior.
contract MockStakingDiamond is AccessControlEnumerable {
    using SafeERC20 for IERC20;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    mapping(address account => bool authorized) internal _pausers;
    mapping(address account => bool authorized) internal _unpausers;
    mapping(address account => bool authorized) internal _sleeveCallers;
    uint8 internal _responseMode;

    address public safeWallet;

    error UnauthorizedSleeve(address caller);
    error ZeroAddress();

    constructor(address admin, address safeWallet_) {
        if (admin == address(0) || safeWallet_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        safeWallet = safeWallet_;
    }

    function upgraderRole() external pure returns (bytes32) {
        return UPGRADER_ROLE;
    }

    function hasRole(bytes32 role, address account)
        public
        view
        override(AccessControl, IAccessControl)
        returns (bool)
    {
        return _respond(super.hasRole(role, account));
    }

    function setSleeveCaller(address sleeve, bool authorized) external {
        _sleeveCallers[sleeve] = authorized;
    }

    function setCanPause(address account, bool authorized) external {
        _pausers[account] = authorized;
    }

    function setCanUnpause(address account, bool authorized) external {
        _unpausers[account] = authorized;
    }

    function setResponseMode(uint8 mode) external {
        _responseMode = mode;
    }

    function canPause(address account) external view returns (bool) {
        return _respond(_pausers[account]);
    }

    function canUnpause(address account) external view returns (bool) {
        return _respond(_unpausers[account]);
    }

    function transferTo(address token, address to, uint256 amount) external {
        if (!_sleeveCallers[msg.sender]) revert UnauthorizedSleeve(msg.sender);
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    function _respond(bool authorized) internal view returns (bool) {
        if (_responseMode == 1) revert();
        if (_responseMode == 2) {
            assembly {
                return(0, 0)
            }
        }
        if (_responseMode == 3) {
            assembly {
                return(0, 1)
            }
        }
        if (_responseMode == 4) {
            assembly {
                mstore(0, authorized)
                mstore(0x20, 0)
                return(0, 0x40)
            }
        }
        if (_responseMode == 5) {
            assembly {
                mstore(0, 2)
                return(0, 0x20)
            }
        }
        return authorized;
    }
}
