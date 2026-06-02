#!/bin/bash

declare -A CVE_TO_TC
CVE_TO_TC["CVE-2026-31431"]="TC24"

RUNC_LOCATION_IDENTIFIED=false
RUNC_PAGE_CACHE_SHARING_STATUS="not-run"
CONTAINER_ESCAPE_POTENTIAL_STATUS="not-run"
HISTORICAL_FIX_REEXPOSED=false
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/shared/adapter-result-helpers.sh"
source "$REPO_ROOT/src/shared/tc24-runc-helpers.sh"
source "$REPO_ROOT/src/shared/copyfail-mode-helpers.sh"
source "$REPO_ROOT/src/shared/adapter-artifact-helpers.sh"

TC24_RUNTIME_ID="${RUNNER_RUNTIME_ID:-docker-rootful}"
RESULTS_DIR="${RUNNER_PHASE_RESULTS_DIR:?RUNNER_PHASE_RESULTS_DIR is required}"
TC24_ARTIFACTS_DIR="${RUNNER_ARTIFACTS_DIR:-}"

if [ -n "$TC24_ARTIFACTS_DIR" ]; then
  TC24_ARTIFACTS_DIR="$(resolve_results_repo_root "$TC24_ARTIFACTS_DIR")"
fi

TC24_COPYFAIL_REQUESTED_MODE="$(cld6001_copyfail_resolve_mode "${RUNNER_COPYFAIL_MODE:-}")"
TC24_COPYFAIL_EXECUTED_MODE="$(cld6001_copyfail_effective_mode "${RUNNER_COPYFAIL_MODE:-}")"
TC24_COPYFAIL_FALLBACK_REASON="$(cld6001_copyfail_fallback_reason "${RUNNER_COPYFAIL_MODE:-}")"
TC24_COPYFAIL_REQUESTED_PAYLOAD_RELATIVE_PATH="$(cld6001_copyfail_payload_relative_path "$TC24_COPYFAIL_REQUESTED_MODE")"
TC24_COPYFAIL_EXECUTED_PAYLOAD_RELATIVE_PATH="$(cld6001_copyfail_executed_payload_relative_path "${RUNNER_COPYFAIL_MODE:-}")"
{ _cf_payload_path="$(cld6001_copyfail_resolve_payload_path "$TC24_COPYFAIL_EXECUTED_MODE")" && [ -f "$_cf_payload_path" ]; } || { printf 'Copy Fail executed payload not found: %s\n' "${_cf_payload_path:-}" >&2; exit 1; }
unset _cf_payload_path
case "$TC24_RUNTIME_ID" in
    docker-rootful|docker-rootless) TC24_RUNTIME_CMD="docker" ;;
    podman-rootless)                TC24_RUNTIME_CMD="podman" ;;
    *) printf 'Unsupported Copy Fail runtime: %s\n' "$TC24_RUNTIME_ID" >&2; exit 1 ;;
esac

identify_runc_location() {
    echo "Identifying runc binary location..."

    local runc_location
    runc_location="$(command -v runc 2>/dev/null || true)"

    if [ -z "$runc_location" ]; then
        echo "runc not found in PATH"
        return 1
    fi

    echo "runc location on host: $runc_location"

    if [ -f "$runc_location" ]; then
        runc --version 2>/dev/null || echo "Could not determine runc version"
    fi

    return 0
}

analyze_runc_page_cache_sharing() {
    echo "Analyzing runc page cache sharing..."

    local run_id="$(cld6001_unique_timestamp_id "%s" "-")"
    local test_container="tc24-test-${run_id}"
    local probe_status=1
    local runtime_cmd="docker"

    local startup_output=""

    if ! startup_output="$($runtime_cmd run --rm -d --name "$test_container" alpine sh -c '
        echo "Test container running..."
        while true; do sleep 1; done
    ' 2>&1)"; then
        printf 'Failed to start runc probe container: %s\n' "$startup_output" >&2
        return 1
    fi

    sleep 2

    echo "Checking runc accessibility from container..."
    if tc24_probe_runc_accessibility "$runtime_cmd" "$test_container"; then
        probe_status=0
    fi

    "$runtime_cmd" rm -f "$test_container" >/dev/null 2>&1 || true

    return "$probe_status"
}

