#!/bin/bash

tc15_create_host_helper_bundle() {
    local helper_prefix="$1"
    HOST_HELPER_DIR="$(create_host_probe_dir "$helper_prefix")"
    mkdir -p "$HOST_HELPER_DIR/protected"
    printf 'simulated-shadow\n' > "$HOST_HELPER_DIR/protected/mock-shadow"
    if sudo -n chown root:root "$HOST_HELPER_DIR/protected/mock-shadow" 2>/dev/null && \
       sudo -n chmod 000 "$HOST_HELPER_DIR/protected/mock-shadow" 2>/dev/null; then
        HOST_HELPER_REQUIRES_SUDO=true
        return 0
    fi

    echo "BLOCK: host-root helper setup requires non-interactive sudo"
    return 3
}

tc15_validate_user_namespace_protection() {
    local mapping_output="$1"
    local privilege_output="$2"
    local escape_output="$3"
    local mapping_reduced=0
    local privilege_blocked=0
    local escape_blocked=0

    mapping_reduced="$(printf '%s\n' "$mapping_output" | grep -c "Host-root equivalence: REDUCED" || true)"
    privilege_blocked="$(printf '%s\n' "$privilege_output" | grep -c "helper protected file: BLOCK" || true)"
    escape_blocked="$(printf '%s\n' "$escape_output" | grep -Ec 'nested namespace helper access: BLOCK|namespace creation: BLOCK' || true)"

    if [ "$mapping_reduced" -gt 0 ] && [ "$privilege_blocked" -gt 0 ] && [ "$escape_blocked" -gt 0 ]; then
        echo "RESULT: PASS - user namespace protection demonstrated"
        return 0
    fi

    echo "RESULT: FAIL - user namespace protection not demonstrated"
    echo "Expected: the chosen user-namespace mode reduces host-root equivalence and keeps controlled helper access blocked"
    return 1
}
