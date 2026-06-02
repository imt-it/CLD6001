#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/execute/image-priorities.sh"
source "$REPO_ROOT/src/shared/adapter-image-helpers.sh"

TC01_RUNTIME_ENGINE="${TC01_RUNTIME_ENGINE:-podman}"
TC01_RUNTIME_LABEL="${TC01_RUNTIME_LABEL:-podman-rootless}"
CUSTOM_IMAGE=""

while [ $# -gt 0 ]; do
    case $1 in
        --image)
            CUSTOM_IMAGE="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--image <image>]"
            echo ""
            echo "Options:"
            echo "--image <image>    Use specific image instead of default priority"
            echo ""
            echo "Available images (priority order):"
            for i in "${!ALPINE_IMAGES[@]}"; do
                echo "$((i+1)). ${ALPINE_IMAGES[$i]}"
            done
            exit 1
            ;;
    esac
done

if [ -n "$CUSTOM_IMAGE" ]; then
    IMAGE="$CUSTOM_IMAGE"
else
    IMAGE="$(get_image ALPINE_IMAGES)"
fi

RESULTS_FILE="${TEST_RESULTS_DIR}/tc01-results-$(cld6001_unique_timestamp_id "%Y%m%d-%H%M%S" "-").txt"

TC01_PROBE_SCRIPT='
set -Eeu

is_host_pid_namespace() {
    [ "${pid1_comm}" != "sh" ] && [ "${pid1_comm}" != "unavailable" ]
}

read_first_line() {
    sed -n "1p" "$1" 2>/dev/null | tr "\000" " " | sed "s/[[:space:]]\+/ /g; s/^ //; s/ $//"
}

echo "probe_label=${TC01_PROBE_LABEL:?}"
pid1_comm="$(cat /proc/1/comm 2>/dev/null || echo unavailable)"
self_net_ns="$(readlink /proc/self/ns/net 2>/dev/null || echo unavailable)"
pid1_net_ns="$(readlink /proc/1/ns/net 2>/dev/null || echo unavailable)"
echo "pid1_comm=${pid1_comm}"
echo "self_net_ns=${self_net_ns}"
echo "pid1_net_ns=${pid1_net_ns}"

if [ -r /host/etc/hostname ]; then
    host_hostname="$(read_first_line /host/etc/hostname)"
    echo "host_fs_mount_read=SUCCESS:${host_hostname:-unavailable}"
else
    echo "host_fs_mount_read=BLOCKED"
fi

if is_host_pid_namespace && [ -r /proc/1/root/etc/hostname ]; then
    proc1_root_hostname="$(read_first_line /proc/1/root/etc/hostname)"
    echo "host_fs_procroot_read=SUCCESS:${proc1_root_hostname:-unavailable}"
else
    echo "host_fs_procroot_read=BLOCKED"
fi

if is_host_pid_namespace && [ -r /proc/1/cmdline ]; then
    pid1_cmdline="$(tr "\000" " " < /proc/1/cmdline 2>/dev/null | sed "s/[[:space:]]\+/ /g; s/^ //; s/ $//")"
    pid1_exe="$(readlink /proc/1/exe 2>/dev/null || echo unavailable)"
    echo "host_process_cmdline=SUCCESS:${pid1_cmdline:-unavailable}"
    echo "host_process_exe=SUCCESS:${pid1_exe}"
else
    echo "host_process_cmdline=BLOCKED"
    echo "host_process_exe=BLOCKED"
fi

if is_host_pid_namespace && [ "${self_net_ns}" = "${pid1_net_ns}" ] && [ -r /proc/net/route ]; then
    host_route_iface="$(awk "NR > 1 && \$1 != \"lo\" && \$2 == \"00000000\" { print \$1; exit }" /proc/net/route 2>/dev/null || true)"
    echo "host_net_route=SUCCESS:${host_route_iface:-present}"
else
    echo "host_net_route=BLOCKED"
