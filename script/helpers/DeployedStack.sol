// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {DeployConfig} from "script/helpers/DeployConfig.sol";
import {JsonUtils} from "script/helpers/JsonUtils.sol";

library DeployedStack {
    struct Protocol {
        address admin;
        address allocator;
        address coreDiamond;
        address stakingDiamond;
        address governanceDiamond;
    }

    struct Expectations {
        uint64 claimExpiry;
        uint256 headSweepLimit;
        uint256 autoProcessMax;
        uint256 govExecutionDelay;
        uint256 govExecutionGracePeriod;
        uint256 quorumNumerator;
    }

    struct Safe {
        address safe;
    }

    function loadProtocol(Vm vm_) internal view returns (Protocol memory p) {
        (bool ok, Protocol memory parsed) = tryLoadProtocol(vm_);
        require(ok, "DeployedStack: missing deploy-protocol.json");
        _requireNonZero(parsed);
        return parsed;
    }

    function tryLoadProtocol(Vm vm_) internal view returns (bool ok, Protocol memory p) {
        string memory path =
            vm_.envOr("DEPLOY_PROTOCOL_PATH", string.concat(vm_.projectRoot(), "/out/deploy-protocol.json"));

        // Deployment scripts intentionally read optional JSON artifacts.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        try vm_.readFile(path) returns (string memory json) {
            p.admin = JsonUtils.tryParseAddress(vm_, json, ".admin");
            p.allocator = JsonUtils.tryParseAddress(vm_, json, ".allocator");
            p.coreDiamond = JsonUtils.tryParseAddress(vm_, json, ".coreDiamond");
            p.stakingDiamond = JsonUtils.tryParseAddress(vm_, json, ".stakingDiamond");
            p.governanceDiamond = JsonUtils.tryParseAddress(vm_, json, ".governanceDiamond");
            ok = _anyNonZero(p);
        } catch {}
    }

    function loadExpectations(Vm vm_) internal view returns (Expectations memory e) {
        DeployConfig.ProtocolConfig memory cfg = DeployConfig.loadProtocol(vm_);
        cfg = DeployConfig.applyProtocolEnvOverrides(vm_, cfg);
        e.claimExpiry = cfg.queue.claimExpiry;
        e.headSweepLimit = cfg.queue.headSweepLimit;
        e.autoProcessMax = cfg.queue.autoProcessMax;
        e.govExecutionDelay = cfg.governance.executionDelay;
        e.govExecutionGracePeriod = cfg.governance.executionGracePeriod;
        e.quorumNumerator = cfg.governance.quorumNumerator;
    }

    function loadSafe(Vm vm_) internal view returns (Safe memory s) {
        (bool ok, Safe memory parsed) = tryLoadSafe(vm_);
        require(ok, "DeployedStack: missing deploy-safe.json");
        require(parsed.safe != address(0), "DeployedStack: safe missing");
        return parsed;
    }

    function tryLoadSafe(Vm vm_) internal view returns (bool ok, Safe memory s) {
        string memory path = vm_.envOr("DEPLOY_SAFE_PATH", string.concat(vm_.projectRoot(), "/out/deploy-safe.json"));

        // Deployment scripts intentionally read optional JSON artifacts.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        try vm_.readFile(path) returns (string memory json) {
            s.safe = JsonUtils.tryParseAddress(vm_, json, ".safe");
            ok = s.safe != address(0);
        } catch {}
    }

    function _anyNonZero(Protocol memory p) private pure returns (bool ok) {
        return p.coreDiamond != address(0) || p.stakingDiamond != address(0) || p.governanceDiamond != address(0)
            || p.admin != address(0) || p.allocator != address(0);
    }

    function _requireNonZero(Protocol memory p) private pure {
        require(p.admin != address(0), "DeployedStack: admin missing");
        require(p.coreDiamond != address(0), "DeployedStack: core diamond missing");
        require(p.stakingDiamond != address(0), "DeployedStack: staking diamond missing");
        require(p.governanceDiamond != address(0), "DeployedStack: governance diamond missing");
    }
}
