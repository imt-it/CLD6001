#!/bin/bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
    cat <<USAGE
Usage: bash run.sh [MODE] [args...]

Modes:
  (no args)                          Interactive menu
  --non-interactive [flags]          Full automation (server-orchestrator)
  --setup-only, --test-only, etc.   Automation subset flags
  setup|testing|export|maintenance   Direct category dispatch
  --help, -h                        Show this help

Examples:
  bash run.sh
  bash run.sh --non-interactive
  bash run.sh --non-interactive --run-id 'YYYYMMDD_HHMMSS_<16 lowercase hex chars>'
  bash run.sh testing testcase tc10 baseline-system

Accepted generated run-id format:
  YYYYMMDD_HHMMSS_<16 lowercase hex chars>
USAGE
}

show_help=false
use_noninteractive=false
use_automation_subset=false

args_to_scan=("$@")
index=0
while [ $index -lt ${#args_to_scan[@]} ]; do
    arg="${args_to_scan[$index]}"
    case "$arg" in
        --help|-h)
            show_help=true
            ;;
        --setup-only|--pull-only|--test-only|--clean|--dry-run)
            use_automation_subset=true
            ;;
        --non-interactive)
            use_noninteractive=true
            ;;
        --run-id|--results-root|--runtime|--operability-image|--environment-state|--test-collection|--testcase)
            index=$((index + 1))
            ;;
        setup|testing|export|maintenance)
            break
            ;;
        --*)
            ;;
        *)
            break
            ;;
    esac
    index=$((index + 1))
done

if [ "$show_help" = "true" ]; then
    usage
    exit 0
fi

if [ "$use_automation_subset" = "true" ]; then
    exec bash "$REPO_ROOT/src/execute/automation-pipeline.sh" "$@"
fi

if [ "$use_noninteractive" = "true" ]; then
    filtered_args=()
    for arg in "$@"; do
        [ "$arg" = "--non-interactive" ] && continue
        filtered_args+=("$arg")
    done
    exec bash "$REPO_ROOT/src/execute/server-orchestrator.sh" "${filtered_args[@]}"
fi

exec bash "$REPO_ROOT/src/execute/menu.sh" "$@"
