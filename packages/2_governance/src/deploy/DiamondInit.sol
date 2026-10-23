// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondEmergencyAuthority} from "diamond-infra/interfaces/IDiamondEmergencyAuthority.sol";
import {LiveInitCoordinator} from "diamond-infra/helpers/LiveInitCoordinator.sol";
import {ReentrancyGuardInitializable} from "diamond-infra/helpers/ReentrancyGuardInitializable.sol";
import {AccessControlFacet} from "diamond-infra/facets/AccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {FacetSelectors as SharedFacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";
import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";
import {StandardInterfaceManifests} from "diamond-infra/libraries/StandardInterfaceManifests.sol";
import {GovernorCoreFacet} from "../facets/GovernorCoreFacet.sol";
import {TokenFacet} from "../facets/TokenFacet.sol";
import {TreasuryFacet} from "../facets/TreasuryFacet.sol";
import {RecoveryFundFacet} from "../facets/RecoveryFundFacet.sol";
import {RecoveryFundLensFacet} from "../facets/RecoveryFundLensFacet.sol";
import {IRecoveryFundTypes} from "../interfaces/IRecoveryFundTypes.sol";
import {LibRecoveryFundStorage} from "../libraries/LibRecoveryFundStorage.sol";
import {GovernorSettingsFacet} from "../facets/GovernorSettingsFacet.sol";
import {FacetSelectors} from "./FacetSelectors.sol";
import {LibGovernorBounds} from "../libraries/LibGovernorBounds.sol";
import {ICygldApprovalCallback} from "cybergold-core/interfaces/ICygldApprovalCallback.sol";
import {ICygldOutflowCallback} from "cybergold-core/interfaces/ICygldOutflowCallback.sol";
import {IRecoveryShareOutflowCallback} from "cybergold-core/interfaces/IRecoveryShareOutflowCallback.sol";
import {IRecoveryShareRedemptionCallback} from "cybergold-core/interfaces/IRecoveryShareRedemptionCallback.sol";

