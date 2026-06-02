from __future__ import annotations

import io
import json
import math
import sys
import types
import unittest
from pathlib import Path
from unittest import mock


TESTS_DIR = Path(__file__).resolve().parent
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

from module_loader import (
    load_fresh_repo_module as load_module,
    load_repo_module,
    load_reports_module,
)
from workspace_case import WorkspaceBackedTestCase

REPO_ROOT = TESTS_DIR.parents[3]
WORKSPACE_DIR = TESTS_DIR / "workspace"


class WorkspaceTestCase(WorkspaceBackedTestCase):
    WORKSPACE_ROOT = WORKSPACE_DIR


class ModuleLoaderRegressionTests(unittest.TestCase):
    def test_load_repo_module_normalizes_backslash_relative_paths(self):
        collection_paths = load_repo_module(
            "collection_paths_backslash_loader_module",
            r"src\analyze\reports\collection_paths.py",
        )

        self.assertEqual(
            Path(collection_paths.__file__).resolve(),
            (REPO_ROOT / "src/analyze/reports/collection_paths.py").resolve(),
        )

    def test_load_reports_module_discards_stale_report_dependencies(self):
        first_report_generator = load_reports_module(
            "report_generator_first_loader_module",
            "report-generator.py",
        )
        first_collection_paths = first_report_generator.collection_paths
        first_collection_paths._CR31_SENTINEL = "stale"

        second_report_generator = load_reports_module(
            "report_generator_second_loader_module",
            "report-generator.py",
        )

        self.assertIsNot(second_report_generator.collection_paths, first_collection_paths)
        self.assertFalse(hasattr(second_report_generator.collection_paths, "_CR31_SENTINEL"))

    def test_load_fresh_repo_module_discards_stale_report_dependencies(self):
        first_report_generator = load_module(
            "report_generator_first_fresh_loader_module",
            "src/analyze/reports/report-generator.py",
        )
        first_collection_paths = first_report_generator.collection_paths
        first_collection_paths._CR31_SENTINEL = "stale"

        second_report_generator = load_module(
            "report_generator_second_fresh_loader_module",
            "src/analyze/reports/report-generator.py",
        )

        self.assertIsNot(second_report_generator.collection_paths, first_collection_paths)
        self.assertFalse(hasattr(second_report_generator.collection_paths, "_CR31_SENTINEL"))


