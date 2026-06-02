#!/bin/bash

if [ -n "${CLD6001_NONINTERACTIVE_RUNTIME_LOADED:-}" ]; then
    return 0
fi
readonly CLD6001_NONINTERACTIVE_RUNTIME_LOADED=1

cld6001_noninteractive_requested() {
    case "${CLD6001_NONINTERACTIVE:-}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

cld6001_enable_noninteractive_mode() {
    export CLD6001_NONINTERACTIVE=1
}

cld6001_detach_stdin_to_devnull() {
    cld6001_enable_noninteractive_mode
    exec </dev/null
}

cld6001_sudo_refresh() {
    local context="${1:-current command}"

    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi

    if sudo -n true 2>/dev/null; then
        return 0
    fi

    if cld6001_noninteractive_requested; then
        printf 'Non-interactive mode requires passwordless sudo before %s.\n' "$context" >&2
        return 1
    fi

    sudo -v
}
