#!/bin/bash

set -Eeuo pipefail

TIMEOUT_SECONDS=${TEST_TIMEOUT:-120}
BLOCK_EXIT_CODE=${BLOCK_EXIT_CODE:-3}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$REPO_ROOT/src/execute/run-context.sh"
source "$REPO_ROOT/src/shared/terminal-colors.sh"
source "$REPO_ROOT/src/shared/output-layout.sh"
source "$REPO_ROOT/src/shared/disk-space-helpers.sh"
source "$REPO_ROOT/src/shared/copyfail-mode-helpers.sh"
source "$REPO_ROOT/src/shared/host-safety-guard.sh"

cld6001_unique_timestamp_id() {
    cld6001_generate_timestamped_id "${1:-%Y%m%d_%H%M%S}" "${2:-_}" 8
}

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
            printf 'Path escapes runner root: %s\n' "$target_path" >&2
            return 1
            ;;
    esac
}

resolve_targeted_runtimes() {
    local _collection="$1"
    local runtime_selection="$2"
    resolve_requested_runtimes "$runtime_selection"
}

validate_targeted_runtime_selection() {
    local testcase="$1"
    local testcase_collection="$2"
    local runtime_selection="$3"
    local runtime=""

    while IFS= read -r runtime; do
        [ -n "$runtime" ] || continue
        return 0
    done < <(resolve_targeted_runtimes "$testcase_collection" "$runtime_selection")

    error "Testcase $testcase in collection $testcase_collection has no supported runtimes for selection: $runtime_selection"
    return 1
}

