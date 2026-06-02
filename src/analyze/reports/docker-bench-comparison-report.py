#!/usr/bin/env python3
"""Generate an HTML comparison report from pre/post Docker Bench JSON results."""

from __future__ import annotations

import argparse
from html import escape
from pathlib import Path
import sys

ANALYZE_DIR = Path(__file__).resolve().parents[1]
if str(ANALYZE_DIR) not in sys.path:
    sys.path.insert(0, str(ANALYZE_DIR))

from docker_bench_helpers import (  # noqa: E402
    load_docker_bench_payload,
    resolve_docker_bench_artifact_path,
)


LEVEL_ORDER = [
    "CRITICAL",
    "HIGH",
    "MEDIUM",
    "LOW",
    "WARN",
    "INFO",
    "NOTE",
    "PASS",
]


def normalize_level(value: object) -> str:
    normalized = str(value or "").upper()
    if normalized == "WARNING":
        return "WARN"
    return normalized or "UNKNOWN"


def load_level_counts(report_path: str) -> dict[str, int]:
    path = resolve_docker_bench_artifact_path(report_path)
    payload = load_docker_bench_payload(path)

    if isinstance(payload, dict):
        checks = payload.get("Checks", [])
    elif isinstance(payload, list):
        checks = payload
    else:
        raise ValueError(f"Unexpected Docker Bench JSON structure in {path}")

    if not isinstance(checks, list):
        raise ValueError(f"Unexpected Docker Bench checks structure in {path}")

    counts: dict[str, int] = {}
    for item in checks:
        if not isinstance(item, dict):
            continue
        level = normalize_level(item.get("Level", item.get("level", "")))
        counts[level] = counts.get(level, 0) + 1

    return counts


def ordered_levels(*count_maps: dict[str, int]) -> list[str]:
    discovered = {level for counts in count_maps for level in counts}
    ordered = [level for level in LEVEL_ORDER if level in discovered]
    ordered.extend(sorted(level for level in discovered if level not in LEVEL_ORDER))
    return ordered


def build_html(pre_path: str, post_path: str, pre_counts: dict[str, int], post_counts: dict[str, int]) -> str:
    rows = []
    for level in ordered_levels(pre_counts, post_counts):
        pre_value = pre_counts.get(level, 0)
        post_value = post_counts.get(level, 0)
        delta = post_value - pre_value
        rows.append(
            "<tr>"
            f"<td>{escape(level)}</td>"
            f"<td>{pre_value}</td>"
            f"<td>{post_value}</td>"
            f"<td>{delta:+d}</td>"
            "</tr>"
        )

    rows_html = "\n".join(rows) if rows else "<tr><td colspan=\"4\">No findings recorded.</td></tr>"
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Docker Bench Hardening Comparison</title>
  <style>
    body {{ font-family: Arial, sans-serif; margin: 2rem; }}
    table {{ border-collapse: collapse; width: 100%; max-width: 48rem; }}
    th, td {{ border: 1px solid #ccc; padding: 0.5rem 0.75rem; text-align: left; }}
    th {{ background: #f5f5f5; }}
  </style>
</head>
<body>
  <h1>Docker Bench Hardening Comparison</h1>
  <p>Pre-hardening source: <code>{escape(pre_path)}</code></p>
  <p>Post-hardening source: <code>{escape(post_path)}</code></p>
  <table>
    <thead>
      <tr>
        <th>Level</th>
        <th>Pre-hardening</th>
        <th>Post-hardening</th>
        <th>Delta</th>
      </tr>
    </thead>
    <tbody>
{rows_html}
    </tbody>
  </table>
</body>
</html>
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Generate an HTML comparison report from Docker Bench JSON results.")
    parser.add_argument("--pre", required=True, help="Pre-hardening Docker Bench JSON file")
    parser.add_argument("--post", required=True, help="Post-hardening Docker Bench JSON file")
    parser.add_argument("--output", required=True, help="HTML report output path")
    return parser


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    pre_counts = load_level_counts(args.pre)
    post_counts = load_level_counts(args.post)

    output_path = resolve_docker_bench_artifact_path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        build_html(args.pre, args.post, pre_counts, post_counts),
        encoding="utf-8",
    )

    print(f"Report saved to {output_path}")


if __name__ == "__main__":
    main()
