#!/usr/bin/env python3

import argparse
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path


TEST_NAME_MAP = {
    "tc01": "Privileged Mode Attack",
    "tc02": "Namespace Manipulation",
    "tc03": "Cgroup Escape",
    "tc04": "Kernel Exploit Inheritance",
    "tc05": "Image Vulnerability Exploitation",
    "tc06": "Hardened Image Validation",
    "tc07": "Custom Hardened Image Traceability",
    "tc08": "Capability Abuse",
    "tc09": "Capability Enforcement",
    "tc10": "SELinux Enforcement",
    "tc11": "SELinux Policy Violations",
    "tc12": "SELinux Bypass",
    "tc13": "Syscall Exposure",
    "tc14": "Seccomp Bypass",
    "tc15": "User-Namespace Protection",
    "tc16": "Exposed Daemon Socket",
    "tc17": "Privileged Container Validation",
    "tc18": "Post-Hardening Host Access Probe",
    "tc19": "Network-Isolation Validation",
    "tc20": "Supply-Chain Validation",
    "tc22": "Page Cache Poisoning",
    "tc23": "Cross-Container Attack",
    "tc24": "runc Container Escape",
}

DOCKER_CONTROLS = [
    {
        "control_id": "C1",
        "name": "Privileged Mode Restriction",
        "tests": ["tc01", "tc18"],
    },
    {
        "control_id": "C2",
        "name": "SELinux Policy Enforcement",
        "tests": ["tc10", "tc11", "tc12"],
    },
    {
        "control_id": "C3",
        "name": "Shared Seccomp Deny-List Profile",
        "tests": ["tc13", "tc14"],
    },
    {
        "control_id": "C4",
        "name": "Capability Dropping",
        "tests": ["tc08", "tc09"],
    },
    {
        "control_id": "C5",
        "name": "Read-Only Filesystem",
        "tests": ["tc03", "tc15", "tc18", "tc22", "tc23", "tc24"],
    },
    {
        "control_id": "C6",
        "name": "Network Namespace Isolation",
        "tests": ["tc02", "tc19"],
    },
]

PODMAN_CONTROLS = [
    {
        "control_id": "PC1",
        "name": "Rootless Container Isolation",
        "tests": ["tc01", "tc15", "tc18"],
    },
    {
        "control_id": "PC2",
        "name": "Shared Seccomp Deny-List Profile",
        "tests": ["tc13", "tc14"],
    },
    {
        "control_id": "PC3",
        "name": "Capability Dropping",
        "tests": ["tc08", "tc09"],
    },
    {
        "control_id": "PC4",
        "name": "Read-Only Filesystem",
        "tests": ["tc03", "tc15", "tc18", "tc22", "tc23", "tc24"],
    },
    {
        "control_id": "PC5",
        "name": "Network Namespace Isolation",
        "tests": ["tc02", "tc19"],
    },
]


def parse_args():
    parser = argparse.ArgumentParser(description="Generate TC21 current-run synthesis artifacts")
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--matrix-path", required=True)
    parser.add_argument("--recommendation-path", required=True)
    return parser.parse_args()


def env_lines(name: str):
    raw = os.environ.get(name, "")
    return [line for line in raw.splitlines() if line.strip()]


def env_words(name: str):
    raw = os.environ.get(name, "")
    return [word for word in raw.split() if word]


def env_tokens(name: str):
    raw = os.environ.get(name, "")
    return [token for token in re.split(r"[\s,]+", raw.strip()) if token]


def profile_axis():
    return (
        os.environ.get("RUNNER_PROFILE_SLUG", "").strip()
        or os.environ.get("RUNNER_ENVIRONMENT_STATE", "").strip()
        or "unscoped"
    )


def environment_state():
    return os.environ.get("RUNNER_ENVIRONMENT_STATE", "").strip()


def canonical_test_id(test_id: str):
    match = re.match(r"^(tc\d+)", (test_id or "").strip(), re.IGNORECASE)
    if match is None:
        return (test_id or "").strip().lower()
    return match.group(1).lower()


