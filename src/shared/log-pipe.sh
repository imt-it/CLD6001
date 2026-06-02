#!/bin/bash

_PIPE_ATTENTION=""
_PIPE_OUTCOME=""

resolve_pipe_classification() {
    local token="${1^^}"
    local message="${2:-}"

    case "$token" in
        INFO)
            _PIPE_ATTENTION="INFO"; _PIPE_OUTCOME="INFO" ;;
        OK|SUCCESS)
            _PIPE_ATTENTION="INFO"; _PIPE_OUTCOME="OK" ;;
        PASS)
            _PIPE_ATTENTION="INFO"; _PIPE_OUTCOME="PASS" ;;
        PASS_WITH_FINDINGS)
            _PIPE_ATTENTION="INFO"; _PIPE_OUTCOME="PARTIAL" ;;
        WARN|WARNING)
            case "$message" in
                *" BLOCK:"*|"BLOCK:"*)
                    _PIPE_ATTENTION="WARN"; _PIPE_OUTCOME="BLOCK" ;;
                *" FAIL:"*|"FAIL:"*)
                    _PIPE_ATTENTION="WARN"; _PIPE_OUTCOME="FAIL" ;;
                *" SKIP:"*|"SKIP:"*)
                    _PIPE_ATTENTION="WARN"; _PIPE_OUTCOME="SKIP" ;;
                *"execution completed with findings"*)
                    _PIPE_ATTENTION="INFO"; _PIPE_OUTCOME="PARTIAL" ;;
                *)
                    _PIPE_ATTENTION="WARN"; _PIPE_OUTCOME="WARN" ;;
            esac
            ;;
        BLOCK|BLOCKED)
            _PIPE_ATTENTION="WARN"; _PIPE_OUTCOME="BLOCK" ;;
        SKIP)
            _PIPE_ATTENTION="WARN"; _PIPE_OUTCOME="SKIP" ;;
        FAIL|FAILED|FAILURE)
            _PIPE_ATTENTION="WARN"; _PIPE_OUTCOME="FAIL" ;;
        ERROR)
            _PIPE_ATTENTION="WARN"; _PIPE_OUTCOME="ERROR" ;;
        *)
            _PIPE_ATTENTION="INFO"; _PIPE_OUTCOME="INFO" ;;
    esac
}

emit_pipe_line() {
    local attention="${1:-INFO}"
    local outcome="${2:-INFO}"
    local stage="${3:-setup}"
    local scope="${4:-status}"
    shift 4
    local message="$*"

    printf '[%s] [%s] [%s] [%s] %s\n' "$attention" "$outcome" "$stage" "$scope" "$message" >&2
}

log_pipe() {
    local level="$1"
    local stage="$2"
    local scope="$3"
    shift 3
    local message="$*"
    resolve_pipe_classification "$level" "$message"
    emit_pipe_line "$_PIPE_ATTENTION" "$_PIPE_OUTCOME" "$stage" "$scope" "$message"
}

if ! declare -F log_info >/dev/null 2>&1; then
    log_info() {
        log_pipe "INFO" "${CLD6001_LOG_STAGE:-setup}" "${CLD6001_LOG_SCOPE:-status}" "$*"
    }
fi

if ! declare -F log_warn >/dev/null 2>&1; then
    log_warn() {
        log_pipe "WARN" "${CLD6001_LOG_STAGE:-setup}" "${CLD6001_LOG_SCOPE:-status}" "$*"
    }
fi

if ! declare -F log_error >/dev/null 2>&1; then
    log_error() {
        log_pipe "ERROR" "${CLD6001_LOG_STAGE:-setup}" "${CLD6001_LOG_SCOPE:-status}" "$*"
    }
fi
