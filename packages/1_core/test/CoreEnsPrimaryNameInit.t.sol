// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {DefaultAdminAccessControlFacet} from "diamond-infra/facets/DefaultAdminAccessControlFacet.sol";
import {PausableFacet} from "diamond-infra/facets/PausableFacet.sol";
import {CoreEnsPrimaryNameInitBase, IEnsDefaultReverseRegistrar} from "../src/ens/CoreEnsPrimaryNameInit.sol";
import {ControllerTestBase} from "./helpers/ControllerTestBase.t.sol";

contract MockEnsDefaultReverseRegistrar is IEnsDefaultReverseRegistrar {
    mapping(address addr => string name) private _names;
    bool public persistSetName = true;

    function nameForAddr(address addr) external view returns (string memory) {
        return _names[addr];
    }

    function setName(string calldata name) external {
        if (persistSetName) _names[msg.sender] = name;
    }

    function setNameFor(address addr, string calldata name) external {
        _names[addr] = name;
    }

    function setPersistSetName(bool persist) external {
        persistSetName = persist;
    }
}

/// @dev Binds the production logic to a test registrar without delegatecall-visible configuration.
contract CoreEnsPrimaryNameInitHarness is CoreEnsPrimaryNameInitBase {
    address internal constant TEST_REGISTRAR = address(0xE115);

    function _expectedChainId() internal pure override returns (uint256) {
        return 1;
    }

    function _registrar() internal pure override returns (IEnsDefaultReverseRegistrar) {
        return IEnsDefaultReverseRegistrar(TEST_REGISTRAR);
    }

    function _expectedRegistrarCodeHash() internal pure virtual override returns (bytes32) {
        return keccak256(type(MockEnsDefaultReverseRegistrar).runtimeCode);
    }

    function _primaryName() internal pure override returns (string memory) {
        return "cybergold.eth";
    }
}

contract CoreEnsPrimaryNameWrongCodeHashHarness is CoreEnsPrimaryNameInitHarness {
    function _expectedRegistrarCodeHash() internal pure override returns (bytes32) {
        return bytes32(0);
    }
}

