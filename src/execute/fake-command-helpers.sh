#!/bin/bash

set -Eeuo pipefail

write_fake_script() {
    local -r path="$1"
    local -r body="$2"

    mkdir -p -- "$(dirname -- "$path")"
    {
        printf '#!/bin/bash\n'
        printf 'set -Eeuo pipefail\n'
        printf '%s\n' "$body"
    } > "$path"
    chmod +x "$path"
}

write_fake_command() {
    local -r bin_dir="$1"
    local -r name="$2"
    local -r body="$3"

    write_fake_script "$bin_dir/$name" "$body"
}

write_logged_fake_command() {
    local -r bin_dir="$1"
    local -r name="$2"
    local -r log_file="$3"
    local -r log_prefix="$4"
    local -r body="$5"
    local escaped_log_file=""
    local log_line=""

    printf -v escaped_log_file '%q' "$log_file"
    printf -v log_line "printf '%s|%%s\\n' \"\$*\" >> %s" "$log_prefix" "$escaped_log_file"

    write_fake_command "$bin_dir" "$name" "$log_line
$body"
}

write_fake_sudo() {
    local -r bin_dir="$1"
    local -r mode="$2"
    local -r log_file="${3:-}"
    local -r sudoers_path="${4:-}"
    local body=""
    local escaped_log_file=""
    local escaped_sudoers_path=""
    local log_line=""

    case "$mode" in
        success)
            body='exit 0'
            ;;
        passthrough)
            body='if [[ "${1:-}" == "-v" ]]; then
    exit 0
fi
if [[ "${1:-}" == "-n" ]]; then
    shift
fi
exec "$@"'
            ;;
        refresh-probe)
            body='if [[ "${1:-}" == "-v" ]]; then
    exit 1
fi
if [[ "${1:-}" == "-n" && "${2:-}" == "true" ]]; then
    exit 0
fi
if [[ "${1:-}" == "-n" ]]; then
    shift
fi
exec "$@"'
            ;;
        env-reset)
            [[ -n "$sudoers_path" ]] || {
                printf 'write_fake_sudo env-reset requires a sudoers path\n' >&2
                return 1
            }
            printf -v escaped_sudoers_path '%q' "$sudoers_path"
            body='if [[ "${1:-}" == "-v" ]]; then
    exit 0
fi
if [[ "${1:-}" == "-n" ]]; then
    if [[ "${2:-}" == "true" ]]; then
        [[ -f '"$escaped_sudoers_path"' ]] || exit 1
        exit 0
    fi
    shift
fi
exec env -i PATH="$PATH" "$@"'
            ;;
        *)
            printf 'Unsupported fake sudo mode: %s\n' "$mode" >&2
            return 1
            ;;
    esac

    if [[ -n "$log_file" ]]; then
        printf -v escaped_log_file '%q' "$log_file"
        printf -v log_line "printf 'sudo|%%s\\n' \"\$*\" >> %s" "$escaped_log_file"
        body="$log_line
$body"
    fi

    write_fake_command "$bin_dir" sudo "$body"
}
