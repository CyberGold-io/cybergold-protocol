// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";

import {DeploymentTypes} from "./DeploymentTypes.sol";
import {DiamondInit} from "./DiamondInit.sol";
import {SleeveDeployerHelper} from "./SleeveDeployerHelper.sol";
import {LibStakingLaunch} from "../libraries/LibStakingLaunch.sol";
import {ISleeve} from "../sleeves/ISleeve.sol";
import {SleeveManual} from "../sleeves/SleeveManual.sol";
import {Sleeve4626} from "../sleeves/Sleeve4626.sol";
import {SleeveCurve} from "../sleeves/SleeveCurve.sol";
import {SleeveProxy, ISleeveProxy} from "../sleeves/SleeveProxy.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {SleeveRegistryFacet} from "../facets/SleeveRegistryFacet.sol";

/// @notice Minimal immutable launch-state view used to attest each deployed Sleeve.
interface ISleeveArtifactLaunchState {
    /// @notice Return the configured principal-asset ceiling.
    /// @return principalCap_ Maximum principal assets the Sleeve may hold.
    function principalCap() external view returns (uint256);

    /// @notice Return whether the Sleeve was launched in operational mode.
    /// @return operational_ Whether protocol operations are enabled for the Sleeve.
    function operational() external view returns (bool);

    /// @notice Return whether the Sleeve-local pause flag is set.
    /// @return paused_ Whether Sleeve-local guarded operations are paused.
    function paused() external view returns (bool);
}

