// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";

/// @notice Selector tables for the core diamond to keep deployment helpers/test harnesses in sync.
library FacetSelectors {
    /// @notice Return selectors exposed by the token facet.
    /// @return selectors token facet selectors in deterministic order.
    function tokenSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](17);
        selectors[0] = 0x3644e515; // DOMAIN_SEPARATOR()
        selectors[1] = 0xdd62ed3e; // allowance(address,address)
        selectors[2] = 0xebdd2f41; // allowanceExposure(address)
        selectors[3] = 0x095ea7b3; // approve(address,uint256)
        selectors[4] = 0x70a08231; // balanceOf(address)
        selectors[5] = 0x9dc29fac; // burn(address,uint256)
        selectors[6] = 0x313ce567; // decimals()
        selectors[7] = 0x84b0196e; // eip712Domain()
        selectors[8] = 0x40c10f19; // mint(address,uint256)
        selectors[9] = 0x06fdde03; // name()
        selectors[10] = 0x7ecebe00; // nonces(address)
        selectors[11] = 0xd505accf; // permit(address,address,uint256,uint256,uint8,bytes32,bytes32)
        selectors[12] = 0x95d89b41; // symbol()
        selectors[13] = 0x18160ddd; // totalSupply()
        selectors[14] = 0xa9059cbb; // transfer(address,uint256)
        selectors[15] = 0x23b872dd; // transferFrom(address,address,uint256)
        selectors[16] = 0x4211fe70; // unallowancedBalanceOf(address)
    }

    /// @notice Return selectors exposed by the issuance facet.
    /// @return selectors issuance facet selectors in deterministic order.
    function issuanceSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = 0xcc872b66; // issue(uint256)
        selectors[1] = 0xe144eeff; // safeIssue(uint256,address[],uint256[])
    }

    /// @notice Return selectors exposed by the redemption facet.
    /// @return selectors redemption facet selectors in deterministic order.
    function redemptionSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = 0xdb006a75; // redeem(uint256)
        selectors[1] = 0x69588208; // safeRedeem(uint256,(uint8,address,uint256,uint256)[])
    }

    /// @notice Return selectors exposed by the rebalance facet.
    /// @return selectors rebalance facet selectors in deterministic order.
    function rebalanceSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = 0x14370f0c; // previewRebalanceSwapExactIn(address,address,uint256)
        selectors[1] = 0xe5b323f3; // rebalanceSwapExactIn(address,address,uint256,uint256)
    }

    /// @notice Return selectors exposed by the preview facet.
    /// @return selectors preview facet selectors in deterministic order.
    function previewSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = 0xdb129a1c; // previewIssueFromBasketExactIn(uint256[])
        selectors[1] = 0xf1f487d5; // previewIssueFromBasketExactOut(uint256)
        selectors[2] = 0x78bac762; // previewRedeemExactIn(uint256)
        selectors[3] = 0xc8ba2f6d; // previewRedeemExactOut((uint8,address,uint256,uint256)[])
    }

    /// @notice Return selectors exposed by the basketAdmin facet.
    /// @return selectors basketAdmin facet selectors in deterministic order.
    function basketAdminSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = 0x53473ae0; // setBasket(bytes32,address[],uint256[],uint256[])
    }

    /// @notice Return selectors exposed by the controllerConfig facet.
    /// @return selectors controllerConfig facet selectors in deterministic order.
    function configSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = 0x01ff572d; // MAX_FEE_PPM()
        selectors[1] = 0x04551e9d; // REDEMPTION_FEE_EXEMPT_ROLE()
        selectors[2] = 0x3221c094; // setIssuanceFeePpm(uint256,uint256)
        selectors[3] = 0x87198cf2; // setMaxTotalSupply(uint256,uint256)
        selectors[4] = 0xeb33347d; // setRedemptionFeePpm(uint256,uint256)
        selectors[5] = 0xadfe0870; // setTreasury(address,address)
    }

    /// @notice Return selectors exposed by the lens facet.
    /// @return selectors lens facet selectors in deterministic order.
    function lensSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](18);
        selectors[0] = 0x420394b2; // basketAssets()
        selectors[1] = 0xb2538ec2; // basketConfigHash()
        selectors[2] = 0x798e9658; // basketCygldPerUnitFp18()
        selectors[3] = 0x5a487e17; // basketGoldRefGramsFp18()
        selectors[4] = 0xb3fd7741; // basketTargetsPpm()
        selectors[5] = 0x5098fc00; // coreAttachedRecoveryAssets()
        selectors[6] = 0xc81212d5; // cygldRefGramsFp18()
        selectors[7] = 0x0f9182e7; // effectiveCygldSupplyCap()
        selectors[8] = 0xa7a19e71; // issuanceFeePpm()
        selectors[9] = 0x2ab4d052; // maxTotalSupply()
        selectors[10] = 0x8264ba8d; // outstandingRecoveryAssetCount()
        selectors[11] = 0xf9cdd808; // outstandingRecoveryAssets(uint256,uint256)
        selectors[12] = 0xba588430; // previewRedeemRecoveryShares(address,uint256)
        selectors[13] = 0xcc649f16; // recoveryPool(address)
        selectors[14] = 0xfd0602f1; // redemptionFeePpm()
        selectors[15] = 0x7e435382; // reserveCustodyStatus(address)
        selectors[16] = 0xc6122eb7; // reserveLifecycle(address)
        selectors[17] = 0x61d027b3; // treasury()
    }

    /// @notice Return selectors exposed by the reserveLifecycle facet.
    /// @return selectors reserveLifecycle facet selectors in deterministic order.
    function reserveLifecycleSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = 0x75deee16; // activateAsset((address,uint8,bytes32,uint256,address[],uint256[],uint256[]))
        selectors[1] = 0x860ecd33; // beginReserveExit((address,bytes32,uint256,address[],uint256[],uint256[]))
        selectors[2] = 0x5f8a5e47; // finalizeReserveInactivation((address,bytes32,address[],uint256[],uint256[]))
    }

    /// @notice Return selectors exposed by the recoveryShare facet.
    /// @return selectors recoveryShare facet selectors in deterministic order.
    function recoveryShareSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](9);
        selectors[0] = 0x00fdd58e; // balanceOf(address,uint256)
        selectors[1] = 0x4e1273f4; // balanceOfBatch(address[],uint256[])
        selectors[2] = 0x6bfe1c58; // burnRecoveryShares(address,address,uint256)
        selectors[3] = 0xe985e9c5; // isApprovedForAll(address,address)
        selectors[4] = 0x32866daf; // issueRecoveryShares(address,address[],uint256[])
        selectors[5] = 0x2eb2c2d6; // safeBatchTransferFrom(address,address,uint256[],uint256[],bytes)
        selectors[6] = 0xf242432a; // safeTransferFrom(address,address,uint256,uint256,bytes)
        selectors[7] = 0xa22cb465; // setApprovalForAll(address,bool)
        selectors[8] = 0xbd85b039; // totalSupply(uint256)
    }

    /// @notice Return selectors exposed by the recoveryShareMetadata facet.
    /// @return selectors recoveryShareMetadata facet selectors in deterministic order.
    function recoveryShareMetadataSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = 0xe8a3d485; // contractURI()
        selectors[1] = 0x0e89341c; // uri(uint256)
    }

    /// @notice Return selectors exposed by the recoveryAdmin facet.
    /// @return selectors recoveryAdmin facet selectors in deterministic order.
    function recoveryAdminSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = 0xdf809d9f; // activateRecovery((address,uint8,bytes32,uint256,address[],uint256[],uint256[],uint256))
        selectors[1] = 0xfe90b33d; // finalizeZeroEntitlementRecovery(address)
        selectors[2] = 0xec4661fb; // rehabilitateRecoveryAsset((address,bytes32,uint256,uint256,uint256,address[],uint256[],uint256[]))
    }

    /// @notice Return selectors exposed by the recoveryPoolSettlement facet.
    /// @return selectors recoveryPoolSettlement facet selectors in deterministic order.
    function recoveryPoolSettlementSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = 0x6f790d9e; // redeemRecoveryShares(address,uint256,address,uint256)
    }

    /// @notice Return the preview selectors belonging to the narrow mixed-redemption interface.
    /// @return selectors Mixed-redemption preview selectors in deterministic order.
    function redemptionPreviewSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = 0x78bac762; // previewRedeemExactIn(uint256)
        selectors[1] = 0xc8ba2f6d; // previewRedeemExactOut((uint8,address,uint256,uint256)[])
    }

    /// @notice Build facet specifications for this diamond cut.
    /// @param facets Facet addresses in the same deterministic order as the generated entries.
    /// @return entries Named facet specifications with their expected selectors.
    function specs(address[] memory facets) internal pure returns (FacetSpec.Entry[] memory entries) {
        require(facets.length == 13, "FacetSelectors: facet count mismatch");
        entries = new FacetSpec.Entry[](13);
        entries[0] = FacetSpec.Entry({name: "token", facet: facets[0], selectors: tokenSelectors()});
        entries[1] = FacetSpec.Entry({name: "issuance", facet: facets[1], selectors: issuanceSelectors()});
        entries[2] = FacetSpec.Entry({name: "redemption", facet: facets[2], selectors: redemptionSelectors()});
        entries[3] = FacetSpec.Entry({name: "rebalance", facet: facets[3], selectors: rebalanceSelectors()});
        entries[4] = FacetSpec.Entry({name: "preview", facet: facets[4], selectors: previewSelectors()});
        entries[5] = FacetSpec.Entry({name: "basketAdmin", facet: facets[5], selectors: basketAdminSelectors()});
        entries[6] = FacetSpec.Entry({name: "controllerConfig", facet: facets[6], selectors: configSelectors()});
        entries[7] = FacetSpec.Entry({name: "lens", facet: facets[7], selectors: lensSelectors()});
        entries[8] =
            FacetSpec.Entry({name: "reserveLifecycle", facet: facets[8], selectors: reserveLifecycleSelectors()});
        entries[9] = FacetSpec.Entry({name: "recoveryShare", facet: facets[9], selectors: recoveryShareSelectors()});
        entries[10] = FacetSpec.Entry({
            name: "recoveryShareMetadata", facet: facets[10], selectors: recoveryShareMetadataSelectors()
        });
        entries[11] = FacetSpec.Entry({name: "recoveryAdmin", facet: facets[11], selectors: recoveryAdminSelectors()});
        entries[12] = FacetSpec.Entry({
            name: "recoveryPoolSettlement", facet: facets[12], selectors: recoveryPoolSettlementSelectors()
        });
    }
}
