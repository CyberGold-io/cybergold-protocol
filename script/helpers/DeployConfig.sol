// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Vm} from "forge-std/Vm.sol";

/// @notice JSON-backed deployment config loader for scripts/tests.
library DeployConfig {
    struct QueueConfig {
        uint64 claimExpiry;
        uint256 headSweepLimit;
        uint256 autoProcessMax;
    }

    struct BasketAssets {
        string[] names;
        string[] symbols;
        address[] addresses;
        uint256[] targetsPpm;
        uint256[] goldRefGramsFp18;
    }

    struct BasketConfig {
        string name;
        string symbol;
        uint256 cygldRefGramsFp18;
        uint256 maxTotalSupply;
        uint256 issuanceFeePpm;
        uint256 redemptionFeePpm;
        BasketAssets assets;
    }

    struct StakingConfig {
        string name;
        string symbol;
        address[] withdrawers;
    }

    struct GovernanceConfig {
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

    struct ProtocolConfig {
        address admin;
        address safeWallet;
        address allocator;
        uint256 performanceFeePpm;
        QueueConfig queue;
        BasketConfig basket;
        StakingConfig staking;
        GovernanceConfig governance;
    }

    struct ForkFundingConfig {
        bool enabled;
        address[] fundAddrs;
        uint256 ethPerAddr;
        address tokenHolder;
        uint256 holderEth;
        string[] tokenSymbols;
        address[] tokenAddresses;
        address[] tokenHolders;
        uint256[] tokenPerAddr;
    }

    struct ForkConfig {
        string rpcUrl;
        ForkFundingConfig funding;
    }

    function configPath(Vm vm_) internal view returns (string memory path) {
        string memory defaultPath = "";
        path = vm_.envOr("DEPLOY_CONFIG_PATH", defaultPath);
        if (bytes(path).length != 0) {
            return path;
        }

        string memory root = vm_.projectRoot();
        string memory local = string.concat(root, "/config/deploy-config.json");
        if (vm_.exists(local)) {
            return local;
        }

        string memory parent = string.concat(root, "/../../config/deploy-config.json");
        if (vm_.exists(parent)) {
            return parent;
        }

        return local;
    }

    function loadProtocol(Vm vm_) internal view returns (ProtocolConfig memory cfg) {
        string memory json = _readJson(vm_);
        cfg.admin = vm_.parseJsonAddress(json, ".protocol.admin");
        cfg.safeWallet = vm_.parseJsonAddress(json, ".protocol.safeWallet");
        cfg.allocator = vm_.parseJsonAddress(json, ".protocol.allocator");
        cfg.performanceFeePpm = _parseUintString(vm_, json, ".protocol.performanceFeePpm");

        cfg.queue.claimExpiry = uint64(_parseUintString(vm_, json, ".protocol.queue.claimExpiry"));
        cfg.queue.headSweepLimit = _parseUintString(vm_, json, ".protocol.queue.headSweepLimit");
        cfg.queue.autoProcessMax = _parseUintString(vm_, json, ".protocol.queue.autoProcessMax");

        cfg.basket.name = vm_.parseJsonString(json, ".protocol.basket.name");
        cfg.basket.symbol = vm_.parseJsonString(json, ".protocol.basket.symbol");
        cfg.basket.cygldRefGramsFp18 = _parseUintString(vm_, json, ".protocol.basket.cygldRefGramsFp18");
        cfg.basket.maxTotalSupply = _parseUintString(vm_, json, ".protocol.basket.maxTotalSupply");
        cfg.basket.issuanceFeePpm = _parseUintString(vm_, json, ".protocol.basket.issuanceFeePpm");
        cfg.basket.redemptionFeePpm = _parseUintString(vm_, json, ".protocol.basket.redemptionFeePpm");
        cfg.basket.assets.names = vm_.parseJsonStringArray(json, ".protocol.basket.assets.names");
        cfg.basket.assets.symbols = vm_.parseJsonStringArray(json, ".protocol.basket.assets.symbols");
        cfg.basket.assets.addresses = vm_.parseJsonAddressArray(json, ".protocol.basket.assets.addresses");
        cfg.basket.assets.targetsPpm = _parseUintStringArray(vm_, json, ".protocol.basket.assets.targetsPpm");
        cfg.basket.assets.goldRefGramsFp18 =
            _parseUintStringArray(vm_, json, ".protocol.basket.assets.goldRefGramsFp18");
        _requireAssetLengths(cfg.basket.assets);

        cfg.staking.name = vm_.parseJsonString(json, ".protocol.staking.name");
        cfg.staking.symbol = vm_.parseJsonString(json, ".protocol.staking.symbol");
        cfg.staking.withdrawers = vm_.parseJsonAddressArray(json, ".protocol.staking.withdrawers");

        cfg.governance.executionDelay = _parseUintString(vm_, json, ".protocol.governance.executionDelay");
        cfg.governance.executionGracePeriod = _parseUintString(vm_, json, ".protocol.governance.executionGracePeriod");
        cfg.governance.name = vm_.parseJsonString(json, ".protocol.governance.name");
        cfg.governance.tokenSymbol = vm_.parseJsonString(json, ".protocol.governance.tokenSymbol");
        cfg.governance.tokenInitialHolder = vm_.parseJsonAddress(json, ".protocol.governance.tokenInitialHolder");
        cfg.governance.tokenInitialSupply = _parseUintString(vm_, json, ".protocol.governance.tokenInitialSupply");
        cfg.governance.tokenTreasurySupply = _parseUintString(vm_, json, ".protocol.governance.tokenTreasurySupply");
        cfg.governance.votingDelay = _parseUintString(vm_, json, ".protocol.governance.votingDelay");
        cfg.governance.votingPeriod = _parseUintString(vm_, json, ".protocol.governance.votingPeriod");
        cfg.governance.proposalThresholdNumerator =
            _parseUintString(vm_, json, ".protocol.governance.proposalThresholdNumerator");
        cfg.governance.quorumNumerator = _parseUintString(vm_, json, ".protocol.governance.quorumNumerator");
    }

    function loadForkConfig(Vm vm_) internal view returns (ForkConfig memory cfg) {
        string memory json = _readJson(vm_);
        cfg.rpcUrl = vm_.parseJsonString(json, ".fork.rpcUrl");
        cfg.funding = _loadForkFunding(vm_, json);
    }

    function loadForkFunding(Vm vm_) internal view returns (ForkFundingConfig memory cfg) {
        string memory json = _readJson(vm_);
        cfg = _loadForkFunding(vm_, json);
    }

    function _loadForkFunding(Vm vm_, string memory json) private pure returns (ForkFundingConfig memory cfg) {
        cfg.enabled = vm_.parseJsonBool(json, ".fork.funding.enabled");
        cfg.fundAddrs = vm_.parseJsonAddressArray(json, ".fork.funding.fundAddrs");
        cfg.ethPerAddr = _parseUintString(vm_, json, ".fork.funding.ethPerAddr");
        cfg.tokenHolder = vm_.parseJsonAddress(json, ".fork.funding.tokenHolder");
        cfg.holderEth = _parseUintString(vm_, json, ".fork.funding.holderEth");
        cfg.tokenSymbols = vm_.parseJsonStringArray(json, ".fork.funding.tokenFunding.symbols");
        cfg.tokenAddresses = vm_.parseJsonAddressArray(json, ".fork.funding.tokenFunding.addresses");
        cfg.tokenHolders = vm_.parseJsonAddressArray(json, ".fork.funding.tokenFunding.holders");
        cfg.tokenPerAddr = _parseUintStringArray(vm_, json, ".fork.funding.tokenFunding.perAddr");
        _requireTokenFundingLengths(cfg);
    }

    function assetAddressBySymbol(ProtocolConfig memory cfg, string memory symbol) internal pure returns (address) {
        bytes32 needle = keccak256(bytes(symbol));
        for (uint256 i; i < cfg.basket.assets.symbols.length; ++i) {
            if (keccak256(bytes(cfg.basket.assets.symbols[i])) == needle) {
                return cfg.basket.assets.addresses[i];
            }
        }
        return address(0);
    }

    function applyProtocolEnvOverrides(Vm vm_, ProtocolConfig memory cfg)
        internal
        view
        returns (ProtocolConfig memory)
    {
        cfg.admin = vm_.envOr("DEPLOY_ADMIN", cfg.admin);
        cfg.safeWallet = vm_.envOr("DEPLOY_SAFE_WALLET", cfg.safeWallet);
        cfg.allocator = vm_.envOr("DEPLOY_ALLOCATOR", cfg.allocator);
        cfg.performanceFeePpm = vm_.envOr("STAKING_PERFORMANCE_FEE_PPM", cfg.performanceFeePpm);
        cfg.queue.claimExpiry = uint64(vm_.envOr("STAKING_CLAIM_EXPIRY", uint256(cfg.queue.claimExpiry)));
        cfg.queue.headSweepLimit = vm_.envOr("STAKING_HEAD_SWEEP_LIMIT", cfg.queue.headSweepLimit);
        cfg.queue.autoProcessMax = vm_.envOr("STAKING_AUTO_PROCESS_MAX", cfg.queue.autoProcessMax);
        cfg.basket.name = vm_.envOr("CORE_NAME", cfg.basket.name);
        cfg.basket.symbol = vm_.envOr("CORE_SYMBOL", cfg.basket.symbol);
        if (vm_.envExists("CORE_MAX_TOTAL_SUPPLY")) {
            cfg.basket.maxTotalSupply = vm_.envUint("CORE_MAX_TOTAL_SUPPLY");
        }
        if (vm_.envExists("CORE_ISSUANCE_FEE_PPM")) {
            cfg.basket.issuanceFeePpm = vm_.envUint("CORE_ISSUANCE_FEE_PPM");
        }
        if (vm_.envExists("CORE_REDEMPTION_FEE_PPM")) {
            cfg.basket.redemptionFeePpm = vm_.envUint("CORE_REDEMPTION_FEE_PPM");
        }
        cfg.staking.name = vm_.envOr("STAKING_NAME", cfg.staking.name);
        cfg.staking.symbol = vm_.envOr("STAKING_SYMBOL", cfg.staking.symbol);
        if (vm_.envExists("STAKING_WITHDRAWERS")) {
            cfg.staking.withdrawers = vm_.envAddress("STAKING_WITHDRAWERS", ",");
        }
        cfg.governance.executionDelay = vm_.envOr("GOV_EXECUTION_DELAY", cfg.governance.executionDelay);
        cfg.governance.executionGracePeriod =
            vm_.envOr("GOV_EXECUTION_GRACE_PERIOD", cfg.governance.executionGracePeriod);
        cfg.governance.name = vm_.envOr("GOV_NAME", cfg.governance.name);
        cfg.governance.tokenSymbol = vm_.envOr("CYGOV_SYMBOL", cfg.governance.tokenSymbol);
        cfg.governance.tokenInitialHolder = vm_.envOr("CYGOV_INITIAL_HOLDER", cfg.governance.tokenInitialHolder);
        cfg.governance.tokenInitialSupply = vm_.envOr("CYGOV_INITIAL_SUPPLY", cfg.governance.tokenInitialSupply);
        cfg.governance.tokenTreasurySupply = vm_.envOr("CYGOV_TREASURY_SUPPLY", cfg.governance.tokenTreasurySupply);
        cfg.governance.votingDelay = vm_.envOr("GOV_VOTING_DELAY", cfg.governance.votingDelay);
        cfg.governance.votingPeriod = vm_.envOr("GOV_VOTING_PERIOD", cfg.governance.votingPeriod);
        require(!vm_.envExists("GOV_PROPOSAL_THRESHOLD"), "legacy GOV_PROPOSAL_THRESHOLD is forbidden");
        require(!vm_.envExists("GOV_QUORUM_FRACTION"), "legacy GOV_QUORUM_FRACTION is forbidden");
        cfg.governance.proposalThresholdNumerator =
            vm_.envOr("GOV_PROPOSAL_THRESHOLD_NUMERATOR", cfg.governance.proposalThresholdNumerator);
        cfg.governance.quorumNumerator = vm_.envOr("GOV_QUORUM_NUMERATOR", cfg.governance.quorumNumerator);
        return cfg;
    }

    function _readJson(Vm vm_) private view returns (string memory json) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        json = vm_.readFile(configPath(vm_));
    }

    function _parseUintString(Vm vm_, string memory json, string memory key) private pure returns (uint256) {
        string memory raw = vm_.parseJsonString(json, key);
        return vm_.parseUint(raw);
    }

    function _parseUintStringArray(Vm vm_, string memory json, string memory key)
        private
        pure
        returns (uint256[] memory out)
    {
        string[] memory raw = vm_.parseJsonStringArray(json, key);
        uint256 len = raw.length;
        out = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            out[i] = vm_.parseUint(raw[i]);
        }
    }

    function _requireAssetLengths(BasketAssets memory assets) private pure {
        uint256 len = assets.addresses.length;
        require(len != 0, "basket empty");
        require(assets.names.length == len, "basket names length mismatch");
        require(assets.symbols.length == len, "basket symbols length mismatch");
        require(assets.targetsPpm.length == len, "basket targets length mismatch");
        require(assets.goldRefGramsFp18.length == len, "basket gold ref length mismatch");
    }

    function _requireTokenFundingLengths(ForkFundingConfig memory cfg) private pure {
        require(cfg.tokenSymbols.length == cfg.tokenPerAddr.length, "token funding length mismatch");
        require(cfg.tokenSymbols.length == cfg.tokenAddresses.length, "token address length mismatch");
        require(cfg.tokenSymbols.length == cfg.tokenHolders.length, "token holder length mismatch");
    }
}