def parse_record(line: str):
    parts = line.split("|")
    if len(parts) != 5:
        raise ValueError(f"Malformed record: expected 5 pipe-delimited fields, got {len(parts)}")
    test_id, result, result_dir, log_path, context_path = parts
    return {
        "test_id": test_id,
        "canonical_test_id": canonical_test_id(test_id),
        "result": result,
        "result_dir": result_dir,
        "log_path": log_path,
        "context_path": context_path,
    }


def normalize_result(result: str):
    mapping = {
        "pass": "pass",
        "success": "pass",
        "block": "block",
        "blocked": "block",
        "fail": "fail",
        "failure": "fail",
        "unknown": "unknown",
        "": "unknown",
    }
    normalized = (result or "").strip().lower()
    if normalized not in mapping:
        raise ValueError(f"Invalid result token: {result}")
    return mapping[normalized]


def display_test_id(test_id: str):
    match = re.fullmatch(r"tc(\d+)(.*)", test_id or "", re.IGNORECASE)
    if match is not None:
        return f"TC{match.group(1)}{match.group(2)}"
    return test_id


def load_context_reason(context_path: str) -> dict[str, str]:
    if not context_path:
        return {"reason_code": "", "reason_text": "", "reason_source": ""}

    path = Path(context_path)
    if not path.is_file():
        return {"reason_code": "", "reason_text": "", "reason_source": ""}

    payload = json.loads(path.read_text(encoding="utf-8"))
    return {
        "reason_code": str(payload.get("reason_code") or "").strip(),
        "reason_text": str(payload.get("reason_text") or "").strip(),
        "reason_source": str(payload.get("reason_source") or "").strip(),
    }


def load_records():
    collections = env_tokens("RUNNER_DEPENDENCY_COLLECTIONS")
    if not collections:
        raise RuntimeError("RUNNER_DEPENDENCY_COLLECTIONS is required")

    collection_records = {}
    collection_expected_tests = {}

    for c in collections:
        env_suffix = c.upper().replace("-", "_")
        manifest_env = f"RUNNER_COLLECTION_{env_suffix}_MANIFEST"
        expected_env = f"RUNNER_COLLECTION_{env_suffix}_EXPECTED_TESTS"

        key_name = f"collection_{c}"
        collection_records[key_name] = [parse_record(line) for line in env_lines(manifest_env)]
        collection_expected_tests[key_name] = env_words(expected_env)

    predecessor_records = {}
    for test_id in ["tc18", "tc19", "tc20"]:
        env_record_key = f"RUNNER_{test_id.upper()}_RECORD"
        if env_record_key in os.environ and os.environ[env_record_key].strip():
            predecessor_records[test_id] = parse_record(os.environ[env_record_key])
        else:
            found = None
            for c_rec_list in collection_records.values():
                for rec in c_rec_list:
                    if rec["canonical_test_id"] == test_id:
                        found = rec
                        break
                if found:
                    break
            if found:
                predecessor_records[test_id] = found
            else:
                predecessor_records[test_id] = {
                    "test_id": test_id,
                    "canonical_test_id": test_id,
                    "result": "unknown",
                    "result_dir": "",
                    "log_path": "",
                    "context_path": "",
                }

    return collection_records, collection_expected_tests, predecessor_records


def build_collection_summary(expected_tests, records):
    record_map = {record["canonical_test_id"]: normalize_result(record["result"]) for record in records}
    observed = [test_id for test_id in expected_tests if canonical_test_id(test_id) in record_map]
    pass_count = sum(1 for test_id in observed if record_map[canonical_test_id(test_id)] == "pass")
    block_count = sum(1 for test_id in observed if record_map[canonical_test_id(test_id)] == "block")
    fail_count = sum(1 for test_id in observed if record_map[canonical_test_id(test_id)] == "fail")
    missing = [test_id for test_id in expected_tests if canonical_test_id(test_id) not in record_map]
    return {
        "expected_tests": expected_tests,
        "observed_tests": observed,
        "expected_count": len(expected_tests),
        "observed_count": len(observed),
        "pass_count": pass_count,
        "block_count": block_count,
        "fail_count": fail_count,
        "missing_tests": missing,
    }


def control_status_from_records(records):
    if not records:
        return "insufficient-evidence"

    normalized = [normalize_result(record["result"]) for record in records]
    pass_count = normalized.count("pass")
    block_count = normalized.count("block")
    fail_count = normalized.count("fail")

    if fail_count:
        return "contradicted"
    if pass_count and block_count:
        return "supported-with-blocked-preconditions"
    if pass_count:
        return "supported"
    if block_count:
        return "blocked-by-preconditions"
    return "insufficient-evidence"


