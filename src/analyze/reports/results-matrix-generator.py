#!/usr/bin/env python3
"""Generate JSON matrix summaries from normalized collection result data."""

from __future__ import annotations

import json
from datetime import datetime

from aggregate_report_helpers import (
    default_run_report_path,
    load_required_collection_results as load_required_collection_results_helper,
    parse_report_cli_args,
    validate_results_root,
    validate_run_report_output_path,
)
from collection_paths import load_collection_results, REPORT_COLLECTIONS
from collection_results import normalize_collection_result


import argparse

import collection_paths


validate_output_path = validate_run_report_output_path


def load_required_collection_results(results_root=None):
    """Load all required collection result payloads or raise a clear validation error."""
    return load_required_collection_results_helper(
        load_collection_results,
        REPORT_COLLECTIONS,
        results_root=results_root,
    )


# Backward-compatible alias
load_required_phase_results = load_required_collection_results

def build_parser():
    parser = argparse.ArgumentParser(description="Generate JSON matrix from collection results.")
    parser.add_argument("--input", default=None, type=validate_results_root,
                        help="Results root directory (must be within workspace)")
    parser.add_argument("--output", default=None, type=validate_output_path,
                        help="Output report path (must be in allowed directories)")
    return parser

def generate_results_matrix(collection_results):
    """Build a per-collection matrix with success rates."""
    matrix = {
        "title": "Container Security Research Results Matrix",
        "date": datetime.now().isoformat(),
        "matrix": {},
    }

    for collection_result in (
        normalize_collection_result(result) for result in collection_results
    ):
        collection = collection_result.get("collection", "unknown")
        test_cases = list(collection_result.get("test_cases", []))
        success_count = sum(1 for case in test_cases if case == "success")
        failure_count = sum(1 for case in test_cases if case == "failure")
        blocked_count = sum(1 for case in test_cases if case == "blocked")
        total_test_cases = len(test_cases)
        matrix["matrix"][collection] = {
            "title": collection_result.get("title", "unknown"),
            "collection": collection,
            "test_cases": test_cases,
            "total_test_cases": total_test_cases,
            "success_count": success_count,
            "failure_count": failure_count,
            "blocked_count": blocked_count,
            "success_rate": (
                success_count / total_test_cases
                if total_test_cases
                else 0
            ),
        }

    return matrix


def generate_report(matrix, filename="security-research-results-matrix.json"):
    """Write the matrix report to JSON."""
    report = {
        "title": "Container Security Research Results Matrix Report",
        "date": datetime.now().isoformat(),
        "summary": {
            "total_collections": len(matrix["matrix"]),
            "total_test_cases": sum(len(collection.get("test_cases", [])) for collection in matrix["matrix"].values()),
            "total_successes": sum(
                sum(1 for case in collection.get("test_cases", []) if case == "success")
                for collection in matrix["matrix"].values()
            ),
            "total_failures": sum(
                sum(1 for case in collection.get("test_cases", []) if case == "failure")
                for collection in matrix["matrix"].values()
            ),
            "total_blocked": sum(
                sum(1 for case in collection.get("test_cases", []) if case == "blocked")
                for collection in matrix["matrix"].values()
            ),
        },
        "matrix": matrix,
    }

    output_path = validate_output_path(filename)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as file:
        json.dump(report, file, indent=2)
    print(f"Report saved to {output_path}")


def main(argv=None):
    args = parse_report_cli_args(build_parser, __file__, argv)
    input_root = args.input
    output_path = (
        args.output
        if args.output is not None
        else default_run_report_path("security-research-results-matrix.json")
    )
    collections = load_required_collection_results(input_root)
    matrix = generate_results_matrix(collections)
    generate_report(matrix, output_path)


if __name__ == "__main__":
    main()
