#!/bin/bash

if [ -n "${CLD6001_HOST_SAFETY_GUARD_LOADED:-}" ]; then
    return 0
fi
readonly CLD6001_HOST_SAFETY_GUARD_LOADED=1

CLD6001_LIVE_HOST_KIND=""
CLD6001_LIVE_HOST_REASON=""
CLD6001_HOST_SAFETY_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

cld6001_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

cld6001_set_live_host_detection() {
    CLD6001_LIVE_HOST_KIND="$1"
    CLD6001_LIVE_HOST_REASON="$2"
}

cld6001_detect_live_host() {
    local override="${CLD6001_UNSAFE_NONTHESIS_HOST_SAFETY_CLASS_OVERRIDE:-}"
    local default_target=""
    local session_kind="workstation"
    local user_session_pattern='^[[:space:]]*[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+'

    CLD6001_LIVE_HOST_KIND=""
    CLD6001_LIVE_HOST_REASON=""

    case "$override" in
        "")
            ;;
        desktop|server|workstation)
            cld6001_set_live_host_detection "$override" "forced by CLD6001_UNSAFE_NONTHESIS_HOST_SAFETY_CLASS_OVERRIDE"
            return 0
            ;;
        *)
            cld6001_set_live_host_detection "server" "invalid CLD6001_UNSAFE_NONTHESIS_HOST_SAFETY_CLASS_OVERRIDE=$override"
            return 0
            ;;
    esac

    if command -v systemctl >/dev/null 2>&1; then
        default_target="$(systemctl get-default 2>/dev/null || true)"
        if [ "$default_target" = "graphical.target" ]; then
            cld6001_set_live_host_detection "desktop" "system default target is graphical.target"
            return 0
        fi
    fi

    case "${XDG_SESSION_TYPE:-}" in
        wayland|x11)
            cld6001_set_live_host_detection "workstation" "graphical session environment detected"
            return 0
            ;;
    esac
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        cld6001_set_live_host_detection "workstation" "graphical display environment detected"
        return 0
    fi

    [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] && session_kind="server"

    if command -v loginctl >/dev/null 2>&1; then
        if loginctl list-sessions --no-legend 2>/dev/null | grep -Eq "$user_session_pattern"; then
            cld6001_set_live_host_detection "$session_kind" "active loginctl sessions detected"
            return 0
        fi
    fi

    if command -v who >/dev/null 2>&1; then
        if who 2>/dev/null | grep -Eq '[^[:space:]]'; then
            cld6001_set_live_host_detection "$session_kind" "active user sessions detected"
            return 0
        fi
    fi

    return 1
}

cld6001_parent_pid() {
    local pid="$1"
    awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null
}

cld6001_process_sources_script() {
    local pid="$1"
    local expected_path="$2"
    local sourced_path=""

    sourced_path="$(readlink -f "/proc/$pid/fd/255" 2>/dev/null || true)"
    [ "$sourced_path" = "$expected_path" ] && return 0
    return 1
}

cld6001_script_in_ancestry() {
    local expected_path="$1"
    local pid="$$"
    local max_depth=20

    expected_path="$(readlink -f "$expected_path" 2>/dev/null || printf '%s' "$expected_path")"

    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$max_depth" -gt 0 ]; do
        cld6001_process_sources_script "$pid" "$expected_path" && return 0
        pid="$(cld6001_parent_pid "$pid")"
        max_depth=$((max_depth - 1))
    done

    return 1
}

cld6001_current_process_fd_target() {
    local fd_var_name="$1"
    local fd_value="${!fd_var_name:-}"

    [ -n "$fd_value" ] || return 1
    printf '%s' "$fd_value" | grep -Eq '^[0-9]+$' || return 1

    readlink "/proc/$$/fd/$fd_value" 2>/dev/null || true
}

