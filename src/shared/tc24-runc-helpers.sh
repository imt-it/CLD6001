#!/bin/bash

if [ -n "${TC24_RUNC_HELPERS_LOADED:-}" ]; then
    return 0
fi
readonly TC24_RUNC_HELPERS_LOADED=1

tc24_collect_runc_proc_matches() {
    local runtime_cmd="$1"
    local container_name="$2"

    "$runtime_cmd" exec "$container_name" sh -c '
        find /proc -name exe -type l 2>/dev/null | xargs -I {} readlink {} 2>/dev/null | grep -i runc || true
    ' 2>&1 || true
}

tc24_collect_self_exe_path() {
    local runtime_cmd="$1"
    local container_name="$2"

    "$runtime_cmd" exec "$container_name" sh -c '
        readlink /proc/self/exe 2>/dev/null || echo "Could not read /proc/self/exe"
    ' 2>&1 || true
}

tc24_probe_runc_accessibility() {
    local runtime_cmd="$1"
    local container_name="$2"
    local runc_matches=""
    local self_exe_output=""

    runc_matches="$(tc24_collect_runc_proc_matches "$runtime_cmd" "$container_name")"
    self_exe_output="$(tc24_collect_self_exe_path "$runtime_cmd" "$container_name")"

    printf '%s\n' "Looking for runc in /proc..."
    if [ -n "$runc_matches" ]; then
        printf '%s\n' "$runc_matches"
    else
        printf 'runc not found in /proc\n'
    fi
    printf '\n'
    printf '%s\n' "Checking /proc/self/exe..."
    printf '%s\n' "$self_exe_output"

    [ -n "$runc_matches" ]
}
