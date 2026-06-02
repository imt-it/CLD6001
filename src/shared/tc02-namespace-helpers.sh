#!/bin/bash

tc02_write_header() {
    local runtime_label="$1"
    echo "--- TC02: Namespace Sharing Isolation Assessment ---"
    echo "Date: $(date -Iseconds)"
    echo "Runtime: ${runtime_label}"
    echo ""
}

tc02_assert_live_pid_helper() {
    local helper_pid="$1"
    kill -0 "$helper_pid" 2>/dev/null || {
        echo "Controlled host PID helper did not start with a live host PID"
        return 1
    }
}
