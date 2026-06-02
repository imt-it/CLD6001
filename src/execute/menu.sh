#!/bin/bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$REPO_ROOT/src/shared/logging/live-console.sh"
source "$REPO_ROOT/src/shared/output-layout.sh"
source "$REPO_ROOT/src/execute/collections/registry.sh"
source "$REPO_ROOT/src/profiles/environment-state-registry.sh"

usage() {
    cat <<EOF
Usage: bash src/execute/menu.sh <setup|testing|export|maintenance> [subcommand] [args]

setup:
  preflight
  apply|verify|snapshot ...
  readiness

testing:
  full [server-orchestrator args]
  testcase CASE [LANE] [src/execute/test-runner.sh args]
  partial CASE [src/execute/test-runner.sh args]

export:
  run <full|partial> <run-id> <input-root>
  full <run-id> <input-root>
  partial <run-id> <input-root>

maintenance:
  contracts
  regression
  smoke
  portability
EOF
}

interactive_category_menu() {
    while true; do
        printf '\n'
        PS3="Select CLD6001 mode: "
        select mode in "automatic (full pipeline: setup -> testing -> export)" "custom (pick category and action)" maintenance quit; do
            case "$mode" in
                automatic*)  interactive_automatic_pipeline; break ;;
                custom*)     interactive_custom_menu; break ;;
                maintenance) interactive_maintenance_menu; break ;;
                quit)        return 0 ;;
                *)           printf 'Invalid selection\n' >&2 ;;
            esac
        done
    done
}

interactive_automatic_pipeline() {
    printf '\n-- Automatic Full Pipeline --\n'
    printf 'Launching server-orchestrator (setup -> testing -> reports)...\n\n'
    exec bash "$REPO_ROOT/src/execute/server-orchestrator.sh"
}

interactive_custom_menu() {
    printf '\n-- Custom Mode --\n'
    PS3="Select category: "
    select category in setup testing export back; do
        case "$category" in
            setup)   interactive_setup_custom_menu; break ;;
            testing) interactive_testing_custom_menu; break ;;
            export)  interactive_export_menu; break ;;
            back)    return 0 ;;
            *)       printf 'Invalid selection\n' >&2 ;;
        esac
    done
}

interactive_setup_custom_menu() {
    PS3="Select setup sub-action: "
    select action in preflight "apply baseline-system" "apply cis-system" "verify baseline-system" "verify cis-system" "snapshot baseline-system" "snapshot cis-system" readiness back; do
        case "$action" in
            preflight)
                exec bash "$REPO_ROOT/src/setup/preflight.sh"
                ;;
            "apply baseline-system")
                dispatch_environment_state_command apply baseline-system
                return $?
                ;;
            "apply cis-system")
                dispatch_environment_state_command apply cis-system
                return $?
                ;;
            "verify baseline-system")
                dispatch_environment_state_command verify baseline-system
                return $?
                ;;
            "verify cis-system")
                dispatch_environment_state_command verify cis-system
                return $?
                ;;
            "snapshot baseline-system")
                dispatch_environment_state_command snapshot baseline-system
                return $?
                ;;
            "snapshot cis-system")
                dispatch_environment_state_command snapshot cis-system
                return $?
                ;;
            readiness)
                exec bash "$REPO_ROOT/src/setup/runtime-readiness.sh"
                ;;
            back) return 0 ;;
            *)    printf 'Invalid selection\n' >&2 ;;
        esac
    done
}

