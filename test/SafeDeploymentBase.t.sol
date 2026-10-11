// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {SafeDeploymentBase} from "script/helpers/SafeDeploymentBase.sol";

contract SafeDeploymentHarness is SafeDeploymentBase {
    function validateOwnersAndThreshold(address[] memory owners, uint256 threshold) external pure {
        _validateOwners(owners);
        require(threshold > 0 && threshold <= owners.length, "SafeDeployment: invalid threshold");
    }

    function validateMainnetQuorum(address[] memory owners, uint256 threshold) external pure {
        _validateMainnetQuorum(owners, threshold);
    }

    function predict(
        address factory,
        address singleton,
        bytes memory initializer,
        uint256 saltNonce,
        bytes memory proxyCreationCode
    ) external pure returns (address) {
        return _predictAddress(factory, singleton, initializer, saltNonce, proxyCreationCode);
    }

    function assertConfig(
        address safeAddress,
        address[] memory owners,
        uint256 threshold,
        address singleton,
        address fallbackHandler,
        string memory version
    ) external view {
        SafeConfig memory config = SafeConfig({
            owners: owners,
            threshold: threshold,
            expectedAddress: safeAddress,
            singleton: singleton,
            proxyFactory: address(1),
            fallbackHandler: fallbackHandler,
            version: version,
            saltNonce: 1
        });
        _assertSafeConfig(safeAddress, config);
    }
}

contract MockSafeProxyState {
    address internal immutable OWNER_A;
    address internal immutable OWNER_B;
    uint256 internal immutable THRESHOLD;
    mapping(bytes32 => uint256) internal unexpectedState;
    bytes32 internal constant GUARD_STORAGE_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    bytes32 internal constant MODULE_KEY = keccak256("mock.safe.module");
    bytes32 internal constant NONCE_KEY = keccak256("mock.safe.nonce");

    constructor(address singleton, address fallbackHandler, address ownerA, address ownerB, uint256 threshold) {
        OWNER_A = ownerA;
        OWNER_B = ownerB;
        THRESHOLD = threshold;
        bytes32 handlerSlot = keccak256("fallback_manager.handler.address");
        assembly ("memory-safe") {
            sstore(0, singleton)
            sstore(handlerSlot, fallbackHandler)
        }
    }

    // Safe's public version getter is uppercase in the deployed compatibility ABI.
    // forge-lint: disable-next-line(mixed-case-function)
    function VERSION() external pure returns (string memory) {
        return "1.5.0";
    }

    function getThreshold() external view returns (uint256) {
        return THRESHOLD;
    }

    function getOwners() external view returns (address[] memory owners) {
        owners = new address[](2);
        owners[0] = OWNER_A;
        owners[1] = OWNER_B;
    }

    function isOwner(address owner) external view returns (bool) {
        return owner == OWNER_A || owner == OWNER_B;
    }

    function getModulesPaginated(address start, uint256)
        external
        view
        returns (address[] memory modules, address next)
    {
        require(start == address(0x1), "bad sentinel");
        address configuredModule = address(uint160(unexpectedState[MODULE_KEY]));
        if (configuredModule == address(0)) {
            modules = new address[](0);
            next = address(0x1);
        } else {
            modules = new address[](1);
            modules[0] = configuredModule;
            next = address(0x1);
        }
    }

    function nonce() external view returns (uint256) {
        return unexpectedState[NONCE_KEY];
    }

    function setUnexpectedState(address guard_, address module_, uint256 nonce_) external {
        bytes32 guardSlot = GUARD_STORAGE_SLOT;
        assembly ("memory-safe") {
            sstore(guardSlot, guard_)
        }
        unexpectedState[MODULE_KEY] = uint256(uint160(module_));
        unexpectedState[NONCE_KEY] = nonce_;
    }
}

