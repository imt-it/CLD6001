from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path


TESTS_DIR = Path(__file__).resolve().parent
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

from module_loader import load_reports_module as load_module
from workspace_case import WorkspaceBackedTestCase

REPORTS_DIR = TESTS_DIR.parent
WORKSPACE_DIR = TESTS_DIR / "workspace"
COLLECTION_FIXTURE_PAYLOADS = {
    "preflight": {
        "collection": "preflight",
        "title": "Environment Setup & Validation",
        "results": []
    },
    "a": {
        "collection": "a",
        "title": "Boundary Foundation",
        "docker-rootful": {
            "test_cases": {
                "tc1_privileged": {"status": "completed", "result": "pass"},
                "tc2_namespace": {"status": "completed", "result": "block"},
            }
        },
    },
    "b": {
        "collection": "b",
        "title": "Image Supply Chain",
        "docker-rootful": {
            "test_cases": {
                "tc5_stock": {"status": "completed", "result": "pass"},
                "tc6_hardened": {"status": "completed", "result": "block"},
            }
        },
        "podman-rootless": {
            "test_cases": {
                "tc7_custom": {"status": "completed", "result": "block"},
            }
        },
    },
    "c": {
        "collection": "c",
        "title": "Capability & Namespace Controls",
        "docker-rootful": {
            "test_cases": {
                "tc8_seccomp": {"status": "completed", "result": "pass"},
            }
        },
    },
    "e": {
        "collection": "e",
        "title": "Seccomp & Syscall Controls",
        "docker-rootless": {
            "test_cases": {
                "tc9_capabilities": {"status": "completed", "result": "block"},
            }
        },
    },
    "d": {
        "collection": "d",
        "title": "SELinux Controls",
        "docker-rootful": {
            "test_cases": {
                "tc18_kernel": {"status": "completed", "result": "block"},
            }
        },
    },
    "f": {
        "collection": "f",
        "title": "Combined Control Exploration",
        "docker-rootful": {
            "test_cases": {
                "tc19_network": {"status": "completed", "result": "pass"},
            }
        },
    },
    "g": {
        "collection": "g",
        "title": "Page-Cache Attack Family",
        "docker-rootful": {
            "test_cases": {
                "tc22_page_cache_poisoning": {"status": "completed", "result": "block"},
                "tc23_cross_container_attack": {"status": "completed", "result": "block"},
                "tc24_runc_container_escape": {"status": "completed", "result": "block"},
            }
        },
    },
    "h": {
        "collection": "h",
        "title": "Post-Hardening Validations",
        "docker-rootful": {
            "test_cases": {
                "tc21_synthesis": {"status": "completed", "result": "pass"},
            }
        },
    },
}
COLLECTION_FIXTURE_ORDER = ["preflight", "a", "b", "c", "e", "d", "f", "g", "h"]
COLLECTION_TITLES = [
    "Environment Setup & Validation",
    "Boundary Foundation",
    "Image Supply Chain",
    "Capability & Namespace Controls",
    "Seccomp & Syscall Controls",
    "SELinux Controls",
    "Combined Control Exploration",
    "Page-Cache Attack Family",
    "Post-Hardening Validations",
]


@contextlib.contextmanager
def working_directory(path: Path):
    original = Path.cwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(original)


@contextlib.contextmanager
def temporary_env(**updates):
    saved = {key: os.environ.get(key) for key in updates}
    try:
        for key, value in updates.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = str(value)
        yield
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


@contextlib.contextmanager
def temporary_collection_results_tree(results_root=None):
    collection_paths = load_module("collection_paths", "collection_paths.py")
    saved_files = {}
    created_directories = []

    try:
        for collection_id, payload in COLLECTION_FIXTURE_PAYLOADS.items():
            results_path = collection_paths.get_collection_results_path(results_root, collection_id)
            if results_path.exists():
                saved_files[results_path] = results_path.read_text(encoding="utf-8")
            elif not results_path.parent.exists():
                created_directories.append(results_path.parent)

            results_path.parent.mkdir(parents=True, exist_ok=True)
            results_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

        yield
    finally:
        for results_path, original_text in saved_files.items():
            results_path.write_text(original_text, encoding="utf-8")

        for collection_id in COLLECTION_FIXTURE_PAYLOADS:
            results_path = collection_paths.get_collection_results_path(results_root, collection_id)
            if results_path in saved_files:
                continue
            if results_path.exists():
                results_path.unlink()

        for directory in reversed(created_directories):
            if directory.exists() and not any(directory.iterdir()):
                directory.rmdir()


