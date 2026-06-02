#!/usr/bin/env python3
"""Shared Docker Bench artifact-path helpers for Python tooling."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]


def resolve_docker_bench_artifact_path(
    path_like: str | Path,
    *,
    base_dir: Path | None = None,
) -> Path:
    """Resolve a Docker Bench artifact path to an absolute filesystem path."""
    path = Path(path_like)
    if not path.is_absolute() and base_dir is not None:
        path = base_dir / path
    return path.resolve()


def validate_repo_scoped_output_path(output_file: str | Path) -> Path:
    """Restrict Docker Bench JSON outputs to the repository tree."""
    path = resolve_docker_bench_artifact_path(output_file, base_dir=REPO_ROOT)
    if not path.is_relative_to(REPO_ROOT):
        raise ValueError(f"Output path escapes repository root: {path}")
    return path


def docker_bench_output_base(output_json: str | Path) -> Path:
    """Return the supported Docker Bench sidecar base path for a JSON artifact."""
    output_path = validate_repo_scoped_output_path(output_json)
    return output_path.with_suffix("")


def load_docker_bench_payload(report_path: str | Path) -> Any:
    """Load a Docker Bench JSON payload from an absolute or cwd-relative path."""
    resolved_path = resolve_docker_bench_artifact_path(report_path)
    with resolved_path.open(encoding="utf-8") as handle:
        return json.load(handle)