resolve_runner_path() {
    local target_path="$1"

    case "$target_path" in
        /*)
            realpath -m -- "$target_path"
            return 0
            ;;
    esac

    resolve_path_within_base "$REPO_ROOT" "$target_path"
}

resolve_runner_liverun_root() {
    local requested_root="${1:-${CLD6001_RUN_ROOT:-temp-work}}"
    local relative_path=""

    case "$requested_root" in
        temp-work)
            relative_path=""
            ;;
        ./temp-work)
            relative_path=""
            ;;
        temp-work/*)
            relative_path="${requested_root#temp-work/}"
            ;;
        ./temp-work/*)
            relative_path="${requested_root#./temp-work/}"
            ;;
        *)
            resolve_runner_path "$requested_root"
            return 0
            ;;
    esac

    if [ -L "$REPO_ROOT/temp-work" ] || [ -d "$REPO_ROOT/temp-work" ]; then
        resolve_path_within_base "$REPO_ROOT/temp-work" "$relative_path"
        return 0
    fi

    resolve_runner_path "${requested_root#./}"
}

ROOTLESS_RUNTIME_DISPATCHER="${ROOTLESS_RUNTIME_DISPATCHER:-}"
DEFAULT_LIVERUN_ROOT="${DEFAULT_LIVERUN_ROOT:-}"
RUN_SESSION_ID="${RUN_SESSION_ID:-}"
LIVERUN_DIR="${LIVERUN_DIR:-}"

RESULTS_ROOT="${RESULTS_ROOT:-}"
TEST_RESULTS_ROOT="${TEST_RESULTS_ROOT:-}"
readonly RESULTS_ROOT_DISK_HEADROOM_CHECK_ID="disk_headroom:results_root"
readonly TEMP_WORK_ROOT_DISK_HEADROOM_CHECK_ID="disk_headroom:temp_work_root"
readonly TEMP_WORK_ROOT_CREATION_CHECK_ID="temp_work_root_creation"
readonly ENVIRONMENT_STATE_ENFORCEMENT_CHECK_ID="environment_state:enforcement"
readonly PROFILE_RUNTIME_SUPPORT_CHECK_ID="profile_runtime_support"
readonly RUNTIME_FUNCTIONALITY_CHECK_ID="runtime_functionality"
LAST_DISK_HEADROOM_STATUS=""
LAST_DISK_HEADROOM_DETAILS=""
LAST_PREREQUISITE_FAILURES=""
LAST_PROFILE_RUNTIME_SUPPORT_DETAILS=""
LAST_RUNTIME_FUNCTIONALITY_FAILURE_CHECK_ID="$RUNTIME_FUNCTIONALITY_CHECK_ID"
LAST_RUNTIME_FUNCTIONALITY_FAILURE_DETAILS=""
LAST_RUNTIME_CONNECTIVITY_DETAILS=""
LAST_TEMP_WORK_ROOT_CREATION_DETAILS=""

source "$REPO_ROOT/src/execute/image-registry.sh"

source "$REPO_ROOT/src/profiles/profile-adapter.sh"
source "$REPO_ROOT/src/profiles/environment-state-registry.sh"

header() {
    echo ""
    echo "--- $1 ---"
    echo ""
}

section() {
    echo ""
    echo "--- $1 ---"
    echo ""
}

declare -A TEST_CASE_SLUGS=(
    ["tc01"]="privileged-mode"
    ["tc02"]="namespace-manipulation"
    ["tc03"]="cgroup-escape"
    ["tc04"]="kernel-exploits"
    ["tc05"]="standard-image-assessment"
    ["tc06"]="hardened-image-assessment"
    ["tc07"]="custom-hardened-image-assessment"
    ["tc08"]="capability-abuse"
    ["tc09"]="capability-dropped"
    ["tc10"]="selinux-enforcement"
    ["tc11"]="selinux-violations"
    ["tc12"]="selinux-bypass"
    ["tc13"]="syscall-abuse"
    ["tc14"]="seccomp-bypass"
    ["tc15"]="user-namespace"
    ["tc16"]="control-interaction-probe"
    ["tc17"]="combined-weakness-probe"
    ["tc18"]="host-access-probe"
    ["tc19"]="network-isolation"
    ["tc20"]="supply-chain"
    ["tc21"]="control-impact-matrix"
    ["tc22"]="page-cache-poisoning"
    ["tc23"]="cross-container-attack"
    ["tc24"]="runc-container-escape"
)
declare -A TEST_CASE_FIXED_FLAVORS=(
    ["tc16"]="misc"
    ["tc17"]="misc"
)

source "$REPO_ROOT/src/execute/collections/registry.sh"
declare -A TEST_EXIT_CODES=()
declare -A TEST_RESULT_DIRS=()
declare -A TEST_RESULT_KEY_INDEX=()
declare -A TEST_RESULT_VARIANTS=()
declare -A TEST_RESULT_IMAGES=()
declare -A TEST_RESULT_BASE_OS=()
declare -A TEST_RESULT_FLAVORS=()
declare -A INITIALIZED_COLLECTION_RESULTS=()
declare -A STAGED_RUNTIME_IMAGES=()

strict_prereqs=false
RUNNER_SMOKE_IMAGE="${RUNNER_SMOKE_IMAGE:-}"
DEFAULT_ENVIRONMENT_STATE="baseline-system"
RUNNER_RELAXED_DEBUG="${RUNNER_RELAXED_DEBUG:-false}"
RUNNER_ENFORCE_ENVIRONMENT_STATE="${RUNNER_ENFORCE_ENVIRONMENT_STATE:-true}"
RUNNER_STAGE_RUNTIME_IMAGES="${RUNNER_STAGE_RUNTIME_IMAGES:-true}"

usage() {
    cat <<EOF
Usage: bash src/execute/test-runner.sh [--test-collection NAME | --testcase tcNN] [--runtime runtime] [--profile name] [--environment-state state] [--relaxed-debug] [--strict-prereqs] [--dry-run]
                                 [--copyfail-mode mode]
                                 [--image image_name] [--base-os os] [--flavor flavor] [--all-images]

Options:
  --test-collection NAME  Run tests for a specific collection (a through h)
  --testcase CASE       Run a single testcase (tcNN or canonical testcase slug)
  --runtime runtime     Specify runtime (docker-rootful|docker-rootless|podman-rootless|all)
  --copyfail-mode mode  Select Copy Fail payload mode (reversible)
                        reversible selects the active non-destructive automation path
  --profile name        Select execution profile for live runs; defaults from --environment-state
  --environment-state state
                         Select environment state (${DEFAULT_ENVIRONMENT_STATE}|all)
  --relaxed-debug       Debug-only opt-in: skip automatic environment-state application
                        while keeping other runner preflight and execution behavior intact
  --strict-prereqs      Fail immediately if live-run prerequisites are missing
  --dry-run             Dry run mode
  --image image_name    Run tests for specific image (nginx|postgres|nodejs)
  --base-os os          Run tests for specific base OS (alpine|debian)
  --flavor flavor       Run tests for specific DHI flavor (production|development)
  --all-images          Run tests for all image variants (default for Phase 3)
  --help                Show this help
EOF
}

initialize_runner_paths() {
    local requested_run_root="${CLD6001_RUN_ROOT:-temp-work}"
    local requested_run_basename=""

    requested_run_root="${requested_run_root%/}"
    [ -n "$requested_run_root" ] || requested_run_root="/"

    ROOTLESS_RUNTIME_DISPATCHER="$(resolve_runner_path "src/shared/rootless-runtime-dispatch.sh")"
    DEFAULT_LIVERUN_ROOT="$(resolve_runner_liverun_root "$requested_run_root")"
    RUN_SESSION_ID="${RUN_SESSION_ID:-${CLD6001_RUN_ID:-$(cld6001_generate_run_id)}}"
    requested_run_basename="${requested_run_root##*/}"

    case "$requested_run_root" in
        temp-work|./temp-work)
            LIVERUN_DIR="${DEFAULT_LIVERUN_ROOT}/${RUN_SESSION_ID}"
            ;;
        temp-work/*|./temp-work/*)
            if [ "$requested_run_basename" = "$RUN_SESSION_ID" ]; then
                LIVERUN_DIR="$DEFAULT_LIVERUN_ROOT"
            else
                LIVERUN_DIR="${DEFAULT_LIVERUN_ROOT}/${RUN_SESSION_ID}"
            fi
            ;;
        *)
            LIVERUN_DIR="$DEFAULT_LIVERUN_ROOT"
            ;;
    esac

    RESULTS_ROOT="$(resolve_runner_path "${RESULTS_ROOT:-$LIVERUN_DIR/test-runner}")"
    TEST_RESULTS_ROOT="${TEST_RESULTS_ROOT:-$LIVERUN_DIR/escape-tests}"
}

environment_state_enforcement_enabled() {
    [ "$RUNNER_ENFORCE_ENVIRONMENT_STATE" = "true" ] || return 1
    [ "$RUNNER_RELAXED_DEBUG" != "true" ]
}

managed_environment_state_requested() {
    [ "$environment_state" != "none" ]
}

build_variant_identity() {
    local target_image="${1:-}"
    local target_base_os="${2:-}"
    local target_flavor="${3:-}"
    local -a segments=()
    local IFS=':'

    [ -n "$target_image" ] && segments+=("$target_image")
    [ -n "$target_base_os" ] && segments+=("$target_base_os")
    [ -n "$target_flavor" ] && segments+=("$target_flavor")

    [ "${#segments[@]}" -gt 0 ] || return 1
    printf '%s\n' "${segments[*]}"
}

build_variant_path() {
    local target_image="${1:-}"
    local target_base_os="${2:-}"
    local target_flavor="${3:-}"
    local -a segments=()
    local IFS='/'

    [ -n "$target_image" ] && segments+=("$target_image")
    [ -n "$target_base_os" ] && segments+=("$target_base_os")
    [ -n "$target_flavor" ] && segments+=("$target_flavor")

    [ "${#segments[@]}" -gt 0 ] || return 1
    printf '%s\n' "${segments[*]}"
}

append_result_store_key() {
    local base_key="$1"
    local result_key="$2"
    local current_keys="${TEST_RESULT_KEY_INDEX[$base_key]:-}"

    case " $current_keys " in
        *" $result_key "*) ;;
        *)
            TEST_RESULT_KEY_INDEX["$base_key"]="${current_keys:+$current_keys }$result_key"
            ;;
    esac
}

default_result_store_key() {
    local runtime="$1"
    local test_id="$2"
    local result_key=""

    result_key="$(result_store_keys_for_test "$runtime" "$test_id" | tail -n 1)"

    if [ -n "$result_key" ]; then
        printf '%s\n' "$result_key"
        return 0
    fi

    printf '%s\n' "${runtime}:${test_id}"
}

result_store_keys_for_test() {
    local runtime="$1"
    local test_id="$2"
    local base_key="${runtime}:${test_id}"
    local indexed_keys="${TEST_RESULT_KEY_INDEX[$base_key]:-}"
    local canonical_test_id=""
    local key=""
    local candidate_test_id=""
    local result_key=""

    if [ -n "$indexed_keys" ]; then
        for result_key in $indexed_keys; do
            printf '%s\n' "$result_key"
        done
        return 0
    fi

    canonical_test_id="$(testcase_key "$test_id")"
    for key in "${!TEST_RESULT_DIRS[@]}"; do
        case "$key" in
            "${runtime}:"*)
                candidate_test_id="${key#${runtime}:}"
                candidate_test_id="${candidate_test_id%%:*}"
                if [ "$(testcase_key "$candidate_test_id")" = "$canonical_test_id" ]; then
                    printf '%s\n' "$key"
                fi
                ;;
        esac
    done
}

resolve_in_memory_result_dir() {
    local result_key=""
    result_key="$(default_result_store_key "$1" "$2")"
    printf '%s\n' "${TEST_RESULT_DIRS[$result_key]:-}"
}

resolve_in_memory_exit_code() {
    local result_key=""
    result_key="$(default_result_store_key "$1" "$2")"
    printf '%s\n' "${TEST_EXIT_CODES[$result_key]:-1}"
}

validate_test_collection() {
    [ -z "${1:-}" ] && return 0
    case "$1" in
        a|b|c|d|e|f|g|h|preflight|cleanup) return 0 ;;
        all)
            error "Use server-orchestrator targeted mode without --test-collection to run all collections for an environment state"
            return 1
            ;;
    esac
    error "Invalid test collection: $1 (valid: a through h, preflight, cleanup)"
    return 1
}

validate_testcase() {
    [ -z "${1:-}" ] && return 0

    cld6001_testcase_slug "$1" >/dev/null 2>&1 || {
        error "Invalid testcase: $1"
        return 1
    }

    cld6001_collection_for_testcase "$1" >/dev/null 2>&1 || {
        error "Unknown testcase: $1"
        return 1
    }
}

collection_results_filename() {
    local collection="$1"
    printf 'collection-%s-results.json\n' "${collection}"
}

requested_collection_status_path() {
    printf '%s\n' "$RESULTS_ROOT/requested-collection-status.json"
}

requested_collection_runtime_outcomes() {
    local collection="$1"
    local collection_dir="$RESULTS_ROOT/collection-$collection"
    local collection_file="$collection_dir/$(collection_results_filename "$collection")"

    [ -f "$collection_file" ] || { printf '{}\n'; return 0; }

    jq -c --arg collection "$collection" '
        def cleanup_checks:
            [
              .checks?["cleanup:runtime_boundary"]?.status
            ]
            | map(select(. != null));
        def preflight_checks:
            [
              .checks?["disk_headroom:results_root"]?.status,
              .checks?["disk_headroom:temp_work_root"]?.status,
              .checks?["environment_state:enforcement"]?.status
            ];
        def testcase_result:
            (.variants // {}
             | to_entries
             | map(.value.result)
             | map(select(. != null))) as $variant_results
            | if ($variant_results | length) == 0 then (.result // "fail")
              elif any($variant_results[]?; . == "fail") then "fail"
              elif any($variant_results[]?; . == "block") then "block"
              elif any($variant_results[]?; . == "pass") then "pass"
              else (.result // "fail")
              end;
        def runtime_status:
            (.test_cases // {}) as $test_cases
            | if $collection == "preflight" then
                  if any(preflight_checks[]?; . == "fail") then "fail" else "pass" end
              elif $collection == "cleanup" then
                  if (cleanup_checks | length) == 0 then "fail"
                  elif any(cleanup_checks[]?; . == "fail") then "fail"
                  else "pass"
                  end
              elif ($test_cases | length) == 0 then "fail"
              elif any($test_cases[]?; testcase_result == "fail") then "fail"
              elif any($test_cases[]?; testcase_result == "block") then "pass_with_findings"
              else "pass"
              end;

        to_entries
        | map(
            select(.value | type == "object")
            | select((.value | has("test_cases")) or (.value | has("checks")))
            | {
                key: .key,
                value: (.value | runtime_status)
              }
          )
        | from_entries
    ' "$collection_file"
}

requested_collection_overall_status() {
    local collection="$1"
    local runtime_outcomes=""

    runtime_outcomes="$(requested_collection_runtime_outcomes "$collection")"

    jq -r '
        if length == 0 then "fail"
        elif any(.[]; . == "fail") then "fail"
        elif any(.[]; . == "pass_with_findings") then "pass_with_findings"
        elif any(.[]; . == "pass") then "pass"
        else "fail"
        end
    ' <<< "$runtime_outcomes"
}

write_requested_collection_status() {
    local collection="$1"
    local runtime_selection="$2"
    local status="$3"
    local output_path
    local runtime_outcomes=""

    runtime_outcomes="$(requested_collection_runtime_outcomes "$collection")"
    output_path="$(requested_collection_status_path)"

    jq -n \
        --arg collection "$collection" \
        --arg environment_state "$environment_state" \
        --arg runtime_selection "$runtime_selection" \
        --arg status "$status" \
        --arg results_root "$RESULTS_ROOT" \
        --argjson runtime_outcomes "$runtime_outcomes" \
        '{
            collection: $collection,
            environment_state: $environment_state,
            runtime_selection: $runtime_selection,
            status: $status,
            results_root: $results_root,
            runtime_outcomes: $runtime_outcomes
        }' > "$output_path"
}

persist_requested_collection_status_after_live_preflight_failure() {
    local collection="${1:-}"
    local runtime_selection="${2:-}"
    local collection_status="fail"

    [ -n "$collection" ] || return 0
    can_persist_live_preflight_results || return 0

    collection_status="$(requested_collection_overall_status "$collection" 2>/dev/null || printf 'fail\n')"
    write_requested_collection_status "$collection" "$runtime_selection" "$collection_status"
}

validate_runtime() {
    case "$1" in
        docker-rootful|docker-rootless|podman-rootless|all)
            ;;
        *)
            error "Invalid runtime: $1"
            return 1
            ;;
    esac
}

validate_environment_state() {
    [ "$1" = "all" ] && return 0
    environment_state_exists "$1" || {
        error "Invalid environment state: $1"
        return 1
    }
}

validate_copyfail_mode() {
    cld6001_copyfail_validate_mode "$1"
}

runtime_engine() {
    case "$1" in
        docker-rootful|docker-rootless)
            printf '%s\n' docker
            ;;
        podman-rootless)
            printf '%s\n' podman
            ;;
        *)
            return 1
            ;;
    esac
}

runtime_mode() {
    case "$1" in
        docker-rootful)
            printf '%s\n' rootful
            ;;
        docker-rootless|podman-rootless)
            printf '%s\n' rootless
            ;;
        *)
            return 1
            ;;
    esac
}

runtime_registry_url() {
    case "$(runtime_engine "$1")" in
        docker)
            printf '%s\n' 'https://registry-1.docker.io/v2/'
            ;;
        podman)
            printf '%s\n' 'https://quay.io/v2/'
            ;;
        *)
            return 1
            ;;
    esac
}

resolve_temp_work_root() {
    cld6001_temp_work_dir ""
}

run_disk_headroom_check() {
    local check_id="$1"
    local description="$2"
    local target_path="$3"

    LAST_DISK_HEADROOM_STATUS="fail"
    if cld6001_enforce_disk_headroom "$target_path"; then
        LAST_DISK_HEADROOM_STATUS="pass"
        LAST_DISK_HEADROOM_DETAILS="$(cld6001_disk_space_summary)"
        info "$description [$check_id]: $LAST_DISK_HEADROOM_DETAILS"
        return 0
    fi

    LAST_DISK_HEADROOM_DETAILS="$(cld6001_disk_space_summary)"
    error "$description [$check_id]: $LAST_DISK_HEADROOM_DETAILS"
    return 1
}

resolve_preferred_user() {
    if [ -n "${1:-}" ]; then
        printf '%s\n' "$1"
    elif [ -n "${SUDO_USER:-}" ]; then
        printf '%s\n' "${SUDO_USER}"
    else
        whoami
    fi
}

resolve_user_home() {
    local user="$1"
    local user_home=""

    if user_home="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6)" && [ -n "${user_home}" ]; then
        printf '%s\n' "${user_home}"
        return 0
    fi

    printf '/home/%s\n' "${user}"
}

runtime_rootless_user() {
    case "$1" in
        docker-rootless)
            resolve_preferred_user "${DOCKER_ROOTLESS_USER:-${CONTAINER_USER:-}}"
            ;;
        podman-rootless)
            resolve_preferred_user "${PODMAN_ROOTLESS_USER:-${CONTAINER_USER:-}}"
            ;;
        *)
            return 1
            ;;
    esac
}

ensure_runtime_output_dir() {
    local runtime="$1"
    local output_dir="$2"
    local runtime_user=""
    local runtime_group=""

    mkdir -p "$output_dir"

    [ "$(runtime_mode "$runtime")" = "rootless" ] || return 0

    runtime_user="$(runtime_rootless_user "$runtime")" || return 1
    if run_runtime_command "$runtime" -- test -w "$output_dir" >/dev/null 2>&1; then
        return 0
    fi

    [ "$(id -u)" -eq 0 ] || {
        error "Results path is not writable for $runtime: $output_dir"
        return 1
    }

    runtime_group="$(id -gn "$runtime_user")"
    chown "$runtime_user:$runtime_group" "$output_dir"
    chmod 0775 "$output_dir"

    run_runtime_command "$runtime" -- test -w "$output_dir" >/dev/null 2>&1 || {
        error "Results path is not writable for $runtime: $output_dir"
        return 1
    }
}

ensure_runtime_output_file() {
    local runtime="$1"
    local output_file="$2"
    local output_dir=""
    local runtime_user=""
    local runtime_group=""

    output_dir="$(dirname -- "$output_file")"
    ensure_runtime_output_dir "$runtime" "$output_dir" || return 1

    : > "$output_file"
    [ "$(runtime_mode "$runtime")" = "rootless" ] || return 0

    if run_runtime_command "$runtime" -- test -w "$output_file" >/dev/null 2>&1; then
        return 0
    fi

    [ "$(id -u)" -eq 0 ] || {
        error "Output file is not writable for $runtime: $output_file"
        return 1
    }

    runtime_user="$(runtime_rootless_user "$runtime")" || return 1
    runtime_group="$(id -gn "$runtime_user")"
    chown "$runtime_user:$runtime_group" "$output_file"
    chmod 0664 "$output_file"

    run_runtime_command "$runtime" -- test -w "$output_file" >/dev/null 2>&1 || {
        error "Output file is not writable for $runtime: $output_file"
        return 1
    }
}

RUNTIME_ENV_PAIRS=()

prepare_runtime_environment() {
    local runtime="$1"
    local runtime_user=""
    local runtime_uid=""
    local runtime_home=""

    RUNTIME_ENV_PAIRS=()

    if [ "$(runtime_mode "$runtime")" != "rootless" ]; then
        if [ "$(runtime_engine "$runtime")" = "docker" ]; then
            RUNTIME_ENV_PAIRS+=("DOCKER_HOST=unix:///var/run/docker.sock")
        fi
        return 0
    fi

    runtime_user="$(runtime_rootless_user "$runtime")" || return 1
    if ! id "$runtime_user" >/dev/null 2>&1; then
        error "Configured rootless user does not exist for $runtime: $runtime_user"
        return 1
    fi

    runtime_uid="$(id -u "$runtime_user")"
    runtime_home="$(resolve_user_home "$runtime_user")"
    RUNTIME_ENV_PAIRS+=("HOME=$runtime_home" "XDG_RUNTIME_DIR=/run/user/$runtime_uid")

    if [ "$(runtime_engine "$runtime")" = "docker" ]; then
        RUNTIME_ENV_PAIRS+=("DOCKER_HOST=unix:///run/user/$runtime_uid/docker.sock")
    fi
}

run_runtime_command() {
    local runtime="$1"
    shift

    local -a env_pairs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        env_pairs+=("$1")
        shift
    done
    [ $# -gt 0 ] && [ "$1" = "--" ] && shift

    local -a command=("$@")
    local runtime_user=""
    local -a full_env=()
    local payload=""

    [ ${#command[@]} -gt 0 ] || {
        error "run_runtime_command requires a command"
        return 1
    }

    prepare_runtime_environment "$runtime" || return 1
    full_env=("${RUNTIME_ENV_PAIRS[@]}" "${env_pairs[@]}")

    if [ "$(runtime_mode "$runtime")" != "rootless" ]; then
        env "${full_env[@]}" "${command[@]}"
        return
    fi

    runtime_user="$(runtime_rootless_user "$runtime")" || return 1
    if [ "$(id -un)" = "$runtime_user" ]; then
        env "${full_env[@]}" "${command[@]}"
        return
    fi

    [ -f "$ROOTLESS_RUNTIME_DISPATCHER" ] || {
        error "Rootless runtime dispatcher not found: $ROOTLESS_RUNTIME_DISPATCHER"
        return 1
    }

    if command -v sudo >/dev/null 2>&1; then
        sudo -H -u "$runtime_user" bash --login "$ROOTLESS_RUNTIME_DISPATCHER" "${full_env[@]}" -- "${command[@]}"
    else
        su -s /bin/bash - "$runtime_user" "$ROOTLESS_RUNTIME_DISPATCHER" "${full_env[@]}" -- "${command[@]}"
    fi
}

cleanup_host_temporary_files() {
    local cleanup_paths="${CLD6001_EPHEMERAL_CLEANUP_PATHS:-}"
    local cleanup_path=""
    local temp_work_root=""
    local resolved_cleanup_path=""
    local -a cleanup_targets=()

    temp_work_root="$(realpath --canonicalize-missing -- "$REPO_ROOT/temp-work")" || return 1

    while IFS= read -r cleanup_path; do
        [ -n "$cleanup_path" ] || continue

        case "$cleanup_path" in
            *..*)
                warn "Skipping unsafe cleanup path outside temp-work boundary: $cleanup_path"
                continue
                ;;
        esac

        resolved_cleanup_path="$(realpath --canonicalize-missing -- "$cleanup_path" 2>/dev/null || true)"
        case "$resolved_cleanup_path" in
            "$temp_work_root"/*)
                cleanup_targets+=("$resolved_cleanup_path")
                ;;
            *)
                warn "Skipping unsafe cleanup path outside temp-work boundary: $cleanup_path"
                ;;
        esac
    done <<< "$cleanup_paths"

    [ "${#cleanup_targets[@]}" -gt 0 ] || return 0

    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -n rm -rf -- "${cleanup_targets[@]}" || return 1
        return 0
    fi

    rm -rf -- "${cleanup_targets[@]}"
}

run_cleanup_tier() {
    local tier="$1"
    local runtime="$2"
    local reason="${3:-cleanup}"
    local runtime_name=""
    local cleanup_script=""

    [ -n "$tier" ] && [ "$tier" != "none" ] || return 0

    runtime_name="$(runtime_engine "$runtime")" || return 1
    info "Running ${tier} cleanup for ${runtime} (${reason})..."

    case "$tier" in
        container)
            cleanup_script="
                set +e
                ${runtime_name} ps -aq | xargs -r ${runtime_name} rm -f >/dev/null 2>&1
                if [ '${runtime_name}' = 'podman' ]; then
                    podman pod rm -fa >/dev/null 2>&1 || true
                fi
            "
            ;;
        runtime)
            cleanup_script="
                set +e
                ${runtime_name} ps -aq | xargs -r ${runtime_name} rm -f >/dev/null 2>&1
                if [ '${runtime_name}' = 'podman' ]; then
                    podman pod rm -fa >/dev/null 2>&1 || true
                fi
                ${runtime_name} container prune -f >/dev/null 2>&1 || true
                ${runtime_name} network prune -f >/dev/null 2>&1 || true
            "
            ;;
        full)
            cleanup_script="
                set +e
                ${runtime_name} ps -aq | xargs -r ${runtime_name} rm -f >/dev/null 2>&1
                if [ '${runtime_name}' = 'podman' ]; then
                    podman pod rm -fa >/dev/null 2>&1 || true
                fi
                ${runtime_name} container prune -f >/dev/null 2>&1 || true
                ${runtime_name} network prune -f >/dev/null 2>&1 || true
                ${runtime_name} volume prune -f >/dev/null 2>&1 || true
            "
            ;;
        *)
            error "Unknown cleanup tier: $tier"
            return 1
            ;;
    esac

    run_runtime_command "$runtime" -- bash -lc "$cleanup_script" || return 1
    cleanup_host_temporary_files
}

run_post_case_cleanup() {
    local collection="$1"
    local runtime="$2"
    local test_id="$3"
    local cleanup_tier="container"

    run_cleanup_tier "$cleanup_tier" "$runtime" "after ${test_id}"
}

run_collection_boundary_cleanup() {
    local collection="$1"
    local runtime="$2"
    local boundary="$3"
    local cleanup_tier="container"

    run_cleanup_tier "$cleanup_tier" "$runtime" "${boundary} collection ${collection}"
}

verify_runtime_mode_contract() {
    local runtime="$1"
    local runtime_command="$2"
    local mode_probe=""

    case "$runtime" in
        docker-rootful|docker-rootless)
            mode_probe="$(run_runtime_command "$runtime" -- "$runtime_command" info --format '{{json .SecurityOptions}}' 2>/dev/null || true)"
            [ -n "$mode_probe" ] || return 0
            if [ "$runtime" = "docker-rootless" ]; then
                grep -qi 'rootless' <<<"$mode_probe"
            else
                ! grep -qi 'rootless' <<<"$mode_probe"
            fi
            ;;
        podman-rootless)
            mode_probe="$(run_runtime_command "$runtime" -- "$runtime_command" info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
            [ -z "$mode_probe" ] || [ "$mode_probe" = "true" ]
            ;;
        *)
            return 1
            ;;
    esac
}

load_runner_profile() {
    environment_state_exists "$environment_state" || {
        error "Invalid environment state: $environment_state"
        return 1
    }

    host_profile="$(environment_state_host_profile_for "$environment_state")"
    runtime_profile="$(environment_state_runtime_profile_for "$environment_state")"

    if [ -z "${profile:-}" ]; then
        profile="$runtime_profile"
    elif [ "$profile" != "$runtime_profile" ]; then
        error "Profile $profile does not match environment state $environment_state runtime profile $runtime_profile"
        return 1
    fi

    profile_json="$(load_profile_json "$profile")" || return 1
    profile_slug="$(profile_results_slug "$profile_json")"
}

require_profile_loader_tooling() {
    if ! command -v jq >/dev/null 2>&1 || ! jq --version >/dev/null 2>&1; then
        error "Missing tool: jq"
        return 1
    fi

    return 0
}

require_live_profile() {
    return 0
}

reason_level_matches_result() {
    local level="${1:-}"
    local normalized_result="${2:-}"

    case "${normalized_result}:${level}" in
        pass:OK|pass:PASS|fail:ERROR|fail:FAIL|block:BLOCK)
            return 0
            ;;
    esac

    return 1
}

strip_terminal_ansi() {
    printf '%s' "${1:-}" | sed -E $'s/\x1B\\[[0-9;]*[[:alpha:]]//g'
}

trim_reason_text() {
    local value="${1:-}"

    value="$(printf '%s' "$value" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    printf '%s\n' "$value"
}

reason_code_from_text() {
    local reason_text="${1:-}"
    local fallback_code="${2:-reason_observed}"
    local reason_code=""

    reason_code="$(printf '%s' "$reason_text" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//; s/_{2,}/_/g')"

    if [ -z "$reason_code" ]; then
        reason_code="$fallback_code"
    fi

    printf '%s\n' "$reason_code"
}

OUTPUT_REASON_CODE=""
OUTPUT_REASON_TEXT=""
OUTPUT_REASON_SOURCE=""

extract_result_reason_from_output_log() {
    local normalized_result="${1:-}"
    local log_path="${2:-}"
    local clean_line=""
    local last_matching_tagged=""
    local last_tagged=""
    local last_plain=""
    local selected_reason=""
    local level=""
    local message=""

    OUTPUT_REASON_CODE=""
    OUTPUT_REASON_TEXT=""
    OUTPUT_REASON_SOURCE=""

    [ -f "$log_path" ] || return 0

    while IFS= read -r clean_line || [ -n "$clean_line" ]; do
        clean_line="$(strip_terminal_ansi "$clean_line")"
        clean_line="$(trim_reason_text "$clean_line")"
        [ -n "$clean_line" ] || continue

        case "$clean_line" in
            "---"|Date:*|Runtime:*|Results\ saved\ to:*|Recorded\ applicability\ artifact:*|Recorded\ Podman\ skip\ transcript:*)
                continue
                ;;
        esac

        if [[ "$clean_line" =~ ^\[([A-Z]+)\][[:space:]]+(.+)$ ]]; then
            level="${BASH_REMATCH[1]}"
            message="$(trim_reason_text "${BASH_REMATCH[2]}")"
            last_tagged="$message"
            if reason_level_matches_result "$level" "$normalized_result"; then
                last_matching_tagged="$message"
            fi
            continue
        fi

        if [[ "$clean_line" =~ ^(PASS|OK|FAIL|ERROR|BLOCK):[[:space:]]*(.+)$ ]]; then
            level="${BASH_REMATCH[1]}"
            message="$(trim_reason_text "${BASH_REMATCH[2]}")"
            last_tagged="$message"
            if reason_level_matches_result "$level" "$normalized_result"; then
                last_matching_tagged="$message"
            fi
            continue
        fi

        last_plain="$clean_line"
    done < "$log_path"

    if [ -n "$last_matching_tagged" ]; then
        selected_reason="$last_matching_tagged"
    elif [ -n "$last_tagged" ]; then
        selected_reason="$last_tagged"
    else
        selected_reason="$last_plain"
    fi

    selected_reason="$(trim_reason_text "$selected_reason")"
    [ -n "$selected_reason" ] || return 0

    OUTPUT_REASON_TEXT="$selected_reason"
    OUTPUT_REASON_CODE="$(reason_code_from_text "$selected_reason" "${normalized_result}_testcase_output")"
    OUTPUT_REASON_SOURCE="testcase-output"
}

ensure_result_reason_artifact() {
    local reason_path="${1:-}"
    local normalized_result="${2:-}"
    local reason_code="${3:-}"
    local reason_text="${4:-}"
    local reason_source="${5:-}"

    [ -n "$reason_path" ] || return 0
    [ -f "$reason_path" ] && return 0

    mkdir -p "$(dirname -- "$reason_path")"
    jq -n \
        --arg result "$normalized_result" \
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

write_execution_context() {
    local results_dir="$1"
    local collection_id="$2"
    local test_id="$3"
    local runtime="$4"
    local timestamp="$5"
    local exit_code="$6"
    local normalized_result="$7"
    local artifacts_dir="$8"
    local target_image="${9:-}"
    local target_base_os="${10:-}"
    local target_flavor="${11:-}"
    local runtime_name=""
    local runtime_mode_name=""
    local reason_path=""
    local canonical_test_id=""
    local reason_code=""
    local reason_text=""
    local reason_source=""

    runtime_name="$(runtime_engine "$runtime" 2>/dev/null || true)"
    runtime_mode_name="$(runtime_mode "$runtime" 2>/dev/null || true)"
    reason_path="$(cld6001_resolve_result_reason_path "$artifacts_dir" "${test_id}-${timestamp}")"

    if [ -f "$reason_path" ]; then
        reason_code="$(jq -r '.reason_code // empty' "$reason_path")"
        reason_text="$(jq -r '.reason_text // empty' "$reason_path")"
        reason_source="$(jq -r '.reason_source // empty' "$reason_path")"
    else
        extract_result_reason_from_output_log "$normalized_result" "$results_dir/test-output.log"
        reason_code="$OUTPUT_REASON_CODE"
        reason_text="$OUTPUT_REASON_TEXT"
        reason_source="$OUTPUT_REASON_SOURCE"
    fi

    if [ -z "$reason_code" ]; then
        reason_code="missing_testcase_reason"
    fi
    if [ -z "$reason_text" ]; then
        reason_text="Testcase did not export a simple result reason."
    fi
    if [ -z "$reason_source" ]; then
        reason_source="runner-fallback"
    fi

    ensure_result_reason_artifact \
        "$reason_path" \
        "$normalized_result" \
        "$reason_code" \
        "$reason_text" \
        "$reason_source"

    if [ -f "$reason_path" ]; then
        jq -n \
            --slurpfile reason "$reason_path" \
            --arg collection_id "$collection_id" \
            --arg test_id "$test_id" \
            --arg runtime "$runtime" \
            --arg runtime_engine "$runtime_name" \
            --arg runtime_mode "$runtime_mode_name" \
            --arg profile "$profile" \
            --arg profile_slug "$profile_slug" \
            --arg environment_state "$environment_state" \
            --arg copyfail_mode "$copyfail_mode" \
            --arg host_profile "$host_profile" \
            --arg runtime_profile "$runtime_profile" \
            --arg run_session_id "$RUN_SESSION_ID" \
            --arg timestamp "$timestamp" \
            --arg result_dir "$results_dir" \
            --arg artifacts_dir "$artifacts_dir" \
            --arg target_image "$target_image" \
            --arg target_base_os "$target_base_os" \
            --arg target_flavor "$target_flavor" \
            --arg status "completed" \
            --arg result "$normalized_result" \
            --argjson exit_code "$exit_code" \
            --arg reason_code "$reason_code" \
            --arg reason_text "$reason_text" \
            --arg reason_source "$reason_source" \
            '{
                collection: $collection_id,
                test_id: $test_id,
                runtime: $runtime,
                runtime_engine: $runtime_engine,
                runtime_mode: $runtime_mode,
                profile: $profile,
                profile_slug: $profile_slug,
                environment_state: $environment_state,
                copyfail_mode: $copyfail_mode,
                host_profile: $host_profile,
                runtime_profile: $runtime_profile,
                run_session_id: $run_session_id,
                timestamp: $timestamp,
                result_dir: $result_dir,
                artifacts_dir: $artifacts_dir,
                target_image: $target_image,
                target_base_os: $target_base_os,
                target_flavor: $target_flavor,
                status: $status,
                result: $result,
                exit_code: $exit_code
            } + ($reason[0] // {}) + {
                reason_code: $reason_code,
                reason_text: $reason_text,
                reason_source: $reason_source
            }' > "$results_dir/execution-context.json"
        return
    fi

    jq -n \
        --arg collection_id "$collection_id" \
        --arg test_id "$test_id" \
        --arg runtime "$runtime" \
        --arg runtime_engine "$runtime_name" \
        --arg runtime_mode "$runtime_mode_name" \
        --arg profile "$profile" \
        --arg profile_slug "$profile_slug" \
        --arg environment_state "$environment_state" \
        --arg copyfail_mode "$copyfail_mode" \
        --arg host_profile "$host_profile" \
        --arg runtime_profile "$runtime_profile" \
        --arg run_session_id "$RUN_SESSION_ID" \
        --arg timestamp "$timestamp" \
        --arg result_dir "$results_dir" \
        --arg artifacts_dir "$artifacts_dir" \
        --arg target_image "$target_image" \
        --arg target_base_os "$target_base_os" \
        --arg target_flavor "$target_flavor" \
        --arg status "completed" \
        --arg result "$normalized_result" \
        --argjson exit_code "$exit_code" \
        --arg reason_code "$reason_code" \
        --arg reason_text "$reason_text" \
        --arg reason_source "$reason_source" \
        '{
            collection: $collection_id,
            test_id: $test_id,
            runtime: $runtime,
            runtime_engine: $runtime_engine,
            runtime_mode: $runtime_mode,
            profile: $profile,
            profile_slug: $profile_slug,
            environment_state: $environment_state,
            copyfail_mode: $copyfail_mode,
            host_profile: $host_profile,
            runtime_profile: $runtime_profile,
            run_session_id: $run_session_id,
            timestamp: $timestamp,
            result_dir: $result_dir,
            artifacts_dir: $artifacts_dir,
            target_image: $target_image,
            target_base_os: $target_base_os,
            target_flavor: $target_flavor,
            status: $status,
            result: $result,
            exit_code: $exit_code,
            reason_code: $reason_code,
            reason_text: $reason_text,
            reason_source: $reason_source
        }' > "$results_dir/execution-context.json"
}

validate_capabilities() {
    local container_id="${1:-}"
    local container_runtime="${CONTAINER_RUNTIME:-docker}"
    local capabilities=""
    local dangerous_caps=("CAP_SYS_ADMIN" "CAP_NET_ADMIN" "CAP_SYS_PTRACE")
    local cap=""

    if [ -z "$container_id" ]; then
        container_id="$("$container_runtime" ps -q 2>/dev/null | head -n 1 || true)"
        [ -n "$container_id" ] || return 0
    fi

    capabilities="$("$container_runtime" inspect "$container_id" 2>/dev/null || true)"
    [ -n "$capabilities" ] || return 1

    for cap in "${dangerous_caps[@]}"; do
        if printf '%s\n' "$capabilities" | grep -q -- "$cap"; then
            warn "Dangerous capability $cap present in $container_runtime container $container_id"
        fi
    done
}

verify_runtime_health() {
    local container_runtime="${CONTAINER_RUNTIME:-docker}"

    case "$container_runtime" in
        docker)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl is-active --quiet docker || return 1
                systemctl is-active --quiet containerd || return 1
                return 0
            fi
            docker info >/dev/null 2>&1
            ;;
        podman)
            podman info >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

resolve_requested_runtimes() {
    case "$1" in
        docker-rootful)
            printf '%s\n' docker-rootful
            ;;
        docker-rootless)
            printf '%s\n' docker-rootless
            ;;
        podman-rootless)
            printf '%s\n' podman-rootless
            ;;
        all)
            printf '%s\n%s\n%s\n' docker-rootful docker-rootless podman-rootless
            ;;
        *)
            return 1
            ;;
    esac
}

testcase_key() {
    printf '%s\n' "${1%%-*}"
}

resolve_test_flavor() {
    local test_id="$1"
    local runtime="$2"
    local canonical_test_id=""
    local fixed_flavor=""

    canonical_test_id="$(testcase_key "$test_id")"
    fixed_flavor="${TEST_CASE_FIXED_FLAVORS[$canonical_test_id]:-}"

    if [ -n "$fixed_flavor" ]; then
        printf '%s\n' "$fixed_flavor"
        return 0
    fi

    case "$runtime" in
        docker-rootful|docker-rootless|podman-rootless)
            printf '%s\n' "$runtime"
            ;;
        *)
            error "Unsupported runtime for test resolution: $runtime"
            return 1
            ;;
    esac
}

resolve_test_script() {
    local test_id="$1"
    local runtime="$2"
    local canonical_test_id=""
    local test_slug=""
    local test_flavor=""

    canonical_test_id="$(testcase_key "$test_id")"
    test_slug="${TEST_CASE_SLUGS[$canonical_test_id]:-}"

    [ -n "$test_slug" ] || {
        error "Unknown test identifier: $test_id"
        return 1
    }

    test_flavor="$(resolve_test_flavor "$test_id" "$runtime")" || return 1
    printf '%s\n' "$REPO_ROOT/src/execute/escape-tests/${canonical_test_id}-${test_flavor}-${test_slug}.sh"
}

testcase_path_id() {
    local test_id="$1"
    local canonical_test_id=""
    local test_slug=""

    canonical_test_id="$(testcase_key "$test_id")"
    test_slug="${TEST_CASE_SLUGS[$canonical_test_id]:-}"

    if [ -n "$test_slug" ]; then
        printf '%s-%s\n' "$canonical_test_id" "$test_slug"
        return 0
    fi

    printf '%s\n' "$canonical_test_id"
}

check_prerequisites() {
    local runtime="$1"
    local errors=0
    local runtime_name=""
    local required_tools=("python3" "gcc" "make" "jq" "curl" "timeout" "realpath" "getent")
    LAST_PREREQUISITE_FAILURES=""

    runtime_name="$(runtime_engine "$runtime")" || {
        error "Unknown runtime: $runtime"
        return 1
    }
    required_tools=("$runtime_name" "${required_tools[@]}")

    section "Checking Prerequisites"

    local tool
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            error "Missing tool: $tool"
            LAST_PREREQUISITE_FAILURES+="${tool}"$'\n'
            ((errors+=1))
        elif ! "$tool" --version >/dev/null 2>&1; then
            error "Missing tool: $tool"
            LAST_PREREQUISITE_FAILURES+="${tool}"$'\n'
            ((errors+=1))
        else
            ok "Found tool: $tool successfully"
        fi
    done

    if [ "$errors" -gt 0 ]; then
        error "Found $errors prerequisite issues"
        return 1
    fi

    if ! CONTAINER_RUNTIME="$runtime_name" verify_runtime_health; then
        warn "Runtime health check reported issues for $runtime; continuing preflight"
    fi

    if ! CONTAINER_RUNTIME="$runtime_name" validate_capabilities; then
        warn "Capability validation reported issues for $runtime; continuing preflight"
    fi

    return 0
}

check_runtime_functionality() {
    local runtime="$1"
    local runtime_name=""
    LAST_RUNTIME_FUNCTIONALITY_FAILURE_CHECK_ID="$RUNTIME_FUNCTIONALITY_CHECK_ID"
    LAST_RUNTIME_FUNCTIONALITY_FAILURE_DETAILS=""

    runtime_name="$(runtime_engine "$runtime")" || {
        LAST_RUNTIME_FUNCTIONALITY_FAILURE_DETAILS="Unknown runtime: $runtime"
        return 1
    }

    run_runtime_command "$runtime" -- "$runtime_name" info >/dev/null 2>&1 || {
        LAST_RUNTIME_FUNCTIONALITY_FAILURE_DETAILS="Failed to query runtime functionality for $runtime using $runtime_name info"
        return 1
    }
    verify_runtime_mode_contract "$runtime" "$runtime_name" || {
        LAST_RUNTIME_FUNCTIONALITY_FAILURE_CHECK_ID="runtime_mode_contract"
        LAST_RUNTIME_FUNCTIONALITY_FAILURE_DETAILS="Resolved runtime did not match requested mode: $runtime"
        error "Resolved runtime did not match requested mode: $runtime"
        return 1
    }
    [ -n "$RUNNER_SMOKE_IMAGE" ] || return 0

    run_runtime_command "$runtime" -- "$runtime_name" image inspect "$RUNNER_SMOKE_IMAGE" >/dev/null 2>&1 || {
        LAST_RUNTIME_FUNCTIONALITY_FAILURE_DETAILS="Configured smoke image is not available locally for $runtime: $RUNNER_SMOKE_IMAGE"
        error "$LAST_RUNTIME_FUNCTIONALITY_FAILURE_DETAILS"
        return 1
    }

    run_runtime_command "$runtime" -- "$runtime_name" run --rm "$RUNNER_SMOKE_IMAGE" true >/dev/null 2>&1 || {
        LAST_RUNTIME_FUNCTIONALITY_FAILURE_DETAILS="Failed to execute smoke image for $runtime: $RUNNER_SMOKE_IMAGE"
        return 1
    }
}

check_runtime_connectivity() {
    local runtime="$1"
    local registry_url=""
    local http_code=""
    LAST_RUNTIME_CONNECTIVITY_DETAILS=""

    registry_url="$(runtime_registry_url "$runtime")" || return 1
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' "$registry_url" || true)"
    case "$http_code" in
        200|301|302|401|403)
            ok "Registry connectivity verified successfully for $runtime"
            ;;
        *)
            LAST_RUNTIME_CONNECTIVITY_DETAILS="Failed to complete registry connectivity check for $runtime ($registry_url)"
            error "Runtime connectivity check failed for $runtime ($registry_url)"
            return 1
            ;;
    esac
}

collect_collection_output_logs() {
    local runtime="$1"
    local collection="$2"
    local test_id=""
    local result_dir=""
    local log_path=""
    local -a log_paths=()

    while IFS= read -r test_id; do
        [ -n "$test_id" ] || continue
        result_dir="${TEST_RESULT_DIRS["${runtime}:${test_id}"]:-}"
        if [ -z "$result_dir" ]; then
            result_dir="$(resolve_persisted_result_dir "$runtime" "$test_id")"
        fi
        [ -n "$result_dir" ] || continue
        log_path="$result_dir/test-output.log"
        [ -f "$log_path" ] || continue
        log_paths+=("$log_path")
    done < <(cld6001_testcases_for_collection "$collection" "$environment_state")

    (IFS=$'\n'; printf '%s' "${log_paths[*]:-}")
}

collect_current_collection_output_logs() {
    local runtime="$1"
    local collection="$2"
    local test_id=""
    local result_dir=""
    local log_path=""
    local -a log_paths=()

    while IFS= read -r test_id; do
        [ -n "$test_id" ] || continue
        result_dir="$(resolve_current_result_dir "$runtime" "$test_id")"
        [ -n "$result_dir" ] || continue
        log_path="$result_dir/test-output.log"
        [ -f "$log_path" ] || continue
        log_paths+=("$log_path")
    done < <(cld6001_testcases_for_collection "$collection" "$environment_state")

    (IFS=$'\n'; printf '%s' "${log_paths[*]:-}")
}

build_current_collection_manifest() {
    local runtime="$1"
    local collection="$2"
    local test_id=""
    local fields=""
    local normalized_result=""
    local result_dir=""
    local log_path=""
    local context_path=""

    while IFS= read -r test_id; do
        [ -n "$test_id" ] || continue
        fields="$(build_current_result_fields "$runtime" "$test_id")"
        IFS='|' read -r normalized_result result_dir log_path context_path <<< "$fields"

        printf '%s|%s|%s|%s|%s\n' \
            "$test_id" \
            "$normalized_result" \
            "$result_dir" \
            "$log_path" \
            "$context_path"
    done < <(cld6001_testcases_for_collection "$collection" "$environment_state")
}

build_runtime_collection_manifest() {
    local runtime="$1"
    local collection="$2"

    build_current_collection_manifest "$runtime" "$collection"
}

build_runtime_collection_expected_tests() {
    local runtime="$1"
    local collection="$2"

    cld6001_testcases_for_collection "$collection" "$environment_state"
}

build_current_result_record() {
    local runtime="$1"
    local test_id="$2"
    local fields=""
    local normalized_result=""
    local result_dir=""
    local log_path=""
    local context_path=""

    fields="$(build_current_result_fields "$runtime" "$test_id")"
    IFS='|' read -r normalized_result result_dir log_path context_path <<< "$fields"

    printf '%s|%s|%s|%s|%s\n' \
        "$test_id" \
        "$normalized_result" \
        "$result_dir" \
        "$log_path" \
        "$context_path"
}

find_latest_matching_path() {
    local path_pattern=""
    local candidate_path=""
    local latest_path=""
    local globstar_was_enabled=0

    if ! shopt -q globstar; then
        shopt -s globstar
        globstar_was_enabled=1
    fi

    for path_pattern in "$@"; do
        while IFS= read -r candidate_path; do
            [ -e "$candidate_path" ] || continue
            latest_path="$candidate_path"
        done < <(compgen -G "$path_pattern" | LC_ALL=C sort)
    done

    if [ "$globstar_was_enabled" -eq 1 ]; then
        shopt -u globstar
    fi

    [ -n "$latest_path" ] && printf '%s\n' "$latest_path"
}

list_matching_paths() {
    local path_pattern=""
    local candidate_path=""
    local globstar_was_enabled=0

    if ! shopt -q globstar; then
        shopt -s globstar
        globstar_was_enabled=1
    fi

    for path_pattern in "$@"; do
        while IFS= read -r candidate_path; do
            [ -e "$candidate_path" ] || continue
            printf '%s\n' "$candidate_path"
        done < <(compgen -G "$path_pattern" | LC_ALL=C sort)
    done

    if [ "$globstar_was_enabled" -eq 1 ]; then
        shopt -u globstar
    fi
}

directory_has_entries() {
    local directory_path="$1"
    [ -d "$directory_path" ] || return 1
    find "$directory_path" -mindepth 1 -maxdepth 1 -print -quit | grep -q .
}

resolve_persisted_result_dir() {
    local runtime="$1"
    local test_id="$2"
    local canonical_test_id=""
    local path_test_id=""
    local log_path=""

    canonical_test_id="$(testcase_key "$test_id")"
    path_test_id="$(testcase_path_id "$test_id")"
    log_path="$(find_latest_matching_path \
        "$RESULTS_ROOT/$path_test_id/$runtime/$profile_slug/**/test-output.log" \
        "$RESULTS_ROOT/$path_test_id/$runtime/**/test-output.log")"
    if [ -z "$log_path" ] && [ "$path_test_id" != "$canonical_test_id" ]; then
        log_path="$(find_latest_matching_path \
            "$RESULTS_ROOT/$canonical_test_id/$runtime/$profile_slug/**/test-output.log" \
            "$RESULTS_ROOT/$canonical_test_id/$runtime/**/test-output.log")"
    fi
    [ -n "$log_path" ] || return 0
    dirname -- "$log_path"
}