class StatisticalAnalysisRegressionTests(WorkspaceTestCase):
    def _write_collection_payload(self, collection_id: str, payload: dict):
        collection_paths = load_module("collection_paths_for_stats", "src/analyze/reports/collection_paths.py")
        results_root = self.workspace / "results"
        results_path = collection_paths.get_collection_results_path(results_root, collection_id)
        results_path.parent.mkdir(parents=True, exist_ok=True)
        results_path.write_text(json.dumps(payload), encoding="utf-8")
        return results_root

    def test_aggregate_results_reads_collection_contract_paths(self):
        stats_module = load_module(
            "statistical_analysis_module",
            "src/analyze/reports/statistical-analysis.py",
        )
        results_root = self._write_collection_payload(
            "preflight",
            {
                "collection": "preflight",
                "title": "Baseline",
                "docker-rootful": {
                    "checks": {
                        "disk_headroom:results_root": {
                            "status": "pass",
                            "description": "Live disk headroom for results filesystem",
                        },
                        "disk_headroom:temp_work_root": {
                            "status": "fail",
                            "description": "Live disk headroom for temp-work backing filesystem",
                        },
                    }
                },
            },
        )

        analyzer = stats_module.StatisticalAnalyzer(str(results_root))
        aggregated = analyzer.aggregate_results()

        self.assertEqual(aggregated["collection_preflight"]["samples"], [1.0, 0.0])
        self.assertEqual(aggregated["collection_preflight"]["n"], 2)

    def test_aggregate_results_fails_when_no_usable_input_exists(self):
        stats_module = load_module(
            "statistical_analysis_empty_module",
            "src/analyze/reports/statistical-analysis.py",
        )

        analyzer = stats_module.StatisticalAnalyzer(str(self.workspace / "results"))
        with self.assertRaisesRegex(ValueError, "No usable"):
            analyzer.aggregate_results()

    def test_main_rejects_metadata_only_non_preflight_testcase_inputs(self):
        stats_module = load_module(
            "statistical_analysis_empty_report_module",
            "src/analyze/reports/statistical-analysis.py",
        )
        collection_paths = load_module(
            "collection_paths_empty_report_module",
            "src/analyze/reports/collection_paths.py",
        )
        output_path = self.workspace / "reports" / "statistical-analysis-report.json"
        results_root = self.workspace / "results"

        for collection_id in collection_paths.REPORT_COLLECTIONS:
            results_path = collection_paths.get_collection_results_path(results_root, collection_id)
            results_path.parent.mkdir(parents=True, exist_ok=True)
            results_path.write_text(
                json.dumps(
                    {
                        "kind": "testcase",
                        "collection": collection_id,
                        "title": f"Collection {collection_id}",
                    }
                ),
                encoding="utf-8",
            )

        with mock.patch.dict("os.environ", {"CLD6001_RUN_ROOT": str(self.workspace)}, clear=False):
            with self.assertRaisesRegex(
                SystemExit,
                "Non-preflight testcase collection result for collection a contains no testcase data",
            ):
                stats_module.main(["--input", str(results_root), "--output", str(output_path)])

        self.assertFalse(output_path.exists())

    def test_normality_flags_strongly_skewed_samples(self):
        stats_module = load_module(
            "statistical_analysis_normality_module",
            "src/analyze/reports/statistical-analysis.py",
        )

        analyzer = stats_module.StatisticalAnalyzer(str(self.workspace / "results"))
        is_normal, p_value = analyzer.test_normality([0.0, 0.0, 0.0, 0.0, 10.0])
        assessment = analyzer.assess_normality([0.0, 0.0, 0.0, 0.0, 10.0])

        self.assertFalse(is_normal)
        self.assertLessEqual(p_value, 0.05)
        self.assertFalse(assessment.is_normal)
        self.assertEqual(assessment.reason, stats_module.NORMALITY_REASON_HIGH_SKEW)

    def test_assess_normality_names_sample_size_out_of_range_edge_cases(self):
        stats_module = load_module(
            "statistical_analysis_normality_edge_module",
            "src/analyze/reports/statistical-analysis.py",
        )

        analyzer = stats_module.StatisticalAnalyzer(str(self.workspace / "results"))
        too_small = analyzer.assess_normality([0.0, 1.0])
        too_large = analyzer.assess_normality(list(range(5001)))

        self.assertFalse(too_small.is_normal)
        self.assertEqual(too_small.p_value, stats_module.NORMALITY_OUT_OF_RANGE_P_VALUE)
        self.assertEqual(
            too_small.reason,
            stats_module.NORMALITY_REASON_SAMPLE_SIZE_OUT_OF_RANGE,
        )
        self.assertFalse(too_large.is_normal)
        self.assertEqual(too_large.p_value, stats_module.NORMALITY_OUT_OF_RANGE_P_VALUE)
        self.assertEqual(
            too_large.reason,
            stats_module.NORMALITY_REASON_SAMPLE_SIZE_OUT_OF_RANGE,
        )

    def test_assess_normality_names_zero_variance_edge_case(self):
        stats_module = load_module(
            "statistical_analysis_normality_zero_variance_module",
            "src/analyze/reports/statistical-analysis.py",
        )

        analyzer = stats_module.StatisticalAnalyzer(str(self.workspace / "results"))
        assessment = analyzer.assess_normality([1.0, 1.0, 1.0])

        self.assertFalse(assessment.is_normal)
        self.assertEqual(
            assessment.p_value,
            stats_module.NORMALITY_ZERO_VARIANCE_P_VALUE,
        )
        self.assertEqual(
            assessment.reason,
            stats_module.NORMALITY_REASON_ZERO_VARIANCE,
        )

    def test_calculate_descriptive_stats_uses_t_distribution_for_small_samples(self):
        stats_module = load_module(
            "statistical_analysis_t_distribution_module",
            "src/analyze/reports/statistical-analysis.py",
        )

        analyzer = stats_module.StatisticalAnalyzer(str(self.workspace / "results"))
        result = analyzer.calculate_descriptive_stats([0.0, 1.0, 1.0])

        self.assertEqual(result["n"], 3)
        self.assertAlmostEqual(result["ci_lower"], -0.7675509099164878, places=6)
        self.assertAlmostEqual(result["ci_upper"], 2.100884243249821, places=6)

    def test_mann_whitney_delegates_to_scipy_with_two_sided_alternative(self):
        stats_module = load_module(
            "statistical_analysis_mann_whitney_module",
            "src/analyze/reports/statistical-analysis.py",
        )

        analyzer = stats_module.StatisticalAnalyzer(str(self.workspace / "results"))
        with mock.patch.object(
            stats_module,
            "mannwhitneyu",
            return_value=(7.5, 0.1234),
        ) as mann_whitney:
            result = analyzer.mann_whitney_u([1.0, 1.0, 2.0, 2.0, 3.0], [1.0, 2.0, 2.0, 3.0, 3.0])

        mann_whitney.assert_called_once_with(
            [1.0, 1.0, 2.0, 2.0, 3.0],
            [1.0, 2.0, 2.0, 3.0, 3.0],
            alternative="two-sided",
        )
        self.assertEqual(
            result,
            {
                "U": 7.5,
                "u_statistic": 7.5,
                "p_value": 0.1234,
                "significant": False,
            },
        )

    def test_analyze_routes_normal_groups_to_t_test_with_effect_size(self):
        stats_module = load_module(
            "statistical_analysis_parametric_pipeline_module",
            "src/analyze/reports/statistical-analysis.py",
        )

        analyzer = stats_module.StatisticalAnalyzer(str(self.workspace / "results"))
        analyzer.test_data = {
            "phase_1": {"samples": [1.0, 2.0, 3.0, 4.0, 5.0], "n": 5},
            "phase_2": {"samples": [2.0, 3.0, 4.0, 5.0, 6.0], "n": 5},
        }

        with mock.patch.object(analyzer, "aggregate_results", return_value=analyzer.test_data), mock.patch.object(
            analyzer,
            "test_normality",
            side_effect=[(True, 0.4), (True, 0.3)],
        ) as normality, mock.patch.object(
            stats_module,
            "ttest_ind",
            return_value=(1.5, 0.14),
        ) as t_test, mock.patch.object(
            analyzer,
            "mann_whitney_u",
        ) as mann_whitney, mock.patch.object(
            analyzer,
            "calculate_effect_size",
            return_value=0.42,
        ) as effect_size:
            result = analyzer.analyze()

        self.assertEqual(normality.call_count, 2)
        t_test.assert_called_once_with(
            [1.0, 2.0, 3.0, 4.0, 5.0],
            [2.0, 3.0, 4.0, 5.0, 6.0],
            equal_var=False,
        )
        mann_whitney.assert_not_called()
        effect_size.assert_called_once_with(
            [1.0, 2.0, 3.0, 4.0, 5.0],
            [2.0, 3.0, 4.0, 5.0, 6.0],
        )
        self.assertTrue(result["inferential_statistics"]["normality"]["phase_1"]["is_normal"])
        self.assertEqual(
            result["inferential_statistics"]["comparisons"]["phase_1_vs_phase_2"],
            {
                "test": "welch_t_test",
                "statistic": 1.5,
                "p_value": 0.14,
                "significant": False,
                "effect_size": 0.42,
            },
        )

    def test_analyze_routes_nonnormal_groups_to_mann_whitney_with_effect_size(self):
        stats_module = load_module(
            "statistical_analysis_nonparametric_pipeline_module",
            "src/analyze/reports/statistical-analysis.py",
        )

        analyzer = stats_module.StatisticalAnalyzer(str(self.workspace / "results"))
        analyzer.test_data = {
            "phase_1": {"samples": [0.0, 0.0, 0.0, 0.0, 10.0], "n": 5},
            "phase_2": {"samples": [0.0, 0.0, 1.0, 1.0, 10.0], "n": 5},
        }

        with mock.patch.object(analyzer, "aggregate_results", return_value=analyzer.test_data), mock.patch.object(
            analyzer,
            "test_normality",
            side_effect=[(False, 0.01), (False, 0.02)],
        ) as normality, mock.patch.object(
            stats_module,
            "ttest_ind",
        ) as t_test, mock.patch.object(
            analyzer,
            "mann_whitney_u",
            return_value={"u_statistic": 4.0, "p_value": 0.03},
        ) as mann_whitney, mock.patch.object(
            analyzer,
            "calculate_effect_size",
            return_value=0.55,
        ) as effect_size:
            result = analyzer.analyze()

        self.assertEqual(normality.call_count, 2)
        t_test.assert_not_called()
        mann_whitney.assert_called_once_with(
            [0.0, 0.0, 0.0, 0.0, 10.0],
            [0.0, 0.0, 1.0, 1.0, 10.0],
        )
        effect_size.assert_called_once_with(
            [0.0, 0.0, 0.0, 0.0, 10.0],
            [0.0, 0.0, 1.0, 1.0, 10.0],
        )
        self.assertFalse(result["inferential_statistics"]["normality"]["phase_1"]["is_normal"])
        self.assertEqual(
            result["inferential_statistics"]["comparisons"]["phase_1_vs_phase_2"],
            {
                "test": "mann_whitney_u",
                "statistic": 4.0,
                "p_value": 0.03,
                "significant": True,
                "effect_size": 0.55,
            },
        )

    def test_assess_mann_whitney_names_small_sample_edge_case(self):
        stats_module = load_module(
            "statistical_analysis_mann_whitney_edge_module",
            "src/analyze/reports/statistical-analysis.py",
        )

        analyzer = stats_module.StatisticalAnalyzer(str(self.workspace / "results"))
        assessment = analyzer.assess_mann_whitney_u([1.0, 2.0], [3.0, 4.0])

        self.assertEqual(
            assessment.reason,
            stats_module.MANN_WHITNEY_REASON_SAMPLE_SIZE_TOO_SMALL,
        )
        self.assertEqual(
            assessment.error,
            "Sample sizes too small for Mann-Whitney U test",
        )
        self.assertEqual(
            analyzer.mann_whitney_u([1.0, 2.0], [3.0, 4.0]),
            {"error": "Sample sizes too small for Mann-Whitney U test"},
        )

    def test_assess_effect_size_names_nonpositive_pooled_variance_edge_case(self):
        stats_module = load_module(
            "statistical_analysis_effect_size_edge_module",
            "src/analyze/reports/statistical-analysis.py",
        )

        analyzer = stats_module.StatisticalAnalyzer(str(self.workspace / "results"))
        assessment = analyzer.assess_effect_size([1.0, 1.0], [1.0, 1.0])

        self.assertEqual(assessment.effect_size, 0.0)
        self.assertEqual(
            assessment.reason,
            stats_module.EFFECT_SIZE_REASON_NONPOSITIVE_POOLED_VARIANCE,
        )
        self.assertEqual(analyzer.calculate_effect_size([1.0, 1.0], [1.0, 1.0]), 0.0)


