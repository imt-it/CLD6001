#!/usr/bin/env python3
"""Generate markdown summaries for normalized collection result data."""

from __future__ import annotations

from datetime import datetime
import re

from aggregate_report_helpers import (
    default_run_report_path,
    load_required_collection_results as load_required_collection_results_helper,
    parse_report_cli_args,
    validate_results_root,
    validate_run_report_output_path,
)
import collection_paths
from collection_paths import load_collection_results, REPORT_COLLECTIONS
from collection_results import normalize_collection_result


import argparse


def validate_output_path(path_str):
    """Validate output path; allows paths under the run-root reports dir or run-root export/."""
    if path_str is None:
        return None
    from pathlib import Path
    path = Path(path_str).resolve()
    export_dir = collection_paths.default_run_root().resolve() / "export"
    if path.is_relative_to(export_dir):
        return path
    return validate_run_report_output_path(path_str)


def load_required_collection_results(results_root=None):
    """Load all required collection result payloads or raise a clear validation error."""
    return load_required_collection_results_helper(
        load_collection_results,
        REPORT_COLLECTIONS,
        results_root=results_root,
    )


load_required_phase_results = load_required_collection_results

def build_parser():
    parser = argparse.ArgumentParser(description="Generate markdown summary from collection results.")
    parser.add_argument("--input", default=None, type=validate_results_root,
                       help="Results root directory (must be within workspace)")
    parser.add_argument("--output", default=None, type=validate_output_path,
                       help="Output report path (must be in allowed directories)")
    return parser

def generate_summary(results):
    """Build a report summary from raw collection result payloads."""
    normalized_results = [normalize_collection_result(result) for result in results]
    return {
        "title": "Container Security Research Results Summary",
        "date": datetime.now().isoformat(),
        "summary": {
            "total_collections": len(normalized_results),
            "total_test_cases": sum(len(collection.get("test_cases", [])) for collection in normalized_results),
            "total_success": sum(collection.get("test_cases", []).count("success") for collection in normalized_results),
            "total_fail": sum(collection.get("test_cases", []).count("failure") for collection in normalized_results),
            "total_blocked": sum(collection.get("test_cases", []).count("blocked") for collection in normalized_results),
        },
        "collections": normalized_results,
    }


def format_test_case_label(test_case_id, runtime=None):
    label = str(test_case_id or "unknown")
    match = re.fullmatch(r"tc(\d+)(.*)", label, re.IGNORECASE)
    if match is not None:
        label = f"TC{match.group(1)}{match.group(2)}"

    if runtime:
        return f"{runtime} / {label}"
    return label


def generate_report(summary, filename="security-research-report.md"):
    output_path = validate_output_path(filename)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as file:
        file.write("# Container Security Research Report\n\n")
        file.write("## Summary\n\n")
        file.write(f"- **Date:** {summary['date']}\n")
        file.write(f"- **Total Collections:** {summary['summary']['total_collections']}\n")
        file.write(f"- **Total Test Cases:** {summary['summary']['total_test_cases']}\n")
        file.write(f"- **Total Successes:** {summary['summary']['total_success']}\n")
        file.write(f"- **Total Failures:** {summary['summary']['total_fail']}\n")
        file.write(f"- **Total Blocked:** {summary['summary']['total_blocked']}\n")

        for collection_result in summary["collections"]:
            collection = collection_result.get("collection", "unknown")
            title = collection_result.get("title", "unknown")
            test_cases = collection_result.get("test_cases", [])
            file.write(f"\n## Collection {collection} - {title}\n\n")
            file.write(f"- **Collection:** {collection}\n")
            file.write(f"- **Test Cases:** {len(test_cases)}\n")
            file.write(f"- **Successes:** {test_cases.count('success')}\n")
            file.write(f"- **Failures:** {test_cases.count('failure')}\n")
            file.write(f"- **Blocked:** {test_cases.count('blocked')}\n")

            results = collection_result.get("results", [])
            if results:
                file.write("\n### Detailed Results\n\n")
                for test_case in results:
                    test_case_label = format_test_case_label(
                        test_case.get("test_case_id", "unknown"),
                        runtime=test_case.get("runtime"),
                    )

                    raw_status = test_case.get("raw_status")
                    raw_result = test_case.get("raw_result")
                    detail_parts = [value for value in (raw_status, raw_result) if value]
                    detail_suffix = f" ({'/'.join(detail_parts)})" if detail_parts else ""
                    file.write(
                        f"- **Test Case {test_case_label}:** "
                        f"{test_case.get('status', 'unknown')}{detail_suffix}\n"
                    )
                    reason_text = test_case.get("reason_text")
                    if reason_text:
                        file.write(f"  - reason: {reason_text}\n")

    print(f"Report saved to {output_path}")


def main(argv=None):
    args = parse_report_cli_args(build_parser, __file__, argv)
    input_root = args.input
    output_path = (
        args.output
        if args.output is not None
        else default_run_report_path("security-research-report.md")
    )
    collections = load_required_collection_results(input_root)
    summary = generate_summary(collections)
    generate_report(summary, output_path)


if __name__ == "__main__":
    main()
