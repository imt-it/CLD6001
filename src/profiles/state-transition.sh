#!/bin/bash
set -Eeuo pipefail

cld6001_transition_environment_state() {
    local requested="${1:?environment state required}"
    case "$requested" in
        baseline-system|cis-system)
            printf '%s\n' "$requested"
            ;;
        *)
            printf 'Unknown environment state: %s\n' "$requested" >&2
            return 1
            ;;
    esac
}
