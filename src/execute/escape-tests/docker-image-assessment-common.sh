#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/image-assessment-runtime-common.sh"
source "${SCRIPT_DIR}/../image-registry.sh"

REQUESTED_CASE="${TC57_CASE:-}"
RUNTIME_ENGINE="$(resolve_image_assessment_runtime docker)"
RUNTIME_LABEL="Docker"
TARGET_IMAGE="${RUNNER_TARGET_IMAGE:-nodejs}"
TARGET_BASE_OS="${RUNNER_TARGET_BASE_OS:-alpine}"
TARGET_FLAVOR="${RUNNER_TARGET_FLAVOR:-production}"

if [ "${RUNNER_RUNTIME_MODE:-}" = "rootless" ]; then
    RUNTIME_LABEL="Docker (rootless)"
fi

should_run_case() {
    [ -z "$REQUESTED_CASE" ] || [ "$REQUESTED_CASE" = "$1" ]
}

resolve_standard_image() {
    get_docker_official_image_tag "$TARGET_IMAGE" "$TARGET_BASE_OS"
}

resolve_dhi_image() {
    get_dhi_image_tag "$TARGET_IMAGE" "$TARGET_BASE_OS" "$TARGET_FLAVOR"
}

echo "--- Image-Specific Security Assessment (TC05-TC07) ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: ${RUNTIME_LABEL}"
echo "Workload: ${TARGET_IMAGE}"
echo "Base OS: ${TARGET_BASE_OS}"
echo "DHI Flavor: ${TARGET_FLAVOR}"
echo ""

collect_image_package_footprint() {
    local image="$1"
    local output_file="$2"

    collect_image_package_footprint_with_runtime "${RUNTIME_ENGINE}" "$image" "$output_file"
}

collect_supply_chain_evidence() {
    local image="$1"
    local output_file="$2"

    {
        echo "--- Image inspect ---"
        "${RUNTIME_ENGINE}" image inspect "$image"
        echo
        echo "--- Archive manifest listing ---"
        "${RUNTIME_ENGINE}" save "$image" | tar -tf - | sed -n '1,80p'
    } | tee "$output_file"
}

emit_image_assessment_summary() {
    local test_id="$1"
    local image="$2"
    local vuln_file="${TEST_RESULTS_DIR}/tc${test_id}-vulns.txt"
    local package_file="${TEST_RESULTS_DIR}/tc${test_id}-packages.txt"
    local evidence_file="${TEST_RESULTS_DIR}/tc${test_id}-evidence.txt"

    {
        echo "--- TC${test_id} Image Assessment Summary ---"
        echo "Image: ${image}"
        echo "Vulnerability report: ${vuln_file}"
        echo "Package footprint report: ${package_file}"
        echo "Supply-chain evidence report: ${evidence_file}"
    } | tee "${TEST_RESULTS_DIR}/tc${test_id}-results.txt"
}

run_image_escape_test() {
    local image="$1"
    local test_id="$2"

    ensure_local_assessment_image "$RUNTIME_ENGINE" "$image" "$test_id"
    echo "--- ${test_id}: ${image} Assessment ---"
    echo "Date: $(date -Iseconds)"
    run_trivy_image_scan "$RUNTIME_ENGINE" "$image" "${TEST_RESULTS_DIR}/tc${test_id}-vulns.txt"
    collect_image_package_footprint "$image" "${TEST_RESULTS_DIR}/tc${test_id}-packages.txt"
    collect_supply_chain_evidence "$image" "${TEST_RESULTS_DIR}/tc${test_id}-evidence.txt"
    emit_image_assessment_summary "$test_id" "$image"
}

if should_run_case 05; then
    run_image_escape_test "$(resolve_standard_image)" 05
fi

if should_run_case 06; then
    run_image_escape_test "$(resolve_dhi_image)" 06
fi

if should_run_case 07; then
    echo "TC07 is de-scoped: custom-hardened images are no longer part of the active suite."
    exit "${BLOCK_EXIT_CODE:-3}"
fi

echo "All image assessment cases completed."
