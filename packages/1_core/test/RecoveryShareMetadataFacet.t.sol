// SPDX-License-Identifier: MIT
pragma solidity ^0.8.38;

import {Test} from "forge-std/Test.sol";

import {RecoveryShareMetadataFacet} from "../src/facets/RecoveryShareMetadataFacet.sol";
import {IRecoveryTypes} from "../src/interfaces/IRecoveryTypes.sol";
import {LibRecoveryStorage} from "../src/libraries/LibRecoveryStorage.sol";

contract RecoveryShareMetadataHarness is RecoveryShareMetadataFacet {
    function seedPool(address asset) external {
        LibRecoveryStorage.getLayout().pools[asset].impaired = true;
    }

    function mutateCurrentState(
        address asset,
        bool impaired,
        uint256 attached,
        uint256 raw,
        uint256 conversion,
        uint256 cap
    ) external {
        LibRecoveryStorage.RecoveryPool storage pool = LibRecoveryStorage.getLayout().pools[asset];
        pool.impaired = impaired;
        pool.coreAttachedShares = attached;
        pool.redeemableRaw = raw;
        pool.cygldPerAssetRawFp18 = conversion;
        pool.cygldSupplyCap = cap;
    }

    function clearPool(address asset) external {
        delete LibRecoveryStorage.getLayout().pools[asset];
    }
}

contract RecoveryShareMetadataFacetTest is Test {
    RecoveryShareMetadataHarness internal metadata;
    address internal constant ASSET = address(0x123456);
    address internal constant CORE = address(0xABCDEF);
    uint256 internal constant CHAIN_ID = 11_155_111;
    string internal constant DEPLOYMENT_BASE =
        "https://cybergold.io/recovery-shares/11155111/0x0000000000000000000000000000000000abcdef/";

    function setUp() public {
        vm.chainId(CHAIN_ID);
        RecoveryShareMetadataHarness implementation = new RecoveryShareMetadataHarness();
        vm.etch(CORE, address(implementation).code);
        metadata = RecoveryShareMetadataHarness(CORE);
        metadata.seedPool(ASSET);
    }

    function testCollectionMetadataUsesDeterministicHttpsTemplate() public view {
        assertEq(metadata.contractURI(), string.concat(DEPLOYMENT_BASE, "collection.json"));
    }

    function testTokenMetadataUsesDecimalShareIdAndLowercaseFixedCoreAddress() public view {
        uint256 shareId = uint256(uint160(ASSET));
        assertEq(metadata.uri(shareId), string.concat(DEPLOYMENT_BASE, "1193046.json"));
    }

    function testMetadataIdentityIsStableAcrossCurrentEconomicStateChanges() public {
        uint256 shareId = uint256(uint160(ASSET));
        string memory beforeUri = metadata.uri(shareId);
        metadata.mutateCurrentState(ASSET, true, 99 ether, 42, 2 ether, 1_000 ether);
        assertEq(metadata.uri(shareId), beforeUri);
        metadata.mutateCurrentState(ASSET, false, 0, 17, 0, 0);
        assertEq(metadata.uri(shareId), beforeUri);
    }

    function testUnknownAndNonCanonicalIdsRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareIdInvalid.selector, 0));
        metadata.uri(0);

        uint256 malformed = uint256(1) << 160;
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareIdInvalid.selector, malformed));
        metadata.uri(malformed);

        address unknown = address(0x9999);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareUnknown.selector, unknown));
        metadata.uri(uint256(uint160(unknown)));

        metadata.clearPool(ASSET);
        vm.expectRevert(abi.encodeWithSelector(IRecoveryTypes.RecoveryShareUnknown.selector, ASSET));
        metadata.uri(uint256(uint160(ASSET)));
    }

    function testFacetIdentity() public view {
        assertEq(metadata.FACET_VERSION(), 1);
        assertEq(metadata.FACET_NAMESPACE(), keccak256("cybergold.core.recovery-share-metadata"));
    }
}
