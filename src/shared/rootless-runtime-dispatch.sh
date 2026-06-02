#!/bin/bash

set -Eeuo pipefail

cld6001_dispatch_rootless_runtime_command() {
    local -a env_pairs=()

    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        case "$1" in
            *=*)
                env_pairs+=("$1")
                ;;
            *)
                printf 'Invalid environment assignment for rootless dispatch: %s\n' "$1" >&2
                return 64
                ;;
        esac
        shift
    done

    [ $# -gt 0 ] && [ "$1" = "--" ] || {
        printf 'Rootless dispatch requires -- before the command\n' >&2
        return 64
    }
    shift

    [ $# -gt 0 ] || {
        printf 'Rootless dispatch requires a command\n' >&2
        return 64
    }

    exec env "${env_pairs[@]}" "$@"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cld6001_dispatch_rootless_runtime_command "$@"
fi
