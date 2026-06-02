#!/bin/bash

if [ -n "${FILESYSTEM_HELPERS_LOADED:-}" ]; then
    return 0
fi
readonly FILESYSTEM_HELPERS_LOADED=1

remove_matching_paths_if_any() {
    local path_pattern="$1"
    local -a matching_paths=()

    mapfile -t matching_paths < <(compgen -G "$path_pattern")
    if [ "${#matching_paths[@]}" -gt 0 ]; then
        rm -rf -- "${matching_paths[@]}"
    fi
}
