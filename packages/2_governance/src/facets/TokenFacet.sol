// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {InitContext} from "diamond-infra/helpers/InitContext.sol";

/// @notice CYGOV ERC20Votes facet for the governance diamond.
/// @dev The diamond also exposes Governor selectors, so duplicated selectors are owned by selector config precedence.
contract TokenFacet is
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    PausableUpgradeable,
    InitContext
{
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.governance.token");

    /// @notice Reverts when initial holder required.
    error InitialHolderRequired();
    /// @notice Reverts when treasury-held CYGOV is assigned voting power while excluded from external supply.
    /// @param delegatee Nonzero account the Governance diamond attempted to delegate its treasury votes to.
    error GovernanceTreasuryDelegationForbidden(address delegatee);

    /// @dev Disable implementation initializers for the governance token facet.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize CYGOV metadata and optional bootstrap supply through DiamondInit only.
    /// @param name_ ERC20Votes token name.
    /// @param symbol_ ERC20Votes token symbol.
    /// @param initialHolder Holder that receives bootstrap supply when configured.
    /// @param initialSupply Bootstrap governance token supply minted during initialization.
    /// @param treasurySupply Bootstrap governance token supply minted to the Governance diamond treasury.
    function initToken(
        string memory name_,
        string memory symbol_,
        address initialHolder,
        uint256 initialSupply,
        uint256 treasurySupply
    ) external onlyInit {
        if (initialSupply != 0 && initialHolder == address(0)) revert InitialHolderRequired();

        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __ERC20Votes_init();

        if (initialSupply != 0) {
            _mint(initialHolder, initialSupply);
            _delegate(initialHolder, initialHolder);
        }
        if (treasurySupply != 0) {
            _mint(address(this), treasurySupply);
        }
    }

    /// @notice Return clock.
    /// @return Current ERC-6372 clock value used by governor votes.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @notice Return clock mode.
    /// @return ERC-6372 clock mode string.
    // forge-lint: disable-next-line(mixed-case-function)
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /// @dev Internal helper for update.
    /// @param from Source address for a transfer or burn.
    /// @param to Recipient address for a transfer, mint, or swap output.
    /// @param value Native ETH value or numeric amount supplied to the operation.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        // A diamond pause protects CYGOV supply changes, not holder mobility. Mint and burn
        // use a zero endpoint; Governance treasury outflows are gated separately in TreasuryFacet.
        if (from == address(0) || to == address(0)) _requireNotPaused();
        super._update(from, to, value);
    }

    /// @dev Keep Governance-owned CYGOV deliberately non-voting while it is excluded from external supply.
    ///      Delegating to zero remains available as a fail-safe repair path.
    function _delegate(address account, address delegatee) internal override {
        if (account == address(this) && delegatee != address(0)) {
            revert GovernanceTreasuryDelegationForbidden(delegatee);
        }
        super._delegate(account, delegatee);
    }

    /// @notice Return nonces.
    /// @param owner Account that owns tokens, shares, or queued requests.
    /// @return Current permit nonce for the owner.
    function nonces(address owner) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }
}
