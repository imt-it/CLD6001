#!/bin/bash
set -Eeuo pipefail

cld6001_generate_random_hex() {
    local byte_count="${1:-8}"

    od -An -N"$byte_count" -tx1 /dev/urandom | tr -d ' \n'
}

cld6001_generate_timestamped_id() {
    local timestamp_format="${1:-%Y%m%d_%H%M%S}"
    local separator="${2:-_}"
    local byte_count="${3:-8}"
    local timestamp=""
    local random_hex=""

    timestamp="$(date +"$timestamp_format")"
    random_hex="$(cld6001_generate_random_hex "$byte_count")"
    printf '%s%s%s\n' "$timestamp" "$separator" "$random_hex"
}

cld6001_generate_run_id() {
    cld6001_generate_timestamped_id "%Y%m%d_%H%M%S" "_" 8
}

cld6001_validate_run_id() {
    printf '%s\n' "${1:-}" | grep -Eq '^[0-9]{8}_[0-9]{6}_[0-9a-f]{16}$'
}

cld6001_resolve_run_root() {
    local results_root="$1"
    local run_id="$2"

    printf '%s/%s\n' "${results_root%/}" "$run_id"
}

cld6001_sanitize_path_component() {
    local raw_value="${1:-}"
    local sanitized_value="${raw_value//[^A-Za-z0-9._-]/-}"

    if [ -z "$sanitized_value" ]; then
        sanitized_value="default"
    fi

    printf '%s\n' "$sanitized_value"
}

cld6001_resolve_result_reason_path() {
    local target_dir="${1:-}"
    local reason_context="${2:-default}"
    local safe_context=""

    if [ -z "$target_dir" ]; then
        return 1
    fi

    safe_context="$(cld6001_sanitize_path_component "$reason_context")"
    printf '%s/result-reason-%s.json\n' "${target_dir%/}" "$safe_context"
}
