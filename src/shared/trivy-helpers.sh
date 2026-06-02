#!/bin/bash

if [ -n "${TRIVY_HELPERS_LOADED:-}" ]; then
    return 0
fi
readonly TRIVY_HELPERS_LOADED=1

cld6001_trivy_log_error() {
    printf 'trivy wrapper error: %s\n' "$*" >&2
}

cld6001_trivy_container_image() {
    printf '%s\n' "${TRIVY_CONTAINER_IMAGE:-docker.io/aquasec/trivy:latest}"
}

cld6001_trivy_runtime_root() {
    if [ -n "${HOST_PROBE_TMP_DIR:-}" ]; then
        printf '%s\n' "${HOST_PROBE_TMP_DIR%/}"
        return 0
    fi

    if [ -n "${CLD6001_TRIVY_TMP_ROOT:-}" ]; then
        printf '%s\n' "${CLD6001_TRIVY_TMP_ROOT%/}"
        return 0
    fi

    if [ -e "./temp-work" ]; then
        printf '%s\n' "$(pwd -P)/temp-work"
        return 0
    fi

    printf '%s\n' "/var/tmp/cld6001"
}

cld6001_trivy_cache_dir() {
    if [ -n "${TRIVY_CACHE_DIR:-}" ]; then
        printf '%s\n' "${TRIVY_CACHE_DIR%/}"
        return 0
    fi

    if [ -n "${XDG_CACHE_HOME:-}" ]; then
        printf '%s\n' "${XDG_CACHE_HOME%/}/trivy"
        return 0
    fi

    if [ -n "${HOME:-}" ]; then
        printf '%s\n' "${HOME%/}/.cache/trivy"
        return 0
    fi

    printf '%s\n' "$(cld6001_trivy_runtime_root)/trivy-cache"
}

cld6001_trivy_resolve_runtime() {
    local requested_runtime="${1:-${CONTAINER_RUNTIME:-}}"

    if [ -n "$requested_runtime" ]; then
        if command -v "$requested_runtime" >/dev/null 2>&1; then
            printf '%s\n' "$requested_runtime"
            return 0
        fi
        cld6001_trivy_log_error "Requested runtime '$requested_runtime' is not available"
        return 1
    fi

    if command -v docker >/dev/null 2>&1; then
        printf 'docker\n'
        return 0
    fi

    if command -v podman >/dev/null 2>&1; then
        printf 'podman\n'
        return 0
    fi

    cld6001_trivy_log_error "Neither docker nor podman is available"
    return 1
}

cld6001_trivy_prepare_cache_dir() {
    local cache_dir=""
    local fallback_dir=""

    cache_dir="$(cld6001_trivy_cache_dir)" || return 1
    if ! mkdir -p -- "$cache_dir" 2>/dev/null; then
        fallback_dir="$(cld6001_trivy_runtime_root)/trivy-cache" || return 1
        mkdir -p -- "$fallback_dir" || return 1
        cache_dir="$fallback_dir"
    fi
    export TRIVY_CACHE_DIR="$cache_dir"
    printf '%s\n' "$cache_dir"
}

cld6001_trivy_create_scan_archive() {
    local runtime="$1"
    local image_ref="$2"
    local tmp_root="$3"
    local scan_input=""

    mkdir -p -- "$tmp_root"
    scan_input="$(mktemp "${tmp_root%/}/trivy-input-XXXXXX")" || return 1
    if ! "$runtime" save -o "$scan_input" "$image_ref" >/dev/null; then
        rm -f -- "$scan_input"
        return 1
    fi
    printf '%s\n' "$scan_input"
}

cld6001_trivy_bind_mount_arg() {
    local runtime="$1"
    local runtime_name="${runtime##*/}"
    local source_path="$2"
    local target_path="$3"
    local mount_mode="${4:-}"
    local mount_spec="${source_path}:${target_path}"

    if [ -n "$mount_mode" ]; then
        mount_spec="${mount_spec}:${mount_mode}"
    fi

    if [ "$runtime_name" = "podman" ]; then
        if [ -n "$mount_mode" ]; then
            mount_spec="${mount_spec},Z"
        else
            mount_spec="${mount_spec}:Z"
        fi
    fi

    printf '%s\n' "$mount_spec"
}

cld6001_trivy_run_saved_image() {
    local runtime="$1"
    local scan_input="$2"
    local cache_dir="$3"
    local trivy_image=""
    local -a runtime_args=()

    shift 3

    trivy_image="$(cld6001_trivy_container_image)" || return 1
    mkdir -p -- "$cache_dir"

    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--" ]; then
            shift
            break
        fi
        runtime_args+=("$1")
        shift
    done

    "$runtime" run --rm \
        "${runtime_args[@]}" \
        -v "$(cld6001_trivy_bind_mount_arg "$runtime" "$scan_input" "/scan-input.tar" "ro")" \
        -v "$(cld6001_trivy_bind_mount_arg "$runtime" "$cache_dir" "/trivy-cache")" \
        -e TRIVY_CACHE_DIR=/trivy-cache \
        "$trivy_image" image --input /scan-input.tar "$@"
}
