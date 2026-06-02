#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/execute/image-priorities.sh"
source "$REPO_ROOT/src/shared/adapter-image-helpers.sh"
source "$REPO_ROOT/src/shared/tc08-tc09-capability-helpers.sh"

RESULTS_FILE="${TEST_RESULTS_DIR}/tc09-results.txt"

low_port_bind_is_unprivileged() {
    local combined_output="$1"
    printf '%s\n' "$combined_output" | awk -F= '
        /^ip_unprivileged_port_start=[0-9]+$/ && ($2 + 0) <= 80 {
            found = 1
        }
        END {
            exit(found ? 0 : 1)
        }
    '
}

get_unprivileged_low_port_threshold() {
    local combined_output="$1"
    printf '%s\n' "$combined_output" | awk -F= '
        /^ip_unprivileged_port_start=[0-9]+$/ && ($2 + 0) <= 80 {
            print $2
            found = 1
            exit
        }
        END {
            exit(found ? 0 : 1)
        }
    '
}

validate_capability_reduction() {
    local dropped_output="$1"
    local selective_output="$2"
    local bind_blocked=0
    local bind_allowed_in_dropped=0
    local bind_blocked_in_selective=0
    local bind_allowed=0

    bind_blocked="$(printf '%s\n' "$dropped_output" | grep -c "Port 80 binding: BLOCK" || true)"
    bind_allowed_in_dropped="$(printf '%s\n' "$dropped_output" | grep -c "Port 80 binding: ALLOWED" || true)"
    bind_blocked_in_selective="$(printf '%s\n' "$selective_output" | grep -c "Port 80 binding: BLOCK" || true)"
    bind_allowed="$(printf '%s\n' "$selective_output" | grep -c "Port 80 binding: ALLOWED" || true)"

    echo "--- Capability Reduction Validation ---"
    echo "Dropped case - blocked low-port bind attempts: ${bind_blocked}"
    echo "Dropped case - allowed low-port bind attempts: ${bind_allowed_in_dropped}"
    echo "Selective grant case - blocked low-port bind attempts: ${bind_blocked_in_selective}"
    echo "Selective grant case - allowed low-port bind attempts: ${bind_allowed}"

    if [ "$bind_blocked" -gt 0 ] && [ "$bind_allowed_in_dropped" -eq 0 ] && [ "$bind_blocked_in_selective" -eq 0 ] && [ "$bind_allowed" -gt 0 ]; then
        echo "RESULT: PASS - capability reduction effective"
        return 0
    fi

    echo "RESULT: FAIL - capability reduction not demonstrated"
    echo "Expected: the same low-port bind probe is blocked with all capabilities dropped and allowed with NET_BIND_SERVICE added"
    return 1
}

run_bind_probe() {
    local capability_description="$1"
    shift

    docker run --rm -i "$@" -e CAPABILITY_DESCRIPTION="$capability_description" "$IMAGE" sh -c '
echo "${CAPABILITY_DESCRIPTION}"
cat /proc/self/status | grep Cap 2>/dev/null || echo "Capability info not available"
echo -n "ip_unprivileged_port_start="
cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo "unavailable"

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
' 2>&1
}

IMAGE="$(get_image ALPINE_IMAGES)"

echo "--- TC09: Capability-Dropped Container Escapes ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: docker-rootless"
echo "Image: $IMAGE"
echo ""

cld6001_ensure_image docker "$IMAGE" || exit 1

echo "--- TC09: Capability-Dropped Container Escapes ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: docker-rootless"
echo "Image: $IMAGE"
echo ""

echo "--- All capabilities dropped ---"
all_dropped_output="$(run_bind_probe "No capabilities granted" --cap-drop=all)"

printf '%s\n' "$all_dropped_output"

echo ""
echo "--- Specific capabilities granted ---"
selective_cap_output="$(run_bind_probe "Only NET_BIND_SERVICE capability" --cap-drop=all --cap-add=NET_BIND_SERVICE)"

printf '%s\n' "$selective_cap_output"

cat > "$RESULTS_FILE" <<EOF
${all_dropped_output}

${selective_cap_output}
EOF

echo ""
combined_output="$all_dropped_output
$selective_cap_output"

if low_port_bind_is_unprivileged "$combined_output"; then
    low_port_bind_threshold="$(get_unprivileged_low_port_threshold "$combined_output")"
    echo "docker-rootless capability comparison: NON-COMPARABLE"
    cld6001_block \
        "capability_non_comparable_rootless_low_port_bind" \
        "Rootless Docker cannot provide a methodology-equivalent TC09 capability comparison when ip_unprivileged_port_start=${low_port_bind_threshold} keeps low-port binding unprivileged"
fi

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
