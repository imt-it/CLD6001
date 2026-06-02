#!/bin/bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$REPO_ROOT/src/profiles/environment-state-registry.sh"

cld6001_environment_state_keys() {
    environment_state_keys
}

cld6001_environment_state_exists() {
    environment_state_exists "$1"
}

cld6001_environment_state_title_for() {
    environment_state_title_for "$1"
}

cld6001_environment_state_host_profile_for() {
    environment_state_host_profile_for "$1"
}

cld6001_environment_state_runtime_profile_for() {
    environment_state_runtime_profile_for "$1"
}
