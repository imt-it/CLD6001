#!/bin/bash

if [ -n "${CLD6001_DISK_SPACE_HELPERS_LOADED:-}" ]; then
    return 0
fi
readonly CLD6001_DISK_SPACE_HELPERS_LOADED=1

readonly CLD6001_DEFAULT_DISK_HEADROOM_MIN_BYTES=50000000000

cld6001_clear_disk_space_context() {
    CLD6001_DISK_SPACE_REQUESTED_PATH=""
    CLD6001_DISK_SPACE_PROBE_PATH=""
    CLD6001_DISK_SPACE_RESOLVED_PATH=""
    CLD6001_DISK_SPACE_FILESYSTEM_SOURCE=""
    CLD6001_DISK_SPACE_FILESYSTEM_TARGET=""
    CLD6001_DISK_SPACE_AVAILABLE_BYTES=""
    CLD6001_DISK_SPACE_AVAILABLE_HUMAN=""
    CLD6001_DISK_SPACE_MINIMUM_BYTES=""
    CLD6001_DISK_SPACE_MINIMUM_HUMAN=""
    CLD6001_DISK_SPACE_ERROR=""
}

cld6001_format_disk_space_bytes() {
    local bytes="${1:-0}"

    LC_ALL=C awk -v bytes="$bytes" 'BEGIN { printf "%.2f GB", bytes / 1000 / 1000 / 1000 }'
}

cld6001_assign_disk_headroom_minimum() {
    local configured_minimum="$1"

    case "$configured_minimum" in
        ''|*[!0-9]*)
            CLD6001_DISK_SPACE_ERROR="invalid disk headroom minimum bytes: ${configured_minimum:-<empty>}"
            return 1
            ;;
    esac

    CLD6001_DISK_SPACE_MINIMUM_BYTES="$configured_minimum"
    CLD6001_DISK_SPACE_MINIMUM_HUMAN="$(cld6001_format_disk_space_bytes "$configured_minimum")"
}

cld6001_disk_headroom_min_bytes() {
    cld6001_assign_disk_headroom_minimum "${CLD6001_DISK_HEADROOM_MIN_BYTES:-$CLD6001_DEFAULT_DISK_HEADROOM_MIN_BYTES}" || return 1
    printf '%s\n' "$CLD6001_DISK_SPACE_MINIMUM_BYTES"
}

cld6001_resolve_disk_probe_path() {
    local requested_path="$1"
    local candidate_path="$requested_path"
    local parent_path=""

    [ -n "$requested_path" ] || {
        CLD6001_DISK_SPACE_ERROR="missing disk probe path"
        return 1
    }

    while [ ! -e "$candidate_path" ] && [ ! -L "$candidate_path" ]; do
        parent_path="$(dirname -- "$candidate_path")"
        if [ "$parent_path" = "$candidate_path" ]; then
            break
        fi
        candidate_path="$parent_path"
    done

    if [ ! -e "$candidate_path" ] && [ ! -L "$candidate_path" ]; then
        CLD6001_DISK_SPACE_REQUESTED_PATH="$requested_path"
        CLD6001_DISK_SPACE_ERROR="unable to resolve filesystem probe path"
        return 1
    fi

    printf '%s\n' "$candidate_path"
}

cld6001_collect_disk_space_context() {
    local requested_path="$1"
    local probe_path=""
    local resolved_path=""
    local resolved_path_source=""
    local resolved_probe_path=""
    local df_record=""
    local minimum_bytes="${CLD6001_DISK_SPACE_MINIMUM_BYTES:-}"
    local minimum_human="${CLD6001_DISK_SPACE_MINIMUM_HUMAN:-}"

    cld6001_clear_disk_space_context
    CLD6001_DISK_SPACE_MINIMUM_BYTES="$minimum_bytes"
    CLD6001_DISK_SPACE_MINIMUM_HUMAN="$minimum_human"
    CLD6001_DISK_SPACE_REQUESTED_PATH="$requested_path"

    probe_path="$(cld6001_resolve_disk_probe_path "$requested_path")" || return 1
    CLD6001_DISK_SPACE_PROBE_PATH="$probe_path"

    resolved_path_source="$probe_path"
    if [ ! -d "$probe_path" ]; then
        if resolved_probe_path="$(realpath -e -- "$probe_path" 2>/dev/null)" && [ -n "$resolved_probe_path" ]; then
            resolved_path_source="$(dirname -- "$resolved_probe_path")"
        else
            resolved_path_source="$(dirname -- "$probe_path")"
        fi
    fi

    resolved_path="$(cd -- "$resolved_path_source" 2>/dev/null && pwd -P)" || {
        CLD6001_DISK_SPACE_ERROR="failed to resolve filesystem probe path"
        return 1
    }
    CLD6001_DISK_SPACE_RESOLVED_PATH="$resolved_path"

    df_record="$(df -B1 --output=source,avail,target -- "$probe_path" 2>/dev/null | awk '
        NR == 2 {
            source = $1
            avail = $2
            $1 = ""
            $2 = ""
            sub(/^[[:space:]]+/, "")
            print source "\t" avail "\t" $0
        }
    ')"

    [ -n "$df_record" ] || {
        CLD6001_DISK_SPACE_ERROR="df returned no filesystem data"
        return 1
    }

    IFS=$'\t' read -r CLD6001_DISK_SPACE_FILESYSTEM_SOURCE CLD6001_DISK_SPACE_AVAILABLE_BYTES CLD6001_DISK_SPACE_FILESYSTEM_TARGET <<< "$df_record"

    case "$CLD6001_DISK_SPACE_AVAILABLE_BYTES" in
        ''|*[!0-9]*)
            CLD6001_DISK_SPACE_ERROR="df returned a non-numeric available-byte value"
            return 1
            ;;
    esac

    CLD6001_DISK_SPACE_AVAILABLE_HUMAN="$(cld6001_format_disk_space_bytes "$CLD6001_DISK_SPACE_AVAILABLE_BYTES")"
}

