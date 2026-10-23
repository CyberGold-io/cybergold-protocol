// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {LibAppStorage} from "../../src/diamond/LibAppStorage.sol";
import {LibQueueReadiness} from "../../src/libraries/LibQueueReadiness.sol";
import {CustodyFacet} from "../../src/facets/CustodyFacet.sol";
import {FundManagerFacet, IStakingVault4626} from "../../src/facets/FundManagerFacet.sol";
import {LensFacet} from "../../src/facets/LensFacet.sol";
import {QueueFacet} from "../../src/facets/QueueFacet.sol";
import {QueueSigFacet} from "../../src/facets/QueueSigFacet.sol";
import {SleeveRegistryFacet} from "../../src/facets/SleeveRegistryFacet.sol";
import {VaultFacet} from "../../src/facets/VaultFacet.sol";
import {SleeveBase} from "../../src/sleeves/SleeveBase.sol";
import {ISleeve} from "../../src/sleeves/ISleeve.sol";
import {MockStakingVault} from "staking-mocks/MockStakingVault.sol";

contract BranchCustodyHarness is CustodyFacet {
    function enterInit() external {
        bytes32 slot = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
        assembly {
            sstore(slot, 1)
        }
    }
}

contract BranchFundManagerHarness is FundManagerFacet {
    address internal testAsset;
    uint256 internal testTotalAssets;
    uint256 internal testClaimableAssets;

    function enterInit() external {
        bytes32 slot = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
        assembly {
            sstore(slot, 1)
        }
    }

    function grantAllocator(address account) external {
        _grantRole(ALLOCATOR_ROLE, account);
    }

    function setCoreState(address cygld, address stakingVault, address custody, address treasury) external {
        LibAppStorage.FundManagerStorage storage fm = LibAppStorage.appStorage().fm;
        fm.cygld = cygld;
        fm.treasury = treasury;
        testAsset = MockStakingVault(stakingVault).asset();
        testTotalAssets = MockStakingVault(stakingVault).totalAssets();
        testClaimableAssets = MockStakingVault(stakingVault).claimableAssets();
        custody;
    }

    function asset() external view returns (address) {
        return testAsset;
    }

    function totalAssets() external view returns (uint256) {
        return testTotalAssets;
    }

    function liquidityBreakdown() external view returns (IStakingVault4626.LiquidityBreakdown memory bd, bool healthy) {
        bd.claimableAssets = testClaimableAssets;
        return (bd, true);
    }

    function setSleeve(address sleeve, address sleeveAsset, bool registered, bool approved, uint256 principal)
        external
    {
        LibAppStorage.FundManagerStorage storage fm = LibAppStorage.appStorage().fm;
        LibAppStorage.SleeveConfig storage cfg = fm.sleeves[sleeve];
        if (!cfg.registered && registered) {
            fm.registeredSleeves.push(sleeve);
        }
        cfg.registered = registered;
        cfg.approved = approved;
        cfg.asset = sleeveAsset;
        cfg.principalAssets = principal;
        fm.principalPerAsset[sleeveAsset] = principal;
    }
}

