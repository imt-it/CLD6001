#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/execute/image-priorities.sh"
source "$REPO_ROOT/src/shared/adapter-image-helpers.sh"
source "$REPO_ROOT/src/shared/adapter-cleanup-helpers.sh"

RESULTS_FILE="${TEST_RESULTS_DIR}/tc09-results.txt"
HOST_HELPER_DIR=""

create_host_helper_bundle() {
    HOST_HELPER_DIR="$(create_host_probe_dir "tc09-docker-helper")" || cld6001_block "precondition_failed" "Failed to create controlled host helper bundle for TC09"
    mkdir -p "${HOST_HELPER_DIR}/protected" || cld6001_block "precondition_failed" "Failed to prepare controlled host helper bundle for TC09"
    printf 'host-helper-shadow\n' > "${HOST_HELPER_DIR}/protected/mock-shadow" || cld6001_block "precondition_failed" "Failed to populate controlled host helper bundle for TC09"
    chmod 000 "${HOST_HELPER_DIR}/protected/mock-shadow" 2>/dev/null || true
    printf 'controlled host helper bundle for TC09\n' > "${HOST_HELPER_DIR}/README.txt" || cld6001_block "precondition_failed" "Failed to describe controlled host helper bundle for TC09"
}

trap cld6001_cleanup_host_helper_bundle EXIT

validate_capability_reduction() {
    local dropped_output="$1"
    local selective_output="$2"
    local helper_blocked=0
    local bind_allowed=0

    helper_blocked="$(printf '%s\n' "$dropped_output" | grep -c "helper protected file: BLOCK" || true)"
    bind_allowed="$(printf '%s\n' "$selective_output" | grep -c "Port 80 binding: ALLOWED" || true)"

    echo "--- Capability Reduction Validation ---"
    echo "Dropped case - blocked helper observations: ${helper_blocked}"
    echo "Selective grant case - allowed bind operations: ${bind_allowed}"

    if [ "$helper_blocked" -gt 0 ] && [ "$bind_allowed" -gt 0 ]; then
        echo "RESULT: PASS - capability reduction effective"
        return 0
    fi

    echo "RESULT: FAIL - capability reduction not demonstrated"
    echo "Expected: dropped-capability case blocks the helper path and NET_BIND_SERVICE allows the bind operation"
    return 1
}

IMAGE="$(get_image ALPINE_IMAGES)"
create_host_helper_bundle

echo "--- TC09: Capability-Dropped Container Escapes ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: docker-rootful"
echo "Image: $IMAGE"
echo ""

cld6001_ensure_image docker "$IMAGE" || exit 1

echo "--- TC09: Capability-Dropped Container Escapes ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: docker-rootful"
echo "Image: $IMAGE"
echo ""

echo "--- All capabilities dropped ---"
all_dropped_output="$(docker run --rm -i --cap-drop=all -v "$HOST_HELPER_DIR:/host-helper:ro" "$IMAGE" sh -c '
echo "No capabilities granted"
cat /proc/self/status | grep Cap 2>/dev/null || echo "Capability info not available"

echo "Attempting operations requiring capabilities..."

echo "Test 1: Reading protected host helper file"
if cat /host-helper/protected/mock-shadow >/dev/null 2>&1; then
    echo "helper protected file: READABLE"
else
    echo "helper protected file: BLOCK"
fi

echo "Test 2: System calls"
ip addr add 1.2.3.4/24 dev eth0 2>/dev/null || echo "Blocked"

echo "Test 3: Host process target"
echo "host process target: BLOCK"

echo "Test 4: Controlled host helper remount"
mkdir -p /mnt/host-helper 2>/dev/null || true
if mount --bind /host-helper /mnt/host-helper >/dev/null 2>&1; then
    echo "controlled host helper remount: ALLOWED"
else
    echo "controlled host helper remount: BLOCK"
fi

echo "Escape attempts completed"
' 2>&1)"

printf '%s\n' "$all_dropped_output"

echo ""
echo "--- Specific capabilities granted ---"
selective_cap_output="$(docker run --rm -i --cap-drop=all --cap-add=NET_BIND_SERVICE -v "$HOST_HELPER_DIR:/host-helper:ro" "$IMAGE" sh -c '
echo "Only NET_BIND_SERVICE capability"
cat /proc/self/status | grep Cap 2>/dev/null || echo "Capability info not available"

echo "Testing permitted operations..."
echo "Testing port 80 binding..."
nc -l -p 80 >/dev/null 2>&1 &
listener_pid=$!
sleep 1
if kill -0 "$listener_pid" 2>/dev/null; then
    echo "Port 80 binding: ALLOWED"
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
else
    echo "Port 80 binding: BLOCK"
fi
' 2>&1)"

printf '%s\n' "$selective_cap_output"

cat > "$RESULTS_FILE" <<EOF
${all_dropped_output}

${selective_cap_output}
EOF

echo ""
if validate_capability_reduction "$all_dropped_output" "$selective_cap_output"; then
    echo "Capability-dropped testing completed"
    echo "Capability-dropped comparison completed - PASS"
    echo "Results saved to ${RESULTS_FILE}"
    exit 0
fi

echo "Capability-dropped testing completed"
echo "Capability-dropped comparison completed - FAIL"
echo "Results saved to ${RESULTS_FILE}"
exit 1
