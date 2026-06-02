#!/usr/bin/env python3
"""Collection-results path helpers."""

import json
import os
from pathlib import Path


from typing import Any, Dict, Optional, Union


class CorruptedResultError(Exception):
    pass

COLLECTION_DIRECTORY_NAMES = {
    "preflight": "collection-preflight",
    "a": "collection-a",
    "b": "collection-b",
    "c": "collection-c",
    "e": "collection-e",
    "d": "collection-d",
    "f": "collection-f",
    "g": "collection-g",
    "h": "collection-h",
}
COLLECTION_RESULTS_FILENAMES = {
    "preflight": "preflight-results.json",
    "a": "collection-a-results.json",
    "b": "collection-b-results.json",
    "c": "collection-c-results.json",
    "e": "collection-e-results.json",
    "d": "collection-d-results.json",
    "f": "collection-f-results.json",
    "g": "collection-g-results.json",
    "h": "collection-h-results.json",
}
COLLECTION_ALTERNATE_RESULTS_FILENAMES = {
    "preflight": "collection-preflight-results.json",
}
REPORT_COLLECTIONS = ["preflight", "a", "b", "c", "e", "d", "f", "g", "h"]
REPO_LIVERUN_BASE = Path(__file__).resolve().parents[3] / "temp-work"
DEFAULT_RESULTS_ROOT = REPO_LIVERUN_BASE / "runner" / "direct-run"

REPO_ROOT = Path(__file__).resolve().parents[3]
ARTIFACTS_BASE = REPO_ROOT / "artifacts"
LEGACY_BASES = [REPO_ROOT / "liverun", REPO_ROOT / "results"]


def default_run_root() -> Path:
    """Resolve the active run root from environment or repository defaults."""
    env_root = os.environ.get("CLD6001_RUN_ROOT")
    run_id = os.environ.get("CLD6001_RUN_ID")
    if env_root:
        return Path(env_root)

    if run_id:
        return REPO_LIVERUN_BASE / run_id

    return REPO_LIVERUN_BASE


def resolve_results_root(results_root: Optional[Union[str, Path]] = None) -> Path:
    """Resolve the best available results root."""
    if results_root is not None:
        return Path(results_root)

    run_root = default_run_root()
    legacy_runner = run_root / "runner" / "direct-run"
    if legacy_runner.exists():
        return legacy_runner

    evidence_root = run_root / "evidence"
    if evidence_root.exists():
        return evidence_root

    return legacy_runner


def get_collection_results_path(results_root: Optional[Union[str, Path]], collection: str) -> Path:
    """Return the JSON results path for a supported collection."""
    collection_key = str(collection)
    try:
        collection_directory = COLLECTION_DIRECTORY_NAMES[collection_key]
    except KeyError as error:
        raise ValueError(f"Unsupported collection: {collection}") from error

    results_path = (
        resolve_results_root(results_root)
        / collection_directory
        / COLLECTION_RESULTS_FILENAMES[collection_key]
    )
    alternate_filename = COLLECTION_ALTERNATE_RESULTS_FILENAMES.get(collection_key)
    if alternate_filename is None or results_path.exists():
        return results_path

    alternate_path = results_path.with_name(alternate_filename)
    if alternate_path.exists():
        return alternate_path

    return results_path


get_phase_results_path = get_collection_results_path


def load_collection_results(collection: str, results_root: Optional[Union[str, Path]] = None) -> Dict[str, Any]:
    """Load results for a supported collection."""
    results_path = get_collection_results_path(results_root, collection)
    if not results_path.is_file():
        raise CorruptedResultError(
            f"Collection results file is missing or unreadable: {results_path}"
        )
    if results_path.stat().st_size == 0:
        raise CorruptedResultError(
            f"Collection results file is empty: {results_path}"
        )

    with results_path.open(encoding="utf-8") as file:
        try:
            return json.load(file)
        except json.JSONDecodeError as error:
            raise CorruptedResultError(
                f"Collection results file is corrupted: {results_path}: {error}"
            ) from error


load_phase_results = load_collection_results
