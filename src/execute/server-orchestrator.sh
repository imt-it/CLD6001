#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"

source "$REPO_ROOT/src/execute/run-context.sh"
source "$REPO_ROOT/src/execute/collections/registry.sh"
source "$REPO_ROOT/src/shared/env-loader.sh"
source "$REPO_ROOT/src/shared/log-pipe.sh"
source "$REPO_ROOT/src/shared/noninteractive-runtime.sh"

ORCHESTRATOR_RELAXED_DEBUG_EXPLICIT="${CLD6001_ORCHESTRATOR_RELAXED_DEBUG-}"
ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
    safe_source_env "$ENV_FILE"
    log_pipe "INFO" "orchestrator" "status" "Loading environment variables from $ENV_FILE"
fi

RUN_ID="$(cld6001_generate_run_id)"
RUN_ID_EXPLICIT=false
TEMP_WORK_PATH="$REPO_ROOT/temp-work"
TEMP_WORK_PHYSICAL_ROOT="${CLD6001_TEMP_WORK_ROOT:-/var/tmp/cld6001}"
RESULTS_ROOT="$TEMP_WORK_PATH"
RESULTS_ROOT_USES_TEMP_WORK=true
RUNTIME_SELECTION="all"
OPERABILITY_IMAGE_DEFAULT="docker.io/library/alpine:3.20"
OPERABILITY_IMAGE="${CLD6001_OPERABILITY_IMAGE:-${OPERABILITY_IMAGE:-}}"
OPERABILITY_IMAGE="${OPERABILITY_IMAGE:-docker.io/library/alpine:3.20}"
RESUME_MODE=false
TARGETED_MODE=false
TARGETED_STATE=""
TARGETED_COLLECTION=""
TARGETED_TESTCASE=""
ORCHESTRATOR_RELAXED_DEBUG="${ORCHESTRATOR_RELAXED_DEBUG_EXPLICIT:-false}"
RESOLVED_RUNTIMES=()

usage() {
    cat <<EOF
Usage: bash src/execute/${SCRIPT_NAME} [OPTIONS]

Runs the complete CLD6001 live sequence on the thesis host.

Options:
  --run-id ID             Override generated orchestrator run id
  --results-root DIR      Override results root (default: temp-work)
  --runtime RUNTIME       Runtime selection passed to test-runner.sh (default: all)
  --operability-image IMG Image used for normal-container sanity checks (default: docker.io/library/alpine:3.20)
  --resume                Skip steps that already have a completed marker (requires --run-id)
  --targeted              Run a single testcase/collection with state management
  --environment-state ST  Environment state for targeted mode (baseline-system|cis-system)
  --test-collection COL   Collection letter for targeted mode (a-h)
  --testcase TC           Testcase identifier for targeted mode
  --relaxed-debug         Debug-only opt-in: pass --relaxed-debug to test-runner.sh
  --help                  Show this help

Targeted mode:
  server-orchestrator.sh --targeted --environment-state cis-system --testcase tc10
  server-orchestrator.sh --targeted --environment-state baseline-system --test-collection a
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --run-id)
            RUN_ID="${2:-}"
            [ -n "$RUN_ID" ] || { printf 'Missing value for --run-id\n' >&2; exit 1; }
            cld6001_validate_run_id "$RUN_ID" || {
                printf 'Invalid run id: %s\n' "$RUN_ID" >&2
                exit 1
            }
            RUN_ID_EXPLICIT=true
            shift 2
            ;;
        --results-root)
            RESULTS_ROOT="${2:-}"
            [ -n "$RESULTS_ROOT" ] || { printf 'Missing value for --results-root\n' >&2; exit 1; }
            shift 2
            ;;
        --runtime)
            RUNTIME_SELECTION="${2:-}"
            [ -n "$RUNTIME_SELECTION" ] || { printf 'Missing value for --runtime\n' >&2; exit 1; }
            shift 2
            ;;
        --operability-image)
            OPERABILITY_IMAGE="${2:-}"
            [ -n "$OPERABILITY_IMAGE" ] || { printf 'Missing value for --operability-image\n' >&2; exit 1; }
            shift 2
            ;;
        --resume)
            RESUME_MODE=true
            shift
            ;;
        --targeted)
            TARGETED_MODE=true
            shift
            ;;
        --environment-state)
            TARGETED_STATE="${2:-}"
            [ -n "$TARGETED_STATE" ] || { printf 'Missing value for --environment-state\n' >&2; exit 1; }
            shift 2
            ;;
        --test-collection)
            TARGETED_COLLECTION="${2:-}"
            [ -n "$TARGETED_COLLECTION" ] || { printf 'Missing value for --test-collection\n' >&2; exit 1; }
            shift 2
            ;;
        --testcase)
            TARGETED_TESTCASE="${2:-}"
            [ -n "$TARGETED_TESTCASE" ] || { printf 'Missing value for --testcase\n' >&2; exit 1; }
            shift 2
            ;;
        --relaxed-debug)
            ORCHESTRATOR_RELAXED_DEBUG=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

load_resolved_runtimes() {
    RESOLVED_RUNTIMES=()
    mapfile -t RESOLVED_RUNTIMES < <(resolve_runtimes) || return 1
    [ "${#RESOLVED_RUNTIMES[@]}" -gt 0 ] || {
        printf 'No runtimes resolved for selection: %s\n' "$RUNTIME_SELECTION" >&2
        return 1
    }
}

validate_targeted_arguments() {
    [ "$TARGETED_MODE" = "true" ] || return 0

    [ -n "$TARGETED_STATE" ] || {
        printf 'ERROR: --targeted requires --environment-state\n' >&2
        exit 1
    }

    source "$REPO_ROOT/src/profiles/environment-states.sh"
    cld6001_environment_state_exists "$TARGETED_STATE" || {
        printf 'Unknown environment state: %s\n' "$TARGETED_STATE" >&2
        exit 1
    }

    if [ -n "$TARGETED_COLLECTION" ]; then
        case "$TARGETED_COLLECTION" in
            a|b|c|d|e|f|g|h|preflight|cleanup) ;;
            *)
                printf 'Invalid targeted collection: %s\n' "$TARGETED_COLLECTION" >&2
                exit 1
                ;;
        esac
    fi
}

resolve_runtimes() {
    case "$RUNTIME_SELECTION" in
        all)
            printf '%s\n' docker-rootful docker-rootless podman-rootless
            ;;
        docker-rootful|docker-rootless|podman-rootless)
            printf '%s\n' "$RUNTIME_SELECTION"
            ;;
        *)
            printf 'Unsupported runtime selection: %s\n' "$RUNTIME_SELECTION" >&2
            return 1
            ;;
    esac
}

copy_directory_contents() {
    local -r source_dir="$1"
    local -r destination_dir="$2"

    [ -d "$source_dir" ] || {
        printf 'temp-work copy source is not a directory: %s\n' "$source_dir" >&2
        return 1
    }

    mkdir -p -- "$destination_dir" || return 1

    (
        cd -- "$source_dir" &&
        /usr/bin/tar -cf - .
    ) | (
        cd -- "$destination_dir" &&
        /usr/bin/tar -xf -
    )
}

best_effort_copy_directory_contents() {
    local -r source_dir="$1"
    local -r destination_dir="$2"

    if copy_directory_contents "$source_dir" "$destination_dir"; then
        return 0
    fi

    log_pipe "WARN" "orchestrator" "temp-work" \
        "Continuing after partial temp-work copy failure from $source_dir to $destination_dir; inaccessible inherited entries were skipped"
    return 0
}

