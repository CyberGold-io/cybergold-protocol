// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {LibQueueReadiness} from "../libraries/LibQueueReadiness.sol";
import {LibQueueEIP712} from "../libraries/LibQueueEIP712.sol";
import {LibQueueIndex} from "../libraries/LibQueueIndex.sol";
import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {ReentrancyGuardInitializable} from "diamond-infra/helpers/ReentrancyGuardInitializable.sol";
import {VaultFacet} from "./VaultFacet.sol";
import {QueueRequestBase} from "./QueueRequestBase.sol";

/// @notice Async redemption queue facet (ports CygldStakingQueue) owned by the diamond.
/// @dev Owns queue storage; hooks into VaultFacet for escrow/payout.
contract QueueFacet is Initializable, PausableUpgradeable, ReentrancyGuardInitializable, InitContext, QueueRequestBase {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.queue");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // ---------- Events ----------
    /// @notice Emitted when an open request becomes claimable.
    /// @param id Queue request identifier.
    /// @param controller Account whose aggregate claimable shares increase.
    /// @param owner Share owner recorded by the request.
    /// @param shares Escrowed Staking shares promoted to claimable status.
    event RequestPromoted(uint256 indexed id, address indexed controller, address indexed owner, uint256 shares);
    /// @notice Emitted when a complete request is claimed and its escrow shares are burned.
    /// @param id Queue request identifier.
    /// @param controller Queue controller whose claimable aggregate decreases.
    /// @param owner Share owner recorded by the request.
    /// @param shares Escrowed Staking shares burned for the payout.
    /// @param assetsOut Underlying asset amount paid out for redeemed vault shares.
    event RequestClaimed(
        uint256 indexed id, address indexed controller, address indexed owner, uint256 shares, uint256 assetsOut
    );
    /// @notice Emitted when part of a request is consumed by an aggregate redemption.
    /// @param id Queue request identifier.
    /// @param controller Queue controller whose claimable aggregate decreases.
    /// @param owner Share owner recorded by the request.
    /// @param sharesConsumed Escrowed Staking shares removed from the request.
    /// @param assetsOut Underlying asset amount paid out for redeemed vault shares.
    event RequestPartiallyClaimed(
        uint256 indexed id, address indexed controller, address indexed owner, uint256 sharesConsumed, uint256 assetsOut
    );
    /// @notice Emitted when ready boundary advanced.
    /// @param newBoundaryId New ready-boundary request id for queue processing.
    /// @param requestsAdvanced Number of queue requests advanced into the ready range.
    event ReadyBoundaryAdvanced(uint256 newBoundaryId, uint256 requestsAdvanced);
    /// @notice Emitted when a request is removed and its remaining escrow shares are returned.
    /// @param requestId Queue request identifier.
    /// @param controller Queue controller recorded by the request.
    /// @param owner Account receiving the returned Staking shares.
    /// @param shares Escrowed Staking shares returned to `owner`.
    event RequestCancelled(
        uint256 indexed requestId, address indexed controller, address indexed owner, uint256 shares
    );
    /// @notice Emitted when an expired request is removed and its escrow shares are returned.
    /// @param requestId Queue request identifier.
    /// @param controller Queue controller recorded by the request.
    /// @param owner Account receiving the returned Staking shares.
    /// @param shares Expired escrow shares returned to `owner`.
    event RequestExpired(uint256 indexed requestId, address indexed controller, address indexed owner, uint256 shares);
    /// @notice Emitted when defensive aggregate repair floors total claimable shares at zero.
    /// @param controller Queue controller involved in the inconsistent decrement.
    /// @param source Internal settlement-path code that attempted the decrement.
    /// @param delta Claimable-share decrement that exceeded the stored total.
    /// @param before Stored global claimable shares before the repair.
    event ClaimableTotalAnomaly(address indexed controller, uint8 source, uint256 delta, uint256 before);
    /// @notice Emitted when the claim window changes.
    /// @param previousExpiry Previously configured queue claim-expiry duration.
    /// @param newExpiry Replacement queue claim-expiry duration.
    event ClaimExpirySet(uint64 previousExpiry, uint64 newExpiry);
    /// @notice Emitted when the expired-head sweep bound changes.
    /// @param previousLimit Previous maximum expired head requests per operation.
    /// @param newLimit New maximum expired head requests per operation.
    event HeadSweepLimitSet(uint256 previousLimit, uint256 newLimit);
    /// @notice Emitted when the automatic-promotion bound changes.
    /// @param previousLimit Previous maximum automatically promoted requests.
    /// @param newLimit New maximum automatically promoted requests; zero disables promotion.
    event AutoProcessMaxSet(uint256 previousLimit, uint256 newLimit);

    // ---------- Errors ----------
    /// @notice The caller is neither the request controller/owner nor an authorized queue operator.
    error NotControllerOrOperator();
    /// @notice The selected request is absent, unready, or expired.
    error RequestNotReady();
    /// @notice The selected request is absent or has no remaining shares.
    error RequestNotCancellable();
    /// @notice A controller's aggregate claimable shares cannot cover the requested settlement.
    /// @param claimable Staking shares currently claimable by the controller.
    /// @param requested Staking shares required by the attempted settlement.
    error ClaimableInsufficient(uint256 claimable, uint256 requested);
    /// @notice Queue initialization received a zero underlying asset.
    error QueueNotConfigured();
    /// @notice Aggregate redemption could not consume every requested claimable share.
    /// @param controller Queue controller whose ready requests were consumed.
    /// @param remaining Requested Staking shares left unconsumed.
    error ReadySharesInvariant(address controller, uint256 remaining);
    /// @notice A queue-configuration caller lacks the Staking default-admin role.
    /// @param account Unauthorized caller.
    /// @param neededRole Staking role required by the operation.
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    /// @notice Initialize queue storage and EIP-712 domain. Must run via init coordinator.
    /// @param asset_ ERC20 asset accepted by the staking vault and queue.
    /// @param name_ Staking vault name used for the EIP-712 domain.
    /// @param claimExpiry_ Seconds after readiness before claims expire.
    /// @param headSweepLimit_ Maximum queue head items swept in one maintenance call.
    /// @param autoProcessMax_ Maximum queue items processed automatically by user flows.
    function initQueue(
        address asset_,
        string calldata name_,
        uint64 claimExpiry_,
        uint256 headSweepLimit_,
        uint256 autoProcessMax_
    ) external onlyInit {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        if (asset_ == address(0)) revert QueueNotConfigured();

        q.hashedName = keccak256(bytes(name_));
        q.hashedVersion = keccak256(bytes("1"));
        q.cachedChainId = block.chainid;
        q.domainSeparator = LibQueueEIP712.buildDomainSeparator(q, block.chainid);

        q.claimExpiry = claimExpiry_;
        q.headSweepLimit = headSweepLimit_;
        q.autoProcessMax = autoProcessMax_;
    }

    /// @dev Internal helper for prune epochs by expiry window.
    /// @param max Maximum number of queue entries or assets to process.
    function _pruneEpochsByExpiryWindow(uint256 max) internal {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        uint256 n = q.readyEpochs.length;
        if (n == 0) return;

        uint64 lastReadyAt = q.readyEpochs[n - 1].readyAt;
        uint64 cutoff = q.claimExpiry == 0
            ? lastReadyAt
            : (lastReadyAt > q.claimExpiry ? uint64(uint256(lastReadyAt) - uint256(q.claimExpiry)) : 0);

        uint256 pruned;
        while (q.epochsHead + 1 < n && pruned < max) {
            if (q.readyEpochs[q.epochsHead + 1].readyAt < cutoff) {
                delete q.readyEpochs[q.epochsHead];
                q.epochsHead++;
                pruned++;
            } else {
                break;
            }
        }
    }

    /// @dev Internal helper for rewind ready boundary.
    /// @param id Queue request identifier.
    function _rewindReadyBoundary(uint256 id) internal {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        if (q.readyBoundaryId != id) return;

        uint256 cursor = q.nodes[id].prevId;
        while (cursor != 0) {
            LibAppStorage.QueueNode storage prevNode = q.nodes[cursor];
            if (prevNode.shares != 0) {
                if (LibQueueReadiness.isReady(q, cursor) && !LibQueueReadiness.isExpired(q, cursor)) {
                    q.readyBoundaryId = cursor;
                    return;
                }
            }
            cursor = prevNode.prevId;
        }

        q.readyBoundaryId = 0;
    }

    // ========= Request flow =========

    /// @notice Escrow Staking shares and append an asynchronous redemption request.
    /// @param shares Exact Staking shares moved from `owner` into Diamond escrow.
    /// @param controller Account that controls settlement and owns the claimable aggregate; zero defaults to `owner`.
    /// @param owner Share holder funding the request.
    /// @return requestId Queue request identifier assigned by the queue.
    function requestRedeem(uint256 shares, address controller, address owner)
        public
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        if (shares == 0) revert ZeroAmount();
        if (owner != msg.sender && !LibAppStorage.appStorage().queue.isOwnerOperator[owner][msg.sender]) {
            revert NotControllerOrOperator();
        }
        requestId = _createRedeemRequest(shares, controller, owner, msg.sender);
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        if (q.autoProcessMax != 0) {
            _processGlobalList(q.autoProcessMax);
        }
    }

    // ========= Promotion / expiry =========

    /// @notice Promote affordable open requests to claimable status while Staking is unpaused.
    /// @param maxRequests Maximum number of requests to promote.
    /// @return processed Number of queue requests processed.
    function processQueue(uint256 maxRequests) external whenNotPaused nonReentrant returns (uint256 processed) {
        processed = _processGlobalList(maxRequests);
    }

    /// @notice Remove up to `max` consecutively expired requests from the queue head.
    /// @param max Maximum number of expired head requests to remove.
    /// @return purged Number of expired queue requests purged.
    function sweepExpiredHead(uint256 max) external whenNotPaused nonReentrant returns (uint256 purged) {
        if (max == 0) revert ZeroAmount();
        purged = _sweepExpiredHead(max);
    }

    /// @notice Remove the selected expired requests and return their escrow shares.
    /// @param requestIds Request identifiers checked for expiry and removal.
    /// @return expiredCount Number of expired queue requests found.
    function purgeExpired(uint256[] calldata requestIds)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 expiredCount)
    {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        if (q.claimExpiry == 0) return 0;
        uint256 len = requestIds.length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 id = requestIds[i];
            LibAppStorage.QueueNode storage nd = q.nodes[id];
            if (nd.owner == address(0) || nd.shares == 0) continue;
            if (!LibQueueReadiness.isExpired(q, id)) continue;

            uint256 nShares = nd.shares;
            uint256 c = q.claimableShares[nd.controller];
            if (c < nShares) continue;

            q.claimableShares[nd.controller] = c - nShares;
            _decreaseClaimableTotal(q, nd.controller, 5, nShares);

            LibQueueIndex.removeControllerRequest(q, nd.controller, id);
            _rewindReadyBoundary(id);
            LibQueueIndex.unlink(q, id);
            nd.shares = 0;
            VaultFacet(address(this)).returnShares(nd.owner, nShares);
            emit RequestExpired(id, nd.controller, nd.owner, nShares);
            expiredCount += 1;
        }
    }

    /// @dev Internal helper for process global list.
    /// @param max Maximum number of queue entries or assets to process.
    /// @return promoted Number of queue requests promoted to claimable state.
    function _processGlobalList(uint256 max) internal returns (uint256 promoted) {
        if (max == 0) revert ZeroAmount();
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;

        _sweepExpiredHead(q.headSweepLimit);

        address asset_ = IERC4626(address(this)).asset();
        uint256 custodyAssets = IERC20(asset_).balanceOf(address(this));
        uint256 lockedClaimableAssets =
            q.claimableSharesTotal == 0 ? 0 : IERC4626(address(this)).convertToAssets(q.claimableSharesTotal);
        if (custodyAssets <= lockedClaimableAssets) return 0;
        uint256 availableAssets = custodyAssets - lockedClaimableAssets;

        uint256 current = q.readyBoundaryId == 0 ? q.headId : q.nodes[q.readyBoundaryId].nextId;
        while (current != 0 && promoted < max) {
            uint256 id = current;
            LibAppStorage.QueueNode storage nd = q.nodes[id];
            current = nd.nextId;
            if (nd.shares == 0) {
                continue;
            }

            uint256 assetsNeeded = IERC4626(address(this)).convertToAssets(nd.shares);
            if (assetsNeeded > availableAssets) break;

            q.readyBoundaryId = id;

            uint64 ts = uint64(block.timestamp);
            uint256 eLen = q.readyEpochs.length;
            if (eLen > 0 && q.readyEpochs[eLen - 1].readyAt == ts) {
                q.readyEpochs[eLen - 1].boundaryId = id;
            } else {
                q.readyEpochs.push(LibAppStorage.ReadyEpoch({boundaryId: id, readyAt: ts}));
            }
            _pruneEpochsByExpiryWindow(2);

            q.claimableShares[nd.controller] += nd.shares;
            q.claimableSharesTotal += nd.shares;

            emit RequestPromoted(id, nd.controller, nd.owner, nd.shares);

            availableAssets -= assetsNeeded;
            promoted += 1;
        }
        if (promoted > 0) {
            emit ReadyBoundaryAdvanced(q.readyBoundaryId, promoted);
        }
    }

    /// @dev Sweep expired head.
    /// @param max Maximum number of queue entries or assets to process.
    /// @return purged Number of expired queue requests purged.
    function _sweepExpiredHead(uint256 max) internal returns (uint256 purged) {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        if (q.claimExpiry == 0) return 0;
        uint256 steps;
        while (steps < max) {
            uint256 id = q.headId;
            if (id == 0) break;
            if (q.readyBoundaryId == 0 || id > q.readyBoundaryId) break;

            if (!LibQueueReadiness.isExpired(q, id)) break;

            LibAppStorage.QueueNode storage nd = q.nodes[id];
            uint256 shares = nd.shares;

            LibQueueIndex.removeControllerRequest(q, nd.controller, id);

            if (shares != 0) {
                uint256 claimable = q.claimableShares[nd.controller];
                if (claimable >= shares) {
                    q.claimableShares[nd.controller] = claimable - shares;
                    _decreaseClaimableTotal(q, nd.controller, 4, shares);
                }
                nd.shares = 0;
                VaultFacet(address(this)).returnShares(nd.owner, shares);
                emit RequestExpired(id, nd.controller, nd.owner, shares);
            }

            _rewindReadyBoundary(id);
            LibQueueIndex.unlink(q, id);

            steps++;
        }
        return steps;
    }

    // ========= Claiming =========

    /// @notice Claim an entire ready request and send its underlying payout.
    /// @param requestId Queue request identifier.
    /// @param receiver Underlying recipient; zero defaults to the request owner.
    /// @return assetsOut Underlying asset amount paid out for redeemed vault shares.
    function claimRequest(uint256 requestId, address receiver)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 assetsOut)
    {
        assetsOut = _claimNode(requestId, receiver);
    }

    /// @notice Claim as much of a ready request as fits within an underlying-asset ceiling.
    /// @param requestId Queue request identifier.
    /// @param maxAssets Maximum underlying value to settle.
    /// @param receiver Underlying recipient; zero defaults to the request owner.
    /// @return assetsOut Underlying asset amount paid out for redeemed vault shares.
    function claimRequestUpTo(uint256 requestId, uint256 maxAssets, address receiver)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 assetsOut)
    {
        if (maxAssets == 0) revert ZeroAmount();
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        LibAppStorage.QueueNode storage nd = q.nodes[requestId];
        uint256 nodeShares = nd.shares;
        if (nodeShares == 0) revert RequestNotReady();

        address controller = nd.controller;
        if (msg.sender != controller && msg.sender != nd.owner && !q.isControllerOperator[controller][msg.sender]) {
            revert NotControllerOrOperator();
        }

        if (!LibQueueReadiness.isReady(q, requestId) || LibQueueReadiness.isExpired(q, requestId)) {
            revert RequestNotReady();
        }

        if (receiver == address(0)) receiver = nd.owner;

        uint256 sharesToConsume = IERC4626(address(this)).convertToShares(maxAssets);
        if (sharesToConsume == 0) revert ZeroAmount();
        if (sharesToConsume > nodeShares) sharesToConsume = nodeShares;

        uint256 claimable = q.claimableShares[controller];
        if (claimable < sharesToConsume) revert ClaimableInsufficient(claimable, sharesToConsume);
        q.claimableShares[controller] = claimable - sharesToConsume;
        _decreaseClaimableTotal(q, controller, 0, sharesToConsume);

        uint256 assetsBudget = IERC4626(address(this)).convertToAssets(sharesToConsume);
        _consumeNode(requestId, sharesToConsume, assetsBudget, true);

        assetsOut = VaultFacet(address(this)).payout(controller, nd.owner, receiver, sharesToConsume);
    }

    /// @notice Consume ready requests for a controller and redeem an exact aggregate share amount.
    /// @param shares Exact claimable Staking shares to burn.
    /// @param receiver Account receiving the underlying payout.
    /// @param owner Queue controller whose claimable requests are consumed.
    /// @return assetsOut Underlying asset amount paid out for redeemed vault shares.
    function redeem(uint256 shares, address receiver, address owner)
        public
        whenNotPaused
        nonReentrant
        returns (uint256 assetsOut)
    {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        address controller = owner;
        if (msg.sender != controller && !q.isControllerOperator[controller][msg.sender]) {
            revert NotControllerOrOperator();
        }

        _processGlobalList(q.autoProcessMax);
        _sweepExpiredHead(q.headSweepLimit);

        uint256 claimable = q.claimableShares[controller];
        if (claimable < shares) revert ClaimableInsufficient(claimable, shares);

        q.claimableShares[controller] = claimable - shares;
        _decreaseClaimableTotal(q, controller, 1, shares);

        uint256 assetsBudget = IERC4626(address(this)).convertToAssets(shares);
        uint256 remaining = _consumeReadyNodes(controller, shares, assetsBudget);
        if (remaining != 0) revert ReadySharesInvariant(controller, remaining);

        assetsOut = VaultFacet(address(this)).payout(controller, controller, receiver, shares);
    }

    /// @notice Withdraw an exact underlying amount by rounding up and redeeming the controller's ready shares.
    /// @param assets Exact underlying amount requested.
    /// @param receiver Account receiving the underlying payout.
    /// @param owner Queue controller whose claimable requests are consumed.
    /// @return sharesBurned Shares burned while finalizing a request.
    function withdraw(uint256 assets, address receiver, address owner)
        external
        whenNotPaused
        returns (uint256 sharesBurned)
    {
        sharesBurned = IERC4626(address(this)).convertToShares(assets);
        if (IERC4626(address(this)).convertToAssets(sharesBurned) < assets) {
            sharesBurned += 1;
        }
        redeem(sharesBurned, receiver, owner);
    }

    /// @dev Consume and pay one complete ready request.
    /// @param id Queue request identifier.
    /// @param receiver Underlying recipient; zero defaults to the request owner.
    /// @return assetsOut Underlying asset amount paid out for redeemed vault shares.
    function _claimNode(uint256 id, address receiver) internal returns (uint256 assetsOut) {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        LibAppStorage.QueueNode storage nd = q.nodes[id];
        uint256 shares = nd.shares;
        if (shares == 0) revert RequestNotReady();

        address controller = nd.controller;
        if (msg.sender != controller && msg.sender != nd.owner && !q.isControllerOperator[controller][msg.sender]) {
            revert NotControllerOrOperator();
        }

        if (!LibQueueReadiness.isReady(q, id) || LibQueueReadiness.isExpired(q, id)) revert RequestNotReady();

        uint256 claimable = q.claimableShares[controller];
        if (claimable < shares) revert ClaimableInsufficient(claimable, shares);
        q.claimableShares[controller] = claimable - shares;
        _decreaseClaimableTotal(q, controller, 0, shares);

        LibQueueIndex.removeControllerRequest(q, controller, id);
        _rewindReadyBoundary(id);
        LibQueueIndex.unlink(q, id);
        nd.shares = 0;

        if (receiver == address(0)) receiver = nd.owner;

        assetsOut = VaultFacet(address(this)).payout(controller, nd.owner, receiver, shares);
        emit RequestClaimed(id, controller, nd.owner, shares, assetsOut);
    }

    /// @notice Cancel one request and return its remaining escrow shares, including while paused.
    /// @dev Automatic promotion is skipped while paused so cancellation cannot advance unrelated requests.
    /// @param requestId Queue request identifier.
    /// @return sharesReturned Shares returned to the owner after cancellation or expiry.
    function cancelRequest(uint256 requestId) external nonReentrant returns (uint256 sharesReturned) {
        sharesReturned = _cancelNode(requestId);
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        if (!paused() && q.autoProcessMax != 0) {
            _processGlobalList(q.autoProcessMax);
        }
        return sharesReturned;
    }

    /// @dev Internal helper for cancel node.
    /// @param id Queue request identifier.
    /// @return sharesReturned Shares returned to the owner after cancellation or expiry.
    function _cancelNode(uint256 id) internal returns (uint256 sharesReturned) {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        LibAppStorage.QueueNode storage nd = q.nodes[id];
        uint256 shares = nd.shares;
        if (shares == 0) revert RequestNotCancellable();

        address controller = nd.controller;
        if (msg.sender != controller && msg.sender != nd.owner && !q.isControllerOperator[controller][msg.sender]) {
            revert NotControllerOrOperator();
        }

        bool readyFlag = LibQueueReadiness.isReady(q, id);
        if (readyFlag) {
            uint256 claimable = q.claimableShares[controller];
            if (claimable < shares) revert ClaimableInsufficient(claimable, shares);
            q.claimableShares[controller] = claimable - shares;
            _decreaseClaimableTotal(q, controller, 3, shares);
        }

        LibQueueIndex.removeControllerRequest(q, controller, id);
        _rewindReadyBoundary(id);
        LibQueueIndex.unlink(q, id);

        nd.shares = 0;
        sharesReturned = shares;
        VaultFacet(address(this)).returnShares(nd.owner, shares);

        emit RequestCancelled(id, controller, nd.owner, shares);
    }

    // ========= Consumption helpers =========

    /// @dev Consume a controller's ready requests until the target share amount or asset budget is exhausted.
    /// @param controller Queue controller whose requests are consumed.
    /// @param shares Exact claimable Staking shares requested for settlement.
    /// @param assetsBudget Underlying asset budget available for queue settlement.
    /// @return remainingShares Shares still outstanding after partial processing.
    function _consumeReadyNodes(address controller, uint256 shares, uint256 assetsBudget)
        internal
        returns (uint256 remainingShares)
    {
        if (shares == 0) return 0;
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        uint256 remainingSharesLocal = shares;
        uint256 allocatedAssets;

        uint256 i = 0;
        while (i < q.queryIds[controller].length && remainingSharesLocal > 0) {
            uint256 id = q.queryIds[controller][i];
            LibAppStorage.QueueNode storage nd = q.nodes[id];
            if (nd.shares == 0) {
                LibQueueIndex.removeControllerRequest(q, controller, id);
                continue;
            }

            if (!LibQueueReadiness.isReady(q, id)) {
                unchecked {
                    ++i;
                }
                continue;
            }
            if (LibQueueReadiness.isExpired(q, id)) {
                unchecked {
                    ++i;
                }
                continue;
            }

            uint256 reqShares = nd.shares;
            uint256 maxAvailable = assetsBudget > allocatedAssets ? assetsBudget - allocatedAssets : 0;

            if (reqShares <= remainingSharesLocal) {
                uint256 assetsAllocated = (remainingSharesLocal == reqShares)
                    ? maxAvailable
                    : IERC4626(address(this)).convertToAssets(reqShares);
                if (assetsAllocated > maxAvailable) assetsAllocated = maxAvailable;

                remainingSharesLocal -= reqShares;
                nd.shares = 0;
                _rewindReadyBoundary(id);
                LibQueueIndex.unlink(q, id);
                LibQueueIndex.removeControllerRequest(q, controller, id);
                emit RequestClaimed(id, nd.controller, nd.owner, reqShares, assetsAllocated);
                allocatedAssets += assetsAllocated;
            } else {
                uint256 consumedShares = remainingSharesLocal;
                remainingSharesLocal = 0;
                nd.shares = reqShares - consumedShares;
                uint256 partialAssets = maxAvailable;
                allocatedAssets += partialAssets;
                emit RequestPartiallyClaimed(id, nd.controller, nd.owner, consumedShares, partialAssets);
            }
        }
        return remainingSharesLocal;
    }

    /// @dev Consume node.
    /// @param id Queue request identifier.
    /// @param sharesToConsume Vault shares to consume from queued redemption requests.
    /// @param assetsBudgetRemaining Underlying asset budget remaining after prior queue settlements.
    /// @param lastAllBudget Whether the previous request consumed all available asset budget.
    /// @return assetsAllocated Assets allocated to satisfy queue requests.
    /// @return fullyConsumed Whether the supplied asset budget was fully consumed.
    function _consumeNode(uint256 id, uint256 sharesToConsume, uint256 assetsBudgetRemaining, bool lastAllBudget)
        internal
        returns (uint256 assetsAllocated, bool fullyConsumed)
    {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        LibAppStorage.QueueNode storage nd = q.nodes[id];
        uint256 reqShares = nd.shares;
        if (reqShares == 0 || sharesToConsume == 0) return (0, false);

        if (!LibQueueReadiness.isReady(q, id) || LibQueueReadiness.isExpired(q, id)) revert RequestNotReady();

        fullyConsumed = sharesToConsume >= reqShares;
        uint256 sharesUsed = fullyConsumed ? reqShares : sharesToConsume;
        assetsAllocated = lastAllBudget ? assetsBudgetRemaining : IERC4626(address(this)).convertToAssets(sharesUsed);

        if (fullyConsumed) {
            nd.shares = 0;
            _rewindReadyBoundary(id);
            LibQueueIndex.unlink(q, id);
            LibQueueIndex.removeControllerRequest(q, nd.controller, id);
            emit RequestClaimed(id, nd.controller, nd.owner, sharesUsed, assetsAllocated);
        } else {
            nd.shares = reqShares - sharesUsed;
            emit RequestPartiallyClaimed(id, nd.controller, nd.owner, sharesUsed, assetsAllocated);
        }
    }

    /// @dev Decrease total claimable shares, preserving anomaly reporting for corrupted totals.
    /// @param q Queue storage pointer being updated.
    /// @param controller Controller whose claimable balance is being decreased.
    /// @param code Anomaly code emitted if aggregate accounting is corrupt.
    /// @param shares Share amount removed from the aggregate claimable total.
    function _decreaseClaimableTotal(
        LibAppStorage.QueueStorage storage q,
        address controller,
        uint8 code,
        uint256 shares
    ) internal {
        uint256 totalBefore = q.claimableSharesTotal;
        if (totalBefore >= shares) {
            q.claimableSharesTotal = totalBefore - shares;
        } else {
            emit ClaimableTotalAnomaly(controller, code, shares, totalBefore);
            q.claimableSharesTotal = 0;
        }
    }

    // ========= Admin knobs =========

    /// @notice Set the elapsed time after promotion during which a request remains claimable.
    /// @param expirySeconds Queue claim-expiry duration in seconds.
    function setClaimExpiry(uint64 expirySeconds) external {
        _requireAdmin();
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        uint64 previous = q.claimExpiry;
        if (previous == expirySeconds) return;
        q.claimExpiry = expirySeconds;
        emit ClaimExpirySet(previous, expirySeconds);
    }

    /// @notice Set the maximum number of expired head requests swept by one queue operation.
    /// @param newLimit Replacement expired-head sweep bound.
    function setHeadSweepLimit(uint256 newLimit) external {
        _requireAdmin();
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        uint256 previous = q.headSweepLimit;
        if (previous == newLimit) return;
        q.headSweepLimit = newLimit;
        emit HeadSweepLimitSet(previous, newLimit);
    }

    /// @notice Set the maximum requests automatically promoted after an eligible user flow.
    /// @param newLimit Replacement automatic-promotion bound; zero disables automatic promotion.
    function setAutoProcessMax(uint256 newLimit) external {
        _requireAdmin();
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        uint256 previous = q.autoProcessMax;
        if (previous == newLimit) return;
        q.autoProcessMax = newLimit;
        emit AutoProcessMaxSet(previous, newLimit);
    }

    /// @dev Require admin.
    function _requireAdmin() internal view {
        if (!IAccessControl(address(this)).hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, DEFAULT_ADMIN_ROLE);
        }
    }
}