def control_impact_summary(status: str):
    summaries = {
        "supported": "Current-run evidence supports retaining this control in the active runtime baseline.",
        "supported-with-blocked-preconditions": "Current-run evidence supports the control, but some mapped validations completed with blocked preconditions that should be revisited before broadening the conclusion.",
        "blocked-by-preconditions": "Only blocked-precondition evidence is available for this control in the current run.",
        "contradicted": "Current-run evidence contradicts this control or shows at least one mapped validation failure.",
        "insufficient-evidence": "The current run did not provide mapped evidence for this control.",
    }
    return summaries[status]


def build_controls(runtime, all_records):
    definitions = DOCKER_CONTROLS if runtime.startswith("docker") else PODMAN_CONTROLS
    records_by_test = {record["canonical_test_id"]: record for record in all_records}
    controls = []

    for definition in definitions:
        matched_records = [
            records_by_test[test_id]
            for test_id in definition["tests"]
            if test_id in records_by_test
        ]
        current_status = control_status_from_records(matched_records)
        normalized = [normalize_result(record["result"]) for record in matched_records]
        controls.append(
            {
                "control_id": definition["control_id"],
                "name": definition["name"],
                "mapped_tests": [display_test_id(test_id) for test_id in definition["tests"]],
                "current_run_status": current_status,
                "evidence_summary": {
                    "observed_tests": len(matched_records),
                    "pass_count": normalized.count("pass"),
                    "block_count": normalized.count("block"),
                    "fail_count": normalized.count("fail"),
                },
                "impact_summary": control_impact_summary(current_status),
                "evidence_refs": [
                    {
                        "test_id": display_test_id(record["test_id"]),
                        "result": normalize_result(record["result"]),
                        "log_path": record["log_path"],
                        "context_path": record["context_path"],
                    }
                    for record in matched_records
                ],
            }
        )

    return controls


def observed_status(result: str):
    normalized = normalize_result(result)
    if normalized == "pass":
        return "observed-as-expected"
    if normalized == "block":
        return "blocked-precondition-recorded"
    if normalized == "fail":
        return "unexpected-failure"
    return normalized or "unknown"


def predecessor_artifacts(test_id: str, runtime: str):
    if test_id == "tc18":
        artifact_file = os.environ.get("RUNNER_TC18_ARTIFACT_FILE", "")
        return [artifact_file] if artifact_file else []

    if test_id == "tc19":
        artifact_dir = os.environ.get("RUNNER_TC19_ARTIFACTS_DIR", "")
        if not artifact_dir:
            return []
        return [
            str(Path(artifact_dir) / "tc19-network-isolation.log"),
            str(Path(artifact_dir) / "test-results.txt"),
        ]

    if test_id == "tc20":
        artifact_dir = os.environ.get("RUNNER_TC20_ARTIFACTS_DIR", "")
        if not artifact_dir:
            return []
        if runtime.startswith("podman"):
            return [
                str(Path(artifact_dir) / "test-output.log"),
                str(Path(artifact_dir) / "tc20-applicability.json"),
                str(Path(artifact_dir) / "podman-skip-transcript.log"),
            ]
        return [
            str(Path(artifact_dir) / "tc20-supply-chain.log"),
            str(Path(artifact_dir) / "supply-chain-observations.tsv"),
            str(Path(artifact_dir) / "supply-chain-analysis-input.json"),
        ]

    return []


def predecessor_artifact_path(test_id: str):
    canonical_id = canonical_test_id(test_id)
    if canonical_id == "tc18":
        return os.environ.get("RUNNER_TC18_ARTIFACT_FILE", "")
    if canonical_id == "tc19":
        return os.environ.get("RUNNER_TC19_ARTIFACTS_DIR", "")
    if canonical_id == "tc20":
        return os.environ.get("RUNNER_TC20_ARTIFACTS_DIR", "")
    return ""


