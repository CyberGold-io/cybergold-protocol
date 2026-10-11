// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {ProtocolDiamondLoupeFacet} from "diamond-infra/facets/ProtocolDiamondLoupeFacet.sol";

/// @notice Versioned Staking wrapper around the canonical EIP-2535 loupe implementation.
/// @dev Only the five standard loupe selectors are installed; metadata remains implementation-only.
contract StakingDiamondLoupeFacet is ProtocolDiamondLoupeFacet {}