cld6001_disk_space_available_bytes() {
    cld6001_clear_disk_space_context
    cld6001_collect_disk_space_context "$1" || return 1
    printf '%s\n' "$CLD6001_DISK_SPACE_AVAILABLE_BYTES"
}

cld6001_enforce_disk_headroom() {
    local requested_path="$1"
    local minimum_bytes="${2:-}"

    cld6001_clear_disk_space_context
    CLD6001_DISK_SPACE_REQUESTED_PATH="$requested_path"

    if [ -n "$minimum_bytes" ]; then
        cld6001_assign_disk_headroom_minimum "$minimum_bytes" || return 1
    else
        minimum_bytes="${CLD6001_DISK_HEADROOM_MIN_BYTES:-$CLD6001_DEFAULT_DISK_HEADROOM_MIN_BYTES}"
        cld6001_assign_disk_headroom_minimum "$minimum_bytes" || return 1
    fi

    cld6001_collect_disk_space_context "$requested_path" || return 1

    if [ "$CLD6001_DISK_SPACE_AVAILABLE_BYTES" -lt "$minimum_bytes" ]; then
        CLD6001_DISK_SPACE_ERROR="insufficient free space"
        return 1
    fi

    return 0
}

cld6001_disk_space_summary() {
    local -a summary_parts=()
    local IFS='; '

    [ -n "${CLD6001_DISK_SPACE_REQUESTED_PATH:-}" ] && summary_parts+=("requested_path=${CLD6001_DISK_SPACE_REQUESTED_PATH}")
    [ -n "${CLD6001_DISK_SPACE_PROBE_PATH:-}" ] && summary_parts+=("probe_path=${CLD6001_DISK_SPACE_PROBE_PATH}")
    [ -n "${CLD6001_DISK_SPACE_RESOLVED_PATH:-}" ] && summary_parts+=("resolved_path=${CLD6001_DISK_SPACE_RESOLVED_PATH}")
    [ -n "${CLD6001_DISK_SPACE_FILESYSTEM_SOURCE:-}" ] && summary_parts+=("filesystem_source=${CLD6001_DISK_SPACE_FILESYSTEM_SOURCE}")
    [ -n "${CLD6001_DISK_SPACE_FILESYSTEM_TARGET:-}" ] && summary_parts+=("filesystem_target=${CLD6001_DISK_SPACE_FILESYSTEM_TARGET}")
    [ -n "${CLD6001_DISK_SPACE_AVAILABLE_BYTES:-}" ] && summary_parts+=("available_bytes=${CLD6001_DISK_SPACE_AVAILABLE_BYTES}")
    [ -n "${CLD6001_DISK_SPACE_AVAILABLE_HUMAN:-}" ] && summary_parts+=("available=${CLD6001_DISK_SPACE_AVAILABLE_HUMAN}")
    [ -n "${CLD6001_DISK_SPACE_MINIMUM_BYTES:-}" ] && summary_parts+=("minimum_bytes=${CLD6001_DISK_SPACE_MINIMUM_BYTES}")
    [ -n "${CLD6001_DISK_SPACE_MINIMUM_HUMAN:-}" ] && summary_parts+=("minimum=${CLD6001_DISK_SPACE_MINIMUM_HUMAN}")
    [ -n "${CLD6001_DISK_SPACE_ERROR:-}" ] && summary_parts+=("error=${CLD6001_DISK_SPACE_ERROR}")

    printf '%s\n' "${summary_parts[*]}"
}
