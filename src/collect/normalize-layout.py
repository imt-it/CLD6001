#!/usr/bin/env python3
"""Normalize artifact layout for a given run."""
from __future__ import annotations

import json
import os
from pathlib import Path


def main() -> None:
    repo_root = Path(__file__).resolve().parents[2]
    run_id = os.environ.get("CLD6001_RUN_ID", "unknown-run")
    payload = {
        "run_id": run_id,
        "artifact_root": str(repo_root / "artifacts" / run_id),
        "temp_work_root": os.environ.get("CLD6001_LINUX_TEMP_ROOT", "/var/tmp/cld6001"),
        "legacy_candidates": [
            str(repo_root / "liverun" / run_id),
            str(repo_root / "results" / run_id),
        ],
    }
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