interactive_testing_custom_menu() {
    local state="" collection="" testcase=""

    printf '\n-- Custom Testing --\n'
    PS3="Select environment state: "
    select state in baseline-system cis-system back; do
        case "$state" in
            baseline-system|cis-system) break ;;
            back) return 0 ;;
            *) printf 'Invalid selection\n' >&2 ;;
        esac
    done

    PS3="Select collection: "
    select collection in a b c d e f g h "all (run full state)" back; do
        case "$collection" in
            a|b|c|d|e|f|g|h) break ;;
            all*)
                exec bash "$REPO_ROOT/src/execute/server-orchestrator.sh" \
                    --targeted --environment-state "$state"
                ;;
            back) return 0 ;;
            *) printf 'Invalid selection\n' >&2 ;;
        esac
    done

    printf '\nTestcases in collection-%s:\n' "$collection"
    local testcases
    testcases="$(cld6001_testcases_for_collection "$collection" "$state" 2>/dev/null || true)"
    if [ -z "$testcases" ]; then
        testcases="$(cld6001_testcases_for_collection "$collection" 2>/dev/null || true)"
    fi

    if [ -z "$testcases" ]; then
        printf '  (no testcases found)\n'
        return 0
    fi

    local tc_array=()
    while IFS= read -r tc; do
        [ -n "$tc" ] && tc_array+=("$tc")
    done <<< "$testcases"
    tc_array+=("all (run entire collection)" "back")

    PS3="Select testcase: "
    select testcase in "${tc_array[@]}"; do
        case "$testcase" in
            all*)
                exec bash "$REPO_ROOT/src/execute/server-orchestrator.sh" \
                    --targeted --environment-state "$state" --test-collection "$collection"
                ;;
            back) return 0 ;;
            "")   printf 'Invalid selection\n' >&2 ;;
            *)
                exec bash "$REPO_ROOT/src/execute/server-orchestrator.sh" \
                    --targeted --environment-state "$state" --testcase "$testcase"
                ;;
        esac
    done
}

interactive_export_menu() {
    printf '\n-- Export --\n'
    PS3="Select export action: "
    select action in "full run export" "partial run export" back; do
        case "$action" in
            full*)
                printf 'Enter RUN_ID: '
                read -r run_id
                printf 'Enter input root path: '
                read -r input_root
                exec bash "$REPO_ROOT/src/analyze/export-run.sh" full "$run_id" "$input_root"
                ;;
            partial*)
                printf 'Enter RUN_ID: '
                read -r run_id
                printf 'Enter input root path: '
                read -r input_root
                exec bash "$REPO_ROOT/src/analyze/export-run.sh" partial "$run_id" "$input_root"
                ;;
            back) return 0 ;;
            *)    printf 'Invalid selection\n' >&2 ;;
        esac
    done
}

interactive_maintenance_menu() {
    printf '\n-- Maintenance --\n'
    PS3="Select maintenance action: "
    select action in contracts regression smoke portability back; do
        case "$action" in
            contracts)
                exec bash "$REPO_ROOT/src/code-checks/contracts/run.sh"
                ;;
            regression)
                exec bash "$REPO_ROOT/src/code-checks/regression/run.sh"
                ;;
            smoke)
                exec bash "$REPO_ROOT/src/code-checks/smoke/run.sh"
                ;;
            portability)
                exec bash "$REPO_ROOT/src/code-checks/portability/run.sh"
                ;;
            back) return 0 ;;
            *)    printf 'Invalid selection\n' >&2 ;;
        esac
    done
}

dispatch_setup() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        preflight)
            cld6001_console_banner "$(date '+%Y-%m-%dT%H:%M:%S')" "-" "-" "setup: preflight"
            exec bash "$REPO_ROOT/src/setup/preflight.sh" "$@"
            ;;
        apply|verify|snapshot)
            cld6001_console_banner "$(date '+%Y-%m-%dT%H:%M:%S')" "-" "-" "setup: $command environment state"
            dispatch_environment_state_command "$command" "$@"
            ;;
        readiness)
            cld6001_console_banner "$(date '+%Y-%m-%dT%H:%M:%S')" "-" "-" "setup: runtime readiness"
            exec bash "$REPO_ROOT/src/setup/runtime-readiness.sh" "$@"
            ;;
        help|--help|-h|"")
            usage
            ;;
        *)
            printf 'Unknown setup command: %s\n' "$command" >&2
            usage >&2
            return 1
            ;;
    esac
}

menu_environment_state_results_dir() {
    local state="$1"
    local runtime="$2"

    cld6001_temp_work_dir "environment-states/$state/$runtime"
}

resolve_environment_state_runtimes() {
    case "${1:-all}" in
        all)
            printf '%s\n' docker-rootful docker-rootless podman-rootless
            ;;
        docker-rootful|docker-rootless|podman-rootless)
            printf '%s\n' "$1"
            ;;
        *)
            printf 'Unknown runtime selection: %s\n' "${1:-}" >&2
            return 1
            ;;
    esac
}