class ImageScannerRegressionTests(unittest.TestCase):
    def test_scan_image_parses_trivy_results_and_vulnerabilities(self):
        image_scanner = load_module(
            "image_scanner_module",
            "src/collect/scanners/image-scanner.py",
        )
        completed_process = types.SimpleNamespace(
            returncode=0,
            stdout=json.dumps(
                {
                    "Results": [
                        {
                            "Vulnerabilities": [
                                {"Severity": "CRITICAL"},
                                {"Severity": "HIGH"},
                            ]
                        },
                        {
                            "Vulnerabilities": [
                                {"Severity": "HIGH"},
                                {"Severity": "MEDIUM"},
                                {"Severity": "LOW"},
                            ]
                        },
                    ]
                }
            ),
            stderr="",
        )

        with mock.patch.object(image_scanner.subprocess, "run", return_value=completed_process):
            result = image_scanner.scan_image("python:3.12", "stock")

        self.assertEqual(result["total_vulnerabilities"], 5)
        self.assertEqual(result["critical"], 1)
        self.assertEqual(result["high"], 2)
        self.assertEqual(result["medium"], 1)
        self.assertEqual(result["low"], 1)

    def test_scan_image_surfaces_subprocess_failures(self):
        image_scanner = load_module(
            "image_scanner_error_module",
            "src/collect/scanners/image-scanner.py",
        )

        with mock.patch.object(
            image_scanner.subprocess,
            "run",
            side_effect=image_scanner.subprocess.CalledProcessError(1, ["trivy"], stderr="boom"),
        ):
            with self.assertRaisesRegex(RuntimeError, "boom"):
                image_scanner.scan_image("python:3.12", "stock")

    def test_scan_image_uses_scan_timeout_and_returns_graceful_timeout_result(self):
        image_scanner = load_module(
            "image_scanner_timeout_module",
            "src/collect/scanners/image-scanner.py",
        )

        def run_side_effect(command, capture_output, text, check, timeout):
            self.assertEqual(command, ["trivy", "image", "python:3.12", "--format", "json"])
            self.assertEqual(timeout, 600)
            raise image_scanner.subprocess.TimeoutExpired(command, timeout)

        with self.assertLogs(image_scanner.__name__, level="ERROR") as captured, mock.patch.object(
            image_scanner.subprocess,
            "run",
            side_effect=run_side_effect,
        ):
            result = image_scanner.scan_image("python:3.12", "stock")

        self.assertEqual(result["image"], "python:3.12")
        self.assertEqual(result["category"], "stock")
        self.assertEqual(result["total_vulnerabilities"], 0)
        self.assertEqual(result["critical"], 0)
        self.assertEqual(result["high"], 0)
        self.assertEqual(result["medium"], 0)
        self.assertEqual(result["low"], 0)
        self.assertEqual(result["status"], "timeout")
        self.assertIn("timed out", result["error"])
        self.assertTrue(any("python:3.12" in message for message in captured.output))


