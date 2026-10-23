// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

/// @notice Narrow Core ABI for generic current-state CYGLD redemption.
/// @dev ERC-20 amounts use each token's raw units. ERC-1155 recovery outputs use project-defined
///      asset-native participation units; they are not claims on an amount of CYGLD.
///      Exact-input calculations floor every output, while exact-output inversion ceilings the
///      net CYGLD requirement before recomputing the ordinary floor-rounded output vector.
interface ICoreRedemption {
    /// @notice Token standard used by one Core redemption output.
    enum TokenKind {
        /// @notice Fungible reserve-token output using that token's raw base units.
        ERC20,
        /// @notice Core recovery-share output using the underlying asset's native precision.
        ERC1155
    }

    /// @notice One realized or projected Core redemption output.
    struct TokenAmount {
        /// @notice Token standard used by this structural output leg.
        TokenKind kind;
        /// @notice ERC-20 reserve token or the Core ERC-1155 contract.
        address token;
        /// @notice Zero for ERC-20 or the asset-derived recovery-share identifier for ERC-1155.
        uint256 id;
        /// @notice ERC-20 raw units or asset-native raw recovery participation units.
        uint256 amount;
    }

    /// @notice Caller-bound identity and minimum for one Core redemption output.
    struct TokenMinimum {
        /// @notice Token standard required at this canonical position.
        TokenKind kind;
        /// @notice Token contract required at this canonical position.
        address token;
        /// @notice Token identifier required at this canonical position.
        uint256 id;
        /// @notice Minimum ERC-20 raw units or asset-native recovery participation units accepted.
        uint256 minimumAmount;
    }

    /// @notice Complete Core redemption calculation and outcome.
    struct RedemptionQuote {
        /// @notice Exact gross CYGLD input.
        uint256 grossCygldIn;
        /// @notice Fee-adjusted CYGLD input applied to the output calculation.
        uint256 netCygldIn;
        /// @notice CYGLD protocol fee charged by the redemption.
        uint256 protocolFeeCygld;
        /// @notice Complete canonical ERC-20-then-ERC-1155 vector, including zero-valued structural legs.
        TokenAmount[] outputs;
    }

    /// @notice Signals that a caller-bound redemption output vector has the wrong length.
    /// @param providedLength Number of output descriptors supplied by the caller.
    /// @param actualLength Number of outputs in the current canonical vector.
    error RedemptionOutputsLengthMismatch(uint256 providedLength, uint256 actualLength);

    /// @notice Signals that one caller-bound redemption descriptor differs from current state.
    /// @param index Canonical output position whose descriptor differs.
    /// @param providedKind Token standard supplied by the caller.
    /// @param providedToken Token contract supplied by the caller.
    /// @param providedId Token identifier supplied by the caller.
    /// @param actualKind Current canonical token standard.
    /// @param actualToken Current canonical token contract.
    /// @param actualId Current canonical token identifier.
    error RedemptionOutputDescriptorMismatch(
        uint256 index,
        TokenKind providedKind,
        address providedToken,
        uint256 providedId,
        TokenKind actualKind,
        address actualToken,
        uint256 actualId
    );

    /// @notice Signals that one calculated redemption output is below its caller-defined minimum.
    /// @param index Canonical output position whose amount is too small.
    /// @param minimum Minimum amount accepted by the caller.
    /// @param actual Current calculated amount.
    error RedemptionOutputBelowMinimum(uint256 index, uint256 minimum, uint256 actual);

    /// @notice Signals that a positive CYGLD redemption would produce no realizable output.
    error RedemptionNoOutput();

    /// @notice Emitted after one complete mixed Core redemption settles.
    /// @param caller Account whose CYGLD was redeemed.
    /// @param reserve Core reserve address that delivered ERC-20 outputs.
    /// @param treasury Treasury that received the CYGLD protocol fee.
    /// @param grossCygldIn Exact CYGLD amount removed from the caller.
    /// @param netCygldIn Fee-adjusted CYGLD amount applied to redemption.
    /// @param protocolFeeCygld CYGLD protocol fee minted to the treasury.
    /// @param kinds Token standards in complete canonical output order.
    /// @param tokens Token contracts in complete canonical output order.
    /// @param ids Token identifiers in complete canonical output order.
    /// @param amounts Realized amounts in complete canonical output order.
    event Redeemed(
        address indexed caller,
        address indexed reserve,
        address indexed treasury,
        uint256 grossCygldIn,
        uint256 netCygldIn,
        uint256 protocolFeeCygld,
        TokenKind[] kinds,
        address[] tokens,
        uint256[] ids,
        uint256[] amounts
    );

    /// @notice Redeem CYGLD against live terms into the complete canonical mixed output vector.
    /// @param grossCygldIn Exact gross CYGLD input burned by the caller.
    /// @return result Realized current-state redemption amounts and protocol fee.
    function redeem(uint256 grossCygldIn) external returns (RedemptionQuote memory result);

    /// @notice Redeem CYGLD while binding every canonical output descriptor and minimum.
    /// @param grossCygldIn Exact gross CYGLD input burned by the caller.
    /// @param expectedOutputs Complete canonical output identities and per-output minima.
    /// @return result Realized current-state redemption amounts and protocol fee.
    function safeRedeem(uint256 grossCygldIn, TokenMinimum[] calldata expectedOutputs)
        external
        returns (RedemptionQuote memory result);

    /// @notice Preview the complete canonical mixed output vector for an exact gross CYGLD input.
    /// @param grossCygldIn Exact gross CYGLD input to quote.
    /// @return quote Current projected outputs and protocol fee.
    function previewRedeemExactIn(uint256 grossCygldIn) external view returns (RedemptionQuote memory quote);

    /// @notice Preview the minimum gross CYGLD input satisfying a complete canonical minimum vector.
    /// @param minimumOutputs Complete canonical output identities and per-output minima.
    /// @return quote Minimum gross input and its current projected outputs and protocol fee.
    function previewRedeemExactOut(TokenMinimum[] calldata minimumOutputs)
        external
        view
        returns (RedemptionQuote memory quote);
}
