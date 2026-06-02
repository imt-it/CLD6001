#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$REPO_ROOT/src/collect/snapshots/snapshot-lib.sh"

TEST_NAME="Baseline Test Case 1: Initial System Snapshot"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_FILE="${RESULT_FILE:-${TEST_RESULTS_DIR:-.}/baseline_results.txt}"

write_result_header() {
    cat > "$RESULT_FILE" <<EOF
--- ${TEST_NAME} ---
Timestamp: ${TIMESTAMP}
Test Description: Initial system snapshot for baseline research
---
EOF
}

append_section() {
    printf '%s\n' "$1" >> "$RESULT_FILE"
}

capture_system_info() {
    append_section "--- System Information ---"
    append_section "Operating System:"
    cat /etc/os-release >> "$RESULT_FILE" 2>/dev/null || append_section "OS release not found"
    append_section "Kernel Version:"
    uname -r >> "$RESULT_FILE"
    append_section "CPU Information:"
    lscpu >> "$RESULT_FILE" 2>/dev/null || append_section "CPU info not available"
    append_section "Memory Information:"
    free -h >> "$RESULT_FILE"
    append_section "Disk Usage:"
    df -h >> "$RESULT_FILE"
    append_section "Network Interfaces:"
    ip addr show >> "$RESULT_FILE"
}

capture_docker_info() {
    append_section "--- Docker Information ---"
    append_section "Docker Info:"
    docker info >> "$RESULT_FILE" 2>/dev/null || append_section "Docker info not available"
    append_section "Docker Version:"
    docker version >> "$RESULT_FILE" 2>/dev/null || append_section "Docker version not available"
    append_section "Running Containers:"
    docker ps -a >> "$RESULT_FILE" 2>/dev/null || append_section "Container list not available"
}

capture_security_config() {
    append_section "--- Security Configuration ---"
    if command -v sestatus >/dev/null 2>&1; then
        append_section "SELinux Status:"
        sestatus >> "$RESULT_FILE" 2>/dev/null || append_section "SELinux not available"
    else
        append_section "SELinux not available"
    fi
    append_section "Docker Security Configuration:"
    append_sanitized_docker_security_options "$RESULT_FILE"
}

main() {
    printf -- '--- %s ---\n' "$TEST_NAME"
    printf 'Timestamp: %s\n' "$TIMESTAMP"
    printf 'Result file: %s\n' "$RESULT_FILE"

    write_result_header
    capture_system_info
    capture_docker_info
    capture_security_config

    printf -- '--- Test complete ---\n'
    printf 'Results saved to: %s\n' "$RESULT_FILE"
}

main "$@"
