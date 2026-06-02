#!/bin/bash

set -Eeuo pipefail

SNAPSHOT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SNAPSHOT_LIB_DIR/../../execute/run-context.sh"
source "$SNAPSHOT_LIB_DIR/../../shared/terminal-colors.sh"
DEFAULT_SNAPSHOT_DIR="$SNAPSHOT_LIB_DIR/snapshots"

cld6001_unique_timestamp_id() {
    cld6001_generate_timestamped_id "${1:-%Y%m%d_%H%M%S}" "${2:-_}" 8
}

snapshot_root_dir() {
    if [ -n "${SNAPSHOT_DIR:-}" ]; then
        printf '%s\n' "$SNAPSHOT_DIR"
        return 0
    fi
    if [ -n "${CLD6001_RUN_ROOT:-}" ]; then
        printf '%s\n' "${CLD6001_RUN_ROOT}/snapshots"
        return 0
    fi
    printf '%s\n' "$DEFAULT_SNAPSHOT_DIR"
}

snapshot_log_name() {
    local source_path="${SNAPSHOT_LOG_SOURCE:-${0:-snapshot}}"
    source_path="${source_path##*/}"
    source_path="${source_path%.sh}"
    printf '%s\n' "$source_path"
}

snapshot_log() {
    local -r level="$1"
    shift
    terminal_emit_scoped "$(snapshot_log_name)" "$level" "$@"
}

snapshot_info() {
    snapshot_log INFO "$@"
}

snapshot_warn() {
    snapshot_log WARN "$@" >&2
}

snapshot_error() {
    snapshot_log ERROR "$@" >&2
}

snapshot_success() {
    snapshot_log OK "$@"
}

snapshot_unexpected_error() {
    local -r exit_code="$1"
    local -r line_number="$2"
    snapshot_error "Unexpected failure at line $line_number"
    exit "$exit_code"
}

enable_snapshot_error_trap() {
    trap 'snapshot_unexpected_error $? $LINENO' ERR
}

write_snapshot_placeholder_file() {
    local -r output_path="$1"
    local -r message="$2"
    printf '%s\n' "$message" > "$output_path"
}

record_optional_snapshot_artifact_failure() {
    local -r output_path="$1"
    local -r message="$2"
    write_snapshot_placeholder_file "$output_path" "$message"
    snapshot_warn "$message"
}

capture_optional_snapshot_output() {
    local -r output_path="$1"
    local -r message="$2"
    shift 2

    if "$@" > "$output_path" 2>/dev/null; then
        return 0
    fi

    record_optional_snapshot_artifact_failure "$output_path" "$message"
}

capture_optional_restorable_output() {
    local -r output_path="$1"
    local -r message="$2"
    shift 2

    if "$@" > "$output_path" 2>/dev/null; then
        return 0
    fi

    rm -f -- "$output_path"
    snapshot_warn "$message"
}

copy_optional_snapshot_file() {
    local -r source_path="$1"
    local -r output_path="$2"
    local -r message="$3"

    if cp -- "$source_path" "$output_path" 2>/dev/null; then
        return 0
    fi

    record_optional_snapshot_artifact_failure "$output_path" "$message"
}

copy_optional_restorable_file() {
    local -r source_path="$1"
    local -r output_path="$2"
    local -r message="$3"

    if cp -- "$source_path" "$output_path" 2>/dev/null; then
        return 0
    fi

    rm -f -- "$output_path"
    snapshot_warn "$message"
}

set_private_snapshot_umask() {
    umask 077
}

ensure_private_snapshot_directory() {
    local -r directory_path="$1"
    mkdir -p -- "$directory_path"
    chmod 700 -- "$directory_path"
}

create_private_snapshot_directories() {
    local directory_path=""

    for directory_path in "$@"; do
        ensure_private_snapshot_directory "$directory_path"
    done
}