cld6001_process_has_fd_target() {
    local pid="$1"
    local expected_target="$2"
    local fd_path=""
    local fd_target=""

    for fd_path in /proc/"$pid"/fd/*; do
        [ -e "$fd_path" ] || continue
        fd_target="$(readlink "$fd_path" 2>/dev/null || true)"
        [ "$fd_target" = "$expected_target" ] && return 0
    done

    return 1
}

cld6001_runner_capability_fd_approved() {
    local capability_target=""
    local bootstrap_target=""
    local pid="$$"
    local max_depth=20
    local canonical_run_root=""
    local capability_root=""

    [ -n "${CLD6001_RUN_ROOT:-}" ] || return 1
    canonical_run_root="$(readlink -f "${CLD6001_RUN_ROOT}" 2>/dev/null || true)"
    [ -n "$canonical_run_root" ] || return 1
    capability_root="$canonical_run_root/orchestrator/host-safety"
    capability_target="$(cld6001_current_process_fd_target "CLD6001_HOST_SAFETY_APPROVAL_FD")"
    [ -n "$capability_target" ] || return 1
    bootstrap_target="$(cld6001_current_process_fd_target "CLD6001_HOST_SAFETY_APPROVAL_BOOTSTRAP_FD")"
    [ -n "$bootstrap_target" ] || return 1

    case "$capability_target" in
        "$capability_root"/runner-approval-*" (deleted)")
            ;;
        *)
            return 1
            ;;
    esac

    case "$bootstrap_target" in
        "$capability_root"/runner-approval-bootstrap-*" (deleted)")
            ;;
        *)
            return 1
            ;;
    esac

    [ "${bootstrap_target#"$capability_root"/runner-approval-bootstrap-}" = \
        "${capability_target#"$capability_root"/runner-approval-}" ] || return 1

    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$max_depth" -gt 0 ]; do
        if cld6001_process_has_fd_target "$pid" "$capability_target"; then
            return 0
        fi
        pid="$(cld6001_parent_pid "$pid")"
        max_depth=$((max_depth - 1))
    done

    return 1
}

cld6001_host_reset_context_approved() {
    cld6001_script_in_ancestry "$CLD6001_HOST_SAFETY_REPO_ROOT/src/setup/apply-state.sh" || return 1
    cld6001_script_in_ancestry "$CLD6001_HOST_SAFETY_REPO_ROOT/src/execute/server-orchestrator.sh"
}

cld6001_runner_context_approved() {
    local orchestrator_path="$CLD6001_HOST_SAFETY_REPO_ROOT/src/execute/server-orchestrator.sh"

    cld6001_script_in_ancestry "$orchestrator_path" && return 0
    cld6001_runner_capability_fd_approved
}

cld6001_unsafe_live_host_reset_allowed() {
    cld6001_truthy "${CLD6001_UNSAFE_NONTHESIS_ALLOW_LIVE_HOST_RESET:-}"
}

cld6001_require_direct_strict_runner_safe_host() {
    cld6001_detect_live_host || return 0
    cld6001_runner_context_approved && return 0

    printf 'Refusing direct test-runner execution against managed environment states on detected live %s host (%s) before any apply-state call. Use src/execute/server-orchestrator.sh for thesis runs.\n' \
        "$CLD6001_LIVE_HOST_KIND" "$CLD6001_LIVE_HOST_REASON" >&2
    return 1
}

cld6001_require_safe_host_reset() {
    local reset_label="${1:-host reset}"

    cld6001_detect_live_host || return 0
    cld6001_host_reset_context_approved && return 0
    cld6001_unsafe_live_host_reset_allowed && return 0

    printf 'Refusing %s on detected live %s host (%s). Re-run via src/execute/server-orchestrator.sh or, for explicit non-thesis recovery only, set CLD6001_UNSAFE_NONTHESIS_ALLOW_LIVE_HOST_RESET=true.\n' \
        "$reset_label" "$CLD6001_LIVE_HOST_KIND" "$CLD6001_LIVE_HOST_REASON" >&2
    return 1
}