class CollectionPathsTests(unittest.TestCase):
    def test_collection_results_paths_match_actual_results_layout(self):
        collection_paths = load_module("collection_paths", "collection_paths.py")

        expected_paths = {
            "preflight": Path("results") / "collection-preflight" / "preflight-results.json",
            "a": Path("results") / "collection-a" / "collection-a-results.json",
            "b": Path("results") / "collection-b" / "collection-b-results.json",
            "c": Path("results") / "collection-c" / "collection-c-results.json",
            "e": Path("results") / "collection-e" / "collection-e-results.json",
            "d": Path("results") / "collection-d" / "collection-d-results.json",
            "f": Path("results") / "collection-f" / "collection-f-results.json",
            "g": Path("results") / "collection-g" / "collection-g-results.json",
            "h": Path("results") / "collection-h" / "collection-h-results.json",
        }

        for collection_id, expected_path in expected_paths.items():
            with self.subTest(collection_id=collection_id):
                self.assertEqual(
                    collection_paths.get_collection_results_path(Path("results"), collection_id),
                    expected_path,
                )

    def test_default_results_root_is_repo_relative(self):
        collection_paths = load_module("collection_paths", "collection_paths.py")

        expected_root = Path(collection_paths.__file__).resolve().parents[3] / "temp-work" / "runner" / "direct-run"
        self.assertEqual(collection_paths.DEFAULT_RESULTS_ROOT, expected_root)

    def test_default_results_root_uses_run_root_env(self):
        run_root = WORKSPACE_DIR / self._testMethodName / "temp-work" / "20260524_042939_abcdef98fedcba76"

        with temporary_env(CLD6001_RUN_ROOT=run_root):
            collection_paths = load_module("collection_paths", "collection_paths.py")
            self.assertEqual(collection_paths.resolve_results_root(), run_root / "runner" / "direct-run")

    def test_legacy_bases_continue_to_point_to_pre_rename_paths(self):
        collection_paths = load_module("collection_paths", "collection_paths.py")

        expected_legacy_bases = [
            collection_paths.REPO_ROOT / "liverun",
            collection_paths.REPO_ROOT / "results",
        ]
        self.assertEqual(collection_paths.LEGACY_BASES, expected_legacy_bases)

    def test_normalize_layout_reports_legacy_candidates_using_pre_rename_paths(self):
        run_id = "20260524_042939_abcdef98fedcba76"
        script_path = TESTS_DIR.parents[2] / "collect" / "normalize-layout.py"

        result = subprocess.run(
            [sys.executable, str(script_path)],
            capture_output=True,
            text=True,
            check=True,
            timeout=60,
            env={**os.environ, "CLD6001_RUN_ID": run_id},
        )

        payload = json.loads(result.stdout)
        repo_root = script_path.resolve().parents[2]
        self.assertEqual(payload["artifact_root"], str(repo_root / "artifacts" / run_id))
        self.assertEqual(
            payload["legacy_candidates"],
            [
                str(repo_root / "liverun" / run_id),
                str(repo_root / "results" / run_id),
            ],
        )

    def test_default_run_root_prefers_explicit_run_root_when_run_id_is_also_set(self):
        run_id = "20260524_042939_abcdef98fedcba76"
        run_root = WORKSPACE_DIR / self._testMethodName / "temp-work" / run_id

        with temporary_env(CLD6001_RUN_ROOT=run_root, CLD6001_RUN_ID=run_id):
            collection_paths = load_module("collection_paths", "collection_paths.py")
            self.assertEqual(collection_paths.default_run_root(), run_root)
            self.assertEqual(collection_paths.resolve_results_root(), run_root / "runner" / "direct-run")

    def test_collection_results_paths_reject_unknown_identifiers(self):
        collection_paths = load_module("collection_paths", "collection_paths.py")

        with self.assertRaises(ValueError):
            collection_paths.get_collection_results_path(Path("results"), "i")


