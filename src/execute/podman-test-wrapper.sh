#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ESCAPE_TESTS_DIR="${SCRIPT_DIR}/escape-tests"
PODMAN_STAGE_DIR="${PODMAN_STAGE_DIR:-/tmp}"
TEST_CASES_ROOT="${SCRIPT_DIR}/../test-cases"
source "${SCRIPT_DIR}/collections/registry.sh"

resolve_podman_test_scripts() {
    local package_dir=""
    local package_name=""
    local testcase_id=""
    local testcase_name=""
    local testcase_slug=""
    local adapter_flavor=""

    for package_dir in "$TEST_CASES_ROOT"/tc*-*; do
        [ -d "$package_dir" ] || continue
        package_name="$(basename -- "$package_dir")"
        testcase_id="${package_name%%-*}"
        testcase_name="$(cld6001_testcase_slug "$testcase_id" 2>/dev/null || printf '%s\n' "$package_name")"
        testcase_slug="${testcase_name#${testcase_id}-}"

        if [ -f "$package_dir/adapters/podman-rootless.sh" ]; then
            adapter_flavor="podman-rootless"
        elif [ -f "$package_dir/adapters/misc.sh" ]; then
            adapter_flavor="misc"
        else
            continue
        fi

        printf '%s-%s-%s.sh\n' "$testcase_id" "$adapter_flavor" "$testcase_slug"
    done | LC_ALL=C sort
}

stage_podman_script() {
    local script_name="$1"
    local source_script="${ESCAPE_TESTS_DIR}/${script_name}"
    local staged_script="${PODMAN_STAGE_DIR%/}/${script_name}"

    if [ ! -f "$source_script" ]; then
        printf 'Skipped: %s not found\n' "$script_name"
        return 0
    fi

    mkdir -p -- "$PODMAN_STAGE_DIR"
    cp -- "$source_script" "$staged_script"
    chmod +x "$staged_script"
    printf 'Staged: %s\n' "$script_name"
}

main() {
    local script=""
    local -a test_cases=()

    printf -- '--- Podman Test Suite ---\n'
    printf 'Date: %s\n\n' "$(date -Iseconds)"
    printf 'Staging Podman test scripts...\n'

    mapfile -t test_cases < <(resolve_podman_test_scripts)

    for script in "${test_cases[@]}"; do
        stage_podman_script "$script"
    done

    printf 'Podman test scripts staged\n'
}

main "$@"