class ImageScannerOutputPathRegressionTests(WorkspaceTestCase):
    def test_generate_report_requires_run_context_for_default_output(self):
        image_scanner = load_module(
            "image_scanner_default_output_module",
            "src/collect/scanners/image-scanner.py",
        )

        with self.assertRaisesRegex(ValueError, "CLD6001_RUN_ROOT"):
            image_scanner.generate_report([])

    def test_generate_report_writes_default_output_under_run_root_evidence(self):
        image_scanner = load_module(
            "image_scanner_run_root_output_module",
            "src/collect/scanners/image-scanner.py",
        )

        with mock.patch.dict(image_scanner.os.environ, {"CLD6001_RUN_ROOT": str(self.workspace)}, clear=False):
            output_path = image_scanner.generate_report(
                [
                    {
                        "image": "python:3.12",
                        "category": "stock",
                        "total_vulnerabilities": 0,
                        "critical": 0,
                        "high": 0,
                        "medium": 0,
                        "low": 0,
                    }
                ],
            )

        self.assertEqual(output_path, self.workspace / "evidence" / "image-vulnerability-report.json")
        self.assertTrue(output_path.exists())

    def test_generate_report_rejects_explicit_output_outside_evidence_root(self):
        image_scanner = load_module(
            "image_scanner_explicit_output_guard_module",
            "src/collect/scanners/image-scanner.py",
        )
        escape_path = self.workspace / "reports" / "image-vulnerability-report.json"

        with mock.patch.dict(image_scanner.os.environ, {"CLD6001_RUN_ROOT": str(self.workspace)}, clear=False):
            with self.assertRaisesRegex(ValueError, "evidence"):
                image_scanner.generate_report([], str(escape_path))


