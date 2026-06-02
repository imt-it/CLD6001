#!/bin/bash

CLD6001_RUN_METADATA_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CLD6001_RUN_METADATA_SAVED_OPTIONS="$(set +o)"

set -Eeuo pipefail

source "$CLD6001_RUN_METADATA_ROOT/src/execute/run-context.sh"
eval "$CLD6001_RUN_METADATA_SAVED_OPTIONS"
unset CLD6001_RUN_METADATA_SAVED_OPTIONS

cld6001_validate_run_kind() {
    case "${1:-}" in
        full|partial)
            return 0
            ;;
        *)
            printf 'Invalid run kind: %s\n' "${1:-}" >&2
            return 1
            ;;
    esac
}

cld6001_new_run_id() {
    local run_kind="${1:-}"
    local generated_run_id=""

    if ! cld6001_validate_run_kind "$run_kind"; then
        return 1
    fi

    generated_run_id="$(cld6001_generate_run_id)" || return 1
    printf '%s-%s\n' "$run_kind" "$generated_run_id"
}