test_runc_poisoning_potential() {
    echo "Testing runc binary page cache poisoning potential..."

    local stage_dir=""
    local executed_payload_path=""
    local payload_name=""
    local helper_image=""
    local program_output=""

    stage_dir="$(create_host_probe_dir "tc24-copyfail")"
    executed_payload_path="$(cld6001_copyfail_resolve_payload_path "$TC24_COPYFAIL_EXECUTED_MODE")"
    { [ -f "$executed_payload_path" ] && mkdir -p "$stage_dir" && cp "$executed_payload_path" "$stage_dir/$(basename -- "$executed_payload_path")"; } || return 1
    payload_name="$(basename -- "$executed_payload_path")"
    helper_image="$(resolve_helper_image "python-probe" 2>/dev/null || echo "python:3.14-slim")"

    program_output="$($TC24_RUNTIME_CMD run --rm -v "$stage_dir:/probe:rw" "$helper_image" sh -c "
        cd /probe
        printf 'Copy Fail requested mode: %s\n' '$TC24_COPYFAIL_REQUESTED_MODE'
        printf 'Copy Fail executed mode: %s\n' '$TC24_COPYFAIL_EXECUTED_MODE'
        printf 'Copy Fail requested payload: %s\n' '$TC24_COPYFAIL_REQUESTED_PAYLOAD_RELATIVE_PATH'
        printf 'Copy Fail executed payload: %s\n' '$TC24_COPYFAIL_EXECUTED_PAYLOAD_RELATIVE_PATH'
        python3 $payload_name --scenario tc24-runc-container-escape --runtime $TC24_RUNTIME_ID --mode $TC24_COPYFAIL_EXECUTED_MODE --thesis-safe > copyfail-payload.log 2>&1
        copyfail_status=\$?
        if [ \"\$copyfail_status\" -eq 0 ]; then
            printf 'runc binary remains unchanged - reversible probe only\n'
        else
            printf 'Copy Fail payload execution failed (exit=%s)\n' \"\$copyfail_status\"
        fi
        cat copyfail-payload.log 2>/dev/null || true
        exit \"\$copyfail_status\"
    " 2>&1 || true)"
    printf '%s\n' "$program_output"

    { [[ "$program_output" == *"softened_copyfail_probe: completed without destructive overwrite"* ]] || \
      [[ "$program_output" == *"reversible_copyfail_variant: completed without destructive overwrite"* ]] || \
      [[ "$program_output" == *"copyfail_reversible_exploit: overwrite demonstrated and restoration verified"* ]]; } && \
        [[ "$program_output" == *"runc binary remains unchanged - reversible probe only"* ]]
}

analyze_historical_runc_fix_reexposure() {
    local executed_mode="${1:-reversible}"
    echo "Analyzing historical runc fix re-exposure..."

    if [ "$executed_mode" = "reversible" ]; then
        local finding_line="Key Finding: Reversible/non-destructive Copy Fail automation path completed; historical runc fix re-exposure remains unconfirmed on this run."
    else
        local finding_line="Key Finding: Copy Fail execution mode ${executed_mode} requires follow-up review before claiming historical runc fix re-exposure."
    fi

    cat > "$RESULTS_DIR/historical_runc_fix_reexposure_analysis.txt" << EOF
--- Historical runc hardening re-exposure analysis ---

Original runc container escape class:
- Issue: runc binary could be overwritten from inside container
- Fix: Copy runc to memfd before execve
- Later Fix: Read-only bind mount of host runc into container

CVE-2026-31431 (Copy Fail) Re-exposure:
- Issue: Page cache sharing for performance re-exposes runc to page cache writes
- Mechanism: AF_ALG socket abuse allows page cache modification
- Impact: runc binary in page cache can be poisoned, affecting next invocation

Attack Chain:
1. Force runc to run (kubectl exec, container restart, etc.)
2. Locate runc PID in container's PID namespace
3. Poison runc via /proc/<runc_pid>/exe using Copy Fail
4. Wait for next runc invocation (admin exec, pod start, etc.)

Mitigation:
- Block AF_ALG sockets via seccomp profile
- Use gVisor (runsc) for separate user-space kernel
- Use Kata Containers for per-pod VM isolation
- Patch host kernel to fix root cause

${finding_line}
EOF

    cat "$RESULTS_DIR/historical_runc_fix_reexposure_analysis.txt"
}

echo "--- TC24: runc Container Escape via Page Cache ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: ${TC24_RUNTIME_ID}"
echo ""

reset_collection_results_dir "$RESULTS_DIR"

cld6001_mirror_artifacts_on_exit "TC24_ARTIFACTS_DIR" "TC24 runc-container-escape"

touch "$RESULTS_DIR/test-results.txt"

LOG_FILE="${RESULTS_DIR}/tc24-runc-container-escape.log"
ANALYSIS_FILE="${RESULTS_DIR}/runc-escape-analysis.json"
date "+%Y-%m-%d %H:%M:%S" > "$LOG_FILE" 2>&1

log_line() {
  echo "$1" | tee -a "$LOG_FILE"
}

log_line "Copy Fail requested mode: $TC24_COPYFAIL_REQUESTED_MODE"
log_line "Copy Fail executed mode: $TC24_COPYFAIL_EXECUTED_MODE"
log_line "Copy Fail requested payload: $TC24_COPYFAIL_REQUESTED_PAYLOAD_RELATIVE_PATH"
log_line "Copy Fail executed payload: $TC24_COPYFAIL_EXECUTED_PAYLOAD_RELATIVE_PATH"
log_line "Copy Fail fallback reason: $TC24_COPYFAIL_FALLBACK_REASON"

echo "--- TC24.1:: runc binary location identification ---"
log_line "--- runc Binary Location Identification ---"

if identify_runc_location 2>&1 | tee -a "$LOG_FILE"; then
    RUNC_LOCATION_IDENTIFIED=true
    log_line "runc binary location identification completed"
    cld6001_record_result "runc_location_identification" "PASS"
else
    RUNC_LOCATION_IDENTIFIED=false
    log_line "runc binary location identification failed"
    cld6001_record_result "runc_location_identification" "FAIL"
fi

echo "--- TC24.2:: runc page cache sharing analysis ---"
log_line "--- runc Page Cache Sharing Analysis ---"

if analyze_runc_page_cache_sharing 2>&1 | tee -a "$LOG_FILE"; then
    RUNC_PAGE_CACHE_SHARING_STATUS="observed"
    log_line "runc page cache sharing analysis completed"
    cld6001_record_result "runc_page_cache_sharing" "PASS"
else
    RUNC_PAGE_CACHE_SHARING_STATUS="not-observed"
    log_line "runc page cache sharing analysis failed"
    cld6001_record_result "runc_page_cache_sharing" "FAIL"
fi

echo "--- TC24.3:: runc binary page cache poisoning potential test ---"
log_line "--- runc Binary Page Cache Poisoning Potential ---"

if test_runc_poisoning_potential 2>&1 | tee -a "$LOG_FILE"; then
    CONTAINER_ESCAPE_POTENTIAL_STATUS="reversible-probe-only"
    log_line "runc poisoning potential test completed"
    cld6001_record_result "runc_poisoning_potential" "PASS"
else
    CONTAINER_ESCAPE_POTENTIAL_STATUS="not-observed"
    log_line "runc poisoning potential test failed"
    cld6001_record_result "runc_poisoning_potential" "FAIL"
fi

echo "--- TC24.4:: historical runc hardening re-exposure analysis ---"
log_line "--- Historical runc hardening re-exposure analysis ---"

analyze_historical_runc_fix_reexposure "$TC24_COPYFAIL_EXECUTED_MODE" 2>&1 | tee -a "$LOG_FILE"
HISTORICAL_FIX_REEXPOSED=false
cld6001_record_result "historical_runc_fix_reexposure_analysis" "PASS"

echo "--- TC24.5:: Generate analysis report ---"

cat > "$ANALYSIS_FILE" << EOF
{
  "test_case": "TC24",
  "title": "runc Container Escape Analysis",
  "timestamp": "$(date -Iseconds)",
  "runtime": "${TC24_RUNTIME_ID}",
  "cves": ["CVE-2026-31431"],
  "copyfail": {
    "requested_mode": "${TC24_COPYFAIL_REQUESTED_MODE}",
    "executed_mode": "${TC24_COPYFAIL_EXECUTED_MODE}",
    "fallback_reason": "${TC24_COPYFAIL_FALLBACK_REASON}",
    "requested_payload": "${TC24_COPYFAIL_REQUESTED_PAYLOAD_RELATIVE_PATH}",
    "executed_payload": "${TC24_COPYFAIL_EXECUTED_PAYLOAD_RELATIVE_PATH}"
  },
  "findings": {
    "runc_location_identified": ${RUNC_LOCATION_IDENTIFIED},
    "page_cache_sharing": "${RUNC_PAGE_CACHE_SHARING_STATUS}",
    "container_escape_potential": "${CONTAINER_ESCAPE_POTENTIAL_STATUS}",
    "historical_fix_reexposed": ${HISTORICAL_FIX_REEXPOSED}
  },
  "attack_chain": [
    "Force runc to run (kubectl exec, container restart)",
    "Locate runc PID in container's PID namespace",
    "Poison runc via /proc/<runc_pid>/exe using Copy Fail",
    "Wait for next runc invocation (admin exec, pod start)"
  ],
  "recommendations": [
    "Block AF_ALG sockets via seccomp profile",
    "Use gVisor (runsc) for separate user-space kernel",
    "Use Kata Containers for per-pod VM isolation",
    "Patch host kernel to fix root cause"
  ]
}
EOF

log_line "Analysis report generated: $ANALYSIS_FILE"

echo ""
echo "--- TC24: runc Container Escape via Page Cache ---"
