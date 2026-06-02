#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/shared/adapter-cleanup-helpers.sh"

TEST_RESULTS_DIR="${TEST_RESULTS_DIR:-./test-results}"
mkdir -p "${TEST_RESULTS_DIR}"

HOST_HELPER_DIR=""
ORIGINAL_SELINUX_MODE=""

restore_original_selinux_mode() {
    local current_mode=""

    [ -n "${ORIGINAL_SELINUX_MODE:-}" ] || return 0
    [ "$(id -u)" -eq 0 ] || return 0

    current_mode="$(getenforce 2>/dev/null || true)"
    [ -n "$current_mode" ] || return 0
    [ "$current_mode" != "Disabled" ] || return 0
    [ "$current_mode" != "$ORIGINAL_SELINUX_MODE" ] || return 0

    case "$ORIGINAL_SELINUX_MODE" in
        Permissive) setenforce 0 >/dev/null 2>&1 || true ;;
        Enforcing) setenforce 1 >/dev/null 2>&1 || true ;;
    esac
}

cleanup_tc11() {
    restore_original_selinux_mode
    cld6001_cleanup_host_helper_bundle
}

trap cleanup_tc11 EXIT

create_host_helper_bundle() {
    HOST_HELPER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tc11-podman-helper.XXXXXX")" || cld6001_block "precondition_failed" "Failed to create controlled host helper bundle for TC11"

    mkdir -p "$HOST_HELPER_DIR/protected" "$HOST_HELPER_DIR/writable"
    printf 'simulated-shadow\n' > "$HOST_HELPER_DIR/protected/mock-shadow"
    chmod 000 "$HOST_HELPER_DIR/protected/mock-shadow"
    : > "$HOST_HELPER_DIR/writable/violation-attempt"
}

require_selinux_mode_change_privilege() {
    if ! command -v getenforce >/dev/null 2>&1; then
        cld6001_block "selinux_tooling_unavailable" "SELinux tooling (getenforce) is not available on the host"
    fi

    if ! command -v setenforce >/dev/null 2>&1; then
        cld6001_block "selinux_tooling_unavailable" "SELinux tooling (setenforce) is not available on the host"
    fi

    if ! command -v getsebool >/dev/null 2>&1; then
        cld6001_block "selinux_tooling_unavailable" "SELinux tooling (getsebool) is not available on the host"
    fi

    if [[ "$(id -u)" -ne 0 ]]; then # [[:
        cld6001_block "privilege_required" "TC11 requires root privileges to toggle SELinux mode for validation"
        exit "${BLOCK_EXIT_CODE:-3}"
    fi

    ORIGINAL_SELINUX_MODE="$(getenforce)"
    if [ "$ORIGINAL_SELINUX_MODE" = "Disabled" ]; then
        cld6001_block "selinux_disabled" "SELinux is disabled on the host"
    fi

    echo "Host SELinux mode: ${ORIGINAL_SELINUX_MODE}"
    getsebool container_use_cephfs 2>/dev/null || true
}

run_case() {
    local mode_label="$1"
    local label_value="$2"

    echo "--- ${mode_label} ---"
    podman run --rm -i \
        --security-opt "label=${label_value}" \
        -v "$HOST_HELPER_DIR:/host-helper:rw" \
        alpine sh -c '
echo "SELinux context: $(id -Z 2>/dev/null || echo unavailable)"
echo "Attempting operations..."
echo "Test 1: Helper file access"
if cat /host-helper/protected/mock-shadow >/dev/null 2>&1; then
    echo "helper protected file: READABLE"
else
    echo "helper protected file: BLOCK"
fi
echo "Test 2: Write to helper"
if printf "policy-violation\n" > /host-helper/writable/violation-attempt 2>/dev/null; then
    echo "helper write: ALLOWED"
else
    echo "helper write: BLOCK"
fi
' 2>&1
}

validate_violation_handling() {
    local permissive_output="$1"
    local enforcing_output="$2"
    local permissive_allowed=0
    local enforcing_blocked=0

    permissive_allowed="$(printf '%s\n' "$permissive_output" | grep -Ec 'helper protected file: READABLE|helper write: ALLOWED' || true)"
    enforcing_blocked="$(printf '%s\n' "$enforcing_output" | grep -Ec 'helper protected file: BLOCK|helper write: BLOCK' || true)"

    echo "--- SELinux Violation Validation ---"
    echo "Permissive mode - allowed violation observations: ${permissive_allowed}"
    echo "Enforcing mode - blocked violation observations: ${enforcing_blocked}"

    if [ "$permissive_allowed" -gt 0 ] && [ "$enforcing_blocked" -gt 0 ]; then
        echo "RESULT: PASS - SELinux violation handling demonstrated"
        return 0
    fi

    echo "RESULT: FAIL - SELinux violation handling not demonstrated"
    echo "Expected: permissive mode shows the violation surface while enforcing mode blocks it"
    return 1
}

echo "Testing SELinux policy violations..."
echo "Target: podman-rootless with SELinux mode comparison"
echo ""

require_selinux_mode_change_privilege
create_host_helper_bundle

setenforce 0
permissive_output="$(run_case "Permissive Mode" "disable")"
printf '%s\n' "$permissive_output" > "${TEST_RESULTS_DIR}/tc11-permissive.txt"

setenforce 1
enforcing_output="$(run_case "Enforcing Mode" "level:s0:c100,c200")"
printf '%s\n' "$enforcing_output" > "${TEST_RESULTS_DIR}/tc11-enforcing.txt"

printf '%s\n' "$permissive_output"
printf '%s\n' "$enforcing_output"

cat > "${TEST_RESULTS_DIR}/tc11-results.txt" <<EOF
${permissive_output}

${enforcing_output}
EOF

echo ""
if validate_violation_handling "$permissive_output" "$enforcing_output"; then
    echo "SELinux policy violation testing completed - PASS"
    echo "Results saved to ${TEST_RESULTS_DIR}/tc11-results.txt"
    exit 0
fi

echo "SELinux policy violation testing completed - FAIL"
echo "Results saved to ${TEST_RESULTS_DIR}/tc11-results.txt"
exit 1