/// @notice Consolidated initializer for governance diamond infra facets.
/// @dev Used as the `_init` target of diamondCut; owns the component's single OZ initializer context.
contract DiamondInit is LiveInitCoordinator, ReentrancyGuardInitializable {
    /// @notice Reverts when facet init failed.
    /// @param target Contract address called or initialized by the operation.
    /// @param data Opaque calldata passed to an initializer.
    error FacetInitFailed(address target, bytes data);
    /// @notice Reverts when launch would have no externally held CYGOV.
    error GovernorInitialExternalSupplyZero();
    /// @notice Reverts when the initial external CYGOV holder is zero.
    error GovernorInitialHolderZero();
    /// @notice Reverts when nonzero initial CYGOV supply would be held by the Governance diamond itself.
    /// @param holder Configured initial token holder.
    error GovernorInitialHolderMustBeExternal(address holder);
    /// @notice Reverts when combined launch minting exceeds the ERC20Votes checkpoint-safe supply ceiling.
    /// @param initialSupply CYGOV minted to the configured external holder.
    /// @param treasurySupply CYGOV minted to the Governance diamond treasury.
    /// @param maximum Maximum total CYGOV supply representable by ERC20Votes checkpoints.
    error GovernorInitialSupplyExceedsSafeSupply(uint256 initialSupply, uint256 treasurySupply, uint256 maximum);
    /// @notice Reverts when the launch threshold numerator is outside compiled bounds.
    /// @param requested Rejected threshold numerator.
    /// @param minimum Minimum accepted threshold numerator.
    /// @param maximum Maximum accepted threshold numerator.
    error GovernorInvalidLaunchProposalThresholdNumerator(uint256 requested, uint256 minimum, uint256 maximum);
    /// @notice Reverts when the launch quorum numerator is outside compiled bounds.
    /// @param requested Rejected quorum numerator.
    /// @param minimum Minimum accepted quorum numerator.
    /// @param maximum Maximum accepted quorum numerator.
    error GovernorInvalidLaunchQuorumNumerator(uint256 requested, uint256 minimum, uint256 maximum);
    /// @notice Reverts when a mandatory production selector has no installed facet owner.
    /// @param selector Canonical selector whose facet must be installed and versioned.
    error GovernanceMandatoryFacetMissing(bytes4 selector);
    /// @notice Reverts when a configured production facet is absent from the installed cut.
    /// @param facet Expected production facet address.
    error GovernanceMandatoryFacetAddressMissing(address facet);
    /// @notice Reverts when an exact production selector is not owned by its configured facet.
    /// @param selector Canonical selector whose owner did not match the launch manifest.
    /// @param expected Configured facet that must own `selector`.
    /// @param actual Facet currently returned by the diamond loupe for `selector`.
    error GovernanceFacetSelectorOwnerMismatch(bytes4 selector, address expected, address actual);
    /// @notice Reverts when the installed selector count differs from the exact production manifest.
    /// @param expected Exact number of selectors in the launch manifest.
    /// @param actual Number of selectors installed in the diamond.
    error GovernanceFacetSelectorCountMismatch(uint256 expected, uint256 actual);

    /// @notice Initializer payload for wiring diamond facets and package-specific state.
    struct InitConfig {
        address safeWallet;
        address trustedCore;
        address accessControlFacet;
        address pausableFacet;
        address governorCoreFacet;
        address tokenFacet;
        address governorSettingsFacet;
        uint256 executionDelay;
        uint256 executionGracePeriod;
        string name;
        string tokenSymbol;
        address tokenInitialHolder;
        uint256 tokenInitialSupply;
        uint256 tokenTreasurySupply;
        uint256 votingDelay;
        uint256 votingPeriod;
        uint256 proposalThresholdNumerator;
        uint256 quorumNumerator;
    }

    /// @notice Initialize governance diamond state.
    /// @param cfg Initializer or deployment config consumed by this function.
    function init(InitConfig calldata cfg) external initializer {
        _validateLaunchDistribution(cfg);
        _registerCoreInterfaces();
        _enterInitContext();
        _initAccessControl(cfg.accessControlFacet);
        _initPausable(cfg.pausableFacet, cfg.safeWallet);
        __ReentrancyGuard_init();
        _initRecoveryFund(cfg.trustedCore);
        _initToken(
            cfg.tokenFacet,
            cfg.name,
            cfg.tokenSymbol,
            cfg.tokenInitialHolder,
            cfg.tokenInitialSupply,
            cfg.tokenTreasurySupply
        );
        _initGovernorCore(cfg.governorCoreFacet, cfg.name);
        _initSettings(
            cfg.governorSettingsFacet,
            cfg.votingDelay,
            cfg.votingPeriod,
            cfg.proposalThresholdNumerator,
            cfg.quorumNumerator,
            cfg.executionDelay,
            cfg.executionGracePeriod
        );
        _registerInstalledFacetGeneration(TreasuryFacet.treasuryWithdraw.selector);
        _registerInstalledFacetGeneration(RecoveryFundFacet.activateAssetRecoveryFund.selector);
        _registerInstalledFacetGeneration(RecoveryFundLensFacet.assetRecoveryFund.selector);
        _registerInstalledFacetGeneration(IDiamondCut.diamondCut.selector);
        _registerInstalledFacetGeneration(SharedFacetSelectors.loupeSelectors()[0]);
        _requireProductionFacetTopology(cfg);
        _exitInitContext();
        LibDiamond.setContractOwner(address(0));
    }

    /// @dev Validate launch external-supply bounds because the diamond runtime is unavailable during construction.
    /// @dev These are configuration-time necessary conditions, not continuous delegated-vote invariants.
    function _validateLaunchDistribution(InitConfig calldata cfg) internal view {
        if (cfg.tokenInitialSupply == 0) revert GovernorInitialExternalSupplyZero();
        uint256 maximumSupply = type(uint208).max;
        if (cfg.tokenInitialSupply > maximumSupply || cfg.tokenTreasurySupply > maximumSupply - cfg.tokenInitialSupply)
        {
            revert GovernorInitialSupplyExceedsSafeSupply(
                cfg.tokenInitialSupply, cfg.tokenTreasurySupply, maximumSupply
            );
        }
        if (cfg.tokenInitialHolder == address(0)) revert GovernorInitialHolderZero();
        if (cfg.tokenInitialHolder == address(this)) {
            revert GovernorInitialHolderMustBeExternal(cfg.tokenInitialHolder);
        }
        if (
            cfg.proposalThresholdNumerator < LibGovernorBounds.MIN_PROPOSAL_THRESHOLD_NUMERATOR
                || cfg.proposalThresholdNumerator > LibGovernorBounds.MAX_PROPOSAL_THRESHOLD_NUMERATOR
        ) {
            revert GovernorInvalidLaunchProposalThresholdNumerator(
                cfg.proposalThresholdNumerator,
                LibGovernorBounds.MIN_PROPOSAL_THRESHOLD_NUMERATOR,
                LibGovernorBounds.MAX_PROPOSAL_THRESHOLD_NUMERATOR
            );
        }
        if (
            cfg.quorumNumerator < LibGovernorBounds.MIN_QUORUM_NUMERATOR
                || cfg.quorumNumerator > LibGovernorBounds.MAX_QUORUM_NUMERATOR
        ) {
            revert GovernorInvalidLaunchQuorumNumerator(
                cfg.quorumNumerator, LibGovernorBounds.MIN_QUORUM_NUMERATOR, LibGovernorBounds.MAX_QUORUM_NUMERATOR
            );
        }
    }

    /// @dev Register core interfaces.
    function _registerCoreInterfaces() internal {
        StandardInterfaceManifests.registerErc165();
        StandardInterfaceManifests.registerDiamondCut();
        StandardInterfaceManifests.registerDiamondLoupe();
        StandardInterfaceManifests.registerAccessControl();
        StandardInterfaceManifests.registerAccessControlEnumerable();
        _registerEmergencyInterfaceManifest();
        StandardInterfaceManifests.registerErc6372();
        StandardInterfaceManifests.registerErc20();
        StandardInterfaceManifests.registerErc20Metadata();
        StandardInterfaceManifests.registerErc20Permit();
        StandardInterfaceManifests.registerErc721Receiver();
        StandardInterfaceManifests.registerErc1155Receiver();
        _registerOneSelectorInterface(
            type(ICygldOutflowCallback).interfaceId, ICygldOutflowCallback.onCygldOutflow.selector
        );
        _registerOneSelectorInterface(
            type(ICygldApprovalCallback).interfaceId, ICygldApprovalCallback.onCygldApprovalChange.selector
        );
        _registerOneSelectorInterface(
            type(IRecoveryShareOutflowCallback).interfaceId,
            IRecoveryShareOutflowCallback.onRecoveryShareOutflow.selector
        );
        _registerOneSelectorInterface(
            type(IRecoveryShareRedemptionCallback).interfaceId,
            IRecoveryShareRedemptionCallback.onRecoveryShareRedemption.selector
        );
    }

    function _registerEmergencyInterfaceManifest() private {
        bytes4[][] memory groups = new bytes4[][](1);
        groups[0] = SharedFacetSelectors.pauseSelectors();
        LibInterfaceInvariant.registerInterface(type(IDiamondEmergencyAuthority).interfaceId, groups);
    }

    function _registerOneSelectorInterface(bytes4 interfaceId, bytes4 selector) private {
        bytes4[][] memory groups = new bytes4[][](1);
        groups[0] = new bytes4[](1);
        groups[0][0] = selector;
        LibInterfaceInvariant.registerInterface(interfaceId, groups);
    }

    /// @dev Internal helper for init access control.
    /// @param accessControlFacet AccessControl facet called during diamond initialization.
    function _initAccessControl(address accessControlFacet) internal {
        _delegateInit(
            accessControlFacet,
            abi.encodeWithSelector(AccessControlFacet.initAccessControlFromOuter.selector, address(this))
        );
    }

    /// @dev Internal helper for init pausable.
    /// @param pausableFacet Pausable facet called during diamond initialization.
    function _initPausable(address pausableFacet, address safeWallet_) internal {
        _delegateInit(pausableFacet, abi.encodeWithSelector(PausableFacet.initPausableFromOuter.selector, safeWallet_));
    }

    /// @dev Bind the canonical trusted Core and initialize the mandatory clean-launch Fund.
    function _initRecoveryFund(address trustedCore) internal {
        if (trustedCore == address(0) || trustedCore.code.length == 0) {
            revert IRecoveryFundTypes.RecoveryFundTrustedCoreInvalid(trustedCore);
        }
        LibRecoveryFundStorage.Layout storage l = LibRecoveryFundStorage.getLayout();
        if (l.trustedCore != address(0)) {
            revert IRecoveryFundTypes.RecoveryFundTrustedCoreInvalid(l.trustedCore);
        }
        l.trustedCore = trustedCore;
        emit IRecoveryFundTypes.RecoveryFundInitialized(trustedCore);
    }

    /// @dev Internal helper for init token.
    /// @param tokenFacet Token facet called during initialization.
    /// @param name_ Token or governor name used during initialization.
    /// @param symbol_ Token symbol used during initialization.
    /// @param initialHolder Account receiving the initial token supply.
    /// @param initialSupply Initial token supply minted during initialization.
    /// @param treasurySupply Initial token supply minted to the Governance treasury.
    function _initToken(
        address tokenFacet,
        string memory name_,
        string memory symbol_,
        address initialHolder,
        uint256 initialSupply,
        uint256 treasurySupply
    ) internal {
        _delegateInit(
            tokenFacet,
            abi.encodeWithSelector(
                TokenFacet.initToken.selector, name_, symbol_, initialHolder, initialSupply, treasurySupply
            )
        );
    }

    /// @dev Internal helper for init governor core.
    /// @param governorCoreFacet Governor core facet called during governance initialization.
    /// @param name_ Token or governor name used during initialization.
    function _initGovernorCore(address governorCoreFacet, string memory name_) internal {
        _delegateInit(governorCoreFacet, abi.encodeWithSelector(GovernorCoreFacet.initCore.selector, name_));
    }

    /// @dev Internal helper for init settings.
    /// @param governorSettingsFacet Governor settings facet called during governance initialization.
    /// @param delay Governor voting delay in timestamp seconds.
    /// @param period Governor voting period in timestamp seconds.
    /// @param thresholdNumerator Governor proposal-threshold numerator over the compiled denominator.
    /// @param quorumNumerator Governor quorum numerator over the compiled denominator.
    /// @param executionDelay Delay from vote settlement to proposal execution eligibility.
    /// @param executionGracePeriod Length of the proposal execution window.
    function _initSettings(
        address governorSettingsFacet,
        uint256 delay,
        uint256 period,
        uint256 thresholdNumerator,
        uint256 quorumNumerator,
        uint256 executionDelay,
        uint256 executionGracePeriod
    ) internal {
        _delegateInit(
            governorSettingsFacet,
            abi.encodeWithSelector(
                GovernorSettingsFacet.initSettings.selector,
                delay,
                period,
                thresholdNumerator,
                quorumNumerator,
                executionDelay,
                executionGracePeriod
            )
        );
    }

    /// @dev Register the facet currently owning a mandatory production selector.
    function _registerInstalledFacetGeneration(bytes4 selector) internal {
        address facet = LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress;
        if (facet == address(0)) revert GovernanceMandatoryFacetMissing(selector);
        _checkAndSetLiveLaunchFacetGeneration(facet);
    }

    /// @dev Internal helper for delegate init.
    /// @param target Contract address called or initialized by the operation.
    /// @param data Opaque calldata passed to an initializer.
    function _delegateInit(address target, bytes memory data) internal {
        if (_isInstalledFacet(target)) {
            _checkAndSetLiveLaunchFacetGeneration(target);
        }

        (bool ok, bytes memory err) = target.delegatecall(data);
        if (!ok) {
            if (err.length > 0) {
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
            revert FacetInitFailed(target, data);
        }
    }

    function _requireProductionFacetTopology(InitConfig calldata cfg) internal view {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address cutFacet = ds.facetAddressAndSelectorPosition[IDiamondCut.diamondCut.selector].facetAddress;
        bytes4[] memory loupeSelectors = SharedFacetSelectors.loupeSelectors();
        address loupeFacet = ds.facetAddressAndSelectorPosition[loupeSelectors[0]].facetAddress;
        address recoveryFundFacet =
            ds.facetAddressAndSelectorPosition[RecoveryFundFacet.activateAssetRecoveryFund.selector].facetAddress;
        address treasuryFacet = ds.facetAddressAndSelectorPosition[TreasuryFacet.treasuryWithdraw.selector].facetAddress;
        address lensFacet =
            ds.facetAddressAndSelectorPosition[RecoveryFundLensFacet.assetRecoveryFund.selector].facetAddress;

        uint256 expectedSelectorCount;
        expectedSelectorCount += _requireSelectorGroup(cutFacet, SharedFacetSelectors.liveCutSelectors());
        expectedSelectorCount += _requireSelectorGroup(loupeFacet, loupeSelectors);
        expectedSelectorCount += _requireSelectorGroup(cfg.accessControlFacet, SharedFacetSelectors.accessSelectors());
        expectedSelectorCount += _requireSelectorGroup(cfg.pausableFacet, SharedFacetSelectors.pauseSelectors());
        expectedSelectorCount += _requireSelectorGroup(recoveryFundFacet, FacetSelectors.recoveryFundSelectors());
        expectedSelectorCount += _requireSelectorGroup(cfg.governorCoreFacet, FacetSelectors.governorCoreSelectors());
        expectedSelectorCount += _requireSelectorGroup(cfg.tokenFacet, FacetSelectors.tokenSelectors());
        expectedSelectorCount += _requireSelectorGroup(treasuryFacet, FacetSelectors.treasurySelectors());
        expectedSelectorCount += _requireSelectorGroup(
            cfg.governorSettingsFacet, FacetSelectors.governorSettingsSelectors()
        );
        expectedSelectorCount += _requireSelectorGroup(lensFacet, FacetSelectors.recoveryFundLensSelectors());
        if (ds.selectors.length != expectedSelectorCount) {
            revert GovernanceFacetSelectorCountMismatch(expectedSelectorCount, ds.selectors.length);
        }
    }

    function _requireSelectorGroup(address facet, bytes4[] memory selectors) internal view returns (uint256) {
        if (facet == address(0)) revert GovernanceMandatoryFacetAddressMissing(facet);
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        for (uint256 i; i < selectors.length; ++i) {
            address actual = ds.facetAddressAndSelectorPosition[selectors[i]].facetAddress;
            if (actual != facet) revert GovernanceFacetSelectorOwnerMismatch(selectors[i], facet, actual);
        }
        return selectors.length;
    }
}