class CollectionPathsLoadErrorRegressionTests(WorkspaceBackedTestCase):
    WORKSPACE_ROOT = WORKSPACE_DIR

    def test_load_collection_results_rejects_empty_files_as_corrupted_results(self):
        collection_paths = load_module("collection_paths_empty_results", "collection_paths.py")
        results_root = self.workspace / "results"
        results_path = collection_paths.get_collection_results_path(results_root, "preflight")
        results_path.parent.mkdir(parents=True, exist_ok=True)
        results_path.write_text("", encoding="utf-8")

        with self.assertRaisesRegex(collection_paths.CorruptedResultError, str(results_path)):
            collection_paths.load_collection_results("preflight", results_root)

    def test_load_collection_results_rejects_invalid_json_as_corrupted_results(self):
        collection_paths = load_module("collection_paths_invalid_results", "collection_paths.py")
        results_root = self.workspace / "results"
        results_path = collection_paths.get_collection_results_path(results_root, "preflight")
        results_path.parent.mkdir(parents=True, exist_ok=True)
        results_path.write_text("{", encoding="utf-8")

        with self.assertRaisesRegex(collection_paths.CorruptedResultError, str(results_path)):
            collection_paths.load_collection_results("preflight", results_root)


class ReportGeneratorPathRegressionTests(WorkspaceBackedTestCase):
    WORKSPACE_ROOT = WORKSPACE_DIR

    def run_cli_script_with_collection_fixture(self, script_name: str, output_path: Path):
        env = os.environ.copy()
        env["CLD6001_RUN_ROOT"] = str(self.workspace)
        script_path = REPORTS_DIR / script_name

        with temporary_env(CLD6001_RUN_ROOT=self.workspace), temporary_collection_results_tree(results_root=self.workspace / "results"), working_directory(self.workspace):
            return subprocess.run(
                [
                    sys.executable,
                    str(script_path),
                    "--input",
                    "results",
                    "--output",
                    str(output_path),
                ],
                capture_output=True,
                text=True,
                timeout=60,
                cwd=self.workspace,
                env=env,
            )

    def test_report_generator_main_writes_requested_output_file(self):
        report_generator = load_module("report_generator_cli", "report-generator.py")
        output_path = self.workspace / "reports" / "security-research-report.md"

        with temporary_env(CLD6001_RUN_ROOT=self.workspace), temporary_collection_results_tree(results_root=self.workspace / "results"), working_directory(self.workspace):
            report_generator.main(["--input", "results", "--output", str(output_path)])

        self.assertTrue(output_path.exists())
        report_contents = output_path.read_text(encoding="utf-8")
        self.assertIn("Container Security Research Report", report_contents)

    def test_results_matrix_generator_main_writes_requested_output_file(self):
        results_matrix_generator = load_module(
            "results_matrix_generator_cli",
            "results-matrix-generator.py",
        )
        output_path = self.workspace / "reports" / "security-research-results-matrix.json"

        with temporary_env(CLD6001_RUN_ROOT=self.workspace), temporary_collection_results_tree(results_root=self.workspace / "results"), working_directory(self.workspace):
            results_matrix_generator.main(["--input", "results", "--output", str(output_path)])

        self.assertTrue(output_path.exists())
        payload = json.loads(output_path.read_text(encoding="utf-8"))
        self.assertEqual(payload["summary"]["total_collections"], 9)

    def test_statistical_analysis_main_writes_requested_output_file(self):
        statistical_analysis = load_module(
            "statistical_analysis_cli",
            "statistical-analysis.py",
        )
        output_path = self.workspace / "reports" / "statistical-analysis-report.json"

        with temporary_env(CLD6001_RUN_ROOT=self.workspace), temporary_collection_results_tree(results_root=self.workspace / "results"), working_directory(self.workspace):
            statistical_analysis.main(["--input", "results", "--output", str(output_path)])

        self.assertTrue(output_path.exists())
        payload = json.loads(output_path.read_text(encoding="utf-8"))
        self.assertEqual(payload["title"], "Container Security Statistical Analysis")

    def test_report_generator_accepts_run_root_outputs_when_run_id_is_set(self):
        report_generator = load_module("report_generator_cli", "report-generator.py")
        run_id = "20260524_042939_abcdef98fedcba76"
        run_root = self.workspace / "temp-work" / run_id
        output_path = run_root / "reports" / "security-research-report.md"

        with temporary_env(CLD6001_RUN_ROOT=run_root, CLD6001_RUN_ID=run_id):
            validated_path = report_generator.validate_output_path(str(output_path))

        self.assertEqual(validated_path, output_path.resolve())

    def test_report_generator_accepts_export_path_under_run_root(self):
        report_generator = load_module("report_generator_export_path", "report-generator.py")
        run_root = self.workspace / "temp-work" / "20260524_run_for_export"
        output_path = run_root / "export" / "security-research-report.md"

        with temporary_env(CLD6001_RUN_ROOT=run_root):
            validated_path = report_generator.validate_output_path(str(output_path))

        self.assertEqual(validated_path, output_path.resolve())

    def test_report_generator_rejects_artifacts_base_path_outside_run_root_export(self):
        report_generator = load_module("report_generator_reject_artifacts_base", "report-generator.py")
        collection_paths = load_module("collection_paths_artifacts_base", "collection_paths.py")
        output_path = collection_paths.ARTIFACTS_BASE / "some-run" / "report.md"

        with temporary_env(CLD6001_RUN_ROOT=str(self.workspace)):
            with self.assertRaises(ValueError):
                report_generator.validate_output_path(str(output_path))

    def test_resolve_results_root_falls_back_through_evidence_to_legacy_runner(self):
        collection_paths = load_module("collection_paths_fallback_runner", "collection_paths.py")
        run_root = self.workspace / "temp-work" / self._testMethodName
        run_root.mkdir(parents=True)

        with temporary_env(CLD6001_RUN_ROOT=run_root):
            result = collection_paths.resolve_results_root()

        self.assertEqual(result, run_root / "runner" / "direct-run")

    def test_resolve_results_root_uses_evidence_dir_when_present(self):
        collection_paths = load_module("collection_paths_evidence_dir", "collection_paths.py")
        run_root = self.workspace / "temp-work" / self._testMethodName
        evidence_dir = run_root / "evidence"
        evidence_dir.mkdir(parents=True)

        with temporary_env(CLD6001_RUN_ROOT=run_root):
            result = collection_paths.resolve_results_root()

        self.assertEqual(result, evidence_dir)

    def test_get_collection_results_path_accepts_legacy_preflight_filename(self):
        collection_paths = load_module("collection_paths_preflight_legacy", "collection_paths.py")
        results_root = self.workspace / "results"
        legacy_path = results_root / "collection-preflight" / "collection-preflight-results.json"
        legacy_path.parent.mkdir(parents=True, exist_ok=True)
        legacy_path.write_text("{}", encoding="utf-8")

        resolved_path = collection_paths.get_collection_results_path(results_root, "preflight")

        self.assertEqual(resolved_path, legacy_path)


    def test_report_generator_honors_script_argv(self):
        # Regression: script-style CLI invocation should honor sys.argv[1:]
        output_path = self.workspace / "reports" / "cli-argv-report.md"
        result = self.run_cli_script_with_collection_fixture(
            "report-generator.py",
            output_path,
        )
        self.assertEqual(result.returncode, 0)
        self.assertTrue(output_path.exists())
        contents = output_path.read_text(encoding="utf-8")
        self.assertIn("Container Security Research Report", contents)

    def test_results_matrix_generator_honors_script_argv(self):
        # Regression: script-style CLI invocation should honor sys.argv[1:]
        output_path = self.workspace / "reports" / "cli-argv-matrix.json"
        result = self.run_cli_script_with_collection_fixture(
            "results-matrix-generator.py",
            output_path,
        )
        self.assertEqual(result.returncode, 0)
        self.assertTrue(output_path.exists())
        self.assertIn(f"Report saved to {output_path}", result.stdout)
        payload = json.loads(output_path.read_text(encoding="utf-8"))
        self.assertEqual(payload["summary"]["total_collections"], 9)

    def test_statistical_analysis_honors_script_argv(self):
        output_path = self.workspace / "reports" / "cli-argv-statistics.json"
        result = self.run_cli_script_with_collection_fixture(
            "statistical-analysis.py",
            output_path,
        )
        self.assertEqual(result.returncode, 0)
        self.assertTrue(output_path.exists())
        self.assertIn(f"Report saved to {output_path}", result.stdout)
        payload = json.loads(output_path.read_text(encoding="utf-8"))
        self.assertEqual(payload["title"], "Container Security Statistical Analysis")

    def test_load_collection_results_uses_stable_default_root_outside_results_cwd(self):
        report_generator = load_module("report_generator", "report-generator.py")
        collection_paths = load_module("collection_paths", "collection_paths.py")
        other_cwd = self.workspace / "outside-cwd"
        other_cwd.mkdir()

        with temporary_collection_results_tree(), working_directory(other_cwd):
            loaded_collections = [report_generator.load_collection_results(collection_id) for collection_id in collection_paths.REPORT_COLLECTIONS]

        self.assertEqual([c["collection"] for c in loaded_collections], COLLECTION_FIXTURE_ORDER)

    def test_report_generator_generates_summary_report_from_nested_collection_results_layout(self):
        report_generator = load_module("report_generator", "report-generator.py")
        collection_paths = load_module("collection_paths", "collection_paths.py")
        output_path = self.workspace / "reports" / "security-research-report.md"

        with temporary_env(CLD6001_RUN_ROOT=self.workspace), temporary_collection_results_tree(), working_directory(self.workspace):
            loaded_collections = [report_generator.load_collection_results(collection_id) for collection_id in collection_paths.REPORT_COLLECTIONS]
            summary = report_generator.generate_summary(loaded_collections)
            report_generator.generate_report(summary, output_path)

        self.assertEqual(
            [collection["collection"] for collection in summary["collections"]],
            COLLECTION_FIXTURE_ORDER,
        )
        self.assertEqual(
            [collection["title"] for collection in summary["collections"]],
            COLLECTION_TITLES,
        )
        self.assertEqual(summary["summary"]["total_test_cases"], 13)
        self.assertEqual(summary["summary"]["total_success"], 5)
        self.assertEqual(summary["summary"]["total_fail"], 0)
        self.assertEqual(summary["summary"]["total_blocked"], 8)
        report_contents = output_path.read_text(encoding="utf-8")
        self.assertIn("Total Collections:** 9", report_contents)
        self.assertIn("Total Test Cases:** 13", report_contents)
        self.assertIn("Total Successes:** 5", report_contents)
        self.assertIn("Total Blocked:** 8", report_contents)
        self.assertTrue(any(
            sub in report_contents
            for sub in [
                "docker-rootful / tc1_privileged",
                "docker-rootful / TC1_privileged",
            ]
        ))
        self.assertIn("Collection g - Page-Cache Attack Family", report_contents)
        self.assertIn("Collection h - Post-Hardening Validations", report_contents)

    def test_report_generator_renders_reason_text_for_blocked_and_failed_details(self):
        report_generator = load_module("report_generator", "report-generator.py")
        output_path = self.workspace / "reports" / "security-reason-report.md"

        summary = report_generator.generate_summary([
            {
                "collection": "d",
                "title": "SELinux Controls",
                "docker-rootful": {
                    "test_cases": {
                        "tc10": {
                            "status": "completed",
                            "result": "block",
                            "reason_code": "selinux_not_enforcing",
                            "reason_text": "SELinux must be enforcing for TC10 before the comparative labeling check can run.",
                            "reason_source": "testcase-artifact",
                        }
                    }
                },
            },
            {
                "collection": "f",
                "title": "Combined Control Exploration",
                "docker-rootful": {
                    "test_cases": {
                        "tc19": {
                            "status": "completed",
                            "result": "fail",
                            "reason_code": "network_probe_failed",
                            "reason_text": "Network namespace probe could not confirm a populated /proc/net/route inside the container.",
                            "reason_source": "testcase-artifact",
                        }
                    }
                },
            },
        ])

        with temporary_env(CLD6001_RUN_ROOT=self.workspace):
            report_generator.generate_report(summary, output_path)

        report_contents = output_path.read_text(encoding="utf-8")
        self.assertIn(
            "reason: SELinux must be enforcing for TC10 before the comparative labeling check can run.",
            report_contents,
        )
        self.assertIn(
            "reason: Network namespace probe could not confirm a populated /proc/net/route inside the container.",
            report_contents,
        )

    def test_results_matrix_generator_generates_matrix_from_nested_collection_results_layout(self):
        results_matrix_generator = load_module("results_matrix_generator", "results-matrix-generator.py")
        collection_paths = load_module("collection_paths", "collection_paths.py")
        output_path = self.workspace / "reports" / "security-research-results-matrix.json"

        with temporary_env(CLD6001_RUN_ROOT=self.workspace), temporary_collection_results_tree(), working_directory(self.workspace):
            loaded_collections = [results_matrix_generator.load_collection_results(collection_id) for collection_id in collection_paths.REPORT_COLLECTIONS]
            matrix = results_matrix_generator.generate_results_matrix(loaded_collections)
            results_matrix_generator.generate_report(matrix, output_path)

        self.assertEqual(sorted(matrix["matrix"]), sorted(COLLECTION_FIXTURE_ORDER))
        self.assertEqual(matrix["matrix"]["a"]["total_test_cases"], 2)
        self.assertEqual(matrix["matrix"]["a"]["success_count"], 1)
        self.assertEqual(matrix["matrix"]["a"]["blocked_count"], 1)
        self.assertEqual(matrix["matrix"]["a"]["success_rate"], 0.5)
        self.assertEqual(matrix["matrix"]["e"]["success_rate"], 0.0)
        report_payload = json.loads(output_path.read_text(encoding="utf-8"))
        self.assertEqual(report_payload["summary"]["total_collections"], 9)
        self.assertEqual(report_payload["summary"]["total_test_cases"], 13)
        self.assertEqual(report_payload["summary"]["total_successes"], 5)
        self.assertEqual(report_payload["summary"]["total_failures"], 0)
        self.assertEqual(report_payload["summary"]["total_blocked"], 8)

    def test_results_matrix_generator_preserves_flattened_dict_test_case_statuses(self):
        results_matrix_generator = load_module("results_matrix_generator", "results-matrix-generator.py")

        matrix = results_matrix_generator.generate_results_matrix([
            {
                "collection": "legacy-9",
                "title": "Flattened Legacy Shape",
                "test_cases": {
                    "tc1": "success",
                    "tc2": "failure",
                },
                "results": [],
            }
        ])

        self.assertEqual(matrix["matrix"]["legacy-9"]["test_cases"], ["success", "failure"])
        self.assertEqual(matrix["matrix"]["legacy-9"]["total_test_cases"], 2)
        self.assertEqual(matrix["matrix"]["legacy-9"]["success_count"], 1)
        self.assertEqual(matrix["matrix"]["legacy-9"]["failure_count"], 1)
        self.assertEqual(matrix["matrix"]["legacy-9"]["blocked_count"], 0)
        self.assertEqual(matrix["matrix"]["legacy-9"]["success_rate"], 0.5)

    def test_report_generator_rejects_outputs_outside_run_root(self):
        report_generator = load_module("report_generator_cli", "report-generator.py")

        with temporary_env(CLD6001_RUN_ROOT=self.workspace):
            with self.assertRaises(ValueError):
                report_generator.validate_output_path(str(Path(self.workspace).parent / "escape.md"))

    def test_report_generator_rejects_inputs_outside_repo_root(self):
        report_generator = load_module("report_generator_cli", "report-generator.py")
        outside_repo_root = REPORTS_DIR.resolve().parents[3]

        with self.assertRaises(ValueError):
            report_generator.validate_results_root(str(outside_repo_root))

    def test_report_generator_rejects_repo_root_results_input(self):
        report_generator = load_module("report_generator_repo_root_guard", "report-generator.py")
        repo_root = REPORTS_DIR.resolve().parents[2]

        with self.assertRaises(ValueError):
            report_generator.validate_results_root(str(repo_root))

    def test_report_generator_load_required_collection_results_rejects_inputs_outside_repo_root(self):
        report_generator = load_module("report_generator_direct_input_guard", "report-generator.py")
        outside_repo_root = REPORTS_DIR.resolve().parents[3]

        with self.assertRaises(ValueError):
            report_generator.load_required_collection_results(str(outside_repo_root))

    def test_report_generator_load_required_collection_results_exits_with_structured_message_for_corrupted_results(self):
        report_generator = load_module("report_generator_corrupted_results_guard", "report-generator.py")
        results_root = self.workspace / "results"
        stderr_buffer = io.StringIO()

        with temporary_collection_results_tree(results_root=results_root):
            (results_root / "collection-preflight" / "collection-preflight-results.json").write_text("", encoding="utf-8")

        with temporary_env(CLD6001_RUN_ROOT=self.workspace), contextlib.redirect_stderr(stderr_buffer):
            with self.assertRaises(SystemExit) as exc:
                report_generator.load_required_collection_results(str(results_root))

        self.assertEqual(str(exc.exception), "collection preflight: corrupted_result")
        error_payload = json.loads(stderr_buffer.getvalue().strip())
        self.assertEqual(error_payload["collection"], "preflight")
        self.assertEqual(error_payload["error"], "corrupted_result")
        self.assertIn("empty", error_payload["message"])

    def test_report_generator_generate_report_rejects_outputs_outside_run_root(self):
        report_generator = load_module("report_generator_direct_output_guard", "report-generator.py")
        escape_path = Path(self.workspace).parent / "escape.md"

        with temporary_env(CLD6001_RUN_ROOT=self.workspace):
            with self.assertRaises(ValueError):
                report_generator.generate_report({"summary": {}, "collections": [], "date": "2026-05-27T00:00:00"}, str(escape_path))

    def test_results_matrix_generator_rejects_inputs_outside_repo_root(self):
        results_matrix_generator = load_module("results_matrix_generator_cli", "results-matrix-generator.py")
        outside_repo_root = REPORTS_DIR.resolve().parents[3]

        with self.assertRaises(ValueError):
            results_matrix_generator.validate_results_root(str(outside_repo_root))

    def test_results_matrix_generator_rejects_outputs_outside_run_root(self):
        results_matrix_generator = load_module("results_matrix_generator_cli", "results-matrix-generator.py")

        with temporary_env(CLD6001_RUN_ROOT=self.workspace):
            with self.assertRaises(ValueError):
                results_matrix_generator.validate_output_path(str(Path(self.workspace).parent / "escape.json"))

    def test_results_matrix_generator_load_required_collection_results_rejects_inputs_outside_repo_root(self):
        results_matrix_generator = load_module("results_matrix_generator_direct_input_guard", "results-matrix-generator.py")
        outside_repo_root = REPORTS_DIR.resolve().parents[3]

        with self.assertRaises(ValueError):
            results_matrix_generator.load_required_collection_results(str(outside_repo_root))

    def test_results_matrix_generator_generate_report_rejects_outputs_outside_run_root(self):
        results_matrix_generator = load_module("results_matrix_generator_direct_output_guard", "results-matrix-generator.py")
        escape_path = Path(self.workspace).parent / "escape.json"

        with temporary_env(CLD6001_RUN_ROOT=self.workspace):
            with self.assertRaises(ValueError):
                results_matrix_generator.generate_report({"matrix": {}}, str(escape_path))

    def test_statistical_analysis_rejects_inputs_outside_repo_root(self):
        statistical_analysis = load_module("statistical_analysis_input_guard", "statistical-analysis.py")
        outside_repo_root = REPORTS_DIR.resolve().parents[3]

        with self.assertRaises(ValueError):
            statistical_analysis.validate_results_root(str(outside_repo_root))

    def test_statistical_analysis_rejects_outputs_outside_run_root(self):
        statistical_analysis = load_module("statistical_analysis_output_guard", "statistical-analysis.py")
        escape_path = Path(self.workspace).parent / "escape-statistics.json"

        with temporary_env(CLD6001_RUN_ROOT=self.workspace):
            with self.assertRaises(ValueError):
                statistical_analysis.validate_output_path(str(escape_path))

    def test_statistical_analysis_generate_report_rejects_outputs_outside_run_root(self):
        statistical_analysis = load_module("statistical_analysis_direct_output_guard", "statistical-analysis.py")
        escape_path = Path(self.workspace).parent / "escape-statistics.json"

        with temporary_env(CLD6001_RUN_ROOT=self.workspace):
            with self.assertRaises(ValueError):
                statistical_analysis.generate_report({"phase_1": {"n": 1}}, str(escape_path))


