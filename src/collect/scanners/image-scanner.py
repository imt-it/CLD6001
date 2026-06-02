#!/usr/bin/env python3
"""Scan container images with Trivy and summarize vulnerabilities."""

from __future__ import annotations

import json
import logging
import os
import subprocess
from datetime import datetime
from pathlib import Path


SCAN_TIMEOUT_SECONDS = 600
LOGGER = logging.getLogger(__name__)
STOCK_IMAGES = ["nginx", "alpine", "ubuntu", "node", "python"]
DHI_IMAGES = ["docker.io/dhi/nginx", "docker.io/dhi/alpine"]
DEFAULT_REPORT_FILENAME = "image-vulnerability-report.json"


def _summarize_vulnerabilities(payload):
    results = payload.get("Results", [])
    vulnerabilities = [
        vulnerability
        for result in results
        for vulnerability in result.get("Vulnerabilities") or []
    ]
    return {
        "total_vulnerabilities": len(vulnerabilities),
        "critical": sum(1 for vulnerability in vulnerabilities if vulnerability.get("Severity") == "CRITICAL"),
        "high": sum(1 for vulnerability in vulnerabilities if vulnerability.get("Severity") == "HIGH"),
        "medium": sum(1 for vulnerability in vulnerabilities if vulnerability.get("Severity") == "MEDIUM"),
        "low": sum(1 for vulnerability in vulnerabilities if vulnerability.get("Severity") == "LOW"),
    }


def scan_image(image, category="stock"):
    """Scan a container image with Trivy and return summarized counts."""
    try:
        result = subprocess.run(
            ["trivy", "image", image, "--format", "json"],
            capture_output=True,
            text=True,
            check=True,
            timeout=SCAN_TIMEOUT_SECONDS,
        )
    except FileNotFoundError as error:
        raise RuntimeError("trivy is not installed or not on PATH.") from error
    except subprocess.TimeoutExpired as error:
        LOGGER.error(
            "Trivy scan timed out for %s after %s seconds: %s",
            image,
            SCAN_TIMEOUT_SECONDS,
            error,
        )
        return {
            "image": image,
            "category": category,
            "scan_date": datetime.now().isoformat(),
            "total_vulnerabilities": 0,
            "critical": 0,
            "high": 0,
            "medium": 0,
            "low": 0,
            "status": "timeout",
            "error": f"Trivy scan timed out for {image} after {SCAN_TIMEOUT_SECONDS} seconds",
        }
    except subprocess.CalledProcessError as error:
        message = error.stderr.strip() or error.stdout.strip() or str(error)
        raise RuntimeError(f"Trivy scan failed for {image}: {message}") from error

    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError(f"Failed to parse Trivy JSON output for {image}: {error}") from error

    summary = _summarize_vulnerabilities(payload)
    return {
        "image": image,
        "category": category,
        "scan_date": datetime.now().isoformat(),
        **summary,
    }


def resolve_output_path(filename=None):
    run_root = os.environ.get("CLD6001_RUN_ROOT")
    if not run_root:
        raise ValueError("CLD6001_RUN_ROOT is required for image scanner report output")

    evidence_root = Path(run_root).resolve() / "evidence"
    requested_path = Path(filename) if filename is not None else Path(DEFAULT_REPORT_FILENAME)
    if not requested_path.is_absolute():
        requested_path = evidence_root / requested_path

    resolved_path = requested_path.resolve()
    if not resolved_path.is_relative_to(evidence_root):
        raise ValueError(f"Image scanner output must stay under the run evidence directory: {resolved_path}")

    return resolved_path


def generate_report(results, filename=None):
    """Write the image vulnerability report to JSON."""
    output_path = resolve_output_path(filename)
    report = {
        "title": "Container Image Vulnerability Analysis",
        "date": datetime.now().isoformat(),
        "summary": {
            "total_images": len(results),
            "stock_images": sum(1 for result in results if result.get("category") == "stock"),
            "dhi_images": sum(1 for result in results if result.get("category") == "dhi"),
            "total_vulnerabilities": sum(result.get("total_vulnerabilities", 0) for result in results),
            "critical_vulnerabilities": sum(result.get("critical", 0) for result in results),
            "high_vulnerabilities": sum(result.get("high", 0) for result in results),
        },
        "detailed_results": results,
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as file:
        json.dump(report, file, indent=2)

    print(f"Report saved to {output_path}")
    return output_path


def main():
    """Run vulnerability scans for the default image sets."""
    print("=== Container Image Vulnerability Scanning ===")
    print(f"Date: {datetime.now().isoformat()}")
    print()

    results = []
    print("Scanning stock images...")
    for image in STOCK_IMAGES:
        print(f"  Scanning {image}...")
        result = scan_image(image, "stock")
        results.append(result)
        print(f"    Critical: {result['critical']}, High: {result['high']}")

    print("\nScanning DHI images...")
    for image in DHI_IMAGES:
        print(f"  Scanning {image}...")
        result = scan_image(image, "dhi")
        results.append(result)
        print(f"    Critical: {result['critical']}, High: {result['high']}")

    generate_report(results)
    print("\nScanning complete.")


if __name__ == "__main__":
    main()
