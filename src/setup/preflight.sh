#!/bin/bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$REPO_ROOT/src/shared/output-layout.sh"
source "$REPO_ROOT/src/shared/resource-paths.sh"
source "$REPO_ROOT/src/shared/disk-space-helpers.sh"
source "$REPO_ROOT/src/setup/temp-work-link.sh"

cld6001_preflight_temp_work_root() {
    cld6001_temp_work_dir ""
}

cld6001_preflight_resource_layout() {
    mkdir -p \
        "$REPO_ROOT/resources/images" \
        "$REPO_ROOT/resources/exploits" \
        "$REPO_ROOT/resources/policies/podman" \
        "$REPO_ROOT/resources/fixtures" \
        "$REPO_ROOT/resources/templates"
}

cld6001_preflight_output_layout() {
    mkdir -p \
        "$(cld6001_artifact_dir "")" \
        "$(cld6001_preflight_temp_work_root)"
}

cld6001_report_disk_headroom_failure() {
    printf 'ERROR: disk headroom preflight failed: %s\n' "$(cld6001_disk_space_summary)" >&2
}

cld6001_preflight_disk_headroom() {
    local explicit_results_root="${1:-}"
    local results_root=""
    local temp_work_root=""

    if [ -n "$explicit_results_root" ]; then
        results_root="$explicit_results_root"
    else
        results_root="$(cld6001_artifact_dir "")"
    fi
    temp_work_root="$(cld6001_preflight_temp_work_root)"

    cld6001_enforce_disk_headroom "$results_root" || {
        cld6001_report_disk_headroom_failure
        return 1
    }
    cld6001_enforce_disk_headroom "$temp_work_root" || {
        cld6001_report_disk_headroom_failure
        return 1
    }
}

cld6001_preflight_layout() {
    cld6001_preflight_resource_layout
    cld6001_preflight_output_layout
    cld6001_ensure_temp_work_link
}
