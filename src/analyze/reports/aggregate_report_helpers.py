#!/usr/bin/env python3
"""Shared helpers for aggregate collection-results report tools."""

from __future__ import annotations

import json
from pathlib import Path
import sys

import collection_paths


RUN_REPORTS_DIRNAME = "reports"


def _allowed_results_roots():
    roots = set()
    roots.add(collection_paths.default_run_root().resolve())
    roots.add(collection_paths.resolve_results_root().resolve())
    return tuple(roots)


def validate_results_root(path_str, *, require_exists=True):
    """Validate input path to prevent path traversal outside the repository tree."""
    if path_str is None:
        return None

    path = Path(path_str).resolve()
    if not any(path.is_relative_to(allowed_root) for allowed_root in _allowed_results_roots()):
        raise ValueError(f"Input path escapes allowed directory: {path}")

    existing_path = path
    while not existing_path.exists() and existing_path != existing_path.parent:
        existing_path = existing_path.parent

    if existing_path.exists() and not existing_path.is_dir():
        raise ValueError(f"Input path is not a directory: {path}")

    if require_exists and not path.exists():
        raise ValueError(f"Input path is not a directory: {path}")

    return path


def validate_run_report_output_path(path_str):
    """Validate aggregate report outputs so they stay under the active run reports directory."""
    if path_str is None:
        return None

    path = Path(path_str).resolve()
    allowed_dir = collection_paths.default_run_root().resolve() / RUN_REPORTS_DIRNAME

    if path.is_relative_to(allowed_dir):
        return path

    raise ValueError(f"Output path not in allowed directories: {path}")


def default_run_report_path(filename):
    """Return the default aggregate report path under the active run root."""
    return collection_paths.default_run_root() / RUN_REPORTS_DIRNAME / filename


def load_required_collection_results(load_collection_results_func, canonical_collections, results_root=None):
    """Load all required collection result payloads or raise a clear validation error."""
    validated_results_root = (
        validate_results_root(results_root)
        if results_root is not None
        else validate_results_root(
            collection_paths.resolve_results_root(),
            require_exists=False,
        )
    )
    collections = []
    for collection in canonical_collections:
        try:
            try:
                collections.append(
                    load_collection_results_func(
                        collection,
                        results_root=validated_results_root,
                    )
                )
            except TypeError as error:
                if (
                    "unexpected keyword argument" in str(error)
                    and "results_root" in str(error)
                ):
                    collections.append(load_collection_results_func(collection))
                else:
                    raise
        except FileNotFoundError as error:
            print(f"Missing results for collection {collection}", file=sys.stderr)
            raise SystemExit(f"collection {collection}") from error
        except collection_paths.CorruptedResultError as error:
            print(
                json.dumps(
                    {
                        "collection": collection,
                        "error": "corrupted_result",
                        "message": str(error),
                    }
                ),
                file=sys.stderr,
            )
            raise SystemExit(f"collection {collection}: corrupted_result") from error
    return collections


# Backward-compatible alias
load_required_phase_results = load_required_collection_results


def parse_report_cli_args(build_parser, script_file, argv=None):
    """Parse CLI arguments while keeping import-time unit-test execution side-effect free."""
    if argv is not None:
        return build_parser().parse_args(argv)

    script_path = Path(sys.argv[0]).resolve()
    this_file = Path(script_file).resolve()
    if script_path == this_file:
        return build_parser().parse_args(sys.argv[1:])

    return build_parser().parse_args([])
