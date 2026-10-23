// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {LibQueueReadiness} from "../libraries/LibQueueReadiness.sol";
import {InitContext} from "diamond-infra/helpers/InitContext.sol";
import {ISleeve} from "../sleeves/ISleeve.sol";
import {TokenFacet} from "./TokenFacet.sol";
import {VaultFacet} from "./VaultFacet.sol";
import {LibStakingLaunch} from "../libraries/LibStakingLaunch.sol";

/// @notice Read-only lens facet aggregating views across queue, vault, and fund manager registry.
contract LensFacet is InitContext {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.lens");

    /// @notice Current Staking asset, pause state, and accounting health.
    struct SystemState {
        address asset;
        bool paused;
        bool fundManagerHealthy;
    }

    /// @notice User-facing state of one asynchronous redemption request.
    struct QueueRequestView {
        uint256 id;
        address controller;
        address owner;
        uint256 shares;
        bool ready;
        bool expired;
        uint64 readyAt;
    }

    /// @notice Queue boundaries, limits, sequence, and claimable-share totals.
    struct QueueAggregates {
        uint256 headId;
        uint256 tailId;
        uint256 readyBoundaryId;
        uint64 claimExpiry;
        uint256 headSweepLimit;
        uint256 autoProcessMax;
        uint64 seqInBlock;
        uint256 claimableController;
        uint256 claimableTotal;
    }

    /// @notice Sleeve principal, current assets, profit or loss, and approval state.
    struct SleevePosition {
        address sleeve;
        address asset;
        uint256 principalAssets;
        uint256 totalAssets;
        int256 pnl;
        bool approved;
    }

    /// @notice Return the terminal launch phase and authenticated finalization hash.
    /// @dev This selector is installed only as part of the committed production finalization.
    /// @return phase Current atomic-launch phase.
    /// @return finalizationHash Hash of the exact candidate that finalized the Diamond.
    function stakingLaunchState() external view returns (LibStakingLaunch.Phase phase, bytes32 finalizationHash) {
        LibStakingLaunch.Layout storage launch = LibStakingLaunch.getLayout();
        return (launch.phase, launch.finalizationHash);
    }

    /// @notice Return the Staking underlying, global pause flag, and last recorded fund-manager health.
    /// @return s Current asset, pause policy, and fund-manager health.
    function systemState() external view returns (SystemState memory s) {
        LibAppStorage.AppStorage storage st = LibAppStorage.appStorage();
        s.asset = TokenFacet(address(this)).asset();
        s.fundManagerHealthy = st.vault.fundManagerHealthy;
        s.paused = VaultFacet(address(this)).paused();
    }

    /// @notice Return queue boundaries, limits, sequence, and global/controller claimable totals.
    /// @param controller Queue controller whose claimable-share total is included.
    /// @return agg Current queue aggregate snapshot.
    function queueAggregates(address controller) external view returns (QueueAggregates memory agg) {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        agg.headId = q.headId;
        agg.tailId = q.tailId;
        agg.readyBoundaryId = q.readyBoundaryId;
        agg.claimExpiry = q.claimExpiry;
        agg.headSweepLimit = q.headSweepLimit;
        agg.autoProcessMax = q.autoProcessMax;
        agg.seqInBlock = q.seqInBlock;
        agg.claimableController = q.claimableShares[controller];
        agg.claimableTotal = q.claimableSharesTotal;
    }

    /// @notice Return all open request identifiers indexed to a queue controller.
    /// @param controller Queue controller to query.
    /// @return ids Open request identifiers in controller-index order.
    function controllerOpenQueries(address controller) external view returns (uint256[] memory ids) {
        return _controllerOpenQueries(controller);
    }

    /// @notice Return a bounded page of open request identifiers indexed to a queue controller.
    /// @param controller Queue controller to query.
    /// @param start Zero-based index of the first controller request to return.
    /// @param limit Maximum request identifiers returned.
    /// @return ids Selected open request identifiers in controller-index order.
    /// @return total Total open requests indexed to `controller`.
    /// @return nextStart Cursor immediately after the returned page.
    function controllerOpenQueries(address controller, uint256 start, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total, uint256 nextStart)
    {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        total = q.queryIds[controller].length;
        if (start >= total) {
            return (new uint256[](0), total, start);
        }
        uint256 remaining = total - start;
        uint256 n = limit;
        if (n > remaining) n = remaining;
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = q.queryIds[controller][start + i];
        }
        nextStart = start + n;
    }

    /// @notice Return the promotion timestamp retained for a request.
    /// @param id Queue request identifier.
    /// @return Timestamp when the queue request becomes claimable.
    function readyAtFor(uint256 id) external view returns (uint64) {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        return LibQueueReadiness.readyAt(q, id);
    }

    /// @notice Decode a request's creation timestamp from its identifier.
    /// @param id Queue request identifier.
    /// @return Timestamp encoded in the queue request id.
    function createdAt(uint256 id) external pure returns (uint64) {
        return _createdAt(id);
    }

    /// @notice Return whether an existing request is within the promoted ready boundary.
    /// @param id Queue request identifier.
    /// @return Whether the queue request is ready to claim.
    function isReady(uint256 id) external view returns (bool) {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        return LibQueueReadiness.isReady(q, id);
    }

    /// @notice Return whether a ready request has passed its configured claim window.
    /// @param id Queue request identifier.
    /// @return Whether the queue request claim window has expired.
    function isExpired(uint256 id) external view returns (bool) {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        return LibQueueReadiness.isExpired(q, id);
    }

    /// @notice Return the Staking shares currently claimable across every controller.
    /// @return Total vault shares claimable from processed queue requests.
    function claimableSharesTotal() external view returns (uint256) {
        return LibAppStorage.appStorage().queue.claimableSharesTotal;
    }

    /// @notice Return the aggregate Staking shares currently claimable by a controller.
    /// @param controller Queue controller to query.
    /// @return Processed Staking shares claimable by `controller`.
    function claimableShares(address controller) external view returns (uint256) {
        return LibAppStorage.appStorage().queue.claimableShares[controller];
    }

    /// @notice Return the first linked request identifier, or zero for an empty queue.
    /// @return Current queue head request id.
    function headId() external view returns (uint256) {
        return LibAppStorage.appStorage().queue.headId;
    }

    /// @notice Return the final linked request identifier, or zero for an empty queue.
    /// @return Current queue tail request id.
    function tailId() external view returns (uint256) {
        return LibAppStorage.appStorage().queue.tailId;
    }

    /// @notice Return the highest linked request identifier promoted to claimable status.
    /// @return Highest queue request id marked ready.
    function readyBoundaryId() external view returns (uint256) {
        return LibAppStorage.appStorage().queue.readyBoundaryId;
    }

    /// @notice Return the elapsed seconds after promotion during which requests remain claimable.
    /// @return Queue claim expiry duration in seconds.
    function claimExpiry() external view returns (uint64) {
        return LibAppStorage.appStorage().queue.claimExpiry;
    }

    /// @notice Return the maximum expired head requests swept by one queue operation.
    /// @return Maximum queue head entries swept in one maintenance pass.
    function headSweepLimit() external view returns (uint256) {
        return LibAppStorage.appStorage().queue.headSweepLimit;
    }

    /// @notice Return the maximum requests automatically promoted by an eligible user flow.
    /// @return Maximum queue requests auto-processed in one call.
    function autoProcessMax() external view returns (uint256) {
        return LibAppStorage.appStorage().queue.autoProcessMax;
    }

    /// @notice Return the sequence assigned to the latest request created in the current block.
    /// @return Sequence number used to order queue requests within a block.
    function seqInBlock() external view returns (uint64) {
        return LibAppStorage.appStorage().queue.seqInBlock;
    }

    /// @notice Return a controller's aggregate claimable shares for the ERC-7540 aggregate sentinel.
    /// @dev Only `requestId == 0` denotes the aggregate request; every other identifier returns zero.
    /// @param requestId Aggregate request identifier, which must be zero.
    /// @param controller Queue controller to query.
    /// @return shares Aggregate processed Staking shares claimable by `controller`.
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares) {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        if (requestId == 0) return q.claimableShares[controller];
        return 0;
    }

    /// @notice Introspect a specific queue request.
    /// @param id Queue request id to inspect.
    /// @return controller Controller address associated with the request.
    /// @return owner Owner address associated with the request.
    /// @return shares Share amount recorded on the request.
    /// @return createdAtTs Timestamp when the request was created.
    /// @return readyAtTs Timestamp when the request becomes ready.
    /// @return ready Whether the request is ready to claim.
    /// @return expired Whether the request has passed its claim expiry.
    /// @return assetsAtCurrentPrice Current asset value represented by the queued shares.
    /// @return paused_ Whether the staking vault is currently paused.
    /// @return healthy Compatibility health field; currently always true and not a live fund-manager health probe.
    /// @return claimable Whether the request can be claimed now.
    function viewRequest(uint256 id)
        external
        view
        returns (
            address controller,
            address owner,
            uint256 shares,
            uint64 createdAtTs,
            uint64 readyAtTs,
            bool ready,
            bool expired,
            uint256 assetsAtCurrentPrice,
            bool paused_,
            bool healthy,
            bool claimable
        )
    {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        LibAppStorage.QueueNode storage nd = q.nodes[id];
        controller = nd.controller;
        owner = nd.owner;
        shares = nd.shares;
        createdAtTs = _createdAt(id);
        readyAtTs = LibQueueReadiness.readyAt(q, id);
        ready = LibQueueReadiness.isReady(q, id);
        expired = LibQueueReadiness.isExpired(q, id);
        assetsAtCurrentPrice = shares == 0 ? 0 : IERC4626(address(this)).convertToAssets(shares);
        paused_ = VaultFacet(address(this)).paused();
        healthy = true; // fund manager health check not proxied; treat as healthy in this view
        claimable = ready && !expired && !paused_;
    }

    /// @notice Return complete views for every open request indexed to a controller.
    /// @param controller Queue controller to query.
    /// @return out All open requests indexed for the controller, in index order.
    function queueRequests(address controller) external view returns (QueueRequestView[] memory out) {
        uint256[] memory ids = _controllerOpenQueries(controller);
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        out = new QueueRequestView[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = ids[i];
            LibAppStorage.QueueNode storage n = q.nodes[id];
            uint64 readyAtTs = LibQueueReadiness.readyAt(q, id);
            bool ready = LibQueueReadiness.isReady(q, id);
            bool expired = LibQueueReadiness.isExpired(q, id);
            out[i] = QueueRequestView({
                id: id,
                controller: n.controller,
                owner: n.owner,
                shares: n.shares,
                ready: ready,
                expired: expired,
                readyAt: readyAtTs
            });
        }
    }

    /// @notice Return current principal, value, PnL, and approval for every registered Sleeve.
    /// @return positions Sleeve snapshots in registry insertion order.
    function sleevePositions() external view returns (SleevePosition[] memory positions) {
        LibAppStorage.FundManagerStorage storage fm = LibAppStorage.appStorage().fm;
        address[] memory sleevesList = fm.registeredSleeves;
        positions = new SleevePosition[](sleevesList.length);
        for (uint256 i = 0; i < sleevesList.length; ++i) {
            address sleeve = sleevesList[i];
            LibAppStorage.SleeveConfig memory cfg = fm.sleeves[sleeve];
            uint256 total = cfg.registered ? ISleeve(sleeve).totalAssets() : 0;
            int256 pnl;
            if (total >= cfg.principalAssets) {
                // casting to int256 is safe because total >= principalAssets in this branch
                // forge-lint: disable-next-line(unsafe-typecast)
                pnl = int256(total - cfg.principalAssets);
            } else {
                // casting to int256 is safe because total < principalAssets in this branch
                // forge-lint: disable-next-line(unsafe-typecast)
                pnl = -int256(cfg.principalAssets - total);
            }
            positions[i] = SleevePosition({
                sleeve: sleeve,
                asset: cfg.asset,
                principalAssets: cfg.principalAssets,
                totalAssets: total,
                pnl: pnl,
                approved: cfg.approved
            });
        }
    }

    /// @dev Copy all open request identifiers indexed to a controller.
    /// @param controller Queue controller to query.
    /// @return ids Open request identifiers in controller-index order.
    function _controllerOpenQueries(address controller) internal view returns (uint256[] memory ids) {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        uint256 len = q.queryIds[controller].length;
        ids = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            ids[i] = q.queryIds[controller][i];
        }
    }

    /// @dev Decode the creation timestamp stored in a request identifier's high 64 bits.
    /// @param id Queue request identifier.
    /// @return Creation timestamp encoded in the high 64 bits of the request id.
    function _createdAt(uint256 id) internal pure returns (uint64) {
        // casting to uint64 is safe because ids encode timestamp in upper 64 bits
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(id >> 64);
    }
}