class DockerBenchWrapperRegressionTests(WorkspaceTestCase):
    def test_run_docker_bench_rejects_outputs_outside_repo_root(self):
        docker_bench_wrapper = load_module(
            "docker_bench_wrapper_outside_path_module",
            "src/collect/scanners/docker-bench-wrapper.py",
        )
        escape_path = REPO_ROOT.parent / "docker-bench-results.json"

        with mock.patch.object(docker_bench_wrapper.subprocess, "run") as mock_run:
            with self.assertRaises(ValueError):
                docker_bench_wrapper.run_docker_bench(str(escape_path))

        mock_run.assert_not_called()

    def test_run_docker_bench_reads_repo_scoped_output(self):
        docker_bench_wrapper = load_module(
            "docker_bench_wrapper_repo_path_module",
            "src/collect/scanners/docker-bench-wrapper.py",
        )
        output_path = self.workspace / "docker-bench-results.json"
        expected_payload = [{"level": "WARN"}]
        expected_log_path = output_path.with_suffix("")

        def run_side_effect(command, capture_output, text, check, timeout):
            self.assertEqual(command, ["docker-bench-security", "-l", str(expected_log_path)])
            self.assertEqual(timeout, 600)
            output_path.write_text(json.dumps(expected_payload), encoding="utf-8")
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")

        with mock.patch.object(docker_bench_wrapper.subprocess, "run", side_effect=run_side_effect):
            payload = docker_bench_wrapper.run_docker_bench(str(output_path))

        self.assertEqual(payload, expected_payload)

    def test_run_docker_bench_raises_runtime_error_when_scan_times_out(self):
        docker_bench_wrapper = load_module(
            "docker_bench_wrapper_timeout_module",
            "src/collect/scanners/docker-bench-wrapper.py",
        )
        output_path = self.workspace / "docker-bench-results.json"
        expected_log_path = output_path.with_suffix("")

        def run_side_effect(command, capture_output, text, check, timeout):
            self.assertEqual(command, ["docker-bench-security", "-l", str(expected_log_path)])
            self.assertEqual(timeout, 600)
            raise docker_bench_wrapper.subprocess.TimeoutExpired(command, timeout)

        with self.assertLogs(docker_bench_wrapper.__name__, level="ERROR") as captured, mock.patch.object(
            docker_bench_wrapper.subprocess,
            "run",
            side_effect=run_side_effect,
        ):
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                docker_bench_wrapper.run_docker_bench(str(output_path))

        self.assertTrue(any("docker-bench-security" in message for message in captured.output))


