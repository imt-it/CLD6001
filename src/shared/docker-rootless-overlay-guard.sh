#!/bin/bash

if [ -n "${CLD6001_DOCKER_ROOTLESS_OVERLAY_GUARD_LOADED:-}" ]; then
    return 0
fi
readonly CLD6001_DOCKER_ROOTLESS_OVERLAY_GUARD_LOADED=1

cld6001_running_inside_container() {
    case "${CLD6001_FORCE_CONTAINER_ENV:-}" in
        true) return 0 ;;
        false) return 1 ;;
    esac

    [ -f "/.dockerenv" ] && return 0
    [ -f "/run/.containerenv" ] && return 0
    grep -Eqs '/(docker|containerd|kubepods|libpod|podman)/' /proc/1/cgroup 2>/dev/null
}

cld6001_is_docker_rootless_overlay_mount_failure() {
    local output="${1:-}"

    grep -Eqi '(overlay[^[:cntrl:]]*no such device|failed to mount overlay|error creating overlay mount)' <<<"$output"
}

cld6001_run_docker_rootless_with_nested_overlay_guard() {
    local testcase_id="${1:?testcase id required}"
    local adapter_path="${2:?adapter path required}"
    shift 2

    local output=""
    local status=0

    set +e
    output="$(
        /bin/bash "$adapter_path" "$@" 2>&1
    )"
    status=$?
    set -e

    [ -z "$output" ] || printf '%s\n' "$output"

    if [ "$status" -ne 0 ] && \
       cld6001_running_inside_container && \
       cld6001_is_docker_rootless_overlay_mount_failure "$output"; then
        printf 'BLOCK: docker-rootless nested overlay mounts are unsupported for %s in this containerized environment\n' "$testcase_id"
        return 3
    fi

    return "$status"
}
