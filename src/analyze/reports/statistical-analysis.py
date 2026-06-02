#!/usr/bin/env python3
"""Statistical analysis helpers for collection result payloads."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import math
import statistics
from datetime import datetime
from itertools import combinations
from pathlib import Path
from typing import Any, Dict, List, Tuple

try:
    from scipy.stats import mannwhitneyu, t, ttest_ind
except ModuleNotFoundError:
    class _StudentTDistributionFallback:
        _CRITICAL_975 = {
            1: 12.706204736432095,
            2: 4.302652729696142,
            3: 3.182446305284263,
            4: 2.7764451051977987,
            5: 2.5705818366147395,
            6: 2.4469118511449692,
            7: 2.3646242515927844,
            8: 2.306004135204166,
            9: 2.2621571628540993,
            10: 2.2281388519649385,
            11: 2.200985160082949,
            12: 2.1788128296634177,
            13: 2.160368656461013,
            14: 2.1447866879169273,
            15: 2.131449545559323,
            16: 2.1199052992210112,
            17: 2.1098155778331806,
            18: 2.10092204024096,
            19: 2.0930240544082634,
            20: 2.0859634472658364,
            21: 2.079613844727662,
            22: 2.073873067904015,
            23: 2.068657610419041,
            24: 2.0638985616280205,
            25: 2.059538552753294,
            26: 2.055529438642871,
            27: 2.0518305164802833,
            28: 2.048407141795244,
            29: 2.045229642132703,
            30: 2.0422724563012373,
            40: 2.021075382995338,
            60: 2.000297821058262,
            120: 1.979930405052777,
        }

        def ppf(self, q: float, df: int) -> float:
            if q != 0.975:
                raise ValueError(f"Fallback t distribution only supports q=0.975, got {q}")
            if df < 1:
                raise ValueError(f"Degrees of freedom must be positive, got {df}")
            if df in self._CRITICAL_975:
                return self._CRITICAL_975[df]
            if df > 120:
                return 1.959963984540054

            lower_df = max(key for key in self._CRITICAL_975 if key < df)
            upper_df = min(key for key in self._CRITICAL_975 if key > df)
            lower_value = self._CRITICAL_975[lower_df]
            upper_value = self._CRITICAL_975[upper_df]
            span = upper_df - lower_df
            if span <= 0:
                return lower_value
            fraction = (df - lower_df) / span
            return lower_value + ((upper_value - lower_value) * fraction)

    def _normal_cdf(value: float) -> float:
        return 0.5 * (1.0 + math.erf(value / math.sqrt(2.0)))

    def ttest_ind(sample1, sample2, equal_var=False):
        left = [float(value) for value in sample1]
        right = [float(value) for value in sample2]
        if len(left) < 2 or len(right) < 2:
            raise ValueError("Welch t-test requires at least two samples per group")

        left_mean = statistics.mean(left)
        right_mean = statistics.mean(right)
        left_variance = statistics.variance(left)
        right_variance = statistics.variance(right)
        denominator = math.sqrt((left_variance / len(left)) + (right_variance / len(right)))
        if denominator == 0:
            return 0.0, 1.0

        statistic = (left_mean - right_mean) / denominator
        p_value = max(0.0, min(1.0, 2.0 * (1.0 - _normal_cdf(abs(statistic)))))
        return statistic, p_value

    def mannwhitneyu(sample1, sample2, alternative="two-sided"):
        if alternative != "two-sided":
            raise ValueError(f"Fallback Mann-Whitney only supports two-sided, got {alternative}")

        left = [float(value) for value in sample1]
        right = [float(value) for value in sample2]
        combined = [(value, 0) for value in left] + [(value, 1) for value in right]
        combined.sort(key=lambda item: item[0])

        rank_sums = {0: 0.0, 1: 0.0}
        tie_lengths = []
        index = 0
        while index < len(combined):
            tie_end = index + 1
            while tie_end < len(combined) and combined[tie_end][0] == combined[index][0]:
                tie_end += 1
            average_rank = ((index + 1) + tie_end) / 2.0
            tie_length = tie_end - index
            if tie_length > 1:
                tie_lengths.append(tie_length)
            for tie_index in range(index, tie_end):
                rank_sums[combined[tie_index][1]] += average_rank
            index = tie_end

        n1 = len(left)
        n2 = len(right)
        u1 = rank_sums[0] - (n1 * (n1 + 1) / 2.0)
        u2 = rank_sums[1] - (n2 * (n2 + 1) / 2.0)
        statistic = min(u1, u2)
        mean_u = (n1 * n2) / 2.0
        tie_correction = 1.0
        total_n = n1 + n2
        if tie_lengths:
            tie_correction -= sum(length ** 3 - length for length in tie_lengths) / (total_n ** 3 - total_n)
        variance_u = (n1 * n2 * (total_n + 1) / 12.0) * tie_correction
        if variance_u <= 0:
            return statistic, 1.0

        z_score = (statistic - mean_u) / math.sqrt(variance_u)
        p_value = max(0.0, min(1.0, 2.0 * (1.0 - _normal_cdf(abs(z_score)))))
        return statistic, p_value

    t = _StudentTDistributionFallback()

from aggregate_report_helpers import (
    default_run_report_path,
    parse_report_cli_args,
    validate_results_root,
    validate_run_report_output_path,
)
import collection_paths
from collection_paths import get_collection_results_path, REPORT_COLLECTIONS
from collection_results import normalize_collection_result


SUCCESS_VALUE = 1.0
FAILURE_VALUE = 0.0
NORMALITY_MIN_SAMPLE_SIZE = 3
NORMALITY_MAX_SAMPLE_SIZE = 5000
NORMALITY_SKEWNESS_THRESHOLD = 1.0
NORMALITY_REJECT_P_VALUE = 0.05
NORMALITY_ACCEPT_P_VALUE = 0.15
NORMALITY_OUT_OF_RANGE_P_VALUE = 0.0
NORMALITY_ZERO_VARIANCE_P_VALUE = 0.05
NORMALITY_REASON_SAMPLE_SIZE_OUT_OF_RANGE = "sample_size_out_of_range"
NORMALITY_REASON_ZERO_VARIANCE = "zero_variance"
NORMALITY_REASON_HIGH_SKEW = "high_skew"
NORMALITY_REASON_ACCEPTABLE_SKEW = "acceptable_skew"
MANN_WHITNEY_MIN_SAMPLE_SIZE = 3
MANN_WHITNEY_SIGNIFICANCE_THRESHOLD = 0.05
MANN_WHITNEY_REASON_OK = "ok"
MANN_WHITNEY_REASON_SAMPLE_SIZE_TOO_SMALL = "sample_size_too_small"
MANN_WHITNEY_REASON_DEGENERATE_VARIANCE = "degenerate_variance"
EFFECT_SIZE_MIN_SAMPLE_SIZE = 2
EFFECT_SIZE_REASON_OK = "ok"
EFFECT_SIZE_REASON_SAMPLE_SIZE_TOO_SMALL = "sample_size_too_small"
EFFECT_SIZE_REASON_NONPOSITIVE_POOLED_VARIANCE = "nonpositive_pooled_variance"
validate_output_path = validate_run_report_output_path


@dataclass(frozen=True)
class NormalityAssessment:
    is_normal: bool
    p_value: float
    reason: str

    def as_tuple(self) -> Tuple[bool, float]:
        return self.is_normal, self.p_value


@dataclass(frozen=True)
class MannWhitneyAssessment:
    reason: str
    u_value: float | None = None
    z_score: float | None = None
    p_value: float | None = None
    significant: bool | None = None
    error: str | None = None

    def as_dict(self) -> Dict[str, float | bool | str]:
        if self.error is not None:
            return {"error": self.error}

        if self.u_value is None or self.p_value is None or self.significant is None:
            raise ValueError("Incomplete Mann-Whitney assessment cannot be serialized.")

        result: Dict[str, float | bool | str] = {
            "U": self.u_value,
            "u_statistic": self.u_value,
            "p_value": self.p_value,
            "significant": self.significant,
        }
        if self.z_score is not None:
            result["z_score"] = self.z_score
        return result


@dataclass(frozen=True)
class EffectSizeAssessment:
    effect_size: float
    reason: str


class StatisticalAnalyzer:
    """Load collection results and derive simple statistical summaries."""

    def __init__(self, results_dir: str = "results"):
        self.results_dir = Path(results_dir)
        self.test_data: Dict[str, Dict[str, List[float] | int]] = {}
        self.statistics: Dict[str, Any] = {}

    def aggregate_results(self) -> Dict[str, Dict[str, List[float] | int]]:
        """Aggregate outcome samples from contract-based collection result files."""
        aggregated = {
            f"collection_{collection}": {"samples": [], "n": 0}
            for collection in REPORT_COLLECTIONS
        }

        usable_sample_count = 0
        for collection in REPORT_COLLECTIONS:
            results_path = get_collection_results_path(self.results_dir, collection)
            if not results_path.exists():
                continue

            try:
                with results_path.open(encoding="utf-8") as file:
                    payload = json.load(file)
            except json.JSONDecodeError as error:
                raise ValueError(f"Unable to parse JSON from {results_path}: {error}") from error

            normalized = normalize_collection_result(payload)
            samples = [
                SUCCESS_VALUE if status == "success" else FAILURE_VALUE
                for status in normalized.get("test_cases", [])
                if status in {"success", "failure", "blocked"}
            ]

            aggregated_collection = aggregated[f"collection_{collection}"]
            aggregated_collection["samples"] = samples
            aggregated_collection["n"] = len(samples)
            usable_sample_count += len(samples)

        if usable_sample_count == 0:
            raise ValueError(
                "No usable statistical samples found in collection result inputs."
            )

        self.test_data = aggregated
        return aggregated

    def calculate_descriptive_stats(self, data: List[float]) -> Dict[str, float | int | str]:
        """Calculate descriptive statistics for a dataset."""
        if len(data) < 2:
            return {"error": "Insufficient data (n < 2)", "n": len(data)}

        n = len(data)
        mean = statistics.mean(data)
        stdev = statistics.stdev(data)
        median = statistics.median(data)
        alpha = 0.05
        t_crit = t.ppf(1 - alpha / 2, df=n - 1)
        margin = t_crit * (stdev / math.sqrt(n))
        return {
            "n": n,
            "mean": mean,
            "median": median,
            "stdev": stdev,
            "ci_lower": mean - margin,
            "ci_upper": mean + margin,
        }

    def assess_normality(self, data: List[float]) -> NormalityAssessment:
        """Return an explicit normality assessment for direct callers/tests."""
        if len(data) < NORMALITY_MIN_SAMPLE_SIZE or len(data) > NORMALITY_MAX_SAMPLE_SIZE:
            return NormalityAssessment(
                is_normal=False,
                p_value=NORMALITY_OUT_OF_RANGE_P_VALUE,
                reason=NORMALITY_REASON_SAMPLE_SIZE_OUT_OF_RANGE,
            )

        stdev = statistics.stdev(data)
        if stdev == 0:
            return NormalityAssessment(
                is_normal=False,
                p_value=NORMALITY_ZERO_VARIANCE_P_VALUE,
                reason=NORMALITY_REASON_ZERO_VARIANCE,
            )

        mean = statistics.mean(data)
        skewness = sum(((value - mean) / stdev) ** 3 for value in data) / len(data)
        if abs(skewness) > NORMALITY_SKEWNESS_THRESHOLD:
            return NormalityAssessment(
                is_normal=False,
                p_value=NORMALITY_REJECT_P_VALUE,
                reason=NORMALITY_REASON_HIGH_SKEW,
            )

        return NormalityAssessment(
            is_normal=True,
            p_value=NORMALITY_ACCEPT_P_VALUE,
            reason=NORMALITY_REASON_ACCEPTABLE_SKEW,
        )

    def test_normality(self, data: List[float]) -> Tuple[bool, float]:
        """Compatibility wrapper returning the legacy tuple contract."""
        return self.assess_normality(data).as_tuple()

    def assess_mann_whitney_u(
        self,
        sample1: List[float],
        sample2: List[float],
    ) -> MannWhitneyAssessment:
        """Return an explicit Mann-Whitney assessment for direct callers/tests."""
        n1 = len(sample1)
        n2 = len(sample2)
        if n1 < MANN_WHITNEY_MIN_SAMPLE_SIZE or n2 < MANN_WHITNEY_MIN_SAMPLE_SIZE:
            return MannWhitneyAssessment(
                reason=MANN_WHITNEY_REASON_SAMPLE_SIZE_TOO_SMALL,
                error="Sample sizes too small for Mann-Whitney U test",
            )

        statistic, p_value = mannwhitneyu(sample1, sample2, alternative="two-sided")
        clamped_p_value = max(0.0, min(1.0, float(p_value)))
        return MannWhitneyAssessment(
            reason=MANN_WHITNEY_REASON_OK,
            u_value=float(statistic),
            p_value=clamped_p_value,
            significant=clamped_p_value < MANN_WHITNEY_SIGNIFICANCE_THRESHOLD,
        )

    def mann_whitney_u(self, sample1: List[float], sample2: List[float]) -> Dict[str, float | bool | str]:
        """Compatibility wrapper returning the legacy result-dict contract."""
        return self.assess_mann_whitney_u(sample1, sample2).as_dict()

    def assess_effect_size(
        self,
        sample1: List[float],
        sample2: List[float],
    ) -> EffectSizeAssessment:
        """Return an explicit effect-size assessment for direct callers/tests."""
        if len(sample1) < EFFECT_SIZE_MIN_SAMPLE_SIZE or len(sample2) < EFFECT_SIZE_MIN_SAMPLE_SIZE:
            return EffectSizeAssessment(
                effect_size=0.0,
                reason=EFFECT_SIZE_REASON_SAMPLE_SIZE_TOO_SMALL,
            )

        mean_difference = statistics.mean(sample1) - statistics.mean(sample2)
        variance_1 = statistics.variance(sample1)
        variance_2 = statistics.variance(sample2)
        pooled_variance = (((len(sample1) - 1) * variance_1) + ((len(sample2) - 1) * variance_2)) / (
            len(sample1) + len(sample2) - 2
        )
        if pooled_variance <= 0:
            return EffectSizeAssessment(
                effect_size=0.0,
                reason=EFFECT_SIZE_REASON_NONPOSITIVE_POOLED_VARIANCE,
            )

        return EffectSizeAssessment(
            effect_size=mean_difference / (pooled_variance ** 0.5),
            reason=EFFECT_SIZE_REASON_OK,
        )

    def calculate_effect_size(self, sample1: List[float], sample2: List[float]) -> float:
        """Compatibility wrapper returning the legacy scalar effect size."""
        return self.assess_effect_size(sample1, sample2).effect_size

    def _calculate_inferential_statistics(
        self,
        grouped_samples: Dict[str, List[float]],
    ) -> Dict[str, Dict[str, Dict[str, float | bool | str]]]:
        normality_results: Dict[str, Dict[str, float | bool]] = {}
        for collection_name, samples in grouped_samples.items():
            is_normal, p_value = self.test_normality(samples)
            normality_results[collection_name] = {
                "is_normal": is_normal,
                "p_value": float(p_value),
            }

        comparisons: Dict[str, Dict[str, float | bool | str]] = {}
        for (left_name, left_samples), (right_name, right_samples) in combinations(
            grouped_samples.items(),
            2,
        ):
            comparison_key = f"{left_name}_vs_{right_name}"
            effect_size = float(self.calculate_effect_size(left_samples, right_samples))
            if (
                normality_results[left_name]["is_normal"]
                and normality_results[right_name]["is_normal"]
                and len(left_samples) > 1
                and len(right_samples) > 1
            ):
                statistic, p_value = ttest_ind(left_samples, right_samples, equal_var=False)
                comparisons[comparison_key] = {
                    "test": "welch_t_test",
                    "statistic": float(statistic),
                    "p_value": float(p_value),
                    "significant": float(p_value) < MANN_WHITNEY_SIGNIFICANCE_THRESHOLD,
                    "effect_size": effect_size,
                }
                continue

            mann_whitney_result = self.mann_whitney_u(left_samples, right_samples)
            comparison: Dict[str, float | bool | str] = {
                "test": "mann_whitney_u",
                "effect_size": effect_size,
            }
            if "error" in mann_whitney_result:
                comparison["error"] = str(mann_whitney_result["error"])
            else:
                p_value = float(mann_whitney_result["p_value"])
                comparison.update(
                    {
                        "statistic": float(
                            mann_whitney_result.get(
                                "u_statistic",
                                mann_whitney_result.get("U", 0.0),
                            )
                        ),
                        "p_value": p_value,
                        "significant": bool(
                            mann_whitney_result.get(
                                "significant",
                                p_value < MANN_WHITNEY_SIGNIFICANCE_THRESHOLD,
                            )
                        ),
                    }
                )
            comparisons[comparison_key] = comparison

        return {
            "normality": normality_results,
            "comparisons": comparisons,
        }

    def analyze(self) -> Dict[str, Any]:
        """Calculate descriptive and inferential statistics for aggregated collection data."""
        if not self.test_data:
            self.aggregate_results()

        grouped_samples = {
            collection_name: collection_data["samples"]
            for collection_name, collection_data in self.test_data.items()
            if collection_data["samples"]
        }
        self.statistics = {
            collection_name: self.calculate_descriptive_stats(samples)
            for collection_name, samples in grouped_samples.items()
        }
        if not self.statistics:
            raise ValueError("No usable statistical samples found in collection result inputs.")
        self.statistics["inferential_statistics"] = self._calculate_inferential_statistics(grouped_samples)
        return self.statistics


def generate_report(statistics_payload, filename="statistical-analysis-report.json"):
    """Write the statistical analysis report to JSON."""
    report = {
        "title": "Container Security Statistical Analysis",
        "date": datetime.now().isoformat(),
        "statistics": statistics_payload,
    }
    output_path = validate_output_path(filename)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as file:
        json.dump(report, file, indent=2)
    print(f"Report saved to {output_path}")


def build_parser():
    """Build the CLI parser."""
    parser = argparse.ArgumentParser(description="Generate statistical analysis from collection results.")
    parser.add_argument(
        "--input",
        default=None,
        type=validate_results_root,
        help="Results root directory (must be within workspace)",
    )
    parser.add_argument(
        "--output",
        default=None,
        type=validate_output_path,
        help="Output report path (must be in allowed directories)",
    )
    return parser


def main(argv=None):
    """CLI entry point."""
    args = parse_report_cli_args(build_parser, __file__, argv)
    input_root = args.input if args.input is not None else collection_paths.resolve_results_root()
    output_path = (
        args.output
        if args.output is not None
        else default_run_report_path("statistical-analysis-report.json")
    )
    analyzer = StatisticalAnalyzer(input_root)
    try:
        statistics_payload = analyzer.analyze()
    except ValueError as error:
        if "No usable statistical samples found" not in str(error):
            raise SystemExit(str(error)) from error
        statistics_payload = {"error": str(error)}
    generate_report(statistics_payload, output_path)


if __name__ == "__main__":
    main()
