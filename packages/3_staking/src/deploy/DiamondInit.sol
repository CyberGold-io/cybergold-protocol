// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {LiveInitCoordinator} from "diamond-infra/helpers/LiveInitCoordinator.sol";
import {ReentrancyGuardInitializable} from "diamond-infra/helpers/ReentrancyGuardInitializable.sol";
import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {IDiamondEmergencyAuthority} from "diamond-infra/interfaces/IDiamondEmergencyAuthority.sol";

import {TokenFacet} from "../facets/TokenFacet.sol";
import {QueueFacet} from "../facets/QueueFacet.sol";
import {CustodyFacet} from "../facets/CustodyFacet.sol";
import {FundManagerFacet} from "../facets/FundManagerFacet.sol";
import {SleeveRegistryFacet} from "../facets/SleeveRegistryFacet.sol";
import {SleeveDeployerHelper} from "./SleeveDeployerHelper.sol";
import {LibStakingLaunch} from "../libraries/LibStakingLaunch.sol";
import {StakingAuthorityInvariant} from "./StakingAuthorityInvariant.sol";
import {StakingSleeveInvariant} from "./StakingSleeveInvariant.sol";
import {StakingInterfaceInit} from "./StakingInterfaceInit.sol";

/// @notice Single outer initializer for the committed Staking finalization.
contract DiamondInit is LiveInitCoordinator, PausableUpgradeable, ReentrancyGuardInitializable {
    /// @notice Raised when a facet delegatecall fails without returning revert data.
    /// @param target The facet that was called through `delegatecall`.
    /// @param data The initialization calldata supplied to the facet.
    error FacetInitFailed(address target, bytes data);

    /// @notice Raised when finalization does not begin from the exact committed launch state.
    error StakingInitInvalidLaunchState();

    /// @notice Raised when a required initialization dependency is absent or has no runtime code.
    /// @param dependency The invalid dependency address, or zero when a required helper is absent.
    error StakingInitInvalidDependency(address dependency);

    /// @notice Raised when a Sleeve's predicted or deployed address violates launch invariants.
    /// @param index The index of the affected Sleeve request.
    /// @param sleeve The invalid predicted or deployed Sleeve address.
    error StakingInitInvalidSleeve(uint256 index, address sleeve);

    /// @notice Raised when a Sleeve implementation's runtime code hash changed after commitment.
    /// @param index The index of the affected Sleeve request.
    /// @param implementation The implementation whose runtime code hash mismatched.
    error StakingInitSleeveImplementationMismatch(uint256 index, address implementation);

    /// @notice Raised when finalization contains no allocator.
    error StakingInitEmptyAllocators();

    /// @notice Raised when finalization contains no Sleeve request.
    error StakingInitEmptySleeves();

    /// @notice Raised when two launch identities that must remain distinct use the same address.
    /// @param first The first colliding identity.
    /// @param second The second colliding identity.
    error StakingInitIdentityCollision(address first, address second);

    /// @notice Raised when two Sleeve requests encode the same complete launch configuration.
    /// @param firstIndex The index of the first request.
    /// @param duplicateIndex The index of the duplicate request.
    error StakingInitDuplicateSleeve(uint256 firstIndex, uint256 duplicateIndex);

    /// @notice Raised when a committed Sleeve base salt is zero.
    /// @param index The index of the affected Sleeve request.
    /// @param salt The invalid committed salt.
    error StakingInitInvalidSleeveSalt(uint256 index, bytes32 salt);

    /// @notice Raised when two Sleeve requests use the same committed base salt.
    /// @param firstIndex The index of the first Sleeve using the salt.
    /// @param duplicateIndex The index of the duplicate Sleeve using the salt.
    /// @param salt The duplicated committed salt.
    error StakingInitDuplicateSleeveSalt(uint256 firstIndex, uint256 duplicateIndex, bytes32 salt);

    /// @notice Raised when Governance unexpectedly has the Safe-only emergency pause authority.
    /// @param governance The Governance Diamond found in the Safe-only pause-owner set.
    error StakingInitGovernanceIsSafeOwner(address governance);

    /// @notice Raised when an allocator is zero or duplicates an earlier allocator.
    /// @param index The index of the invalid allocator entry.
    /// @param allocator The invalid allocator address.
    error StakingInitInvalidAllocator(uint256 index, address allocator);

    /// @notice Raised when a withdrawer is zero or duplicates an earlier withdrawer.
    /// @param index The index of the invalid withdrawer entry.
    /// @param withdrawer The invalid withdrawer address.
    error StakingInitInvalidWithdrawer(uint256 index, address withdrawer);

    /// @notice A Sleeve request bound to the implementation code and deterministic base salt committed at launch.
    /// @param request The complete typed Sleeve initialization request.
    /// @param implementationCodeHash The implementation runtime code hash authenticated during finalization.
    /// @param salt The nonzero base salt committed for deterministic Sleeve deployment.
    struct LaunchSleeve {
        SleeveDeployerHelper.SleeveRequest request;
        bytes32 implementationCodeHash;
        bytes32 salt;
    }

    /// @notice The complete dependency, facet, roster, Sleeve, and product configuration for atomic finalization.
    /// @param safeWallet The sole emergency pause and post-flight unpause authority.
    /// @param authorityInvariant The helper that proves no critical authority exists before the final admin hook.
    /// @param sleeveInvariant The helper that authenticates every deployed Sleeve.
    /// @param interfaceInit The helper that registers and authenticates the final interface surface.
    /// @param accessControlFacet The composite default-admin access-control facet.
    /// @param loupeFacet The Staking-specific Diamond loupe facet.
    /// @param pausableFacet The emergency pause facet.
    /// @param reentrancyFacet The reentrancy-guard initializer implementation.
    /// @param cutFacet The Diamond cut facet.
    /// @param tokenFacet The share-token facet.
    /// @param vaultFacet The ERC-4626 vault facet.
    /// @param sleeveRegistryFacet The Sleeve registry facet.
    /// @param queueFacet The withdrawal queue facet.
    /// @param queueOperatorFacet The queue operator facet.
    /// @param queueSigFacet The signed queue-action facet.
    /// @param custodyFacet The custody and withdrawer-role facet.
    /// @param fundManagerFacet The fund manager and allocator-role facet.
    /// @param lensFacet The read-only Staking lens facet.
    /// @param coreDiamond The deployed Core Diamond dependency.
    /// @param governanceDiamond The Governance Diamond that receives sole critical administration.
    /// @param withdrawers The explicitly configured ordinary custody withdrawers.
    /// @param allocators The nonempty set of ordinary fund allocators.
    /// @param sleeves The nonempty ordered set of committed Sleeve launches.
    /// @param claimExpiry The withdrawal-claim expiry interval.
    /// @param headSweepLimit The maximum queue-head entries swept by a bounded operation.
    /// @param autoProcessMax The maximum queue entries processed automatically.
    /// @param performanceFeePpm The performance fee expressed in parts per million.
    /// @param fundManagerSwapAdapter The explicitly selected Fund Manager swap adapter, which may be zero.
    struct InitConfig {
        address safeWallet;
        address authorityInvariant;
        address sleeveInvariant;
        address interfaceInit;
        address accessControlFacet;
        address loupeFacet;
        address pausableFacet;
        address reentrancyFacet;
        address cutFacet;
        address tokenFacet;
        address vaultFacet;
        address sleeveRegistryFacet;
        address queueFacet;
        address queueOperatorFacet;
        address queueSigFacet;
        address custodyFacet;
        address fundManagerFacet;
        address lensFacet;
        address coreDiamond;
        address governanceDiamond;
        address[] withdrawers;
        address[] allocators;
        LaunchSleeve[] sleeves;
        uint64 claimExpiry;
        uint256 headSweepLimit;
        uint256 autoProcessMax;
        uint256 performanceFeePpm;
        address fundManagerSwapAdapter;
    }

    /// @notice Atomically initialize the complete committed Staking candidate and install Governance as sole admin.
    /// @param cfg The exact launch configuration committed by the finalization payload.
    /// @param name_ The Staking share token name and queue domain name.
    /// @param symbol_ The Staking share token symbol.
    function finalize(InitConfig calldata cfg, string calldata name_, string calldata symbol_) external initializer {
        LibStakingLaunch.Layout storage launch = LibStakingLaunch.getLayout();
        if (
            launch.phase != LibStakingLaunch.Phase.Finalizing || launch.activePayloadHash == bytes32(0)
                || launch.commitment != LibStakingLaunch.commitment(launch.activePayloadHash)
                || LibDiamond.contractOwner() != address(0)
        ) revert StakingInitInvalidLaunchState();
        if (cfg.coreDiamond.code.length == 0) revert StakingInitInvalidDependency(cfg.coreDiamond);
        if (cfg.governanceDiamond.code.length == 0 || cfg.allocators.length == 0) {
            if (cfg.allocators.length == 0) revert StakingInitEmptyAllocators();
            revert StakingInitInvalidDependency(cfg.governanceDiamond);
        }
        if (
            cfg.authorityInvariant == address(0) || cfg.sleeveInvariant == address(0) || cfg.interfaceInit == address(0)
                || cfg.reentrancyFacet == address(0)
        ) {
            revert StakingInitInvalidDependency(address(0));
        }
        if (cfg.sleeves.length == 0) revert StakingInitEmptySleeves();
        _requireDistinctIdentities(cfg);
        _requireUniqueRosters(cfg);
        _requireUniqueSleeves(cfg.sleeves);
        _enterInitContext();
        _initializeInterfaceSurface(cfg);
        _initializeBaseAndProduct(cfg, name_, symbol_);
        _registerRuntimeFacets(cfg);

        address[] memory sleeves = _deploySleeves(cfg);
        _initializeSleeveRegistry(cfg.sleeveRegistryFacet, cfg.sleeves, sleeves);
        _initializeOrdinaryRoles(cfg, sleeves);
        _requireNoCriticalAuthority(cfg);

        // The composite hook is deliberately the final authority-producing operation.
        _delegateInit(
            cfg.accessControlFacet,
            abi.encodeWithSelector(
                DefaultAdminAccessControlFacet.initDefaultAdminAccessControlFromOuter.selector, cfg.governanceDiamond
            )
        );

        // The composite hook above internally proves the final authority topology. Only trusted
        // initialization bookkeeping follows it; there is no post-authority external call.
        _exitInitContext();
        launch.finalizationHash = launch.activePayloadHash;
        launch.activePayloadHash = bytes32(0);
        launch.commitment = bytes32(0);
        launch.phase = LibStakingLaunch.Phase.Finalized;
    }

    function _initializeInterfaceSurface(InitConfig calldata cfg) private {
        address[13] memory facets;
        facets[0] = cfg.cutFacet;
        facets[1] = cfg.loupeFacet;
        facets[2] = cfg.accessControlFacet;
        facets[3] = cfg.pausableFacet;
        facets[4] = cfg.tokenFacet;
        facets[5] = cfg.vaultFacet;
        facets[6] = cfg.queueFacet;
        facets[7] = cfg.queueOperatorFacet;
        facets[8] = cfg.queueSigFacet;
        facets[9] = cfg.custodyFacet;
        facets[10] = cfg.sleeveRegistryFacet;
        facets[11] = cfg.fundManagerFacet;
        facets[12] = cfg.lensFacet;
        _delegateInit(cfg.interfaceInit, abi.encodeCall(StakingInterfaceInit.initialize, (facets)));
    }

    function _requireDistinctIdentities(InitConfig calldata cfg) private view {
        if (cfg.coreDiamond == cfg.governanceDiamond) {
            revert StakingInitIdentityCollision(cfg.coreDiamond, cfg.governanceDiamond);
        }
        if (cfg.coreDiamond == cfg.safeWallet) {
            revert StakingInitIdentityCollision(cfg.coreDiamond, cfg.safeWallet);
        }
        if (cfg.governanceDiamond == cfg.safeWallet) {
            revert StakingInitIdentityCollision(cfg.governanceDiamond, cfg.safeWallet);
        }
        if (cfg.governanceDiamond == address(this)) {
            revert StakingInitIdentityCollision(cfg.governanceDiamond, address(this));
        }
        if (cfg.coreDiamond == address(this)) {
            revert StakingInitIdentityCollision(cfg.coreDiamond, address(this));
        }
        if (cfg.safeWallet == address(this)) {
            revert StakingInitIdentityCollision(cfg.safeWallet, address(this));
        }
    }

    function _requireUniqueRosters(InitConfig calldata cfg) private pure {
        for (uint256 i; i < cfg.allocators.length; ++i) {
            address allocator = cfg.allocators[i];
            if (allocator == address(0)) revert StakingInitInvalidAllocator(i, allocator);
            for (uint256 j; j < i; ++j) {
                if (cfg.allocators[j] == allocator) revert StakingInitInvalidAllocator(i, allocator);
            }
        }
        for (uint256 i; i < cfg.withdrawers.length; ++i) {
            address withdrawer = cfg.withdrawers[i];
            if (withdrawer == address(0)) revert StakingInitInvalidWithdrawer(i, withdrawer);
            for (uint256 j; j < i; ++j) {
                if (cfg.withdrawers[j] == withdrawer) revert StakingInitInvalidWithdrawer(i, withdrawer);
            }
        }
    }

    function _requireUniqueSleeves(LaunchSleeve[] calldata sleeves) private pure {
        for (uint256 i; i < sleeves.length; ++i) {
            bytes32 salt = sleeves[i].salt;
            if (salt == bytes32(0)) revert StakingInitInvalidSleeveSalt(i, salt);
            bytes32 requestHash = keccak256(abi.encode(sleeves[i].request));
            for (uint256 j; j < i; ++j) {
                if (salt == sleeves[j].salt) revert StakingInitDuplicateSleeveSalt(j, i, salt);
                if (requestHash == keccak256(abi.encode(sleeves[j].request))) {
                    revert StakingInitDuplicateSleeve(j, i);
                }
            }
        }
    }

    function _initializeBaseAndProduct(InitConfig calldata cfg, string calldata name_, string calldata symbol_)
        private
    {
        _delegateInit(
            cfg.pausableFacet, abi.encodeWithSelector(PausableFacet.initPausableFromOuter.selector, cfg.safeWallet)
        );
        if (IDiamondEmergencyAuthority(address(this)).canPause(cfg.governanceDiamond)) {
            revert StakingInitGovernanceIsSafeOwner(cfg.governanceDiamond);
        }
        _pause();
        __ReentrancyGuard_init();
        _delegateInit(
            cfg.tokenFacet, abi.encodeWithSelector(TokenFacet.initToken.selector, cfg.coreDiamond, name_, symbol_)
        );
        _initializeQueue(cfg, name_);
        _delegateInit(
            cfg.fundManagerFacet,
            abi.encodeWithSelector(
                FundManagerFacet.initFundManager.selector,
                cfg.coreDiamond,
                cfg.governanceDiamond,
                cfg.performanceFeePpm,
                cfg.fundManagerSwapAdapter
            )
        );
    }

    function _initializeQueue(InitConfig calldata cfg, string calldata name_) private {
        _delegateInit(
            cfg.queueFacet,
            abi.encodeWithSelector(
                QueueFacet.initQueue.selector,
                cfg.coreDiamond,
                name_,
                cfg.claimExpiry,
                cfg.headSweepLimit,
                cfg.autoProcessMax
            )
        );
    }

    function _registerRuntimeFacets(InitConfig calldata cfg) private {
        _registerFacetGeneration(cfg.cutFacet);
        _registerFacetGeneration(cfg.loupeFacet);
        _registerFacetGeneration(cfg.accessControlFacet);
        _registerFacetGeneration(cfg.pausableFacet);
        _registerFacetGeneration(cfg.tokenFacet);
        _registerFacetGeneration(cfg.vaultFacet);
        _registerFacetGeneration(cfg.queueFacet);
        _registerFacetGeneration(cfg.sleeveRegistryFacet);
        _registerFacetGeneration(cfg.queueOperatorFacet);
        _registerFacetGeneration(cfg.queueSigFacet);
        _registerFacetGeneration(cfg.custodyFacet);
        _registerFacetGeneration(cfg.fundManagerFacet);
        _registerFacetGeneration(cfg.lensFacet);
    }

    function _deploySleeves(InitConfig calldata cfg) private returns (address[] memory sleeves) {
        LaunchSleeve[] calldata requests = cfg.sleeves;
        sleeves = new address[](requests.length);
        bytes32 payloadHash_ = LibStakingLaunch.getLayout().activePayloadHash;
        for (uint256 i; i < requests.length; ++i) {
            LaunchSleeve calldata launchSleeve = requests[i];
            address implementation = launchSleeve.request.implementation;
            if (implementation.codehash != launchSleeve.implementationCodeHash) {
                revert StakingInitSleeveImplementationMismatch(i, implementation);
            }
            bytes32 effectiveSalt = LibStakingLaunch.sleeveSalt(payloadHash_, launchSleeve.salt, i);
            address predicted = SleeveDeployerHelper.predictDeterministic(
                address(this), address(this), launchSleeve.request, effectiveSalt
            );
            if (predicted.code.length != 0) revert StakingInitInvalidSleeve(i, predicted);
            address sleeve =
                SleeveDeployerHelper.deployDeterministic(address(this), launchSleeve.request, effectiveSalt);
            StakingSleeveInvariant(cfg.sleeveInvariant).requireSleeve(address(this), i, sleeve, launchSleeve.request);
            sleeves[i] = sleeve;
        }
    }

    function _initializeSleeveRegistry(address registry, LaunchSleeve[] calldata requests, address[] memory sleeves)
        private
    {
        address[] memory assets = new address[](sleeves.length);
        bool[] memory approvals = new bool[](sleeves.length);
        for (uint256 i; i < sleeves.length; ++i) {
            assets[i] = requests[i].request.asset;
            approvals[i] = requests[i].request.approve;
        }
        _delegate(
            registry, abi.encodeWithSelector(SleeveRegistryFacet.initSleeves.selector, sleeves, assets, approvals)
        );
    }

    function _initializeOrdinaryRoles(InitConfig calldata cfg, address[] memory sleeves) private {
        address[] memory withdrawers = new address[](cfg.withdrawers.length + sleeves.length);
        for (uint256 i; i < cfg.withdrawers.length; ++i) {
            withdrawers[i] = cfg.withdrawers[i];
        }
        for (uint256 i; i < sleeves.length; ++i) {
            withdrawers[cfg.withdrawers.length + i] = sleeves[i];
        }
        _delegate(cfg.custodyFacet, abi.encodeWithSelector(CustodyFacet.initCustody.selector, withdrawers));
        _delegate(
            cfg.fundManagerFacet, abi.encodeWithSelector(FundManagerFacet.initAllocators.selector, cfg.allocators)
        );
    }

    function _requireNoCriticalAuthority(InitConfig calldata cfg) private view {
        StakingAuthorityInvariant(cfg.authorityInvariant)
            .requireNoCriticalAuthority(address(this), cfg.governanceDiamond, cfg.safeWallet);
    }

    function _registerFacetGeneration(address facet) private {
        _checkAndSetLiveLaunchFacetGeneration(facet);
    }

    function _delegateInit(address target, bytes memory data) private {
        _delegate(target, data);
    }

    function _delegate(address target, bytes memory data) private {
        (bool ok, bytes memory err) = target.delegatecall(data);
        if (!ok) {
            if (err.length != 0) {
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
            revert FacetInitFailed(target, data);
        }
    }
}
