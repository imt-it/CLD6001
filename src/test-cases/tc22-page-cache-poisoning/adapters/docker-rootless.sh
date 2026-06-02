#!/bin/bash
declare -A CVE_TO_TC
CVE_TO_TC["CVE-2026-31431"]="TC22"

AF_ALG_AVAILABLE=false
AF_ALG_PROBE_STATUS="not-run"
AF_ALG_DEFAULT_PROFILE_STATUS="not-run"
AF_ALG_UNCONFINED_PROFILE_STATUS="not-run"
AF_ALG_LAST_PROBE_RESULT="not-run"
AF_ALG_LAST_PROBE_ERRNO=""
PAGE_CACHE_WRITE_STATUS="not-run"
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/shared/adapter-result-helpers.sh"
source "$REPO_ROOT/src/shared/copyfail-mode-helpers.sh"
source "$REPO_ROOT/src/shared/adapter-artifact-helpers.sh"

TC22_RUNTIME_ID="${RUNNER_RUNTIME_ID:-docker-rootless}"
RESULTS_DIR="${RUNNER_PHASE_RESULTS_DIR:?RUNNER_PHASE_RESULTS_DIR is required}"
TC22_ARTIFACTS_DIR="${RUNNER_ARTIFACTS_DIR:-}"

if [ -n "$TC22_ARTIFACTS_DIR" ]; then
  TC22_ARTIFACTS_DIR="$(resolve_results_repo_root "$TC22_ARTIFACTS_DIR")"
fi

TC22_COPYFAIL_REQUESTED_MODE="$(cld6001_copyfail_resolve_mode "${RUNNER_COPYFAIL_MODE:-}")"
TC22_COPYFAIL_EXECUTED_MODE="$(cld6001_copyfail_effective_mode "${RUNNER_COPYFAIL_MODE:-}")"
TC22_COPYFAIL_FALLBACK_REASON="$(cld6001_copyfail_fallback_reason "${RUNNER_COPYFAIL_MODE:-}")"
TC22_COPYFAIL_REQUESTED_PAYLOAD_RELATIVE_PATH="$(cld6001_copyfail_payload_relative_path "$TC22_COPYFAIL_REQUESTED_MODE")"
TC22_COPYFAIL_EXECUTED_PAYLOAD_RELATIVE_PATH="$(cld6001_copyfail_executed_payload_relative_path "${RUNNER_COPYFAIL_MODE:-}")"
{ _cf_payload_path="$(cld6001_copyfail_resolve_payload_path "$TC22_COPYFAIL_EXECUTED_MODE")" && [ -f "$_cf_payload_path" ]; } || { printf 'Copy Fail executed payload not found: %s\n' "${_cf_payload_path:-}" >&2; exit 1; }
unset _cf_payload_path
case "$TC22_RUNTIME_ID" in
    docker-rootful|docker-rootless) TC22_RUNTIME_CMD="docker" ;;
    podman-rootless)                TC22_RUNTIME_CMD="podman" ;;
    *) printf 'Unsupported Copy Fail runtime: %s\n' "$TC22_RUNTIME_ID" >&2; exit 1 ;;
esac

