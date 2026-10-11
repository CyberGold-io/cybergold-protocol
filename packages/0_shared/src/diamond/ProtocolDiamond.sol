// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {DiamondArgs} from "diamond-1/Diamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";

/// @notice Reverts when ether not accepted.
error EtherNotAccepted();
/// @notice Reverts when function not found.
/// @param functionSelector Selector that failed to resolve to an installed facet.
error FunctionNotFound(bytes4 functionSelector);

/// @notice CyberGold protocol diamond shell with no native ETH entrypoints.
/// @dev The installed diamond interfaces intentionally expose no caller-funded native-value flow, so fallback is
///      nonpayable even when an inherited facet implementation declares a selector payable.
contract ProtocolDiamond {
    /// @notice Deploy the ProtocolDiamond contract.
    /// @param diamondCut Diamond cut facet address supplied to the diamond constructor.
    /// @param args ABI-encoded initializer arguments or default deployment arguments.
    constructor(IDiamondCut.FacetCut[] memory diamondCut, DiamondArgs memory args) {
        LibDiamond.setContractOwner(args.owner);
        LibDiamond.diamondCut(diamondCut, args.init, args.initCalldata);
    }

    /// @notice Reject calls that do not match an installed facet selector.
    fallback() external {
        _beforeFallback(msg.sig);
        LibDiamond.DiamondStorage storage ds;
        bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
        address facet = ds.facetAddressAndSelectorPosition[msg.sig].facetAddress;
        if (facet == address(0)) {
            revert FunctionNotFound(msg.sig);
        }
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /// @notice Reject native ETH sent directly to this contract.
    receive() external payable {
        revert EtherNotAccepted();
    }

    /// @dev Component-specific guard invoked before dispatching an installed selector.
    function _beforeFallback(bytes4) internal view virtual {}
}