persisted_result_context_matches_current_run() {
    local context_path="${1:-}"
    local context_run_session_id=""
    local context_environment_state=""
    local context_profile_slug=""

    [ -n "${RUN_SESSION_ID:-}" ] || return 1
    [ -f "$context_path" ] || return 1

    IFS=$'\001' read -r context_run_session_id context_environment_state context_profile_slug < <(
        jq -r '[.run_session_id // "", .environment_state // "", .profile_slug // ""] | join("\u0001")' "$context_path" 2>/dev/null || true
    )
    [ -n "$context_run_session_id" ] || return 1
    [ "$context_run_session_id" = "$RUN_SESSION_ID" ] || return 1

    if [ -n "${environment_state:-}" ] && [ -n "$context_environment_state" ] && [ "$context_environment_state" != "$environment_state" ]; then
        return 1
    fi

    if [ -n "${profile_slug:-}" ] && [ -n "$context_profile_slug" ] && [ "$context_profile_slug" != "$profile_slug" ]; then
        return 1
    fi

    return 0
}

persisted_result_context_match_strength() {
    local context_path="${1:-}"
    local context_environment_state=""
    local context_profile_slug=""
    local strength=0

    [ -f "$context_path" ] || return 1

    IFS=$'\001' read -r _ context_environment_state context_profile_slug < <(
        jq -r '[.run_session_id // "", .environment_state // "", .profile_slug // ""] | join("\u0001")' "$context_path" 2>/dev/null || true
    )

    if [ -n "${environment_state:-}" ] && [ -n "$context_environment_state" ] && [ "$context_environment_state" = "$environment_state" ]; then
        strength=$((strength + 1))
    fi

    if [ -n "${profile_slug:-}" ] && [ -n "$context_profile_slug" ] && [ "$context_profile_slug" = "$profile_slug" ]; then
        strength=$((strength + 1))
    fi

    printf '%s\n' "$strength"
}