class PhaseResultsNormalizationTests(unittest.TestCase):
    def test_non_preflight_testcase_results_require_testcase_data(self):
        collection_results = load_module("collection_results", "collection_results.py")

        with self.assertRaisesRegex(
            ValueError,
            "Non-preflight testcase collection result for collection a contains no testcase data",
        ):
            collection_results.normalize_collection_result(
                {
                    "kind": "testcase",
                    "collection": "a",
                    "title": "Capabilities",
                }
            )

    def test_runtime_oriented_records_reject_unsupported_legacy_runtime_keys(self):
        collection_results = load_module("collection_results", "collection_results.py")

        with self.assertRaisesRegex(ValueError, "Unsupported collection-result runtime key\\(s\\): docker"):
            collection_results.normalize_collection_result(
                {
                    "collection": "d",
                    "title": "SELinux Controls",
                    "docker": {
                        "test_cases": {
                            "tc10": {"status": "completed", "result": "pass"},
                        }
                    },
                }
            )

    def test_runtime_oriented_records_reject_metadata_dicts_with_test_cases(self):
        collection_results = load_module("collection_results", "collection_results.py")

        with self.assertRaisesRegex(ValueError, "Unsupported collection-result runtime key\\(s\\): metadata"):
            collection_results.normalize_collection_result(
                {
                    "collection": "d",
                    "title": "SELinux Controls",
                    "metadata": {
                        "test_cases": {
                            "note": {"status": "completed", "result": "pass"},
                        }
                    },
                    "docker-rootful": {
                        "test_cases": {
                            "tc10": {"status": "completed", "result": "pass"},
                        }
                    },
                }
            )

    def test_flattened_detail_rows_drive_summary_and_prefer_result_over_status(self):
        collection_results = load_module("collection_results", "collection_results.py")

        normalized = collection_results.normalize_collection_result(
            {
                "collection": "legacy-9",
                "title": "Flattened Legacy Shape",
                "test_cases": {
                    "tc_legacy": "success",
                },
                "results": [
                    {
                        "test_case_id": "tc_legacy",
                        "status": "completed",
                        "result": "fail",
                    }
                ],
            }
        )

        self.assertEqual(normalized["test_cases"], ["failure"])
        self.assertEqual(normalized["results"][0]["status"], "failure")
        self.assertEqual(normalized["results"][0]["raw_status"], "completed")
        self.assertEqual(normalized["results"][0]["raw_result"], "fail")

    def test_flattened_detail_rows_merge_remaining_legacy_test_cases(self):
        collection_results = load_module("collection_results", "collection_results.py")

        normalized = collection_results.normalize_collection_result(
            {
                "collection": "legacy-9",
                "title": "Mixed Flattened Legacy Shape",
                "test_cases": {
                    "tc_results": "failure",
                    "tc_fallback": "success",
                },
                "results": [
                    {
                        "test_case_id": "tc_results",
                        "status": "completed",
                        "result": "fail",
                    }
                ],
            }
        )

        self.assertEqual(normalized["test_cases"], ["failure", "success"])
        self.assertEqual(
            [result["test_case_id"] for result in normalized["results"]],
            ["tc_results", "tc_fallback"],
        )
        self.assertEqual(normalized["results"][1]["status"], "success")

    def test_runtime_oriented_records_preserve_reason_metadata_for_blocked_and_failed_results(self):
        collection_results = load_module("collection_results", "collection_results.py")

        normalized = collection_results.normalize_collection_result(
            {
                "collection": "d",
                "title": "SELinux Controls",
                "docker-rootful": {
                    "test_cases": {
                        "tc10": {
                            "status": "completed",
                            "result": "block",
                            "reason_code": "selinux_not_enforcing",
                            "reason_text": "SELinux must be enforcing for TC10 before the comparative labeling check can run.",
                            "reason_source": "testcase-artifact",
                        },
                        "tc19": {
                            "status": "completed",
                            "result": "fail",
                            "reason_code": "network_probe_failed",
                            "reason_text": "Network namespace probe could not confirm a populated /proc/net/route inside the container.",
                            "reason_source": "testcase-artifact",
                        }
                    }
                },
            }
        )

        records = {record["test_case_id"]: record for record in normalized["results"]}

        self.assertEqual(records["tc10"]["status"], "blocked")
        self.assertEqual(records["tc10"]["reason_code"], "selinux_not_enforcing")
        self.assertEqual(
            records["tc10"]["reason_text"],
            "SELinux must be enforcing for TC10 before the comparative labeling check can run.",
        )
        self.assertEqual(records["tc10"]["reason_source"], "testcase-artifact")
        self.assertEqual(records["tc19"]["status"], "failure")
        self.assertEqual(records["tc19"]["reason_code"], "network_probe_failed")
        self.assertEqual(
            records["tc19"]["reason_text"],
            "Network namespace probe could not confirm a populated /proc/net/route inside the container.",
        )
        self.assertEqual(records["tc19"]["reason_source"], "testcase-artifact")

    def test_preflight_runtime_checks_are_normalized_as_results(self):
        collection_results = load_module("collection_results", "collection_results.py")

        normalized = collection_results.normalize_collection_result(
            {
                "collection": "preflight",
                "title": "Environment Setup & Validation",
                "docker-rootful": {
                    "checks": {
                        "disk_headroom:results_root": {
                            "status": "pass",
                            "description": "Live disk headroom for results filesystem",
                            "details": "minimum_bytes=200",
                        },
                        "disk_headroom:temp_work_root": {
                            "status": "fail",
                            "description": "Live disk headroom for temp-work backing filesystem",
                            "details": "minimum_bytes=200",
                        },
                    }
                },
            }
        )

        self.assertEqual(normalized["test_cases"], ["success", "failure"])
        self.assertEqual(
            [result["test_case_id"] for result in normalized["results"]],
            ["disk_headroom:results_root", "disk_headroom:temp_work_root"],
        )
        self.assertEqual(normalized["results"][0]["runtime"], "docker-rootful")
        self.assertEqual(normalized["results"][0]["raw_status"], "pass")
        self.assertEqual(normalized["results"][0]["raw_result"], "pass")
        self.assertEqual(
            normalized["results"][0]["description"],
            "Live disk headroom for results filesystem",
        )
        self.assertEqual(normalized["results"][1]["status"], "failure")
        self.assertEqual(
            normalized["results"][1]["details"],
            "minimum_bytes=200",
        )


if __name__ == "__main__":
    unittest.main()
