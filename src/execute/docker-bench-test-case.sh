#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$REPO_ROOT/src/shared/docker-bench-helpers.sh"

TEST_NAME="Docker Bench for Security Test Case"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULT_FILE="${RESULT_FILE:-${TEST_RESULTS_DIR:-.}/docker-bench-results.txt}"
JSON_RESULT_FILE="${JSON_RESULT_FILE:-${TEST_RESULTS_DIR:-.}/docker-bench-results.json}"

write_result_header() {
    cat > "$RESULT_FILE" <<EOF
--- ${TEST_NAME} ---
Timestamp: ${TIMESTAMP}
Test Description: Assess Docker security configuration
---
EOF
}

count_severity() {
    count_docker_bench_level "$JSON_RESULT_FILE" "$1"
}

run_docker_bench() {
    local critical=""
    local high=""
    local medium=""
    local low=""
    run_docker_bench_capture "$JSON_RESULT_FILE"

    critical="$(count_severity "CRITICAL")"
    high="$(count_severity "HIGH")"
    medium="$(count_severity "MEDIUM")"
    low="$(count_severity "LOW")"

    {
        printf -- '--- Docker Bench Results ---\n'
        printf 'Critical: %s\n' "$critical"
        printf 'High: %s\n' "$high"
        printf 'Medium: %s\n' "$medium"
        printf 'Low: %s\n' "$low"
    } >> "$RESULT_FILE"
}

main() {
    printf -- '--- %s ---\n' "$TEST_NAME"
    printf 'Timestamp: %s\n' "$TIMESTAMP"
    printf 'Result file: %s\n' "$RESULT_FILE"

    write_result_header
    run_docker_bench

    printf -- '--- Docker Bench test complete ---\n'
    printf 'Results saved to: %s\n' "$RESULT_FILE"
}

main "$@"