dispatch_environment_state_command() {
    local command="$1"
    shift || true

    local state=""
    local runtime_selection="all"
    local results_root=""
    local token=""
    local runtime=""
    local runtime_results_dir=""
    local runtime_status=0
    local status=0
    local -a resolved_runtimes=()
    local -a passthrough_args=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --state)
                state="${2:-}"
                [ -n "$state" ] || { printf 'Missing value for --state\n' >&2; return 1; }
                shift 2
                ;;
            --runtime)
                runtime_selection="${2:-}"
                [ -n "$runtime_selection" ] || { printf 'Missing value for --runtime\n' >&2; return 1; }
                shift 2
                ;;
            --results-dir)
                results_root="${2:-}"
                [ -n "$results_root" ] || { printf 'Missing value for --results-dir\n' >&2; return 1; }
                shift 2
                ;;
            --*)
                passthrough_args+=("$1")
                if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
                    passthrough_args+=("$2")
                    shift 2
                else
                    shift
                fi
                ;;
            *)
                token="$1"
                shift
                if [ -z "$state" ]; then
                    state="$token"
                elif [ "$runtime_selection" = "all" ]; then
                    runtime_selection="$token"
                elif [ -z "$results_root" ]; then
                    results_root="$token"
                else
                    passthrough_args+=("$token")
                fi
                ;;
        esac
    done

    [ -n "$state" ] || {
        printf 'Missing environment state for setup %s\n' "$command" >&2
        usage >&2
        return 1
    }

    mapfile -t resolved_runtimes < <(resolve_environment_state_runtimes "$runtime_selection") || return 1
    [ "${#resolved_runtimes[@]}" -gt 0 ] || {
        printf 'No runtimes resolved for selection: %s\n' "$runtime_selection" >&2
        return 1
    }

    for runtime in "${resolved_runtimes[@]}"; do
        runtime_results_dir="$results_root"
        if [ -z "$runtime_results_dir" ]; then
            runtime_results_dir="$(menu_environment_state_results_dir "$state" "$runtime")"
        elif [ "${#resolved_runtimes[@]}" -gt 1 ]; then
            runtime_results_dir="${results_root%/}/$runtime"
        fi

        if bash "$REPO_ROOT/src/setup/apply-environment-state.sh" \
            "$command" \
            --state "$state" \
            --runtime "$runtime" \
            --results-dir "$runtime_results_dir" \
            "${passthrough_args[@]}"; then
            continue
        else
            runtime_status=$?
        fi

        status=$runtime_status
        if [ "$command" = "apply" ]; then
            return "$runtime_status"
        fi
    done

    return "$status"
}

dispatch_testing() {
    local command="${1:-help}"

    case "$command" in
        help|--help|-h|"")
            usage
            ;;
        full|automatic)
            shift || true
            exec bash "$REPO_ROOT/src/execute/server-orchestrator.sh" "$@"
            ;;
        *)
            shift || true
            resolve_and_run_testcase "$command" "$@"
            ;;
    esac
}

