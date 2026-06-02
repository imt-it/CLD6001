#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/../test-runner-common.sh"
source "${SCRIPT_DIR}/../../shared/trivy-helpers.sh"

resolve_image_assessment_runtime() {
    local default_engine="$1"
    cld6001_trivy_resolve_runtime "${RUNNER_RUNTIME_ENGINE:-$default_engine}"
}

block_missing_assessment_image() {
    local test_id="$1"
    local image_ref="$2"
    local reason_text=""

    reason_text="required assessment image is not available locally for TC${test_id}. Image reference: ${image_ref}"
    write_result_reason "block" "assessment_image_missing" "$reason_text" "testcase-artifact"
    printf 'BLOCK: required assessment image is not available locally for TC%s\n' "$test_id"
    printf 'Image reference: %s\n' "$image_ref"
    exit "${BLOCK_EXIT_CODE:-3}"
}

ensure_local_assessment_image() {
    local runtime_engine="$1"
    local image_ref="$2"
    local test_id="$3"

    if "$runtime_engine" image inspect "$image_ref" >/dev/null 2>&1; then
        return 0
    fi

    block_missing_assessment_image "$test_id" "$image_ref"
}

run_trivy_image_scan() {
    local runtime_engine="$1"
    local image_ref="$2"
    local output_file="$3"
    local tmp_root="${HOST_PROBE_TMP_DIR:-${TEST_RESULTS_DIR:-/tmp}}"
    local cache_dir="${tmp_root}/trivy-cache"
    local scan_input=""
    local status=0

    mkdir -p -- "$tmp_root" "$cache_dir" "$(dirname -- "$output_file")"
    scan_input="$(cld6001_trivy_create_scan_archive "$runtime_engine" "$image_ref" "$tmp_root")" || {
        printf 'Failed to export image for Trivy scan: %s\n' "$image_ref" >&2
        return 1
    }

    cld6001_trivy_run_saved_image \
        "$runtime_engine" \
        "$scan_input" \
        "$cache_dir" \
        -- \
        --severity CRITICAL,HIGH --format table \
        | tee "$output_file"
    status=${PIPESTATUS[0]}

    rm -f -- "$scan_input"
    return "$status"
}

image_assessment_entrypoint_missing() {
    local output="$1"
    local entrypoint="$2"

    case "$output" in
        *"exec: \"${entrypoint}\": executable file not found in \$PATH"* \
        |*"executable file \`${entrypoint}\` not found in \$PATH"* \
        |*"executable file '${entrypoint}' not found in \$PATH"* \
        |*"executable file \"${entrypoint}\" not found in \$PATH"*)
            return 0
            ;;
    esac

    return 1
}

emit_package_enumeration_unavailable() {
    local detail="$1"

    echo "PACKAGE_ENUMERATION_UNAVAILABLE"
    if [[ -n "$detail" ]]; then
        echo "Reason: $detail"
    fi
}

print_sorted_package_footprint() {
    local package_output="$1"

    if [[ -z "$package_output" ]]; then
        return 0
    fi

    printf '%s\n' "$package_output" | LC_ALL=C sort
}

collect_image_package_footprint_with_runtime() {
    local runtime_engine="$1"
    local image_ref="$2"
    local output_file="$3"
    local package_output=""
    local command_status=0
    local package_query_handled=0

    {
        echo "--- Package manager detection ---"

        if package_output="$("$runtime_engine" run --rm --entrypoint apk "$image_ref" info -v 2>&1)"; then
            print_sorted_package_footprint "$package_output"
            package_query_handled=1
        else
            command_status=$?
            if ! image_assessment_entrypoint_missing "$package_output" "apk"; then
                printf '%s\n' "$package_output" >&2
                return "$command_status"
            fi
        fi

        if [[ "$package_query_handled" -eq 0 ]]; then
            if package_output="$("$runtime_engine" run --rm --entrypoint rpm "$image_ref" -qa 2>&1)"; then
                print_sorted_package_footprint "$package_output"
                package_query_handled=1
            else
                command_status=$?
                if ! image_assessment_entrypoint_missing "$package_output" "rpm"; then
                    printf '%s\n' "$package_output" >&2
                    return "$command_status"
                fi
            fi
        fi

        if [[ "$package_query_handled" -eq 0 ]]; then
            if package_output="$("$runtime_engine" run --rm --entrypoint dpkg-query "$image_ref" -W "-f=\${Package} \${Version}\n" 2>&1)"; then
                print_sorted_package_footprint "$package_output"
                package_query_handled=1
            else
                command_status=$?
                if ! image_assessment_entrypoint_missing "$package_output" "dpkg-query"; then
                    printf '%s\n' "$package_output" >&2
                    return "$command_status"
                fi
            fi
        fi

        if [[ "$package_query_handled" -eq 0 ]]; then
            emit_package_enumeration_unavailable "no supported package manager executable found in image"
        fi
    } | tee "$output_file"
}
