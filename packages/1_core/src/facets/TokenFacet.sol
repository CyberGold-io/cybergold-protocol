// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {ICygldApprovalCallback} from "../interfaces/ICygldApprovalCallback.sol";
import {ICygldOutflowCallback} from "../interfaces/ICygldOutflowCallback.sol";
import {LibAccountCallbacks} from "../libraries/LibAccountCallbacks.sol";
import {LibAllowanceExposureStorage} from "../libraries/LibAllowanceExposureStorage.sol";
import {LibSupplyCap} from "../libraries/LibSupplyCap.sol";

/// @notice ERC20 facet for the core diamond, mirroring CyberGoldToken behavior while reusing OZ storage/logic.
contract TokenFacet is ERC20Upgradeable, ERC20PermitUpgradeable, PausableUpgradeable, InitContext {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.core.token");

    // Errors
    /// @notice Reverts when mint or burn is not routed as a same-diamond controller call.
    error ControllerOnly();

    /// @notice Initialize ERC20 state. Must be called via the init coordinator.
    /// @param name_ ERC20 token name initialized for the diamond token facet.
    /// @param symbol_ ERC20 token symbol initialized for the diamond token facet.
    function initToken(string calldata name_, string calldata symbol_) external onlyInit {
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
    }

    // --- Mint/Burn controlled by controller ---

    /// @notice Mint CYGLD through the same-diamond controller while unpaused and within the supply cap.
    /// @param to Recipient of the newly minted CYGLD.
    /// @param amount CYGLD base units to mint.
    function mint(address to, uint256 amount) external onlyController whenNotPaused {
        LibSupplyCap.enforceMint(LibAppStorage.appStorage().controller.maxTotalSupply, totalSupply(), amount);
        _mint(to, amount);
    }

    /// @notice Burn CYGLD through the same-diamond controller while unpaused.
    /// @param from Account whose CYGLD is burned.
    /// @param amount CYGLD base units to burn.
    function burn(address from, uint256 amount) external onlyController whenNotPaused {
        _burn(from, amount);
    }

    /// @notice Return the balance conservatively exposed by all current allowances from `owner`.
    /// @dev Allowances are summed even though spenders compete for one balance. The result is capped at the
    ///      current balance, so overlapping permissions deliberately fail closed for solvency accounting.
    /// @param owner Allowance owner whose exposure is queried.
    /// @return exposure Current balance conservatively reachable through allowances.
    function allowanceExposure(address owner) public view returns (uint256 exposure) {
        uint256 balance = balanceOf(owner);
        LibAllowanceExposureStorage.AllowanceSum storage sum =
            LibAllowanceExposureStorage.getLayout().allowanceSums[owner];
        if (sum.high != 0 || sum.low >= balance) return balance;
        return sum.low;
    }

    /// @notice Return the current balance not conservatively exposed by any allowance from `owner`.
    /// @param owner Allowance owner whose unexposed balance is queried.
    /// @return Current balance minus conservative allowance exposure.
    function unallowancedBalanceOf(address owner) external view returns (uint256) {
        return balanceOf(owner) - allowanceExposure(owner);
    }

    /// @dev Apply the diamond pause to supply changes without freezing ordinary holder transfers.
    function _update(address from, address to, uint256 value) internal override {
        // Mint and burn use a zero endpoint. Keeping the guard here covers every current and future
        // supply-changing path in addition to the explicit guards on today's runtime endpoints.
        if (from == address(0) || to == address(0)) _requireNotPaused();

        bool usesCallback;
        if (from != address(0) && from != to && value > 0) {
            usesCallback = LibAccountCallbacks.supportsInterface(from, type(ICygldOutflowCallback).interfaceId);
        }

        super._update(from, to, value);
        if (usesCallback) {
            bytes4 callback = ICygldOutflowCallback.onCygldOutflow.selector;
            LibAccountCallbacks.callAndRequireMagic(
                from,
                callback,
                abi.encodeCall(
                    ICygldOutflowCallback.onCygldOutflow,
                    (_msgSender(), to, value, balanceOf(from), allowanceExposure(from))
                )
            );
        }
    }

    /// @dev Track every approval mutation in one exact aggregate exposure value.
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal override {
        uint256 previousValue = allowance(owner, spender);
        if (previousValue == value) {
            super._approve(owner, spender, value, emitEvent);
            return;
        }

        bool usesCallback = LibAccountCallbacks.supportsInterface(owner, type(ICygldApprovalCallback).interfaceId);
        super._approve(owner, spender, value, emitEvent);

        LibAllowanceExposureStorage.Layout storage l = LibAllowanceExposureStorage.getLayout();
        LibAllowanceExposureStorage.replaceAllowance(l.allowanceSums[owner], previousValue, value);

        if (usesCallback) {
            bytes4 callback = ICygldApprovalCallback.onCygldApprovalChange.selector;
            LibAccountCallbacks.callAndRequireMagic(
                owner,
                callback,
                abi.encodeCall(
                    ICygldApprovalCallback.onCygldApprovalChange,
                    (spender, previousValue, value, balanceOf(owner), allowanceExposure(owner))
                )
            );
        }
    }

    modifier onlyController() {
        _onlyController();
        _;
    }

    /// @dev Validate caller for controller.
    function _onlyController() internal view {
        if (msg.sender != address(this)) revert ControllerOnly();
    }
}
