from __future__ import annotations

import json
import sys
from pathlib import Path
from unittest import mock


TESTS_DIR = Path(__file__).resolve().parent
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

from module_loader import (
    load_fresh_repo_module,
    load_reports_module as load_module,
)
from workspace_case import WorkspaceBackedTestCase

WORKSPACE_DIR = TESTS_DIR / "workspace"
LEAF_SCHEMA = "current-run-runtime-profile"
RUNTIMES = ("docker-rootful", "docker-rootless", "podman-rootless")
PROFILES = ("baseline-system", "cis-system")


class WorkspaceTestCase(WorkspaceBackedTestCase):
    WORKSPACE_ROOT = WORKSPACE_DIR


class ControlImpactMatrixReportTests(WorkspaceTestCase):
    def _load_module(self):
        return load_module("control_impact_matrix_module", "control_impact_matrix.py")

    def _write_leaf_matrix(
        self,
        runtime: str,
        profile: str,
        timestamp: str,
        *,
        filename: str,
        attack_paths: list[dict] | None = None,
        controls: list[dict] | None = None,
        run_session_id: str = "run-001",
        schema: str = LEAF_SCHEMA,
    ) -> Path:
        leaf_dir = self.workspace / "results" / runtime / profile / filename.removesuffix(".json")
        leaf_dir.mkdir(parents=True, exist_ok=True)
        path = leaf_dir / filename
        payload = {
            "metadata": {
                "schema": schema,
                "runtime": runtime,
                "environment_state": profile,
                "date": timestamp,
                "run_session_id": run_session_id,
            },
            "attack_paths": attack_paths or [],
            "controls": controls or [],
            "predecessor_evidence": {
                "first": {"canonical_test_id": "tc01"},
                "second": {"canonical_test_id": "tc03"},
            },
        }
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def _attack(self, test_id: str, *, result: str = "pass", **overrides):
        payload = {
            "canonical_test_id": test_id,
            "name": test_id.upper(),
            "current_run_result": result,
            "result_dir": f"results/{test_id}",
            "log_path": f"logs/{test_id}.log",
            "context_path": f"context/{test_id}.json",
            "artifact_paths": [],
        }
        payload.update(overrides)
        return payload

    def test_load_latest_leaf_matrices_keeps_newest_leaf_per_runtime_and_environment_state(
        self,
    ):
        module = self._load_module()
        older_path = self._write_leaf_matrix(
            "docker-rootful",
            "baseline-system",
            "2026-05-31T00:00:00+00:00",
            filename="control-impact-matrix-old.json",
        )
        newer_path = self._write_leaf_matrix(
            "docker-rootful",
            "baseline-system",
            "2026-05-31T01:00:00+00:00",
            filename="control-impact-matrix-new.json",
        )
        self._write_leaf_matrix(
            "docker-rootless",
            "baseline-system",
            "2026-05-31T02:00:00+00:00",
            filename="control-impact-matrix-ignore.json",
            schema="other-schema",
        )
        self._write_leaf_matrix(
            "podman-rootless",
            "cis-system",
            "2026-05-31T01:00:00+00:00",
            filename="control-impact-matrix-cis.json",
        )

        latest = module.load_latest_leaf_matrices(self.workspace / "results")

        self.assertEqual(set(latest), {
            ("docker-rootful", "baseline-system"),
            ("podman-rootless", "cis-system"),
        })
        self.assertEqual(
            Path(latest[("docker-rootful", "baseline-system")]["source_path"]),
            newer_path,
        )
        self.assertNotEqual(
            Path(latest[("docker-rootful", "baseline-system")]["source_path"]),
            older_path,
        )
        self.assertEqual(
            latest[("docker-rootful", "baseline-system")]["payload"]["metadata"]["date"],
            "2026-05-31T01:00:00+00:00",
        )

    def test_load_latest_leaf_matrices_skips_leaf_missing_date(self):
        module = self._load_module()
        self._write_leaf_matrix(
            "docker-rootful",
            "baseline-system",
            "2026-05-31T00:00:00+00:00",
            filename="control-impact-matrix-valid.json",
        )

        missing_date_path = (
            self.workspace
            / "results"
            / "docker-rootless"
            / "cis-system"
            / "control-impact-matrix-missing-date"
            / "control-impact-matrix-missing-date.json"
        )
        missing_date_path.parent.mkdir(parents=True, exist_ok=True)
        missing_date_path.write_text(
            json.dumps(
                {
                    "metadata": {
                        "schema": LEAF_SCHEMA,
                        "runtime": "docker-rootless",
                        "environment_state": "cis-system",
                        "run_session_id": "run-001",
                    },
                    "attack_paths": [],
                    "controls": [],
                    "predecessor_evidence": {},
                }
            ),
            encoding="utf-8",
        )

        latest = module.load_latest_leaf_matrices(self.workspace / "results")

        self.assertEqual(set(latest), {("docker-rootful", "baseline-system")})

    def test_build_full_matrix_marks_tc07_excluded_tc21_metadata_only_and_collection_g_cis_cells_missing(
        self,
    ):
        module = self._load_module()
        expected_controls = {}
        for runtime in RUNTIMES:
            for profile in PROFILES:
                controls = [
                    {
                        "control_id": f"{runtime}-{profile}",
                        "status": "enabled",
                    }
                ]
                attack_paths = [
                    self._attack("tc01"),
                    self._attack("tc07"),
                    self._attack("tc21"),
                ]
                if profile == "baseline-system":
                    attack_paths.extend(
                        [
                            self._attack("tc22"),
                            self._attack("tc23"),
                            self._attack("tc24"),
                        ]
                    )
                self._write_leaf_matrix(
                    runtime,
                    profile,
                    "2026-05-31T01:00:00+00:00",
                    filename=f"control-impact-matrix-{runtime}-{profile}.json",
                    attack_paths=attack_paths,
                    controls=controls,
                )
                expected_controls.setdefault(profile, {})[runtime] = controls

        leaves = module.load_latest_leaf_matrices(self.workspace / "results")
        matrix = module.build_full_matrix(leaves)

        self.assertEqual(matrix["scope"]["expected_cells"], 132)
        self.assertEqual(matrix["scope"]["produced_cells"], 15)
        self.assertEqual(
            matrix["scope"]["excluded_test_cases"],
            [{"test_id": "tc07", "reason": "de-scoped methodology case"}],
        )
        self.assertEqual(matrix["scope"]["excluded_cells"], [])
        self.assertEqual(matrix["provenance"]["synthesized_by"], "tc21")
        self.assertEqual(matrix["controls"], expected_controls)

        cell_test_ids = {cell["test_id"] for cell in matrix["cells"]}
        self.assertNotIn("tc07", cell_test_ids)
        self.assertNotIn("tc21", cell_test_ids)

        missing_cells = {
            (entry["test_id"], entry["runtime"], entry["profile"])
            for entry in matrix["scope"]["missing_cells"]
        }
        expected_collection_g_cis_missing = {
            (test_id, runtime, "cis-system")
            for runtime in RUNTIMES
            for test_id in ("tc22", "tc23", "tc24")
        }
        self.assertTrue(expected_collection_g_cis_missing.issubset(missing_cells))
        self.assertNotIn(("tc07", "docker-rootful", "baseline-system"), missing_cells)
        self.assertNotIn(("tc21", "docker-rootful", "baseline-system"), missing_cells)

    def test_canonical_status_classifies_supported_leaf_results(self):
        module = self._load_module()
        cases = (
            ("pass", [], "pass"),
            ("fail", [], "fail"),
            ("block", [], "block"),
            ("block", ["artifacts/tc20-applicability.json"], "not_applicable"),
            ("skip", [], "skip"),
            ("error", [], "error"),
        )

        for result, artifact_paths, expected in cases:
            with self.subTest(result=result, artifact_paths=artifact_paths):
                self.assertEqual(
                    module.canonical_status(
                        {
                            "current_run_result": result,
                            "artifact_paths": artifact_paths,
                        }
                    ),
                    expected,
                )

    def test_build_full_matrix_requires_reason_code_for_non_pass_cells(self):
        module = self._load_module()
        leaves = {
            ("docker-rootful", "baseline-system"): {
                "source_path": "results/docker-rootful/baseline-system/control-impact-matrix.json",
                "payload": {
                    "metadata": {
                        "schema": LEAF_SCHEMA,
                        "runtime": "docker-rootful",
                        "environment_state": "baseline-system",
                        "date": "2026-05-31T01:00:00+00:00",
                        "run_session_id": "run-001",
                    },
                    "attack_paths": [self._attack("tc01", result="block")],
                    "controls": [],
                    "predecessor_evidence": {},
                },
            }
        }

        with self.assertRaisesRegex(
            ValueError,
            "Missing reason_code for docker-rootful/baseline-system/tc01",
        ):
            module.build_full_matrix(leaves)

    def test_build_full_matrix_treats_unknown_leaf_results_as_missing_coverage(self):
        module = self._load_module()
        leaves = {
            ("docker-rootful", "baseline-system"): {
                "source_path": "results/docker-rootful/baseline-system/control-impact-matrix.json",
                "payload": {
                    "metadata": {
                        "schema": LEAF_SCHEMA,
                        "runtime": "docker-rootful",
                        "environment_state": "baseline-system",
                        "date": "2026-05-31T01:00:00+00:00",
                        "run_session_id": "run-001",
                        "status": "partial",
                    },
                    "attack_paths": [self._attack("tc01", result="unknown")],
                    "controls": [],
                    "predecessor_evidence": {},
                },
            }
        }

        matrix = module.build_full_matrix(leaves)

        self.assertEqual(matrix["scope"]["produced_cells"], 0)
        self.assertNotIn(
            ("tc01", "docker-rootful", "baseline-system"),
            {
                (cell["test_id"], cell["runtime"], cell["profile"])
                for cell in matrix["cells"]
            },
        )
        self.assertIn(
            ("tc01", "docker-rootful", "baseline-system"),
            {
                (entry["test_id"], entry["runtime"], entry["profile"])
                for entry in matrix["scope"]["missing_cells"]
            },
        )

    def test_build_full_matrix_requires_reason_text_and_reason_source_for_non_pass_cells(self):
        module = self._load_module()

        for missing_field in ("reason_text", "reason_source"):
            with self.subTest(missing_field=missing_field):
                attack = self._attack(
                    "tc01",
                    result="block",
                    reason_code="blocked",
                    reason_text="Blocked by prerequisite",
                    reason_source="generator",
                )
                attack[missing_field] = ""
                leaves = {
                    ("docker-rootful", "baseline-system"): {
                        "source_path": "results/docker-rootful/baseline-system/control-impact-matrix.json",
                        "payload": {
                            "metadata": {
                                "schema": LEAF_SCHEMA,
                                "runtime": "docker-rootful",
                                "environment_state": "baseline-system",
                                "date": "2026-05-31T01:00:00+00:00",
                                "run_session_id": "run-001",
                            },
                            "attack_paths": [attack],
                            "controls": [],
                            "predecessor_evidence": {},
                        },
                    }
                }

                with self.assertRaisesRegex(
                    ValueError,
                    f"Missing {missing_field} for docker-rootful/baseline-system/tc01",
                ):
                    module.build_full_matrix(leaves)

    def test_build_profile_and_runtime_diffs_classifies_improvements_and_non_comparable_cells(
        self,
    ):
        module = self._load_module()
        leaves = {
            ("docker-rootful", "baseline-system"): {
                "source_path": "results/docker-rootful/baseline-system/control-impact-matrix.json",
                "payload": {
                    "metadata": {
                        "schema": LEAF_SCHEMA,
                        "runtime": "docker-rootful",
                        "environment_state": "baseline-system",
                        "date": "2026-05-31T01:00:00+00:00",
                        "run_session_id": "run-001",
                    },
                    "attack_paths": [
                        self._attack(
                            "tc03",
                            result="block",
                            reason_code="blocked",
                            reason_text="Blocked in baseline",
                            reason_source="generator",
                        ),
                        self._attack("tc20", result="block", artifact_paths=["artifacts/tc20-applicability.json"], reason_code="not_applicable", reason_text="Out of scope", reason_source="generator"),
                    ],
                    "controls": [],
                    "predecessor_evidence": {},
                },
            },
            ("docker-rootful", "cis-system"): {
                "source_path": "results/docker-rootful/cis-system/control-impact-matrix.json",
                "payload": {
                    "metadata": {
                        "schema": LEAF_SCHEMA,
                        "runtime": "docker-rootful",
                        "environment_state": "cis-system",
                        "date": "2026-05-31T01:00:00+00:00",
                        "run_session_id": "run-001",
                    },
                    "attack_paths": [
                        self._attack("tc03", result="pass"),
                        self._attack("tc20", result="block", artifact_paths=["artifacts/tc20-applicability.json"], reason_code="not_applicable", reason_text="Out of scope", reason_source="generator"),
                    ],
                    "controls": [],
                    "predecessor_evidence": {},
                },
            },
            ("podman-rootless", "baseline-system"): {
                "source_path": "results/podman-rootless/baseline-system/control-impact-matrix.json",
                "payload": {
                    "metadata": {
                        "schema": LEAF_SCHEMA,
                        "runtime": "podman-rootless",
                        "environment_state": "baseline-system",
                        "date": "2026-05-31T01:00:00+00:00",
                        "run_session_id": "run-001",
                    },
                    "attack_paths": [
                        self._attack("tc20", result="block", artifact_paths=["artifacts/tc20-applicability.json"], reason_code="not_applicable", reason_text="Out of scope", reason_source="generator"),
                    ],
                    "controls": [],
                    "predecessor_evidence": {},
                },
            },
            ("docker-rootless", "baseline-system"): {
                "source_path": "results/docker-rootless/baseline-system/control-impact-matrix.json",
                "payload": {
                    "metadata": {
                        "schema": LEAF_SCHEMA,
                        "runtime": "docker-rootless",
                        "environment_state": "baseline-system",
                        "date": "2026-05-31T01:00:00+00:00",
                        "run_session_id": "run-001",
                    },
                    "attack_paths": [
                        self._attack(
                            "tc20",
                            result="block",
                            artifact_paths=["artifacts/tc20-applicability.json"],
                            reason_code="not_applicable",
                            reason_text="Out of scope",
                            reason_source="generator",
                        ),
                    ],
                    "controls": [],
                    "predecessor_evidence": {},
                },
            },
            ("podman-rootless", "cis-system"): {
                "source_path": "results/podman-rootless/cis-system/control-impact-matrix.json",
                "payload": {
                    "metadata": {
                        "schema": LEAF_SCHEMA,
                        "runtime": "podman-rootless",
                        "environment_state": "cis-system",
                        "date": "2026-05-31T01:00:00+00:00",
                        "run_session_id": "run-001",
                    },
                    "attack_paths": [
                        self._attack("tc20", result="block", artifact_paths=["artifacts/tc20-applicability.json"], reason_code="not_applicable", reason_text="Out of scope", reason_source="generator"),
                    ],
                    "controls": [],
                    "predecessor_evidence": {},
                },
            },
        }

        matrix = module.build_full_matrix(leaves)
        diffs = module.build_diffs(matrix["cells"], matrix["axes"], matrix["scope"])

        self.assertIn(
            {
                "test_id": "tc03",
                "runtime": "docker-rootful",
                "baseline_status": "block",
                "cis_status": "pass",
                "classification": "cis_improved",
            },
            [
                {
                    "test_id": entry["test_id"],
                    "runtime": entry["runtime"],
                    "baseline_status": entry["baseline_status"],
                    "cis_status": entry["cis_status"],
                    "classification": entry["classification"],
                }
                for entry in diffs["profile_diff"]
            ],
        )
        self.assertIn(
            {
                "test_id": "tc03",
                "profile": "baseline-system",
                "statuses": {
                    "docker-rootful": "block",
                    "docker-rootless": None,
                    "podman-rootless": None,
                },
                "classification": "incomplete",
            },
            [
                {
                    "test_id": entry["test_id"],
                    "profile": entry["profile"],
                    "statuses": entry["statuses"],
                    "classification": entry["classification"],
                }
                for entry in diffs["runtime_diff"]
            ],
        )
        self.assertIn(
            {
                "test_id": "tc20",
                "profile": "baseline-system",
                "statuses": {
                    "docker-rootful": "not_applicable",
                    "docker-rootless": "not_applicable",
                    "podman-rootless": "not_applicable",
                },
                "classification": "non_comparable",
            },
            [
                {
                    "test_id": entry["test_id"],
                    "profile": entry["profile"],
                    "statuses": entry["statuses"],
                    "classification": entry["classification"],
                }
                for entry in diffs["runtime_diff"]
            ],
        )
        self.assertIn(
            {
                "test_id": "tc20",
                "runtime": "podman-rootless",
                "baseline_status": "not_applicable",
                "cis_status": "not_applicable",
                "classification": "non_comparable",
            },
            [
                {
                    "test_id": entry["test_id"],
                    "runtime": entry["runtime"],
                    "baseline_status": entry["baseline_status"],
                    "cis_status": entry["cis_status"],
                    "classification": entry["classification"],
                }
                for entry in diffs["profile_diff"]
            ],
        )

    def test_write_report_bundle_writes_json_markdown_and_csv(self):
        module = self._load_module()
        leaves = {
            ("docker-rootful", "baseline-system"): {
                "source_path": "results/docker-rootful/baseline-system/control-impact-matrix.json",
                "payload": {
                    "metadata": {
                        "schema": LEAF_SCHEMA,
                        "runtime": "docker-rootful",
                        "environment_state": "baseline-system",
                        "date": "2026-05-31T01:00:00+00:00",
                        "run_session_id": "run-001",
                    },
                    "attack_paths": [self._attack("tc01", result="pass")],
                    "controls": [],
                    "predecessor_evidence": {},
                },
            }
        }
        report = module.build_full_matrix(leaves)
        output_path = self.workspace / "control-impact-matrix-report.json"

        module.write_report_bundle(report, output_path)

        self.assertTrue(output_path.exists())
        self.assertTrue(output_path.with_suffix(".md").exists())
        self.assertTrue(output_path.with_suffix(".csv").exists())
        self.assertIn(
            "Boundary foundation collection",
            output_path.with_suffix(".md").read_text(encoding="utf-8"),
        )
        self.assertIn(
            "tc01,docker-rootful,baseline-system,pass",
            output_path.with_suffix(".csv").read_text(encoding="utf-8"),
        )

    def test_control_impact_matrix_report_cli_writes_json_markdown_and_csv_bundle(self):
        cli_module = load_fresh_repo_module(
            "control_impact_matrix_report_cli",
            "src/analyze/reports/control-impact-matrix-report.py",
        )
        output_path = self.workspace / "reports" / "control-impact-matrix.json"

        for runtime in RUNTIMES:
            for profile in PROFILES:
                self._write_leaf_matrix(
                    runtime,
                    profile,
                    "2026-05-31T01:00:00+00:00",
                    filename=f"control-impact-matrix-{runtime}-{profile}.json",
                    attack_paths=[self._attack("tc01", result="pass")],
                    controls=[
                        {
                            "control_id": f"{runtime}-{profile}",
                            "status": "enabled",
                        }
                    ],
                )

        with mock.patch.dict("os.environ", {"CLD6001_RUN_ROOT": str(self.workspace)}, clear=False):
            cli_module.main(
                [
                    "--input",
                    str(self.workspace / "results"),
                    "--output",
                    str(output_path),
                ]
            )

        self.assertTrue(output_path.exists())
        self.assertTrue(output_path.with_suffix(".md").exists())
        self.assertTrue(output_path.with_suffix(".csv").exists())

    def test_write_report_bundle_treats_tuple_level_exclusions_as_non_comparable_scope(self):
        module = self._load_module()
        report = {
            "schema": "control-impact-matrix-v1",
            "generated_at": "2026-05-31T00:00:00Z",
            "run_session_id": "run-001",
            "axes": {
                "profiles": ["baseline-system", "cis-system"],
                "runtimes": ["docker-rootful"],
                "suites": [
                    {
                        "id": "a",
                        "title": "Boundary foundation collection",
                        "test_cases": ["tc01"],
                    }
                ],
                "test_cases": ["tc01"],
            },
            "scope": {
                "expected_cells": 2,
                "produced_cells": 1,
                "missing_cells": [],
                "excluded_test_cases": [],
                "excluded_cells": [
                    {
                        "test_id": "tc01",
                        "runtime": "docker-rootful",
                        "profile": "cis-system",
                        "reason": "unsupported in cis run",
                    }
                ],
            },
            "cells": [
                {
                    "test_id": "tc01",
                    "test_title": "Privileged Mode",
                    "suite_id": "a",
                    "runtime": "docker-rootful",
                    "profile": "baseline-system",
                    "status": "pass",
                    "reason_code": "",
                    "reason_text": "",
                    "reason_source": "",
                    "evidence": {
                        "result_dir": "",
                        "log_path": "",
                        "context_path": "",
                        "artifact_paths": [],
                    },
                    "predecessor_chain": [],
                    "run_session_id": "run-001",
                    "captured_at": "2026-05-31T00:00:00Z",
                }
            ],
            "controls": {},
            "diffs": {"profile_diff": [], "runtime_diff": []},
            "provenance": {"synthesized_by": "tc21", "leaf_artifacts": []},
        }
        output_path = self.workspace / "control-impact-matrix-report.json"

        module.write_report_bundle(report, output_path)

        written = json.loads(output_path.read_text(encoding="utf-8"))
        self.assertEqual(
            written["diffs"]["profile_diff"],
            [
                {
                    "test_id": "tc01",
                    "runtime": "docker-rootful",
                    "baseline_status": "pass",
                    "cis_status": "skip",
                    "classification": "non_comparable",
                }
            ],
        )
        self.assertEqual(
            written["diffs"]["runtime_diff"],
            [
                {
                    "test_id": "tc01",
                    "profile": "baseline-system",
                    "statuses": {"docker-rootful": "pass"},
                    "classification": "same",
                },
                {
                    "test_id": "tc01",
                    "profile": "cis-system",
                    "statuses": {"docker-rootful": "skip"},
                    "classification": "non_comparable",
                },
            ],
        )

    def test_build_diffs_marks_fully_missing_comparisons_incomplete(self):
        module = self._load_module()
        leaves = {
            ("docker-rootful", "baseline-system"): {
                "source_path": "results/docker-rootful/baseline-system/control-impact-matrix.json",
                "payload": {
                    "metadata": {
                        "schema": LEAF_SCHEMA,
                        "runtime": "docker-rootful",
                        "environment_state": "baseline-system",
                        "date": "2026-05-31T01:00:00+00:00",
                        "run_session_id": "run-001",
                    },
                    "attack_paths": [self._attack("tc01", result="pass")],
                    "controls": [],
                    "predecessor_evidence": {},
                },
            }
        }

        matrix = module.build_full_matrix(leaves)
        diffs = module.build_diffs(matrix["cells"], matrix["axes"], matrix["scope"])

        self.assertIn(
            {
                "test_id": "tc01",
                "runtime": "docker-rootless",
                "baseline_status": None,
                "cis_status": None,
                "classification": "incomplete",
            },
            [
                {
                    "test_id": entry["test_id"],
                    "runtime": entry["runtime"],
                    "baseline_status": entry["baseline_status"],
                    "cis_status": entry["cis_status"],
                    "classification": entry["classification"],
                }
                for entry in diffs["profile_diff"]
            ],
        )

    def test_build_diffs_limits_default_scope_to_provided_cells(self):
        module = self._load_module()

        diffs = module.build_diffs(
            [
               {
                   "test_id": "tc01",
                   "runtime": "docker-rootful",
                   "profile": "baseline-system",
                   "status": "pass",
               },
               {
                   "test_id": "tc01",
                   "runtime": "docker-rootful",
                   "profile": "cis-system",
                   "status": "fail",
               },
            ]
        )

        self.assertEqual(
            diffs["profile_diff"],
            [
               {
                   "test_id": "tc01",
                   "runtime": "docker-rootful",
                   "baseline_status": "pass",
                   "cis_status": "fail",
                   "classification": "cis_regressed",
               }
            ],
        )
        self.assertEqual(
            diffs["runtime_diff"],
            [
               {
                   "test_id": "tc01",
                   "profile": "baseline-system",
                   "statuses": {"docker-rootful": "pass"},
                   "classification": "same",
               },
               {
                   "test_id": "tc01",
                   "profile": "cis-system",
                   "statuses": {"docker-rootful": "fail"},
                   "classification": "same",
               },
            ],
        )

    def test_render_markdown_uses_test_titles_from_cells(self):
        module = self._load_module()
        leaves = {
            ("docker-rootful", "baseline-system"): {
                "source_path": "results/docker-rootful/baseline-system/control-impact-matrix.json",
                "payload": {
                    "metadata": {
                        "schema": LEAF_SCHEMA,
                        "runtime": "docker-rootful",
                        "environment_state": "baseline-system",
                        "date": "2026-05-31T01:00:00+00:00",
                        "run_session_id": "run-001",
                    },
                    "attack_paths": [
                        self._attack("tc01", result="pass", name="Privileged Mode")
                    ],
                    "controls": [],
                    "predecessor_evidence": {},
                },
            }
        }

        report = module.build_full_matrix(leaves)
        markdown = module.render_markdown(report)

        self.assertIn("| tc01 | Privileged Mode |", markdown)

    def test_build_diffs_treats_fail_to_block_as_cis_improved(self):
        module = self._load_module()

        diffs = module.build_diffs(
            [
                {
                    "test_id": "tc01",
                    "runtime": "docker-rootful",
                    "profile": "baseline-system",
                    "status": "fail",
                },
                {
                    "test_id": "tc01",
                    "runtime": "docker-rootful",
                    "profile": "cis-system",
                    "status": "block",
                },
            ]
        )

        self.assertIn(
            {
                "test_id": "tc01",
                "runtime": "docker-rootful",
                "baseline_status": "fail",
                "cis_status": "block",
                "classification": "cis_improved",
            },
            [
                {
                    "test_id": entry["test_id"],
                    "runtime": entry["runtime"],
                    "baseline_status": entry["baseline_status"],
                    "cis_status": entry["cis_status"],
                    "classification": entry["classification"],
                }
                for entry in diffs["profile_diff"]
            ],
        )

    def test_render_markdown_orders_columns_by_profile_then_runtime(self):
        module = self._load_module()
        report = module.build_full_matrix(
            {
                ("docker-rootful", "baseline-system"): {
                    "source_path": "results/docker-rootful/baseline-system/control-impact-matrix.json",
                    "payload": {
                        "metadata": {
                            "schema": LEAF_SCHEMA,
                            "runtime": "docker-rootful",
                            "environment_state": "baseline-system",
                            "date": "2026-05-31T01:00:00+00:00",
                            "run_session_id": "run-001",
                        },
                        "attack_paths": [self._attack("tc01", result="pass")],
                        "controls": [],
                        "predecessor_evidence": {},
                    },
                }
            }
        )

        markdown = module.render_markdown(report)

        self.assertIn(
            "| Test ID | Title | docker-rootful baseline-system | docker-rootless baseline-system | podman-rootless baseline-system | docker-rootful cis-system | docker-rootless cis-system | podman-rootless cis-system |",
            markdown,
        )

    def test_render_markdown_shows_tuple_level_excluded_cells(self):
        module = self._load_module()
        report = {
            "schema": "control-impact-matrix-v1",
            "generated_at": "2026-05-31T00:00:00Z",
            "run_session_id": "run-001",
            "axes": {
                "profiles": ["baseline-system", "cis-system"],
                "runtimes": ["docker-rootful"],
                "suites": [
                    {
                        "id": "a",
                        "title": "Boundary foundation collection",
                        "test_cases": ["tc01"],
                    }
                ],
                "test_cases": ["tc01"],
            },
            "scope": {
                "expected_cells": 2,
                "produced_cells": 1,
                "missing_cells": [],
                "excluded_test_cases": [],
                "excluded_cells": [
                    {
                        "test_id": "tc01",
                        "runtime": "docker-rootful",
                        "profile": "cis-system",
                        "reason": "unsupported in cis run",
                    }
                ],
            },
            "cells": [
                {
                    "test_id": "tc01",
                    "test_title": "Privileged Mode",
                    "suite_id": "a",
                    "runtime": "docker-rootful",
                    "profile": "baseline-system",
                    "status": "pass",
                    "reason_code": "",
                    "reason_text": "",
                    "reason_source": "",
                    "evidence": {
                        "result_dir": "",
                        "log_path": "",
                        "context_path": "",
                        "artifact_paths": [],
                    },
                    "predecessor_chain": [],
                    "run_session_id": "run-001",
                    "captured_at": "2026-05-31T00:00:00Z",
                }
            ],
        }

        markdown = module.render_markdown(report)

        self.assertIn(
            "- tc01 / docker-rootful / cis-system: unsupported in cis run",
            markdown,
        )
        self.assertIn(
            "| tc01 | Privileged Mode | pass | excluded (unsupported in cis run) |",
            markdown,
        )
