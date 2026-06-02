#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/shared/adapter-cleanup-helpers.sh"

RESULTS_FILE="${TEST_RESULTS_DIR}/tc08-results.txt"
HOST_HELPER_DIR=""
IMAGE="alpine"

create_host_helper_bundle() {
    HOST_HELPER_DIR="$(create_host_probe_dir "tc08-docker-helper")" || cld6001_block "precondition_failed" "Failed to create controlled host helper bundle for TC08"
    mkdir -p "${HOST_HELPER_DIR}/protected" || cld6001_block "precondition_failed" "Failed to prepare controlled host helper bundle for TC08"
    printf 'host-helper-shadow\n' > "${HOST_HELPER_DIR}/protected/mock-shadow" || cld6001_block "precondition_failed" "Failed to populate controlled host helper bundle for TC08"
    chmod 000 "${HOST_HELPER_DIR}/protected/mock-shadow" 2>/dev/null || true
    printf 'controlled host helper bundle for TC08\n' > "${HOST_HELPER_DIR}/README.txt" || cld6001_block "precondition_failed" "Failed to describe controlled host helper bundle for TC08"
}

trap cld6001_cleanup_host_helper_bundle EXIT
create_host_helper_bundle

mkdir -p "$(dirname "$RESULTS_FILE")"
: > "$RESULTS_FILE"
exec > >(tee "$RESULTS_FILE") 2>&1

echo "--- TC08: Capability Abuse Attacks ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: docker-rootful"
echo "Image: ${IMAGE}"
echo ""

run_probe() {
    local label="$1"
    local cap="$2"
    local probe_script="$3"
    local output=""
    local status=0
    local -a docker_args=(run --rm -i --cap-drop=all -v "$HOST_HELPER_DIR:/host-helper:ro")

    if [ "$label" = "host-pid" ]; then
        docker_args+=(--pid=host)
    fi
    if [ -n "$cap" ]; then
        docker_args+=(--cap-add="$cap" -e "CAP_UNDER_TEST=$cap")
    else
        docker_args+=(-e CAP_UNDER_TEST=negative-control)
    fi

    set +e
    output="$(docker "${docker_args[@]}" "$IMAGE" sh -c "$probe_script" 2>&1)"
    status=$?
    set -e

    printf '%s\n' "$output"
    return "$status"
}

print_result_or_block() {
    local description="$1"
    local label="$2"
    local cap="$3"
    local probe_script="$4"
    local block_message="$5"
    local output=""

    echo "$description"
    if output="$(run_probe "$label" "$cap" "$probe_script")"; then
        printf '%s\n' "$output"
    else
        printf '%s\n' "$output"
        echo "$block_message"
    fi
}

test_dac_override() {
    local probe_script='echo "Capabilities granted:"; capsh --print 2>/dev/null || echo "Capability info unavailable"; echo "Attempting escape with ${CAP_UNDER_TEST}..."; echo "CAP_DAC_OVERRIDE - Reading a controlled host-only artifact"; helper_secret="$(cat /host-helper/protected/mock-shadow 2>/dev/null || true)"; if [ -n "$helper_secret" ]; then echo "helper protected file: READABLE"; echo "helper protected sample: ${helper_secret}"; else echo "helper protected file: BLOCK"; fi'

    echo "--- Testing capability: CAP_DAC_OVERRIDE (host artifact access) ---"
    print_result_or_block "Negative control: no added capability" "helper" "" "$probe_script" "BLOCK: runtime failed before DAC negative control completed"
    print_result_or_block "Positive case: granting CAP_DAC_OVERRIDE" "helper" "CAP_DAC_OVERRIDE" "$probe_script" "BLOCK: runtime refused CAP_DAC_OVERRIDE helper read attempt"
    echo ""
}

test_sys_admin() {
    local probe_script='echo "Capabilities granted:"; capsh --print 2>/dev/null || echo "Capability info unavailable"; echo "Attempting escape with ${CAP_UNDER_TEST}..."; echo "CAP_SYS_ADMIN - Bind-mounting controlled host helper for alternate-path access"; mkdir -p /mnt/host-helper 2>/dev/null || true; if mount --bind /host-helper /mnt/host-helper >/dev/null 2>&1; then echo "controlled host helper remount: ALLOWED"; remount_sample="$(cat /mnt/host-helper/README.txt 2>/dev/null || true)"; if [ -n "$remount_sample" ]; then echo "remounted helper inventory: ${remount_sample}"; else echo "remounted helper inventory: UNREADABLE"; fi; else echo "controlled host helper remount: BLOCK"; fi'

    echo "--- Testing capability: CAP_SYS_ADMIN (admin surface remount) ---"
    print_result_or_block "Negative control: no added capability" "helper" "" "$probe_script" "BLOCK: runtime failed before SYS_ADMIN negative control completed"
    print_result_or_block "Positive case: granting CAP_SYS_ADMIN" "helper" "CAP_SYS_ADMIN" "$probe_script" "BLOCK: runtime refused CAP_SYS_ADMIN helper remount"
    echo ""
}

test_mknod() {
    local probe_script='echo "Capabilities granted:"; capsh --print 2>/dev/null || echo "Capability info unavailable"; echo "Attempting escape with ${CAP_UNDER_TEST}..."; echo "CAP_MKNOD - Provisioning a host-like device alias in writable workspace"; rm -f /probe-tmp/tc08-null 2>/dev/null || true; mkdir -p /probe-tmp 2>/dev/null || true; if mknod /probe-tmp/tc08-null c 1 3 >/dev/null 2>&1; then echo "device node creation: ALLOWED"; echo "device node target: /probe-tmp/tc08-null"; else echo "device node creation: BLOCK"; fi'

    echo "--- Testing capability: CAP_MKNOD (device node creation) ---"
    print_result_or_block "Negative control: no added capability" "helper" "" "$probe_script" "BLOCK: runtime failed before MKNOD negative control completed"
    print_result_or_block "Positive case: granting CAP_MKNOD" "helper" "CAP_MKNOD" "$probe_script" "BLOCK: runtime refused CAP_MKNOD device-node attempt"
    echo ""
}

test_sys_ptrace() {
    local probe_script='echo "Capabilities granted:"; capsh --print 2>/dev/null || echo "Capability info unavailable"; echo "Attempting escape with ${CAP_UNDER_TEST}..."; echo "CAP_SYS_PTRACE - Inspecting host PID 1 environment"; host_env_sample="$(cat /proc/1/environ 2>/dev/null | tr "\000" "\n" | sed -n "1p")"; if [ -n "$host_env_sample" ]; then echo "host process environ: READABLE"; echo "host process key observed: ${host_env_sample%%=*}"; else echo "host process environ: BLOCK"; fi'

    echo "--- Testing capability: CAP_SYS_PTRACE (host process introspection) ---"
    print_result_or_block "Negative control: no added capability" "host-pid" "" "$probe_script" "BLOCK: runtime failed before SYS_PTRACE negative control completed"
    print_result_or_block "Positive case: granting CAP_SYS_PTRACE" "host-pid" "CAP_SYS_PTRACE" "$probe_script" "BLOCK: runtime refused CAP_SYS_PTRACE host process probe"
    echo ""
}

test_dac_override
test_sys_admin
test_mknod
test_sys_ptrace

echo "Capability abuse testing completed"
echo "Results saved to ${RESULTS_FILE}"
