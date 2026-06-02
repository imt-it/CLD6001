#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/shared/adapter-cleanup-helpers.sh"
source "$REPO_ROOT/src/shared/tc10-selinux-helpers.sh"

HOST_HELPER_DIR=""
trap cld6001_cleanup_host_helper_bundle EXIT

create_host_helper_bundle() {
    HOST_HELPER_DIR="$(create_host_probe_dir "tc10-docker-rootless-helper")" || cld6001_block "precondition_failed" "Failed to create controlled host helper bundle for TC10"
    mkdir -p "$HOST_HELPER_DIR/protected" || cld6001_block "precondition_failed" "Failed to prepare controlled host helper bundle for TC10"
    printf 'simulated-shadow\n' > "$HOST_HELPER_DIR/protected/mock-shadow" || cld6001_block "precondition_failed" "Failed to populate controlled host helper bundle for TC10"
    chmod 0644 "$HOST_HELPER_DIR/protected/mock-shadow" 2>/dev/null || true
}

run_case() {
    local description="$1"
    shift

    local output=""
    local status=0

    echo "--- ${description} ---"
    set +e
    output="$(docker run --rm -i "$@" \
        -v "$HOST_HELPER_DIR:/host-helper:ro" \
        alpine sh -c '
echo "SELinux context: $(id -Z 2>/dev/null || echo unavailable)"
echo "Attempting controlled helper access"
if cat /host-helper/protected/mock-shadow >/dev/null 2>&1; then
    echo "helper protected file: READABLE"
else
    echo "helper protected file: BLOCK"
fi
' 2>&1)"
    status=$?
    set -e

    printf '%s\n\n' "$output"
    RUN_CASE_OUTPUT="$output"
    RUN_CASE_STATUS="$status"
}

validate_enforcement() {
    local labeled_output="$1"
    local disabled_output="$2"
    local labeled_blocked=0
    local labeled_readable=0
    local disabled_blocked=0
    local disabled_readable=0
    local labeled_context_unavailable=0
    local disabled_context_unavailable=0

    labeled_blocked="$(printf '%s\n' "$labeled_output" | grep -c 'BLOCK' || true)"
    labeled_readable="$(printf '%s\n' "$labeled_output" | grep -c 'READABLE' || true)"
    disabled_blocked="$(printf '%s\n' "$disabled_output" | grep -c 'BLOCK' || true)"
    disabled_readable="$(printf '%s\n' "$disabled_output" | grep -c 'READABLE' || true)"
    labeled_context_unavailable="$(printf '%s\n' "$labeled_output" | grep -c 'SELinux context: unavailable' || true)"
    disabled_context_unavailable="$(printf '%s\n' "$disabled_output" | grep -c 'SELinux context: unavailable' || true)"

    echo "--- Enforcement Validation ---"
    echo "Labeled case - BLOCK actions: ${labeled_blocked}"
    echo "Labeled case - READABLE actions: ${labeled_readable}"
    echo "Disabled case - BLOCK actions: ${disabled_blocked}"
    echo "Disabled case - READABLE actions: ${disabled_readable}"

    if [ "$labeled_context_unavailable" -gt 0 ] || [ "$disabled_context_unavailable" -gt 0 ]; then
        echo "RESULT: BLOCK - rootless Docker helper probe did not expose comparable SELinux context for both label modes"
        echo "Expected: both probes must expose comparable SELinux context and label=disable must restore readability"
        cld6001_block "selinux_non_comparable_rootless" "Rootless Docker helper probe did not expose comparable SELinux context for TC10"
    fi

    if [ "$labeled_blocked" -gt 0 ] && [ "$disabled_readable" -gt 0 ]; then
        echo "RESULT: PASS - SELinux enforcement effective"
        return 0
    fi

    if [ "$labeled_readable" -gt 0 ] && [ "$disabled_readable" -gt 0 ]; then
        echo "RESULT: FAIL - SELinux enforcement not demonstrated"
        echo "Expected: labeled case blocks helper access and label=disable restores readability"
        return 1
    fi

    echo "RESULT: BLOCK - rootless Docker helper probe did not produce a methodology-equivalent SELinux label-toggle delta"
    echo "Expected: labeled case blocks helper access and label=disable restores readability"
    cld6001_block "selinux_non_comparable_rootless" "Rootless Docker helper probe did not produce a comparable SELinux label-toggle delta for TC10"
}

echo "--- TC10: SELinux Enforcement ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: docker-rootless"
echo ""

if ! command -v getenforce &>/dev/null; then
    cld6001_block "selinux_tooling_unavailable" "SELinux tooling not available for TC10"
fi

SELINUX_MODE="$(getenforce)"
echo "Host SELinux mode: ${SELINUX_MODE}"

if [ "${SELINUX_MODE}" != "Enforcing" ]; then
    cld6001_block "selinux_not_enforcing" "SELinux must be enforcing for TC10 (current: ${SELINUX_MODE})"
fi

create_host_helper_bundle

RUN_CASE_OUTPUT=""
RUN_CASE_STATUS=0
run_case "Default container labeling"
labeled_output="$RUN_CASE_OUTPUT"
labeled_status="$RUN_CASE_STATUS"

if [ "$labeled_status" -ne 0 ]; then
    echo "docker-rootless SELinux comparison: NON-COMPARABLE"
    echo "Rootless Docker could not complete the labeled SELinux helper probe for TC10"
    cld6001_block "selinux_non_comparable_rootless" "Rootless Docker labeled SELinux helper probe did not complete for TC10"
fi

run_case "SELinux labeling disabled" --security-opt label=disable
disabled_output="$RUN_CASE_OUTPUT"
disabled_status="$RUN_CASE_STATUS"

if [ "$disabled_status" -ne 0 ]; then
    echo "docker-rootless SELinux comparison: NON-COMPARABLE"
    echo "Rootless Docker cannot provide a methodology-equivalent label-toggle comparison for TC10 on this host"
    cld6001_block "selinux_non_comparable_rootless" "Rootless Docker SELinux comparison remains non-comparable under enforcing mode for TC10"
fi

if validate_enforcement "$labeled_output" "$disabled_output"; then
    echo "SELinux enforcement comparison completed - PASS"
    exit 0
fi

echo "SELinux enforcement comparison completed - FAIL"
exit 1
