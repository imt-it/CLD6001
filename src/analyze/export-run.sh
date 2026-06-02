#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

run_kind="${1:?run kind required}"
run_id="${2:?run id required}"
input_root="${3:?input root required}"

case "$run_kind" in
    full)
        exec bash "$SCRIPT_DIR/full-export.sh" "$run_id" "$input_root"
        ;;
    partial)
        exec bash "$SCRIPT_DIR/partial-export.sh" "$run_id" "$input_root"
        ;;
    *)
        printf 'Unsupported export kind: %s\n' "$run_kind" >&2
        exit 1
        ;;
esac
