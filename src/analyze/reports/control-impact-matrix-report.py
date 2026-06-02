#!/usr/bin/env python3
"""Generate the full control impact matrix report bundle from leaf matrices."""

from __future__ import annotations

import argparse

from aggregate_report_helpers import (
    default_run_report_path,
    parse_report_cli_args,
    validate_results_root,
    validate_run_report_output_path,
)
import collection_paths
from control_impact_matrix import (
    build_full_matrix,
    load_latest_leaf_matrices,
    write_report_bundle,
)


validate_output_path = validate_run_report_output_path


def build_parser():
    parser = argparse.ArgumentParser(
        description="Generate the full control impact matrix report bundle."
    )
    parser.add_argument(
        "--input",
        default=None,
        type=validate_results_root,
        help="Results root directory containing control impact matrix leaves",
    )
    parser.add_argument(
        "--output",
        default=None,
        type=validate_output_path,
        help="Output JSON report path under the active run reports directory",
    )
    return parser


def main(argv: list[str] | None = None) -> None:
    args = parse_report_cli_args(build_parser, __file__, argv)
    results_root = (
        args.input
        if args.input is not None
        else validate_results_root(
            collection_paths.resolve_results_root(),
            require_exists=False,
        )
    )
    output_path = (
        args.output
        if args.output is not None
        else default_run_report_path("control-impact-matrix.json")
    )

    leaves = load_latest_leaf_matrices(results_root)
    report = build_full_matrix(leaves)
    write_report_bundle(report, output_path)
    print(f"Report saved to {output_path}")


if __name__ == "__main__":
    main()
