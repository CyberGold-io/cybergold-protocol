// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardInitializable} from "diamond-infra/helpers/ReentrancyGuardInitializable.sol";
import {IDiamondEmergencyAuthority} from "diamond-infra/interfaces/IDiamondEmergencyAuthority.sol";

import {ICyberGoldStaking} from "../interfaces/ICyberGoldStaking.sol";
import {LibStakingDiamondAuthority} from "../libraries/LibStakingDiamondAuthority.sol";
import {ISleeve} from "./ISleeve.sol";

/// @notice Shared scaffolding for sleeves so they can focus on venue-specific logic.
abstract contract SleeveBase is
    Initializable,
    PausableUpgradeable,
    ReentrancyGuardInitializable,
    UUPSUpgradeable,
    ISleeve
{
    using SafeERC20 for IERC20;

    /// @notice ERC-20 asset in which principal, profit, and sleeve value are denominated.
    IERC20 public underlying;
    /// @notice Staking Diamond that operates, controls, and receives assets from this sleeve.
    address public override stakingDiamond;

    uint256 internal _principal;
    /// @notice Maximum tracked principal; zero means uncapped.
    uint256 public principalCap; // 0 = uncapped
    /// @notice Whether new allocations are allowed; unwinds remain available when false.
    bool public operational;

    /// @notice An allocation would raise tracked principal above the configured nonzero cap.
    /// @param cap Maximum sleeve deposit or exposure cap.
    /// @param newPrincipal Candidate sleeve principal after the requested allocation.
    error PrincipalCapExceeded(uint256 cap, uint256 newPrincipal);
    /// @notice A proposed cap is nonzero and lower than principal already deployed.
    /// @param currentPrincipal Current sleeve principal before applying the cap update.
    /// @param newCap Replacement principal cap for the sleeve.
    error PrincipalCapTooLow(uint256 currentPrincipal, uint256 newCap);
    /// @notice A new allocation was attempted while the sleeve was marked non-operational.
    error SleeveNotOperational();
    /// @notice The Staking diamond emergency authority rejected a caller.
    /// @param account Caller rejected for a Sleeve pause or unpause operation.
    error EmergencyAuthorityUnauthorizedAccount(address account);
    /// @notice The configured Staking Diamond rejected an administrative or upgrade caller.
    /// @param account Caller rejected by the Staking Diamond role authority.
    /// @param neededRole Staking Diamond role required by the operation.
    error StakingDiamondAuthorityUnauthorizedAccount(address account, bytes32 neededRole);
    /// @notice A candidate does not expose the required canonical Staking Diamond authority surface.
    /// @param candidate Address rejected during Sleeve initialization.
    error InvalidStakingDiamond(address candidate);

    /// @notice Emitted when governance changes or disables the principal cap.
    /// @param cap Maximum sleeve deposit or exposure cap.
    event PrincipalCapUpdated(uint256 cap);
    /// @notice Emitted when governance enables or disables new allocations.
    /// @param operational Whether new sleeve allocations are enabled.
    event OperationalStatusUpdated(bool operational);

    /// @dev Disable implementation initializers for sleeve implementations.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Internal committed-launch helper for exact operational and local-pause state.
    /// @param stakingDiamond_ Staking Diamond that operates and controls the sleeve.
    /// @param asset_ Underlying asset token accepted by the sleeve.
    /// @param principalCap_ Initial maximum tracked principal; zero means uncapped.
    /// @param operational_ Whether new allocations are enabled immediately after launch.
    /// @param paused_ Whether the Sleeve starts in its independent local paused state.
    // forge-lint: disable-next-line(mixed-case-function)
    function __SleeveBase_initLaunch(
        address stakingDiamond_,
        address asset_,
        uint256 principalCap_,
        bool operational_,
        bool paused_
    ) internal onlyInitializing {
        if (stakingDiamond_ == address(0) || asset_ == address(0)) revert ZeroAddress();
        _validateStakingDiamond(stakingDiamond_);

        __Pausable_init();
        __ReentrancyGuard_init();

        underlying = IERC20(asset_);
        stakingDiamond = stakingDiamond_;
        principalCap = principalCap_;
        operational = operational_;

        if (paused_) _pause();

        if (principalCap_ != 0) emit PrincipalCapUpdated(principalCap_);
        if (!operational_) emit OperationalStatusUpdated(false);
    }

    // ====== View helpers ======

    /// @notice Return the underlying ERC-20 used for sleeve accounting and settlement.
    /// @return Underlying asset token address.
    function asset() public view override returns (address) {
        return address(underlying);
    }

    /// @notice Return net principal attributed to this sleeve by successful allocations and deallocations.
    /// @dev This is book principal, not mark-to-market sleeve value; use `totalAssets()` for current value.
    /// @return Principal denominated in the underlying asset's smallest unit.
    function principalAssets() public view override returns (uint256) {
        return _principal;
    }

    // ====== Access modifiers ======

    modifier onlyStakingDiamond() {
        _onlyStakingDiamond();
        _;
    }

    modifier onlyStakingDiamondAdmin() {
        _checkStakingDiamondRole(LibStakingDiamondAuthority.DEFAULT_ADMIN_ROLE, msg.sender);
        _;
    }

    /// @dev Validate the exact Staking Diamond caller.
    function _onlyStakingDiamond() internal view {
        if (msg.sender != stakingDiamond) revert NotStakingDiamond(msg.sender);
    }

    // ====== Core flow ======

    /// @notice Deploy up to `assets` of custody capital into the sleeve's venue.
    /// @dev Restricted to the Staking Diamond and blocked while paused or non-operational. The venue hook's
    /// measured `used` amount increases principal and must not breach `principalCap`.
    /// @param assets Maximum underlying amount requested for allocation.
    /// @param data Venue-specific execution constraints, such as slippage limits.
    /// @return used Underlying amount actually deployed and added to book principal.
    function allocate(uint256 assets, bytes calldata data)
        external
        override
        onlyStakingDiamond
        whenNotPaused
        nonReentrant
        returns (uint256 used)
    {
        if (!operational) revert SleeveNotOperational();
        if (assets == 0) revert ZeroAmount();

        used = _onAllocate(assets, data);
        if (used == 0) revert ZeroAmount();

        uint256 newPrincipal = _principal + used;
        if (principalCap != 0 && newPrincipal > principalCap) revert PrincipalCapExceeded(principalCap, newPrincipal);

        _principal = newPrincipal;
        emit Allocated(assets, used);
    }

    /// @notice Deallocate, including while the sleeve is paused for emergency unwinds.
    /// @dev This path deliberately remains callable while paused and non-operational so capital can be unwound.
    /// Returned assets reduce book principal, floored at zero when a profitable unwind returns more than principal.
    /// @param assets Maximum underlying amount requested from the venue.
    /// @param data Venue-specific unwind constraints, such as LP quantity and minimum output.
    /// @return returned Underlying amount actually transferred back to custody.
    function deallocate(uint256 assets, bytes calldata data)
        external
        override
        onlyStakingDiamond
        nonReentrant
        returns (uint256 returned)
    {
        if (assets == 0) revert ZeroAmount();

        returned = _onDeallocate(assets, data);
        if (returned > _principal) {
            _principal = 0;
        } else {
            _principal -= returned;
        }

        emit Deallocated(assets, returned);
    }

    /// @notice Realize venue profit without reducing tracked principal.
    /// @param data Venue-specific claim and swap constraints.
    /// @return profit Underlying profit transferred to the Staking Diamond.
    function harvest(bytes calldata data)
        external
        override
        onlyStakingDiamond
        whenNotPaused
        nonReentrant
        returns (uint256 profit)
    {
        profit = _onHarvest(data);
        emit Harvested(profit);
    }

    // ====== Pause controls ======

    /// @notice Pause allocations and harvests when authorized by the Staking diamond.
    /// @dev Emergency deallocation remains available while paused.
    function pause() external {
        if (!LibStakingDiamondAuthority.canPause(stakingDiamond, msg.sender)) {
            revert EmergencyAuthorityUnauthorizedAccount(msg.sender);
        }
        _pause();
    }

    /// @notice Resume allocations and harvests when authorized by the Staking diamond.
    function unpause() external {
        if (!LibStakingDiamondAuthority.canUnpause(stakingDiamond, msg.sender)) {
            revert EmergencyAuthorityUnauthorizedAccount(msg.sender);
        }
        _unpause();
    }

    // ====== Internal hooks for implementations ======

    /// @dev Venue hook that pulls and deploys up to the requested underlying.
    /// @param assets Maximum underlying amount requested from Staking custody.
    /// @param data Venue-specific allocation and slippage constraints.
    /// @return used Underlying amount actually deployed.
    function _onAllocate(uint256 assets, bytes calldata data) internal virtual returns (uint256 used);

    /// @dev Venue hook that unwinds capital and returns underlying to Staking custody.
    /// @param assets Maximum underlying amount requested from the venue.
    /// @param data Venue-specific unwind and slippage constraints.
    /// @return returned Underlying amount transferred back to Staking custody.
    function _onDeallocate(uint256 assets, bytes calldata data) internal virtual returns (uint256 returned);

    /// @dev Venue hook that realizes profit without changing book principal.
    /// @param data Venue-specific reward-claim, realization, and slippage constraints.
    /// @return profit Underlying profit transferred to the Staking Diamond.
    function _onHarvest(bytes calldata data) internal virtual returns (uint256 profit);

    /// @dev Helper for sleeves to request funds from custody.
    /// @param amount Underlying asset amount requested from custody.
    /// @param to Recipient receiving assets pulled from custody.
    function _pullFromCustody(uint256 amount, address to) internal {
        ICyberGoldStaking(stakingDiamond).transferTo(asset(), to, amount);
    }

    /// @dev Helper for sleeves to push funds back to custody.
    /// @param amount Underlying asset amount returned to custody.
    function _pushToCustody(uint256 amount) internal {
        underlying.safeTransfer(stakingDiamond, amount);
    }

    /// @notice Set the maximum principal that can remain allocated in this sleeve.
    /// @dev Zero value disables the cap. Cap cannot be set below the existing principal.
    /// @param newCap New principal cap, or zero to disable the cap.
    function setPrincipalCap(uint256 newCap) external onlyStakingDiamondAdmin {
        if (newCap != 0 && newCap < _principal) revert PrincipalCapTooLow(_principal, newCap);
        principalCap = newCap;
        emit PrincipalCapUpdated(newCap);
    }

    /// @notice Toggle the sleeve's operational status. When false, allocations are blocked but deallocations/harvests continue.
    /// @param status Whether new allocations are enabled for the sleeve.
    function setOperational(bool status) external onlyStakingDiamondAdmin {
        if (operational != status) {
            operational = status;
            emit OperationalStatusUpdated(status);
        }
    }

    // ====== UUPS upgrade auth ======

    /// @dev Authorize a UUPS implementation change only for a current Staking Diamond upgrader.
    function _authorizeUpgrade(address) internal view override {
        _checkStakingDiamondRole(LibStakingDiamondAuthority.UPGRADER_ROLE, msg.sender);
    }

    function _checkStakingDiamondRole(bytes32 role, address account) internal view {
        if (!LibStakingDiamondAuthority.hasRole(stakingDiamond, role, account)) {
            revert StakingDiamondAuthorityUnauthorizedAccount(account, role);
        }
    }

    function _validateStakingDiamond(address candidate) internal view {
        if (candidate.code.length == 0) revert InvalidStakingDiamond(candidate);

        (bool adminRoleOk, bytes32 adminRole) = LibStakingDiamondAuthority.readBytes32(
            candidate, abi.encodeWithSelector(ICyberGoldStaking.DEFAULT_ADMIN_ROLE.selector)
        );
        (bool upgraderRoleOk, bytes32 upgraderRole) = LibStakingDiamondAuthority.readBytes32(
            candidate, abi.encodeWithSelector(ICyberGoldStaking.upgraderRole.selector)
        );
        (bool safeWalletOk, address safeWallet_) = LibStakingDiamondAuthority.readAddress(
            candidate, abi.encodeWithSelector(IDiamondEmergencyAuthority.safeWallet.selector)
        );
        if (
            !adminRoleOk || adminRole != LibStakingDiamondAuthority.DEFAULT_ADMIN_ROLE || !upgraderRoleOk
                || upgraderRole != LibStakingDiamondAuthority.UPGRADER_ROLE || !safeWalletOk
                || safeWallet_ == address(0)
        ) {
            revert InvalidStakingDiamond(candidate);
        }

        address probe = address(this);
        if (
            !LibStakingDiamondAuthority.isCanonicalBooleanCall(
                    candidate,
                    abi.encodeWithSelector(
                        ICyberGoldStaking.hasRole.selector, LibStakingDiamondAuthority.DEFAULT_ADMIN_ROLE, probe
                    )
                )
                || !LibStakingDiamondAuthority.isCanonicalBooleanCall(
                    candidate, abi.encodeWithSelector(IDiamondEmergencyAuthority.canPause.selector, probe)
                )
                || !LibStakingDiamondAuthority.isCanonicalBooleanCall(
                    candidate, abi.encodeWithSelector(IDiamondEmergencyAuthority.canUnpause.selector, probe)
                )
        ) {
            revert InvalidStakingDiamond(candidate);
        }
    }

    // Version-1 base state occupies slots 0-4; reserve through slot 49 for future upgrades.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[45] private __gap;
}