normalize_path_for_prefix_check() {
    local raw_path="$1"
    local -a path_parts=()
    local -a normalized_parts=()
    local part=""
    local normalized_path="/"
    local index=0

    if [[ "$raw_path" != /* ]]; then
        raw_path="$(pwd -P)/$raw_path"
    fi

    IFS='/' read -r -a path_parts <<< "${raw_path#/}"
    for part in "${path_parts[@]}"; do
        case "$part" in
            ""|".")
                continue
                ;;
            "..")
                if [ ${#normalized_parts[@]} -gt 0 ]; then
                    unset "normalized_parts[$((${#normalized_parts[@]} - 1))]"
                fi
                ;;
            *)
                normalized_parts+=("$part")
                ;;
        esac
    done

    if [ ${#normalized_parts[@]} -eq 0 ]; then
        printf '/\n'
        return 0
    fi

    normalized_path=""
    for ((index = 0; index < ${#normalized_parts[@]}; index++)); do
        normalized_path="$normalized_path/${normalized_parts[$index]}"
    done

    printf '%s\n' "$normalized_path"
}

results_root_uses_temp_work() {
    local -r normalized_results_root="$(normalize_path_for_prefix_check "$1")"
    local -r normalized_temp_work="$(normalize_path_for_prefix_check "$TEMP_WORK_PATH")"

    case "$normalized_results_root" in
        "$normalized_temp_work"|"$normalized_temp_work"/*)
            return 0
            ;;
    esac

    return 1
}

ensure_temp_work_symlink() {
    local -r temp_work="$TEMP_WORK_PATH"
    local -r physical_root="$TEMP_WORK_PHYSICAL_ROOT"
    local current_target=""
    local expected_target=""
    local symlink_target=""
    local replacement_dir=""

    if [ "$(uname -s)" != "Linux" ]; then
        [ "$RESULTS_ROOT_USES_TEMP_WORK" = "true" ] || return 0

        if [ -L "$temp_work" ]; then
            symlink_target="$(readlink "$temp_work" 2>/dev/null || true)"
            if [ -n "$symlink_target" ]; then
                case "$symlink_target" in
                    /*) current_target="$symlink_target" ;;
                    *) current_target="$(cd -- "$(dirname -- "$temp_work")" && pwd -P)/$symlink_target" ;;
                esac
            fi

            replacement_dir="${temp_work}.orchestrator-migrate.$$"
            rm -rf -- "$replacement_dir"
            mkdir -p -- "$replacement_dir"

            if [ -n "$current_target" ] && [ -d "$current_target" ]; then
                best_effort_copy_directory_contents "$current_target" "$replacement_dir"
            fi

            rm -f -- "$temp_work"
            mv -- "$replacement_dir" "$temp_work"
            return 0
        fi

        if [ -e "$temp_work" ] && [ ! -d "$temp_work" ]; then
            printf 'temp-work path is not a directory or symlink: %s\n' "$temp_work" >&2
            return 1
        fi

        return 0
    fi

    mkdir -p -- "$physical_root/cache"
    expected_target="$(readlink -f -- "$physical_root")"

    if [ -L "$temp_work" ]; then
        current_target="$(readlink -f -- "$temp_work" 2>/dev/null || true)"
        if [ "$current_target" = "$expected_target" ]; then
            return 0
        fi
        if [ -n "$current_target" ] && [ -d "$temp_work" ]; then
            best_effort_copy_directory_contents "$temp_work" "$physical_root"
        fi
        rm -f -- "$temp_work"
        ln -s -- "$physical_root" "$temp_work"
        return 0
    fi

    if [ -d "$temp_work" ]; then
        best_effort_copy_directory_contents "$temp_work" "$physical_root"
        rm -rf -- "$temp_work"
        ln -s -- "$physical_root" "$temp_work"
        return 0
    fi

    if [ -e "$temp_work" ]; then
        printf 'temp-work path is not a directory or symlink: %s\n' "$temp_work" >&2
        return 1
    fi

    ln -s -- "$physical_root" "$temp_work"
}

if [ "$RESUME_MODE" = "true" ] && [ "$RUN_ID_EXPLICIT" != "true" ]; then
    printf 'ERROR: --resume requires --run-id to target a specific previous run\n' >&2
    usage >&2
    exit 1
fi

load_resolved_runtimes
validate_targeted_arguments

if results_root_uses_temp_work "$RESULTS_ROOT"; then
    RESULTS_ROOT_USES_TEMP_WORK=true
else
    RESULTS_ROOT_USES_TEMP_WORK=false
fi

ensure_temp_work_symlink

CLD6001_RUN_ROOT="$(cld6001_resolve_run_root "$RESULTS_ROOT" "$RUN_ID")"
export CLD6001_RUN_ID="$RUN_ID"
export CLD6001_RUN_ROOT
export CLD6001_RESULTS_ROOT="$CLD6001_RUN_ROOT"

ORCH_DIR="$CLD6001_RUN_ROOT/orchestrator"
LOG_DIR="$ORCH_DIR/logs"
STATUS_FILE="$ORCH_DIR/orchestrator-status.jsonl"
MARKER_DIR="$ORCH_DIR/completed"
ORCHESTRATOR_SUDOERS_PATH="${CLD6001_ORCHESTRATOR_SUDOERS_PATH:-/etc/sudoers.d/99-cld6001-thesis-runtime}"

mkdir -p -- "$LOG_DIR" "$MARKER_DIR"
if [ "$RESUME_MODE" != "true" ]; then
    : > "$STATUS_FILE"
fi

is_known_level_token() {
    case "${1^^}" in
        INFO|OK|SUCCESS|PASS|PASS_WITH_FINDINGS|WARN|WARNING|BLOCK|SKIP|FAIL|FAILED|FAILURE|ERROR)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

_LINE_ATTENTION=""
_LINE_OUTCOME=""

resolve_line_classification() {
    resolve_pipe_classification "$1" "$2"
    _LINE_ATTENTION="$_PIPE_ATTENTION"
    _LINE_OUTCOME="$_PIPE_OUTCOME"
}

orchestrator_relaxed_debug_enabled() {
    case "${ORCHESTRATOR_RELAXED_DEBUG:-false}" in
        1|true|TRUE|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

HOST_SAFETY_APPROVAL_FD=""
HOST_SAFETY_APPROVAL_BOOTSTRAP_SOURCE_FD=""
HOST_SAFETY_APPROVAL_BOOTSTRAP_HELPER=""

ensure_runner_host_safety_approval_fd() {
    local capability_dir=""
    local capability_path=""
    local bootstrap_path=""
    local helper_path=""
    local capability_nonce=""

    if [ -n "$HOST_SAFETY_APPROVAL_FD" ]; then
        return 0
    fi

    capability_dir="$ORCH_DIR/host-safety"
    mkdir -p -- "$capability_dir"
    chmod 700 "$capability_dir"
    capability_dir="$(cd -- "$capability_dir" && pwd -P)"
    capability_nonce="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ -n "$capability_nonce" ] || capability_nonce="${CLD6001_RUN_ID:-run}.$$.$RANDOM$RANDOM"
    capability_path="$capability_dir/runner-approval-$capability_nonce"
    bootstrap_path="$capability_dir/runner-approval-bootstrap-$capability_nonce"
    helper_path="$capability_dir/runner-approval-bootstrap-$capability_nonce.sh"
    (
        umask 077
        printf 'server-orchestrator runner approval %s\n' "$capability_nonce" > "$capability_path"
        printf 'server-orchestrator runner bootstrap %s\n' "$capability_nonce" > "$bootstrap_path"
        cat > "$helper_path" <<EOF
#!/bin/bash
if [ -n "\${CLD6001_HOST_SAFETY_APPROVAL_BOOTSTRAP_SOURCE_FD:-}" ] && \
    [ -z "\${CLD6001_HOST_SAFETY_APPROVAL_BOOTSTRAP_FD:-}" ]; then
    exec {CLD6001_HOST_SAFETY_APPROVAL_BOOTSTRAP_FD}<&"\$CLD6001_HOST_SAFETY_APPROVAL_BOOTSTRAP_SOURCE_FD"
    export CLD6001_HOST_SAFETY_APPROVAL_BOOTSTRAP_FD
fi
unset BASH_ENV
EOF
    )
    chmod 600 "$helper_path"
    exec {HOST_SAFETY_APPROVAL_FD}<"$capability_path"
    exec {HOST_SAFETY_APPROVAL_BOOTSTRAP_SOURCE_FD}<"$bootstrap_path"
    HOST_SAFETY_APPROVAL_BOOTSTRAP_HELPER="$helper_path"
    rm -f -- "$capability_path"
    rm -f -- "$bootstrap_path"
}

emit_console_line() {
    emit_pipe_line "${1:-INFO}" "${2:-INFO}" "${3:-orchestrator}" "${4:-status}" "${5:-}"
}

STEP_DISPLAY_TAG_1=""
STEP_DISPLAY_TAG_2=""
STEP_DISPLAY_TAG_3=""

set_step_display_tags() {
    STEP_DISPLAY_TAG_1="${1:-}"
    STEP_DISPLAY_TAG_2="${2:-}"
    STEP_DISPLAY_TAG_3="${3:-}"
}

resolve_step_display_tags() {
    local -r step_id="$1"

    case "$step_id" in
        01-bootstrap-prerequisites) set_step_display_tags "setup" "bootstrap" ;;
        02-verify-repo-layout) set_step_display_tags "setup" "verify" ;;
        03-apply-baseline) set_step_display_tags "test" "baseline-system" "apply" ;;
        04-baseline-preflight) set_step_display_tags "test" "baseline-system" "preflight" ;;
        05-baseline-stage-images) set_step_display_tags "test" "baseline-system" "stage-images" ;;
        06-baseline-collection-a) set_step_display_tags "test" "baseline-system" "collection-a" ;;
        07-baseline-collection-b) set_step_display_tags "test" "baseline-system" "collection-b" ;;
        08-baseline-collection-c) set_step_display_tags "test" "baseline-system" "collection-c" ;;
        09-baseline-collection-e) set_step_display_tags "test" "baseline-system" "collection-e" ;;
        10-baseline-collection-d) set_step_display_tags "test" "baseline-system" "collection-d" ;;
        11-baseline-collection-f) set_step_display_tags "test" "baseline-system" "collection-f" ;;
        11a-baseline-collection-g) set_step_display_tags "test" "baseline-system" "collection-g" ;;
        12-baseline-collection-h) set_step_display_tags "test" "baseline-system" "collection-h" ;;
        12a-baseline-tc21) set_step_display_tags "test" "baseline-system" "tc21" ;;
        13-apply-cis-system) set_step_display_tags "test" "cis-system" "apply" ;;
        14-cis-container-operability) set_step_display_tags "test" "cis-system" "operability" ;;
        15-cis-preflight) set_step_display_tags "test" "cis-system" "preflight" ;;
        17-cis-collection-a) set_step_display_tags "test" "cis-system" "collection-a" ;;
        18-cis-collection-b) set_step_display_tags "test" "cis-system" "collection-b" ;;
        19-cis-collection-c) set_step_display_tags "test" "cis-system" "collection-c" ;;
        20-cis-collection-e) set_step_display_tags "test" "cis-system" "collection-e" ;;
        21-cis-collection-d) set_step_display_tags "test" "cis-system" "collection-d" ;;
        22-cis-collection-f) set_step_display_tags "test" "cis-system" "collection-f" ;;
        23-cis-collection-h) set_step_display_tags "test" "cis-system" "collection-h" ;;
        23a-cis-tc21) set_step_display_tags "test" "cis-system" "tc21" ;;
        24-cleanup) set_step_display_tags "cleanup" "restore" ;;
        24a-generate-reports) set_step_display_tags "analyze" "report" ;;
        25-final-summary) set_step_display_tags "final" "summary" ;;
        *) set_step_display_tags "orchestrator" "$step_id" ;;
    esac
}

emit_step_console_line() {
    local -r step_id="$1"
    local -r attention="${2:-}"
    local -r outcome="${3:-}"
    local -r step_override="${4:-}"
    local -r message="${5:-}"
    local rendered=""

    resolve_step_display_tags "$step_id"
    rendered="[$STEP_DISPLAY_TAG_1][$STEP_DISPLAY_TAG_2]"
    [ -n "$STEP_DISPLAY_TAG_3" ] && rendered="${rendered}[$STEP_DISPLAY_TAG_3]"
    printf '%s %s\n' "$rendered" "$message" >&2
}

strip_ansi_from_line() {
    printf '%s' "$1" | sed -E $'s/\x1B\\[0-9;]*[ -/]*[@-~]//g'
}

_PARSED_FIRST_TOKEN=""
_PARSED_SECOND_TOKEN=""
_PARSED_MESSAGE=""
_PARSED_THIRD_TOKEN=""
_PARSED_FOURTH_TOKEN=""

parse_double_token_line() {
    local parsed=""
    local -a parsed_parts=()

    parsed="$(printf '%s\n' "$1" | sed -nE 's/^\[([^][]+)\]\[([^][]+)\][ 	](.*)$/\1\n\2\n\3/p')"
    [ -n "$parsed" ] || return 1
    mapfile -t parsed_parts <<< "$parsed"
    _PARSED_FIRST_TOKEN="${parsed_parts[0]:-}"
    _PARSED_SECOND_TOKEN="${parsed_parts[1]:-}"
    _PARSED_MESSAGE="${parsed_parts[2]:-}"
}

parse_single_token_line() {
    local parsed=""
    local -a parsed_parts=()

    parsed="$(printf '%s\n' "$1" | sed -nE 's/^\[([^][]+)\][ 	](.*)$/\1\n\2/p')"
    [ -n "$parsed" ] || return 1
    mapfile -t parsed_parts <<< "$parsed"
    _PARSED_FIRST_TOKEN="${parsed_parts[0]:-}"
    _PARSED_MESSAGE="${parsed_parts[1]:-}"
    _PARSED_SECOND_TOKEN=""
}

parse_pipe_formatted_line() {
    local parsed=""
    local -a parsed_parts=()

    parsed="$(printf '%s\n' "$1" | sed -nE 's/^[0-9T:+.-]+[[:space:]]*\|[[:space:]]*([^|[:space:]]+)[[:space:]]*\|[[:space:]]*([^|[:space:]]+)[[:space:]]*\|[[:space:]]*([^|]+)[[:space:]]*\|[[:space:]]*([^|]+)[[:space:]]*\|[[:space:]]*(.*)$/\1\n\2\n\3\n\4\n\5/p')"
    [ -n "$parsed" ] || return 1
    mapfile -t parsed_parts <<< "$parsed"
    _PARSED_FIRST_TOKEN="${parsed_parts[0]:-}"
    _PARSED_SECOND_TOKEN="${parsed_parts[1]:-}"
    _PARSED_THIRD_TOKEN="$(printf '%s' "${parsed_parts[2]:-}" | sed 's/[[:space:]]*$//')"
    _PARSED_FOURTH_TOKEN="$(printf '%s' "${parsed_parts[3]:-}" | sed 's/[[:space:]]*$//')"
    _PARSED_MESSAGE="${parsed_parts[4]:-}"
}

classify_unstructured_line() {
    local normalized="${1,,}"

    case "$normalized" in
        error:*|fatal:*)
            _LINE_ATTENTION="WARN"
            _LINE_OUTCOME="ERROR"
            return 0
            ;;
        warn:*|warning:*)
            _LINE_ATTENTION="WARN"
            _LINE_OUTCOME="WARN"
            return 0
            ;;
        fail:*|failed:*)
            _LINE_ATTENTION="WARN"
            _LINE_OUTCOME="FAIL"
            return 0
            ;;
    esac

    return 1
}

log_info() {
    log_pipe "INFO" "orchestrator" "status" "$*"
}

log_error() {
    log_pipe "ERROR" "orchestrator" "status" "$*"
}

shell_join_quoted() {
    local quoted=""
    printf -v quoted '%q ' "$@"
    printf '%s' "${quoted% }"
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/}"
    printf '%s' "$value"
}

transient_startup_step_id() {
    case "$1" in
        03-apply-baseline)      printf '04-apply-baseline\n'      ;;
        04-baseline-preflight)         printf '05-baseline-preflight\n'         ;;
        05-baseline-stage-images)      printf '06-baseline-stage-images\n'      ;;
        06-baseline-collection-a)      printf '07-baseline-collection-a\n'      ;;
        07-baseline-collection-b)      printf '08-baseline-collection-b\n'      ;;
        08-baseline-collection-c)      printf '09-baseline-collection-c\n'      ;;
        09-baseline-collection-e)      printf '10-baseline-collection-e\n'      ;;
        10-baseline-collection-d)      printf '11-baseline-collection-d\n'      ;;
        11-baseline-collection-f)      printf '12-baseline-collection-f\n'      ;;
        11a-baseline-collection-g)     printf '12a-baseline-collection-g\n'     ;;
        12-baseline-collection-h)      printf '13-baseline-collection-h\n'      ;;
        13-apply-cis-system)           printf '14-apply-cis-system\n'           ;;
        14-cis-container-operability)  printf '15-cis-container-operability\n'  ;;
        15-cis-preflight)              printf '16-cis-preflight\n'              ;;
        17-cis-collection-a)           printf '18-cis-collection-a\n'           ;;
        18-cis-collection-b)           printf '19-cis-collection-b\n'           ;;
        19-cis-collection-c)           printf '20-cis-collection-c\n'           ;;
        20-cis-collection-e)           printf '21-cis-collection-e\n'           ;;
        21-cis-collection-d)           printf '22-cis-collection-d\n'           ;;
        22-cis-collection-f)           printf '23-cis-collection-f\n'           ;;
        23-cis-collection-h)           printf '24-cis-collection-h\n'           ;;
        24-cleanup)                    printf '25-cleanup\n'                    ;;
        24a-generate-reports)          printf '25a-generate-reports\n'          ;;
        25-final-summary)              printf '26-final-summary\n'              ;;
        *)                             return 1                                  ;;
    esac
}

should_skip_step() {
    local step_id="$1"
    local transient_id=""

    [ "$RESUME_MODE" = "true" ] || return 1
    [ -f "$MARKER_DIR/$step_id" ] && return 0

    if transient_id="$(transient_startup_step_id "$step_id" 2>/dev/null)"; then
        [ -f "$MARKER_DIR/$transient_id" ] && return 0
    fi

    return 1
}

record_step() {
    local -r step_id="$1"
    local -r status="$2"
    local -r exit_code="$3"
    local -r log_path="${4:-}"
    local -r message="${5:-}"
    local -r step_kind="${6:-operational}"
    local -r step_collection="${7:-}"
    local -r step_state="${8:-}"
    local -r step_runtime="${9:-$RUNTIME_SELECTION}"

    printf '{"timestamp":"%s","run_id":"%s","step":"%s","status":"%s","exit_code":%s,"log":"%s","message":"%s","step_kind":"%s","collection":"%s","environment_state":"%s","runtime_selection":"%s"}\n' \
        "$(date -Iseconds)" \
        "$(json_escape "$RUN_ID")" \
        "$(json_escape "$step_id")" \
        "$(json_escape "$status")" \
        "$exit_code" \
        "$(json_escape "$log_path")" \
        "$(json_escape "$message")" \
        "$(json_escape "$step_kind")" \
        "$(json_escape "$step_collection")" \
        "$(json_escape "$step_state")" \
        "$(json_escape "$step_runtime")" \
        >> "$STATUS_FILE"
}

stream_step_log() {
    local -r step_id="$1"
    local -r log_path="$2"
    local -r command_pid="$3"
    local line=""
    local clean_line=""
    local first_token=""
    local second_token=""
    local third_token=""
    local fourth_token=""
    local message=""

    tail --pid="$command_pid" -n +1 -f "$log_path" 2>/dev/null | while IFS= read -r line; do
        [ -n "$line" ] || continue
        line="${line%$'\r'}"
        clean_line="$(strip_ansi_from_line "$line")"

        if parse_pipe_formatted_line "$clean_line"; then
            first_token="$_PARSED_FIRST_TOKEN"
            second_token="$_PARSED_SECOND_TOKEN"
            third_token="$_PARSED_THIRD_TOKEN"
            fourth_token="$_PARSED_FOURTH_TOKEN"
            message="$_PARSED_MESSAGE"
            resolve_line_classification "$second_token" "$message"
            emit_step_console_line "$step_id" "$_LINE_ATTENTION" "$_LINE_OUTCOME" "${fourth_token:-$third_token}" "$message"
            continue
        fi

        if parse_double_token_line "$clean_line"; then
            first_token="$_PARSED_FIRST_TOKEN"
            second_token="$_PARSED_SECOND_TOKEN"
            message="$_PARSED_MESSAGE"
            resolve_line_classification "$second_token" "$message"
            emit_step_console_line "$step_id" "$_LINE_ATTENTION" "$_LINE_OUTCOME" "$first_token" "$message"
            continue
        fi

        if parse_single_token_line "$clean_line"; then
            first_token="$_PARSED_FIRST_TOKEN"
            message="$_PARSED_MESSAGE"
            if is_known_level_token "$first_token"; then
                resolve_line_classification "$first_token" "$message"
                emit_step_console_line "$step_id" "$_LINE_ATTENTION" "$_LINE_OUTCOME" "" "$message"
            else
                emit_step_console_line "$step_id" "INFO" "INFO" "$first_token" "$message"
            fi
            continue
        fi

        if classify_unstructured_line "$clean_line"; then
            emit_step_console_line "$step_id" "$_LINE_ATTENTION" "$_LINE_OUTCOME" "" "$clean_line"
        else
            emit_step_console_line "$step_id" "INFO" "INFO" "" "$clean_line"
        fi
    done
}

execute_step_command() {
    local -r step_id="$1"
    local -r log_path="$2"
    shift 2
    local status=0
    local command_pid=0

    : > "$log_path"

    set +e
    "$@" > "$log_path" 2>&1 &
    command_pid=$!
    stream_step_log "$step_id" "$log_path" "$command_pid"
    wait "$command_pid"
    status=$?
    set -e

    return "$status"
}

run_step() {
    local -r step_id="$1"
    local -r description="$2"
    shift 2
    local -r log_path="$LOG_DIR/${step_id}.log"
    local status=0
    local step_outcome=""

    if should_skip_step "$step_id"; then
        record_step "$step_id" "skip" 0 "$log_path" "$description" "operational"
        emit_step_console_line "$step_id" "WARN" "SKIP" "" "SKIP ${step_id} (already completed)"
        return 0
    fi

    emit_step_console_line "$step_id" "INFO" "INFO" "" "START ${step_id}: ${description}"
    record_step "$step_id" "start" 0 "$log_path" "$description" "operational"

    if execute_step_command "$step_id" "$log_path" "$@"; then
        status=0
    else
        status=$?
    fi

    if [ "$status" -eq 0 ]; then
        : > "$MARKER_DIR/$step_id"
        record_step "$step_id" "pass" 0 "$log_path" "$description" "operational"
        emit_step_console_line "$step_id" "INFO" "PASS" "" "PASS ${step_id}"
        return 0
    fi

    if [ "$status" -eq 1 ]; then
        step_outcome="$(aggregate_collection_status "$CLD6001_RUN_ROOT/runner/$step_id")"
        if [ "$step_outcome" != "fail" ]; then
            : > "$MARKER_DIR/$step_id"
            record_step "$step_id" "pass_with_findings" 0 "$log_path" "$description" "operational"
            emit_step_console_line "$step_id" "INFO" "PARTIAL" "" "PASS_WITH_FINDINGS ${step_id} (runner exit ${status}); research findings recorded"
            return 0
        fi
    fi

    record_step "$step_id" "fail" "$status" "$log_path" "$description" "operational"
    emit_step_console_line "$step_id" "WARN" "FAIL" "" "FAIL ${step_id} (exit ${status}); see ${log_path}"
    return "$status"
}

aggregate_collection_status() {
    local dir="$1"
    local found_any=false
    local found_fail=false
    local found_findings=false
    local status_path=""
    local collection_status=""

    while IFS= read -r status_path; do
        [ -n "$status_path" ] || continue
        found_any=true
        collection_status="$(jq -r '.status // empty' "$status_path" 2>/dev/null || true)"
        case "$collection_status" in
            pass) ;;
            pass_with_findings) found_findings=true ;;
            *) found_fail=true ;;
        esac
    done < <(find "$dir" -maxdepth 2 -name "requested-collection-status.json" 2>/dev/null || true)

    if [ "$found_fail" = "true" ]; then
        printf 'fail\n'
    elif [ "$found_findings" = "true" ]; then
        printf 'pass_with_findings\n'
    elif [ "$found_any" = "true" ]; then
        printf 'pass\n'
    else
        printf 'fail\n'
    fi
}

run_collection_step() {
    local -r step_id="$1"
    local -r description="$2"
    local -r collection="$3"
    local -r state="$4"
    local -r log_path="$LOG_DIR/${step_id}.log"
    local status=0
    local collection_outcome=""

    if should_skip_step "$step_id"; then
        record_step "$step_id" "skip" 0 "$log_path" "$description" "collection" "$collection" "$state"
        emit_step_console_line "$step_id" "WARN" "SKIP" "" "SKIP ${step_id} (already completed)"
        return 0
    fi

    emit_step_console_line "$step_id" "INFO" "INFO" "" "START ${step_id}: ${description}"
    record_step "$step_id" "start" 0 "$log_path" "$description" "collection" "$collection" "$state"

    if execute_step_command "$step_id" "$log_path" run_collection_step_impl "$step_id" "$collection" "$state"; then
        status=0
    else
        status=$?
    fi

    if [ "$status" -gt 1 ]; then
        record_step "$step_id" "fail" "$status" "$log_path" "$description" "collection" "$collection" "$state"
        emit_step_console_line "$step_id" "WARN" "FAIL" "" "FAIL ${step_id} (exit ${status}); see ${log_path}"
        return "$status"
    fi

    if [ "$status" -eq 0 ]; then
        : > "$MARKER_DIR/$step_id"
        record_step "$step_id" "pass" 0 "$log_path" "$description" "collection" "$collection" "$state"
        emit_step_console_line "$step_id" "INFO" "PASS" "" "PASS ${step_id}"
        return 0
    fi

    collection_outcome="$(aggregate_collection_status "$CLD6001_RUN_ROOT/runner/$step_id")"
    if [ "$collection_outcome" = "fail" ]; then
        record_step "$step_id" "fail" "$status" "$log_path" "$description" "collection" "$collection" "$state"
        emit_step_console_line "$step_id" "WARN" "FAIL" "" "FAIL ${step_id} (exit ${status}); see ${log_path}"
        return "$status"
    fi

    : > "$MARKER_DIR/$step_id"
    record_step "$step_id" "pass_with_findings" 0 "$log_path" "$description" "collection" "$collection" "$state"
    emit_step_console_line "$step_id" "INFO" "PARTIAL" "" "PASS_WITH_FINDINGS ${step_id} (runner exit ${status}); research findings recorded"
    return 0
}

require_repo_file() {
    local -r path="$1"
    [ -f "$REPO_ROOT/$path" ] || {
        printf 'Required repo file missing: %s\n' "$path" >&2
        return 1
    }
}

require_repo_executable() {
    local -r path="$1"
    require_repo_file "$path" || return 1
    [ -x "$REPO_ROOT/$path" ] || chmod +x "$REPO_ROOT/$path"
}

sudo_refresh() {
    cld6001_sudo_refresh "src/execute/server-orchestrator.sh startup"
}

sudo_noninteractive() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo -n "$@"
    fi
}

orchestrator_sudo_user() {
    if [ -n "${CLD6001_ORCHESTRATOR_SUDO_USER:-}" ]; then
        printf '%s\n' "$CLD6001_ORCHESTRATOR_SUDO_USER"
    elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        printf '%s\n' "$SUDO_USER"
    else
        id -un
    fi
}

ensure_passwordless_sudo() {
    local target_user=""
    local sudoers_dir=""

    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi

    sudo_refresh
    target_user="$(orchestrator_sudo_user)"
    sudoers_dir="$(dirname -- "$ORCHESTRATOR_SUDOERS_PATH")"

    sudo_noninteractive mkdir -p -- "$sudoers_dir"
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$target_user" | sudo_noninteractive tee "$ORCHESTRATOR_SUDOERS_PATH" >/dev/null
    sudo_noninteractive chmod 0440 "$ORCHESTRATOR_SUDOERS_PATH"
    sudo_noninteractive visudo -cf "$ORCHESTRATOR_SUDOERS_PATH" >/dev/null
    sudo_noninteractive true
}

enter_noninteractive_orchestration() {
    if cld6001_noninteractive_requested; then
        return 0
    fi

    log_info "Switching server-orchestrator to noninteractive stdin after bootstrap"
    cld6001_detach_stdin_to_devnull
}

bootstrap_prerequisites() {
    local -a required_commands=(gcc make jq curl git tar gzip pigz unzip python3 oscap)
    local -a missing_packages=()
    local command_name=""

    ensure_temp_work_symlink
    sudo_refresh
    ensure_passwordless_sudo

    for command_name in "${required_commands[@]}"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            case "$command_name" in
                oscap)
                    missing_packages+=(openscap-scanner scap-security-guide)
                    ;;
                *)
                    missing_packages+=("$command_name")
                    ;;
            esac
        fi
    done

    if ! python3 -c 'import scipy' >/dev/null 2>&1; then
        missing_packages+=(python3-scipy)
    fi

    if [ "${#missing_packages[@]}" -gt 0 ]; then
        sudo_noninteractive dnf install -y --disableexcludes=all "${missing_packages[@]}"
    fi

    for command_name in "${required_commands[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 || {
            printf 'Missing required command after bootstrap: %s\n' "$command_name" >&2
            return 1
        }
    done

    python3 -c 'import scipy' >/dev/null 2>&1 || {
        printf 'Missing required Python module after bootstrap: scipy\n' >&2
        return 1
    }
}

warn_operability_image_override() {
    if [ "$OPERABILITY_IMAGE" != "$OPERABILITY_IMAGE_DEFAULT" ]; then
        log_warn "OPERABILITY_IMAGE overridden to '$OPERABILITY_IMAGE' - ensure this is a trusted image"
    fi
}

verify_repo_layout() {
    require_repo_executable "src/execute/test-runner.sh"
    require_repo_executable "src/setup/apply-state.sh"
    require_repo_executable "src/setup/pull-images.sh"
    require_repo_file "src/execute/collections/registry.sh"
    require_repo_file "src/analyze/reports/report-generator.py"
    require_repo_file "src/analyze/reports/statistical-analysis.py"
    require_repo_file "src/analyze/reports/results-matrix-generator.py"
    warn_operability_image_override
}

should_authenticate_dhi() {
    [ -n "${DOCKER_USERNAME:-}" ] && [ -n "${DOCKER_TOKEN:-}" ]
}

login_dhi_rootful_docker() {
    printf '%s\n' "$DOCKER_TOKEN" | sudo_noninteractive docker login -u "$DOCKER_USERNAME" --password-stdin dhi.io
}

login_dhi_rootless_docker() {
    local -r rootless_home="$1"
    local -r rootless_runtime_dir="$2"
    local -r rootless_dbus="$3"

    printf '%s\n' "$DOCKER_TOKEN" | env \
        HOME="$rootless_home" \
        XDG_RUNTIME_DIR="$rootless_runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="$rootless_dbus" \
        DOCKER_HOST="unix://${rootless_runtime_dir}/docker.sock" \
        docker login -u "$DOCKER_USERNAME" --password-stdin dhi.io
}

login_dhi_rootless_podman() {
    local -r rootless_home="$1"
    local -r rootless_runtime_dir="$2"
    local -r rootless_dbus="$3"

    printf '%s\n' "$DOCKER_TOKEN" | env \
        HOME="$rootless_home" \
        XDG_RUNTIME_DIR="$rootless_runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="$rootless_dbus" \
        podman login -u "$DOCKER_USERNAME" --password-stdin dhi.io
}

authenticate_dhi_for_runtime() {
    local -r runtime="$1"
    local -r rootless_home="$2"
    local -r rootless_runtime_dir="$3"
    local -r rootless_dbus="$4"

    should_authenticate_dhi || return 0

    case "$runtime" in
        docker-rootful)
            login_dhi_rootful_docker
            ;;
        docker-rootless)
            login_dhi_rootless_docker "$rootless_home" "$rootless_runtime_dir" "$rootless_dbus"
            ;;
        podman-rootless)
            login_dhi_rootless_podman "$rootless_home" "$rootless_runtime_dir" "$rootless_dbus"
            ;;
    esac
}

apply_environment_state_all() {
    local -r state="$1"
    local runtime=""
    local results_dir=""

    for runtime in "${RESOLVED_RUNTIMES[@]}"; do
        results_dir="$ORCH_DIR/environment-states/$state/$runtime"
        bash "$REPO_ROOT/src/setup/apply-state.sh" apply \
            --state "$state" \
            --runtime "$runtime" \
            --results-dir "$results_dir"
    done
}

run_test_runner_step() {
    local -r suite_name="$1"
    local payload=""
    shift
    local -a runner_command=(bash "$REPO_ROOT/src/execute/test-runner.sh" "$@")
    local -a runner_env=(
        CLD6001_RUN_ID="$CLD6001_RUN_ID"
        CLD6001_RUN_ROOT="$CLD6001_RUN_ROOT"
        CLD6001_RESULTS_ROOT="$CLD6001_RESULTS_ROOT"
        RUNNER_SOURCE_REPO_ROOT="$REPO_ROOT"
        RESULTS_ROOT="$CLD6001_RUN_ROOT/runner/$suite_name"
        ORCH_TEST_LOG="${ORCH_TEST_LOG:-}"
        RUNNER_STAGE_RUNTIME_IMAGES=false
    )

    ensure_runner_host_safety_approval_fd
    runner_env+=(CLD6001_HOST_SAFETY_APPROVAL_FD="$HOST_SAFETY_APPROVAL_FD")
    runner_env+=(CLD6001_HOST_SAFETY_APPROVAL_BOOTSTRAP_SOURCE_FD="$HOST_SAFETY_APPROVAL_BOOTSTRAP_SOURCE_FD")
    runner_env+=(BASH_ENV="$HOST_SAFETY_APPROVAL_BOOTSTRAP_HELPER")

    if orchestrator_relaxed_debug_enabled; then
        runner_command+=(--relaxed-debug)
    else
        runner_env+=(RUNNER_RELAXED_DEBUG=false)
        runner_env+=(RUNNER_ENFORCE_ENVIRONMENT_STATE=true)
    fi

    if should_use_docker_group_shell; then
        payload="$(shell_join_quoted env "${runner_env[@]}" "${runner_command[@]}")"
        sg docker -c "$payload"
        return
    fi

    env "${runner_env[@]}" "${runner_command[@]}"
}

run_collection_step_impl() {
    local step_label="$1"
    local collection="$2"
    local state="$3"
    local runtime=""
    local status=0
    local rc=0

    for runtime in "${RESOLVED_RUNTIMES[@]}"; do
        run_test_runner_step "$step_label/$runtime" \
            --test-collection "$collection" \
            --runtime "$runtime" \
            --environment-state "$state"
        rc=$?
        [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || return "$rc"
        [ "$rc" -eq 0 ] || status=1
    done

    return "$status"
}

run_testcase_step_impl() {
    local step_label="$1"
    local testcase="$2"
    local state="$3"
    local runtime=""
    local status=0
    local rc=0

    for runtime in "${RESOLVED_RUNTIMES[@]}"; do
        run_test_runner_step "$step_label/$runtime" \
            --testcase "$testcase" \
            --runtime "$runtime" \
            --environment-state "$state"
        rc=$?
        [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || return "$rc"
        [ "$rc" -eq 0 ] || status=1
    done

    return "$status"
}

stage_runtime_images() {
    local runtime=""
    local rootless_user=""
    local rootless_uid=""
    local rootless_home=""
    local rootless_runtime_dir=""
    local rootless_dbus=""
    local -a rootful_stage_env=()

    rootless_user="$(orchestrator_sudo_user)"
    rootless_uid="$(id -u "$rootless_user")"
    rootless_home="$(getent passwd "$rootless_user" | cut -d: -f6)"
    rootless_runtime_dir="/run/user/${rootless_uid}"
    rootless_dbus="unix:path=${rootless_runtime_dir}/bus"

    for runtime in "${RESOLVED_RUNTIMES[@]}"; do
        case "$runtime" in
            docker-rootful)
                authenticate_dhi_for_runtime "$runtime" "$rootless_home" "$rootless_runtime_dir" "$rootless_dbus"
                rootful_stage_env=(CLD6001_PULL_IMAGES_STRICT=true CONTAINER_RUNTIME=docker)
                if [ -n "${ORCH_TEST_LOG:-}" ]; then
                    rootful_stage_env=(ORCH_TEST_LOG="$ORCH_TEST_LOG" "${rootful_stage_env[@]}")
                fi
                sudo_noninteractive env "${rootful_stage_env[@]}" bash "$REPO_ROOT/src/setup/pull-images.sh" --primary --dhi
                ;;
            docker-rootless)
                authenticate_dhi_for_runtime "$runtime" "$rootless_home" "$rootless_runtime_dir" "$rootless_dbus"
                env \
                    HOME="$rootless_home" \
                    XDG_RUNTIME_DIR="$rootless_runtime_dir" \
                    DBUS_SESSION_BUS_ADDRESS="$rootless_dbus" \
                    DOCKER_HOST="unix://${rootless_runtime_dir}/docker.sock" \
                    CLD6001_PULL_IMAGES_STRICT=true \
                    CONTAINER_RUNTIME=docker \
                    bash "$REPO_ROOT/src/setup/pull-images.sh" --primary --dhi
                ;;
            podman-rootless)
                authenticate_dhi_for_runtime "$runtime" "$rootless_home" "$rootless_runtime_dir" "$rootless_dbus"
                env \
                    HOME="$rootless_home" \
                    XDG_RUNTIME_DIR="$rootless_runtime_dir" \
                    DBUS_SESSION_BUS_ADDRESS="$rootless_dbus" \
                    CLD6001_PULL_IMAGES_STRICT=true \
                    CONTAINER_RUNTIME=podman \
                    bash "$REPO_ROOT/src/setup/pull-images.sh" --primary --dhi
                ;;
            *)
                printf 'Unsupported runtime for image staging: %s\n' "$runtime" >&2
                return 1
                ;;
        esac
    done
}

cis_preflight() {
    run_test_runner_step cis-preflight --runtime "$RUNTIME_SELECTION" --environment-state cis-system --strict-prereqs
}

runtime_command_prefix() {
    local -r runtime="$1"
    local uid=""

    case "$runtime" in
        docker-rootful)
            printf '%s\n' "docker"
            ;;
        docker-rootless)
            uid="$(id -u)"
            printf '%s\n' "env DOCKER_HOST=unix:///run/user/${uid}/docker.sock docker"
            ;;
        podman-rootless)
            printf '%s\n' "podman"
            ;;
        *)
            printf 'Unsupported runtime for operability: %s\n' "$runtime" >&2
            return 1
            ;;
    esac
}

should_use_docker_group_shell() {
    local user_name=""

    [ "$(id -u)" -ne 0 ] || return 1
    command -v sg >/dev/null 2>&1 || return 1
    getent group docker >/dev/null 2>&1 || return 1

    user_name="$(id -un)"
    id -nG "$user_name" 2>/dev/null | tr ' ' '\n' | grep -Fx docker >/dev/null
}

run_runtime_command() {
    local -r runtime="$1"
    shift
    local prefix=""
    local -a command_parts=()
    local payload=""

    prefix="$(runtime_command_prefix "$runtime")" || return 1
    command_parts=($prefix)

    if [ "$runtime" = "docker-rootful" ] && should_use_docker_group_shell; then
        payload="$(shell_join_quoted "${command_parts[@]}" "$@")"
        sg docker -c "$payload"
        return
    fi

    "${command_parts[@]}" "$@"
}

check_runtime_operability() {
    local -r runtime="$1"
    local work_dir="$ORCH_DIR/operability/$runtime"
    local mount_dir="$work_dir/mount"
    local status=0

    mkdir -p -- "$mount_dir"
    printf 'cld6001-host-file\n' > "$mount_dir/input.txt"

    if ! run_runtime_command "$runtime" pull "$OPERABILITY_IMAGE"; then
        status=1
    fi
    if ! run_runtime_command "$runtime" run --rm "$OPERABILITY_IMAGE" sh -c 'printf "cld6001-container-ok\n"'; then
        status=1
    fi
    if ! run_runtime_command "$runtime" run --rm "$OPERABILITY_IMAGE" sh -c 'if test -s /proc/net/route || ip route show 2>/dev/null | grep -q .; then printf "cld6001-network-ok\n"; else exit 1; fi'; then
        status=1
    fi
    if ! run_runtime_command "$runtime" run --rm -v "${mount_dir}:/mnt/cld6001:Z" "$OPERABILITY_IMAGE" sh -c 'test -r /mnt/cld6001/input.txt && printf "cld6001-container-write\n" > /mnt/cld6001/output.txt'; then
        status=1
    fi

    return "$status"
}

cis_container_operability() {
    local runtime=""
    local status=0

    for runtime in "${RESOLVED_RUNTIMES[@]}"; do
        if ! check_runtime_operability "$runtime"; then
            status=1
        fi
    done

    return "$status"
}

status_priority() {
    case "$1" in
        fail|error|invalid) printf '3\n' ;;
        pass_with_findings|warn|warning|partial) printf '2\n' ;;
        pass|ok|success) printf '1\n' ;;
        *) printf '0\n' ;;
    esac
}

merge_status_value() {
    local current="${1:-}"
    local candidate="${2:-}"

    if [ "$(status_priority "$candidate")" -gt "$(status_priority "$current")" ]; then
        printf '%s\n' "$candidate"
    else
        printf '%s\n' "$current"
    fi
}

synthesize_aggregate_results_root() {
    local synth_root="$CLD6001_RUN_ROOT/reports-input"
    local collection=""
    local collection_dir=""
    local source_filename=""
    local destination_filename=""
    local runtime=""
    local step_pattern=""
    local selected_path=""
    local -a selected_paths=()
    local -a runtimes=(
        docker-rootful
        docker-rootless
        podman-rootless
    )

    rm -rf -- "$synth_root"
    mkdir -p -- "$synth_root"

    for collection in preflight a b c e d f h; do
        collection_dir="collection-$collection"
        source_filename="collection-$collection-results.json"
        destination_filename="$source_filename"
        if [ "$collection" = "preflight" ]; then
            collection_dir="collection-preflight"
            source_filename="collection-preflight-results.json"
            destination_filename="preflight-results.json"
        fi

        selected_paths=()
        for runtime in "${runtimes[@]}"; do
            case "$collection" in
                preflight)
                    for step_pattern in "*-baseline-preflight" "*-cis-preflight"; do
                        selected_path="$(
                            find "$CLD6001_RUN_ROOT/runner" \
                                -path "*/${step_pattern}/${runtime}/${collection_dir}/${source_filename}" \
                                2>/dev/null \
                                | LC_ALL=C sort \
                                | tail -n 1
                        )"
                        [ -n "$selected_path" ] || continue
                        selected_paths+=("$selected_path")
                    done
                    ;;
                *)
                    for step_pattern in "*-baseline-collection-${collection}" "*-cis-collection-${collection}"; do
                        selected_path="$(
                            find "$CLD6001_RUN_ROOT/runner" \
                                -path "*/${step_pattern}/${runtime}/${collection_dir}/${source_filename}" \
                                2>/dev/null \
                                | LC_ALL=C sort \
                                | tail -n 1
                        )"
                        [ -n "$selected_path" ] || continue
                        selected_paths+=("$selected_path")
                    done
                    ;;
            esac
        done

        [ "${#selected_paths[@]}" -gt 0 ] || continue

        mkdir -p -- "$synth_root/$collection_dir"
        jq -s 'reduce .[] as $item ({}; . * $item)' \
            "${selected_paths[@]}" \
            > "$synth_root/$collection_dir/$destination_filename"

        if [ "$collection" = "preflight" ]; then
            cp -- \
                "$synth_root/$collection_dir/$destination_filename" \
                "$synth_root/$collection_dir/$source_filename"
        fi
    done

    printf '%s\n' "$synth_root"
}

