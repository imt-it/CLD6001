#!/usr/bin/env python3
"""Wrapper for Docker Bench for Security output collection."""

from __future__ import annotations

import json
import logging
import subprocess
from datetime import datetime
from pathlib import Path
import sys

ANALYZE_DIR = Path(__file__).resolve().parents[2] / "analyze"
if str(ANALYZE_DIR) not in sys.path:
    sys.path.insert(0, str(ANALYZE_DIR))

from docker_bench_helpers import (  # noqa: E402
    docker_bench_output_base,
    load_docker_bench_payload,
    validate_repo_scoped_output_path,
)


validate_output_path = validate_repo_scoped_output_path
DOCKER_BENCH_TIMEOUT_SECONDS = 600
LOGGER = logging.getLogger(__name__)


def run_docker_bench(output_file="docker-bench-results.json"):
    """Run Docker Bench and return the parsed JSON output."""
    output_path = validate_output_path(output_file)
    log_path = docker_bench_output_base(output_path)
    try:
        subprocess.run(
            ["docker-bench-security", "-l", str(log_path)],
            capture_output=True,
            text=True,
            check=True,
            timeout=DOCKER_BENCH_TIMEOUT_SECONDS,
        )
    except FileNotFoundError as error:
        raise RuntimeError("docker-bench-security is not installed or not on PATH.") from error
    except subprocess.TimeoutExpired as error:
        LOGGER.error(
            "Docker Bench scan timed out after %s seconds: %s",
            DOCKER_BENCH_TIMEOUT_SECONDS,
            error,
        )
        raise RuntimeError(
            f"Docker Bench scan timed out after {DOCKER_BENCH_TIMEOUT_SECONDS} seconds"
        ) from error
    except subprocess.CalledProcessError as error:
        message = error.stderr.strip() or error.stdout.strip() or str(error)
        raise RuntimeError(f"Docker Bench execution failed: {message}") from error

    return load_docker_bench_payload(output_path)


def analyze_results(docker_bench_results):
    """Count findings by severity level."""
    analysis = {"critical": 0, "high": 0, "medium": 0, "low": 0}
    for check in docker_bench_results:
        level = str(check.get("level", "")).lower()
        if level in analysis:
            analysis[level] += 1
    return analysis


def main():
    """Run Docker Bench and print a minimal summary."""
    print("=== Docker Bench for Security Wrapper ===")
    print(f"Date: {datetime.now().isoformat()}")
    print()

    results = run_docker_bench()
    analysis = analyze_results(results)
    print(json.dumps(analysis, indent=2))
    print("Analysis complete.")


if __name__ == "__main__":
    main()
