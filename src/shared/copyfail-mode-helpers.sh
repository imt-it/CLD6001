#!/bin/bash

if [ -n "${COPYFAIL_MODE_HELPERS_LOADED:-}" ]; then
    return 0
fi
readonly COPYFAIL_MODE_HELPERS_LOADED=1

readonly CLD6001_COPYFAIL_DEFAULT_MODE="reversible"
readonly CLD6001_COPYFAIL_REVERSIBLE_PAYLOAD="resources/exploits/cve2026_31431_reversible/copy_fail_exp_reversible.py"

cld6001_copyfail_validate_mode() {
    case "${1:-}" in
        reversible)
            return 0
            ;;
        *)
            printf 'Invalid Copy Fail mode: %s\n' "${1:-}" >&2
            return 1
            ;;
    esac
}

cld6001_copyfail_resolve_mode() {
    local requested_mode="${1:-${RUNNER_COPYFAIL_MODE:-$CLD6001_COPYFAIL_DEFAULT_MODE}}"

    [ -n "$requested_mode" ] || requested_mode="$CLD6001_COPYFAIL_DEFAULT_MODE"
    cld6001_copyfail_validate_mode "$requested_mode" || return 1
    printf '%s\n' "$requested_mode"
}

cld6001_copyfail_payload_relative_path() {
    case "$(cld6001_copyfail_resolve_mode "${1:-}")" in
        reversible)
            printf '%s\n' "$CLD6001_COPYFAIL_REVERSIBLE_PAYLOAD"
            ;;
    esac
}

cld6001_copyfail_resolve_payload_path() {
    local relative_path=""
    relative_path="$(cld6001_copyfail_payload_relative_path "${1:-}")" || return 1

    if declare -F resolve_source_repo_path >/dev/null 2>&1; then
        resolve_source_repo_path "$relative_path"
        return $?
    fi

    if [ -n "${REPO_ROOT:-}" ]; then
        printf '%s\n' "$REPO_ROOT/$relative_path"
        return 0
    fi

    printf '%s\n' "$relative_path"
}

cld6001_copyfail_effective_mode() {
    case "$(cld6001_copyfail_resolve_mode "${1:-}")" in
        reversible) printf 'reversible\n' ;;
    esac
}

cld6001_copyfail_executed_payload_relative_path() {
    cld6001_copyfail_payload_relative_path "$(cld6001_copyfail_effective_mode "${1:-}")"
}

cld6001_copyfail_fallback_reason() {
    case "$(cld6001_copyfail_resolve_mode "${1:-}")" in
        reversible) printf '' ;;
    esac
}

cld6001_copyfail_mode_summary() {
    case "$(cld6001_copyfail_resolve_mode "${1:-}")" in
        reversible)
            printf '%s\n' 'reversible (active reversible automation path on this branch)'
            ;;
    esac
}
