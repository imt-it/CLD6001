#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/shared/adapter-cleanup-helpers.sh"
source "$REPO_ROOT/src/shared/adapter-image-helpers.sh"

RESULTS_FILE="${TEST_RESULTS_DIR}/tc12-results.txt"
HOST_HELPER_DIR=""
ORIGINAL_SELINUX_MODE=""
TC12_TOOLING_IMAGE="${RUNNER_TC12_TOOLING_IMAGE:-cld6001/tc12-selinux-tooling:ubi9}"
TC12_TOOLING_BASE_IMAGE="${RUNNER_TC12_TOOLING_BASE_IMAGE:-registry.access.redhat.com/ubi9/ubi:latest}"
TOOLING_MISSING="TOOLING_MISSING"

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

cleanup_tc12() {
    restore_original_selinux_mode
    cld6001_cleanup_host_helper_bundle
}

trap cleanup_tc12 EXIT

create_host_helper_bundle() {
    HOST_HELPER_DIR="$(create_host_probe_dir "tc12-docker-helper")" || cld6001_block "precondition_failed" "Failed to create controlled host helper bundle for TC12"

    mkdir -p "$HOST_HELPER_DIR/protected" "$HOST_HELPER_DIR/relabel"
    printf 'simulated-shadow\n' > "$HOST_HELPER_DIR/protected/mock-shadow"
    chmod 000 "$HOST_HELPER_DIR/protected/mock-shadow"
    printf 'label-target\n' > "$HOST_HELPER_DIR/relabel/label-target"
}

echo "--- TC12: SELinux Bypass Techniques ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: docker-rootful"
echo ""

require_tc12_container_tooling() {
    local missing=""
    local missing_csv=""

    if [ -n "${RUNNER_TC12_TOOLING_IMAGE:-}" ]; then
        cld6001_ensure_image docker "$TC12_TOOLING_IMAGE" || exit 1
    elif ! docker image inspect "$TC12_TOOLING_IMAGE" >/dev/null 2>&1; then
        info "Building TC12 tooling image: $TC12_TOOLING_IMAGE"
        docker build \
            --build-arg "BASE_IMAGE=$TC12_TOOLING_BASE_IMAGE" \
            --tag "$TC12_TOOLING_IMAGE" \
            - >/dev/null <<'EOF' || cld6001_block "tc12_tooling_image_unavailable" "Failed to build the TC12 tooling image"
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
RUN dnf install -y --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
        policycoreutils \
        policycoreutils-python-utils \
    && dnf clean all
EOF
    fi

    missing="$(docker run --rm -e TOOLING_MISSING="$TOOLING_MISSING" --entrypoint sh "$TC12_TOOLING_IMAGE" -c '
for tool in semanage semodule chcon restorecon; do
    command -v "$tool" >/dev/null 2>&1 || printf "%s:%s\n" "$TOOLING_MISSING" "$tool"
done
' 2>/dev/null || true)"
    missing="$(printf '%s\n' "$missing" | sed -n "s/^${TOOLING_MISSING}://p")"

    if [ -n "$missing" ]; then
        missing_csv="$(printf '%s\n' "$missing" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
        cld6001_block "tc12_tooling_missing" "TC12 container tooling missing: ${missing_csv}"
    fi
}

require_selinux_enforcing_mode() {
    local selinux_mode=""

    if ! command -v getenforce >/dev/null 2>&1; then
        cld6001_block "selinux_tooling_unavailable" "SELinux tooling not available on the host"
    fi

    if ! command -v setenforce >/dev/null 2>&1; then
        cld6001_block "selinux_tooling_unavailable" "SELinux mode changes cannot be requested on the host"
    fi

    selinux_mode="$(getenforce)"
    ORIGINAL_SELINUX_MODE="$selinux_mode"
    echo "Host SELinux mode: ${selinux_mode}"

    if [ "$selinux_mode" = "Disabled" ]; then
        cld6001_block "selinux_disabled" "SELinux is disabled on the host"
    fi

    if [ "$selinux_mode" != "Enforcing" ]; then
        if [[ "$(id -u)" -ne 0 ]]; then # [[:
            cld6001_block "privilege_required" "host SELinux mode changes require elevated privileges"
            exit "${BLOCK_EXIT_CODE:-3}"
        fi

        setenforce 1
        selinux_mode="$(getenforce)"
        echo "Host SELinux mode after enforcement request: ${selinux_mode}"
        if [ "$selinux_mode" != "Enforcing" ]; then
            cld6001_block "selinux_not_enforcing" "host SELinux could not be set to enforcing"
        fi
    fi
}

run_case() {
    local security_opt="$1"
    local case_script="$2"

    docker run --rm -i \
        --security-opt "$security_opt" \
        -v "$HOST_HELPER_DIR:/host-helper:rw" \
        "$TC12_TOOLING_IMAGE" sh -c "$case_script" 2>&1
}

