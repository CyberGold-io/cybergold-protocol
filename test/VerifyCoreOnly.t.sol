// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.38;

import {VerifyCoreOnly} from "../script/VerifyCoreOnly.s.sol";
import {ControllerTestBase} from "../packages/1_core/test/helpers/ControllerTestBase.t.sol";
import {CoreArtifacts} from "../script/helpers/CoreArtifacts.sol";
import {DeployConfig} from "../script/helpers/DeployConfig.sol";

contract VerifyCoreOnlyHarness is VerifyCoreOnly {
    function verifyExactNetIssuance(address coreDiamond) external view {
        _verifyExactNetIssuance(coreDiamond);
    }

    function verifyInitializerState(address coreDiamond) external view {
        CoreArtifacts.Core memory core;
        core.coreDiamond = coreDiamond;
        _verifyInitializerState(core);
    }

    function verifyBasket(DeployConfig.ProtocolConfig calldata cfg, address coreDiamond) external view {
        _verifyBasket(cfg, coreDiamond);
    }
}

contract ExactNetIssuanceVerificationMock {
    uint256 internal immutable _issuanceFeePpm;
    uint256 internal immutable _protocolFeeCygld;
    bool internal immutable _mismatchedBasket;

    constructor(uint256 issuanceFeePpm_, uint256 protocolFeeCygld_, bool mismatchedBasket_) {
        _issuanceFeePpm = issuanceFeePpm_;
        _protocolFeeCygld = protocolFeeCygld_;
        _mismatchedBasket = mismatchedBasket_;
    }

    function issuanceFeePpm() external view returns (uint256) {
        return _issuanceFeePpm;
    }

    function previewIssueFromBasketExactOut(uint256)
        external
        view
        returns (uint256 protocolFeeCygld, uint256[] memory amountsInExact, address[] memory orderedBasketAssets)
    {
        amountsInExact = new uint256[](1);
        orderedBasketAssets = new address[](1);
        orderedBasketAssets[0] = _mismatchedBasket ? address(0xB) : address(0xA);
        return (_protocolFeeCygld, amountsInExact, orderedBasketAssets);
    }

    function basketAssets() external pure returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = address(0xA);
    }
}

contract VerifyCoreOnlyTest is ControllerTestBase {
    uint256 internal constant REQUESTED_NET_CYGLD_OUT = 1 ether;

    function test_verifyExactNetIssuance_acceptsCanonicalNonzeroFeeCore() public {
        VerifyCoreOnlyHarness harness = new VerifyCoreOnlyHarness();

        harness.verifyExactNetIssuance(diamond);
    }

    function test_verifyInitializerState_acceptsCleanLaunchRecoverySeed() public {
        VerifyCoreOnlyHarness harness = new VerifyCoreOnlyHarness();

        _pauseCoreForTest();

        harness.verifyInitializerState(diamond);
    }

    function test_verifyBasket_acceptsUnsolicitedCustodyAfterInitialization() public {
        VerifyCoreOnlyHarness harness = new VerifyCoreOnlyHarness();
        DeployConfig.ProtocolConfig memory cfg;
        cfg.basket.cygldRefGramsFp18 = CYGLD_REF_GRAMS_FP18;
        cfg.basket.assets.addresses = new address[](2);
        cfg.basket.assets.addresses[0] = address(tokA);
        cfg.basket.assets.addresses[1] = address(tokB);
        cfg.basket.assets.targetsPpm = new uint256[](2);
        cfg.basket.assets.targetsPpm[0] = 600_000;
        cfg.basket.assets.targetsPpm[1] = 400_000;
        cfg.basket.assets.goldRefGramsFp18 = new uint256[](2);
        cfg.basket.assets.goldRefGramsFp18[0] = A_GOLD_REF_GRAMS_FP18;
        cfg.basket.assets.goldRefGramsFp18[1] = B_GOLD_REF_GRAMS_FP18;
        tokA.mint(diamond, 17);

        harness.verifyBasket(cfg, diamond);
    }

    function test_verifyExactNetIssuance_rejectsZeroConfiguredFee() public {
        VerifyCoreOnlyHarness harness = new VerifyCoreOnlyHarness();
        ExactNetIssuanceVerificationMock mock = new ExactNetIssuanceVerificationMock(0, 0, false);

        vm.expectRevert(bytes("VerifyCoreOnly: issuance fee must exercise gross-up"));
        harness.verifyExactNetIssuance(address(mock));
    }

    function test_verifyExactNetIssuance_rejectsZeroPreviewFee() public {
        VerifyCoreOnlyHarness harness = new VerifyCoreOnlyHarness();
        ExactNetIssuanceVerificationMock mock = new ExactNetIssuanceVerificationMock(1_000, 0, false);

        vm.expectRevert(bytes("VerifyCoreOnly: exact-net preview fee is zero"));
        harness.verifyExactNetIssuance(address(mock));
    }

    function test_verifyExactNetIssuance_rejectsNoncanonicalGrossQuote() public {
        VerifyCoreOnlyHarness harness = new VerifyCoreOnlyHarness();
        ExactNetIssuanceVerificationMock mock = new ExactNetIssuanceVerificationMock(1_000, 1 ether, false);

        vm.expectRevert(bytes("VerifyCoreOnly: noncanonical exact-net gross"));
        harness.verifyExactNetIssuance(address(mock));
    }

    function test_verifyExactNetIssuance_rejectsPreviewBasketMismatch() public {
        VerifyCoreOnlyHarness harness = new VerifyCoreOnlyHarness();
        (uint256 protocolFeeCygld,,) = preview.previewIssueFromBasketExactOut(REQUESTED_NET_CYGLD_OUT);
        ExactNetIssuanceVerificationMock mock = new ExactNetIssuanceVerificationMock(1_000, protocolFeeCygld, true);

        vm.expectRevert(bytes("VerifyCoreOnly: preview/live basket mismatch"));
        harness.verifyExactNetIssuance(address(mock));
    }
}
