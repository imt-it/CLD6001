#!/bin/bash

set -Eeuo pipefail

declare -Ag ENVIRONMENT_STATE_TITLES=(
    ["baseline-system"]="Baseline AlmaLinux host + baseline container runtime"
    ["cis-system"]="CIS-hardened AlmaLinux host + CIS-hardened container runtime"
)

declare -Ag ENVIRONMENT_STATE_HOST_PROFILES=(
    ["baseline-system"]="baseline-host"
    ["cis-system"]="cis-rhel10"
)

declare -Ag ENVIRONMENT_STATE_RUNTIME_PROFILES=(
    ["baseline-system"]="baseline-defaults"
    ["cis-system"]="cis-hardened"
)

environment_state_keys() {
    printf '%s\n' \
        baseline-system \
        cis-system
}

environment_state_exists() {
    [ -n "${ENVIRONMENT_STATE_TITLES[$1]:-}" ]
}

environment_state_title_for() {
    printf '%s\n' "${ENVIRONMENT_STATE_TITLES[$1]}"
}

environment_state_host_profile_for() {
    printf '%s\n' "${ENVIRONMENT_STATE_HOST_PROFILES[$1]}"
}

environment_state_runtime_profile_for() {
    printf '%s\n' "${ENVIRONMENT_STATE_RUNTIME_PROFILES[$1]}"
}

cld6001_environment_states() {
    environment_state_keys
}

cld6001_environment_state_count() {
    environment_state_keys | wc -l | tr -d ' '
}
