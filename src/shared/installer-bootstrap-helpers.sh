#!/bin/bash

if [ -n "${INSTALLER_BOOTSTRAP_HELPERS_LOADED:-}" ]; then
    return 0
fi
readonly INSTALLER_BOOTSTRAP_HELPERS_LOADED=1

cld6001_reset_installer_parse_state() {
    if [ "$#" -lt 6 ]; then
        printf 'Expected at least 6 variable names for installer parse-state reset\n' >&2
        return 1
    fi

    local action_var="$1"
    local profile_var="$2"
    local overlay_var="$3"
    local profile_json_var="$4"
    local log_dir_var="$5"
    local log_file_var="$6"
    local mode_var="${7:-}"
    local mode_default="${8:-}"

    printf -v "${action_var}" '%s' 'install'
    printf -v "${profile_var}" '%s' ''
    printf -v "${overlay_var}" '%s' ''
    printf -v "${profile_json_var}" '%s' ''
    printf -v "${log_dir_var}" '%s' ''
    printf -v "${log_file_var}" '%s' ''

    if [ -n "${mode_var}" ]; then
        printf -v "${mode_var}" '%s' "${mode_default}"
    fi
}

cld6001_initialize_installer_log_paths() {
    if [ "$#" -lt 4 ]; then
        printf 'Expected run-id, script name, action, and rollback timestamp\n' >&2
        return 1
    fi

    local run_id="$1"
    local script_name="$2"
    local action="$3"
    local rollback_timestamp="$4"
    local log_dir_var="${5:-LOG_DIR}"
    local log_file_var="${6:-LOG_FILE}"
    local log_dir="/var/log/cld6001/${run_id}"

    mkdir -p "${log_dir}"
    printf -v "${log_dir_var}" '%s' "${log_dir}"
    printf -v "${log_file_var}" '%s' "${log_dir}/${script_name}_${action}_${rollback_timestamp}.log"
}

cld6001_installer_log() {
    if [ "$#" -lt 5 ]; then
        printf 'Expected level, stage, runtime, script name, and log file for installer log\n' >&2
        return 1
    fi

    local level="$1"
    local stage="$2"
    local runtime="$3"
    local script_name="$4"
    local log_file="$5"
    shift 5

    log_pipe "$level" "${stage}" "${runtime}" "$*"

    local timestamp
    local normalized_level
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    normalized_level="$(terminal_normalize_level "$level")"

    if [ -n "${log_file}" ]; then
        printf '%s [%s] %s: %s\n' "$timestamp" "$normalized_level" "$script_name" "$*" >> "${log_file}"
    fi
}

cld6001_installer_log_step() {
    if [ "$#" -lt 7 ]; then
        printf 'Expected colors, stage, runtime, script name, log file, and message for installer step log\n' >&2
        return 1
    fi

    local blue="$1"
    local nc="$2"
    local stage="$3"
    local runtime="$4"
    local script_name="$5"
    local log_file="$6"
    shift 6

    printf '\n%b---%b\n' "${blue}" "${nc}"
    cld6001_installer_log "STEP" "${stage}" "${runtime}" "${script_name}" "${log_file}" "$@"
    printf '%b---%b\n\n' "${blue}" "${nc}"
}
