#!/bin/bash

set -Eeuo pipefail
COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TESTS_REPO_ROOT="$(cd "${COMMON_SH_DIR}/../.." && pwd -P)"
source "${TESTS_REPO_ROOT}/src/shared/terminal-colors.sh"
source "${TESTS_REPO_ROOT}/src/execute/run-context.sh"
PULL_IMAGES_HELPER_LOADED=false

resolve_path_within_base() {
    local base_dir="$1"
    local target_path="${2:-}"
    local candidate_path=""
    local resolved_base=""
    local resolved_candidate=""

    resolved_base="$(cd -- "$base_dir" 2>/dev/null && pwd -P)" || return 1

    case "$target_path" in
        "")
            printf '%s\n' "$resolved_base"
            return 0
            ;;
        /*)
            candidate_path="$target_path"
            ;;
        ../*|*/../*|..)
            candidate_path="${resolved_base}/${target_path}"
            ;;
        ./*)
            candidate_path="${resolved_base}/${target_path#./}"
            ;;
        *)
            candidate_path="${resolved_base}/${target_path}"
            ;;
    esac

    resolved_candidate="$(realpath -m -- "$candidate_path")" || return 1
    case "$resolved_candidate" in
        "$resolved_base"|"$resolved_base"/*)
            printf '%s\n' "$resolved_candidate"
            ;;
        *)
            printf 'Path escapes repository root: %s\n' "$target_path" >&2
            return 1
            ;;
    esac
}

resolve_repo_path() {
    local target_path="${1:-}"
    resolve_path_within_base "$TESTS_REPO_ROOT" "$target_path"
}

resolve_results_repo_root() {
    local target_path="artifacts"

    if [ "$#" -gt 0 ]; then
        target_path="$1"
    fi

    case "$target_path" in
        /*)
            realpath -m -- "$target_path"
            return 0
            ;;
    esac

    if [ -n "${RESULTS_REPO_ROOT:-}" ]; then
        case "${RESULTS_REPO_ROOT:-}" in
            /*)
                resolve_path_within_base "$RESULTS_REPO_ROOT" "$target_path"
                return 0
                ;;
        esac
    fi

    resolve_repo_path "$target_path"
}

resolve_source_repo_root() {
    if [ -n "${RUNNER_SOURCE_REPO_ROOT:-}" ]; then
        resolve_path_within_base "${RUNNER_SOURCE_REPO_ROOT}" ""
        return 0
    fi

    case "$RESULTS_REPO_ROOT" in
        /*)
            case "$RESULTS_REPO_ROOT" in
                "$DEFAULT_RESULTS_REPO_ROOT"|"$DEFAULT_RESULTS_REPO_ROOT"/*)
                    printf '%s\n' "$TESTS_REPO_ROOT"
                    return 0
                    ;;
            esac
            local results_parent=""
            results_parent="$(cd -- "$(dirname -- "$RESULTS_REPO_ROOT")" 2>/dev/null && pwd -P)" || return 1
            printf '%s\n' "$results_parent"
            return 0
            ;;
    esac

    printf '%s\n' "$TESTS_REPO_ROOT"
}

resolve_source_repo_path() {
    local target_path="${1:-}"
    resolve_path_within_base "$SOURCE_REPO_ROOT" "$target_path"
}

DEFAULT_RESULTS_REPO_ROOT="$(resolve_repo_path "artifacts")"
CLD6001_RUN_ID="${CLD6001_RUN_ID:-$(cld6001_generate_run_id)}"
CLD6001_RUN_ROOT="${CLD6001_RUN_ROOT:-$(cld6001_resolve_run_root "$DEFAULT_RESULTS_REPO_ROOT" "$CLD6001_RUN_ID")}"
RESULTS_REPO_ROOT="${CLD6001_RESULTS_ROOT:-$CLD6001_RUN_ROOT}"
SOURCE_REPO_ROOT="$(resolve_source_repo_root)"

cld6001_unique_timestamp_id() {
    cld6001_generate_timestamped_id "${1:-%Y%m%d_%H%M%S}" "${2:-_}" 8
}

reset_collection_results_dir() {
    local target_dir="${1:?}"
    local results_root=""

    results_root="$(resolve_results_repo_root "")" || return 1

    case "$target_dir" in
        "$results_root"|"$results_root"/*)
            ;;
        *)
            printf 'Refusing to reset non-results directory: %s\n' "$target_dir" >&2
            return 1
            ;;
    esac

    rm -rf -- "$target_dir"
    mkdir -p -- "$target_dir"
}

TEST_RESULTS_DIR="${TEST_RESULTS_DIR:-${RESULTS_REPO_ROOT}/runner/direct-run/shared/${CLD6001_RUN_ID}}"
HOST_PROBE_TMP_DIR="${HOST_PROBE_TMP_DIR:-${TEST_RESULTS_DIR}/probe-tmp}"
CONTAINER_PROBE_TMP_DIR="${CONTAINER_PROBE_TMP_DIR:-/probe-tmp}"

mkdir -p "$TEST_RESULTS_DIR" "$HOST_PROBE_TMP_DIR"

create_host_probe_dir() {
    local prefix="${1:-probe}"
    local safe_prefix="${prefix//[^A-Za-z0-9._-]/-}"
    local target_dir="${HOST_PROBE_TMP_DIR}/${safe_prefix}-$(cld6001_unique_timestamp_id "%s" "-")"

    mkdir -p "$target_dir"
    printf '%s\n' "$target_dir"
}

load_helper_image_inventory() {
    $PULL_IMAGES_HELPER_LOADED && return 0

    source "${TESTS_REPO_ROOT}/src/setup/pull-images.sh"
    PULL_IMAGES_HELPER_LOADED=true
}

resolve_helper_image() {
    local helper_name="$1"
    local override_image=""

    case "$helper_name" in
        python-probe)
            override_image="${RUNNER_HELPER_PYTHON_IMAGE:-}"
            ;;
        alpine-shell)
            override_image="${RUNNER_HELPER_ALPINE_IMAGE:-}"
            ;;
        *)
            printf 'Unknown helper image request: %s\n' "$helper_name" >&2
            return 1
            ;;
    esac

    if [ -n "$override_image" ]; then
        printf '%s\n' "$override_image"
        return 0
    fi

    load_helper_image_inventory || return 1
    get_helper_image_tag "$helper_name"
}

export TESTS_REPO_ROOT SOURCE_REPO_ROOT DEFAULT_RESULTS_REPO_ROOT CLD6001_RUN_ID CLD6001_RUN_ROOT RESULTS_REPO_ROOT TEST_RESULTS_DIR HOST_PROBE_TMP_DIR CONTAINER_PROBE_TMP_DIR

generate_results_file() {
    local prefix="${1:-test}"
    echo "${TEST_RESULTS_DIR}/${prefix}-$(cld6001_unique_timestamp_id "%Y%m%d-%H%M%S" "-").txt"
}

safe_write() {
    local file_path="$1"
    local content="$2"
    mkdir -p "$(dirname "$file_path")"
    echo "$content" > "$file_path"
}

safe_append() {
    local file_path="$1"
    local content="$2"
    mkdir -p "$(dirname "$file_path")"
    echo "$content" >> "$file_path"
}

safe_tee() {
    local file_path="$1"
    mkdir -p "$(dirname "$file_path")"
    tee "$file_path"
}

safe_tee_append() {
    local file_path="$1"
    mkdir -p "$(dirname "$file_path")"
    tee -a "$file_path"
}

resolve_result_reason_path() {
    local target_dir=""
    local reason_context=""

    if [ -n "${RUNNER_REASON_PATH:-}" ]; then
        mkdir -p "$(dirname -- "$RUNNER_REASON_PATH")"
        printf '%s\n' "$RUNNER_REASON_PATH"
        return 0
    fi

    if [ -n "${RUNNER_ARTIFACTS_DIR:-}" ]; then
        target_dir="$RUNNER_ARTIFACTS_DIR"
    elif [ -n "${TEST_RESULTS_DIR:-}" ]; then
        target_dir="$TEST_RESULTS_DIR"
    else
        return 1
    fi

    mkdir -p "$target_dir"

    if [ -n "${RUNNER_TEST_ID:-}" ] && [ -n "${CLD6001_RUN_ID:-}" ]; then
        reason_context="${RUNNER_TEST_ID}-${CLD6001_RUN_ID}"
    elif [ -n "${CLD6001_RUN_ID:-}" ]; then
        reason_context="$CLD6001_RUN_ID"
    elif [ -n "${RUNNER_TEST_ID:-}" ]; then
        reason_context="$RUNNER_TEST_ID"
    else
        reason_context="default"
    fi

    cld6001_resolve_result_reason_path "$target_dir" "$reason_context"
}

result_reason_exists() {
    local reason_path=""

    reason_path="$(resolve_result_reason_path)" || return 1
    [ -f "$reason_path" ]
}

write_result_reason() {
    local result="$1"
    local reason_code="$2"
    local reason_text="$3"
    local reason_source="${4:-testcase-artifact}"
    local reason_path=""

    reason_path="$(resolve_result_reason_path)" || return 0
    jq -n \
        --arg result "$result" \
        --arg reason_code "$reason_code" \
        --arg reason_text "$reason_text" \
        --arg reason_source "$reason_source" \
        '{
            result: $result,
            reason_code: $reason_code,
            reason_text: $reason_text,
            reason_source: $reason_source
        }' > "$reason_path"
}

cld6001_terminal_reason() {
    local result="${1:?result required}"
    local reason_code="${2:?reason_code required}"
    local reason_text="${3:?reason_text required}"
    local terminal_label=""

    write_result_reason "$result" "$reason_code" "$reason_text" "testcase-artifact"
    terminal_label="$(printf '%s' "$result" | tr '[:lower:]' '[:upper:]')"
    printf '%s: %s\n' "$terminal_label" "$reason_text"
}

cld6001_pass() {
    local reason_code="${1:?reason_code required}"
    local reason_text="${2:?reason_text required}"

    cld6001_terminal_reason "pass" "$reason_code" "$reason_text"
}

cld6001_fail() {
    local reason_code="${1:?reason_code required}"
    local reason_text="${2:?reason_text required}"

    cld6001_terminal_reason "fail" "$reason_code" "$reason_text"
    exit 1
}

cld6001_block() {
    local reason_code="${1:?reason_code required}"
    local reason_text="${2:?reason_text required}"

    cld6001_terminal_reason "block" "$reason_code" "$reason_text"
    exit "${BLOCK_EXIT_CODE:-3}"
}
