// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";

/// @notice Selector tables for the governance diamond to keep deployment helpers/test harnesses in sync.
library FacetSelectors {
    /// @notice Return selectors exposed by the recoveryFund facet.
    /// @return selectors recoveryFund facet selectors in deterministic order.
    function recoveryFundSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = 0x3e35db1e; // activateAssetRecoveryFund((address,uint64,uint256,uint256))
        selectors[1] = 0xc8a81e3b; // onCygldApprovalChange(address,uint256,uint256,uint256,uint256)
        selectors[2] = 0x8886834b; // onCygldOutflow(address,address,uint256,uint256,uint256)
        selectors[3] = 0xbc197c81; // onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)
        selectors[4] = 0xf23a6e61; // onERC1155Received(address,address,uint256,uint256,bytes)
        selectors[5] = 0xc723c768; // onRecoveryShareOutflow(address,address,uint256[],uint256[])
        selectors[6] = 0x54b02e3b; // onRecoveryShareRedemption(address,uint256,address,uint256,uint256)
    }

    /// @notice Return selectors exposed by the governorCore facet.
    /// @return selectors governorCore facet selectors in deterministic order.
    function governorCoreSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](30);
        selectors[0] = 0xdeaaa7cc; // BALLOT_TYPEHASH()
        selectors[1] = 0x4bf5d7e9; // CLOCK_MODE()
        selectors[2] = 0xdd4e2ba5; // COUNTING_MODE()
        selectors[3] = 0x452115d6; // cancel(address[],uint256[],bytes[],bytes32)
        selectors[4] = 0x56781388; // castVote(uint256,uint8)
        selectors[5] = 0x8ff262e3; // castVoteBySig(uint256,uint8,address,bytes)
        selectors[6] = 0x7b3c71d3; // castVoteWithReason(uint256,uint8,string)
        selectors[7] = 0x91ddadf4; // clock()
        selectors[8] = 0x84b0196e; // eip712Domain()
        selectors[9] = 0x2656227d; // execute(address[],uint256[],bytes[],bytes32)
        selectors[10] = 0x146d838b; // externalCygovSupply()
        selectors[11] = 0xa8f8a668; // getProposalId(address[],uint256[],bytes[],bytes32)
        selectors[12] = 0xeb9019d4; // getVotes(address,uint256)
        selectors[13] = 0x43859632; // hasVoted(uint256,address)
        selectors[14] = 0xc59057e4; // hashProposal(address[],uint256[],bytes[],bytes32)
        selectors[15] = 0x06fdde03; // name()
        selectors[16] = 0x150b7a02; // onERC721Received(address,address,uint256,bytes)
        selectors[17] = 0xc01f9e37; // proposalDeadline(uint256)
        selectors[18] = 0xab58fb8e; // proposalEta(uint256)
        selectors[19] = 0x5aa21375; // proposalExpiresAt(uint256)
        selectors[20] = 0xa9a95294; // proposalNeedsQueuing(uint256)
        selectors[21] = 0x143489d0; // proposalProposer(uint256)
        selectors[22] = 0xfb999fcb; // proposalQuorum(uint256)
        selectors[23] = 0x2d63f693; // proposalSnapshot(uint256)
        selectors[24] = 0xb58131b0; // proposalThreshold()
        selectors[25] = 0x544ffc9c; // proposalVotes(uint256)
        selectors[26] = 0x7d5e81e2; // propose(address[],uint256[],bytes[],string)
        selectors[27] = 0x3e4f49e6; // state(uint256)
        selectors[28] = 0xfc0c546a; // token()
        selectors[29] = 0x54fd4d50; // version()
    }

    /// @notice Return selectors exposed by the token facet.
    /// @return selectors token facet selectors in deterministic order.
    function tokenSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](19);
        selectors[0] = 0x3644e515; // DOMAIN_SEPARATOR()
        selectors[1] = 0xdd62ed3e; // allowance(address,address)
        selectors[2] = 0x095ea7b3; // approve(address,uint256)
        selectors[3] = 0x70a08231; // balanceOf(address)
        selectors[4] = 0xf1127ed8; // checkpoints(address,uint32)
        selectors[5] = 0x313ce567; // decimals()
        selectors[6] = 0x5c19a95c; // delegate(address)
        selectors[7] = 0xc3cda520; // delegateBySig(address,uint256,uint256,uint8,bytes32,bytes32)
        selectors[8] = 0x587cde1e; // delegates(address)
        selectors[9] = 0x8e539e8c; // getPastTotalSupply(uint256)
        selectors[10] = 0x3a46b1a8; // getPastVotes(address,uint256)
        selectors[11] = 0x9ab24eb0; // getVotes(address)
        selectors[12] = 0x7ecebe00; // nonces(address)
        selectors[13] = 0x6fcfff45; // numCheckpoints(address)
        selectors[14] = 0xd505accf; // permit(address,address,uint256,uint256,uint8,bytes32,bytes32)
        selectors[15] = 0x95d89b41; // symbol()
        selectors[16] = 0x18160ddd; // totalSupply()
        selectors[17] = 0xa9059cbb; // transfer(address,uint256)
        selectors[18] = 0x23b872dd; // transferFrom(address,address,uint256)
    }

    /// @notice Return selectors exposed by the treasury facet.
    /// @return selectors treasury facet selectors in deterministic order.
    function treasurySelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = 0xbd1ff441; // treasuryWithdraw(address,address,uint256)
    }

    /// @notice Return selectors exposed by the governorSettings facet.
    /// @return selectors governorSettings facet selectors in deterministic order.
    function governorSettingsSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](12);
        selectors[0] = 0x8b257989; // executionDelay()
        selectors[1] = 0xec0a12d9; // executionGracePeriod()
        selectors[2] = 0x327a71e7; // proposalThresholdNumerator()
        selectors[3] = 0xa7713a70; // quorumNumerator()
        selectors[4] = 0x7b1b6abf; // setExecutionDelay(uint48,uint48)
        selectors[5] = 0x69c61caa; // setExecutionGracePeriod(uint48,uint48)
        selectors[6] = 0xf4c3ff58; // setProposalThresholdNumerator(uint32,uint32)
        selectors[7] = 0x9cc2d2ce; // setQuorumNumerator(uint8,uint8)
        selectors[8] = 0x4e62da25; // setVotingDelay(uint48,uint48)
        selectors[9] = 0x0f00c179; // setVotingPeriod(uint32,uint32)
        selectors[10] = 0x3932abb1; // votingDelay()
        selectors[11] = 0x02a251a3; // votingPeriod()
    }

    /// @notice Return selectors exposed by the recoveryFundLens facet.
    /// @return selectors recoveryFundLens facet selectors in deterministic order.
    function recoveryFundLensSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = 0x441a9bd5; // acquiredRecoveryShares(address)
        selectors[1] = 0xd08cc542; // assetRecoveryFund(address)
        selectors[2] = 0xbbcde2c6; // previewAssetRecoveryFundPurchase(address,uint256)
        selectors[3] = 0x001f229b; // recoveryFundTreasuryStatus()
        selectors[4] = 0x8b313110; // trustedRecoveryFundCore()
    }

    /// @notice Build facet specifications for this diamond cut.
    /// @param recoveryFund recoveryFund facet address.
    /// @param governorCore governorCore facet address.
    /// @param token token facet address.
    /// @param treasury treasury facet address.
    /// @param governorSettings governorSettings facet address.
    /// @param recoveryFundLens recoveryFundLens facet address.
    /// @return entries Named facet specifications with their expected selectors.
    function specs(
        address recoveryFund,
        address governorCore,
        address token,
        address treasury,
        address governorSettings,
        address recoveryFundLens
    ) internal pure returns (FacetSpec.Entry[] memory entries) {
        entries = new FacetSpec.Entry[](6);
        entries[0] = FacetSpec.Entry({name: "recoveryFund", facet: recoveryFund, selectors: recoveryFundSelectors()});
        entries[1] = FacetSpec.Entry({name: "governorCore", facet: governorCore, selectors: governorCoreSelectors()});
        entries[2] = FacetSpec.Entry({name: "token", facet: token, selectors: tokenSelectors()});
        entries[3] = FacetSpec.Entry({name: "treasury", facet: treasury, selectors: treasurySelectors()});
        entries[4] = FacetSpec.Entry({
            name: "governorSettings", facet: governorSettings, selectors: governorSettingsSelectors()
        });
        entries[5] = FacetSpec.Entry({
            name: "recoveryFundLens", facet: recoveryFundLens, selectors: recoveryFundLensSelectors()
        });
    }
}
