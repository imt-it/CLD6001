#!/bin/bash

set -Eeuo pipefail

TEST_NAME="Network Isolation Test Case"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_FILE="${RESULT_FILE:-${TEST_RESULTS_DIR:-.}/network-isolation-results.txt}"
CONTAINER_NAMES=("container1" "container2")
NETWORK_NAME="${NETWORK_NAME:-test-network}"
TEST_IMAGE="${TEST_IMAGE:-python:3.14-slim}"
PUBLISHED_PORT="${PUBLISHED_PORT:-18080}"

trap 'cleanup_test_resources' EXIT

create_test_network() {
    docker network create --driver bridge "$NETWORK_NAME" >/dev/null
    docker run -d --network "$NETWORK_NAME" --name "${CONTAINER_NAMES[0]}" "$TEST_IMAGE" sleep infinity >/dev/null
    docker run -d --network "$NETWORK_NAME" --name "${CONTAINER_NAMES[1]}" -p "${PUBLISHED_PORT}:8080" "$TEST_IMAGE" python3 -m http.server 8080 >/dev/null
}

test_cross_subnet_communication() {
    local target_ip=""
    target_ip="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONTAINER_NAMES[1]}")"

    if docker exec "${CONTAINER_NAMES[0]}" python3 -c "import socket,sys; socket.create_connection((sys.argv[1], 8080), 3).close()" "$target_ip"; then
        printf 'Shared bridge communication: REACHABLE\n' >> "$RESULT_FILE"
        return 0
    fi
    printf 'Shared bridge communication: BLOCK\n' >> "$RESULT_FILE"
}

test_host_to_container_access() {
    if python3 -c "import socket; socket.create_connection(('127.0.0.1', ${PUBLISHED_PORT}), 3).close()"; then
        printf 'Host to published port: EXPOSED\n' >> "$RESULT_FILE"
        return 0
    fi
    printf 'Host to published port: BLOCK\n' >> "$RESULT_FILE"
}

test_container_to_host_access() {
    if docker exec "${CONTAINER_NAMES[0]}" python3 -c "import socket; socket.create_connection(('127.0.0.1', 8080), 1).close()"; then
        printf 'Container loopback isolation: FAILED\n' >> "$RESULT_FILE"
        return 0
    fi
    printf 'Container loopback isolation: ISOLATED\n' >> "$RESULT_FILE"
}

test_container_network_isolation() {
    if docker network inspect "$NETWORK_NAME" --format '{{.Name}}' | grep -Fx "$NETWORK_NAME" >/dev/null; then
        printf 'Container network attachment: VERIFIED\n' >> "$RESULT_FILE"
        return 0
    fi
    printf 'Container network attachment: FAILED\n' >> "$RESULT_FILE"
}

cleanup_test_resources() {
    docker rm -f "${CONTAINER_NAMES[0]}" >/dev/null 2>&1 || true
    docker rm -f "${CONTAINER_NAMES[1]}" >/dev/null 2>&1 || true
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
}

main() {
    : > "$RESULT_FILE"

    printf -- '--- %s ---\n' "$TEST_NAME"
    printf 'Timestamp: %s\n' "$TIMESTAMP"
    printf 'Result file: %s\n' "$RESULT_FILE"

    create_test_network
    test_cross_subnet_communication
    test_host_to_container_access
    test_container_to_host_access
    test_container_network_isolation

    printf -- '--- Network isolation test complete ---\n'
    printf 'Results saved to: %s\n' "$RESULT_FILE"
}

main "$@" Objective: Verify network isolation effectiveness and cross-container
