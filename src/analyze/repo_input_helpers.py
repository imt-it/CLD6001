#!/usr/bin/env python3
"""Shared repository-scoped JSON input helpers for Python tooling."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]


def validate_repo_scoped_input_path(filepath: str | Path) -> Path:
    """Restrict analyzer inputs to files within the repository tree."""
    path = Path(filepath).resolve()
    if not path.is_relative_to(REPO_ROOT):
        raise ValueError(f"Input path escapes repository root: {path}")
    return path


def load_repo_scoped_json_input(filepath: str | Path) -> Any:
    """Load a JSON file only after enforcing repository scoping."""
    input_path = validate_repo_scoped_input_path(filepath)
    with input_path.open(encoding="utf-8") as file:
        return json.load(file)