resolve_and_run_testcase() {
    local first="${1:-}"
    shift || true

    local testcase=""
    local environment_state="baseline-system"
    local runtime="all"
    local collection=""
    local passthrough_args=()

    if is_runtime_token "$first"; then
        runtime="$first"
        if [ $# -ge 1 ] && is_state_token "$1"; then
            environment_state="$1"; shift
        fi
        if [ $# -ge 1 ] && [ "${1#-}" = "$1" ]; then
            testcase="$1"; shift
        fi
        passthrough_args=("$@")
    elif is_state_token "$first"; then
        environment_state="$first"
        if [ $# -ge 1 ] && [ "${1#-}" = "$1" ]; then
            testcase="$1"; shift
        fi
        passthrough_args=("$@")
    elif [ "${first#-}" = "$first" ]; then
        testcase="$first"
        if [ $# -ge 1 ] && is_state_token "$1"; then
            environment_state="$1"; shift
        fi
        passthrough_args=("$@")
    else
        local args=("$first" "$@")
        local i=0
        while [ $i -lt ${#args[@]} ]; do
            case "${args[$i]}" in
                --testcase)
                    i=$((i+1)); testcase="${args[$i]:-}" ;;
                --environment-state)
                    i=$((i+1)); environment_state="${args[$i]:-}" ;;
                --runtime)
                    i=$((i+1)); runtime="${args[$i]:-}" ;;
                --test-collection)
                    i=$((i+1)); collection="${args[$i]:-}" ;;
                *)
                    passthrough_args+=("${args[$i]}") ;;
            esac
            i=$((i+1))
        done
    fi

    [ -n "$testcase" ] || [ -n "$collection" ] || {
        printf 'Missing testcase or collection identifier\n' >&2
        usage >&2
        return 1
    }

    if [ -n "$testcase" ]; then
        local canonical
        canonical="$(cld6001_testcase_slug "$testcase" 2>/dev/null)" || {
            printf 'Unknown testcase: %s\n' "$testcase" >&2
            return 1
        }
        testcase="$canonical"
    fi

    local orch_args=(--targeted --environment-state "$environment_state" --runtime "$runtime")
    if [ -n "$testcase" ]; then
        orch_args+=(--testcase "$testcase")
    elif [ -n "$collection" ]; then
        orch_args+=(--test-collection "$collection")
    fi

    exec bash "$REPO_ROOT/src/execute/server-orchestrator.sh" "${orch_args[@]}"
}

is_runtime_token() {
    case "${1:-}" in
        docker-rootful|docker-rootless|podman-rootless|all) return 0 ;;
    esac
    return 1
}

is_state_token() {
    case "${1:-}" in
        baseline-system|cis-system|all) return 0 ;;
    esac
    return 1
}

dispatch_export() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        help|--help|-h|"")
            usage
            ;;
        run)
            [ $# -ge 3 ] || {
                usage >&2
                return 1
            }
            cld6001_console_banner "$(date '+%Y-%m-%dT%H:%M:%S')" "-" "-" "export: $1 run"
            exec bash "$REPO_ROOT/src/analyze/export-run.sh" "$@"
            ;;
        full|partial)
            [ $# -ge 2 ] || {
                usage >&2
                return 1
            }
            cld6001_console_banner "$(date '+%Y-%m-%dT%H:%M:%S')" "-" "-" "export: $command run"
            exec bash "$REPO_ROOT/src/analyze/export-run.sh" "$command" "$@"
            ;;
        *)
            printf 'Unknown export command: %s\n' "$command" >&2
            usage >&2
            return 1
            ;;
    esac
}

dispatch_maintenance() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        contracts)
            cld6001_console_banner "$(date '+%Y-%m-%dT%H:%M:%S')" "-" "-" "maintenance: contracts"
            exec bash "$REPO_ROOT/src/code-checks/contracts/run.sh" "$@"
            ;;
        regression)
            cld6001_console_banner "$(date '+%Y-%m-%dT%H:%M:%S')" "-" "-" "maintenance: regression"
            exec bash "$REPO_ROOT/src/code-checks/regression/run.sh" "$@"
            ;;
        smoke)
            cld6001_console_banner "$(date '+%Y-%m-%dT%H:%M:%S')" "-" "-" "maintenance: smoke"
            exec bash "$REPO_ROOT/src/code-checks/smoke/run.sh" "$@"
            ;;
        portability)
            cld6001_console_banner "$(date '+%Y-%m-%dT%H:%M:%S')" "-" "-" "maintenance: portability"
            exec bash "$REPO_ROOT/src/code-checks/portability/run.sh" "$@"
            ;;
        help|--help|-h|"")
            usage
            ;;
        *)
            printf 'Unknown maintenance command: %s\n' "$command" >&2
            usage >&2
            return 1
            ;;
    esac
}

category="${1:-}"

if [ -z "$category" ]; then
    if [ -t 0 ] && [ -t 1 ]; then
        interactive_category_menu
        exit 0
    fi
    usage >&2
    exit 1
fi

shift || true

case "$category" in
    setup)
        dispatch_setup "$@"
        ;;
    testing)
        dispatch_testing "$@"
        ;;
    export)
        dispatch_export "$@"
        ;;
    maintenance)
        dispatch_maintenance "$@"
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        printf 'Unknown category: %s\n' "$category" >&2
        usage >&2
        exit 1
        ;;
esac
