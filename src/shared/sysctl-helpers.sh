#!/bin/bash

if [ -n "${SYSCTL_HELPERS_LOADED:-}" ]; then
    return 0
fi
readonly SYSCTL_HELPERS_LOADED=1

if ! declare -F log_warn >/dev/null 2>&1; then
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/log-pipe.sh"
fi

read_saved_sysctl_value() {
    local snapshot_file="$1"
    local sysctl_key="$2"

    [ -f "$snapshot_file" ] || return 1

    awk -v target="$sysctl_key" '
        index($0, target " = ") == 1 {
            value = substr($0, length(target) + 4)
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "$snapshot_file"
}

restore_saved_sysctl_value() {
    local snapshot_file="$1"
    local sysctl_key="$2"
    local saved_value=""

    saved_value="$(read_saved_sysctl_value "$snapshot_file" "$sysctl_key")"
    if [ -z "$saved_value" ]; then
        log_warn "Could not restore ${sysctl_key}; saved value is unavailable"
        return 1
    fi

    sysctl -w "${sysctl_key}=${saved_value}" 2>/dev/null || true
}