def build_attack_paths(all_records, runtime):
    attack_paths = []
    for record in sorted(all_records, key=lambda item: item["canonical_test_id"]):
        context_reason = load_context_reason(record["context_path"])
        canonical_id = canonical_test_id(record["test_id"])
        attack_paths.append(
            {
                "test_id": display_test_id(record["test_id"]),
                "canonical_test_id": canonical_id,
                "name": TEST_NAME_MAP.get(canonical_id, canonical_id.upper()),
                "current_run_result": normalize_result(record["result"]),
                "observed_status": observed_status(record["result"]),
                "reason_code": context_reason["reason_code"],
                "reason_text": context_reason["reason_text"],
                "reason_source": context_reason["reason_source"],
                "result_dir": record["result_dir"],
                "log_path": record["log_path"],
                "context_path": record["context_path"],
                "artifact_paths": predecessor_artifacts(canonical_id, runtime),
            }
        )
    return attack_paths


def build_predecessor_evidence(predecessor_records, runtime):
    evidence = {}
    for test_id, record in predecessor_records.items():
        context_reason = load_context_reason(record["context_path"])
        canonical_id = canonical_test_id(record["test_id"])
        artifact_path = predecessor_artifact_path(canonical_id)
        artifact_paths = predecessor_artifacts(canonical_id, runtime)
        evidence[display_test_id(canonical_id)] = {
            "test_id": display_test_id(record["test_id"]),
            "canonical_test_id": canonical_id,
            "result": normalize_result(record["result"]),
            "reason_code": context_reason["reason_code"],
            "reason_text": context_reason["reason_text"],
            "reason_source": context_reason["reason_source"],
            "result_dir": record["result_dir"],
            "log_path": record["log_path"],
            "context_path": record["context_path"],
            "artifact_path": artifact_path,
            "current_run_result": normalize_result(record["result"]),
            "artifact_paths": artifact_paths,
        }
    return evidence


def collection_chain_status(collection_summary):
    for summary in collection_summary.values():
        if summary["expected_count"] == 0:
            return "partial"
        if summary["observed_count"] != summary["expected_count"]:
            return "partial"
        if summary["missing_tests"]:
            return "partial"
    return "complete"


def predecessor_chain_status(predecessor_records, runtime):
    for test_id, record in predecessor_records.items():
        if normalize_result(record["result"]) == "unknown":
            return "partial"
        if not record["result_dir"] or not Path(record["result_dir"]).is_dir():
            return "partial"
        if not record["log_path"] or not Path(record["log_path"]).is_file():
            return "partial"
        if not record["context_path"] or not Path(record["context_path"]).is_file():
            return "partial"
        artifact_paths = predecessor_artifacts(test_id, runtime)
        if not artifact_paths:
            return "partial"
        if any(not Path(path).exists() for path in artifact_paths):
            return "partial"
    return "complete"


def build_matrix(runtime, profile, collection_records, collection_expected_tests, predecessor_records):
    run_session_id = os.environ.get("RUNNER_RUN_SESSION_ID", "")
    environment = environment_state()
    collection_summary = {
        col: build_collection_summary(collection_expected_tests[col], collection_records[col])
        for col in collection_records.keys()
    }
    collection_status = collection_chain_status(collection_summary)
    predecessor_status = predecessor_chain_status(predecessor_records, runtime)
    all_records = []
    for records in collection_records.values():
        all_records.extend(records)

    for test_id in ["tc18", "tc19", "tc20"]:
        rec = predecessor_records[test_id]
        if not any(item["canonical_test_id"] == test_id for item in all_records):
            all_records.append(rec)

    return {
        "metadata": {
            "title": f"Current-Run Control-Impact Matrix ({runtime} / {profile})",
            "version": "2.0",
            "date": datetime.now(timezone.utc).isoformat(),
            "runtime": runtime,
            "profile": profile,
            "environment_state": environment,
            "run_session_id": run_session_id,
            "schema": "current-run-runtime-profile",
            "status": "complete" if collection_status == "complete" and predecessor_status == "complete" else "partial",
            "predecessor_chain_status": predecessor_status,
            "collection_summary": collection_summary,
        },
        "controls": build_controls(runtime, all_records),
        "attack_paths": build_attack_paths(all_records, runtime),
        "predecessor_evidence": build_predecessor_evidence(predecessor_records, runtime),
    }


