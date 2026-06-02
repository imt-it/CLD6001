#!/bin/bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$REPO_ROOT/src/analyze/synthesis-gate.sh"
source "$REPO_ROOT/src/shared/output-layout.sh"

run_id="${1:?run id required}"
input_root="${2:?input root required}"

artifact_run_root="$(cld6001_artifact_dir "$run_id")"
output_dir="${artifact_run_root}/export"

cld6001_require_completed_full_run "$artifact_run_root" "$run_id"
cld6001_run_report_export \
    "$artifact_run_root" \
    "$input_root" \
    "$output_dir/security-research-report.md"