fi

if [ -r /dev/kmsg ]; then
    kmsg_line="$(cat /dev/kmsg 2>/dev/null | head -n 1 | sed "s/[[:space:]]\+/ /g; s/^ //; s/ $//")"
    echo "host_device_kmsg=SUCCESS:${kmsg_line:-readable}"
else
    echo "host_device_kmsg=BLOCKED"
fi
'

run_probe_capture() {
    local probe_label="$1"
    shift

    "${TC01_RUNTIME_ENGINE}" run --rm "$@" -i -e TC01_PROBE_LABEL="$probe_label" "$IMAGE" sh -eu -c "$TC01_PROBE_SCRIPT" 2>&1
}

contains_host_success() {
    local probe_output="$1"

    [[ "$probe_output" == *"host_fs_mount_read=SUCCESS:"* ]] \
        || [[ "$probe_output" == *"host_fs_procroot_read=SUCCESS:"* ]] \
        || [[ "$probe_output" == *"host_process_cmdline=SUCCESS:"* ]] \
        || [[ "$probe_output" == *"host_process_exe=SUCCESS:"* ]] \
        || [[ "$probe_output" == *"host_net_route=SUCCESS:"* ]] \
        || [[ "$probe_output" == *"host_device_kmsg=SUCCESS:"* ]]
}

echo "--- TC01: Privileged Mode ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: $TC01_RUNTIME_LABEL"
echo "Image: $IMAGE"
echo "Priority: ${ALPINE_IMAGES[*]}"
echo ""

cld6001_ensure_image "$TC01_RUNTIME_ENGINE" "$IMAGE" || exit 1

baseline_status=0
attack_status=0
baseline_output=""
attack_output=""

set +e
baseline_output="$(run_probe_capture "negative-control")"
baseline_status=$?
attack_output="$(
    run_probe_capture \
        "privileged-abuse" \
        --privileged \
        --pid=host \
        --network=host \
        -v /:/host:ro
)"
attack_status=$?
set -e

{
    echo "--- Negative control: default container ---"
    printf '%s\n' "$baseline_output"
    echo ""
    echo "--- Privileged abuse path: host PID/network + read-only host mount ---"
    printf '%s\n' "$attack_output"
    echo ""
    if [ "$baseline_status" -ne 0 ]; then
        echo "TC01_NEGATIVE_CONTROL=ERROR"
    elif contains_host_success "$baseline_output"; then
        echo "TC01_NEGATIVE_CONTROL=FAIL"
    else
        echo "TC01_NEGATIVE_CONTROL=PASS"
    fi

    if [ "$attack_status" -ne 0 ]; then
        echo "TC01_PRIVILEGED_REACHABILITY=ERROR"
    elif contains_host_success "$attack_output"; then
        echo "TC01_PRIVILEGED_REACHABILITY=PASS"
    else
        echo "TC01_PRIVILEGED_REACHABILITY=FAIL"
    fi
} | tee "$RESULTS_FILE"

if [ "$baseline_status" -ne 0 ]; then
    error "TC01 negative control failed to execute under $TC01_RUNTIME_LABEL"
    exit 1
fi

if [ "$attack_status" -ne 0 ]; then
    warn "TC01 privileged abuse path could not execute under $TC01_RUNTIME_LABEL"
elif contains_host_success "$baseline_output"; then
    error "TC01 negative control unexpectedly reached host-scoped resources under $TC01_RUNTIME_LABEL"
    exit 1
elif contains_host_success "$attack_output"; then
    ok "TC01 privileged abuse path demonstrated direct host reachability under $TC01_RUNTIME_LABEL"
else
    warn "TC01 privileged abuse path remained container-scoped under $TC01_RUNTIME_LABEL"
fi

echo ""
echo "---"
ok "TC01 negative control stayed container-scoped under $TC01_RUNTIME_LABEL"
echo "Results saved to: $RESULTS_FILE"
echo "---"