class DockerBenchArtifactPathRegressionTests(WorkspaceTestCase):
    def test_docker_bench_helper_rejects_outputs_outside_repo_root(self):
        docker_bench_helpers = load_module(
            "docker_bench_helpers_outside_path_module",
            "src/analyze/docker_bench_helpers.py",
        )
        escape_path = REPO_ROOT.parent / "docker-bench-results.json"

        with self.assertRaises(ValueError):
            docker_bench_helpers.validate_repo_scoped_output_path(str(escape_path))

    def test_docker_bench_helper_derives_repo_scoped_sidecar_base(self):
        docker_bench_helpers = load_module(
            "docker_bench_helpers_sidecar_base_module",
            "src/analyze/docker_bench_helpers.py",
        )

        expected_base = self.workspace / "docker-bench-results"
        self.assertEqual(
            docker_bench_helpers.docker_bench_output_base(str(self.workspace / "docker-bench-results.json")),
            expected_base.resolve(),
        )

    def test_docker_bench_comparison_report_generates_html_from_json_inputs(self):
        docker_bench_comparison_report = load_module(
            "docker_bench_comparison_report_module",
            "src/analyze/reports/docker-bench-comparison-report.py",
        )
        pre_path = self.workspace / "docker-bench-pre.json"
        post_path = self.workspace / "docker-bench-post.json"
        output_path = self.workspace / "comparison.html"

        pre_path.write_text(json.dumps({"Checks": [{"Level": "WARNING"}]}), encoding="utf-8")
        post_path.write_text(json.dumps({"Checks": [{"Level": "INFO"}]}), encoding="utf-8")

        docker_bench_comparison_report.main(
            [
                "--pre",
                str(pre_path),
                "--post",
                str(post_path),
                "--output",
                str(output_path),
            ]
        )

        self.assertTrue(output_path.exists())
        report_contents = output_path.read_text(encoding="utf-8")
        self.assertIn("Docker Bench Hardening Comparison", report_contents)
        self.assertIn("WARN", report_contents)
        self.assertIn("INFO", report_contents)


class RepoInputHelperRegressionTests(WorkspaceTestCase):
    def test_repo_input_helper_rejects_inputs_outside_repo_root(self):
        repo_input_helpers = load_module(
            "repo_input_helpers_outside_path_module",
            "src/analyze/repo_input_helpers.py",
        )
        escape_path = REPO_ROOT.parent / "analysis-input.json"

        with self.assertRaises(ValueError):
            repo_input_helpers.validate_repo_scoped_input_path(str(escape_path))

    def test_repo_input_helper_reads_repo_scoped_json(self):
        repo_input_helpers = load_module(
            "repo_input_helpers_repo_path_module",
            "src/analyze/repo_input_helpers.py",
        )
        input_path = self.workspace / "analysis-input.json"
        payload = {"items": []}
        input_path.write_text(json.dumps(payload), encoding="utf-8")

        self.assertEqual(repo_input_helpers.load_repo_scoped_json_input(str(input_path)), payload)


