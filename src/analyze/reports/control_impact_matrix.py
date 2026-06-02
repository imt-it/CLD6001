from __future__ import annotations

import csv
import json
from collections import defaultdict
from datetime import datetime
from io import StringIO
from pathlib import Path

LEAF_SCHEMA = "current-run-runtime-profile"
FULL_SCHEMA = "control-impact-matrix-v1"
RUNTIMES = ("docker-rootful", "docker-rootless", "podman-rootless")
PROFILES = ("baseline-system", "cis-system")
EXCLUDED_TEST_CASES = {
    "tc07": "de-scoped methodology case",
}
SYNTHESIS_ONLY_TESTS = {"tc21"}
SUITES = (
    {"id": "a", "title": "Boundary foundation collection", "test_cases": ("tc01", "tc02", "tc03", "tc04")},
    {"id": "b", "title": "Image and supply chain collection", "test_cases": ("tc05", "tc06", "tc07")},
    {"id": "c", "title": "Capability and namespace restrictions collection", "test_cases": ("tc08", "tc09", "tc15")},
    {"id": "d", "title": "Mandatory access control collection", "test_cases": ("tc10", "tc11", "tc12")},
    {"id": "e", "title": "Syscall and seccomp collection", "test_cases": ("tc13", "tc14")},
    {"id": "f", "title": "Composite hardening interactions collection", "test_cases": ("tc16", "tc17")},
    {"id": "g", "title": "Page-cache and side-channel family", "test_cases": ("tc22", "tc23", "tc24")},
    {"id": "h", "title": "Post-hardening validation, supply-chain audit, and synthesis support collection", "test_cases": ("tc18", "tc19", "tc20", "tc21")},
)
TEST_TO_SUITE = {
    test_id: suite["id"]
    for suite in SUITES
    for test_id in suite["test_cases"]
}


def _parse_leaf_date(stamp: str) -> datetime:
    normalized = stamp.replace("Z", "+00:00")
    return datetime.fromisoformat(normalized)


