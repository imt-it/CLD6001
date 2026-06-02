#!/bin/bash

set -Eeuo pipefail

cld6001_require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        return 1
    }
}

cld6001_check_runtime_readiness() {
    cld6001_require_command bash
    cld6001_require_command jq
    cld6001_require_command python3
}