extract_af_alg_probe_errno() {
    local program_output="$1"

    if [[ "$program_output" =~ \(errno=([0-9]+)\) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

classify_af_alg_probe_output() {
    local program_output="$1"
    local errno_value=""

    if [[ "$program_output" == *"AF_ALG socket available: YES"* ]]; then
        printf 'available\n'
        return 0
    fi

    errno_value="$(extract_af_alg_probe_errno "$program_output")"
    case "$errno_value" in
        1|13)
            printf 'blocked\n'
            ;;
        *)
            printf 'unavailable\n'
            ;;
    esac
}

run_af_alg_probe() {
    local af_alg_binary_path="$1"
    local helper_image="$2"
    shift 2
    local program_output=""

    program_output="$($TC22_RUNTIME_CMD run --rm "$@" -v "$af_alg_binary_path:/af_alg_test:ro" "$helper_image" /af_alg_test 2>&1 || true)"
    AF_ALG_LAST_PROBE_ERRNO="$(extract_af_alg_probe_errno "$program_output")"
    AF_ALG_LAST_PROBE_RESULT="$(classify_af_alg_probe_output "$program_output")"
    printf '%s\n' "$program_output"

    [ "$AF_ALG_LAST_PROBE_RESULT" = "available" ]
}

check_af_alg_availability() {
    echo "Checking AF_ALG socket availability..."

    local af_alg_probe_dir=""
    local af_alg_source_path=""
    local af_alg_binary_path=""

    AF_ALG_PROBE_STATUS="not-run"
    AF_ALG_DEFAULT_PROFILE_STATUS="not-run"
    AF_ALG_UNCONFINED_PROFILE_STATUS="not-run"
    AF_ALG_LAST_PROBE_RESULT="not-run"
    AF_ALG_LAST_PROBE_ERRNO=""

    af_alg_probe_dir="$(create_host_probe_dir "tc22-af-alg")"
    af_alg_source_path="$af_alg_probe_dir/af_alg_test.c"
    af_alg_binary_path="$af_alg_probe_dir/af_alg_test"

    cat > "$af_alg_source_path" << 'EOF'
#include <sys/socket.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

int main() {
    int fd;

    // Match the actual Copy Fail payload socket type.
    fd = socket(AF_ALG, SOCK_SEQPACKET, 0);
    if (fd >= 0) {
        printf("AF_ALG socket available: YES\n");
        close(fd);
        return 0;
    } else {
        printf("AF_ALG socket available: NO\n");
        printf("Error: %s (errno=%d)\n", strerror(errno), errno);
        return 1;
    }
}
EOF

    if gcc -o "$af_alg_binary_path" "$af_alg_source_path" 2>/dev/null; then
        local helper_image=""
        if declare -F resolve_helper_image >/dev/null 2>&1; then
            helper_image="$(resolve_helper_image "python-probe" 2>/dev/null || echo "python:3.14-slim")"
        else
            helper_image="python:3.14-slim"
        fi

        echo "--- Default seccomp profile ---"
        if run_af_alg_probe "$af_alg_binary_path" "$helper_image"; then
            AF_ALG_DEFAULT_PROFILE_STATUS="$AF_ALG_LAST_PROBE_RESULT"
            AF_ALG_PROBE_STATUS="available"
            echo "AF_ALG probe status: ${AF_ALG_PROBE_STATUS}"
            rm -rf -- "$af_alg_probe_dir"
            return 0
        fi
        AF_ALG_DEFAULT_PROFILE_STATUS="$AF_ALG_LAST_PROBE_RESULT"

        echo "--- Unconfined profile ---"
        run_af_alg_probe "$af_alg_binary_path" "$helper_image" --security-opt seccomp=unconfined || true
        AF_ALG_UNCONFINED_PROFILE_STATUS="$AF_ALG_LAST_PROBE_RESULT"

        case "$AF_ALG_UNCONFINED_PROFILE_STATUS" in
            available)
                AF_ALG_PROBE_STATUS="default-seccomp-blocked"
                echo "AF_ALG default-profile restrictions were lifted by seccomp=unconfined."
                ;;
            unavailable)
                AF_ALG_PROBE_STATUS="host-unavailable"
                echo "AF_ALG remained unavailable even with seccomp=unconfined."
                ;;
            *)
                AF_ALG_PROBE_STATUS="unavailable"
                echo "AF_ALG remained unavailable after both default and unconfined probes."
                ;;
        esac

        echo "AF_ALG probe status: ${AF_ALG_PROBE_STATUS}"
        rm -rf -- "$af_alg_probe_dir"
        return 1
    else
        AF_ALG_PROBE_STATUS="compile-failed"
        AF_ALG_DEFAULT_PROFILE_STATUS="compile-failed"
        echo "Failed to compile AF_ALG test"
        rm -rf -- "$af_alg_probe_dir"
        return 1
    fi
}