def load_latest_leaf_matrices(results_root: Path) -> dict[tuple[str, str], dict]:
    latest = {}
    for path in sorted(results_root.rglob("control-impact-matrix-*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        metadata = payload.get("metadata", {})
        if metadata.get("schema") != LEAF_SCHEMA:
            continue
        runtime = metadata.get("runtime")
        environment_state = metadata.get("environment_state")
        if runtime not in RUNTIMES or environment_state not in PROFILES:
            continue
        stamp = metadata.get("date")
        if not stamp:
            continue
        key = (runtime, environment_state)
        wrapped = {
            "source_path": str(path),
            "payload": payload,
            "timestamp": _parse_leaf_date(str(stamp)),
        }
        current = latest.get(key)
        if current is None or wrapped["timestamp"] >= current["timestamp"]:
            latest[key] = wrapped
    return latest


def canonical_status(attack_path: dict) -> str:
    result = str(attack_path.get("current_run_result") or "").strip().lower()
    artifact_paths = attack_path.get("artifact_paths") or []
    if result == "pass":
        return "pass"
    if result == "fail":
        return "fail"
    if result == "block" and any(path.endswith("tc20-applicability.json") for path in artifact_paths):
        return "not_applicable"
    if result == "block":
        return "block"
    if result in {"skip", "error"}:
        return result
    raise ValueError(f"Unsupported attack-path result: {result}")


def _attack_index(leaf_payload: dict) -> dict[str, dict]:
    return {
        entry["canonical_test_id"]: entry
        for entry in leaf_payload.get("attack_paths", [])
        if entry.get("canonical_test_id")
    }


def _leaf_predecessor_chain(leaf_payload: dict) -> list[str]:
    chain = {
        entry.get("canonical_test_id")
        for entry in (leaf_payload.get("predecessor_evidence") or {}).values()
        if entry.get("canonical_test_id")
    }
    return sorted(item for item in chain if item)


def build_controls_rollup(leaves: dict[tuple[str, str], dict]) -> dict[str, dict[str, list[dict]]]:
    controls = defaultdict(dict)
    for (runtime, profile), leaf in leaves.items():
        controls[profile][runtime] = list(leaf["payload"].get("controls") or [])
    return {profile: dict(runtime_map) for profile, runtime_map in controls.items()}


def build_run_session_id(leaves: dict[tuple[str, str], dict]) -> str:
    session_ids = {
        leaf["payload"].get("metadata", {}).get("run_session_id", "")
        for leaf in leaves.values()
        if leaf["payload"].get("metadata", {}).get("run_session_id")
    }
    if len(session_ids) == 1:
        return next(iter(session_ids))
    return "mixed-run-session"


def _active_test_ids() -> list[str]:
    ordered = []
    for suite in SUITES:
        for test_id in suite["test_cases"]:
            if test_id in EXCLUDED_TEST_CASES or test_id in SYNTHESIS_ONLY_TESTS:
                continue
            ordered.append(test_id)
    return ordered


def _is_non_comparable(status: str) -> bool:
    return status in {"not_applicable", "skip", "error"}


def _classify_profile_diff(baseline_status: str | None, cis_status: str | None) -> str:
    if not baseline_status or not cis_status:
        return "incomplete"
    if _is_non_comparable(baseline_status) or _is_non_comparable(cis_status):
        return "non_comparable"
    if baseline_status == "block" and cis_status == "pass":
        return "cis_improved"
    if baseline_status == "block" and cis_status == "fail":
        return "cis_regressed"
    if baseline_status == "pass" and cis_status in {"fail", "block"}:
        return "cis_regressed"
    if baseline_status == "fail" and cis_status == "pass":
        return "cis_improved"
    if baseline_status == "fail" and cis_status == "block":
        return "cis_improved"
    if baseline_status == "fail" and cis_status == "fail":
        return "still_failing"
    if baseline_status == "block" and cis_status == "block":
        return "still_blocked"
    if baseline_status == cis_status:
        return "same"
    return "cis_regressed"


def _classify_runtime_diff(statuses: list[str], *, expected_count: int = len(RUNTIMES)) -> str:
    if len(statuses) != expected_count:
        return "incomplete"
    if any(_is_non_comparable(status) for status in statuses):
        return "non_comparable"
    if len(set(statuses)) == 1:
        return "same"
    return "runtime_sensitive"


def _diff_test_ids(axes: dict | None, scope: dict | None) -> list[str]:
    if not axes or not axes.get("test_cases"):
        return _active_test_ids()
    excluded_test_cases = {
        entry.get("test_id")
        for entry in (scope or {}).get("excluded_test_cases", [])
        if entry.get("test_id")
    }
    return [
        test_id
        for test_id in axes.get("test_cases", [])
        if test_id not in excluded_test_cases and test_id not in SYNTHESIS_ONLY_TESTS
    ]


def _scope_aware_cells(cells: list[dict], scope: dict | None) -> list[dict]:
    effective_cells = list(cells)
    seen = {
        (cell["test_id"], cell["runtime"], cell["profile"])
        for cell in effective_cells
    }
    for entry in (scope or {}).get("excluded_cells", []):
        key = (entry.get("test_id"), entry.get("runtime"), entry.get("profile"))
        if None in key or key in seen:
            continue
        effective_cells.append(
            {
                "test_id": key[0],
                "runtime": key[1],
                "profile": key[2],
                "status": "skip",
            }
        )
        seen.add(key)
    return effective_cells


def _ordered_axis_subset(values: list[str], preferred_order: tuple[str, ...] | list[str]) -> list[str]:
    seen = set(values)
    ordered = [value for value in preferred_order if value in seen]
    ordered.extend(value for value in values if value not in preferred_order and value not in ordered)
    return ordered


def _infer_diff_axes(cells: list[dict]) -> tuple[list[str], list[str], list[str]]:
    test_ids = [cell["test_id"] for cell in cells if cell.get("test_id")]
    runtimes = [cell["runtime"] for cell in cells if cell.get("runtime")]
    profiles = [cell["profile"] for cell in cells if cell.get("profile")]
    return (
        _ordered_axis_subset(test_ids, _active_test_ids()),
        _ordered_axis_subset(runtimes, RUNTIMES),
        _ordered_axis_subset(profiles, PROFILES),
    )


def build_diffs(cells: list[dict], axes: dict | None = None, scope: dict | None = None) -> dict[str, list[dict]]:
    effective_cells = _scope_aware_cells(cells, scope)
    if axes:
        runtimes = tuple((axes or {}).get("runtimes") or RUNTIMES)
        profiles = tuple((axes or {}).get("profiles") or PROFILES)
        test_ids = _diff_test_ids(axes, scope)
    else:
        test_ids, runtimes, profiles = _infer_diff_axes(effective_cells)
    by_test_runtime = defaultdict(dict)
    by_test_profile = defaultdict(dict)
    for cell in effective_cells:
        by_test_runtime[(cell["test_id"], cell["runtime"])][cell["profile"]] = cell
        by_test_profile[(cell["test_id"], cell["profile"])][cell["runtime"]] = cell

    profile_diff = []
    for test_id in test_ids:
        for runtime in runtimes:
            profile_map = by_test_runtime.get((test_id, runtime), {})
            baseline_cell = profile_map.get("baseline-system")
            cis_cell = profile_map.get("cis-system")
            baseline_status = (baseline_cell or {}).get("status")
            cis_status = (cis_cell or {}).get("status")
            profile_diff.append(
                {
                    "test_id": test_id,
                    "runtime": runtime,
                    "baseline_status": baseline_status,
                    "cis_status": cis_status,
                    "classification": _classify_profile_diff(baseline_status, cis_status),
                }
            )

    runtime_diff = []
    for test_id in test_ids:
        for profile in profiles:
            runtime_map = by_test_profile.get((test_id, profile), {})
            statuses = {runtime: runtime_map.get(runtime, {}).get("status") for runtime in runtimes}
            comparable_statuses = [status for status in statuses.values() if status]
            runtime_diff.append(
                {
                    "test_id": test_id,
                    "profile": profile,
                    "statuses": statuses,
                    "classification": _classify_runtime_diff(comparable_statuses, expected_count=len(runtimes)),
                }
            )

    return {
        "profile_diff": profile_diff,
        "runtime_diff": runtime_diff,
    }


def build_full_matrix(leaves: dict[tuple[str, str], dict]) -> dict:
    cells = []
    missing = []
    for runtime in RUNTIMES:
        for profile in PROFILES:
            leaf = leaves.get((runtime, profile))
            attack_index = _attack_index(leaf["payload"]) if leaf else {}
            metadata = (leaf or {}).get("payload", {}).get("metadata", {})
            predecessor_chain = _leaf_predecessor_chain((leaf or {}).get("payload", {}))
            for test_id in _active_test_ids():
                attack = attack_index.get(test_id)
                if attack is None:
                    missing.append({"test_id": test_id, "runtime": runtime, "profile": profile})
                    continue
                if str(attack.get("current_run_result") or "").strip().lower() == "unknown":
                    missing.append({"test_id": test_id, "runtime": runtime, "profile": profile})
                    continue
                status = canonical_status(attack)
                if status != "pass":
                    for field in ("reason_code", "reason_text", "reason_source"):
                        if not str(attack.get(field) or "").strip():
                            raise ValueError(f"Missing {field} for {runtime}/{profile}/{test_id}")
                cells.append(
                    {
                        "test_id": test_id,
                        "test_title": attack.get("name") or test_id.upper(),
                        "suite_id": TEST_TO_SUITE[test_id],
                        "runtime": runtime,
                        "profile": profile,
                        "status": status,
                        "reason_code": attack.get("reason_code", ""),
                        "reason_text": attack.get("reason_text", ""),
                        "reason_source": attack.get("reason_source", ""),
                        "evidence": {
                            "result_dir": attack.get("result_dir", ""),
                            "log_path": attack.get("log_path", ""),
                            "context_path": attack.get("context_path", ""),
                            "artifact_paths": attack.get("artifact_paths") or [],
                        },
                        "predecessor_chain": predecessor_chain,
                        "run_session_id": metadata.get("run_session_id", ""),
                        "captured_at": metadata.get("date", ""),
                    }
                )
    return {
        "schema": FULL_SCHEMA,
        "generated_at": datetime.utcnow().isoformat(timespec="seconds") + "Z",
        "run_session_id": build_run_session_id(leaves),
        "source_schema_versions": {"leaf_matrix": LEAF_SCHEMA},
        "axes": {
            "profiles": list(PROFILES),
            "runtimes": list(RUNTIMES),
            "suites": [
                {
                    "id": suite["id"],
                    "title": suite["title"],
                    "test_cases": list(suite["test_cases"]),
                }
                for suite in SUITES
            ],
            "test_cases": [test_id for suite in SUITES for test_id in suite["test_cases"]],
        },
        "scope": {
            "expected_cells": len(RUNTIMES) * len(PROFILES) * len(_active_test_ids()),
            "produced_cells": len(cells),
            "missing_cells": missing,
            "excluded_test_cases": [
                {"test_id": test_id, "reason": reason}
                for test_id, reason in EXCLUDED_TEST_CASES.items()
            ],
            "excluded_cells": [],
        },
        "cells": cells,
        "controls": build_controls_rollup(leaves),
        "diffs": {"profile_diff": [], "runtime_diff": []},
        "provenance": {
            "synthesized_by": "tc21",
            "leaf_artifacts": [leaf["source_path"] for leaf in leaves.values()],
        },
    }


def _cell_lookup(report: dict) -> dict[tuple[str, str, str], dict]:
    return {
        (cell["test_id"], cell["runtime"], cell["profile"]): cell
        for cell in report.get("cells", [])
    }


def render_markdown(report: dict) -> str:
    axes = report.get("axes", {})
    suites = axes.get("suites", [])
    runtimes = axes.get("runtimes", [])
    profiles = axes.get("profiles", [])
    excluded_test_cases = {
        entry["test_id"]: entry.get("reason", "")
        for entry in report.get("scope", {}).get("excluded_test_cases", [])
    }
    excluded_cells = {
        (entry["test_id"], entry["runtime"], entry["profile"]): entry.get("reason", "")
        for entry in report.get("scope", {}).get("excluded_cells", [])
    }
    missing = {
        (entry["test_id"], entry["runtime"], entry["profile"])
        for entry in report.get("scope", {}).get("missing_cells", [])
    }
    cells = _cell_lookup(report)
    test_titles = {}
    for cell in report.get("cells", []):
        test_titles.setdefault(cell["test_id"], cell.get("test_title") or cell["test_id"].upper())

    lines = [
        "# Full Control Impact Matrix",
        "",
        f"- Schema: {report.get('schema', '')}",
        f"- Run session: {report.get('run_session_id', '')}",
        f"- Generated at: {report.get('generated_at', '')}",
        "",
        "## Exclusions",
        "",
    ]
    if excluded_test_cases or excluded_cells:
        for test_id, reason in excluded_test_cases.items():
            lines.append(f"- {test_id}: {reason}")
        for test_id, runtime, profile in sorted(excluded_cells):
            lines.append(f"- {test_id} / {runtime} / {profile}: {excluded_cells[(test_id, runtime, profile)]}")
    else:
        lines.append("- None")

    lines.extend(["", "## Missing cells", ""])
    if missing:
        for test_id, runtime, profile in sorted(missing):
            lines.append(f"- {test_id} / {runtime} / {profile}")
    else:
        lines.append("- None")

    for suite in suites:
        lines.extend(["", f"## {suite['title']}", ""])
        header = ["Test ID", "Title"] + [f"{runtime} {profile}" for profile in profiles for runtime in runtimes]
        lines.append("| " + " | ".join(header) + " |")
        lines.append("| " + " | ".join(["---"] * len(header)) + " |")
        for test_id in suite.get("test_cases", []):
            row = [test_id, test_titles.get(test_id, test_id.upper())]
            for profile in profiles:
                for runtime in runtimes:
                    if test_id in excluded_test_cases:
                        row.append(f"excluded ({excluded_test_cases[test_id]})")
                        continue
                    excluded_reason = excluded_cells.get((test_id, runtime, profile))
                    if excluded_reason is not None:
                        row.append(f"excluded ({excluded_reason})")
                        continue
                    if test_id in SYNTHESIS_ONLY_TESTS:
                        row.append("metadata-only")
                        continue
                    cell = cells.get((test_id, runtime, profile))
                    if cell:
                        value = cell["status"]
                        if cell.get("reason_code"):
                            value = f"{value} ({cell['reason_code']})"
                        row.append(value)
                    elif (test_id, runtime, profile) in missing:
                        row.append("MISSING")
                    else:
                        row.append("-")
            lines.append("| " + " | ".join(row) + " |")

    return "\n".join(lines) + "\n"


def render_csv(report: dict) -> str:
    buffer = StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerow(
        [
            "test_id",
            "runtime",
            "profile",
            "status",
            "reason_code",
            "reason_text",
            "reason_source",
            "suite_id",
            "log_path",
            "context_path",
        ]
    )
    test_order = {test_id: index for index, test_id in enumerate(report.get("axes", {}).get("test_cases", []))}
    runtime_order = {runtime: index for index, runtime in enumerate(report.get("axes", {}).get("runtimes", []))}
    profile_order = {profile: index for index, profile in enumerate(report.get("axes", {}).get("profiles", []))}
    for cell in sorted(
        report.get("cells", []),
        key=lambda item: (
            test_order.get(item["test_id"], 999),
            runtime_order.get(item["runtime"], 999),
            profile_order.get(item["profile"], 999),
        ),
    ):
        writer.writerow(
            [
                cell.get("test_id", ""),
                cell.get("runtime", ""),
                cell.get("profile", ""),
                cell.get("status", ""),
                cell.get("reason_code", ""),
                cell.get("reason_text", ""),
                cell.get("reason_source", ""),
                cell.get("suite_id", ""),
                cell.get("evidence", {}).get("log_path", ""),
                cell.get("evidence", {}).get("context_path", ""),
            ]
        )
    return buffer.getvalue()


def write_report_bundle(report: dict, output_path: Path) -> None:
    report["diffs"] = build_diffs(
        report.get("cells", []),
        axes=report.get("axes"),
        scope=report.get("scope"),
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    output_path.with_suffix(".md").write_text(render_markdown(report), encoding="utf-8")
    output_path.with_suffix(".csv").write_text(render_csv(report), encoding="utf-8")
