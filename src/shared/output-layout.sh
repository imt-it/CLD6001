#!/bin/bash

CLD6001_OUTPUT_LAYOUT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

cld6001_validate_output_subpath() {
    local relative_path="${1:-}"

    case "$relative_path" in
        /*)
            printf 'ERROR: output subpath must be relative: %s\n' "$relative_path" >&2
            return 1
            ;;
        \\*)
            printf 'ERROR: output subpath must be relative: %s\n' "$relative_path" >&2
            return 1
            ;;
        [A-Za-z]:[\\/]*)
            printf 'ERROR: output subpath must be relative: %s\n' "$relative_path" >&2
            return 1
            ;;
    esac

    case "/$relative_path/" in
        *[/\\]..[/\\]*)
            printf 'ERROR: output subpath must not contain parent traversal: %s\n' "$relative_path" >&2
            return 1
            ;;
    esac
}

cld6001_validate_output_containment() {
    local rooted_layout_dir="$1"
    local relative_path="${2:-}"
    local allow_root_symlink="${3:-0}"
    local containment_root="$rooted_layout_dir"
    local existing_path="$rooted_layout_dir"
    local path_component=""
    local remaining_path="$relative_path"
    local resolved_existing_path=""

    if [ -e "$existing_path" ] || [ -L "$existing_path" ]; then
        if [ -L "$existing_path" ] && [ "$allow_root_symlink" != "1" ]; then
            printf 'ERROR: output path escapes rooted layout: %s\n' "$rooted_layout_dir/$relative_path" >&2
            return 1
        fi
        [ -d "$existing_path" ] || return 1
        containment_root="$(cd -- "$existing_path" && pwd -P)" || return 1
    fi

    while [ -n "$remaining_path" ]; do
        path_component="${remaining_path%%/*}"

        if [ "$remaining_path" = "$path_component" ]; then
            remaining_path=""
        else
            remaining_path="${remaining_path#*/}"
        fi

        [ -n "$path_component" ] || continue

        existing_path="$existing_path/$path_component"
        if [ ! -e "$existing_path" ] && [ ! -L "$existing_path" ]; then
            break
        fi
        [ -d "$existing_path" ] || return 1

        resolved_existing_path="$(cd -- "$existing_path" && pwd -P)" || return 1
        case "$resolved_existing_path" in
            "$containment_root"|"$containment_root"/*)
                ;;
            *)
                printf 'ERROR: output path escapes rooted layout: %s\n' "$rooted_layout_dir/$relative_path" >&2
                return 1
                ;;
        esac
    done
}

cld6001_output_dir() {
    local rooted_layout_name="$1"
    local relative_path="${2:-}"
    local rooted_layout_dir="$CLD6001_OUTPUT_LAYOUT_ROOT/$rooted_layout_name"
    local allow_root_symlink="0"

    if [ "$rooted_layout_name" = "temp-work" ]; then
        allow_root_symlink="1"
    fi

    cld6001_validate_output_subpath "$relative_path" || return 1
    cld6001_validate_output_containment "$rooted_layout_dir" "$relative_path" "$allow_root_symlink" || return 1
    printf '%s/%s\n' "$rooted_layout_dir" "$relative_path"
}

cld6001_artifact_dir() {
    local relative_path="${1:-}"

    cld6001_output_dir artifacts "$relative_path"
}

cld6001_temp_work_dir() {
    local relative_path="${1:-}"

    cld6001_output_dir temp-work "$relative_path"
}

CLD6001_LINUX_TEMP_ROOT="${CLD6001_LINUX_TEMP_ROOT:-/var/tmp/cld6001}"

cld6001_linux_temp_root() {
    printf '%s\n' "$CLD6001_LINUX_TEMP_ROOT"
}

cld6001_repo_temp_link() {
    printf '%s/temp-work\n' "$CLD6001_OUTPUT_LAYOUT_ROOT"
}

cld6001_cache_dir() {
    printf '%s/cache\n' "$(cld6001_linux_temp_root)"
}
