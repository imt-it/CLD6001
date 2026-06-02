#!/bin/bash
set -Eeuo pipefail

cld6001_console_banner() {
    local env_state="${2:--}"
    local collection="${3:--}"
    local message="${4:?message required}"
    printf '[%s] [%s] %s\n' "$env_state" "$collection" "$message"
}
