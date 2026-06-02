#!/bin/bash

if [ -n "${STRING_HELPERS_LOADED:-}" ]; then
    return 0
fi
readonly STRING_HELPERS_LOADED=1

cld6001_to_lower() {
    printf '%s' "${1:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}
