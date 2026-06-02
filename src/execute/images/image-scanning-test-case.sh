#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../test-runner-common.sh"
source "${SCRIPT_DIR}/../image-priorities.sh"

MODE="all"

while [ $# -gt 0 ]; do
    case $1 in
        --primary)
            MODE="primary"
            shift
            ;;
        --all)
            MODE="all"
            shift
            ;;
        *)
            echo "Usage: $0 [--primary|--all]"
            echo ""
            echo "Options:"
            echo "--primary    Scan only primary (latest) images"
            echo "--all        Scan all images (default)"
            exit 1
            ;;
    esac
done

TEST_NAME="Image Scanning Test Case"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_FILE="image-scanning-results-${TIMESTAMP}.txt"
REPORT_DIR="image-scanning-reports"
RAW_REPORT_DIR="${REPORT_DIR}/raw-${TIMESTAMP}"
TOTAL_CRITICAL=0
TOTAL_HIGH=0
TOTAL_MEDIUM=0
TOTAL_LOW=0

scan_image() {
    local image=$1
    local scan_name=$2

    echo "--- Scanning Image: $image ($scan_name) ---"

    mkdir -p "$RAW_REPORT_DIR"
    local output_file="${RAW_REPORT_DIR}/trivy-${scan_name}.json"

    info "Running Trivy scan..."
    if ! trivy image --json --output "$output_file" --format json "$image" > /dev/null 2>&1; then
        warn "Trivy scan failed for $image"
        return 1
    fi

    local critical=0
    local high=0
    local medium=0
    local low=0

    if [ -f "$output_file" ]; then
        critical=$(jq '[.Results[].Vulnerabilities[] | select(.Severity == "CRITICAL")] | length' "$output_file" 2>/dev/null || echo "0")
        high=$(jq '[.Results[].Vulnerabilities[] | select(.Severity == "HIGH")] | length' "$output_file" 2>/dev/null || echo "0")
        medium=$(jq '[.Results[].Vulnerabilities[] | select(.Severity == "MEDIUM")] | length' "$output_file" 2>/dev/null || echo "0")
        low=$(jq '[.Results[].Vulnerabilities[] | select(.Severity == "LOW")] | length' "$output_file" 2>/dev/null || echo "0")
    fi

    echo "Image: $image" >> "${RESULT_FILE}"
    echo "Scan Name: $scan_name" >> "${RESULT_FILE}"
    echo "Critical: $critical" >> "${RESULT_FILE}"
    echo "High: $high" >> "${RESULT_FILE}"
    echo "Medium: $medium" >> "${RESULT_FILE}"
    echo "Low: $low" >> "${RESULT_FILE}"
    echo "---" >> "${RESULT_FILE}"

    echo "Critical: $critical | High: $high | Medium: $medium | Low: $low"
    ((TOTAL_CRITICAL+=critical))
    ((TOTAL_HIGH+=high))
    ((TOTAL_MEDIUM+=medium))
    ((TOTAL_LOW+=low))

    return 0
}

scan_image_group() {
    local group_name=$1
    local category=$2
    shift 2
    local images=( "$@" )

    echo ""
    echo "---"
    echo "Scanning: $group_name"
    echo "Category: $category"
    echo "Images: ${#images[@]}"
    echo "---"

    local failed=0
    for i in "${!images[@]}"; do
        local image="${images[$i]}"
        if ! scan_image "$image" "${category}-$((i+1))"; then
            ((failed++))
        fi
    done

    echo ""
    echo "Result: $(( ${#images[@]} - failed ))/${#images[@]} scanned"
    if [ $failed -gt 0 ]; then
        warn "$failed images failed to scan"
    fi

    return 0
}

generate_report() {
    echo "--- Image Scanning Report ---"

    mkdir -p "$REPORT_DIR"
    echo "--- Image Scanning Summary ---" > "${REPORT_DIR}/summary-${TIMESTAMP}.txt"
    echo "Timestamp: ${TIMESTAMP}" >> "${REPORT_DIR}/summary-${TIMESTAMP}.txt"
    echo "Mode: ${MODE}" >> "${REPORT_DIR}/summary-${TIMESTAMP}.txt"
    echo "" >> "${REPORT_DIR}/summary-${TIMESTAMP}.txt"
    echo "Total Critical: $TOTAL_CRITICAL" >> "${REPORT_DIR}/summary-${TIMESTAMP}.txt"
    echo "Total High: $TOTAL_HIGH" >> "${REPORT_DIR}/summary-${TIMESTAMP}.txt"
    echo "Total Medium: $TOTAL_MEDIUM" >> "${REPORT_DIR}/summary-${TIMESTAMP}.txt"
    echo "Total Low: $TOTAL_LOW" >> "${REPORT_DIR}/summary-${TIMESTAMP}.txt"
}

echo "--- Image Scanning Test Case ---"
echo "Timestamp: ${TIMESTAMP}"
echo "Mode: ${MODE}"
echo "Result file: ${RESULT_FILE}"

echo "--- Image Scanning Test Case ---" > "${RESULT_FILE}"
echo "Timestamp: ${TIMESTAMP}" >> "${RESULT_FILE}"
echo "Test Description: Scan container images for vulnerabilities" >> "${RESULT_FILE}"
echo "Mode: ${MODE}" >> "${RESULT_FILE}"
echo "---" >> "${RESULT_FILE}"

ALL_IMAGES=("${PRIMARY_IMAGES[@]}")

echo ""
echo "Total images to scan: ${#ALL_IMAGES[@]}"
echo ""

scan_image_group "All Images" "test-case" "${ALL_IMAGES[@]}"

generate_report

echo ""
echo "--- Image scanning test complete ---"
echo "Results saved to: ${RESULT_FILE}"
echo "Reports saved to: image-scanning-reports/"
