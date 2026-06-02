#!/bin/bash

set -Eeuo pipefail

TEST_NAME="Container Escape Test Case"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_FILE="${RESULT_FILE:-${TEST_RESULTS_DIR:-.}/escape_test_results.txt}"
CONTAINER_NAME="${CONTAINER_NAME:-escape-test-container}"
IMAGE_NAME="${IMAGE_NAME:-escape-test-image}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/container-escape.XXXXXX")"

trap 'cleanup_test_resources' EXIT

record_probe_result() {
    local probe_name="$1"
    local result="$2"
    printf '%s: %s\n' "$probe_name" "$result" >> "$RESULT_FILE"
}

create_test_container() {
    cat > "$WORK_DIR/Dockerfile" <<'EOF'
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y python3 util-linux libcap2-bin
CMD ["sleep", "infinity"]
EOF

    docker build -t "$IMAGE_NAME" "$WORK_DIR"
    docker run -d --name "$CONTAINER_NAME" "$IMAGE_NAME" sleep infinity >/dev/null
}

test_mount_namespace_escape() {
    if docker exec "$CONTAINER_NAME" mount -t tmpfs /tmp && docker exec "$CONTAINER_NAME" ls -la /tmp; then
        record_probe_result "Mount namespace escape" "SUCCESSFUL"
        return 0
    fi
    record_probe_result "Mount namespace escape" "BLOCK"
}

test_process_namespace_escape() {
    if docker exec "$CONTAINER_NAME" nsenter --pid=1 ls -l /proc/1; then
        record_probe_result "Process namespace escape" "SUCCESSFUL"
        return 0
    fi
    record_probe_result "Process namespace escape" "BLOCK"
}

test_network_namespace_escape() {
    if docker exec "$CONTAINER_NAME" nsenter --net=1 ip addr; then
        record_probe_result "Network namespace escape" "SUCCESSFUL"
        return 0
    fi
    record_probe_result "Network namespace escape" "BLOCK"
}

test_capability_escalation() {
    if docker exec "$CONTAINER_NAME" capsh --caps; then
        record_probe_result "Capability escalation" "SUCCESSFUL"
        return 0
    fi
    record_probe_result "Capability escalation" "BLOCK"
}

cleanup_test_resources() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
    rm -rf -- "$WORK_DIR"
}

main() {
    : > "$RESULT_FILE"

    printf -- '--- %s ---\n' "$TEST_NAME"
    printf 'Timestamp: %s\n' "$TIMESTAMP"
    printf 'Result file: %s\n' "$RESULT_FILE"

    create_test_container
    test_mount_namespace_escape
    test_process_namespace_escape
    test_network_namespace_escape
    test_capability_escalation

    printf -- '--- Container escape test complete ---\n'
    printf 'Results saved to: %s\n' "$RESULT_FILE"
}

main "$@"