contract SafeDeploymentBaseTest is Test {
    SafeDeploymentHarness internal harness;
    address internal constant OWNER_A = address(0xA1);
    address internal constant OWNER_B = address(0xB2);
    address internal constant SINGLETON = address(0xC3);
    address internal constant HANDLER = address(0xD4);

    function setUp() external {
        harness = new SafeDeploymentHarness();
    }

    function testOwnerAndThresholdValidation() external view {
        address[] memory owners = _owners();
        harness.validateOwnersAndThreshold(owners, 2);
    }

    function testOwnerValidationRejectsZeroDuplicateAndInvalidThreshold() external {
        address[] memory owners = _owners();
        owners[1] = address(0);
        vm.expectRevert("SafeDeployment: owner is zero");
        harness.validateOwnersAndThreshold(owners, 1);

        owners[1] = OWNER_A;
        vm.expectRevert("SafeDeployment: duplicate owner");
        harness.validateOwnersAndThreshold(owners, 1);

        owners[1] = OWNER_B;
        vm.expectRevert("SafeDeployment: invalid threshold");
        harness.validateOwnersAndThreshold(owners, 0);
        vm.expectRevert("SafeDeployment: invalid threshold");
        harness.validateOwnersAndThreshold(owners, 3);
    }

    function testMainnetQuorumRequiresTwoOfThreeMinimum() external {
        address[] memory twoOwners = _owners();
        vm.expectRevert("SafeDeployment: mainnet requires at least 3 owners");
        harness.validateMainnetQuorum(twoOwners, 2);

        address[] memory threeOwners = new address[](3);
        threeOwners[0] = OWNER_A;
        threeOwners[1] = OWNER_B;
        threeOwners[2] = address(0xC3);
        vm.expectRevert("SafeDeployment: mainnet requires threshold at least 2");
        harness.validateMainnetQuorum(threeOwners, 1);
        harness.validateMainnetQuorum(threeOwners, 2);
        harness.validateMainnetQuorum(threeOwners, 3);
    }

    function testPredictionIsStableAndSaltSensitive() external view {
        bytes memory initializer = hex"123456";
        bytes memory creationCode = hex"6080604052";
        address first = harness.predict(address(0xF1), SINGLETON, initializer, 1, creationCode);
        address repeated = harness.predict(address(0xF1), SINGLETON, initializer, 1, creationCode);
        address secondSalt = harness.predict(address(0xF1), SINGLETON, initializer, 2, creationCode);
        assertEq(first, repeated);
        assertNotEq(first, secondSalt);
    }

    function testSafeStateAttestationAndMismatchFailures() external {
        address[] memory owners = _owners();
        MockSafeProxyState safe = new MockSafeProxyState(SINGLETON, HANDLER, OWNER_A, OWNER_B, 2);
        harness.assertConfig(address(safe), owners, 2, SINGLETON, HANDLER, "1.5.0");

        vm.expectRevert("SafeDeployment: version mismatch");
        harness.assertConfig(address(safe), owners, 2, SINGLETON, HANDLER, "1.4.1");
        vm.expectRevert("SafeDeployment: threshold mismatch");
        harness.assertConfig(address(safe), owners, 1, SINGLETON, HANDLER, "1.5.0");
        vm.expectRevert("SafeDeployment: singleton mismatch");
        harness.assertConfig(address(safe), owners, 2, address(0xBAD), HANDLER, "1.5.0");
        vm.expectRevert("SafeDeployment: fallback handler mismatch");
        harness.assertConfig(address(safe), owners, 2, SINGLETON, address(0xBAD), "1.5.0");

        safe.setUnexpectedState(address(0xBAD), address(0), 0);
        vm.expectRevert("SafeDeployment: unexpected guard");
        harness.assertConfig(address(safe), owners, 2, SINGLETON, HANDLER, "1.5.0");

        safe.setUnexpectedState(address(0), address(0xBAD), 0);
        vm.expectRevert("SafeDeployment: unexpected module");
        harness.assertConfig(address(safe), owners, 2, SINGLETON, HANDLER, "1.5.0");

        safe.setUnexpectedState(address(0), address(0), 1);
        vm.expectRevert("SafeDeployment: unexpected nonce");
        harness.assertConfig(address(safe), owners, 2, SINGLETON, HANDLER, "1.5.0");
    }

    function _owners() internal pure returns (address[] memory owners) {
        owners = new address[](2);
        owners[0] = OWNER_A;
        owners[1] = OWNER_B;
    }
}