normalize_persisted_execution_result() {
    case "${1:-}" in
        pass|block|fail)
            printf '%s\n' "$1"
            ;;
        *)
            printf '%s\n' fail
            ;;
    esac
}

list_current_run_search_roots() {
    {
        if [ -n "${CLD6001_RUN_ROOT:-}" ]; then
            printf '%s\n' "$CLD6001_RUN_ROOT/runner"
            if [ -n "${RESULTS_ROOT:-}" ]; then
                case "$RESULTS_ROOT" in
                    "$CLD6001_RUN_ROOT"/*)
                        printf '%s\n' "$RESULTS_ROOT"
                        ;;
                esac
            fi
        elif [ -n "${RESULTS_ROOT:-}" ]; then
            printf '%s\n' "$RESULTS_ROOT"
        fi
    } | awk 'NF && !seen[$0]++'
}

current_run_search_root() {
    list_current_run_search_roots | head -n 1
}

list_current_run_persisted_result_context_paths() {
    local search_root="$1"
    local runtime="$2"
    local canonical_test_id="$3"
    local path_test_id="$4"
    local current_profile_slug="$5"
    local matched_any=0
    local context_path=""

    while IFS= read -r context_path; do
        matched_any=1
        printf '%s\n' "$context_path"
    done < <(list_matching_paths \
        "$search_root/current/$canonical_test_id/execution-context.json" \
        "$search_root/$path_test_id/$runtime/$current_profile_slug/**/execution-context.json" \
        "$search_root/$path_test_id/$runtime/**/execution-context.json" \
        "$search_root/*/$path_test_id/$runtime/$current_profile_slug/**/execution-context.json" \
        "$search_root/*/$path_test_id/$runtime/**/execution-context.json" | awk '!seen[$0]++')

    if [ "$matched_any" -eq 1 ] || [ "$path_test_id" = "$canonical_test_id" ]; then
        return 0
    fi

    list_matching_paths \
        "$search_root/$canonical_test_id/$runtime/$current_profile_slug/**/execution-context.json" \
        "$search_root/$canonical_test_id/$runtime/**/execution-context.json" \
        "$search_root/*/$canonical_test_id/$runtime/$current_profile_slug/**/execution-context.json" \
        "$search_root/*/$canonical_test_id/$runtime/**/execution-context.json" | awk '!seen[$0]++'
}

resolve_current_run_persisted_result_context_path() {
    local runtime="$1"
    local test_id="$2"
    local canonical_test_id=""
    local path_test_id=""
    local current_profile_slug="${profile_slug:-}"
    local search_root=""
    local context_path=""
    local latest_context_path=""
    local latest_context_strength=-1
    local latest_context_count=0
    local fallback_context_path=""
    local fallback_context_count=0
    local context_strength=0
    local required_context_strength=0

    canonical_test_id="$(testcase_key "$test_id")"
    path_test_id="$(testcase_path_id "$test_id")"
    [ -n "${environment_state:-}" ] && required_context_strength=$((required_context_strength + 1))
    [ -n "${profile_slug:-}" ] && required_context_strength=$((required_context_strength + 1))

    while IFS= read -r search_root; do
        [ -n "$search_root" ] || continue

        while IFS= read -r context_path; do
            [ -f "$context_path" ] || continue
            persisted_result_context_matches_current_run "$context_path" || continue
            context_strength="$(persisted_result_context_match_strength "$context_path")"
            if [ "$context_strength" -gt 0 ]; then
                if [ "$context_strength" -gt "$latest_context_strength" ]; then
                    latest_context_path="$context_path"
                    latest_context_strength="$context_strength"
                    latest_context_count=1
                elif [ "$context_strength" -eq "$latest_context_strength" ]; then
                    latest_context_path="$context_path"
                    latest_context_count=$((latest_context_count + 1))
                fi
                continue
            fi
            fallback_context_path="$context_path"
            fallback_context_count=$((fallback_context_count + 1))
        done < <(list_current_run_persisted_result_context_paths "$search_root" "$runtime" "$canonical_test_id" "$path_test_id" "$current_profile_slug")
    done < <(list_current_run_search_roots)

    if [ -n "$latest_context_path" ] && { [ "$latest_context_strength" -eq "$required_context_strength" ] || [ "$latest_context_count" -eq 1 ]; }; then
        printf '%s\n' "$latest_context_path"
        return 0
    fi

    if [ "$fallback_context_count" -eq 1 ] && [ -n "$fallback_context_path" ]; then
        printf '%s\n' "$fallback_context_path"
    fi
}

resolve_current_run_persisted_result_dir() {
    local runtime="$1"
    local test_id="$2"
    local context_path=""

    context_path="$(resolve_current_run_persisted_result_context_path "$runtime" "$test_id")"
    [ -n "$context_path" ] || return 0
    dirname -- "$context_path"
}

resolve_current_run_result_step_root() {
    local result_dir="$1"
    local test_id="$2"
    local search_root=""
    local canonical_test_id=""
    local path_test_id=""

    [ -n "$result_dir" ] || return 0

    canonical_test_id="$(testcase_key "$test_id")"
    path_test_id="$(testcase_path_id "$test_id")"

    while IFS= read -r search_root; do
        [ -n "$search_root" ] || continue

        case "$result_dir" in
            "$search_root/$canonical_test_id"|"$search_root/$canonical_test_id/"*|\
            "$search_root/current/$canonical_test_id"|"$search_root/current/$canonical_test_id/"*)
                printf '%s\n' "$search_root"
                return 0
                ;;
            "$search_root"/*"/$canonical_test_id"|"$search_root"/*"/$canonical_test_id/"*)
                printf '%s\n' "${result_dir%/$canonical_test_id*}"
                return 0
                ;;
        esac

        if [ "$path_test_id" != "$canonical_test_id" ]; then
            case "$result_dir" in
                "$search_root/$path_test_id"|"$search_root/$path_test_id/"*|\
                "$search_root/current/$path_test_id"|"$search_root/current/$path_test_id/"*)
                    printf '%s\n' "$search_root"
                    return 0
                    ;;
                "$search_root"/*"/$path_test_id"|"$search_root"/*"/$path_test_id/"*)
                    printf '%s\n' "${result_dir%/$path_test_id*}"
                    return 0
                    ;;
            esac
        fi
    done < <(list_current_run_search_roots)

    return 1
}

resolve_current_result_dir() {
    local runtime="$1"
    local test_id="$2"
    local result_dir=""

    result_dir="$(resolve_in_memory_result_dir "$runtime" "$test_id")"
    if [ -n "$result_dir" ]; then
        printf '%s\n' "$result_dir"
        return 0
    fi

    resolve_current_run_persisted_result_dir "$runtime" "$test_id"
}

build_current_result_fields() {
    local runtime="$1"
    local test_id="$2"
    local result_dir=""
    local exit_code=""
    local normalized_result="fail"
    local log_path=""
    local context_path=""
    local in_memory_result=0

    result_dir="$(resolve_in_memory_result_dir "$runtime" "$test_id")"
    if [ -n "$result_dir" ]; then
        in_memory_result=1
        exit_code="$(resolve_in_memory_exit_code "$runtime" "$test_id")"
        normalized_result="$(normalize_test_exit_result "$exit_code")"
    else
        result_dir="$(resolve_current_run_persisted_result_dir "$runtime" "$test_id")"
        if [ -n "$result_dir" ]; then
            if [ -f "$result_dir/execution-context.json" ]; then
                context_path="$result_dir/execution-context.json"
                normalized_result="$(normalize_persisted_execution_result "$(jq -r '.result // empty' "$context_path" 2>/dev/null || true)")"
            fi
        fi
    fi

    if [ -n "$result_dir" ]; then
        if [ "$in_memory_result" -eq 1 ]; then
            log_path="$result_dir/test-output.log"
            context_path="$result_dir/execution-context.json"
        elif [ -f "$result_dir/test-output.log" ]; then
            log_path="$result_dir/test-output.log"
        fi
        if [ "$in_memory_result" -ne 1 ] && [ -f "$result_dir/execution-context.json" ]; then
            context_path="$result_dir/execution-context.json"
        fi
    fi

    printf '%s|%s|%s|%s\n' \
        "$normalized_result" \
        "$result_dir" \
        "$log_path" \
        "$context_path"
}

resolve_persisted_collection_d_artifacts_dir() {
    local runtime="$1"
    local test_id="$2"
    local canonical_test_id=""
    local path_test_id=""
    local collection_results_dir=""
    local artifacts_dir=""

    canonical_test_id="$(testcase_key "$test_id")"
    path_test_id="$(testcase_path_id "$test_id")"
    collection_results_dir="$RESULTS_ROOT/collection-d/$path_test_id/$runtime"
    if directory_has_entries "$collection_results_dir"; then
        printf '%s\n' "$collection_results_dir"
        return 0
    fi

    if [ "$path_test_id" != "$canonical_test_id" ]; then
        collection_results_dir="$RESULTS_ROOT/collection-d/$canonical_test_id/$runtime"
        if directory_has_entries "$collection_results_dir"; then
            printf '%s\n' "$collection_results_dir"
            return 0
        fi
    fi

    artifacts_dir="$(find_latest_matching_path \
        "$RESULTS_ROOT/$path_test_id/$runtime/$profile_slug/**/artifacts" \
        "$RESULTS_ROOT/$path_test_id/$runtime/**/artifacts")"
    if [ -z "$artifacts_dir" ] && [ "$path_test_id" != "$canonical_test_id" ]; then
        artifacts_dir="$(find_latest_matching_path \
            "$RESULTS_ROOT/$canonical_test_id/$runtime/$profile_slug/**/artifacts" \
            "$RESULTS_ROOT/$canonical_test_id/$runtime/**/artifacts")"
    fi
    [ -n "$artifacts_dir" ] && [ -d "$artifacts_dir" ] || return 0
    printf '%s\n' "$artifacts_dir"
}

resolve_current_run_collection_d_artifacts_dir() {
    local runtime="$1"
    local test_id="$2"
    local canonical_test_id=""
    local path_test_id=""
    local search_root=""
    local collection_results_dir=""

    canonical_test_id="$(testcase_key "$test_id")"
    path_test_id="$(testcase_path_id "$test_id")"

    while IFS= read -r search_root; do
        [ -n "$search_root" ] || continue
        collection_results_dir="$search_root/collection-d/$path_test_id/$runtime"

        if directory_has_entries "$collection_results_dir"; then
            printf '%s\n' "$collection_results_dir"
            return 0
        fi

        if [ "$path_test_id" != "$canonical_test_id" ]; then
            collection_results_dir="$search_root/collection-d/$canonical_test_id/$runtime"

            if directory_has_entries "$collection_results_dir"; then
                printf '%s\n' "$collection_results_dir"
                return 0
            fi
        fi
    done < <(list_current_run_search_roots)
}

resolve_persisted_shared_artifact_file() {
    local runtime="$1"
    local relative_path="$2"
    local artifact_path=""
    artifact_path="$(find_latest_matching_path \
        "$RESULTS_ROOT/shared/**/$runtime/**/$relative_path" \
        "$RESULTS_ROOT/tc18/$runtime/$profile_slug/**/artifacts/$relative_path" \
        "$RESULTS_ROOT/tc18/$runtime/**/artifacts/$relative_path" \
        "$RESULTS_ROOT/test-results/$profile_slug/*/$runtime/**/$relative_path" \
        "$RESULTS_ROOT/test-results/*/$runtime/**/$relative_path")"
    [ -n "$artifact_path" ] || return 0
    printf '%s\n' "$artifact_path"
}

resolve_in_memory_shared_artifact_file() {
    local runtime="$1"
    local relative_path="$2"
    local artifact_path=""

    [ -n "${TEST_RESULTS_ROOT:-}" ] || return 0
    artifact_path="$TEST_RESULTS_ROOT/$runtime/$relative_path"
    [ -f "$artifact_path" ] || return 0
    printf '%s\n' "$artifact_path"
}

resolve_current_run_tc18_shared_artifact_file() {
    local runtime="$1"
    local relative_path="$2"
    local context_path=""
    local result_dir=""
    local step_root=""
    local artifact_path=""

    [ -n "${RUN_SESSION_ID:-}" ] || return 0
    context_path="$(resolve_current_run_persisted_result_context_path "$runtime" "tc18")"
    [ -n "$context_path" ] || return 0

    result_dir="$(dirname -- "$context_path")"
    step_root="$(resolve_current_run_result_step_root "$result_dir" "tc18")"
    [ -n "$step_root" ] || return 0

    artifact_path="$(find_latest_matching_path \
        "$step_root/shared/$RUN_SESSION_ID/$runtime/**/$relative_path")"
    [ -n "$artifact_path" ] || return 0
    printf '%s\n' "$artifact_path"
}

resolve_predecessor_artifacts_dir() {
    local runtime="$1"
    local test_id="$2"
    local result_dir=""
    local artifacts_dir=""

    result_dir="$(resolve_in_memory_result_dir "$runtime" "$test_id")"

    if [ -n "$result_dir" ]; then
        artifacts_dir="$result_dir/artifacts"
        if directory_has_entries "$artifacts_dir"; then
            printf '%s\n' "$artifacts_dir"
            return 0
        fi
    fi

    artifacts_dir="$(resolve_persisted_collection_d_artifacts_dir "$runtime" "$test_id")"
    if [ -n "$artifacts_dir" ]; then
        printf '%s\n' "$artifacts_dir"
        return 0
    fi

    return 0
}

