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

  Governance Diamond


  קְנֹה חָכְמָה מַה־טּוֹב מֵחָרוּץ
    -- Proverbs 16:16

*/

import {DiamondArgs} from "diamond-1/Diamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {ProtocolDiamond} from "diamond-infra/diamond/ProtocolDiamond.sol";

/// @custom:security-contact security@cybergold.io
/// @notice Thin wrapper around CyberGold's nonpayable protocol diamond shell for the governance stack.
contract GovernanceDiamond is ProtocolDiamond {
    /// @notice Deploy the GovernanceDiamond contract.
    /// @param _diamondCut Diamond facet cuts or diamond cut facet address supplied during initialization.
    /// @param _args ABI-encoded initializer arguments supplied to the diamond constructor.
    constructor(IDiamondCut.FacetCut[] memory _diamondCut, DiamondArgs memory _args)
        ProtocolDiamond(_diamondCut, _args)
    {}
}