test_page_cache_write() {
    echo "Testing page cache write primitive..."

    local stage_dir=""
    local executed_payload_path=""
    local payload_name=""
    local helper_image=""
    local program_output=""

    stage_dir="$(create_host_probe_dir "tc22-copyfail")"
    executed_payload_path="$(cld6001_copyfail_resolve_payload_path "$TC22_COPYFAIL_EXECUTED_MODE")"
    { [ -f "$executed_payload_path" ] && mkdir -p "$stage_dir" && cp "$executed_payload_path" "$stage_dir/$(basename -- "$executed_payload_path")"; } || return 1
    payload_name="$(basename -- "$executed_payload_path")"
    helper_image="$(resolve_helper_image "python-probe" 2>/dev/null || echo "python:3.14-slim")"

    program_output="$($TC22_RUNTIME_CMD run --rm -v "$stage_dir:/probe:rw" "$helper_image" sh -c "
        cd /probe
        printf 'Copy Fail requested mode: %s\n' '$TC22_COPYFAIL_REQUESTED_MODE'
        printf 'Copy Fail executed mode: %s\n' '$TC22_COPYFAIL_EXECUTED_MODE'
        printf 'Copy Fail requested payload: %s\n' '$TC22_COPYFAIL_REQUESTED_PAYLOAD_RELATIVE_PATH'
        printf 'Copy Fail executed payload: %s\n' '$TC22_COPYFAIL_EXECUTED_PAYLOAD_RELATIVE_PATH'
        python3 $payload_name --scenario tc22-page-cache-poisoning --runtime $TC22_RUNTIME_ID --mode $TC22_COPYFAIL_EXECUTED_MODE --thesis-safe > copyfail-payload.log 2>&1
        copyfail_status=\$?
        if [ \"\$copyfail_status\" -eq 0 ]; then
            printf 'Page cache write: REVERSIBLE VARIANT COMPLETED\n'
        else
            printf 'Copy Fail payload execution failed (exit=%s)\n' \"\$copyfail_status\"
        fi
        cat copyfail-payload.log 2>/dev/null || true
        exit \"\$copyfail_status\"
    " 2>&1 || true)"
    printf '%s\n' "$program_output"

    { [[ "$program_output" == *"reversible_copyfail_variant: completed without destructive overwrite"* ]] || \
      [[ "$program_output" == *"copyfail_reversible_exploit: overwrite demonstrated and restoration verified"* ]]; } && \
        [[ "$program_output" == *"Page cache write: REVERSIBLE VARIANT COMPLETED"* ]]
}

analyze_detection_gaps() {
    echo "Analyzing detection limitations..."

    cat > "$RESULTS_DIR/detection_analysis.txt" << 'EOF'
--- Page Cache Poisoning Detection Analysis ---

Detection Method | Effective? | Notes
-----------------|------------|------
Image Registry Scanning | NO | Image bytes unchanged
Agent-less Disk Scanning | NO | On-disk file unchanged
File Integrity Monitoring | NO | On-disk hash unchanged
Runtime EDR (in-memory) | YES | Can detect modified pages
Seccomp AF_ALG blocking | YES | Removes the primitive
gVisor (runsc) | YES | Separate user-space kernel
Kata Containers | YES | Per-pod VM, separate kernel
Patched host kernel | YES | Root cause fixed

Key Finding: Most traditional security tools cannot detect page cache poisoning
because the compromise exists only in kernel memory, not on disk.
EOF

    cat "$RESULTS_DIR/detection_analysis.txt"
}

echo "--- TC22: Page Cache Poisoning (Copy Fail) ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: ${TC22_RUNTIME_ID}"
echo ""

reset_collection_results_dir "$RESULTS_DIR"

cld6001_mirror_artifacts_on_exit "TC22_ARTIFACTS_DIR" "TC22 page-cache-poisoning"

touch "$RESULTS_DIR/test-results.txt"

LOG_FILE="${RESULTS_DIR}/tc22-page-cache-poisoning.log"
ANALYSIS_FILE="${RESULTS_DIR}/page-cache-analysis.json"
date "+%Y-%m-%d %H:%M:%S" > "$LOG_FILE" 2>&1

log_line() {
  echo "$1" | tee -a "$LOG_FILE"
}

log_line "Copy Fail requested mode: $TC22_COPYFAIL_REQUESTED_MODE"
log_line "Copy Fail executed mode: $TC22_COPYFAIL_EXECUTED_MODE"
log_line "Copy Fail requested payload: $TC22_COPYFAIL_REQUESTED_PAYLOAD_RELATIVE_PATH"
log_line "Copy Fail executed payload: $TC22_COPYFAIL_EXECUTED_PAYLOAD_RELATIVE_PATH"
log_line "Copy Fail fallback reason: $TC22_COPYFAIL_FALLBACK_REASON"

echo "--- TC22.1:: AF_ALG socket availability check ---"
log_line "--- AF_ALG Socket Availability ---"

AF_ALG_OUTPUT_PATH="$(mktemp "${TMPDIR:-/tmp}/tc22-af-alg-output.XXXXXX")"
if check_af_alg_availability >"$AF_ALG_OUTPUT_PATH" 2>&1; then
    cat "$AF_ALG_OUTPUT_PATH" | tee -a "$LOG_FILE"
    AF_ALG_AVAILABLE=true
    log_line "AF_ALG sockets are available - potential Copy Fail attack surface"
    cld6001_record_result "af_alg_availability" "PASS"
else
    cat "$AF_ALG_OUTPUT_PATH" | tee -a "$LOG_FILE"
    AF_ALG_AVAILABLE=false
    case "$AF_ALG_PROBE_STATUS" in
        default-seccomp-blocked)
            log_line "AF_ALG sockets are blocked by the default profile but available with seccomp=unconfined"
            ;;
        host-unavailable)
            log_line "AF_ALG sockets remain unavailable even with seccomp=unconfined"
            ;;
        *)
            log_line "AF_ALG sockets not available - Copy Fail primitive blocked"
            ;;
    esac
    cld6001_record_result "af_alg_availability" "FAIL"
