#!/bin/bash

set -Eeuo pipefail

PROFILE_ADAPTER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROFILE_REPO_ROOT="$(cd -- "$PROFILE_ADAPTER_DIR/../.." && pwd -P)"

is_valid_profile_name() {
    local -r profile_name="${1:-}"
    printf '%s\n' "$profile_name" | grep -Eq '^[a-z0-9][a-z0-9-]*$'
}

profile_file_for() {
    local -r profile_name="$1"

    is_valid_profile_name "$profile_name" || return 1
    printf '%s/resources/fixtures/%s.json\n' "$PROFILE_REPO_ROOT" "$profile_name"
}

load_profile_json() {
    local -r profile_name="$1"

    local profile_path=""
    if ! profile_path="$(profile_file_for "$profile_name")"; then
        printf 'Unknown profile: %s\n' "$profile_name" >&2
        return 1
    fi
    local -r profile_path

    if [ ! -f "$profile_path" ]; then
        printf 'Unknown profile: %s\n' "$profile_name" >&2
        return 1
    fi

    jq -ce . "$profile_path"
}

profile_value() {
    local -r profile_json="$1"
    local -r jq_path="$2"

    jq -r "$jq_path" <<<"$profile_json"
}

profile_supports() {
    local -r profile_json="$1"
    local -r runtime="$2"
    local -r mode="$3"

    jq -r --arg runtime "$runtime" --arg mode "$mode" \
        '.support[$runtime][$mode] // false' <<<"$profile_json"
}

profile_results_slug() {
    local -r profile_json="$1"
    profile_value "$profile_json" '.metadata.results_slug'
}

profile_allows_overlay() {
    local -r profile_json="$1"
    local -r overlay_name="$2"

    jq -e --arg overlay_name "$overlay_name" \
        '(.research_overlays // []) | index($overlay_name) != null' <<<"$profile_json" >/dev/null
}
