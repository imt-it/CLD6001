#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"

TC16_RESULTS_DIR="${RUNNER_ARTIFACTS_DIR:-$TEST_RESULTS_DIR}"
mkdir -p "$TC16_RESULTS_DIR"
tc16_result_targets=("${TC16_RESULTS_DIR}/tc16-results.txt")
if [ -n "${RUNNER_ARTIFACTS_DIR:-}" ] && [ "$TEST_RESULTS_DIR" != "$RUNNER_ARTIFACTS_DIR" ]; then
    tc16_result_targets+=("${TEST_RESULTS_DIR}/tc16-results.txt")
fi

RUNTIME_ENGINE="${RUNNER_RUNTIME_ENGINE:-docker}"
helper_image="alpine"
if declare -F resolve_helper_image >/dev/null 2>&1; then
    helper_image="$(resolve_helper_image "alpine-shell" 2>/dev/null || echo "alpine")"
fi

runtime_args=(run --rm -i)
runtime_args+=(--cap-drop=all)
runtime_args+=(--read-only)
runtime_args+=(--security-opt=no-new-privileges)
runtime_args+=(--security-opt label=level:s0:c100,c200)
runtime_args+=(--network=none)
if [ -S /var/run/docker.sock ]; then
    runtime_args+=(-v /var/run/docker.sock:/var/run/docker.sock:ro)
fi

echo "--- TC16: Control Interaction Probe ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: ${RUNTIME_ENGINE}"
echo ""

{
    if "${RUNTIME_ENGINE}" "${runtime_args[@]}" "$helper_image" sh -c '
echo "=== PROBE 1: Docker socket access ==="
if [ -S /var/run/docker.sock ]; then
    socket_list_request="GET /v1.24/containers/json HTTP/1.1\r\nHost: docker\r\n\r\n"
    if printf "%b" "$socket_list_request" | nc -w 3 local:/var/run/docker.sock 2>/dev/null; then
        :
    elif printf "%b" "$socket_list_request" | nc -w 3 -U /var/run/docker.sock 2>/dev/null; then
        :
    elif wget -qO- --timeout=3 http://localhost/v1.24/containers/json --header "Host: docker" 2>/dev/null; then
        :
    else
        echo "RESULT: Socket communication blocked"
    fi

    socket_create_request="POST /v1.24/containers/create HTTP/1.1\r\nHost: docker\r\nContent-Type: application/json\r\n\r\n{\"Image\":\"alpine\",\"HostConfig\":{\"Privileged\":true}}"
    if printf "%b" "$socket_create_request" | nc -w 3 local:/var/run/docker.sock 2>/dev/null; then
        :
    elif printf "%b" "$socket_create_request" | nc -w 3 -U /var/run/docker.sock 2>/dev/null; then
        :
    else
        echo "RESULT: Container creation blocked"
    fi
else
    echo "RESULT: Docker socket not available"
fi

echo "=== PROBE 2: Filesystem write attempts ==="
echo "test" > /etc/escape_test 2>&1 || echo "RESULT: /etc write blocked (read-only)"
echo "test" > /tmp/escape_test 2>&1 || echo "RESULT: /tmp write blocked (read-only)"
mkdir /breakout 2>&1 || echo "RESULT: mkdir blocked (read-only)"

echo "=== PROBE 3: Capability escalation ==="
mount -t proc proc /mnt 2>&1 || echo "RESULT: mount blocked (no CAP_SYS_ADMIN)"
mknod /dev/sda1 b 8 1 2>&1 || echo "RESULT: mknod blocked (no CAP_MKNOD)"
ip link add dummy0 type dummy 2>&1 || echo "RESULT: network manipulation blocked (no CAP_NET_ADMIN)"

echo "=== PROBE 4: Privilege escalation via SUID ==="
cp /bin/sh /tmp/suid_sh 2>/dev/null && chmod u+s /tmp/suid_sh 2>&1 || echo "RESULT: SUID creation blocked"
grep -i "nonewprivs" /proc/self/status 2>/dev/null || echo "RESULT: NoNewPrivs status unavailable"

echo "=== PROBE 5: Network host access ==="
wget -qO- --timeout=3 http://172.17.0.1:2375/ 2>&1 || echo "RESULT: Host network access blocked"
ping -c 1 -W 1 172.17.0.1 2>&1 || echo "RESULT: Host ping blocked (network=none)"
'; then
        :
    else
        probe_exit=$?
        echo "RESULT: Hardened probe launch failed (exit=${probe_exit})"
    fi

    echo ""
    echo "=== TC16 SUMMARY ==="
    echo "Controls tested: cap-drop=all, read-only, no-new-privileges, SELinux MCS, network=none"
    echo "Expected: All probes blocked by combined controls"
} 2>&1 | tee "${tc16_result_targets[@]}"

echo "TC16 control-interaction probe completed"
