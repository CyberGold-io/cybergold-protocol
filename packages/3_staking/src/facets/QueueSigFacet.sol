// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {ReentrancyGuardInitializable} from "diamond-infra/helpers/ReentrancyGuardInitializable.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {LibQueueEIP712} from "../libraries/LibQueueEIP712.sol";
import {QueueRequestBase} from "./QueueRequestBase.sol";

/// @notice Signature-based queue entrypoint and EIP-712 helpers.
contract QueueSigFacet is PausableUpgradeable, ReentrancyGuardInitializable, QueueRequestBase {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.queue.sig");

    /// @notice EIP-712 typehash for signed redeem requests.
    bytes32 public constant REQUEST_REDEEM_TYPEHASH =
        keccak256("RequestRedeem(address owner,address controller,uint256 shares,uint256 nonce,uint256 deadline)");

    /// @notice The signed request deadline is earlier than the current block timestamp.
    error SignatureExpired();
    /// @notice The supplied signature does not recover to the declared share owner.
    error InvalidSigner();
    /// @notice The supplied signature was created for the immediately preceding, already-consumed nonce.
    error InvalidNonce();

    /// @notice Return the next EIP-712 redemption-request nonce for an owner.
    /// @param owner Share owner whose nonce is queried.
    /// @return Current signed-request nonce for `owner`.
    function nonces(address owner) external view returns (uint256) {
        return LibAppStorage.appStorage().queue.nonces[owner];
    }

    /// @notice EIP-712 domain separator (for off-chain signers/tests).
    /// @return EIP-712 domain separator for this staking diamond and chain.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        return LibQueueEIP712.domainSeparator(q);
    }

    /// @notice Relay an owner's signed instruction to escrow shares and append a redemption request.
    /// @param shares Exact Staking shares moved from `owner` into Diamond escrow.
    /// @param controller Account controlling settlement; zero defaults to `owner`.
    /// @param owner Share holder who signed and funds the request.
    /// @param deadline Last timestamp at which the signed request remains valid.
    /// @param v ECDSA recovery id from the queue signature.
    /// @param r ECDSA r value from the queue signature.
    /// @param s ECDSA s value from the queue signature.
    /// @return requestId Queue request identifier assigned by the queue.
    function requestRedeemBySig(
        uint256 shares,
        address controller,
        address owner,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused nonReentrant returns (uint256 requestId) {
        if (shares == 0) revert ZeroAmount();
        // The signed EIP-712 deadline is explicitly denominated in timestamp seconds.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert SignatureExpired();

        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        uint256 currentNonce = q.nonces[owner];
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(REQUEST_REDEEM_TYPEHASH, owner, controller, shares, currentNonce, deadline)), q
        );
        address signer = ECDSA.recover(digest, v, r, s);
        if (signer != owner) {
            if (currentNonce != 0) {
                digest = _hashTypedDataV4(
                    keccak256(
                        abi.encode(REQUEST_REDEEM_TYPEHASH, owner, controller, shares, currentNonce - 1, deadline)
                    ),
                    q
                );
                if (ECDSA.recover(digest, v, r, s) == owner) revert InvalidNonce();
            }
            revert InvalidSigner();
        }
        _useNonce(owner);
        requestId = _createRedeemRequest(shares, controller, owner, msg.sender);
    }

    /// @dev Consume and return an owner's current signed-request nonce.
    /// @param owner Share owner whose nonce is consumed.
    /// @return current Nonce embedded in the request being processed.
    function _useNonce(address owner) internal returns (uint256 current) {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        current = q.nonces[owner];
        unchecked {
            q.nonces[owner] = current + 1;
        }
    }

    /// @dev Hash typed data v4.
    /// @param structHash EIP-712 struct hash before domain separation.
    /// @param q Queue storage pointer used for request accounting.
    /// @return EIP-712 digest for the typed queue payload.
    function _hashTypedDataV4(bytes32 structHash, LibAppStorage.QueueStorage storage q)
        internal
        view
        returns (bytes32)
    {
        return MessageHashUtils.toTypedDataHash(LibQueueEIP712.domainSeparator(q), structHash);
    }
}
