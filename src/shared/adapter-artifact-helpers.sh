#!/bin/bash

cld6001_mirror_artifacts_now() {
    local _dir_var="${1:?artifact dir variable name required}"
    local _target_dir="${!_dir_var}"
    [ -n "$_target_dir" ] && [ "$_target_dir" != "${RESULTS_DIR:-}" ] || return 0
    mkdir -p "$_target_dir"
    cp -a "${RESULTS_DIR}/." "$_target_dir/" 2>/dev/null || true
}

cld6001_mirror_artifacts_on_exit() {
    _cld6001_artifacts_dir_var="${1:?artifacts dir variable name required}"
    _cld6001_artifact_label="${2:-artifact}"

    _cld6001_mirror_artifacts() {
        local target_dir="${!_cld6001_artifacts_dir_var}"
        [ -n "$target_dir" ] && [ "$target_dir" != "$RESULTS_DIR" ] || return 0
        mkdir -p "$target_dir"
        cp -a "${RESULTS_DIR}/." "$target_dir/"
    }

    _cld6001_artifact_cleanup_on_exit() {
        local exit_status=$?
        if ! _cld6001_mirror_artifacts; then
            echo "$_cld6001_artifact_label mirroring failed" >&2
            if [ $exit_status -eq 0 ]; then exit_status=1; fi
        fi
        exit "$exit_status"
    }

    trap _cld6001_artifact_cleanup_on_exit EXIT
}