contract CoreEnsPrimaryNameInitTest is ControllerTestBase {
    bytes32 private constant VALIDATED_DIAMOND_CUT_STATE_SLOT =
        0xfef9e0d4830ecb9885f5f0122b2da44d5685ac964d58d6fbe52ef636cf84be43;
    address private constant TEST_REGISTRAR = address(0xE115);

    MockEnsDefaultReverseRegistrar private registrar;
    address private initializer;

    function setUp() public override {
        vm.chainId(1);
        super.setUp();

        vm.etch(TEST_REGISTRAR, type(MockEnsDefaultReverseRegistrar).runtimeCode);
        registrar = MockEnsDefaultReverseRegistrar(TEST_REGISTRAR);
        registrar.setPersistSetName(true);
        initializer = address(new CoreEnsPrimaryNameInitHarness());
    }

    function testEmptyCutSetsPrimaryNameAndPreservesCoreState() public {
        bytes32 topologyBefore = _topologyHash();
        uint256 selectorCountBefore = _selectorCount();
        bytes32 upgraderRole = DefaultAdminAccessControlFacet(diamond).upgraderRole();
        uint256 upgraderCountBefore = IAccessControlEnumerable(diamond).getRoleMemberCount(upgraderRole);
        address upgraderBefore = IAccessControlEnumerable(diamond).getRoleMember(upgraderRole, 0);
        address safeBefore = PausableFacet(diamond).safeWallet();
        string memory tokenNameBefore = IERC20Metadata(diamond).name();
        string memory tokenSymbolBefore = IERC20Metadata(diamond).symbol();

        vm.record();
        _executeEmptyCut();
        (, bytes32[] memory writes) = vm.accesses(diamond);

        assertEq(registrar.nameForAddr(diamond), "cybergold.eth");
        assertEq(_topologyHash(), topologyBefore, "selector topology changed");
        assertEq(_selectorCount(), selectorCountBefore, "selector count changed");
        assertEq(IAccessControlEnumerable(diamond).getRoleMemberCount(upgraderRole), upgraderCountBefore);
        assertEq(IAccessControlEnumerable(diamond).getRoleMember(upgraderRole, 0), upgraderBefore);
        assertEq(PausableFacet(diamond).safeWallet(), safeBefore);
        assertEq(IERC20Metadata(diamond).name(), tokenNameBefore);
        assertEq(IERC20Metadata(diamond).symbol(), tokenSymbolBefore);
        assertEq(uint256(vm.load(diamond, VALIDATED_DIAMOND_CUT_STATE_SLOT)), 0, "coordinator latch uncleared");
        _assertOnlyCoordinatorLatchWasWritten(writes);
    }

    function testExistingExpectedNameIsSafeToReplay() public {
        registrar.setNameFor(diamond, "cybergold.eth");

        _executeEmptyCut();

        assertEq(registrar.nameForAddr(diamond), "cybergold.eth");
    }

    function testRejectsConflictingExistingName() public {
        registrar.setNameFor(diamond, "another-name.eth");

        vm.expectRevert(
            abi.encodeWithSelector(
                CoreEnsPrimaryNameInitBase.EnsPrimaryNameUnexpectedCurrent.selector, keccak256("another-name.eth")
            )
        );
        _executeEmptyCut();

        assertEq(registrar.nameForAddr(diamond), "another-name.eth");
    }

    function testRejectsWrongChain() public {
        vm.chainId(11_155_111);

        vm.expectRevert(
            abi.encodeWithSelector(CoreEnsPrimaryNameInitBase.EnsPrimaryNameWrongChain.selector, uint256(11_155_111))
        );
        _executeEmptyCut();

        assertEq(registrar.nameForAddr(diamond), "");
    }

    function testRejectsRegistrarRuntimeMismatch() public {
        initializer = address(new CoreEnsPrimaryNameWrongCodeHashHarness());

        vm.expectRevert(
            abi.encodeWithSelector(
                CoreEnsPrimaryNameInitBase.EnsPrimaryNameRegistrarRuntimeMismatch.selector, address(registrar).codehash
            )
        );
        _executeEmptyCut();

        assertEq(registrar.nameForAddr(diamond), "");
    }

    function testRejectsWhenRegistrarDoesNotPersistName() public {
        registrar.setPersistSetName(false);

        vm.expectRevert(
            abi.encodeWithSelector(CoreEnsPrimaryNameInitBase.EnsPrimaryNamePostconditionFailed.selector, keccak256(""))
        );
        _executeEmptyCut();

        assertEq(registrar.nameForAddr(diamond), "");
    }

    function _executeEmptyCut() private {
        IDiamondCut(diamond)
            .diamondCut(
                new IDiamond.FacetCut[](0), address(initializer), abi.encodeCall(CoreEnsPrimaryNameInitBase.init, ())
            );
    }

    function _selectorCount() private view returns (uint256 count) {
        IDiamondLoupe.Facet[] memory facets = IDiamondLoupe(diamond).facets();
        for (uint256 i; i < facets.length; ++i) {
            count += facets[i].functionSelectors.length;
        }
    }

    function _topologyHash() private view returns (bytes32 topologyHash) {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address[] memory facets = loupe.facetAddresses();
        topologyHash = keccak256(abi.encode(facets));
        for (uint256 i; i < facets.length; ++i) {
            topologyHash = keccak256(abi.encode(topologyHash, facets[i], loupe.facetFunctionSelectors(facets[i])));
        }
    }

    function _assertOnlyCoordinatorLatchWasWritten(bytes32[] memory writes) private pure {
        require(writes.length != 0, "expected coordinator latch write");
        for (uint256 i; i < writes.length; ++i) {
            require(writes[i] == VALIDATED_DIAMOND_CUT_STATE_SLOT, "unexpected Core storage write");
        }
    }
}
