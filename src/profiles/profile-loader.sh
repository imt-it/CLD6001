#!/bin/bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$REPO_ROOT/src/profiles/profile-adapter.sh"

cld6001_profile_file_for() {
    profile_file_for "$1"
}

cld6001_load_profile_json() {
    load_profile_json "$1"
}

cld6001_profile_value() {
    profile_value "$1" "$2"
}

cld6001_profile_supports() {
    profile_supports "$1" "$2" "$3"
}

cld6001_profile_results_slug() {
    profile_results_slug "$1"
}

cld6001_profile_allows_overlay() {
    profile_allows_overlay "$1" "$2"
}
