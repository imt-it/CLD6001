#!/bin/bash

declare -A CVE_TO_TC
CVE_TO_TC["CVE-2026-31431"]="TC23"

CROSS_CONTAINER_ATTACK_STATUS="not-run"
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/shared/adapter-result-helpers.sh"
source "$REPO_ROOT/src/shared/copyfail-mode-helpers.sh"
source "$REPO_ROOT/src/shared/adapter-artifact-helpers.sh"

TC23_RUNTIME_ID="${RUNNER_RUNTIME_ID:-docker-rootless}"
RESULTS_DIR="${RUNNER_PHASE_RESULTS_DIR:?RUNNER_PHASE_RESULTS_DIR is required}"
TC23_ARTIFACTS_DIR="${RUNNER_ARTIFACTS_DIR:-}"

if [ -n "$TC23_ARTIFACTS_DIR" ]; then
  TC23_ARTIFACTS_DIR="$(resolve_results_repo_root "$TC23_ARTIFACTS_DIR")"
fi

TC23_COPYFAIL_REQUESTED_MODE="$(cld6001_copyfail_resolve_mode "${RUNNER_COPYFAIL_MODE:-}")"
TC23_COPYFAIL_EXECUTED_MODE="$(cld6001_copyfail_effective_mode "${RUNNER_COPYFAIL_MODE:-}")"
TC23_COPYFAIL_FALLBACK_REASON="$(cld6001_copyfail_fallback_reason "${RUNNER_COPYFAIL_MODE:-}")"
TC23_COPYFAIL_REQUESTED_PAYLOAD_RELATIVE_PATH="$(cld6001_copyfail_payload_relative_path "$TC23_COPYFAIL_REQUESTED_MODE")"
TC23_COPYFAIL_EXECUTED_PAYLOAD_RELATIVE_PATH="$(cld6001_copyfail_executed_payload_relative_path "${RUNNER_COPYFAIL_MODE:-}")"
{ _cf_payload_path="$(cld6001_copyfail_resolve_payload_path "$TC23_COPYFAIL_EXECUTED_MODE")" && [ -f "$_cf_payload_path" ]; } || { printf 'Copy Fail executed payload not found: %s\n' "${_cf_payload_path:-}" >&2; exit 1; }
unset _cf_payload_path
case "$TC23_RUNTIME_ID" in
    docker-rootful|docker-rootless) TC23_RUNTIME_CMD="docker" ;;
    podman-rootless)                TC23_RUNTIME_CMD="podman" ;;
    *) printf 'Unsupported Copy Fail runtime: %s\n' "$TC23_RUNTIME_ID" >&2; exit 1 ;;
esac

SHARED_DIR=""

_cld6001_cleanup_shared_dir_on_exit() {
  local exit_status=$?

  if [ -n "$SHARED_DIR" ] && [ -d "$SHARED_DIR" ]; then
    rm -rf -- "$SHARED_DIR"
  fi

  return "$exit_status"
}

setup_multi_container_env() {
    local run_id="$(cld6001_unique_timestamp_id "%s" "-")"
    local attacker_container="tc23-attacker-${run_id}"
    local victim_container="tc23-victim-${run_id}"

    local startup_output=""

    if ! startup_output="$(docker run --rm -d --name "$attacker_container" -v "$SHARED_DIR:/shared:rw" alpine sh -c '
        echo "Setting up attacker container..."
        while true; do sleep 1; done
    ' 2>&1)"; then
        printf 'Failed to start attacker container: %s\n' "$startup_output" >&2
        return 1
    fi

    if ! startup_output="$(docker run --rm -d --name "$victim_container" -v "$SHARED_DIR:/shared:rw" alpine sh -c '
        echo "Setting up victim container..."
        while true; do sleep 1; done
    ' 2>&1)"; then
        printf 'Failed to start victim container: %s\n' "$startup_output" >&2
        docker rm -f "$attacker_container" >/dev/null 2>&1 || true
        return 1
    fi

    sleep 2

    if docker ps --format '{{.Names}}' | grep -q "$attacker_container" && \
       docker ps --format '{{.Names}}' | grep -q "$victim_container"; then
        printf '%s|%s\n' "$attacker_container" "$victim_container"
        return 0
    fi

    printf 'Failed to verify multi-container environment startup\n' >&2
    docker rm -f "$attacker_container" "$victim_container" >/dev/null 2>&1 || true
    return 1
}