def write_recommendation(runtime, profile, matrix, recommendation_path):
    supported = [control for control in matrix["controls"] if control["current_run_status"] == "supported"]
    mixed = [
        control
        for control in matrix["controls"]
        if control["current_run_status"] == "supported-with-blocked-preconditions"
    ]
    blocked_only = [
        control
        for control in matrix["controls"]
        if control["current_run_status"] == "blocked-by-preconditions"
    ]
    contradicted = [
        control
        for control in matrix["controls"]
        if control["current_run_status"] == "contradicted"
    ]
    insufficient = [
        control
        for control in matrix["controls"]
        if control["current_run_status"] == "insufficient-evidence"
    ]

    predecessor = matrix["predecessor_evidence"]
    lines = [
        f"# Current-Run Control-Impact Recommendation ({runtime} / {profile})",
        "",
        "## Evidence Chain",
        "",
        f"- **Runtime:** {runtime}",
        f"- **Profile:** {profile}",
        f"- **Environment state:** {matrix['metadata']['environment_state'] or 'unspecified'}",
        f"- **Run session:** {matrix['metadata']['run_session_id'] or 'unspecified'}",
        f"- **Schema:** {matrix['metadata']['schema']}",
        f"- **Predecessor chain:** {matrix['metadata']['predecessor_chain_status']}",
        "",
        "## Supported Controls",
        "",
    ]

    if supported:
        for index, control in enumerate(supported, start=1):
            refs = ", ".join(ref["test_id"] for ref in control["evidence_refs"])
            lines.append(f"{index}. **{control['name']}** - supported by current-run evidence ({refs})")
    else:
        lines.append("1. No controls reached an unqualified supported status in this current run.")

    lines.extend(["", "## Controls With Blocked Preconditions", ""])
    if mixed or blocked_only:
        for index, control in enumerate([*mixed, *blocked_only], start=1):
            lines.append(
                f"{index}. **{control['name']}** - {control['current_run_status']} ({control['impact_summary']})"
            )
    else:
        lines.append("1. No blocked-precondition control findings were recorded in this current run.")

    lines.extend(["", "## Contradicted Controls", ""])
    if contradicted:
        for index, control in enumerate(contradicted, start=1):
            lines.append(
                f"{index}. **{control['name']}** - contradicted ({control['impact_summary']})"
            )
    else:
        lines.append("1. No contradicted controls were recorded in this current run.")

    lines.extend(["", "## Controls Without Direct Current-Run Evidence", ""])
    if insufficient:
        for index, control in enumerate(insufficient, start=1):
            lines.append(f"{index}. **{control['name']}** - insufficient-evidence")
    else:
        lines.append("1. Every tracked control received at least one mapped current-run evidence point.")

    lines.extend(
        [
            "",
            "## Predecessor Evidence Summary",
            "",
            f"- **TC18:** {predecessor['TC18']['current_run_result']} ({', '.join(predecessor['TC18']['artifact_paths'])})",
            f"- **TC19:** {predecessor['TC19']['current_run_result']} ({', '.join(predecessor['TC19']['artifact_paths'])})",
            f"- **TC20:** {predecessor['TC20']['current_run_result']} ({', '.join(predecessor['TC20']['artifact_paths'])})",
            "",
            "## Runtime Recommendation",
            "",
            "Retain controls with supported current-run evidence in the active runtime/profile baseline.",
            "Where blocked preconditions were recorded, resolve those paths before broadening the conclusion beyond the current run.",
            "Read this recommendation together with the predecessor artifact paths above for traceability.",
            "",
        ]
    )

    recommendation_path.write_text("\n".join(lines), encoding="utf-8")


def main():
    args = parse_args()
    runtime = args.runtime
    profile = profile_axis()
    matrix_path = Path(args.matrix_path)
    recommendation_path = Path(args.recommendation_path)

    collection_records, collection_expected_tests, predecessor_records = load_records()
    matrix = build_matrix(runtime, profile, collection_records, collection_expected_tests, predecessor_records)

    matrix_path.parent.mkdir(parents=True, exist_ok=True)
    matrix_path.write_text(json.dumps(matrix, indent=2), encoding="utf-8")
    write_recommendation(runtime, profile, matrix, recommendation_path)


if __name__ == "__main__":
    main()
