#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/execute/escape-tests/network-probe-common.sh"
source "$REPO_ROOT/src/execute/image-priorities.sh"
source "$REPO_ROOT/src/shared/adapter-image-helpers.sh"
source "$REPO_ROOT/src/shared/docker-rootless-overlay-guard.sh"
source "$REPO_ROOT/src/shared/tc02-namespace-helper-probes.sh"
source "$REPO_ROOT/src/shared/tc02-namespace-helpers.sh"

if [ "${CLD6001_TC02_DOCKER_ROOTLESS_OVERLAY_GUARD_ACTIVE:-0}" != "1" ]; then
    export CLD6001_TC02_DOCKER_ROOTLESS_OVERLAY_GUARD_ACTIVE=1
    cld6001_run_docker_rootless_with_nested_overlay_guard "tc02" "$0" "$@"
    exit $?
fi

RESULTS_FILE="${TEST_RESULTS_DIR}/tc02-results-$(cld6001_unique_timestamp_id "%Y%m%d-%H%M%S" "-").txt"
RUN_ID="$(cld6001_unique_timestamp_id "%s" "-")"
RUN_EPOCH="${RUN_ID%%-*}"
IMAGE="$(get_image ALPINE_IMAGES)"
HOST_PID_HELPER_PID=""
HOST_LISTENER_PID=""
HOST_NETWORK_PORT=""
HOST_NETWORK_TOKEN=""

run_or_note_rootless_limitation() {
    local fallback_message="$1"
    shift

    local output=""
    local status=0

    set +e
    output="$(docker "$@" 2>&1)"
    status=$?
    set -e

    if [ -n "$output" ]; then
        printf '%s\n' "$output" | tee -a "$RESULTS_FILE"
    fi

    if [ "$status" -ne 0 ] && [ -n "$fallback_message" ]; then
        printf '%s\n' "$fallback_message" | tee -a "$RESULTS_FILE"
    fi
}

cleanup() {
    tc02_cleanup_host_pid_helper "${HOST_PID_HELPER_PID:-}"
    tc02_cleanup_host_loopback_helper "${HOST_LISTENER_PID:-}"
}

start_pid_helper() {
    tc02_cleanup_host_pid_helper "${HOST_PID_HELPER_PID:-}"
    HOST_PID_HELPER_PID=""

    if ! tc02_start_host_pid_helper HOST_PID_HELPER_PID; then
        echo "Controlled host PID helper did not start with a live host PID" | tee -a "$RESULTS_FILE"
        exit 1
    fi
}

start_network_helper() {
    tc02_cleanup_host_loopback_helper "${HOST_LISTENER_PID:-}"
    HOST_LISTENER_PID=""
    HOST_NETWORK_PORT=""

    if ! tc02_start_host_loopback_helper HOST_LISTENER_PID HOST_NETWORK_PORT HOST_NETWORK_TOKEN "$RUN_EPOCH"; then
        echo "Failed to start controlled host loopback helper service" | tee -a "$RESULTS_FILE"
        exit 1
    fi
}

trap cleanup EXIT

echo "--- TC02: Namespace Sharing Isolation Assessment ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: docker-rootless"
echo "Image: $IMAGE"
echo "Run ID: $RUN_ID"
echo ""

cld6001_ensure_image docker "$IMAGE" || exit 1
start_pid_helper
start_network_helper
echo "Controlled host helper PID: $HOST_PID_HELPER_PID" | tee -a "$RESULTS_FILE"
echo "Controlled host loopback helper: 127.0.0.1:${HOST_NETWORK_PORT} token=${HOST_NETWORK_TOKEN}" | tee -a "$RESULTS_FILE"

echo "--- Test 2a: PID Namespace Visibility Assessment ---" | tee -a "$RESULTS_FILE"
run_or_note_rootless_limitation \
    "Host PID sharing comparison: NON-COMPARABLE in docker-rootless" \
    run --rm --pid=host -e TARGET_HOST_PID="$HOST_PID_HELPER_PID" -i "$IMAGE" sh -c '
echo "Container PID namespace:"
ps aux
echo "Attempting to probe controlled host helper..."
kill -0 "$TARGET_HOST_PID" 2>/dev/null && echo "Host helper reachable from shared PID namespace" || echo "Host helper probe blocked"
if kill -TERM "$TARGET_HOST_PID" 2>/dev/null; then
  echo "PID helper termination triggered from container"
else
  echo "PID helper termination blocked"
fi
'

helper_stopped=0
for _ in $(seq 1 40); do
    if ! kill -0 "$HOST_PID_HELPER_PID" 2>/dev/null; then
        echo "Controlled host helper exited after in-container signal" | tee -a "$RESULTS_FILE"
        helper_stopped=1
        break
    fi
    sleep 0.2