resolve_current_predecessor_artifacts_dir() {
    local runtime="$1"
    local test_id="$2"
    local result_dir=""
    local artifacts_dir=""

    result_dir="$(resolve_in_memory_result_dir "$runtime" "$test_id")"

    if [ -n "$result_dir" ]; then
        artifacts_dir="$result_dir/artifacts"
        if directory_has_entries "$artifacts_dir"; then
            printf '%s\n' "$artifacts_dir"
            return 0
        fi
    fi

    result_dir="$(resolve_current_run_persisted_result_dir "$runtime" "$test_id")"
    if [ -n "$result_dir" ]; then
        artifacts_dir="$(resolve_current_run_collection_d_artifacts_dir "$runtime" "$test_id")"
        if [ -n "$artifacts_dir" ]; then
            printf '%s\n' "$artifacts_dir"
            return 0
        fi

        artifacts_dir="$result_dir/artifacts"
        if directory_has_entries "$artifacts_dir"; then
            printf '%s\n' "$artifacts_dir"
            return 0
        fi
    fi

    return 0
}

resolve_predecessor_artifact_file() {
    local runtime="$1"
    local test_id="$2"
    local relative_path="$3"
    local artifacts_dir=""
    local artifact_path=""

    if [ "$test_id" = "tc18" ]; then
        artifact_path="$(resolve_in_memory_shared_artifact_file "$runtime" "$relative_path")"
        if [ -n "$artifact_path" ]; then
            printf '%s\n' "$artifact_path"
            return 0
        fi
    fi

    artifacts_dir="$(resolve_predecessor_artifacts_dir "$runtime" "$test_id")"
    if [ -n "$artifacts_dir" ]; then
        artifact_path="$artifacts_dir/$relative_path"
        if [ -f "$artifact_path" ]; then
            printf '%s\n' "$artifact_path"
            return 0
        fi
    fi

    if [ "$test_id" = "tc18" ]; then
        artifact_path="$(resolve_persisted_shared_artifact_file "$runtime" "$relative_path")"
        [ -n "$artifact_path" ] || return 0
        printf '%s\n' "$artifact_path"
        return 0
    fi

    return 0
}

resolve_current_predecessor_artifact_file() {
    local runtime="$1"
    local test_id="$2"
    local relative_path="$3"
    local artifacts_dir=""
    local artifact_path=""

    if [ "$test_id" = "tc18" ]; then
        artifact_path="$(resolve_in_memory_shared_artifact_file "$runtime" "$relative_path")"
        if [ -n "$artifact_path" ]; then
            printf '%s\n' "$artifact_path"
            return 0
        fi
    fi

    artifacts_dir="$(resolve_current_predecessor_artifacts_dir "$runtime" "$test_id")"
    if [ -n "$artifacts_dir" ]; then
        artifact_path="$artifacts_dir/$relative_path"
        if [ -f "$artifact_path" ]; then
            printf '%s\n' "$artifact_path"
            return 0
        fi
    fi

    if [ "$test_id" = "tc18" ]; then
        artifact_path="$(resolve_current_run_tc18_shared_artifact_file "$runtime" "$relative_path")"
        if [ -n "$artifact_path" ]; then
            printf '%s\n' "$artifact_path"
            return 0
        fi
    fi

    return 0
}

normalize_test_exit_result() {
    local exit_code="${1:-1}"

    case "$exit_code" in
        0)
            printf '%s\n' pass
            ;;
        "$BLOCK_EXIT_CODE")
            printf '%s\n' block
            ;;
        *)
            printf '%s\n' fail
            ;;
    esac
}

validate_profile_runtime_support() {
    local runtime="$1"
    LAST_PROFILE_RUNTIME_SUPPORT_DETAILS=""
    [ -z "${profile:-}" ] && return 0
    local runtime_name=""
    local mode_name=""

    runtime_name="$(runtime_engine "$runtime")" || return 1
    mode_name="$(runtime_mode "$runtime")" || return 1
    if [ "$(profile_supports "$profile_json" "$runtime_name" "$mode_name")" != "true" ]; then
        LAST_PROFILE_RUNTIME_SUPPORT_DETAILS="Profile $profile does not support $runtime"
        error "$LAST_PROFILE_RUNTIME_SUPPORT_DETAILS"
        return 1
    fi
}

run_live_preflight() {
    local runtime_selection="$1"
    local collection_filter="${2:-}"
    local -a runtimes=()
    local runtime
    local disk_headroom_failures=0
    local temp_work_root=""
    local results_disk_headroom_status=""
    local results_disk_headroom_details=""
    local temp_work_disk_headroom_status=""
    local temp_work_disk_headroom_details=""
    LAST_TEMP_WORK_ROOT_CREATION_DETAILS=""

    if [ -n "$collection_filter" ]; then
        mapfile -t runtimes < <(resolve_targeted_runtimes "$collection_filter" "$runtime_selection")
    else
        mapfile -t runtimes < <(resolve_requested_runtimes "$runtime_selection")
    fi

    [ "${#runtimes[@]}" -gt 0 ] || {
        error "No runtimes selected for live preflight"
        return 1
    }

    temp_work_root="$(resolve_temp_work_root)" || return 1

    run_disk_headroom_check \
        "$RESULTS_ROOT_DISK_HEADROOM_CHECK_ID" \
        "Live disk headroom for results filesystem" \
        "$RESULTS_ROOT" || ((disk_headroom_failures+=1))
    results_disk_headroom_status="$LAST_DISK_HEADROOM_STATUS"
    results_disk_headroom_details="$LAST_DISK_HEADROOM_DETAILS"
    run_disk_headroom_check \
        "$TEMP_WORK_ROOT_DISK_HEADROOM_CHECK_ID" \
        "Live disk headroom for temp-work backing filesystem" \
        "$temp_work_root" || ((disk_headroom_failures+=1))
    temp_work_disk_headroom_status="$LAST_DISK_HEADROOM_STATUS"
    temp_work_disk_headroom_details="$LAST_DISK_HEADROOM_DETAILS"

    if [ "$disk_headroom_failures" -ne 0 ]; then
        if can_persist_live_preflight_results; then
            persist_live_preflight_results \
                "$results_disk_headroom_status" \
                "$results_disk_headroom_details" \
                "$temp_work_disk_headroom_status" \
                "$temp_work_disk_headroom_details" \
                "${runtimes[@]}"
        fi
        return 1
    fi

    mkdir -p "$RESULTS_ROOT" || return 1
    [ -w "$RESULTS_ROOT" ] || {
        error "Results root is not writable: $RESULTS_ROOT"
        return 1
    }
    mkdir -p "$temp_work_root" || {
        LAST_TEMP_WORK_ROOT_CREATION_DETAILS="Failed to create temp-work root: $temp_work_root"
        persist_live_preflight_results \
            "$results_disk_headroom_status" \
            "$results_disk_headroom_details" \
            "$temp_work_disk_headroom_status" \
            "$temp_work_disk_headroom_details" \
            "${runtimes[@]}"
        for runtime in "${runtimes[@]}"; do
            persist_live_preflight_failure_checks "$runtime" "temp_work_root_creation"
        done
        return 1
    }

    for runtime in "${runtimes[@]}"; do
        enforce_environment_state_for_runtime "$runtime" "preflight" || {
            persist_live_preflight_results \
                "$results_disk_headroom_status" \
                "$results_disk_headroom_details" \
                "$temp_work_disk_headroom_status" \
                "$temp_work_disk_headroom_details" \
                "${runtimes[@]}"
            persist_live_preflight_failure_checks "$runtime" "environment_state"
            return 1
        }
        validate_profile_runtime_support "$runtime" || {
            persist_live_preflight_results \
                "$results_disk_headroom_status" \
                "$results_disk_headroom_details" \
                "$temp_work_disk_headroom_status" \
                "$temp_work_disk_headroom_details" \
                "${runtimes[@]}"
            persist_live_preflight_failure_checks "$runtime" "profile_runtime_support"
            return 1
        }
        check_prerequisites "$runtime" || {
            persist_live_preflight_results \
                "$results_disk_headroom_status" \
                "$results_disk_headroom_details" \
                "$temp_work_disk_headroom_status" \
                "$temp_work_disk_headroom_details" \
                "${runtimes[@]}"
            persist_live_preflight_failure_checks "$runtime" "prerequisites"
            return 1
        }
        check_runtime_functionality "$runtime" || {
            error "Runtime preflight failed for $runtime"
            persist_live_preflight_results \
                "$results_disk_headroom_status" \
                "$results_disk_headroom_details" \
                "$temp_work_disk_headroom_status" \
                "$temp_work_disk_headroom_details" \
                "${runtimes[@]}"
            persist_live_preflight_failure_checks "$runtime" "runtime_functionality"
            return 1
        }
        check_runtime_connectivity "$runtime" || {
            persist_live_preflight_results \
                "$results_disk_headroom_status" \
                "$results_disk_headroom_details" \
                "$temp_work_disk_headroom_status" \
                "$temp_work_disk_headroom_details" \
                "${runtimes[@]}"
            persist_live_preflight_failure_checks "$runtime" "connectivity"
            return 1
        }
    done

    persist_live_preflight_results \
        "$results_disk_headroom_status" \
        "$results_disk_headroom_details" \
        "$temp_work_disk_headroom_status" \
        "$temp_work_disk_headroom_details" \
        "${runtimes[@]}"
    for runtime in "${runtimes[@]}"; do
        persist_live_preflight_success_checks "$runtime" "$temp_work_root"
    done
}

run_auxiliary_command() {
    local description="$1"
    shift

    local output=""
    set +e
    output="$("$@" 2>&1)"
    local status=$?
    set -e

    if [ "$status" -ne 0 ]; then
        if [ -n "$output" ]; then
            warn "$description failed: $output"
        else
            warn "$description failed with exit code $status"
        fi
        return 1
    fi

    if [ -n "$output" ]; then
        info "$description: $output"
    fi

    return 0
}

capture_state() {
    local stage="$1"
    local test_id="$2"
    local runtime="$3"
    local snapshot_root=""

    if [ -n "${CLD6001_RUN_ROOT:-}" ]; then
        snapshot_root="$(resolve_runner_path "${CLD6001_RUN_ROOT}/snapshots")" || return 1
    else
        snapshot_root="$LIVERUN_DIR/snapshots"
    fi

    info "Capturing ${stage}-test state..."
    run_auxiliary_command "${stage} system snapshot for ${test_id}/${runtime}" \
        env SNAPSHOT_DIR="$snapshot_root" bash "$REPO_ROOT/src/collect/snapshots/system-snapshot.sh" create || true
    run_auxiliary_command "${stage} config snapshot for ${test_id}/${runtime}" \
        env SNAPSHOT_DIR="$snapshot_root" bash "$REPO_ROOT/src/collect/snapshots/config-snapshot.sh" || true
    run_auxiliary_command "${stage} container snapshot for ${test_id}/${runtime}" \
        env SNAPSHOT_DIR="$snapshot_root" SNAPSHOT_RUNTIME="$(runtime_engine "$runtime")" bash "$REPO_ROOT/src/collect/snapshots/container-snapshot.sh" || true
}