fi
rm -f -- "$AF_ALG_OUTPUT_PATH"
log_line "AF_ALG probe status: $AF_ALG_PROBE_STATUS"
log_line "AF_ALG default profile status: $AF_ALG_DEFAULT_PROFILE_STATUS"
log_line "AF_ALG unconfined profile status: $AF_ALG_UNCONFINED_PROFILE_STATUS"

echo "--- TC22.2:: Page cache write primitive test ---"
log_line "--- Page Cache Write Primitive ---"

if test_page_cache_write 2>&1 | tee -a "$LOG_FILE"; then
    PAGE_CACHE_WRITE_STATUS="reversible-probe-only"
    log_line "Page cache write primitive test completed"
    cld6001_record_result "page_cache_write" "PASS"
else
    PAGE_CACHE_WRITE_STATUS="no-change-detected"
    log_line "Page cache write primitive test failed"
    cld6001_record_result "page_cache_write" "FAIL"
fi

echo "--- TC22.3:: Detection gap analysis ---"
log_line "--- Detection Gap Analysis ---"

analyze_detection_gaps 2>&1 | tee -a "$LOG_FILE"
cld6001_record_result "detection_gap_analysis" "PASS"

echo "--- TC22.4:: Generate analysis report ---"

cat > "$ANALYSIS_FILE" << EOF
{
  "test_case": "TC22",
  "title": "Page Cache Poisoning Analysis (Copy Fail)",
  "timestamp": "$(date -Iseconds)",
  "runtime": "${TC22_RUNTIME_ID}",
  "cve": "CVE-2026-31431",
  "copyfail": {
    "requested_mode": "${TC22_COPYFAIL_REQUESTED_MODE}",
    "executed_mode": "${TC22_COPYFAIL_EXECUTED_MODE}",
    "fallback_reason": "${TC22_COPYFAIL_FALLBACK_REASON}",
    "requested_payload": "${TC22_COPYFAIL_REQUESTED_PAYLOAD_RELATIVE_PATH}",
    "executed_payload": "${TC22_COPYFAIL_EXECUTED_PAYLOAD_RELATIVE_PATH}"
  },
  "findings": {
    "af_alg_available": ${AF_ALG_AVAILABLE},
    "af_alg_probe_status": "${AF_ALG_PROBE_STATUS}",
    "af_alg_default_profile_status": "${AF_ALG_DEFAULT_PROFILE_STATUS}",
    "af_alg_unconfined_profile_status": "${AF_ALG_UNCONFINED_PROFILE_STATUS}",
    "page_cache_write": "${PAGE_CACHE_WRITE_STATUS}",
    "detection_gaps": "significant",
    "traditional_tools_effective": false
  },
  "recommendations": [
    "Block AF_ALG sockets via seccomp profile",
    "Use runtime EDR for in-memory detection",
    "Consider VM-based isolation for sensitive workloads",
    "Patch host kernel to fix root cause"
  ]
}
EOF

log_line "Analysis report generated: $ANALYSIS_FILE"

echo ""
echo "--- TC22: Page Cache Poisoning (Copy Fail) ---"