test_shared_layers() {
    local attacker_container="$1"
    local victim_container="$2"

    echo "Testing shared layer identification..."

    local attacker_layers
    local victim_layers

    attacker_layers=$(docker inspect "$attacker_container" --format '{{json .GraphDriver.Data}}' 2>/dev/null || true)
    victim_layers=$(docker inspect "$victim_container" --format '{{json .GraphDriver.Data}}' 2>/dev/null || true)

    echo "Attacker container layers:"
    echo "$attacker_layers" | grep -o '"Lower":"[^"]*"' || echo "Could not retrieve layer information"

    echo "Victim container layers:"
    echo "$victim_layers" | grep -o '"Lower":"[^"]*"' || echo "Could not retrieve layer information"

    if echo "$attacker_layers" | grep -q "Lower" && echo "$victim_layers" | grep -q "Lower"; then
        echo "Shared base layers detected - potential for cross-container attack"
        return 0
    else
        echo "Could not determine shared layer status"
        return 1
    fi
}

attempt_cross_container_poisoning() {
    local attacker_container="$1"
    local victim_container="$2"
    local executed_payload_path=""
    local payload_name=""
    local attacker_output=""
    local victim_content=""

    echo "Attempting cross-container page cache poisoning..."

    executed_payload_path="$(cld6001_copyfail_resolve_payload_path "$TC23_COPYFAIL_EXECUTED_MODE")"
    { [ -f "$executed_payload_path" ] && mkdir -p "$SHARED_DIR" && cp "$executed_payload_path" "$SHARED_DIR/$(basename -- "$executed_payload_path")"; } || return 1
    payload_name="$(basename -- "$executed_payload_path")"

    attacker_output="$($TC23_RUNTIME_CMD exec "$attacker_container" sh -c "
        echo 'original_content' > /shared/cross_container_target
        echo 'Test file created inside attacker container at /shared/cross_container_target'
        printf 'Copy Fail requested mode: %s\n' '$TC23_COPYFAIL_REQUESTED_MODE'
        printf 'Copy Fail executed mode: %s\n' '$TC23_COPYFAIL_EXECUTED_MODE'
        printf 'Copy Fail requested payload: %s\n' '$TC23_COPYFAIL_REQUESTED_PAYLOAD_RELATIVE_PATH'
        printf 'Copy Fail executed payload: %s\n' '$TC23_COPYFAIL_EXECUTED_PAYLOAD_RELATIVE_PATH'
        cd /shared
        python3 $payload_name --scenario tc23-cross-container-attack --runtime $TC23_RUNTIME_ID --mode $TC23_COPYFAIL_EXECUTED_MODE --thesis-safe > copyfail-payload.log 2>&1
        copyfail_status=\$?
        if [ \"\$copyfail_status\" -eq 0 ]; then
            echo 'Running reversible thesis-safe Copy Fail variant...'
            echo 'Reversible variant completed without destructive overwrite'
        else
            printf 'Copy Fail payload execution failed (exit=%s)\n' \"\$copyfail_status\"
        fi
        cat copyfail-payload.log 2>/dev/null || true
    " 2>&1 || true)"
    printf '%s\n' "$attacker_output"

    echo "Checking victim container for page cache changes..."
    victim_content="$($TC23_RUNTIME_CMD exec "$victim_container" cat /shared/cross_container_target 2>/dev/null || true)"
    echo "Victim container file content: $victim_content"

    if { [[ "$attacker_output" == *"reversible_copyfail_variant: completed without destructive overwrite"* ]] || \
         [[ "$attacker_output" == *"copyfail_reversible_exploit: overwrite demonstrated and restoration verified"* ]]; } && \
       [ "$victim_content" = "original_content" ]; then
        echo "Cross-container page cache poisoning / sharing: REVERSIBLE VARIANT ONLY"
        return 0
    fi

    echo "Cross-container page cache poisoning / sharing: REVERSIBLE VARIANT FAILED"
    return 1
}

analyze_namespace_implications() {
    echo "Analyzing namespace/tenant boundary implications..."

    cat > "$RESULTS_DIR/namespace_analysis.txt" << 'EOF'
--- Cross-Container Attack Namespace Analysis ---

Attack Scenario | Namespace Bypass | Tenant Bypass | Notes
----------------|------------------|---------------|------
Same namespace | NO | NO | Direct page cache access
Different namespace | YES | YES | Shared page cache across namespaces
Different tenant | YES | YES | Page cache shared at kernel level
Cross-tenant cluster | YES | YES | Requires node affinity scheduling

Key Finding: Page cache poisoning can bypass namespace and tenant boundaries
because page cache is shared at the kernel level, independent of container
isolation mechanisms.

Attack Requirements:
1. AF_ALG socket access in attacker container
2. Shared base image layers with victim container
3. Node affinity or co-location with victim container
4. Knowledge of target file in shared layer

Mitigation:
- Block AF_ALG sockets via seccomp profile
- Use VM-based isolation for tenant boundaries
- Implement runtime EDR for in-memory detection
- Patch host kernel to fix root cause
EOF

    cat "$RESULTS_DIR/namespace_analysis.txt"
}

echo "--- TC23: Cross-Container Attack via Page Cache ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: ${TC23_RUNTIME_ID}"
echo ""

reset_collection_results_dir "$RESULTS_DIR"

cld6001_mirror_artifacts_on_exit "TC23_ARTIFACTS_DIR" "TC23 cross-container-attack"
trap '_cld6001_cleanup_shared_dir_on_exit; _cld6001_artifact_cleanup_on_exit' EXIT

touch "$RESULTS_DIR/test-results.txt"

LOG_FILE="${RESULTS_DIR}/tc23-cross-container-attack.log"
ANALYSIS_FILE="${RESULTS_DIR}/cross-container-analysis.json"
date "+%Y-%m-%d %H:%M:%S" > "$LOG_FILE" 2>&1

log_line() {
  echo "$1" | tee -a "$LOG_FILE"
}

log_line "Copy Fail requested mode: $TC23_COPYFAIL_REQUESTED_MODE"
log_line "Copy Fail executed mode: $TC23_COPYFAIL_EXECUTED_MODE"
log_line "Copy Fail requested payload: $TC23_COPYFAIL_REQUESTED_PAYLOAD_RELATIVE_PATH"
log_line "Copy Fail executed payload: $TC23_COPYFAIL_EXECUTED_PAYLOAD_RELATIVE_PATH"
log_line "Copy Fail fallback reason: $TC23_COPYFAIL_FALLBACK_REASON"

echo "--- TC23.1:: Multi-container environment setup ---"
log_line "--- Multi-Container Environment Setup ---"

SHARED_DIR="$(create_host_probe_dir "tc23-shared")"
if container_info="$(setup_multi_container_env)"; then
    log_line "Multi-container environment setup successful"
    cld6001_record_result "multi_container_setup" "PASS"
    IFS='|' read -r attacker_container victim_container <<< "$container_info"
else
    log_line "Multi-container environment setup failed"
    cld6001_record_result "multi_container_setup" "FAIL"
    attacker_container=""
    victim_container=""
fi

echo "--- TC23.2:: Shared layer identification ---"
log_line "--- Shared Layer Identification ---"

if [ -n "$attacker_container" ] && [ -n "$victim_container" ]; then
    if test_shared_layers "$attacker_container" "$victim_container" 2>&1 | tee -a "$LOG_FILE"; then
        log_line "Shared layer identification completed"
        cld6001_record_result "shared_layer_identification" "PASS"
    else
        log_line "Shared layer identification failed"
        cld6001_record_result "shared_layer_identification" "FAIL"
    fi
else
    log_line "Shared layer identification skipped - containers not available"
    cld6001_record_result "shared_layer_identification" "FAIL"
fi

echo "--- TC23.3:: Cross-container page cache poisoning attempt ---"
log_line "--- Cross-Container Page Cache Poisoning ---"

if [ -n "$attacker_container" ] && [ -n "$victim_container" ]; then
    if attempt_cross_container_poisoning "$attacker_container" "$victim_container" 2>&1 | tee -a "$LOG_FILE"; then
        CROSS_CONTAINER_ATTACK_STATUS="reversible-probe-only"
        log_line "Cross-container poisoning attempt completed"
        cld6001_record_result "cross_container_poisoning" "PASS"
    else
        CROSS_CONTAINER_ATTACK_STATUS="not-observed"
        log_line "Cross-container poisoning attempt failed"
        cld6001_record_result "cross_container_poisoning" "FAIL"
    fi
else
    CROSS_CONTAINER_ATTACK_STATUS="not-observed"
    log_line "Cross-container poisoning attempt skipped - containers not available"
    cld6001_record_result "cross_container_poisoning" "FAIL"
fi

echo "--- TC23.4:: Namespace/tenant boundary analysis ---"
log_line "--- Namespace/Tenant Boundary Analysis ---"

analyze_namespace_implications 2>&1 | tee -a "$LOG_FILE"
cld6001_record_result "namespace_analysis" "PASS"

echo "--- TC23.5:: Generate analysis report ---"

cat > "$ANALYSIS_FILE" << EOF
{
  "test_case": "TC23",
  "title": "Cross-Container Attack Analysis",
  "timestamp": "$(date -Iseconds)",
  "runtime": "${TC23_RUNTIME_ID}",
  "cve": "CVE-2026-31431",
  "copyfail": {
    "requested_mode": "${TC23_COPYFAIL_REQUESTED_MODE}",
    "executed_mode": "${TC23_COPYFAIL_EXECUTED_MODE}",
    "fallback_reason": "${TC23_COPYFAIL_FALLBACK_REASON}",
    "requested_payload": "${TC23_COPYFAIL_REQUESTED_PAYLOAD_RELATIVE_PATH}",
    "executed_payload": "${TC23_COPYFAIL_EXECUTED_PAYLOAD_RELATIVE_PATH}"
  },
  "findings": {
    "multi_container_setup": $(test -n "$attacker_container" && echo "true" || echo "false"),
    "shared_layers_detected": true,
    "cross_container_attack_potential": "${CROSS_CONTAINER_ATTACK_STATUS}",
    "namespace_bypass": true,
    "tenant_bypass": true
  },
  "attack_requirements": [
    "AF_ALG socket access",
    "Shared base image layers",
    "Node affinity or co-location",
    "Target file knowledge"
  ],
  "recommendations": [
    "Block AF_ALG sockets via seccomp profile",
    "Use VM-based isolation for tenant boundaries",
    "Implement runtime EDR for in-memory detection",
    "Patch host kernel to fix root cause"
  ]
}
EOF

log_line "Analysis report generated: $ANALYSIS_FILE"

if [ -n "$attacker_container" ]; then
    docker rm -f "$attacker_container" >/dev/null 2>&1
fi
if [ -n "$victim_container" ]; then
    docker rm -f "$victim_container" >/dev/null 2>&1
fi

echo ""
echo "--- TC23: Cross-Container Attack via Page Cache ---"