execute_test() {
    local collection="$1"
    local test_id="$2"
    local runtime="$3"
    local target_image="${4:-}"
    local target_base_os="${5:-}"
    local target_flavor="${6:-}"
    local runtime_name=""
    local runtime_mode_name=""
    local timestamp
    local normalized_result="fail"
    local shared_test_results_dir=""
    local runtime_collection_results_dir=""
    local test_output_file=""
    local preflight_logs=""
    local collection_a_logs=""
    local collection_b_logs=""
    local preflight_manifest=""
    local collection_a_manifest=""
    local collection_b_manifest=""
    local preflight_expected_tests=""
    local collection_a_expected_tests=""
    local collection_b_expected_tests=""
    local tc18_artifact_file=""
    local tc19_artifacts_dir=""
    local tc20_artifacts_dir=""
    local tc18_record=""
    local tc19_record=""
    local tc20_record=""
    local runner_dependency_collections=""
    local runner_collection_a_manifest=""
    local runner_collection_a_expected_tests=""
    local runner_collection_a_logs=""
    local runner_collection_b_manifest=""
    local runner_collection_b_expected_tests=""
    local runner_collection_b_logs=""
    local runner_collection_c_manifest=""
    local runner_collection_c_expected_tests=""
    local runner_collection_c_logs=""
    local runner_collection_e_manifest=""
    local runner_collection_e_expected_tests=""
    local runner_collection_e_logs=""
    local runner_collection_d_manifest=""
    local runner_collection_d_expected_tests=""
    local runner_collection_d_logs=""
    local runner_collection_f_manifest=""
    local runner_collection_f_expected_tests=""
    local runner_collection_f_logs=""
    local runner_collection_g_manifest=""
    local runner_collection_g_expected_tests=""
    local runner_collection_g_logs=""
    local variant_identity=""
    local variant_path=""
    local base_result_key=""
    local result_store_key=""
    local reason_path=""
    local canonical_test_id=""
    local phase_results_repo_root=""
    local -a runner_env_args=()
    timestamp="$(cld6001_unique_timestamp_id)"
    runtime_name="$(runtime_engine "$runtime")" || return 1
    runtime_mode_name="$(runtime_mode "$runtime")" || return 1

    section "Executing Test Case: $test_id - $runtime - Image: ${target_image:-default} - OS: ${target_base_os:-default} - Flavor: ${target_flavor:-default} (timeout: ${TIMEOUT_SECONDS}s)"

    variant_identity="$(build_variant_identity "$target_image" "$target_base_os" "$target_flavor" || true)"
    variant_path="$(build_variant_path "$target_image" "$target_base_os" "$target_flavor" || true)"
    base_result_key="${runtime}:${test_id}"
    result_store_key="${base_result_key}${variant_identity:+:${variant_identity}}"

    local results_dir="$RESULTS_ROOT/$test_id/$runtime/$profile_slug/$timestamp"
    local artifacts_dir="$results_dir/artifacts"
    shared_test_results_dir="$TEST_RESULTS_ROOT/$runtime"

    if [ -n "$variant_path" ]; then
        results_dir="$RESULTS_ROOT/$test_id/$runtime/$profile_slug/$variant_path/$timestamp"
        artifacts_dir="$results_dir/artifacts"
        shared_test_results_dir="$shared_test_results_dir/$variant_path"
    fi

    mkdir -p "$results_dir"
    ensure_runtime_output_dir "$runtime" "$results_dir" || return 1
    ensure_runtime_output_dir "$runtime" "$artifacts_dir" || return 1
    ensure_runtime_output_dir "$runtime" "$shared_test_results_dir" || return 1
    reason_path="$(cld6001_resolve_result_reason_path "$artifacts_dir" "${test_id}-${timestamp}")" || return 1
    canonical_test_id="$(testcase_key "$test_id")"

    case "$canonical_test_id" in
        tc20)
            phase_results_repo_root="$RESULTS_ROOT"
            runtime_collection_results_dir="$phase_results_repo_root/collection-$collection/$test_id/$runtime"
            ensure_runtime_output_dir "$runtime" "$runtime_collection_results_dir" || return 1
            ;;
        tc19|tc21)
            runtime_collection_results_dir="$RESULTS_ROOT/collection-d/$test_id/$runtime"
            ensure_runtime_output_dir "$runtime" "$runtime_collection_results_dir" || return 1
            ;;
        tc22|tc23|tc24)
            runtime_collection_results_dir="$RESULTS_ROOT/collection-g/$test_id/$runtime"
            ensure_runtime_output_dir "$runtime" "$runtime_collection_results_dir" || return 1
            ;;
    esac

    capture_state "pre" "$test_id" "$runtime"

    local test_script
    test_script="$(resolve_test_script "$test_id" "$runtime")" || return 1

    if [ ! -f "$test_script" ]; then
        error "Test script not found: $test_script"
        return 1
    fi

    if [ "$canonical_test_id" = "tc21" ]; then
        runner_dependency_collections="a,b,c,d,e,f,g"

        runner_collection_a_manifest="$(build_current_collection_manifest "$runtime" "a")"
        runner_collection_a_expected_tests="$(build_runtime_collection_expected_tests "$runtime" "a")"
        runner_collection_a_logs="$(collect_current_collection_output_logs "$runtime" "a")"

        runner_collection_b_manifest="$(build_current_collection_manifest "$runtime" "b")"
        runner_collection_b_expected_tests="$(build_runtime_collection_expected_tests "$runtime" "b")"
        runner_collection_b_logs="$(collect_current_collection_output_logs "$runtime" "b")"

        runner_collection_c_manifest="$(build_current_collection_manifest "$runtime" "c")"
        runner_collection_c_expected_tests="$(build_runtime_collection_expected_tests "$runtime" "c")"
        runner_collection_c_logs="$(collect_current_collection_output_logs "$runtime" "c")"

        runner_collection_d_manifest="$(build_current_collection_manifest "$runtime" "d")"
        runner_collection_d_expected_tests="$(build_runtime_collection_expected_tests "$runtime" "d")"
        runner_collection_d_logs="$(collect_current_collection_output_logs "$runtime" "d")"

        runner_collection_e_manifest="$(build_current_collection_manifest "$runtime" "e")"
        runner_collection_e_expected_tests="$(build_runtime_collection_expected_tests "$runtime" "e")"
        runner_collection_e_logs="$(collect_current_collection_output_logs "$runtime" "e")"

        runner_collection_f_manifest="$(build_current_collection_manifest "$runtime" "f")"
        runner_collection_f_expected_tests="$(build_runtime_collection_expected_tests "$runtime" "f")"
        runner_collection_f_logs="$(collect_current_collection_output_logs "$runtime" "f")"

        runner_collection_g_manifest="$(build_current_collection_manifest "$runtime" "g")"
        runner_collection_g_expected_tests="$(build_runtime_collection_expected_tests "$runtime" "g")"
        runner_collection_g_logs="$(collect_current_collection_output_logs "$runtime" "g")"

        preflight_logs="$runner_collection_a_logs"
        collection_a_logs="$runner_collection_b_logs"
        collection_b_logs="$runner_collection_c_logs"
        preflight_manifest="$runner_collection_a_manifest"
        collection_a_manifest="$runner_collection_b_manifest"
        collection_b_manifest="$runner_collection_c_manifest"
        preflight_expected_tests="$runner_collection_a_expected_tests"
        collection_a_expected_tests="$runner_collection_b_expected_tests"
        collection_b_expected_tests="$runner_collection_c_expected_tests"

        tc18_artifact_file="$(resolve_current_predecessor_artifact_file "$runtime" "tc18" "tc18-results.txt")"
        tc19_artifacts_dir="$(resolve_current_predecessor_artifacts_dir "$runtime" "tc19")"
        tc20_artifacts_dir="$(resolve_current_predecessor_artifacts_dir "$runtime" "tc20")"
        tc18_record="$(build_current_result_record "$runtime" "tc18")"
        tc19_record="$(build_current_result_record "$runtime" "tc19")"
        tc20_record="$(build_current_result_record "$runtime" "tc20")"
    fi

    test_output_file="$results_dir/test-output.log"
    ensure_runtime_output_file "$runtime" "$test_output_file" || return 1

    info "Running test case: $test_id..."
    runner_env_args=(
        "RESULTS_REPO_ROOT=$RESULTS_ROOT" \
        "RUNNER_SOURCE_REPO_ROOT=${RUNNER_SOURCE_REPO_ROOT:-$REPO_ROOT}" \
        "TEST_RESULTS_DIR=$shared_test_results_dir" \
        "RUNNER_ARTIFACTS_DIR=$artifacts_dir" \
        "RUNNER_TEST_ID=$test_id" \
        "RUNNER_REASON_PATH=$reason_path" \
        "RUNNER_PHASE_RESULTS_DIR=$runtime_collection_results_dir" \
        "RUNNER_RESULTS_DIR=$results_dir" \
        "RUNNER_RESULTS_ROOT=$RESULTS_ROOT" \
        "RUNNER_PROFILE_SLUG=$profile_slug" \
        "RUNNER_RUN_SESSION_ID=$RUN_SESSION_ID" \
        "RUNNER_ENVIRONMENT_STATE=$environment_state" \
        "RUNNER_RELAXED_DEBUG=$RUNNER_RELAXED_DEBUG" \
        "RUNNER_HOST_PROFILE=$host_profile" \
        "RUNNER_RUNTIME_PROFILE=$runtime_profile" \
        "RUNNER_RUNTIME_ID=$runtime" \
        "RUNNER_RUNTIME_ENGINE=$runtime_name" \
        "RUNNER_RUNTIME_MODE=$runtime_mode_name" \
        "RUNNER_COPYFAIL_MODE=$copyfail_mode" \
        "RUNNER_COPYFAIL_MODE_SOURCE=$copyfail_mode_source" \
        "RUNNER_TARGET_IMAGE=$target_image" \
        "RUNNER_TARGET_BASE_OS=$target_base_os" \
        "RUNNER_TARGET_FLAVOR=$target_flavor" \
        "RUNNER_PREFLIGHT_LOGS=$preflight_logs" \
        "RUNNER_COLLECTION_A_LOGS=$collection_a_logs" \
        "RUNNER_COLLECTION_B_LOGS=$collection_b_logs" \
        "RUNNER_PREFLIGHT_EXPECTED_TESTS=$preflight_expected_tests" \
        "RUNNER_COLLECTION_A_EXPECTED_TESTS=$collection_a_expected_tests" \
        "RUNNER_COLLECTION_B_EXPECTED_TESTS=$collection_b_expected_tests" \
        "RUNNER_PREFLIGHT_MANIFEST=$preflight_manifest" \
        "RUNNER_COLLECTION_A_MANIFEST=$collection_a_manifest" \
        "RUNNER_COLLECTION_B_MANIFEST=$collection_b_manifest" \
        "RUNNER_DEPENDENCY_COLLECTIONS=$runner_dependency_collections" \
        "RUNNER_COLLECTION_A_MANIFEST=$runner_collection_a_manifest" \
        "RUNNER_COLLECTION_A_EXPECTED_TESTS=$runner_collection_a_expected_tests" \
        "RUNNER_COLLECTION_A_LOGS=$runner_collection_a_logs" \
        "RUNNER_COLLECTION_B_MANIFEST=$runner_collection_b_manifest" \
        "RUNNER_COLLECTION_B_EXPECTED_TESTS=$runner_collection_b_expected_tests" \
        "RUNNER_COLLECTION_B_LOGS=$runner_collection_b_logs" \
        "RUNNER_COLLECTION_C_MANIFEST=$runner_collection_c_manifest" \
        "RUNNER_COLLECTION_C_EXPECTED_TESTS=$runner_collection_c_expected_tests" \
        "RUNNER_COLLECTION_C_LOGS=$runner_collection_c_logs" \
        "RUNNER_COLLECTION_E_MANIFEST=$runner_collection_e_manifest" \
        "RUNNER_COLLECTION_E_EXPECTED_TESTS=$runner_collection_e_expected_tests" \
        "RUNNER_COLLECTION_E_LOGS=$runner_collection_e_logs" \
        "RUNNER_COLLECTION_D_MANIFEST=$runner_collection_d_manifest" \
        "RUNNER_COLLECTION_D_EXPECTED_TESTS=$runner_collection_d_expected_tests" \
        "RUNNER_COLLECTION_D_LOGS=$runner_collection_d_logs" \
        "RUNNER_COLLECTION_F_MANIFEST=$runner_collection_f_manifest" \
        "RUNNER_COLLECTION_F_EXPECTED_TESTS=$runner_collection_f_expected_tests" \
        "RUNNER_COLLECTION_F_LOGS=$runner_collection_f_logs" \
        "RUNNER_COLLECTION_G_MANIFEST=$runner_collection_g_manifest" \
        "RUNNER_COLLECTION_G_EXPECTED_TESTS=$runner_collection_g_expected_tests" \
        "RUNNER_COLLECTION_G_LOGS=$runner_collection_g_logs" \
        "RUNNER_TC18_ARTIFACT_FILE=$tc18_artifact_file" \
        "RUNNER_TC19_ARTIFACTS_DIR=$tc19_artifacts_dir" \
        "RUNNER_TC20_ARTIFACTS_DIR=$tc20_artifacts_dir" \
        "RUNNER_TC18_RECORD=$tc18_record" \
        "RUNNER_TC19_RECORD=$tc19_record" \
        "RUNNER_TC20_RECORD=$tc20_record" \
        "runner_dependency_collections=$runner_dependency_collections" \
        "runner_collection_a_manifest=$runner_collection_a_manifest" \
        "runner_collection_a_expected_tests=$runner_collection_a_expected_tests" \
        "runner_collection_a_logs=$runner_collection_a_logs" \
        "runner_collection_b_manifest=$runner_collection_b_manifest" \
        "runner_collection_b_expected_tests=$runner_collection_b_expected_tests" \
        "runner_collection_b_logs=$runner_collection_b_logs" \
        "runner_collection_c_manifest=$runner_collection_c_manifest" \
        "runner_collection_c_expected_tests=$runner_collection_c_expected_tests" \
        "runner_collection_c_logs=$runner_collection_c_logs" \
        "runner_collection_e_manifest=$runner_collection_e_manifest" \
        "runner_collection_e_expected_tests=$runner_collection_e_expected_tests" \
        "runner_collection_e_logs=$runner_collection_e_logs" \
        "runner_collection_d_manifest=$runner_collection_d_manifest" \
        "runner_collection_d_expected_tests=$runner_collection_d_expected_tests" \
        "runner_collection_d_logs=$runner_collection_d_logs" \
        "runner_collection_f_manifest=$runner_collection_f_manifest" \
        "runner_collection_f_expected_tests=$runner_collection_f_expected_tests" \
        "runner_collection_f_logs=$runner_collection_f_logs" \
        "runner_collection_g_manifest=$runner_collection_g_manifest" \
        "runner_collection_g_expected_tests=$runner_collection_g_expected_tests" \
        "runner_collection_g_logs=$runner_collection_g_logs"
    )
    if [ -n "$phase_results_repo_root" ]; then
        runner_env_args+=("CLD6001_RESULTS_ROOT=$phase_results_repo_root")
    fi
    set +e
    run_runtime_command \
        "$runtime" \
        "${runner_env_args[@]}" \
        -- \
        timeout --signal=TERM --kill-after=5 "${TIMEOUT_SECONDS}s" bash "$test_script" < /dev/null > "$test_output_file" 2>&1
    local exit_code=$?
    if [ $exit_code -eq 124 ]; then
        warn "TIMEOUT: $test_id exceeded ${TIMEOUT_SECONDS}s limit"
    fi
    set -e

    capture_state "post" "$test_id" "$runtime"
    normalized_result="$(normalize_test_exit_result "$exit_code")"
    TEST_EXIT_CODES["$result_store_key"]="$exit_code"
    TEST_RESULT_DIRS["$result_store_key"]="$results_dir"
    TEST_RESULT_VARIANTS["$result_store_key"]="$variant_identity"
    TEST_RESULT_IMAGES["$result_store_key"]="$target_image"
    TEST_RESULT_BASE_OS["$result_store_key"]="$target_base_os"
    TEST_RESULT_FLAVORS["$result_store_key"]="$target_flavor"
    append_result_store_key "$base_result_key" "$result_store_key"
    if [ "$canonical_test_id" != "$test_id" ]; then
        append_result_store_key "${runtime}:${canonical_test_id}" "$result_store_key"
    fi
    write_execution_context "$results_dir" "$collection" "$test_id" "$runtime" "$timestamp" "$exit_code" "$normalized_result" "$artifacts_dir" "$target_image" "$target_base_os" "$target_flavor"

    if [ "$exit_code" -eq 0 ]; then
        ok "Test case $test_id completed successfully"
    else
        warn "Test case $test_id completed with exit code: $exit_code"
    fi

    return "$exit_code"
}

