// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Lightweight helper to deploy UUPS proxies with init calldata.
library ProxyDeployer {
    // forge-lint: disable-next-line(mixed-case-function)
    function deployUUPS(address impl, bytes memory initCalldata) internal returns (address) {
        return address(new ERC1967Proxy(impl, initCalldata));
    }
}