class SecurityControlAnalysisRegressionTests(WorkspaceTestCase):
    def test_load_security_data_rejects_inputs_outside_repo_root(self):
        security_control_analysis = load_module(
            "security_control_analysis_outside_path_module",
            "src/analyze/reports/security-control-analysis.py",
        )
        escape_path = REPO_ROOT.parent / "security-controls.json"

        with self.assertRaises(ValueError):
            security_control_analysis.load_security_data(str(escape_path))

    def test_load_security_data_reads_repo_scoped_file(self):
        security_control_analysis = load_module(
            "security_control_analysis_repo_path_module",
            "src/analyze/reports/security-control-analysis.py",
        )
        input_path = self.workspace / "security-controls.json"
        payload = [{"name": "seccomp", "effectiveness": 0.95}]
        input_path.write_text(json.dumps(payload), encoding="utf-8")

        self.assertEqual(security_control_analysis.load_security_data(str(input_path)), payload)

    def test_supply_chain_analysis_accepts_numeric_counts_and_error_sentinel(self):
        security_control_analysis = load_module(
            "security_control_analysis_numeric_contract_module",
            "src/analyze/reports/security-control-analysis.py",
        )

        report = security_control_analysis.build_report(
            {
                "analysis_type": "supply-chain",
                "images": [
                    {
                        "family": "standard",
                        "image": "nginx",
                        "sbom": "2",
                        "attestation": "1",
                        "provenance": "0",
                    },
                    {
                        "family": "dhi",
                        "image": "dhi.io/nginx",
                        "sbom": "ERROR",
                        "attestation": "0",
                        "provenance": "0",
                    },
                ],
            }
        )

        self.assertEqual(report["summary"]["total_images"], 2)
        self.assertEqual(report["summary"]["images_with_errors"], 1)
        self.assertEqual(report["summary"]["images_with_sbom_evidence"], 1)
        self.assertEqual(report["summary"]["images_with_attestation_evidence"], 1)
        self.assertEqual(report["summary"]["images_with_provenance_evidence"], 0)
        self.assertEqual(report["analysis"]["images"][0]["total_observed_signals"], 3)
        self.assertIsNone(report["analysis"]["images"][1]["total_observed_signals"])
        self.assertEqual(report["analysis"]["images"][1]["error_fields"], ["sbom"])

    def test_supply_chain_analysis_rejects_non_numeric_markers_outside_contract(self):
        security_control_analysis = load_module(
            "security_control_analysis_rejects_present_marker_module",
            "src/analyze/reports/security-control-analysis.py",
        )

        with self.assertRaisesRegex(
            ValueError,
            "Unsupported count marker: 'present'. Expected an integer or ERROR.",
        ):
            security_control_analysis.build_report(
                {
                    "analysis_type": "supply-chain",
                    "images": [
                        {
                            "family": "standard",
                            "image": "nginx",
                            "sbom": "present",
                            "attestation": "present",
                            "provenance": "present",
                        }
                    ],
                }
            )


class ReportGeneratorRegressionTests(unittest.TestCase):
    def test_report_generator_exits_cleanly_when_collection_results_are_missing(self):
        report_generator = load_module(
            "report_generator_missing_collection_module",
            "src/analyze/reports/report-generator.py",
        )

        missing_file = str(Path("results") / "collection-a" / "collection-a-results.json")

        def load_collection_results_side_effect(collection_id):
            if str(collection_id) == "a":
                raise FileNotFoundError(2, "No such file or directory", missing_file)
            return {"collection": "preflight", "title": f"Collection {collection_id}", "test_cases": []}

        with mock.patch.object(report_generator, "load_collection_results", side_effect=load_collection_results_side_effect):
            with self.assertRaisesRegex(SystemExit, "collection a"):
                report_generator.main()

    def test_results_matrix_generator_exits_cleanly_when_collection_results_are_missing(self):
        results_matrix_generator = load_module(
            "results_matrix_generator_missing_collection_module",
            "src/analyze/reports/results-matrix-generator.py",
        )

        missing_file = str(Path("results") / "collection-b" / "collection-b-results.json")

        def load_collection_results_side_effect(collection_id):
            if str(collection_id) == "b":
                raise FileNotFoundError(2, "No such file or directory", missing_file)
            return {"collection": "preflight", "title": f"Collection {collection_id}", "test_cases": []}

        with mock.patch.object(
            results_matrix_generator,
            "load_collection_results",
            side_effect=load_collection_results_side_effect,
        ):
            with self.assertRaisesRegex(SystemExit, "collection b"):
                results_matrix_generator.main()


if __name__ == "__main__":
    unittest.main()
