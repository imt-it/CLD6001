#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../../src/shared/string-helpers.sh"

usage() {
    cat <<'EOF'
Usage: bash src/collect/backup-evidence.sh --source PATH [--destination PATH]

Copy evidence into a local destination.
Windows-style local paths are normalized automatically.

Options:
  --source PATH        Required. Local source path.
  --destination PATH   Optional. Local destination path (defaults to temp-work/<CLD6001_RUN_ID>/backup).
  --help               Show this help text.

Environment:
  CLD6001_RUN_ID       Required. Used to derive the default backup destination.
EOF
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

normalize_local_path() {
    local path="$1"
    local drive_letter=""
    local remainder=""
    local drive_lower=""

    case "$path" in
        [A-Za-z]:[\\/]*)
        if command -v cygpath >/dev/null 2>&1; then
            cygpath -u "$path"
            return 0
        fi

        drive_letter="${path:0:1}"
        drive_lower="$(cld6001_to_lower "$drive_letter")"
        remainder="${path:2}"
        remainder="${remainder//\\//}"
        remainder="${remainder#/}"

        if [ -d "/mnt/$drive_lower" ]; then
            printf '/mnt/%s/%s' "$drive_lower" "$remainder"
            return 0
        fi

        printf '/%s/%s' "$drive_lower" "$remainder"
        return 0
        ;;
    esac

    printf '%s' "$path"
}

destination_has_entries() {
    local destination_path="$1"
    [ -d "$destination_path" ] && find "$destination_path" -mindepth 1 -print -quit | grep -q .
}

RUN_ID="${CLD6001_RUN_ID:-}"
[ -n "$RUN_ID" ] || fail "CLD6001_RUN_ID is required"
source_path=""
destination_path="${REPO_ROOT}/temp-work/${RUN_ID}/backup"

while [ $# -gt 0 ]; do
    case "$1" in
        --source)
            [ $# -ge 2 ] || fail "Missing value for --source"
            source_path="$2"
            shift 2
            ;;
        --destination)
            [ $# -ge 2 ] || fail "Missing value for --destination"
            destination_path="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

[ -n "$source_path" ] || fail "--source is required"
[ -n "$destination_path" ] || fail "--destination is required"

local_destination_path="$(normalize_local_path "$destination_path")"
local_source_path="$(normalize_local_path "$source_path")"

if [ -e "$local_destination_path" ] && [ ! -d "$local_destination_path" ]; then
    fail "Destination is not a directory: $local_destination_path"
fi

if destination_has_entries "$local_destination_path"; then
    fail "Refusing to merge into non-empty destination: $local_destination_path"
fi

mkdir -p "$local_destination_path"
cp -R "$local_source_path" "$local_destination_path"
