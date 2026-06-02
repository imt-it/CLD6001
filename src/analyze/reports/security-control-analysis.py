#!/usr/bin/env python3
"""Analyze security control effectiveness reports."""

from __future__ import annotations

import argparse
import json
from datetime import datetime
from pathlib import Path
import sys

import collection_paths

ANALYZE_DIR = Path(__file__).resolve().parents[1]
if str(ANALYZE_DIR) not in sys.path:
    sys.path.insert(0, str(ANALYZE_DIR))

from repo_input_helpers import (  # noqa: E402
    load_repo_scoped_json_input,
    validate_repo_scoped_input_path,
)

COUNT_ERROR_MARKER = "ERROR"
validate_input_path = validate_repo_scoped_input_path


def load_security_data(filepath):
    """Load security control data from JSON."""
    return load_repo_scoped_json_input(filepath)


def analyze_security_effectiveness(security_data):
    """Summarize effectiveness scores and recommendations."""
    analysis = {
        "analysis_type": "control-effectiveness",
        "total_controls": len(security_data),
        "effectiveness_scores": {},
        "recommendations": [],
    }

    for control in security_data:
        name = control.get("name", "unknown")
        effectiveness = control.get("effectiveness", 0)
        analysis["effectiveness_scores"][name] = effectiveness

        if effectiveness > 0.9:
            recommendation = "Highly effective - recommend for implementation"
        elif effectiveness > 0.7:
            recommendation = "Moderately effective - consider for implementation"
        else:
            recommendation = "Less effective - additional evaluation needed"

        analysis["recommendations"].append(
            {"name": name, "recommendation": recommendation}
        )

    return analysis


def _parse_count(value):
    """Convert a numeric observed count or ERROR sentinel into a report-friendly value."""
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        stripped = value.strip()
        if stripped.upper() == COUNT_ERROR_MARKER:
            return None
        try:
            return int(stripped)
        except ValueError as error:
            raise ValueError(
                f"Unsupported count marker: {value!r}. Expected an integer or {COUNT_ERROR_MARKER}."
            ) from error
    raise ValueError(f"Unsupported count value: {value!r}")


def analyze_supply_chain_observations(observations):
    """Summarize TC20 per-image evidence observations using the numeric-count + ERROR contract."""
    image_rows = observations.get("images", [])
    analyzed_images = []
    images_with_errors = 0
    images_with_sbom_evidence = 0
    images_with_attestation_evidence = 0
    images_with_provenance_evidence = 0

    for row in image_rows:
        sbom = _parse_count(row.get("sbom", 0))
        attestation = _parse_count(row.get("attestation", 0))
        provenance = _parse_count(row.get("provenance", 0))

        error_fields = []
        for field_name, field_value in (
            ("sbom", sbom),
            ("attestation", attestation),
            ("provenance", provenance),
        ):
            if field_value is None:
                error_fields.append(field_name)

        if error_fields:
            images_with_errors += 1

        if sbom and sbom > 0:
            images_with_sbom_evidence += 1
        if attestation and attestation > 0:
            images_with_attestation_evidence += 1
        if provenance and provenance > 0:
            images_with_provenance_evidence += 1

        analyzed_images.append(
            {
                "family": row.get("family", "unknown"),
                "image": row.get("image", "unknown"),
                "sbom": row.get("sbom", "0"),
                "attestation": row.get("attestation", "0"),
                "provenance": row.get("provenance", "0"),
                "error_fields": error_fields,
                "total_observed_signals": None if error_fields else sbom + attestation + provenance,
            }
        )

    family_counts = {}
    for row in analyzed_images:
        family = row["family"]
        family_counts[family] = family_counts.get(family, 0) + 1

    return {
        "analysis_type": "supply-chain",
        "total_images": len(analyzed_images),
        "images_with_errors": images_with_errors,
        "images_with_sbom_evidence": images_with_sbom_evidence,
        "images_with_attestation_evidence": images_with_attestation_evidence,
        "images_with_provenance_evidence": images_with_provenance_evidence,
        "family_counts": family_counts,
        "images": analyzed_images,
    }


def build_report(input_payload):
    """Create a report document for the supported input shapes."""
    if isinstance(input_payload, list):
        analysis = analyze_security_effectiveness(input_payload)
        average_effectiveness = (
            sum(analysis["effectiveness_scores"].values()) / len(analysis["effectiveness_scores"])
            if analysis["effectiveness_scores"]
            else 0
        )
        return {
            "title": "Container Security Control Effectiveness Report",
            "date": datetime.now().isoformat(),
            "summary": {
                "total_controls": len(analysis["effectiveness_scores"]),
                "average_effectiveness": average_effectiveness,
            },
            "analysis": analysis,
        }

    if isinstance(input_payload, dict) and input_payload.get("analysis_type") == "supply-chain":
        analysis = analyze_supply_chain_observations(input_payload)
        return {
            "title": "Container Supply-Chain Evidence Report",
            "date": datetime.now().isoformat(),
            "summary": {
                "total_images": analysis["total_images"],
                "images_with_errors": analysis["images_with_errors"],
                "images_with_sbom_evidence": analysis["images_with_sbom_evidence"],
                "images_with_attestation_evidence": analysis["images_with_attestation_evidence"],
                "images_with_provenance_evidence": analysis["images_with_provenance_evidence"],
                "family_counts": analysis["family_counts"],
            },
            "analysis": analysis,
        }

    raise ValueError("Unsupported security analysis input format")


def generate_report(report, filename="security-effectiveness-report.json"):
    """Write the analysis report to JSON."""
    average_effectiveness = (
        report["summary"].get("average_effectiveness")
        if isinstance(report.get("summary"), dict)
        else None
    )

    if average_effectiveness is not None:
        report["summary"]["average_effectiveness"] = average_effectiveness

    output_path = Path(filename)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as file:
        json.dump(report, file, indent=2)

    print(f"Report saved to {filename}")


def build_parser():
    """Build the CLI parser."""
    parser = argparse.ArgumentParser(description="Analyze security control effectiveness.")
    parser.add_argument("input", help="Path to security control JSON input")
    parser.add_argument("--output", default=None, help="Output report path")
    return parser


def main(argv=None):
    """CLI entry point."""
    args = build_parser().parse_args(argv)
    output_path = args.output if args.output is not None else str(collection_paths.default_run_root() / "reports" / "security-effectiveness-report.json")
    generate_report(build_report(load_security_data(args.input)), output_path)


if __name__ == "__main__":
    main()
