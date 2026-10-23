// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";

import {DeploymentHelper} from "staking/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "staking/deploy/DeploymentTypes.sol";
import {SleeveDeployerHelper} from "staking/deploy/SleeveDeployerHelper.sol";
import {SleeveRequestBuilder} from "staking/deploy/SleeveRequestBuilder.sol";
import {IStakingFinalizer} from "staking/deploy/StakingLaunchTypes.sol";
import {LensFacet} from "staking/facets/LensFacet.sol";
import {LibStakingLaunch} from "staking/libraries/LibStakingLaunch.sol";

import {MockCyberGold} from "staking-mocks/MockCyberGold.sol";
import {MockSleeve} from "staking-mocks/MockSleeve.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";

/// @dev Arachnid deterministic-deployment-proxy compatible input: `salt || initCode`.
/// The caller intentionally does not depend on the optional 20-byte return value.
contract RawCreate2Factory {
    fallback() external payable {
        assembly {
            let initCodeSize := sub(calldatasize(), 0x20)
            calldatacopy(0, 0x20, initCodeSize)
            let deployed := create2(callvalue(), 0, initCodeSize, calldataload(0))
            if iszero(extcodesize(deployed)) { revert(0, 0) }
            mstore(0, deployed)
            return(0x0c, 0x14)
        }
    }
}

contract ShellFactoryGovernance {}

