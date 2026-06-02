#!/bin/bash

tc08_print_header() {
    local runtime_label="$1"
    echo "--- TC08: Capability Abuse Attacks ---"
    echo "Date: $(date -Iseconds)"
    echo "Runtime: ${runtime_label}"
    echo ""
}

tc09_validate_capability_reduction() {
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