summarize_bypass_observations() {
    local context_output="$1"
    local policy_output="$2"
    local transition_output="$3"
    local label_output="$4"
    local weakened_observations=0
    local blocked_observations=0

    weakened_observations="$(printf '%s\n%s\n%s\n%s\n' \
        "$context_output" "$policy_output" "$transition_output" "$label_output" \
        | grep -Ec 'READABLE|ALLOWED' || true)"
    blocked_observations="$(printf '%s\n%s\n%s\n%s\n' \
        "$context_output" "$policy_output" "$transition_output" "$label_output" \
        | grep -Ec 'BLOCK' || true)"

    echo "--- SELinux Bypass Observation Summary ---"
    echo "Potential weakening observations recorded: ${weakened_observations}"
    echo "Blocked observations recorded: ${blocked_observations}"
    echo "Interpretation: TC12 preserves raw bypass-attempt evidence only; it does not emit a top-level validation verdict."
}

read -r -d '' TC12_CONTEXT_SCRIPT <<'EOF' || true
echo "SELinux context: $(id -Z 2>/dev/null || echo unavailable)"
echo "Attempting context manipulation..."
echo "Test 1a: Controlled helper access"
if cat /host-helper/protected/mock-shadow >/dev/null 2>&1; then
    echo "helper protected file: READABLE"
else
    echo "helper protected file: BLOCK"
fi
EOF

read -r -d '' TC12_POLICY_SCRIPT <<'EOF' || true
echo "SELinux context: $(id -Z 2>/dev/null || echo unavailable)"
echo "Attempting policy manipulation..."
echo "Test 2a: Policy modification"
if semanage boolean -M container_manage_cifs -on 2>/dev/null; then
    echo "policy boolean modification: ALLOWED"
else
    echo "policy boolean modification: BLOCK"
fi
echo "Test 2b: Custom boolean"
if semanage boolean -M container_use_nfs -on 2>/dev/null; then
    echo "custom boolean modification: ALLOWED"
else
    echo "custom boolean modification: BLOCK"
fi
EOF

read -r -d '' TC12_TRANSITION_SCRIPT <<'EOF' || true
echo "SELinux context: $(id -Z 2>/dev/null || echo unavailable)"
echo "Attempting transition manipulation..."
echo "Test 3a: Create transition"
if semanage module -i /dev/null 2>/dev/null; then
    echo "policy module import: ALLOWED"
else
    echo "policy module import: BLOCK"
fi
echo "Test 3b: Load policy"
if semodule -i /dev/null 2>/dev/null; then
    echo "policy load: ALLOWED"
else
    echo "policy load: BLOCK"
fi
EOF

read -r -d '' TC12_LABEL_SCRIPT <<'EOF' || true
echo "SELinux context: $(id -Z 2>/dev/null || echo unavailable)"
echo "Attempting file label manipulation..."
echo "Test 4a: Relabel controlled helper"
if chcon system_u:object_r:container_file_t:s0:c100,c200 /host-helper/relabel/label-target 2>/dev/null; then
    echo "helper relabel: ALLOWED"
else
    echo "helper relabel: BLOCK"
fi
echo "Test 4b: Restorecon controlled helper"
if restorecon -v /host-helper/relabel/label-target 2>/dev/null; then
    echo "helper restorecon: ALLOWED"
else
    echo "helper restorecon: BLOCK"
fi
EOF

require_selinux_enforcing_mode
create_host_helper_bundle
require_tc12_container_tooling

echo "--- Test 1: Context manipulation ---"
context_output="$(run_case "label=type:unconfined_t" "$TC12_CONTEXT_SCRIPT")"
printf '%s\n' "$context_output" | tee "${TEST_RESULTS_DIR}/tc12-test1.txt"

echo "--- Test 2: Policy manipulation ---"
policy_output="$(run_case "label=type:container_init_t" "$TC12_POLICY_SCRIPT")"
printf '%s\n' "$policy_output" | tee "${TEST_RESULTS_DIR}/tc12-test2.txt"

echo "--- Test 3: Transition manipulation ---"
transition_output="$(run_case "label=type:container_t" "$TC12_TRANSITION_SCRIPT")"
printf '%s\n' "$transition_output" | tee "${TEST_RESULTS_DIR}/tc12-test3.txt"

echo "--- Test 4: File label manipulation ---"
label_output="$(run_case "label=level:s0:c100,c200" "$TC12_LABEL_SCRIPT")"
printf '%s\n' "$label_output" | tee "${TEST_RESULTS_DIR}/tc12-test4.txt"

cat > "$RESULTS_FILE" <<EOF
--- Test 1: Context manipulation ---
${context_output}

--- Test 2: Policy manipulation ---
${policy_output}

--- Test 3: Transition manipulation ---
${transition_output}

--- Test 4: File label manipulation ---
${label_output}
EOF

echo ""
summarize_bypass_observations "$context_output" "$policy_output" "$transition_output" "$label_output"
echo "SELinux bypass technique testing completed"
echo "Results saved to ${RESULTS_FILE}"