contract StakingCommittedShellFactoryTest is Test {
    address internal constant SAFE_OWNER = address(0xA11CE);
    address internal constant WITHDRAWER = address(0xB0B);
    address internal constant ALLOCATOR = address(0xCAFE);

    function testExternalFactoryFrontRunAdoptionAndIdempotentFinalization() external {
        RawCreate2Factory factory = new RawCreate2Factory();
        (DeploymentTypes.DeployConfig memory cfg,) = _config(address(factory));
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);

        bytes memory initCode = DeploymentHelper.shellInitCode(out);
        assertEq(DeploymentHelper.shellInitCodeHash(out), keccak256(initCode));
        address predicted = DeploymentHelper.predictedShell(cfg, out);

        // Counterfactual native dust is not protocol-created accounting and cannot
        // censor the exact zero-value shell creation.
        vm.deal(predicted, 1);
        address frontRunner = address(0xF00D);
        vm.deal(frontRunner, 1);
        vm.prank(frontRunner);
        (bool valueOk,) = address(factory).call{value: 1}(bytes.concat(cfg.shellSalt, initCode));
        assertFalse(valueOk);
        assertEq(predicted.code.length, 0);

        // Any sender may win the exact factory transaction. Sender identity and
        // return-data decoding are deliberately irrelevant.
        vm.prank(frontRunner);
        (bool createOk,) = address(factory).call(bytes.concat(cfg.shellSalt, initCode));
        assertTrue(createOk);
        assertGt(predicted.code.length, 0);
        assertEq(predicted.balance, 1);

        // The exact CREATE2 tuple is occupied after the winning transaction.
        (bool duplicateOk,) = address(factory).call(bytes.concat(cfg.shellSalt, initCode));
        assertFalse(duplicateOk);

        out = DeploymentHelper.adoptCommittedShell(cfg, out);
        assertEq(address(out.diamond), predicted);

        // A different permissionless relay may also win before the convenience
        // path runs. Exact phase/hash reconciliation makes that path idempotent.
        address relay = address(0xBEEF);
        vm.prank(relay);
        IStakingFinalizer(predicted).finalizeStaking(out.finalization);
        out = DeploymentHelper.finalizeCommitted(cfg, out);
        assertEq(out.sleeves.length, 1);
        (LibStakingLaunch.Phase phase, bytes32 finalizationHash) = LensFacet(predicted).stakingLaunchState();
        assertEq(uint8(phase), uint8(LibStakingLaunch.Phase.Finalized));
        assertEq(finalizationHash, out.payloadHash);

        // Reconciliation remains idempotent after the first successful read.
        out = DeploymentHelper.finalizeCommitted(cfg, out);
        assertEq(address(out.diamond), predicted);
    }

    function testAdoptionRejectsWrongSaltAndRuntime() external {
        RawCreate2Factory factory = new RawCreate2Factory();
        (DeploymentTypes.DeployConfig memory cfg,) = _config(address(factory));
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);

        DeploymentTypes.DeployConfig memory wrongSaltCfg = cfg;
        wrongSaltCfg.shellSalt = keccak256("wrong-staking-shell-salt");
        address wrongSaltCandidate = DeploymentHelper.predictedShell(wrongSaltCfg, out);
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentHelper.StakingDeploymentShellMissing.selector, wrongSaltCandidate)
        );
        this.adoptCommittedShell(wrongSaltCfg, out);

        address predicted = DeploymentHelper.predictedShell(cfg, out);
        vm.etch(predicted, hex"60006000fd");
        vm.expectRevert(abi.encodeWithSelector(DeploymentHelper.StakingDeploymentRuntimeMismatch.selector, predicted));
        this.adoptCommittedShell(cfg, out);
    }

    function testLocalHelperRequiresActualDeployerAndAdoptsExactOccupant() external {
        RawCreate2Factory factory = new RawCreate2Factory();
        (DeploymentTypes.DeployConfig memory cfg,) = _config(address(factory));
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentHelper.StakingDeploymentCreate2DeployerMismatch.selector, address(factory), address(this)
            )
        );
        this.deployCommittedShellLocal(cfg, out);

        cfg.create2Deployer = address(this);
        out = this.deployCommittedShellLocal(cfg, out);
        address first = address(out.diamond);
        out = this.deployCommittedShellLocal(cfg, out);
        assertEq(address(out.diamond), first);
    }

    function testFinalizeConvenienceRejectsUnknownLaunchState() external {
        RawCreate2Factory factory = new RawCreate2Factory();
        (DeploymentTypes.DeployConfig memory cfg,) = _config(address(factory));
        DeploymentTypes.DeployArtifacts memory out = DeploymentHelper.prepare(cfg);
        address predicted = DeploymentHelper.predictedShell(cfg, out);
        vm.etch(predicted, type(RawCreate2Factory).runtimeCode);

        vm.expectRevert(abi.encodeWithSelector(DeploymentHelper.StakingDeploymentRuntimeMismatch.selector, predicted));
        this.finalizeCommitted(cfg, out);
    }

    function adoptCommittedShell(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory out)
        external
        view
        returns (DeploymentTypes.DeployArtifacts memory)
    {
        return DeploymentHelper.adoptCommittedShell(cfg, out);
    }

    function deployCommittedShellLocal(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory out
    ) external returns (DeploymentTypes.DeployArtifacts memory) {
        return DeploymentHelper.deployCommittedShellLocal(cfg, out);
    }

    function finalizeCommitted(DeploymentTypes.DeployConfig memory cfg, DeploymentTypes.DeployArtifacts memory out)
        external
        returns (DeploymentTypes.DeployArtifacts memory)
    {
        return DeploymentHelper.finalizeCommitted(cfg, out);
    }

    function _config(address create2Deployer)
        private
        returns (DeploymentTypes.DeployConfig memory cfg, MockCyberGold core)
    {
        core = new MockCyberGold();
        cfg.safeWallet = MockSafeWalletFactory.deploy(SAFE_OWNER);
        cfg.name = "Staked CyberGold";
        cfg.symbol = "sCYGLD";
        cfg.coreDiamond = address(core);
        cfg.governanceDiamond = address(new ShellFactoryGovernance());
        cfg.withdrawers = new address[](1);
        cfg.withdrawers[0] = WITHDRAWER;
        cfg.claimExpiry = 7 days;
        cfg.headSweepLimit = 32;
        cfg.autoProcessMax = 16;
        cfg.performanceFeePpm = 100_000;
        cfg.allocators = new address[](1);
        cfg.allocators[0] = ALLOCATOR;
        cfg.sleeves = new SleeveDeployerHelper.SleeveRequest[](1);
        cfg.sleeves[0] = SleeveRequestBuilder.basic(address(new MockSleeve()), address(core), true, 1_000 ether);
        cfg.create2Deployer = create2Deployer;
        cfg.shellSalt = keccak256("staking-committed-shell-factory-test");
    }
}
