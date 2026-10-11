// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {ReentrancyGuardInitializable} from "diamond-infra/helpers/ReentrancyGuardInitializable.sol";

/// @notice Custody facet: role-gated asset holder for staking flows.
/// @dev Assets are held at the diamond address; roles/pause share OZ storage via AccessControl/Pausable facets.
contract CustodyFacet is
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardInitializable,
    InitContext
{
    using SafeERC20 for IERC20;

    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.custody");
    /// @notice Configured withdrawer role.
    bytes32 public constant WITHDRAWER_ROLE = keccak256("WITHDRAWER_ROLE");

    /// @notice Custody initialization or transfer received a zero account or token address.
    error ZeroAddress();
    /// @notice Reverts when a launch withdrawer appears more than once.
    /// @param withdrawer Duplicate account found in the ordered launch roster.
    error DuplicateWithdrawer(address withdrawer);

    /// @notice Initialize custody roles.
    /// @param withdrawers Accounts allowed to transfer assets out of custody.
    function initCustody(address[] calldata withdrawers) external onlyInit {
        uint256 len = withdrawers.length;
        for (uint256 i; i < len;) {
            address w = withdrawers[i];
            if (w == address(0)) revert ZeroAddress();
            for (uint256 j; j < i; ++j) {
                if (withdrawers[j] == w) revert DuplicateWithdrawer(w);
            }
            _grantRole(WITHDRAWER_ROLE, w);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Custodial transfer to a recipient, callable by authorized withdrawers.
    /// @param token ERC20 token transferred out of custody.
    /// @param to Recipient receiving the custodial transfer.
    /// @param amount Token amount transferred from custody.
    function transferTo(address token, address to, uint256 amount) external whenNotPaused onlyRole(WITHDRAWER_ROLE) {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) return;
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Returns the balance of `token` held by the custody (diamond) address.
    /// @param token ERC20 token checked against custody balance.
    /// @return Balance of the token held by the custody address.
    function custodyBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Return whether the Staking Diamond advertises an ERC-165 interface identifier.
    /// @param iid ERC-165 interface id queried by the view.
    /// @return Whether the ERC-165 interface id is supported.
    function supportsInterface(bytes4 iid) public view override(AccessControlEnumerableUpgradeable) returns (bool) {
        return super.supportsInterface(iid);
    }
}