write_collection_results() {
    local collection="$1"
    local runtime="$2"
    local tests="${3:-}"
    local runtime_name=""
    local runtime_mode_name=""
    local collection_dir="$RESULTS_ROOT/collection-$collection"
    local collection_json="$collection_dir/$(collection_results_filename "$collection")"
    local test

    runtime_name="$(runtime_engine "$runtime" 2>/dev/null || true)"
    runtime_mode_name="$(runtime_mode "$runtime" 2>/dev/null || true)"

    mkdir -p "$collection_dir"
    jq -n \
        --arg collection "$collection" \
        --arg kind "testcase" \
        --arg profile "${profile:-}" \
        --arg profile_slug "${profile_slug:-}" \
        --arg environment_state "$environment_state" \
        --arg host_profile "$host_profile" \
        --arg runtime_profile "$runtime_profile" \
        --arg timestamp "$(date -Iseconds)" \
        --arg hostname "$(hostname)" \
        --arg runtime "$runtime" \
        --arg runtime_engine "$runtime_name" \
        --arg runtime_mode "$runtime_mode_name" \
        '{
            collection: $collection,
            kind: $kind,
            profile: $profile,
            profile_slug: $profile_slug,
            environment_state: $environment_state,
            host_profile: $host_profile,
            runtime_profile: $runtime_profile,
            timestamp: $timestamp,
            environment: {
                hostname: $hostname,
                runtime: $runtime,
                runtime_engine: $runtime_engine,
                runtime_mode: $runtime_mode
            }
        }' \
        > "${collection_json}.tmp"

    if [ -f "$collection_json" ]; then
        jq -s '.[0] * .[1]' "${collection_json}.tmp" "$collection_json" > "${collection_json}.merged" && \
            mv "${collection_json}.merged" "${collection_json}.tmp"
    else
        INITIALIZED_COLLECTION_RESULTS["$collection"]=1
    fi

    [ -n "$tests" ] || tests="$(cld6001_testcases_for_collection "$collection" "$environment_state" 2>/dev/null || true)"
    for test in $tests; do
        local key=""

        jq \
            --arg runtime "$runtime" \
            --arg test_id "$test" \
            '.[$runtime] //= {} |
             .[$runtime].test_cases //= {} |
             .[$runtime].test_cases[$test_id] = {status: "completed"}' \
            "${collection_json}.tmp" > "${collection_json}.reset"
        mv "${collection_json}.reset" "${collection_json}.tmp"

        while IFS= read -r key; do
            local exit_code="${TEST_EXIT_CODES[$key]}"
            local result_dir="${TEST_RESULT_DIRS[$key]}"
            local variant_identity="${TEST_RESULT_VARIANTS[$key]:-}"
            local variant_image="${TEST_RESULT_IMAGES[$key]:-}"
            local variant_base_os="${TEST_RESULT_BASE_OS[$key]:-}"
            local variant_flavor="${TEST_RESULT_FLAVORS[$key]:-}"
            local normalized_result=""
            local context_path=""
            local reason_code=""
            local reason_text=""
            local reason_source=""
            normalized_result="$(normalize_test_exit_result "${exit_code:-1}")"
            context_path="$result_dir/execution-context.json"

            if [ -f "$context_path" ]; then
                reason_code="$(jq -r '.reason_code // empty' "$context_path")"
                reason_text="$(jq -r '.reason_text // empty' "$context_path")"
                reason_source="$(jq -r '.reason_source // empty' "$context_path")"
            fi

            jq \
                --arg runtime "$runtime" \
                --arg test_id "$test" \
                --arg result "$normalized_result" \
                --arg result_dir "$result_dir" \
                --arg variant "$variant_identity" \
                --arg image "$variant_image" \
                --arg base_os "$variant_base_os" \
                --arg flavor "$variant_flavor" \
                --arg reason_code "$reason_code" \
                --arg reason_text "$reason_text" \
                --arg reason_source "$reason_source" \
                --argjson exit_code "${exit_code:-1}" \
                '.[$runtime] //= {} |
                 def variant_rank($result):
                    if $result == "fail" then 0
                    elif $result == "block" then 1
                    elif $result == "pass" then 2
                    else 3
                    end;
                 def synthesized_variant_record:
                    (.variants // {}
                    | to_entries
                    | map(.value + {variant_key: .key})) as $variants
                    | if ($variants | length) == 0 then null
                     else ($variants | sort_by(variant_rank(.result), (.variant_key // "")) | .[0])
                     end;
                 .[$runtime].test_cases //= {} |
                 .[$runtime].test_cases[$test_id] //= {status: "completed"} |
                 .[$runtime].test_cases[$test_id] += {
                    status: "completed",
                    result: $result,
                    exit_code: $exit_code,
                    result_dir: $result_dir,
                    image: $image,
                    base_os: $base_os,
                    flavor: $flavor
                 } |
                 if ($reason_code | length) > 0 then
                    .[$runtime].test_cases[$test_id].reason_code = $reason_code
                 else
                    .
                 end |
                 if ($reason_text | length) > 0 then
                    .[$runtime].test_cases[$test_id].reason_text = $reason_text
                 else
                    .
                 end |
                 if ($reason_source | length) > 0 then
                    .[$runtime].test_cases[$test_id].reason_source = $reason_source
                 else
                    .
                 end |
                 if ($variant | length) > 0 then
                    .[$runtime].test_cases[$test_id].variants //= {} |
                    .[$runtime].test_cases[$test_id].variants[$variant] = {
                        status: "completed",
                        result: $result,
                        exit_code: $exit_code,
                        result_dir: $result_dir,
                        image: $image,
                        base_os: $base_os,
                        flavor: $flavor
                    } |
                    if ($reason_code | length) > 0 then
                        .[$runtime].test_cases[$test_id].variants[$variant].reason_code = $reason_code
                    else
                        .
                    end |
                    if ($reason_text | length) > 0 then
                        .[$runtime].test_cases[$test_id].variants[$variant].reason_text = $reason_text
                    else
                        .
                    end |
                    if ($reason_source | length) > 0 then
                        .[$runtime].test_cases[$test_id].variants[$variant].reason_source = $reason_source
                    else
                        .
                    end |
                    .[$runtime].test_cases[$test_id] |=
                        (. as $testcase
                         | (synthesized_variant_record) as $representative
                         | if $representative == null then
                               $testcase
                           else
                               $testcase
                               | .result = $representative.result
                               | .exit_code = ($representative.exit_code // 1)
                               | .result_dir = ($representative.result_dir // "")
                               | .image = ($representative.image // "")
                               | .base_os = ($representative.base_os // "")
                               | .flavor = ($representative.flavor // "")
                               | if (($representative.reason_code // "") | length) > 0 then
                                     .reason_code = $representative.reason_code
                                 else
                                     del(.reason_code)
                                 end
                               | if (($representative.reason_text // "") | length) > 0 then
                                     .reason_text = $representative.reason_text
                                 else
                                     del(.reason_text)
                                 end
                               | if (($representative.reason_source // "") | length) > 0 then
                                     .reason_source = $representative.reason_source
                                 else
                                     del(.reason_source)
                                 end
                           end)
                 else
                     .
                 end' \
                "${collection_json}.tmp" > "${collection_json}.next"
            mv "${collection_json}.next" "${collection_json}.tmp"
        done < <(result_store_keys_for_test "$runtime" "$test")
    done

    mv "${collection_json}.tmp" "$collection_json"
}

write_cleanup_collection_result() {
    local collection="$1"
    local runtime="$2"
    local cleanup_exit_code="$3"
    local collection_dir="$RESULTS_ROOT/collection-$collection"
    local collection_json="$collection_dir/$(collection_results_filename "$collection")"
    local collection_working_json="$collection_json"
    local runtime_name=""
    local runtime_mode_name=""
    local cleanup_status="pass"

    runtime_name="$(runtime_engine "$runtime" 2>/dev/null || true)"
    runtime_mode_name="$(runtime_mode "$runtime" 2>/dev/null || true)"
    [ "$cleanup_exit_code" -eq 0 ] || cleanup_status="fail"

    mkdir -p "$collection_dir"
    if [ ! -f "$collection_json" ]; then
        jq -n \
            --arg collection "$collection" \
            --arg kind "testcase" \
            --arg profile "${profile:-}" \
            --arg profile_slug "${profile_slug:-}" \
            --arg environment_state "$environment_state" \
            --arg host_profile "$host_profile" \
            --arg runtime_profile "$runtime_profile" \
            --arg timestamp "$(date -Iseconds)" \
            --arg hostname "$(hostname)" \
            --arg runtime "$runtime" \
            --arg runtime_engine "$runtime_name" \
            --arg runtime_mode "$runtime_mode_name" \
            '{
                collection: $collection,
                kind: $kind,
                profile: $profile,
                profile_slug: $profile_slug,
                environment_state: $environment_state,
                host_profile: $host_profile,
                runtime_profile: $runtime_profile,
                timestamp: $timestamp,
                environment: {
                    hostname: $hostname,
                    runtime: $runtime,
                    runtime_engine: $runtime_engine,
                    runtime_mode: $runtime_mode
                }
            }' > "${collection_json}.tmp"
        collection_working_json="${collection_json}.tmp"
    fi

    jq \
        --arg runtime "$runtime" \
        --arg status "$cleanup_status" \
        --argjson exit_code "$cleanup_exit_code" \
        '.[$runtime] //= {} |
         .[$runtime].checks //= {} |
         .[$runtime].checks["cleanup:runtime_boundary"] = {
             status: $status,
             exit_code: $exit_code
         }' \
        "$collection_working_json" > "${collection_json}.next"
    mv "${collection_json}.next" "${collection_json}.tmp"
    mv "${collection_json}.tmp" "$collection_json"
}

append_preflight_check() {
    local collection_json="$1"
    local runtime="$2"
    local check_id="$3"
    local status="$4"
    local description="$5"
    local details="${6:-}"

    jq \
        --arg runtime "$runtime" \
        --arg check_id "$check_id" \
        --arg status "$status" \
        --arg desc "$description" \
        --arg details "$details" \
        '.[$runtime] //= {} |
         .[$runtime].checks //= {} |
         .[$runtime].checks[$check_id] = {
            status: $status,
            description: $desc,
            details: $details
         }' "$collection_json" > "${collection_json}.tmp"
    mv "${collection_json}.tmp" "$collection_json"
}

persist_preflight_disk_headroom_results() {
    local runtime="$1"
    local results_disk_headroom_status="$2"
    local results_disk_headroom_details="$3"
    local temp_work_disk_headroom_status="$4"
    local temp_work_disk_headroom_details="$5"
    local preflight_dir="$RESULTS_ROOT/collection-preflight"
    local preflight_json="$preflight_dir/collection-preflight-results.json"

    write_collection_results "preflight" "$runtime"

    append_preflight_check \
        "$preflight_json" \
        "$runtime" \
        "$RESULTS_ROOT_DISK_HEADROOM_CHECK_ID" \
        "$results_disk_headroom_status" \
        "Live disk headroom for results filesystem" \
        "$results_disk_headroom_details"
    append_preflight_check \
        "$preflight_json" \
        "$runtime" \
        "$TEMP_WORK_ROOT_DISK_HEADROOM_CHECK_ID" \
        "$temp_work_disk_headroom_status" \
        "Live disk headroom for temp-work backing filesystem" \
        "$temp_work_disk_headroom_details"
}

can_persist_live_preflight_results() {
    local preflight_dir="$RESULTS_ROOT/collection-preflight"
    local candidate_path="$preflight_dir"
    local parent_path=""

    if [ -e "$RESULTS_ROOT" ] || [ -L "$RESULTS_ROOT" ]; then
        [ -d "$RESULTS_ROOT" ] || return 1
        [ -w "$RESULTS_ROOT" ] || return 1
        [ -x "$RESULTS_ROOT" ] || return 1
    fi

    while [ ! -e "$candidate_path" ] && [ ! -L "$candidate_path" ]; do
        parent_path="$(dirname -- "$candidate_path")"
        [ "$parent_path" != "$candidate_path" ] || return 1
        candidate_path="$parent_path"
    done

    [ -d "$candidate_path" ] || return 1
    [ -w "$candidate_path" ] || return 1
    [ -x "$candidate_path" ] || return 1
}

persist_live_preflight_results() {
    local results_disk_headroom_status="$1"
    local results_disk_headroom_details="$2"
    local temp_work_disk_headroom_status="$3"
    local temp_work_disk_headroom_details="$4"
    shift 4
    local runtime=""

    for runtime in "$@"; do
        persist_preflight_disk_headroom_results \
            "$runtime" \
            "$results_disk_headroom_status" \
            "$results_disk_headroom_details" \
            "$temp_work_disk_headroom_status" \
            "$temp_work_disk_headroom_details"
    done
}

persist_live_preflight_success_checks() {
    local runtime="$1"
    local temp_work_root="$2"
    local preflight_dir="$RESULTS_ROOT/collection-preflight"
    local preflight_json="$preflight_dir/collection-preflight-results.json"
    local runtime_name=""
    local tool=""
    local version_output=""
    local -a required_tools=("python3" "gcc" "make" "jq" "curl" "timeout" "realpath" "getent")

    runtime_name="$(runtime_engine "$runtime" 2>/dev/null || true)"
    if [ -n "$runtime_name" ]; then
    required_tools=("$runtime_name" "${required_tools[@]}")
    fi

    append_preflight_check \
    "$preflight_json" \
    "$runtime" \
    "$TEMP_WORK_ROOT_CREATION_CHECK_ID" \
    "pass" \
    "Temp-work root directory is creatable" \
    "$temp_work_root"
    append_preflight_check \
    "$preflight_json" \
    "$runtime" \
    "$ENVIRONMENT_STATE_ENFORCEMENT_CHECK_ID" \
    "pass" \
    "Environment-state enforcement completed" \
    "Environment state applied successfully"
    append_preflight_check \
    "$preflight_json" \
    "$runtime" \
    "$PROFILE_RUNTIME_SUPPORT_CHECK_ID" \
    "pass" \
    "Profile/runtime support validation" \
    "Profile $profile supports $runtime"

    for tool in "${required_tools[@]}"; do
    version_output="$("$tool" --version 2>&1 | head -n 1 || true)"
    append_preflight_check \
        "$preflight_json" \
        "$runtime" \
        "tool_availability:${tool}" \
        "pass" \
        "Prerequisite tool availability: ${tool}" \
        "$version_output"
    done

    append_preflight_check \
    "$preflight_json" \
    "$runtime" \
    "runtime_mode_contract" \
    "pass" \
    "Runtime Mode Contract validation" \
    "Runtime conforms to expected execution mode (rootless vs rootful)"
    append_preflight_check \
    "$preflight_json" \
    "$runtime" \
    "registry_connectivity" \
    "pass" \
    "Registry Connectivity validation" \
    "Successfully resolved and reached container registry"
    append_preflight_check \
    "$preflight_json" \
    "$runtime" \
    "results_writable" \
    "pass" \
    "Results destination directory is writable" \
    "$RESULTS_ROOT"
}

append_live_preflight_failure_check() {
    local runtime="$1"
    local check_id="$2"
    local status="$3"
    local description="$4"
    local details="${5:-}"
    local preflight_dir="$RESULTS_ROOT/collection-preflight"
    local preflight_json="$preflight_dir/collection-preflight-results.json"

    [ -n "$check_id" ] || return 0
    append_preflight_check "$preflight_json" "$runtime" "$check_id" "$status" "$description" "$details"
}

persist_live_preflight_failure_checks() {
    local runtime="$1"
    local failure_kind="$2"
    local tool=""
    local failure_check_id=""
    local failure_description=""
    local failure_details=""

    case "$failure_kind" in
        environment_state)
            append_live_preflight_failure_check \
                "$runtime" \
                "$ENVIRONMENT_STATE_ENFORCEMENT_CHECK_ID" \
                "fail" \
                "Environment-state enforcement completed" \
                "Environment state application failed for ${environment_state}/${runtime}/preflight"
            ;;
        profile_runtime_support)
            append_live_preflight_failure_check \
                "$runtime" \
                "$PROFILE_RUNTIME_SUPPORT_CHECK_ID" \
                "fail" \
                "Profile/runtime support validation" \
                "${LAST_PROFILE_RUNTIME_SUPPORT_DETAILS:-Profile $profile does not support $runtime}"
            ;;
        prerequisites)
            while IFS= read -r tool; do
                [ -n "$tool" ] || continue
                append_live_preflight_failure_check \
                    "$runtime" \
                    "tool_availability:${tool}" \
                    "fail" \
                    "Prerequisite tool availability: ${tool}" \
                    "Missing tool: ${tool}"
            done <<< "$LAST_PREREQUISITE_FAILURES"
            ;;
        runtime_functionality)
            failure_check_id="${LAST_RUNTIME_FUNCTIONALITY_FAILURE_CHECK_ID:-$RUNTIME_FUNCTIONALITY_CHECK_ID}"
            failure_description="Runtime functionality validation"
            if [ "$failure_check_id" = "runtime_mode_contract" ]; then
                failure_description="Runtime Mode Contract validation"
            fi
            append_live_preflight_failure_check \
                "$runtime" \
                "$failure_check_id" \
                "fail" \
                "$failure_description" \
                "${LAST_RUNTIME_FUNCTIONALITY_FAILURE_DETAILS:-Runtime preflight failed for $runtime}"
            ;;
        connectivity)
            append_live_preflight_failure_check \
                "$runtime" \
                "registry_connectivity" \
                "fail" \
                "Registry Connectivity validation" \
                "${LAST_RUNTIME_CONNECTIVITY_DETAILS:-Failed to complete registry connectivity check}"
            ;;
        temp_work_root_creation)
            append_live_preflight_failure_check \
                "$runtime" \
                "$TEMP_WORK_ROOT_CREATION_CHECK_ID" \
                "fail" \
                "Temp-work root directory is creatable" \
                "${LAST_TEMP_WORK_ROOT_CREATION_DETAILS:-Failed to create temp-work root}"
            ;;
    esac
}

execute_preflight_checks() {
    local collection="$1"
    local runtime="$2"
    local preflight_dir="$RESULTS_ROOT/collection-preflight"
    local preflight_json="$preflight_dir/collection-preflight-results.json"
    local disk_headroom_failures=0
    local temp_work_root=""
    local results_disk_headroom_status=""
    local results_disk_headroom_details=""
    local temp_work_disk_headroom_status=""
    local temp_work_disk_headroom_details=""

    temp_work_root="$(resolve_temp_work_root)" || return 1

    run_disk_headroom_check \
        "$RESULTS_ROOT_DISK_HEADROOM_CHECK_ID" \
        "Live disk headroom for results filesystem" \
        "$RESULTS_ROOT" || ((disk_headroom_failures+=1))
    results_disk_headroom_status="$LAST_DISK_HEADROOM_STATUS"
    results_disk_headroom_details="$LAST_DISK_HEADROOM_DETAILS"

    run_disk_headroom_check \
        "$TEMP_WORK_ROOT_DISK_HEADROOM_CHECK_ID" \
        "Live disk headroom for temp-work backing filesystem" \
        "$temp_work_root" || ((disk_headroom_failures+=1))
    temp_work_disk_headroom_status="$LAST_DISK_HEADROOM_STATUS"
    temp_work_disk_headroom_details="$LAST_DISK_HEADROOM_DETAILS"

    persist_preflight_disk_headroom_results \
        "$runtime" \
        "$results_disk_headroom_status" \
        "$results_disk_headroom_details" \
        "$temp_work_disk_headroom_status" \
        "$temp_work_disk_headroom_details"

    [ "$disk_headroom_failures" -eq 0 ] || return 1

    local environment_state_status="pass"
    local environment_state_details="Environment state applied successfully"
    if environment_state_enforcement_enabled; then
        if ! enforce_environment_state_for_runtime "$runtime" "preflight"; then
            environment_state_status="fail"
            environment_state_details="Environment state application failed for ${environment_state}/${runtime}/preflight"
        fi
    else
        environment_state_details="Environment state application skipped"
    fi
    append_preflight_check \
        "$preflight_json" \
        "$runtime" \
        "$ENVIRONMENT_STATE_ENFORCEMENT_CHECK_ID" \
        "$environment_state_status" \
        "Environment-state enforcement completed" \
        "$environment_state_details"
    [ "$environment_state_status" = "pass" ] || return 1

    local runtime_name=""
    runtime_name="$(runtime_engine "$runtime" 2>/dev/null || true)"

    local required_tools=("python3" "gcc" "make" "jq" "curl" "timeout" "realpath" "getent")
    if [ -n "$runtime_name" ]; then
        required_tools=("$runtime_name" "${required_tools[@]}")
    fi

    for tool in "${required_tools[@]}"; do
        local tool_status="fail"
        local version_output=""
        if command -v "$tool" >/dev/null 2>&1; then
            tool_status="pass"
            version_output="$("$tool" --version 2>&1 | head -n 1)"
        fi
        append_preflight_check "$preflight_json" "$runtime" "tool_availability:${tool}" "$tool_status" "Prerequisite tool availability: ${tool}" "$version_output"
    done

    local contract_status="fail"
    local contract_details=""
    if verify_runtime_mode_contract "$runtime" "$runtime_name" 2>/dev/null; then
        contract_status="pass"
        contract_details="Runtime conforms to expected execution mode (rootless vs rootful)"
    else
        contract_details="Runtime does NOT conform to expected execution mode"
    fi
    append_preflight_check "$preflight_json" "$runtime" "runtime_mode_contract" "$contract_status" "Runtime Mode Contract validation" "$contract_details"

    local connectivity_status="fail"
    local connectivity_details=""
    if check_runtime_connectivity "$runtime" >/dev/null 2>&1; then
        connectivity_status="pass"
        connectivity_details="Successfully resolved and reached container registry"
    else
        connectivity_details="Failed to complete registry connectivity check"
    fi
    append_preflight_check "$preflight_json" "$runtime" "registry_connectivity" "$connectivity_status" "Registry Connectivity validation" "$connectivity_details"

    local writable_status="fail"
    if [ -w "$RESULTS_ROOT" ]; then
        writable_status="pass"
    fi
    append_preflight_check "$preflight_json" "$runtime" "results_writable" "$writable_status" "Results destination directory is writable" "$RESULTS_ROOT"

    mkdir -p "$temp_work_root"

    [ "$disk_headroom_failures" -eq 0 ]
}

execute_testcase_collection() {
    local collection="$1"
    local runtime="$2"
    local target_image="${3:-}"
    local target_base_os="${4:-}"
    local target_flavor="${5:-}"
    local all_images="${6:-false}"
    local tests="${7:-}"
    local failed_tests=0
    local test

    [ -n "$tests" ] || tests="$(cld6001_testcases_for_collection "$collection" "$environment_state" 2>/dev/null || true)"
    [ -n "$tests" ] || {
        error "Collection $collection resolved no testcase rows for $environment_state; refusing to emit an empty testcase artifact"
        return 1
    }

    section "Executing Collection $collection Tests ($runtime) - Image: ${target_image:-default} - OS: ${target_base_os:-default} - Flavor: ${target_flavor:-default}"

    run_collection_boundary_cleanup "$collection" "$runtime" "before" || return 1

    if collection_runs_full_image_matrix "$collection" "$all_images"; then
        for image in "${IMAGE_NAMES[@]}"; do
            for base_os in "${BASE_OS_VARIANTS[@]}"; do
                for flavor in "${DHI_FLAVORS[@]}"; do
                    for test in $tests; do
                        local test_status=0
                        local cleanup_status=0
                        execute_test "$collection" "$test" "$runtime" "$image" "$base_os" "$flavor" || test_status=$?
                        run_post_case_cleanup "$collection" "$runtime" "$test" || cleanup_status=$?
                        if [ $test_status -ne 0 ] && [ $test_status -ne $BLOCK_EXIT_CODE ]; then
                            ((failed_tests+=1))
                            warn "Test $test failed for ${image}:${base_os}:${flavor} - continuing with next test"
                        fi
                        if [ $cleanup_status -ne 0 ]; then
                            ((failed_tests+=1))
                            warn "Cleanup after $test failed for ${image}:${base_os}:${flavor} - continuing with next test"
                        fi
                    done
                done
            done
        done
    else
        for test in $tests; do
            local test_status=0
            local cleanup_status=0
            execute_test "$collection" "$test" "$runtime" "$target_image" "$target_base_os" "$target_flavor" || test_status=$?
            run_post_case_cleanup "$collection" "$runtime" "$test" || cleanup_status=$?
            if [ $test_status -ne 0 ] && [ $test_status -ne $BLOCK_EXIT_CODE ]; then
                ((failed_tests+=1))
                warn "Test $test failed - continuing with next test"
            fi
            if [ $cleanup_status -ne 0 ]; then
                ((failed_tests+=1))
                warn "Cleanup after $test failed - continuing with next test"
            fi
        done
    fi

    run_collection_boundary_cleanup "$collection" "$runtime" "after" || ((failed_tests+=1))
    write_collection_results "$collection" "$runtime" "$tests" || return 1
    [ "$failed_tests" -eq 0 ]
}

collection_runs_full_image_matrix() {
    local collection="$1"
    local all_images="${2:-false}"

    [ "$collection" = "b" ] && return 0
    [ "$all_images" = "true" ]
}

execute_cleanup_collection() {
    local collection="$1"
    local runtime="$2"
    local cleanup_status=0

    section "Executing Collection $collection Cleanup ($runtime)"
    run_collection_boundary_cleanup "$collection" "$runtime" "during" || cleanup_status=$?
    write_cleanup_collection_result "$collection" "$runtime" "$cleanup_status"
    return "$cleanup_status"
}

enforce_environment_state_for_runtime() {
    local runtime="$1"
    local evidence_scope="$2"
    local state_results_dir="$RESULTS_ROOT/environment-states/$environment_state/$runtime/$evidence_scope"
    local state_tool="$REPO_ROOT/src/setup/apply-state.sh"

    environment_state_enforcement_enabled || {
        warn "Environment-state application skipped for $environment_state/$runtime/$evidence_scope"
        return 0
    }

    mkdir -p "$state_results_dir"
    info "Enforcing environment state $environment_state for $runtime ($evidence_scope)..."
    bash "$state_tool" apply \
        --state "$environment_state" \
        --runtime "$runtime" \
        --results-dir "$state_results_dir"
}

enforce_environment_state_for_collection() {
    local collection="$1"
    local runtime="$2"
    enforce_environment_state_for_runtime "$runtime" "collection-$collection"
}

stage_runtime_images_for_collection() {
    local collection="$1"
    local runtime="$2"
    local stage_key="${environment_state}:${profile_slug}:${runtime}"

    [ "$RUNNER_STAGE_RUNTIME_IMAGES" = "true" ] || return 0

    case "$collection" in
        a|b|c|d|e|f|g|h)
            ;;
        *)
            return 0
            ;;
    esac

    [ "${STAGED_RUNTIME_IMAGES[$stage_key]:-false}" = "true" ] && return 0

    info "Staging runtime images for $runtime before collection $collection..."
    run_runtime_command \
        "$runtime" \
        "CLD6001_PULL_IMAGES_STRICT=true" \
        "CONTAINER_RUNTIME=$(runtime_engine "$runtime")" \
        -- \
        bash "$REPO_ROOT/src/setup/pull-images.sh" --primary --dhi || return 1

    STAGED_RUNTIME_IMAGES["$stage_key"]="true"
}

execute_collection() {
    local collection="$1"
    local runtime="$2"
    local target_image="${3:-}"
    local target_base_os="${4:-}"
    local target_flavor="${5:-}"
    local all_images="${6:-false}"
    local requested_tests="${7:-}"

    enforce_environment_state_for_collection "$collection" "$runtime" || return 1
    stage_runtime_images_for_collection "$collection" "$runtime" || return 1
    execute_testcase_collection "$collection" "$runtime" "$target_image" "$target_base_os" "$target_flavor" "$all_images" "$requested_tests"
}

execute_requested_collection() {
    local collection="$1"
    local runtime_selection="$2"
    local target_image="${3:-}"
    local target_base_os="${4:-}"
    local target_flavor="${5:-}"
    local all_images="${6:-false}"
    local -a runtimes=()
    local failed_runtimes=0
    local runtime

    mapfile -t runtimes < <(resolve_requested_runtimes "$runtime_selection")
    for runtime in "${runtimes[@]}"; do
        case "$collection" in
            preflight)
                ;;
            cleanup)
                execute_cleanup_collection "$collection" "$runtime" || ((failed_runtimes+=1))
                ;;
            *)
                execute_collection "$collection" "$runtime" "$target_image" "$target_base_os" "$target_flavor" "$all_images" || ((failed_runtimes+=1))
                ;;
        esac
    done

    [ "$failed_runtimes" -eq 0 ]
}

execute_requested_testcase() {
    local testcase="$1"
    local testcase_collection="$2"
    local runtime_selection="$3"
    local target_image="${4:-}"
    local target_base_os="${5:-}"
    local target_flavor="${6:-}"
    local all_images="${7:-false}"
    local -a runtimes=()
    local failed_runtimes=0
    local runtime

    mapfile -t runtimes < <(resolve_targeted_runtimes "$testcase_collection" "$runtime_selection")
    [ "${#runtimes[@]}" -gt 0 ] || {
        error "Testcase $testcase in collection $testcase_collection has no supported runtimes for selection: $runtime_selection"
        return 1
    }

    for runtime in "${runtimes[@]}"; do
        if ! execute_collection "$testcase_collection" "$runtime" "$target_image" "$target_base_os" "$target_flavor" "$all_images" "$testcase"; then
            ((failed_runtimes+=1))
        fi
    done

    [ "$failed_runtimes" -eq 0 ]
}

generate_reports() {
    section "Generating Reports"
    local reports_dir="$LIVERUN_DIR/reports"
    mkdir -p "$reports_dir"

    export CLD6001_RUN_ID="$RUN_SESSION_ID"
    export CLD6001_RUN_ROOT="$LIVERUN_DIR"

    run_auxiliary_command "Report generator" \
        python3 "$REPO_ROOT/src/analyze/reports/report-generator.py" \
            --input "$RESULTS_ROOT" \
            --output "$reports_dir/security-research-report.md" || return 1
    run_auxiliary_command "Statistical analysis" \
        python3 "$REPO_ROOT/src/analyze/reports/statistical-analysis.py" \
            --input "$RESULTS_ROOT" \
            --output "$reports_dir/statistical-analysis-report.json" || return 1
    run_auxiliary_command "Results matrix generator" \
        python3 "$REPO_ROOT/src/analyze/reports/results-matrix-generator.py" \
            --input "$RESULTS_ROOT" \
            --output "$reports_dir/security-research-results-matrix.json" || return 1
    run_auxiliary_command "Control impact matrix report" \
        python3 "$REPO_ROOT/src/analyze/reports/control-impact-matrix-report.py" \
            --input "$RESULTS_ROOT" \
            --output "$reports_dir/control-impact-matrix.json" || return 1
}

execute_all_tests() {
    local runtime_selection="$1"
    local target_image="${2:-}"
    local target_base_os="${3:-}"
    local target_flavor="${4:-}"
    local all_images="${5:-false}"
    local -a runtimes=()
    local failed_runs=0
    local runtime
    local collection

    header "CLD6001 Container Security Test Suite"
    info "Runtime selection: $runtime_selection"
    info "Image selection: ${target_image:-default}"
    info "Base OS selection: ${target_base_os:-default}"
    info "Flavor selection: ${target_flavor:-default}"
    info "All images: $all_images"
    info "Start time: $(date)"

    mapfile -t runtimes < <(resolve_requested_runtimes "$runtime_selection")
    for runtime in "${runtimes[@]}"; do

        section "Runtime: $runtime"
        for collection in a b c d e f g h; do
            if ! execute_collection "$collection" "$runtime" "$target_image" "$target_base_os" "$target_flavor" "$all_images"; then
                ((failed_runs+=1))
            fi
        done
    done

    info "End time: $(date)"

    if [ "$failed_runs" -eq 0 ]; then
        ok "Test suite execution completed successfully"
        return 0
    fi

    warn "Test suite execution completed with findings"
    return 1
}

execute_environment_state_matrix() {
    local runtime_selection="$1"
    local requested_collection="${2:-}"
    local requested_testcase="${3:-}"
    local requested_testcase_collection="${4:-}"
    local target_image="${5:-}"
    local target_base_os="${6:-}"
    local target_flavor="${7:-}"
    local all_images="${8:-false}"
    local base_results_root="$RESULTS_ROOT"
    local state=""
    local failed_states=0

    for state in $(environment_state_keys); do
        environment_state="$state"
        profile=""
        profile_json=""
        profile_slug=""
        load_runner_profile || return 1

        RESULTS_ROOT="$base_results_root/environment-states/$environment_state/results"
        TEST_RESULTS_ROOT="$RESULTS_ROOT/shared/$RUN_SESSION_ID"

        header "Environment State: $environment_state"
        info "Host profile: $host_profile"
        info "Runtime profile: $runtime_profile"
        info "Shared test results root: $TEST_RESULTS_ROOT"

        if [ -n "$requested_testcase" ]; then
            run_live_preflight "$runtime_selection" "$requested_testcase_collection" || {
                ((failed_states+=1))
                continue
            }
            execute_requested_testcase "$requested_testcase" "$requested_testcase_collection" "$runtime_selection" "$target_image" "$target_base_os" "$target_flavor" "$all_images" || ((failed_states+=1))
        elif [ -n "$requested_collection" ]; then
            run_live_preflight "$runtime_selection" || {
                ((failed_states+=1))
                continue
            }
            execute_requested_collection "$requested_collection" "$runtime_selection" "$target_image" "$target_base_os" "$target_flavor" "$all_images" || ((failed_states+=1))
        else
            run_live_preflight "$runtime_selection" || {
                ((failed_states+=1))
                continue
            }
            execute_all_tests "$runtime_selection" "$target_image" "$target_base_os" "$target_flavor" "$all_images" || ((failed_states+=1))
        fi
    done

    RESULTS_ROOT="$base_results_root"
    if [ -z "$requested_testcase" ] && [ -z "$requested_collection" ]; then
        generate_reports || ((failed_states+=1))
    fi
    [ "$failed_states" -eq 0 ]
}

test_collection=""
testcase=""
testcase_collection=""
runtime="docker-rootful"
copyfail_mode="reversible"
copyfail_mode_source="default"
profile=""
profile_json=""
profile_slug=""
environment_state="$DEFAULT_ENVIRONMENT_STATE"
host_profile=""
runtime_profile=""
TEST_RESULTS_ROOT=""
dry_run=false
target_image=""
target_base_os=""
target_flavor=""
all_images=false

while [ $# -gt 0 ]; do
    case "$1" in
        --test-collection)
            [ $# -ge 2 ] || {
                error "Missing value for --test-collection"
                usage
                exit 1
            }
            test_collection="$2"
            shift 2
            ;;
        --testcase)
            [ $# -ge 2 ] || {
                error "Missing value for --testcase"
                usage
                exit 1
            }
            testcase="$2"
            shift 2
            ;;
        --runtime)
            [ $# -ge 2 ] || {
                error "Missing value for --runtime"
                usage
                exit 1
            }
            runtime="$2"
            shift 2
            ;;
        --copyfail-mode)
            [ $# -ge 2 ] || {
                error "Missing value for --copyfail-mode"
                usage
                exit 1
            }
            copyfail_mode="$2"
            copyfail_mode_source="cli"
            shift 2
            ;;
        --profile)
            [ $# -ge 2 ] || {
                error "Missing value for --profile"
                usage
                exit 1
            }
            profile="$2"
            shift 2
            ;;
        --environment-state)
            [ $# -ge 2 ] || {
                error "Missing value for --environment-state"
                usage
                exit 1
            }
            environment_state="$2"
            shift 2
            ;;
        --relaxed-debug)
            RUNNER_RELAXED_DEBUG=true
            shift
            ;;
        --strict-prereqs)
            strict_prereqs=true
            shift
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --image)
            [ $# -ge 2 ] || {
                error "Missing value for --image"
                usage
                exit 1
            }
            target_image="$2"
            shift 2
            ;;
        --base-os)
            [ $# -ge 2 ] || {
                error "Missing value for --base-os"
                usage
                exit 1
            }
            target_base_os="$2"
            shift 2
            ;;
        --flavor)
            [ $# -ge 2 ] || {
                error "Missing value for --flavor"
                usage
                exit 1
            }
            target_flavor="$2"
            shift 2
            ;;
        --all-images)
            all_images=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        a|b|c|d|e|f|g|h)
            test_collection="$1"
            shift
            ;;
        *)
            error "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