/// @notice Forge-only writer for ordered deterministic Sleeve launch evidence.
/// @dev Kept separate from the canonical typed CREATE2 deployment helper.
library SleeveArtifactWriter {
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice Ordered launch commitments and live observations serialized for every Sleeve.
    struct Evidence {
        address[] sleeves;
        address[] controllers;
        address[] implementations;
        address[] proxyImplementations;
        bytes32[] committedImplementationCodeHashes;
        bytes32[] observedImplementationCodeHashes;
        bytes32[] proxyRuntimeCodeHashes;
        address[] assets;
        bool[] approvals;
        bool[] requestedOperational;
        bool[] requestedLocalPaused;
        uint256[] principalCaps;
        uint256[] initTypes;
        bytes[] initArgs;
        bytes32[] initArgsHashes;
        bytes32[] requestHashes;
        bytes32[] baseSalts;
        bytes32[] effectiveSalts;
        bytes32[] initCalldataHashes;
        bool[] registryRegistered;
        bool[] registryApprovals;
        address[] registryAssets;
        uint256[] registryPrincipalAssets;
        address[] sleeveControllers;
        address[] sleeveAssets;
        uint256[] sleevePrincipalAssets;
        uint256[] observedSleeveTotalAssets;
        bool[] observedSleeveTotalAssetsHealthy;
        bool[] sleeveOperational;
        bool[] sleevePaused;
        address[] manualOperators;
        address[] erc4626Vaults;
        address[] curveOtherAssets;
        address[] curvePools;
        address[] curveLpTokens;
        int256[] curveUnderlyingIndices;
        int256[] curveOtherIndices;
        uint256[] curveOtherSharePpm;
        address[] curveGauges;
        uint256[] curveMaxLpTokens;
        uint256[] curvePriceReferences;
        uint256[] curveMaxPriceDeviationBps;
        address[] curveRewardSwapAdapters;
        bytes[] curveRewardTokens;
        bytes32[] curveRewardTokenHashes;
        uint256[] curveRewardTokenCounts;
        address[] curveCygldControllers;
        address[] curveBasketSwapAdapters;
    }

    /// @notice Scratch record used while validating and recording one Sleeve deployment.
    struct Collection {
        SleeveDeployerHelper.SleeveRequest request;
        SleeveDeployerHelper.SleeveDeployment result;
        LibAppStorage.SleeveConfig registry;
        bytes32 requestHash;
        bytes32 baseSalt;
        bytes32 effectiveSalt;
        address controller;
        address proxyImplementation;
        uint256 observedTotalAssets;
        bool observedTotalAssetsHealthy;
        bool observedOperational;
        bool observedPaused;
    }

    function writeJson(
        Vm vm_,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        string memory path
    ) internal {
        uint256 count = cfg.sleeves.length;
        require(bytes(path).length != 0, "Staking Sleeve output path missing");
        require(count != 0, "Staking Sleeve requests empty");
        require(art.sleeves.length == count, "Staking Sleeve result length mismatch");
        require(
            LibStakingLaunch.payloadHash(art.finalization) == art.payloadHash,
            "Staking Sleeve finalization candidate mismatch"
        );

        DiamondInit.LaunchSleeve[] memory committed = _committedSleeves(art.finalization.initializerCalldata);
        require(committed.length == count, "Staking committed Sleeve length mismatch");
        Evidence memory evidence = _allocate(count);
        address[] memory registeredSleeves = SleeveRegistryFacet(address(art.diamond)).sleeves();
        require(registeredSleeves.length == count, "Staking Sleeve registry count mismatch");
        for (uint256 i; i < count; ++i) {
            _collect(vm_, evidence, cfg, art, committed[i], i);
            require(registeredSleeves[i] == evidence.sleeves[i], "Staking Sleeve registry order mismatch");
        }

        string memory label = "sleeves";
        string memory out = vm_.serializeUint(label, "chainId", block.chainid);
        out = vm_.serializeAddress(label, "stakingDiamond", address(art.diamond));
        out = vm_.serializeAddress(label, "controller", address(art.diamond));
        out = vm_.serializeBytes32(label, "payloadHash", art.payloadHash);
        out = vm_.serializeBytes32(label, "implementationSlot", ERC1967_IMPLEMENTATION_SLOT);
        out = vm_.serializeBytes32(label, "sleeveProxyRuntimeCodeHash", keccak256(type(SleeveProxy).runtimeCode));
        out = vm_.serializeUint(label, "count", count);
        out = _serializeIdentity(vm_, label, out, evidence);
        out = _serializeConfiguration(vm_, label, out, evidence);
        out = _serializeTypedConfiguration(vm_, label, out, evidence);
        out = _serializeCommitments(vm_, label, out, evidence);
        vm_.writeJson(out, path);
    }

    function _collect(
        Vm vm_,
        Evidence memory evidence,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        DiamondInit.LaunchSleeve memory committed,
        uint256 index
    ) private view {
        Collection memory c;
        c.request = cfg.sleeves[index];
        c.result = art.sleeves[index];
        c.requestHash = keccak256(abi.encode(c.request));
        c.baseSalt = LibStakingLaunch.sleeveBaseSalt(cfg.shellSalt, index, c.requestHash);
        require(keccak256(abi.encode(committed.request)) == c.requestHash, "Staking committed Sleeve request mismatch");
        require(committed.salt == c.baseSalt, "Staking committed Sleeve salt mismatch");
        require(
            c.request.implementation.codehash == committed.implementationCodeHash,
            "Staking Sleeve live implementation codehash mismatch"
        );

        c.effectiveSalt = LibStakingLaunch.sleeveSalt(art.payloadHash, c.baseSalt, index);
        c.controller = address(art.diamond);
        require(
            c.result.sleeve
                == SleeveDeployerHelper.predictDeterministic(c.controller, c.controller, c.request, c.effectiveSalt),
            "Staking Sleeve address mismatch"
        );
        require(c.result.asset == c.request.asset, "Staking Sleeve asset mismatch");
        require(c.result.approve == c.request.approve, "Staking Sleeve approval mismatch");
        require(c.result.sleeve.codehash == keccak256(type(SleeveProxy).runtimeCode), "Staking Sleeve proxy mismatch");

        c.proxyImplementation = address(uint160(uint256(vm_.load(c.result.sleeve, ERC1967_IMPLEMENTATION_SLOT))));
        require(c.proxyImplementation == c.request.implementation, "Staking Sleeve raw implementation mismatch");
        require(
            ISleeveProxy(c.result.sleeve).implementation() == c.proxyImplementation,
            "Staking Sleeve proxy implementation view mismatch"
        );

        ISleeve sleeve = ISleeve(c.result.sleeve);
        ISleeveArtifactLaunchState launchState = ISleeveArtifactLaunchState(c.result.sleeve);
        c.registry = SleeveRegistryFacet(c.controller).sleeveConfig(c.result.sleeve);
        require(c.registry.registered, "Staking Sleeve not registered");
        require(c.registry.approved == c.request.approve, "Staking Sleeve registry approval mismatch");
        require(c.registry.asset == c.request.asset, "Staking Sleeve registry asset mismatch");
        require(c.registry.principalAssets == 0, "Staking Sleeve registry principal mismatch");
        require(sleeve.stakingDiamond() == c.controller, "Staking Sleeve controller mismatch");
        require(sleeve.asset() == c.request.asset, "Staking Sleeve runtime asset mismatch");
        require(sleeve.principalAssets() == 0, "Staking Sleeve principal mismatch");
        require(launchState.principalCap() == c.request.principalCap, "Staking Sleeve cap mismatch");
        c.observedOperational = launchState.operational();
        c.observedPaused = launchState.paused();
        require(c.observedOperational == c.request.initialOperational, "Staking Sleeve operational mismatch");
        require(c.observedPaused == c.request.initialPaused, "Staking Sleeve local pause mismatch");
        (c.observedTotalAssetsHealthy, c.observedTotalAssets) = _observeTotalAssets(c.result.sleeve);

        _record(evidence, c, committed, index);
        _collectTyped(evidence, c.request, c.result.sleeve, index);
    }

    function _record(
        Evidence memory evidence,
        Collection memory c,
        DiamondInit.LaunchSleeve memory committed,
        uint256 index
    ) private view {
        evidence.sleeves[index] = c.result.sleeve;
        evidence.controllers[index] = c.controller;
        evidence.implementations[index] = c.request.implementation;
        evidence.proxyImplementations[index] = c.proxyImplementation;
        evidence.committedImplementationCodeHashes[index] = committed.implementationCodeHash;
        evidence.observedImplementationCodeHashes[index] = c.request.implementation.codehash;
        evidence.proxyRuntimeCodeHashes[index] = c.result.sleeve.codehash;
        evidence.assets[index] = c.request.asset;
        evidence.approvals[index] = c.request.approve;
        evidence.requestedOperational[index] = c.request.initialOperational;
        evidence.requestedLocalPaused[index] = c.request.initialPaused;
        evidence.principalCaps[index] = c.request.principalCap;
        evidence.initTypes[index] = uint256(c.request.initType);
        evidence.initArgs[index] = c.request.initArgs;
        evidence.initArgsHashes[index] = keccak256(c.request.initArgs);
        evidence.requestHashes[index] = c.requestHash;
        evidence.baseSalts[index] = c.baseSalt;
        evidence.effectiveSalts[index] = c.effectiveSalt;
        evidence.initCalldataHashes[index] = keccak256(SleeveDeployerHelper._buildInitializer(c.request, c.controller));
        evidence.registryRegistered[index] = c.registry.registered;
        evidence.registryApprovals[index] = c.registry.approved;
        evidence.registryAssets[index] = c.registry.asset;
        evidence.registryPrincipalAssets[index] = c.registry.principalAssets;
        evidence.sleeveControllers[index] = c.controller;
        evidence.sleeveAssets[index] = c.request.asset;
        evidence.sleevePrincipalAssets[index] = 0;
        // Total assets are donation/exchange-rate sensitive and are recorded, not required to be zero.
        evidence.observedSleeveTotalAssets[index] = c.observedTotalAssets;
        evidence.observedSleeveTotalAssetsHealthy[index] = c.observedTotalAssetsHealthy;
        evidence.sleeveOperational[index] = c.observedOperational;
        evidence.sleevePaused[index] = c.observedPaused;
    }

    function _collectTyped(
        Evidence memory evidence,
        SleeveDeployerHelper.SleeveRequest memory request,
        address sleeve,
        uint256 index
    ) private view {
        if (request.initType == SleeveDeployerHelper.InitType.Basic) return;
        if (request.initType == SleeveDeployerHelper.InitType.Manual) {
            address operator = abi.decode(request.initArgs, (address));
            require(SleeveManual(sleeve).operator() == operator, "Staking Manual operator mismatch");
            evidence.manualOperators[index] = operator;
            return;
        }
        if (request.initType == SleeveDeployerHelper.InitType.ERC4626) {
            address vault = abi.decode(request.initArgs, (address));
            require(address(Sleeve4626(sleeve).vault()) == vault, "Staking ERC4626 vault mismatch");
            evidence.erc4626Vaults[index] = vault;
            return;
        }

        SleeveCurve.CurveLaunchParams memory params = abi.decode(request.initArgs, (SleeveCurve.CurveLaunchParams));
        SleeveCurve.CurveInitParams memory venue = params.venue;
        SleeveCurve curve = SleeveCurve(sleeve);
        require(address(curve.otherAsset()) == venue.otherAsset, "Staking Curve other asset mismatch");
        require(address(curve.curvePool()) == venue.pool, "Staking Curve pool mismatch");
        require(address(curve.lpToken()) == venue.pool, "Staking Curve LP token mismatch");
        require(curve.underlyingIndex() == venue.underlyingIndex, "Staking Curve underlying index mismatch");
        require(curve.otherIndex() == venue.otherIndex, "Staking Curve other index mismatch");
        require(curve.targetOtherPpm() == venue.otherSharePpm, "Staking Curve share mismatch");
        require(address(curve.gauge()) == venue.gauge, "Staking Curve gauge mismatch");
        require(curve.maxLpTokens() == params.maxLpTokens, "Staking Curve LP cap mismatch");
        require(curve.priceReference() == venue.priceReference, "Staking Curve price reference mismatch");
        require(curve.maxPriceDeviationBps() == venue.maxPriceDeviationBps, "Staking Curve price deviation mismatch");
        require(curve.rewardSwapAdapter() == params.rewardSwapAdapter, "Staking Curve reward adapter mismatch");
        require(address(curve.cygldController()) == venue.cygldController, "Staking Curve controller mismatch");
        require(curve.basketSwapAdapter() == venue.basketSwapAdapter, "Staking Curve basket adapter mismatch");
        address[] memory observedRewards = curve.rewardTokens();
        require(
            keccak256(abi.encode(observedRewards)) == keccak256(abi.encode(params.rewardTokens)),
            "Staking Curve reward tokens mismatch"
        );

        evidence.curveOtherAssets[index] = venue.otherAsset;
        evidence.curvePools[index] = venue.pool;
        evidence.curveLpTokens[index] = address(curve.lpToken());
        evidence.curveUnderlyingIndices[index] = venue.underlyingIndex;
        evidence.curveOtherIndices[index] = venue.otherIndex;
        evidence.curveOtherSharePpm[index] = venue.otherSharePpm;
        evidence.curveGauges[index] = venue.gauge;
        evidence.curveMaxLpTokens[index] = params.maxLpTokens;
        evidence.curvePriceReferences[index] = venue.priceReference;
        evidence.curveMaxPriceDeviationBps[index] = venue.maxPriceDeviationBps;
        evidence.curveRewardSwapAdapters[index] = params.rewardSwapAdapter;
        evidence.curveRewardTokens[index] = abi.encode(observedRewards);
        evidence.curveRewardTokenHashes[index] = keccak256(abi.encode(observedRewards));
        evidence.curveRewardTokenCounts[index] = observedRewards.length;
        evidence.curveCygldControllers[index] = venue.cygldController;
        evidence.curveBasketSwapAdapters[index] = venue.basketSwapAdapter;
    }

    function _observeTotalAssets(address sleeve) private view returns (bool healthy, uint256 value) {
        (bool ok, bytes memory data) = sleeve.staticcall(abi.encodeWithSelector(ISleeve.totalAssets.selector));
        if (!ok || data.length != 32) return (false, 0);
        return (true, abi.decode(data, (uint256)));
    }

    function _committedSleeves(bytes memory initializerCalldata)
        private
        pure
        returns (DiamondInit.LaunchSleeve[] memory sleeves)
    {
        require(initializerCalldata.length >= 4, "Staking initializer calldata malformed");
        bytes4 selector;
        assembly {
            selector := mload(add(initializerCalldata, 0x20))
        }
        require(selector == DiamondInit.finalize.selector, "Staking initializer selector mismatch");
        bytes memory args = new bytes(initializerCalldata.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = initializerCalldata[i + 4];
        }
        (DiamondInit.InitConfig memory initCfg,,) = abi.decode(args, (DiamondInit.InitConfig, string, string));
        sleeves = initCfg.sleeves;
    }

    function _allocate(uint256 count) private pure returns (Evidence memory evidence) {
        evidence.sleeves = new address[](count);
        evidence.controllers = new address[](count);
        evidence.implementations = new address[](count);
        evidence.proxyImplementations = new address[](count);
        evidence.committedImplementationCodeHashes = new bytes32[](count);
        evidence.observedImplementationCodeHashes = new bytes32[](count);
        evidence.proxyRuntimeCodeHashes = new bytes32[](count);
        evidence.assets = new address[](count);
        evidence.approvals = new bool[](count);
        evidence.requestedOperational = new bool[](count);
        evidence.requestedLocalPaused = new bool[](count);
        evidence.principalCaps = new uint256[](count);
        evidence.initTypes = new uint256[](count);
        evidence.initArgs = new bytes[](count);
        evidence.initArgsHashes = new bytes32[](count);
        evidence.requestHashes = new bytes32[](count);
        evidence.baseSalts = new bytes32[](count);
        evidence.effectiveSalts = new bytes32[](count);
        evidence.initCalldataHashes = new bytes32[](count);
        evidence.registryRegistered = new bool[](count);
        evidence.registryApprovals = new bool[](count);
        evidence.registryAssets = new address[](count);
        evidence.registryPrincipalAssets = new uint256[](count);
        evidence.sleeveControllers = new address[](count);
        evidence.sleeveAssets = new address[](count);
        evidence.sleevePrincipalAssets = new uint256[](count);
        evidence.observedSleeveTotalAssets = new uint256[](count);
        evidence.observedSleeveTotalAssetsHealthy = new bool[](count);
        evidence.sleeveOperational = new bool[](count);
        evidence.sleevePaused = new bool[](count);
        evidence.manualOperators = new address[](count);
        evidence.erc4626Vaults = new address[](count);
        evidence.curveOtherAssets = new address[](count);
        evidence.curvePools = new address[](count);
        evidence.curveLpTokens = new address[](count);
        evidence.curveUnderlyingIndices = new int256[](count);
        evidence.curveOtherIndices = new int256[](count);
        evidence.curveOtherSharePpm = new uint256[](count);
        evidence.curveGauges = new address[](count);
        evidence.curveMaxLpTokens = new uint256[](count);
        evidence.curvePriceReferences = new uint256[](count);
        evidence.curveMaxPriceDeviationBps = new uint256[](count);
        evidence.curveRewardSwapAdapters = new address[](count);
        evidence.curveRewardTokens = new bytes[](count);
        evidence.curveRewardTokenHashes = new bytes32[](count);
        evidence.curveRewardTokenCounts = new uint256[](count);
        evidence.curveCygldControllers = new address[](count);
        evidence.curveBasketSwapAdapters = new address[](count);
    }

    function _serializeIdentity(Vm vm_, string memory label, string memory out, Evidence memory evidence)
        private
        returns (string memory)
    {
        out = vm_.serializeAddress(label, "sleeves", evidence.sleeves);
        out = vm_.serializeAddress(label, "controllers", evidence.controllers);
        out = vm_.serializeAddress(label, "implementations", evidence.implementations);
        out = vm_.serializeAddress(label, "proxyImplementations", evidence.proxyImplementations);
        out = vm_.serializeBytes32(
            label, "committedImplementationCodeHashes", evidence.committedImplementationCodeHashes
        );
        out = vm_.serializeBytes32(label, "observedImplementationCodeHashes", evidence.observedImplementationCodeHashes);
        out = vm_.serializeBytes32(label, "proxyRuntimeCodeHashes", evidence.proxyRuntimeCodeHashes);
        out = vm_.serializeAddress(label, "sleeveControllers", evidence.sleeveControllers);
        out = vm_.serializeAddress(label, "sleeveAssets", evidence.sleeveAssets);
        return out;
    }

    function _serializeConfiguration(Vm vm_, string memory label, string memory out, Evidence memory evidence)
        private
        returns (string memory)
    {
        out = vm_.serializeAddress(label, "assets", evidence.assets);
        out = vm_.serializeBool(label, "approvals", evidence.approvals);
        out = vm_.serializeBool(label, "requestedOperational", evidence.requestedOperational);
        out = vm_.serializeBool(label, "requestedLocalPaused", evidence.requestedLocalPaused);
        out = vm_.serializeUint(label, "principalCaps", evidence.principalCaps);
        out = vm_.serializeUint(label, "initTypes", evidence.initTypes);
        out = vm_.serializeBytes(label, "initArgs", evidence.initArgs);
        out = vm_.serializeBytes32(label, "initArgsHashes", evidence.initArgsHashes);
        out = vm_.serializeBool(label, "registryRegistered", evidence.registryRegistered);
        out = vm_.serializeBool(label, "registryApprovals", evidence.registryApprovals);
        out = vm_.serializeAddress(label, "registryAssets", evidence.registryAssets);
        out = vm_.serializeUint(label, "registryPrincipalAssets", evidence.registryPrincipalAssets);
        out = vm_.serializeUint(label, "sleevePrincipalAssets", evidence.sleevePrincipalAssets);
        out = vm_.serializeUint(label, "observedSleeveTotalAssets", evidence.observedSleeveTotalAssets);
        out = vm_.serializeBool(label, "observedSleeveTotalAssetsHealthy", evidence.observedSleeveTotalAssetsHealthy);
        out = vm_.serializeBool(label, "sleeveOperational", evidence.sleeveOperational);
        out = vm_.serializeBool(label, "sleevePaused", evidence.sleevePaused);
        return out;
    }

    function _serializeTypedConfiguration(Vm vm_, string memory label, string memory out, Evidence memory evidence)
        private
        returns (string memory)
    {
        out = vm_.serializeAddress(label, "manualOperators", evidence.manualOperators);
        out = vm_.serializeAddress(label, "erc4626Vaults", evidence.erc4626Vaults);
        out = vm_.serializeAddress(label, "curveOtherAssets", evidence.curveOtherAssets);
        out = vm_.serializeAddress(label, "curvePools", evidence.curvePools);
        out = vm_.serializeAddress(label, "curveLpTokens", evidence.curveLpTokens);
        out = vm_.serializeInt(label, "curveUnderlyingIndices", evidence.curveUnderlyingIndices);
        out = vm_.serializeInt(label, "curveOtherIndices", evidence.curveOtherIndices);
        out = vm_.serializeUint(label, "curveOtherSharePpm", evidence.curveOtherSharePpm);
        out = vm_.serializeAddress(label, "curveGauges", evidence.curveGauges);
        out = vm_.serializeUint(label, "curveMaxLpTokens", evidence.curveMaxLpTokens);
        out = vm_.serializeUint(label, "curvePriceReferences", evidence.curvePriceReferences);
        out = vm_.serializeUint(label, "curveMaxPriceDeviationBps", evidence.curveMaxPriceDeviationBps);
        out = vm_.serializeAddress(label, "curveRewardSwapAdapters", evidence.curveRewardSwapAdapters);
        out = vm_.serializeBytes(label, "curveRewardTokens", evidence.curveRewardTokens);
        out = vm_.serializeBytes32(label, "curveRewardTokenHashes", evidence.curveRewardTokenHashes);
        out = vm_.serializeUint(label, "curveRewardTokenCounts", evidence.curveRewardTokenCounts);
        out = vm_.serializeAddress(label, "curveCygldControllers", evidence.curveCygldControllers);
        out = vm_.serializeAddress(label, "curveBasketSwapAdapters", evidence.curveBasketSwapAdapters);
        return out;
    }

    function _serializeCommitments(Vm vm_, string memory label, string memory out, Evidence memory evidence)
        private
        returns (string memory)
    {
        out = vm_.serializeBytes32(label, "requestHashes", evidence.requestHashes);
        out = vm_.serializeBytes32(label, "baseSalts", evidence.baseSalts);
        out = vm_.serializeBytes32(label, "effectiveSalts", evidence.effectiveSalts);
        out = vm_.serializeBytes32(label, "initCalldataHashes", evidence.initCalldataHashes);
        return out;
    }
}
