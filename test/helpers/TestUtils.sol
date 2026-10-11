// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

library TestUtils {
    function arr2(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function uarr2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function mintMock(address token, address to, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
        require(ok, "mint failed");
    }
}