generate_aggregate_reports() {
    local reports_dir="$CLD6001_RUN_ROOT/reports"
    local aggregate_results_root=""

    mkdir -p -- "$reports_dir"
    aggregate_results_root="$(synthesize_aggregate_results_root)"

    python3 "$REPO_ROOT/src/analyze/reports/report-generator.py" \
        --input "$aggregate_results_root" \
        --output "$reports_dir/security-research-report.md"
    python3 "$REPO_ROOT/src/analyze/reports/statistical-analysis.py" \
        --input "$aggregate_results_root" \
        --output "$reports_dir/statistical-analysis-report.json"
    python3 "$REPO_ROOT/src/analyze/reports/results-matrix-generator.py" \
        --input "$aggregate_results_root" \
        --output "$reports_dir/security-research-results-matrix.json"
}

write_final_summary() {
    local summary="$ORCH_DIR/orchestrator-summary.txt"
    local requested_statuses=""
    local status_file=""
    local key=""
    local env_state=""
    local collection=""
    local status_val=""
    local runtime_key=""
    local runtime_name=""
    local runtime_status=""
    local runtime_detail=""
    local pair=""
    local overall_status=""
    local -a ordered_keys=()
    declare -A requested_collection_status=()
    declare -A requested_collection_runtime_status=()

    while IFS= read -r status_file; do
        [ -n "$status_file" ] || continue
        env_state="$(jq -r '.environment_state // empty' "$status_file" 2>/dev/null || true)"
        collection="$(jq -r '.collection // empty' "$status_file" 2>/dev/null || true)"
        status_val="$(jq -r '.status // empty' "$status_file" 2>/dev/null || true)"
        key="${env_state:-unknown}|${collection:-unknown}"

        if [ -z "${requested_collection_status[$key]+x}" ]; then
            ordered_keys+=("$key")
        fi
        requested_collection_status["$key"]="$(merge_status_value "${requested_collection_status[$key]:-}" "$status_val")"

        while IFS=$'\t' read -r runtime_name runtime_status; do
            [ -n "$runtime_name" ] || continue
            runtime_key="$key|$runtime_name"
            requested_collection_runtime_status["$runtime_key"]="$(merge_status_value "${requested_collection_runtime_status[$runtime_key]:-}" "$runtime_status")"
            requested_collection_status["$key"]="$(merge_status_value "${requested_collection_status[$key]:-}" "$runtime_status")"
        done < <(jq -r '.runtime_outcomes // {} | to_entries[]? | "\(.key)\t\(.value)"' "$status_file" 2>/dev/null || true)

        runtime_name="$(jq -r '.runtime_selection // empty' "$status_file" 2>/dev/null || true)"
        if [ -n "$runtime_name" ] \
            && [ -n "$status_val" ] \
            && [ "$(jq -r '(.runtime_outcomes // {} | length)' "$status_file" 2>/dev/null || printf '0')" = "0" ]; then
            runtime_key="$key|$runtime_name"
            requested_collection_runtime_status["$runtime_key"]="$(merge_status_value "${requested_collection_runtime_status[$runtime_key]:-}" "$status_val")"
        fi
    done < <(find "$CLD6001_RUN_ROOT/runner" -name "requested-collection-status.json" 2>/dev/null || true)

    for key in "${ordered_keys[@]}"; do
        env_state="${key%%|*}"
        collection="${key#*|}"
        overall_status="${requested_collection_status[$key]:-}"
        runtime_detail=""
        pair=""
        for runtime_name in docker-rootful docker-rootless podman-rootless; do
            runtime_key="$key|$runtime_name"
            runtime_status="${requested_collection_runtime_status[$runtime_key]:-}"
            [ -n "$runtime_status" ] || continue
            if [ -n "$pair" ]; then
                pair+=", "
            fi
            pair+="${runtime_name}=${runtime_status}"
        done
        [ -n "$pair" ] && runtime_detail=" (runtimes: ${pair})"
        if [ "$overall_status" != "pass" ] && [ -n "$overall_status" ]; then
            requested_statuses+="${env_state} collection ${collection}: ${overall_status}${runtime_detail}"$'\n'
        fi
    done

    {
        printf 'CLD6001 server-orchestrator run\n'
        printf 'Run ID: %s\n' "$RUN_ID"
        printf 'Run root: %s\n' "$CLD6001_RUN_ROOT"
        printf 'Runtime selection: %s\n' "$RUNTIME_SELECTION"
        printf 'Completed at: %s\n' "$(date -Iseconds)"
        printf '\nStatus records:\n'
        cat "$STATUS_FILE"
        if [ -n "$requested_statuses" ]; then
            printf '\nRequested collection outcomes:\n%s\n' "$requested_statuses"
        fi
    } > "$summary"
}

