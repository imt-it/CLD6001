#!/bin/bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$REPO_ROOT/src/shared/output-layout.sh"

cld6001_capture_artifacts() {
    local run_id="$1"
    local source_root="$2"
    local evidence_dir=""
    evidence_dir="$(cld6001_artifact_dir "$run_id")/evidence"

    if [ -e "$evidence_dir" ] && [ ! -d "$evidence_dir" ]; then
        printf 'Refusing to capture artifacts into a non-directory evidence path: %s\n' "$evidence_dir" >&2
        return 1
    fi

    if [ -d "$evidence_dir" ] && find "$evidence_dir" -mindepth 1 -print -quit | grep -q .; then
        printf 'Refusing to capture artifacts into pre-populated evidence directory: %s\n' "$evidence_dir" >&2
        return 1
    fi

    mkdir -p "$evidence_dir"
    cp -a "$source_root/." "$evidence_dir/"
}
