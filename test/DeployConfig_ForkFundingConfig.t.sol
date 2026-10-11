// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";

contract DeployConfig_ForkFundingConfig is Test {
    address internal constant USDC_MAINNET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT_MAINNET = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant CURVE_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    function test_loadForkFunding_tokenArraysAlignedAndNonZero() external view {
        DeployConfig.ForkFundingConfig memory funding = DeployConfig.loadForkFunding(vm);
        uint256 len = funding.tokenSymbols.length;

        assertEq(len, funding.tokenAddresses.length, "token addresses length mismatch");
        assertEq(len, funding.tokenHolders.length, "token holders length mismatch");
        assertEq(len, funding.tokenPerAddr.length, "token perAddr length mismatch");

        for (uint256 i = 0; i < len; i++) {
            assertTrue(funding.tokenAddresses[i] != address(0), "token address missing");
            assertTrue(funding.tokenHolders[i] != address(0), "token holder missing");
        }
    }

    function test_loadForkFunding_usesMainnetStablecoinEntries() external view {
        DeployConfig.ForkFundingConfig memory funding = DeployConfig.loadForkFunding(vm);

        uint256 usdcIndex = _symbolIndex(funding.tokenSymbols, "USDC");
        uint256 usdtIndex = _symbolIndex(funding.tokenSymbols, "USDT");

        assertEq(funding.tokenAddresses[usdcIndex], USDC_MAINNET, "USDC address mismatch");
        assertEq(funding.tokenAddresses[usdtIndex], USDT_MAINNET, "USDT address mismatch");
        assertEq(funding.tokenHolders[usdcIndex], CURVE_3POOL, "USDC holder mismatch");
        assertEq(funding.tokenHolders[usdtIndex], CURVE_3POOL, "USDT holder mismatch");
        assertGt(funding.tokenPerAddr[usdcIndex], 0, "USDC amount must be > 0");
        assertGt(funding.tokenPerAddr[usdtIndex], 0, "USDT amount must be > 0");
    }

    function _symbolIndex(string[] memory symbols, string memory symbol) private pure returns (uint256) {
        bytes32 needle = keccak256(bytes(symbol));
        for (uint256 i = 0; i < symbols.length; i++) {
            if (keccak256(bytes(symbols[i])) == needle) {
                return i;
            }
        }
        revert("symbol missing");
    }
}
