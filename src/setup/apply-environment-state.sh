#!/bin/bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$REPO_ROOT/src/setup/preflight.sh"
source "$REPO_ROOT/src/profiles/environment-states.sh"
source "$REPO_ROOT/src/setup/runtime-readiness.sh"

CLD6001_PREFLIGHT_RESULTS_DIR=""

cld6001_runtime_is_supported() {
    case "$1" in
        docker-rootful|docker-rootless|podman-rootless) return 0 ;;
        *) return 1 ;;
    esac
}

cld6001_resolve_preflight_results_dir() {
    local state="$1"
    local runtime="$2"
    local results_dir="$3"

    if [ -n "${CLD6001_RUN_ROOT:-}" ]; then
        printf '%s/environment-state/%s/%s\n' "$CLD6001_RUN_ROOT" "$state" "$runtime"
    else
        printf '%s\n' "$results_dir"
    fi
}

cld6001_invocation_requires_preflight() {
    local action=""
    local state=""
    local runtime=""
    local results_dir=""
    CLD6001_PREFLIGHT_RESULTS_DIR=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --help)
                return 1
                ;;
            apply|verify|snapshot)
                [ -z "$action" ] || return 1
                action="$1"
                shift
                ;;
            --state)
                [ $# -ge 2 ] || return 1
                state="${2:-}"
                [ -n "$state" ] || return 1
                shift 2
                ;;
            --runtime)
                [ $# -ge 2 ] || return 1
                runtime="${2:-}"
                [ -n "$runtime" ] || return 1
                shift 2
                ;;
            --results-dir)
                [ $# -ge 2 ] || return 1
                results_dir="${2:-}"
                [ -n "$results_dir" ] || return 1
                shift 2
                ;;
            *)
                return 1
                ;;
        esac
    done

    [ -n "$action" ] || return 1
    [ -n "$state" ] || return 1
    [ -n "$runtime" ] || return 1
    [ -n "$results_dir" ] || return 1

    cld6001_environment_state_exists "$state" || return 1
    cld6001_runtime_is_supported "$runtime" || return 1
    CLD6001_PREFLIGHT_RESULTS_DIR="$(cld6001_resolve_preflight_results_dir "$state" "$runtime" "$results_dir")"
}

if cld6001_invocation_requires_preflight "$@"; then
    cld6001_preflight_resource_layout
    cld6001_preflight_disk_headroom "$CLD6001_PREFLIGHT_RESULTS_DIR"
    cld6001_check_runtime_readiness
fi

exec bash "$REPO_ROOT/src/setup/apply-state.sh" "$@"
