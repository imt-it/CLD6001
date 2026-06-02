#!/bin/bash

PASS_COUNT=0
FAIL_COUNT=0

cld6001_record_result() {
    local test_name="$1"
    local result="$2"
    local timestamp=""

    timestamp="$(date -Iseconds)"
    printf '%s | %s | %s\n' "$timestamp" "$test_name" "$result" >> "$RESULTS_DIR/test-results.txt"

    if [ "$result" = "PASS" ]; then
        ((PASS_COUNT+=1))
    else
        ((FAIL_COUNT+=1))
    fi
}
