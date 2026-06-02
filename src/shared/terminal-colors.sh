#!/bin/bash

if [ -n "${TERMINAL_COLORS_LOADED:-}" ]; then
    return 0
fi
readonly TERMINAL_COLORS_LOADED=1

readonly COLOR_INFO='\033[0;90m'
readonly COLOR_SUCCESS='\033[0;32m'
readonly COLOR_WARN='\033[1;33m'
readonly COLOR_BLOCK='\033[0;35m'
readonly COLOR_ERROR='\033[38;5;208m'
readonly COLOR_FAIL='\033[0;31m'
readonly COLOR_RESET='\033[0m'

readonly RED="$COLOR_FAIL"
readonly GREEN="$COLOR_SUCCESS"
readonly YELLOW="$COLOR_WARN"
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC="$COLOR_RESET"

terminal_normalize_level() {
    case "${1^^}" in
        INFO)
            printf 'INFO\n'
            ;;
        OK|SUCCESS)
            printf 'OK\n'
            ;;
        PASS)
            printf 'PASS\n'
            ;;
        WARN|WARNING)
            printf 'WARN\n'
            ;;
        BLOCK)
            printf 'BLOCK\n'
            ;;
        ERROR)
            printf 'ERROR\n'
            ;;
        FAIL|FAILED|FAILURE)
            printf 'FAIL\n'
            ;;
        *)
            printf '%s\n' "${1^^}"
            ;;
    esac
}

terminal_color_for_level() {
    case "$(terminal_normalize_level "$1")" in
        INFO)  printf '%s' "$COLOR_INFO" ;;
        OK)    printf '%s' "$COLOR_SUCCESS" ;;
        PASS)  printf '%s' "$COLOR_SUCCESS" ;;
        WARN)  printf '%s' "$COLOR_WARN" ;;
        BLOCK) printf '%s' "$COLOR_BLOCK" ;;
        ERROR) printf '%s' "$COLOR_ERROR" ;;
        FAIL)  printf '%s' "$COLOR_FAIL" ;;
        *)     printf '%s' "$COLOR_RESET" ;;
    esac
}

terminal_emit() {
    local level=""
    local color=""

    level="$(terminal_normalize_level "$1")"
    shift
    color="$(terminal_color_for_level "$level")"
    printf '%b[%s] %s%b\n' "$color" "$level" "$*" "$COLOR_RESET"
}

terminal_emit_scoped() {
    local scope="$1"
    local level=""
    local color=""

    shift
    level="$(terminal_normalize_level "$1")"
    shift
    color="$(terminal_color_for_level "$level")"
    printf '%b[%s][%s] %s%b\n' "$color" "$scope" "$level" "$*" "$COLOR_RESET"
}

info()  { terminal_emit INFO "$@"; }
ok()    { terminal_emit OK "$@"; }
pass()  { terminal_emit PASS "$@"; }
warn()  { terminal_emit WARN "$@" >&2; }
block() { terminal_emit BLOCK "$@" >&2; }
error() { terminal_emit ERROR "$@" >&2; }
fail()  { terminal_emit FAIL "$@" >&2; }
