#!/bin/bash

if [ -n "${STORAGE_DRIVER_HELPERS_LOADED:-}" ]; then
    return 0
fi
readonly STORAGE_DRIVER_HELPERS_LOADED=1

cld6001_expected_storage_driver() {
    local runtime_id="${1:-}"

    case "$runtime_id" in
        docker-rootful)
            printf '%s\n' 'overlay2'
            ;;
        docker-rootless)
            printf '%s\n' 'fuse-overlayfs'
            ;;
        podman-rootful|podman-rootless)
            printf '%s\n' 'overlay'
            ;;
        *)
            printf 'Unknown storage-driver runtime: %s\n' "$runtime_id" >&2
            return 1
            ;;
    esac
}

cld6001_storage_driver_matches() {
    local runtime_id="$1"
    local current_driver="$2"
    local expected_driver=""

    expected_driver="$(cld6001_expected_storage_driver "$runtime_id")" || return 1
    case "$runtime_id:$current_driver" in
        docker-rootful:overlayfs|docker-rootless:overlayfs)
            [ "$expected_driver" = "overlay2" ]
            return
            ;;
    esac
    [ "$current_driver" = "$expected_driver" ]
}