contract BranchQueueHarness is QueueFacet {
    address public assetValue;
    bool public zeroConvertToShares;

    function enterInit() external {
        bytes32 slot = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
        assembly {
            sstore(slot, 1)
        }
    }

    function setPaused(bool paused_) external {
        if (paused_) _pause();
        else _unpause();
    }

    function setAsset(address asset_) external {
        assetValue = asset_;
    }

    function setZeroConvertToShares(bool value) external {
        zeroConvertToShares = value;
    }

    function rawSetClaimExpiry(uint64 expiry) external {
        LibAppStorage.appStorage().queue.claimExpiry = expiry;
    }

    function rawSetHeadSweepLimit(uint256 limit) external {
        LibAppStorage.appStorage().queue.headSweepLimit = limit;
    }

    function rawSetAutoProcessMax(uint256 max) external {
        LibAppStorage.appStorage().queue.autoProcessMax = max;
    }

    function setReadyBoundary(uint256 id) external {
        LibAppStorage.appStorage().queue.readyBoundaryId = id;
    }

    function setClaimable(address controller, uint256 shares) external {
        LibAppStorage.appStorage().queue.claimableShares[controller] = shares;
    }

    function setClaimableTotal(uint256 shares) external {
        LibAppStorage.appStorage().queue.claimableSharesTotal = shares;
    }

    function setHeadTail(uint256 head, uint256 tail) external {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        q.headId = head;
        q.tailId = tail;
    }

    function setNode(uint256 id, address controller, address owner, uint256 shares, uint256 prevId, uint256 nextId)
        external
    {
        LibAppStorage.QueueNode storage nd = LibAppStorage.appStorage().queue.nodes[id];
        nd.controller = controller;
        nd.owner = owner;
        nd.shares = shares;
        nd.prevId = prevId;
        nd.nextId = nextId;
    }

    function pushReadyEpoch(uint256 boundaryId, uint64 readyAt_) external {
        LibAppStorage.appStorage().queue.readyEpochs
            .push(LibAppStorage.ReadyEpoch({boundaryId: boundaryId, readyAt: readyAt_}));
    }

    function addQuery(address controller, uint256 id) external {
        LibAppStorage.QueueStorage storage q = LibAppStorage.appStorage().queue;
        q.queryIndex[controller][id] = q.queryIds[controller].length;
        q.queryIds[controller].push(id);
    }

    function asset() external view returns (address) {
        return assetValue;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return zeroConvertToShares ? 0 : assets;
    }

    function escrowFrom(address, uint256) external {}

    function returnShares(address, uint256) external {}

    function payout(address, address, address, uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function exposedReadyAtFor(uint256 id) external view returns (uint64) {
        return LibQueueReadiness.readyAt(LibAppStorage.appStorage().queue, id);
    }

    function exposedPrune(uint256 max) external {
        _pruneEpochsByExpiryWindow(max);
    }

    function exposedSweepExpiredHead(uint256 max) external returns (uint256) {
        return _sweepExpiredHead(max);
    }

    function exposedConsumeReadyNodes(address controller, uint256 shares, uint256 assetsBudget)
        external
        returns (uint256)
    {
        return _consumeReadyNodes(controller, shares, assetsBudget);
    }

    function exposedConsumeNode(uint256 id, uint256 sharesToConsume, uint256 assetsBudgetRemaining, bool lastAllBudget)
        external
        returns (uint256 assetsAllocated, bool fullyConsumed)
    {
        return _consumeNode(id, sharesToConsume, assetsBudgetRemaining, lastAllBudget);
    }

    function nodeInfo(uint256 id)
        external
        view
        returns (address controller, address owner, uint256 shares, uint256 prevId, uint256 nextId)
    {
        LibAppStorage.QueueNode storage nd = LibAppStorage.appStorage().queue.nodes[id];
        return (nd.controller, nd.owner, nd.shares, nd.prevId, nd.nextId);
    }
}

contract BranchQueueSigHarness is QueueSigFacet {
    function setPaused(bool paused_) external {
        if (paused_) _pause();
        else _unpause();
    }
}

contract BranchLensHarness is LensFacet {}

contract BranchRegistryHarness is SleeveRegistryFacet {
    function enterInit() external {
        bytes32 slot = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
        assembly {
            sstore(slot, 1)
        }
    }

    function grantAdmin(address account) external {
        _grantRole(DEFAULT_ADMIN_ROLE, account);
    }
}

contract BranchVaultHarness is VaultFacet {}

contract ZeroUseSleeve is SleeveBase {
    function initialize(address stakingDiamond_, address asset_) external initializer {
        __SleeveBase_initLaunch(stakingDiamond_, asset_, 0, true, false);
    }

    function _onAllocate(uint256, bytes calldata) internal pure override returns (uint256) {
        return 0;
    }

    function _onDeallocate(uint256, bytes calldata) internal pure override returns (uint256) {
        return 0;
    }

    function _onHarvest(bytes calldata) internal pure override returns (uint256) {
        return 0;
    }

    function totalAssets() public pure override returns (uint256) {
        return 0;
    }
}

contract ZeroReturnSleeve is ISleeve {
    address private immutable ASSET;
    address private immutable STAKING_DIAMOND;

    constructor(address asset_, address stakingDiamond_) {
        ASSET = asset_;
        STAKING_DIAMOND = stakingDiamond_;
    }

    function asset() external view override returns (address) {
        return ASSET;
    }

    function stakingDiamond() external view override returns (address) {
        return STAKING_DIAMOND;
    }

    function principalAssets() external pure returns (uint256) {
        return 0;
    }

    function totalAssets() external pure returns (uint256) {
        return 0;
    }

    function allocate(uint256, bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function deallocate(uint256, bytes calldata) external pure returns (uint256) {
        return 0;
    }

    function harvest(bytes calldata) external pure returns (uint256) {
        return 0;
    }
}

contract BranchCustodyLike {
    function transferTo(address, address, uint256) external {}
}