secure_snapshot_tree() {
    local -r snapshot_path="$1"

    [ -d "$snapshot_path" ] || return 1

    find "$snapshot_path" -type d -exec chmod 700 -- {} +
    find "$snapshot_path" -type f -exec chmod 600 -- {} +
}

list_snapshot_directories() {
    local -r root_dir="$(snapshot_root_dir)"

    if [ ! -d "$root_dir" ]; then
        return 0
    fi

    find "$root_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | LC_ALL=C sort -r
}

is_safe_snapshot_name() {
    local -r snapshot_name="${1:-}"

    [ -n "$snapshot_name" ] || return 1
    [ "$snapshot_name" != "." ] && [ "$snapshot_name" != ".." ] || return 1
    printf '%s\n' "$snapshot_name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

snapshot_is_restorable() {
    local -r snapshot_path="$1"

    [ -d "$snapshot_path/restore" ] && return 0

    [ -f "$snapshot_path/docker/daemon.json" ] && return 0
    [ -f "$snapshot_path/hosts/hosts.txt" ] && return 0
    [ -f "$snapshot_path/network/dns-config.txt" ] && return 0
    [ -f "$snapshot_path/security/selinux-config.txt" ] && return 0

    return 1
}

canonical_snapshot_directory() {
    local -r directory_path="$1"
    [ -d "$directory_path" ] || return 1

    (
        cd -P -- "$directory_path" &&
        pwd -P
    )
}

snapshot_path_is_within_root() {
    local -r snapshot_path="$1"
    local root_canonical
    local snapshot_canonical

    root_canonical="$(canonical_snapshot_directory "$(snapshot_root_dir)")" || return 1
    snapshot_canonical="$(canonical_snapshot_directory "$snapshot_path")" || return 1

    case "$snapshot_canonical" in
        "$root_canonical"/*) return 0 ;;
    esac

    return 1
}

resolve_snapshot_path() {
    local requested_name="${1:-}"
    local root_dir
    root_dir="$(snapshot_root_dir)"

    if [ -n "$requested_name" ]; then
        is_safe_snapshot_name "$requested_name" || return 1
        local explicit_path="$root_dir/$requested_name"
        [ -d "$explicit_path" ] || return 1
        snapshot_path_is_within_root "$explicit_path" || return 1
        printf '%s\n' "$explicit_path"
        return 0
    fi

    local snapshot_name
    while IFS= read -r snapshot_name; do
        if snapshot_is_restorable "$root_dir/$snapshot_name"; then
            printf '%s\n' "$root_dir/$snapshot_name"
            return 0
        fi
    done < <(list_snapshot_directories)

    return 1
}

snapshot_backup_root() {
    local -r root_dir="$(snapshot_root_dir)"
    printf '%s\n' "$root_dir/.restore-backups"
}

map_live_path() {
    local -r relative_path="$1"
    local live_root="${SNAPSHOT_LIVE_ROOT:-}"

    if [ -n "$live_root" ]; then
        printf '%s/%s\n' "${live_root%/}" "$relative_path"
        return 0
    fi

    printf '/%s\n' "$relative_path"
}

resolve_live_target_path() {
    local -r relative_path="$1"
    local target_path=""
    local resolved_live_root=""
    local resolved_target=""

    target_path="$(map_live_path "$relative_path")"
    resolved_target="$(realpath -m -- "$target_path")" || return 1
    resolved_live_root="$(realpath -m -- "${SNAPSHOT_LIVE_ROOT:-/}")" || return 1

    if [ "$resolved_live_root" = "/" ]; then
        printf '%s\n' "$resolved_target"
        return 0
    fi

    case "$resolved_target" in
        "$resolved_live_root"/*)
            printf '%s\n' "$resolved_target"
            return 0
            ;;
    esac

    snapshot_error "Resolved restore path escapes live root: $relative_path"
    return 1
}

backup_target_file() {
    local -r target_path="$1"
    local -r relative_path="$2"

    if [ ! -f "$target_path" ]; then
        return 0
    fi

    local -r backup_root="$(snapshot_backup_root)"
    local -r backup_path="$backup_root/$relative_path"

    mkdir -p "$(dirname -- "$backup_path")"
    cp -- "$target_path" "$backup_path"
}

restore_file_to_relative_path() {
    local -r source_path="$1"
    local -r relative_path="$2"
    local target_path

    target_path="$(resolve_live_target_path "$relative_path")"
    mkdir -p "$(dirname -- "$target_path")"
    backup_target_file "$target_path" "$relative_path"
    cp -- "$source_path" "$target_path"

    printf 'Restored: %s\n' "$relative_path"
}

restore_system_snapshot_directory() {
    local -r snapshot_path="$1"
    local -r restore_root="$snapshot_path/restore"

    [ -d "$restore_root" ] || return 1

    while IFS= read -r -d '' source_path; do
        local relative_path="${source_path#$restore_root/}"
        restore_file_to_relative_path "$source_path" "$relative_path"
    done < <(find "$restore_root" -type f -print0 | sort -z)
}

restore_config_snapshot_directory() {
    local -r snapshot_path="$1"
    local restored=false

    if [ -f "$snapshot_path/docker/daemon.json" ]; then
        restore_file_to_relative_path "$snapshot_path/docker/daemon.json" "etc/docker/daemon.json"
        restored=true
    fi

    if [ -f "$snapshot_path/hosts/hosts.txt" ]; then
        restore_file_to_relative_path "$snapshot_path/hosts/hosts.txt" "etc/hosts"
        restored=true
    fi

    if [ -f "$snapshot_path/network/dns-config.txt" ]; then
        restore_file_to_relative_path "$snapshot_path/network/dns-config.txt" "etc/resolv.conf"
        restored=true
    fi

    if [ -f "$snapshot_path/security/selinux-config.txt" ]; then
        restore_file_to_relative_path "$snapshot_path/security/selinux-config.txt" "etc/selinux/config"
        restored=true
    fi

    [ "$restored" = true ]
}

restore_snapshot_path() {
    local -r snapshot_path="$1"

    if [ -d "$snapshot_path/restore" ]; then
        restore_system_snapshot_directory "$snapshot_path"
        return 0
    fi

    restore_config_snapshot_directory "$snapshot_path"
}

delete_snapshot_directory() {
    local -r snapshot_name="$1"
    is_safe_snapshot_name "$snapshot_name" || return 1
    local -r snapshot_path="$(snapshot_root_dir)/$snapshot_name"

    [ -d "$snapshot_path" ] || return 1
    snapshot_path_is_within_root "$snapshot_path" || return 1
    rm -rf -- "$snapshot_path"
}

sanitize_docker_security_options() {
    awk 'NF'
}

append_sanitized_docker_security_options() {
    local -r output_path="$1"
    local security_options
    local sanitized_output

    security_options="$(docker info --format '{{range .SecurityOptions}}{{println .}}{{end}}' 2>/dev/null)" || {
        record_optional_snapshot_artifact_failure "$output_path" 'Docker security config not available'
        return 0
    }

    sanitized_output="$(printf '%s\n' "$security_options" | sanitize_docker_security_options)"

    if [ -n "$sanitized_output" ]; then
        printf '%s\n' "$sanitized_output" >> "$output_path"
        return 0
    fi

    printf '%s\n' 'No Docker security options reported' >> "$output_path"
}

write_sanitized_docker_security_options() {
    local -r output_path="$1"

    : > "$output_path"
    append_sanitized_docker_security_options "$output_path"
}

write_podman_security_config() {
    local -r output_path="$1"

    if command -v podman >/dev/null 2>&1; then
        if podman info --format '{{json .Host.Security}}' > "$output_path" 2>/dev/null; then
            return 0
        fi
        record_optional_snapshot_artifact_failure "$output_path" 'Podman security config not available'
    else
        write_snapshot_placeholder_file "$output_path" 'Podman security config not available (Podman not installed)'
    fi
}
