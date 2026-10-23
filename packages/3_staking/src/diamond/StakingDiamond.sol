// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

/*
   _____      _                _____       _     _
  / ____|    | |              / ____|     | |   | |
 | |    _   _| |__   ___ _ __| |  __  ___ | | __| |
 | |   | | | | '_ \ / _ \ '__| | |_ |/ _ \| |/ _` |
 | |___| |_| | |_) |  __/ |  | |__| | (_) | | (_| |
  \_____\__, |_.__/ \___|_|   \_____|\___/|_|\__,_|
         __/ |
        |___/

  Staking Diamond


  ὅπου γάρ ἐστιν ὁ θησαυρός σου, ἐκεῖ ἔσται καὶ ἡ καρδία σου.
    -- Matthew 6:21

*/

import {DiamondArgs} from "diamond-1/Diamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {ProtocolDiamond} from "diamond-infra/diamond/ProtocolDiamond.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {IDiamondEmergencyAuthority} from "diamond-infra/interfaces/IDiamondEmergencyAuthority.sol";
import {LibStakingLaunch} from "../libraries/LibStakingLaunch.sol";

/// @custom:security-contact security@cybergold.io
/// @notice Staking domain diamond proxy using CyberGold's nonpayable protocol diamond shell.
contract StakingDiamond is ProtocolDiamond {
    /// @notice Deploy the StakingDiamond contract.
    /// @param _diamondCut Diamond facet cuts or diamond cut facet address supplied during initialization.
    /// @param _args ABI-encoded initializer arguments supplied to the diamond constructor.
    constructor(IDiamondCut.FacetCut[] memory _diamondCut, DiamondArgs memory _args)
        ProtocolDiamond(_diamondCut, _args)
    {}

    /// @dev Sleeve initialization may inspect only the canonical authority views while Finalizing.
    function _beforeFallback(bytes4 selector) internal view override {
        if (LibStakingLaunch.getLayout().phase != LibStakingLaunch.Phase.Finalizing) return;
        if (
            selector == bytes4(keccak256("DEFAULT_ADMIN_ROLE()"))
                || selector == DefaultAdminAccessControlFacet.upgraderRole.selector
                || selector == IAccessControl.hasRole.selector || selector == IAccessControl.getRoleAdmin.selector
                || selector == IAccessControlEnumerable.getRoleMember.selector
                || selector == IAccessControlEnumerable.getRoleMemberCount.selector
                || selector == IAccessControlDefaultAdminRules.defaultAdmin.selector
                || selector == IAccessControlDefaultAdminRules.pendingDefaultAdmin.selector
                || selector == IAccessControlDefaultAdminRules.defaultAdminDelay.selector
                || selector == IAccessControlDefaultAdminRules.pendingDefaultAdminDelay.selector
                || selector == IDiamondEmergencyAuthority.safeWallet.selector
                || selector == IDiamondEmergencyAuthority.canPause.selector
                || selector == IDiamondEmergencyAuthority.canUnpause.selector
        ) return;
        revert StakingMutationDuringFinalization(selector);
    }

    /// @notice A callback attempted a non-canonical call during atomic initialization.
    /// @param selector Selector rejected while the launch was in its Finalizing phase.
    error StakingMutationDuringFinalization(bytes4 selector);
}