validate_test_collection "$test_collection"
validate_testcase "$testcase"
validate_runtime "$runtime"
validate_environment_state "$environment_state"
validate_copyfail_mode "$copyfail_mode"

if [ -n "$test_collection" ]; then
    case "$test_collection" in
        a|b|c|d|e|f|g|h|preflight|cleanup) ;;
        all)
            error "Use server-orchestrator targeted mode without --test-collection to run all collections for an environment state"
            exit 1
            ;;
        *) error "Invalid test collection: $test_collection (valid: a through h, preflight, cleanup)"; exit 1 ;;
    esac
fi

if [ -n "$test_collection" ] && [ -n "$testcase" ]; then
    error "--test-collection and --testcase cannot be combined"
    exit 1
fi

if [ -n "$testcase" ]; then
    testcase="$(cld6001_testcase_slug "$testcase")" || {
        error "Unknown testcase: $testcase"
        exit 1
    }
    testcase_collection="$(cld6001_collection_for_testcase "$testcase")" || {
        error "Testcase $testcase not found in any collection"
        exit 1
    }
    validate_targeted_runtime_selection "$testcase" "$testcase_collection" "$runtime" || exit 1
fi

if [ "$dry_run" = "true" ]; then
    echo "DRY RUN MODE - No tests will be executed"
    if [ -n "$testcase" ]; then
        echo "--- Testcase $testcase (collection $testcase_collection) ---"
    elif [ -n "$test_collection" ]; then
        echo "--- Test collection $test_collection ---"
    else
        echo "--- All collections ---"
    fi
    echo "Runtime: $runtime"
    echo "Copy Fail mode: $copyfail_mode"
    exit 0
fi

initialize_runner_paths

if managed_environment_state_requested; then
    cld6001_require_direct_strict_runner_safe_host || exit "$BLOCK_EXIT_CODE"
fi

strict_prereqs=true
require_live_profile || exit 1
require_profile_loader_tooling || exit 1

if [ "$environment_state" = "all" ] && [ -n "$profile" ]; then
    error "--profile cannot be combined with --environment-state all; each state owns its runtime profile"
    exit 1
fi

if [ "$environment_state" != "all" ]; then
    load_runner_profile
    if [ -n "$testcase" ]; then
        run_live_preflight "$runtime" "$testcase_collection" || {
            persist_requested_collection_status_after_live_preflight_failure "$testcase_collection" "$runtime"
            exit 1
        }
    else
        run_live_preflight "$runtime" || {
            persist_requested_collection_status_after_live_preflight_failure "$test_collection" "$runtime"
            exit 1
        }
    fi

    TEST_RESULTS_ROOT="$RESULTS_ROOT/shared/$RUN_SESSION_ID"
    mkdir -p "$TEST_RESULTS_ROOT"
    info "Environment state: $environment_state"
    info "Host profile: $host_profile"
    info "Runtime profile: $runtime_profile"
    info "Shared test results root: $TEST_RESULTS_ROOT"
fi

main_exit=0
if [ "$environment_state" = "all" ]; then
    execute_environment_state_matrix "$runtime" "$test_collection" "$testcase" "$testcase_collection" "$target_image" "$target_base_os" "$target_flavor" "$all_images" || main_exit=1
elif [ -n "$testcase" ]; then
    execute_requested_testcase "$testcase" "$testcase_collection" "$runtime" "$target_image" "$target_base_os" "$target_flavor" "$all_images" || main_exit=1
    collection_status="$(requested_collection_overall_status "$testcase_collection")"
    write_requested_collection_status "$testcase_collection" "$runtime" "$collection_status"
    [ "$collection_status" = "pass" ] || main_exit=1
elif [ -n "$test_collection" ]; then
    execute_requested_collection "$test_collection" "$runtime" "$target_image" "$target_base_os" "$target_flavor" "$all_images" || main_exit=1
    collection_status="$(requested_collection_overall_status "$test_collection")"
    write_requested_collection_status "$test_collection" "$runtime" "$collection_status"
    [ "$collection_status" = "pass" ] || main_exit=1
else
    execute_all_tests "$runtime" "$target_image" "$target_base_os" "$target_flavor" "$all_images" || main_exit=1
    generate_reports || main_exit=1
fi

exit "$main_exit"