promote_to_artifacts() {
    local run_type="${1:-full}"
    local artifacts_dir="$REPO_ROOT/artifacts/$RUN_ID"
    local reports_src="$CLD6001_RUN_ROOT/reports"

    mkdir -p "$artifacts_dir/export" "$artifacts_dir/evidence" "$artifacts_dir/run-info"

    if [[ -d "$reports_src" ]]; then
        cp -a "$reports_src"/* "$artifacts_dir/export/" 2>/dev/null || true
    fi

    if [[ -d "$CLD6001_RUN_ROOT/runner" ]]; then
        cp -a "$CLD6001_RUN_ROOT/runner/." "$artifacts_dir/evidence/" 2>/dev/null || true
    fi

    printf '{"run_id":"%s","run_type":"%s","timestamp":"%s","hostname":"%s"}\n' \
        "$RUN_ID" "$run_type" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" \
        > "$artifacts_dir/run-info/run-metadata.json"
    cp "$ORCH_DIR/orchestrator-summary.txt" "$artifacts_dir/run-info/" 2>/dev/null || true
    cp "$ORCH_DIR/orchestrator-status.jsonl" "$artifacts_dir/run-info/" 2>/dev/null || true

    if [[ "$run_type" == "partial" ]]; then
        rm -f "$artifacts_dir/export/security-research-report.md" 2>/dev/null || true
        rm -f "$artifacts_dir/export/security-research-results-matrix.json" 2>/dev/null || true
    fi

    log_pipe "promote" "artifacts" "Promoted to artifacts/$RUN_ID ($run_type run)"
}

targeted_run() {
    log_info "CLD6001 server-orchestrator targeted run: $RUN_ID"
    log_info "  state=$TARGETED_STATE collection=${TARGETED_COLLECTION:-*} testcase=${TARGETED_TESTCASE:-*}"

    log_info "Applying environment state: $TARGETED_STATE"
    apply_environment_state_all "$TARGETED_STATE"

    local runner_args=(--environment-state "$TARGETED_STATE" --runtime "$RUNTIME_SELECTION")

    if [ -n "$TARGETED_TESTCASE" ]; then
        runner_args+=(--testcase "$TARGETED_TESTCASE")
    elif [ -n "$TARGETED_COLLECTION" ]; then
        runner_args+=(--test-collection "$TARGETED_COLLECTION")
    fi

    local suite_name="targeted-${TARGETED_STATE}-${TARGETED_TESTCASE:-${TARGETED_COLLECTION:-all}}"
    run_test_runner_step "$suite_name" "${runner_args[@]}"
    promote_to_artifacts "partial"

    log_info "CLD6001 targeted run completed"
}

main() {
    log_info "CLD6001 server-orchestrator run: $RUN_ID"
    log_info "Orchestrator directory: $ORCH_DIR"

    run_step "01-bootstrap-prerequisites" "Install and verify host prerequisites before any preflight" bootstrap_prerequisites
    enter_noninteractive_orchestration
    run_step "02-verify-repo-layout" "Verify required repository files and profiles are present" verify_repo_layout
    run_step "03-apply-baseline" "Apply baseline host/runtime state for selected runtimes" apply_environment_state_all baseline-system
    run_collection_step "04-baseline-preflight" "Run baseline preflight checks" "preflight" "baseline-system"
    run_step "05-baseline-stage-images" "Stage active suite images for baseline runtimes" stage_runtime_images
    run_collection_step "06-baseline-collection-a" "Run baseline collection a (boundary foundation)" "a" "baseline-system"
    run_collection_step "07-baseline-collection-b" "Run baseline collection b (image supply chain)" "b" "baseline-system"
    run_collection_step "08-baseline-collection-c" "Run baseline collection c (capability/namespace)" "c" "baseline-system"
    run_collection_step "09-baseline-collection-e" "Run baseline collection e (seccomp)" "e" "baseline-system"
    run_collection_step "10-baseline-collection-d" "Run baseline collection d (selinux)" "d" "baseline-system"
    run_collection_step "11-baseline-collection-f" "Run baseline collection f (combined exploration)" "f" "baseline-system"
    run_collection_step "11a-baseline-collection-g" "Run baseline collection g (page-cache attacks)" "g" "baseline-system"
    run_collection_step "12-baseline-collection-h" "Run baseline collection h (post-hardening)" "h" "baseline-system"
    run_step "12a-baseline-tc21" "Generate baseline TC21 control-impact synthesis" run_testcase_step_impl "12a-baseline-tc21" "tc21-control-impact-matrix" "baseline-system"
    run_step "13-apply-cis-system" "Apply OpenSCAP CIS host and CIS runtime hardening" apply_environment_state_all cis-system
    run_step "14-cis-container-operability" "Verify normal container operations still work under CIS hardening" cis_container_operability
    run_collection_step "15-cis-preflight" "Run CIS preflight checks" "preflight" "cis-system"
    run_collection_step "17-cis-collection-a" "Run CIS collection a (boundary foundation)" "a" "cis-system"
    run_collection_step "18-cis-collection-b" "Run CIS collection b (image supply chain)" "b" "cis-system"
    run_collection_step "19-cis-collection-c" "Run CIS collection c (capability/namespace)" "c" "cis-system"
    run_collection_step "20-cis-collection-e" "Run CIS collection e (seccomp)" "e" "cis-system"
    run_collection_step "21-cis-collection-d" "Run CIS collection d (selinux)" "d" "cis-system"
    run_collection_step "22-cis-collection-f" "Run CIS collection f (combined exploration)" "f" "cis-system"
    run_collection_step "23-cis-collection-h" "Run CIS collection h (post-hardening)" "h" "cis-system"
    run_step "23a-cis-tc21" "Generate CIS TC21 control-impact synthesis" run_testcase_step_impl "23a-cis-tc21" "tc21-control-impact-matrix" "cis-system"
    run_collection_step "24-cleanup" "Run final host restoration and cleanup" "cleanup" "cis-system"
    run_step "24a-generate-reports" "Generate aggregate research reports" generate_aggregate_reports
    run_step "25-final-summary" "Write final orchestrator summary" write_final_summary
    promote_to_artifacts "full"

    log_info "CLD6001 server-orchestrator completed successfully"
}

if [ "$TARGETED_MODE" = "true" ]; then
    targeted_run
else
    main "$@"
fi
