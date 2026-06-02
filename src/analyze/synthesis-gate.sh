#!/bin/bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

cld6001_require_completed_full_run() {
    local artifact_run_root="${1:?artifact run root required}"
    local expected_run_id="${2:-}"
    local metadata_path="${artifact_run_root%/}/run-info/run-metadata.json"
    local run_metadata=""
    local metadata_run_id=""
    local run_type=""

    if [ ! -s "$metadata_path" ]; then
        printf 'Completed full run artifacts required: missing %s\n' "$metadata_path" >&2
        return 1
    fi

    run_metadata="$(python3 - "$metadata_path" <<'PY'
import json
import sys

metadata_path = sys.argv[1]
with open(metadata_path, encoding="utf-8") as handle:
    payload = json.load(handle)

print(payload.get("run_id", ""))
print(payload.get("run_type", ""))
PY
)" || {
        printf 'Completed full run artifacts required: unreadable %s\n' "$metadata_path" >&2
        return 1
    }

    metadata_run_id="$(printf '%s\n' "$run_metadata" | sed -n '1p')"
    run_type="$(printf '%s\n' "$run_metadata" | sed -n '2p')"

    if [ -n "$expected_run_id" ] && [ "$metadata_run_id" != "$expected_run_id" ]; then
        printf 'Completed full run artifacts required: metadata run id mismatch for %s\n' "$artifact_run_root" >&2
        return 1
    fi

    if [ "$run_type" != "full" ]; then
        printf 'Completed full run artifacts required: %s is %s\n' "$artifact_run_root" "${run_type:-unknown}" >&2
        return 1
    fi

    if [ ! -d "${artifact_run_root%/}/evidence" ] || ! find "${artifact_run_root%/}/evidence" -mindepth 1 -print -quit | grep -q .; then
        printf 'Completed full run artifacts required: missing evidence under %s\n' "$artifact_run_root" >&2
        return 1
    fi
}

cld6001_run_report_export() {
    local artifact_run_root="${1:?artifact run root required}"
    local input_root="${2:?input root required}"
    local output_path="${3:?output path required}"
    shift 3

    mkdir -p -- "$(dirname -- "$output_path")"
    CLD6001_RUN_ROOT="$artifact_run_root" python3 "$REPO_ROOT/src/analyze/reports/report-generator.py" \
        --input "$input_root" \
        --output "$output_path" \
        "$@"

    if [ ! -s "$output_path" ]; then
        printf 'report-generator did not produce non-empty output: %s\n' "$output_path" >&2
        return 1
    fi
}