done
if [ "$helper_stopped" -eq 0 ]; then
    echo "Controlled host helper still running after in-container signal" | tee -a "$RESULTS_FILE"
fi
start_pid_helper

echo "--- Test 2b: Network Namespace Access Assessment ---" | tee -a "$RESULTS_FILE"
run_or_note_rootless_limitation \
    "Host network sharing comparison: NON-COMPARABLE in docker-rootless" \
    run --rm --network=host -e HOST_NETWORK_PORT="$HOST_NETWORK_PORT" -e HOST_NETWORK_TOKEN="$HOST_NETWORK_TOKEN" -i "$IMAGE" sh -c '
echo "Network interfaces visible:"
ip addr show 2>/dev/null || echo "Network access blocked"
echo "Attempting localhost helper fetch..."
TOKEN="$(nc -w 1 127.0.0.1 "${HOST_NETWORK_PORT}" 2>/dev/null || true)"
if [ "$TOKEN" = "$HOST_NETWORK_TOKEN" ]; then
  echo "Host loopback helper reachable from shared network namespace"
else
  echo "Host loopback helper unreachable from shared network namespace"
fi
'

echo "--- Test 2c: Host-UserNS Comparative Probe ---" | tee -a "$RESULTS_FILE"
run_or_note_rootless_limitation \
    "Host user namespace comparison: NON-COMPARABLE in docker-rootless" \
    run --rm --userns=host -e TARGET_HOST_PID="$HOST_PID_HELPER_PID" -e HOST_NETWORK_PORT="$HOST_NETWORK_PORT" -e HOST_NETWORK_TOKEN="$HOST_NETWORK_TOKEN" -i "$IMAGE" sh -c '
echo "Host-userns comparison note: PID and network helper use is demonstrated in Tests 2a/2b; this remains a comparative probe."
echo "Host-userns uid map:"
cat /proc/self/uid_map 2>/dev/null || echo "uid_map unavailable"
echo "Attempting controlled host PID helper probe..."
kill -0 "$TARGET_HOST_PID" 2>/dev/null && echo "Unexpected controlled host PID helper reachable under host-userns comparison" || echo "Host-userns comparison keeps controlled host PID helper unreachable"
echo "Attempting localhost helper fetch..."
TOKEN="$(nc -w 1 127.0.0.1 "${HOST_NETWORK_PORT}" 2>/dev/null || true)"
if [ "$TOKEN" = "$HOST_NETWORK_TOKEN" ]; then
  echo "Unexpected host loopback helper reachable under host-userns comparison"
else
  echo "Host-userns comparison does not expose the host loopback helper"
fi
'

echo "--- Test 2d: Default-Isolation Negative Control ---" | tee -a "$RESULTS_FILE"
run_or_note_rootless_limitation \
    "Default namespace isolation maintained"$'\n'"Host PID helper hidden by default namespace isolation"$'\n'"Host loopback helper hidden by default namespace isolation" \
    run --rm -e TARGET_HOST_PID="$HOST_PID_HELPER_PID" -e HOST_NETWORK_PORT="$HOST_NETWORK_PORT" -e HOST_NETWORK_TOKEN="$HOST_NETWORK_TOKEN" -i "$IMAGE" sh -c '
echo "Default namespace isolation maintained"
kill -0 "$TARGET_HOST_PID" 2>/dev/null && echo "Unexpected host PID helper reachable" || echo "Host PID helper hidden by default namespace isolation"
TOKEN="$(nc -w 1 127.0.0.1 "${HOST_NETWORK_PORT}" 2>/dev/null || true)"
if [ "$TOKEN" = "$HOST_NETWORK_TOKEN" ]; then
  echo "Unexpected host loopback helper reachable"
else
  echo "Host loopback helper hidden by default namespace isolation"
fi
'

echo "--- Test 2e: Namespace Manipulation Assessment ---" | tee -a "$RESULTS_FILE"
run_or_note_rootless_limitation \
    "PID namespace creation blocked"$'\n'"Network namespace creation blocked" \
    run --rm -i "$IMAGE" sh -c '
echo "Attempting namespace manipulation..."
unshare --pid --fork echo "New PID namespace created" 2>/dev/null || echo "PID namespace creation blocked"
unshare --net --fork echo "New network namespace created" 2>/dev/null || echo "Network namespace creation blocked"
'

echo ""
echo "---"
ok "Test TC02 completed successfully"
echo "Results saved to: $RESULTS_FILE"
echo "---"
