// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";

/// @notice Centralized selector tables so deploy scripts and integration tests stay aligned.
library FacetSelectors {
    /// @notice Return selectors exposed by the token facet.
    /// @return selectors token facet selectors in deterministic order.
    function tokenSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = 0xa8d5fd65; // share()
    }

    /// @notice Return selectors exposed by the vault facet.
    /// @return selectors vault facet selectors in deterministic order.
    function vaultSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](28);
        selectors[0] = 0xdd62ed3e; // allowance(address,address)
        selectors[1] = 0x095ea7b3; // approve(address,uint256)
        selectors[2] = 0x38d52e0f; // asset()
        selectors[3] = 0x70a08231; // balanceOf(address)
        selectors[4] = 0x07a2d13a; // convertToAssets(uint256)
        selectors[5] = 0xc6e6f592; // convertToShares(uint256)
        selectors[6] = 0x313ce567; // decimals()
        selectors[7] = 0x6e553f65; // deposit(uint256,address)
        selectors[8] = 0xd38eb9d3; // escrowFrom(address,uint256)
        selectors[9] = 0xe5a44482; // liquidityBreakdown()
        selectors[10] = 0x402d267d; // maxDeposit(address)
        selectors[11] = 0xc63d75b6; // maxMint(address)
        selectors[12] = 0xd905777e; // maxRedeem(address)
        selectors[13] = 0xce96cb77; // maxWithdraw(address)
        selectors[14] = 0x94bf804d; // mint(uint256,address)
        selectors[15] = 0x06fdde03; // name()
        selectors[16] = 0xce94eb96; // payout(address,address,address,uint256)
        selectors[17] = 0xef8b30f7; // previewDeposit(uint256)
        selectors[18] = 0xb3d7f6b9; // previewMint(uint256)
        selectors[19] = 0x4cdad506; // previewRedeem(uint256)
        selectors[20] = 0x0a28a477; // previewWithdraw(uint256)
        selectors[21] = 0x8b198025; // returnShares(address,uint256)
        selectors[22] = 0x95d89b41; // symbol()
        selectors[23] = 0x01e1d114; // totalAssets()
        selectors[24] = 0xdf6e6142; // totalAssetsSafe()
        selectors[25] = 0x18160ddd; // totalSupply()
        selectors[26] = 0xa9059cbb; // transfer(address,uint256)
        selectors[27] = 0x23b872dd; // transferFrom(address,address,uint256)
    }

    /// @notice Return selectors exposed by the queue facet.
    /// @return selectors queue facet selectors in deterministic order.
    function queueSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](12);
        selectors[0] = 0x3015394c; // cancelRequest(uint256)
        selectors[1] = 0x29e999f4; // claimRequest(uint256,address)
        selectors[2] = 0xc16b5039; // claimRequestUpTo(uint256,uint256,address)
        selectors[3] = 0xdc900765; // processQueue(uint256)
        selectors[4] = 0xd9b7c250; // purgeExpired(uint256[])
        selectors[5] = 0xba087652; // redeem(uint256,address,address)
        selectors[6] = 0x7d41c86e; // requestRedeem(uint256,address,address)
        selectors[7] = 0xe43a3230; // setAutoProcessMax(uint256)
        selectors[8] = 0x42ddb9f0; // setClaimExpiry(uint64)
        selectors[9] = 0xe18854ed; // setHeadSweepLimit(uint256)
        selectors[10] = 0x440e52bf; // sweepExpiredHead(uint256)
        selectors[11] = 0xb460af94; // withdraw(uint256,address,address)
    }

    /// @notice Return selectors exposed by the queueOperator facet.
    /// @return selectors queueOperator facet selectors in deterministic order.
    function queueOperatorSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = 0x02545bcb; // setControllerOperator(address,bool)
        selectors[1] = 0x16e30dcf; // setOwnerOperator(address,bool)
    }

    /// @notice Return selectors exposed by the queueSig facet.
    /// @return selectors queueSig facet selectors in deterministic order.
    function queueSigSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = 0x3644e515; // DOMAIN_SEPARATOR()
        selectors[1] = 0x5e39974f; // REQUEST_REDEEM_TYPEHASH()
        selectors[2] = 0x7ecebe00; // nonces(address)
        selectors[3] = 0xc06dada3; // requestRedeemBySig(uint256,address,address,uint256,uint8,bytes32,bytes32)
    }

    /// @notice Return selectors exposed by the custody facet.
    /// @return selectors custody facet selectors in deterministic order.
    function custodySelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = 0x85f438c1; // WITHDRAWER_ROLE()
        selectors[1] = 0x69e08a0c; // custodyBalance(address)
        selectors[2] = 0xa5f2a152; // transferTo(address,address,uint256)
    }

    /// @notice Return selectors exposed by the registry facet.
    /// @return selectors registry facet selectors in deterministic order.
    function registrySelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = 0x34129a59; // registerSleeve(address,address)
        selectors[1] = 0x8654db41; // setSleeveApproval(address,bool)
        selectors[2] = 0xf4d5808c; // sleeveConfig(address)
        selectors[3] = 0xc4188020; // sleeves()
        selectors[4] = 0x42e2ee9e; // stakerAssetsInSleeves(address)
    }

    /// @notice Return selectors exposed by the fund facet.
    /// @return selectors fund facet selectors in deterministic order.
    function fundSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](16);
        selectors[0] = 0xc81cbaa1; // ALLOCATOR_ROLE()
        selectors[1] = 0x7d85ad6a; // MAX_PERFORMANCE_FEE_PPM()
        selectors[2] = 0x1c75e369; // allocate(address,uint256,bytes)
        selectors[3] = 0xd3e99e1c; // cygld()
        selectors[4] = 0x549230c9; // deallocate(address,uint256,bytes)
        selectors[5] = 0xc526c90a; // harvestAndDonateAsCygld(address,uint256,bytes)
        selectors[6] = 0x2d379033; // investableFor(address)
        selectors[7] = 0x31b5f955; // performanceFeePpm()
        selectors[8] = 0xb7648fb9; // position(address)
        selectors[9] = 0x69336753; // principalPerAsset(address)
        selectors[10] = 0xb4260cbc; // setPerformanceFee(uint256,uint256)
        selectors[11] = 0xb826ee54; // setSwapAdapter(address)
        selectors[12] = 0xf0f44260; // setTreasury(address)
        selectors[13] = 0x86af88f3; // stakerRatioFp18()
        selectors[14] = 0x77bb1eb9; // swapAdapter()
        selectors[15] = 0x61d027b3; // treasury()
    }

    /// @notice Return selectors exposed by the lens facet.
    /// @return selectors lens facet selectors in deterministic order.
    function lensSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](22);
        selectors[0] = 0x569c7fd1; // autoProcessMax()
        selectors[1] = 0xd03384b8; // claimExpiry()
        selectors[2] = 0xeaed1d07; // claimableRedeemRequest(uint256,address)
        selectors[3] = 0x4f5ad9c5; // claimableShares(address)
        selectors[4] = 0x6114d32c; // claimableSharesTotal()
        selectors[5] = 0x2dbcdd2d; // controllerOpenQueries(address)
        selectors[6] = 0x3b3c186d; // controllerOpenQueries(address,uint256,uint256)
        selectors[7] = 0x50a1676e; // createdAt(uint256)
        selectors[8] = 0x15d6f1a8; // headId()
        selectors[9] = 0x70c75d14; // headSweepLimit()
        selectors[10] = 0xd9548e53; // isExpired(uint256)
        selectors[11] = 0x50df8f71; // isReady(uint256)
        selectors[12] = 0xdc6b247f; // queueAggregates(address)
        selectors[13] = 0x8544a0ae; // queueRequests(address)
        selectors[14] = 0x035c0801; // readyAtFor(uint256)
        selectors[15] = 0x676f3cb7; // readyBoundaryId()
        selectors[16] = 0xf3f78be5; // seqInBlock()
        selectors[17] = 0x2d293586; // sleevePositions()
        selectors[18] = 0x5ff4d706; // stakingLaunchState()
        selectors[19] = 0x991292e3; // systemState()
        selectors[20] = 0x20dd22be; // tailId()
        selectors[21] = 0x26e85250; // viewRequest(uint256)
    }

    /// @notice Build facet specifications for this diamond cut.
    /// @param token token facet address.
    /// @param vault vault facet address.
    /// @param queue queue facet address.
    /// @param queueOperator queueOperator facet address.
    /// @param queueSig queueSig facet address.
    /// @param custody custody facet address.
    /// @param registry registry facet address.
    /// @param fund fund facet address.
    /// @param lens lens facet address.
    /// @return entries Named facet specifications with their expected selectors.
    function specs(
        address token,
        address vault,
        address queue,
        address queueOperator,
        address queueSig,
        address custody,
        address registry,
        address fund,
        address lens
    ) internal pure returns (FacetSpec.Entry[] memory entries) {
        entries = new FacetSpec.Entry[](9);
        entries[0] = FacetSpec.Entry({name: "token", facet: token, selectors: tokenSelectors()});
        entries[1] = FacetSpec.Entry({name: "vault", facet: vault, selectors: vaultSelectors()});
        entries[2] = FacetSpec.Entry({name: "queue", facet: queue, selectors: queueSelectors()});
        entries[3] = FacetSpec.Entry({name: "queueOperator", facet: queueOperator, selectors: queueOperatorSelectors()});
        entries[4] = FacetSpec.Entry({name: "queueSig", facet: queueSig, selectors: queueSigSelectors()});
        entries[5] = FacetSpec.Entry({name: "custody", facet: custody, selectors: custodySelectors()});
        entries[6] = FacetSpec.Entry({name: "registry", facet: registry, selectors: registrySelectors()});
        entries[7] = FacetSpec.Entry({name: "fund", facet: fund, selectors: fundSelectors()});
        entries[8] = FacetSpec.Entry({name: "lens", facet: lens, selectors: lensSelectors()});
    }
}
