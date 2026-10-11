#!/usr/bin/env python3
"""Self-contained negative fixtures for the ADMIN-2STEP source gate."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CHECKER = Path(__file__).resolve().parents[1] / "check-admin-two-step-source.py"


class AdminTwoStepSourcePolicyTest(unittest.TestCase):
    def run_fixture(self, files: dict[str, str]) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="admin-two-step-policy-") as raw_root:
            root = Path(raw_root)
            for relative, contents in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents, encoding="utf-8")
            return subprocess.run(
                (sys.executable, str(CHECKER), "--root", str(root)),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

    def assert_rejected(self, relative: str, source: str, rule: str) -> None:
        completed = self.run_fixture({relative: source})
        self.assertNotEqual(completed.returncode, 0, completed.stdout)
        self.assertIn(f"[{rule}]", completed.stderr)

    def test_selected_architecture_is_accepted(self) -> None:
        completed = self.run_fixture(
            {
                "packages/0_shared/src/facets/AccessControlFacet.sol": """
                    contract AccessControlFacet {
                        bytes32 constant FACET_NAMESPACE =
                            keccak256("openzeppelin.storage.AccessControl");
                        function init(address admin) external {
                            _grantRole(DEFAULT_ADMIN_ROLE, admin);
                        }
                    }
                """,
                "packages/0_shared/src/facets/DefaultAdminAccessControlFacet.sol": """
                    contract DefaultAdminAccessControlFacet {
                        function init(address governanceDiamond) external {
                            __AccessControlDefaultAdminRules_init(0, governanceDiamond);
                            _grantRole(UPGRADER_ROLE, governanceDiamond);
                        }
                    }
                """,
                "packages/1_core/src/deploy/DiamondInit.sol": """
                    contract DiamondInit {
                        function init(address access, address safeWallet) external {
                            DefaultAdminAccessControlFacet(access)
                                .initDefaultAdminAccessControlFromOuter(safeWallet);
                        }
                    }
                """,
                "packages/2_governance/src/deploy/DiamondInit.sol": """
                    contract DiamondInit {
                        function init(address access, address governance) external {
                            AccessControlFacet(access).initAccessControlFromOuter(governance);
                        }
                    }
                """,
                "packages/3_staking/src/deploy/DeploymentHelper.sol": """
                    library DeploymentHelper {
                        function deployCommittedShell(Config memory cfg) internal {
                            diamond = new StakingDiamond{salt: cfg.shellSalt}(shellCut, args);
                        }
                    }
                """,
                "script/WireDeployedRoles.s.sol": """
                    contract WireDeployedRoles { error StakingRoleWiringRemoved(); }
                """,
            }
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_rejects_default_admin_mutations_outside_governance_facet(self) -> None:
        fixtures = (
            (
                "packages/1_core/src/facets/Bad.sol",
                "contract Bad { function f() internal { _grantRole(DEFAULT_ADMIN_ROLE, safe); } }",
            ),
            (
                "packages/3_staking/src/facets/Bad.sol",
                "contract Bad { function f() internal { _revokeRole(bytes32(0), governance); } }",
            ),
            (
                "packages/0_shared/src/facets/DefaultAdminAccessControlFacet.sol",
                "contract Bad { function f() internal { _grantRole(DEFAULT_ADMIN_ROLE, relay); } }",
            ),
        )
        for relative, source in fixtures:
            with self.subTest(relative=relative):
                self.assert_rejected(relative, source, "default-admin-mutation")

    def test_rejects_access_initializers_outside_selected_shared_facets(self) -> None:
        self.assert_rejected(
            "packages/1_core/src/deploy/Bad.sol",
            "contract Bad { function init() external { __AccessControlDefaultAdminRules_init(0, safe); } }",
            "access-initializer-boundary",
        )

    def test_rejects_raw_openzeppelin_access_storage(self) -> None:
        for marker in (
            "AccessControlStorageLocation",
            "0xeef3dac4538c82c8ace4063ab0acd2d15cdb5883aa1dff7c2673abb3d8698400",
            'keccak256("openzeppelin.storage.AccessControlEnumerable")',
        ):
            with self.subTest(marker=marker):
                self.assert_rejected(
                    "packages/3_staking/src/libraries/Bad.sol",
                    f"contract Bad {{ bytes32 constant SLOT = {marker}; }}",
                    "raw-access-storage",
                )
        self.assert_rejected(
            "packages/1_core/src/deploy/Bad.sol",
            "contract Bad { function write(bytes32 slot) external { assembly { sstore(slot, 1) } } }",
            "raw-access-storage",
        )

    def test_rejects_every_removed_transfer_latch_form(self) -> None:
        for token in ("enableTransfers", "transfersEnabled", "TransfersDisabled", "0xaf35c6c7"):
            with self.subTest(token=token):
                self.assert_rejected(
                    "packages/3_staking/src/facets/Bad.sol",
                    f"contract Bad {{ /* stale surface */ bytes32 value = bytes32({token}); }}",
                    "s12-transfer-latch",
                )

    def test_rejects_post_deployment_role_wiring(self) -> None:
        for source in (
            "library RoleWiring { function wireStaking() internal {} }",
            "contract Stack { bool autoWireRoles; }",
            'import {RoleWiring} from "script/helpers/RoleWiring.sol";',
        ):
            with self.subTest(source=source):
                self.assert_rejected(
                    "script/helpers/StackDeployer.sol", source, "post-deploy-role-wiring"
                )

    def test_rejects_direct_staking_construction_and_legacy_helper(self) -> None:
        self.assert_rejected(
            "script/DeployStaking.sol",
            "contract Deploy { function run() external { new StakingDiamond(cut, args); } }",
            "staking-direct-construction",
        )
        self.assert_rejected(
            "packages/3_staking/src/deploy/DeploymentHelper.sol",
            "library DeploymentHelper { function deploy() internal { new StakingDiamond(cut, args); } }",
            "staking-direct-construction",
        )
        self.assert_rejected(
            "script/DeployStaking.sol",
            "contract Deploy { bytes constant INIT = type(StakingDiamond).creationCode; }",
            "staking-direct-construction",
        )
        self.assert_rejected(
            "script/helpers/StackDeployer.sol",
            """
                import {DeploymentHelper as AnyAlias}
                    from "packages/3_staking/src/deploy/DeploymentHelper.sol";
                library StackDeployer {
                    function deploy(Cfg memory cfg) internal { AnyAlias.deploy(cfg.staking); }
                }
            """,
            "staking-direct-deploy-helper",
        )

    def test_rejects_ordinary_access_mode_for_core_and_staking(self) -> None:
        self.assert_rejected(
            "packages/1_core/src/deploy/Bad.sol",
            "contract Bad { function f() external { AccessControlFacet(access).init(admin); } }",
            "ordinary-access-mode",
        )
        self.assert_rejected(
            "packages/3_staking/src/deploy/Bad.sol",
            "contract Bad { function f() external { BaseDiamondHelper.deployBaseFacets(true, true); } }",
            "ordinary-access-mode",
        )

    def test_rejects_implicit_or_ambiguous_staking_admin(self) -> None:
        fixtures = (
            (
                "script/helpers/StackDeployer.sol",
                "cfg.staking.governanceDiamond = cfg.staking.governanceDiamond == address(0) ? deployed : cfg.staking.governanceDiamond;",
                "implicit-staking-admin-fallback",
            ),
            (
                "packages/3_staking/src/deploy/Bad.sol",
                "if (allocator == address(0)) { allocator = safeWallet; }",
                "implicit-staking-admin-fallback",
            ),
            (
                "packages/3_staking/src/deploy/Bad.sol",
                "governanceDiamond = msg.sender;",
                "implicit-staking-admin-fallback",
            ),
            (
                "packages/3_staking/src/deploy/Bad.sol",
                "struct DeployConfig { address admin; }",
                "ambiguous-staking-admin",
            ),
            (
                "packages/3_staking/script/Deploy.s.sol",
                'address admin = vm.envAddress("DEPLOY_ADMIN");',
                "ambiguous-staking-admin",
            ),
        )
        for relative, source, rule in fixtures:
            with self.subTest(relative=relative, source=source):
                self.assert_rejected(relative, source, rule)


if __name__ == "__main__":
    unittest.main()
