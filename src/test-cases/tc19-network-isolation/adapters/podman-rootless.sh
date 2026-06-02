#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/shared/adapter-result-helpers.sh"
source "$REPO_ROOT/src/shared/adapter-artifact-helpers.sh"
source "$REPO_ROOT/src/execute/escape-tests/network-probe-common.sh"
TC19_REVERSIBLE_VARIANT_PROBE="$(resolve_source_repo_path "resources/exploits/cve2026_31431_reversible/copy_fail_exp_reversible.py")"

TC19_RUNTIME_ID="${RUNNER_RUNTIME_ID:-podman-rootless}"
RESULTS_DIR="${RUNNER_PHASE_RESULTS_DIR:?RUNNER_PHASE_RESULTS_DIR is required}"
TC19_ARTIFACTS_DIR="${RUNNER_ARTIFACTS_DIR:-}"
TC19_BLOCKED_REASON_CODE=""
TC19_BLOCKED_REASON_TEXT=""

if [ -n "$TC19_ARTIFACTS_DIR" ]; then
  TC19_ARTIFACTS_DIR="$(resolve_results_repo_root "$TC19_ARTIFACTS_DIR")"
fi

if [ ! -f "$TC19_REVERSIBLE_VARIANT_PROBE" ]; then
  printf 'TC19 reversible variant helper not found: %s\n' "$TC19_REVERSIBLE_VARIANT_PROBE" >&2
  exit 1
fi

reset_collection_results_dir "$RESULTS_DIR"

HOST_LISTENER_PID=""
HOST_LISTENER_PORT=""

log_tc19() {
  printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

sanitize_tc19_probe_label() {
  printf '%s' "$1" | tr '[:upper:] ' '[:lower:]_' | tr -cd '[:alnum:]_-'
}

assess_tc19_reversible_variant() {
  local label="$1"
  local expected_network="$2"
  local target_host="$3"
  local probe_status="$4"
  local probe_output="$5"
  local artifact_file="$RESULTS_DIR/tc19-$(sanitize_tc19_probe_label "$label")-reversible-variant.json"

  python3 "$TC19_REVERSIBLE_VARIANT_PROBE" network \
    --scenario "tc19-network-isolation" \
    --runtime "$TC19_RUNTIME_ID" \
    --mode "reversible" \
    --thesis-safe \
    --probe-label "$label" \
    --expected-network "$expected_network" \
    --target-host "$target_host" \
    --target-port "$HOST_LISTENER_PORT" \
    --probe-status "$probe_status" \
    --probe-output "$probe_output" \
    --artifact-file "$artifact_file" \
    --format tsv
}

start_host_tcp_helper() {
  HOST_LISTENER_PORT="$1"
  start_host_tcp_helper_process HOST_LISTENER_PID "$HOST_LISTENER_PORT"
  wait_for_local_tcp_listener_ready "$HOST_LISTENER_PID" "$HOST_LISTENER_PORT"
}

cleanup_host_tcp_helper() {
  if [ -n "${HOST_LISTENER_PID:-}" ]; then
    kill "$HOST_LISTENER_PID" 2>/dev/null || true
    wait "$HOST_LISTENER_PID" 2>/dev/null || true
    HOST_LISTENER_PID=""
  fi
}

podman_container_ip() {
  local container_name="$1"
  podman inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name"
}

podman_container_gateway() {
  local container_name="$1"
  podman inspect --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' "$container_name"
}

LOG_FILE="${RESULTS_DIR}/tc19-network-isolation.log"
date "+%Y-%m-%d %H:%M:%S" > "$LOG_FILE" 2>&1
touch "$RESULTS_DIR/test-results.txt"

PROBE_IMAGE="${RUNNER_TARGET_IMAGE:-}"
if [ -z "$PROBE_IMAGE" ]; then
  PROBE_IMAGE="$(resolve_helper_image alpine-shell)"
fi

RUN_ID="$(cld6001_unique_timestamp_id "%s" "-")"
TARGET_CONTAINER="tc19-target-${RUN_ID}"
POD_TARGET_CONTAINER="tc19-pod-target-${RUN_ID}"
TEST_POD="tc19-pod-${RUN_ID}"
DEFAULT_NETWORK="tc19-net-${RUN_ID}"
TC19_LISTENING_PORTS_PROBE="$(listening_socket_probe_script)"
TC19_TCP_TARGET_PROBE="$(tcp_target_probe_script)"

cleanup_tc19_podman_resources() {
  cleanup_host_tcp_helper

  if podman container exists "$POD_TARGET_CONTAINER" >/dev/null 2>&1; then
    podman rm -f "$POD_TARGET_CONTAINER" >/dev/null 2>&1
  fi

  if podman container exists "$TARGET_CONTAINER" >/dev/null 2>&1; then
    podman rm -f "$TARGET_CONTAINER" >/dev/null 2>&1
  fi

  if podman network exists "$DEFAULT_NETWORK" >/dev/null 2>&1; then
    podman network rm "$DEFAULT_NETWORK" >/dev/null 2>&1
  fi

  if podman pod exists "$TEST_POD" >/dev/null 2>&1; then
    podman pod rm -f "$TEST_POD" >/dev/null 2>&1
  fi
}

cleanup_on_exit() {
  local exit_status=$?

  if ! cleanup_tc19_podman_resources; then
    echo "TC19 Podman cleanup failed" >&2
    if [ $exit_status -eq 0 ]; then
      exit_status=1
    fi
  fi

  if ! cld6001_mirror_artifacts_now "TC19_ARTIFACTS_DIR"; then
    echo "TC19 Podman artifact mirroring failed" >&2
    if [ $exit_status -eq 0 ]; then
      exit_status=1
    fi
  fi

  exit "$exit_status"
}

trap cleanup_on_exit EXIT

record_tc19_block() {
  local reason_code="$1"
  local reason_text="$2"

  if [ -z "$TC19_BLOCKED_REASON_CODE" ]; then
    TC19_BLOCKED_REASON_CODE="$reason_code"
    TC19_BLOCKED_REASON_TEXT="$reason_text"
  fi
}

run_tc19_validation() {
  local status=0

  "$@" || status=$?
  if [ "$status" -eq "${BLOCK_EXIT_CODE:-3}" ]; then
    return 0
  fi

  return 0
}

run_bounded_bypass_probe() {
  local label="$1"
  local expected_network="$2"
  local target_host="$3"
  shift 3

  local probe_output=""
  local probe_status=0
  local assessment_output=""
  local assessment_state=""
  local assessment_message=""

  log_tc19 "Attempting bounded bypass probe: ${label} (${expected_network} -> ${target_host}:${HOST_LISTENER_PORT})"
  capture_command_output probe_output probe_status "$@"
  if [ -n "$probe_output" ]; then
    printf '%s\n' "$probe_output" | tee -a "$LOG_FILE"
  fi

  if ! assessment_output="$(assess_tc19_reversible_variant "$label" "$expected_network" "$target_host" "$probe_status" "$probe_output")"; then
    log_tc19 "FAIL: ${label} reversible variant assessment failed"
    return 1
  fi
  IFS=$'\t' read -r assessment_state assessment_message <<< "$assessment_output"

  case "$assessment_state" in
    pass)
      log_tc19 "PASS: ${assessment_message}"
      return 0
      ;;
    unavailable)
      log_tc19 "INFO: ${assessment_message}"
      return 2
      ;;
    fail)
      log_tc19 "FAIL: ${assessment_message}"
      return 1
      ;;
  esac

  log_tc19 "FAIL: ${label} reversible variant assessment returned an unknown state"
  return 1
}

validate_default_network_reachability() {
  local target_ip=""

  log_tc19 "--- TC19.1:: Shared default-network reachability ---"
  log_tc19 "Starting default-network target container on dedicated Podman bridge..."
  podman network create "$DEFAULT_NETWORK" >/dev/null
  podman run --rm -d --network "$DEFAULT_NETWORK" --name "$TARGET_CONTAINER" "$PROBE_IMAGE" sh -c 'while true; do printf "default\n" | nc -l -p 8000; done' >/dev/null

  if ! target_ip="$(wait_for_nonempty_command_output podman_container_ip "$TARGET_CONTAINER")"; then
    log_tc19 "FAIL: Could not resolve Podman default-network target IP"
    cld6001_record_result "default_network_reachability" "FAIL"
    return 1
  fi

  if ! wait_for_command_success podman run --rm --network "$DEFAULT_NETWORK" -e TARGET_IP="$target_ip" -i "$PROBE_IMAGE" sh -c 'nc -w 3 -z "$TARGET_IP" 8000'; then
    log_tc19 "FAIL: Dedicated default-network target listener did not become reachable on ${target_ip}:8000"
    cld6001_record_result "default_network_reachability" "FAIL"
    return 1
  fi

  log_tc19 "Resolved Podman default-network target IP: $target_ip"
  if podman run --rm --network "$DEFAULT_NETWORK" -e TARGET_IP="$target_ip" -i "$PROBE_IMAGE" sh -c 'nc -w 3 -z "$TARGET_IP" 8000' 2>&1 | tee -a "$LOG_FILE"; then
    log_tc19 "PASS: Shared default-network peers can reach the target by IP"
    cld6001_record_result "default_network_reachability" "PASS"
    return 0
  fi

  log_tc19 "FAIL: Shared default-network peers could not reach the target by IP"
  cld6001_record_result "default_network_reachability" "FAIL"
  return 1
}

capture_network_namespace_state() {
  log_tc19 "--- TC19.2:: Network namespace state capture ---"
  read -r -d '' TC19_PODMAN_NETWORK_STATE_SCRIPT <<EOF || true
echo "--- Network namespace state ---"
echo "Network interfaces:"
ip link show
echo ""
echo "Listening ports:"
${TC19_LISTENING_PORTS_PROBE}
echo ""
echo "Default route:"
ip route show
echo ""
echo "Namespaces:"
cat /proc/self/ns/net 2>/dev/null || echo "Cannot read namespace info"
EOF

  if podman run --rm -i "$PROBE_IMAGE" sh -c "$TC19_PODMAN_NETWORK_STATE_SCRIPT" 2>&1 | tee -a "$LOG_FILE"; then
    log_tc19 "PASS: Network namespace state capture completed"
    cld6001_record_result "network_namespace_state_capture" "PASS"
    return 0
  fi

  log_tc19 "FAIL: Network namespace state capture failed"
  cld6001_record_result "network_namespace_state_capture" "FAIL"
  return 1
}

validate_host_network_exposure() {
  HOST_LISTENER_PORT="$((19080 + (RANDOM % 1000)))"
  log_tc19 "--- TC19.3:: Host network mode validation ---"

  if ! start_host_tcp_helper "$HOST_LISTENER_PORT"; then
    log_tc19 "FAIL: Could not start host-side TCP helper on 127.0.0.1:${HOST_LISTENER_PORT}"
    cld6001_record_result "host_network_exposure" "FAIL"
    return 1
  fi

  log_tc19 "Validating Podman host-network exposure against 127.0.0.1:${HOST_LISTENER_PORT}"
  if podman run --rm --network=host -e HOST_LISTENER_PORT="$HOST_LISTENER_PORT" -i "$PROBE_IMAGE" sh -c 'nc -w 3 -z 127.0.0.1 "$HOST_LISTENER_PORT"' 2>&1 | tee -a "$LOG_FILE"; then
    log_tc19 "PASS: Host-network mode exposes the controlled host listener"
    cld6001_record_result "host_network_exposure" "PASS"
    return 0
  fi

  log_tc19 "FAIL: Host-network mode did not expose the controlled host listener"
  cld6001_record_result "host_network_exposure" "FAIL"
  return 1
}

validate_same_pod_shared_network() {
  log_tc19 "--- TC19.4:: Same-pod shared network validation ---"
  podman pod create --name "$TEST_POD" >/dev/null
  podman run --rm -d --pod "$TEST_POD" --name "$POD_TARGET_CONTAINER" "$PROBE_IMAGE" sh -c 'while true; do printf "pod\n" | nc -l -p 9000; done' >/dev/null

  if ! wait_for_command_success podman run --rm --pod "$TEST_POD" -i "$PROBE_IMAGE" sh -c 'nc -w 3 -z 127.0.0.1 9000'; then
    log_tc19 "FAIL: Same-pod listener did not become reachable on shared localhost"
    cld6001_record_result "same_pod_shared_network" "FAIL"
    return 1
  fi

  if podman run --rm --pod "$TEST_POD" -i "$PROBE_IMAGE" sh -c 'nc -w 3 -z 127.0.0.1 9000' 2>&1 | tee -a "$LOG_FILE"; then
    log_tc19 "PASS: Containers in the same pod share localhost reachability"
    cld6001_record_result "same_pod_shared_network" "PASS"
    return 0
  fi

  log_tc19 "FAIL: Same-pod validation could not reach the shared localhost listener"
  cld6001_record_result "same_pod_shared_network" "FAIL"
  return 1
}

validate_external_container_pod_separation() {
  log_tc19 "--- TC19.5:: External container separation from pod localhost ---"
  if podman run --rm -i "$PROBE_IMAGE" sh -c 'nc -w 3 -z 127.0.0.1 9000' 2>&1 | tee -a "$LOG_FILE"; then
    log_tc19 "FAIL: External container unexpectedly reached the pod localhost listener"
    cld6001_record_result "external_container_pod_separation" "FAIL"
    return 1
  fi

  log_tc19 "PASS: External container could not reach the pod localhost listener"
  cld6001_record_result "external_container_pod_separation" "PASS"
  return 0
}

validate_bounded_host_bypass_probes() {
  local default_gateway=""
  local pod_gateway=""
  local attempted_count=0
  local unavailable_count=0
  local probe_status=0

  log_tc19 "--- TC19.6:: Bounded host-loopback bypass probes ---"

  if [ -z "${HOST_LISTENER_PORT:-}" ]; then
    record_tc19_block "tc19_bypass_probe_unavailable" "Bounded host-bypass probes were unavailable because the controlled host listener was not established."
    log_tc19 "BLOCK: Bounded host-bypass probes were unavailable because the controlled host listener was not established."
    return "${BLOCK_EXIT_CODE:-3}"
  fi

  if ! default_gateway="$(wait_for_nonempty_command_output podman_container_gateway "$TARGET_CONTAINER")"; then
    unavailable_count=$((unavailable_count + 1))
    log_tc19 "INFO: Could not resolve Podman default-network gateway metadata for bounded bypass probes"
  else
    if run_bounded_bypass_probe \
      "default bridge gateway probe" \
      "dedicated default bridge" \
      "$default_gateway" \
      podman run --rm --network "$DEFAULT_NETWORK" -e TARGET_HOST="$default_gateway" -e TARGET_PORT="$HOST_LISTENER_PORT" -i "$PROBE_IMAGE" sh -c "$TC19_TCP_TARGET_PROBE"
    then
      attempted_count=$((attempted_count + 1))
    else
      probe_status=$?
      if [ "$probe_status" -eq 2 ]; then
        unavailable_count=$((unavailable_count + 1))
      else
        cld6001_record_result "bounded_host_loopback_bypass" "FAIL"
        return 1
      fi
    fi
  fi

  if run_bounded_bypass_probe \
    "runtime host alias probe" \
    "dedicated default bridge" \
    "host.containers.internal" \
    podman run --rm --network "$DEFAULT_NETWORK" -e TARGET_HOST="host.containers.internal" -e TARGET_PORT="$HOST_LISTENER_PORT" -i "$PROBE_IMAGE" sh -c "$TC19_TCP_TARGET_PROBE"
  then
    attempted_count=$((attempted_count + 1))
  else
    probe_status=$?
    if [ "$probe_status" -eq 2 ]; then
      unavailable_count=$((unavailable_count + 1))
    else
      cld6001_record_result "bounded_host_loopback_bypass" "FAIL"
      return 1
    fi
  fi

  if ! pod_gateway="$(wait_for_nonempty_command_output podman_container_gateway "$POD_TARGET_CONTAINER")"; then
    unavailable_count=$((unavailable_count + 1))
    log_tc19 "INFO: Could not resolve Podman pod gateway metadata for bounded bypass probes"
  else
    if run_bounded_bypass_probe \
      "shared pod gateway probe" \
      "shared pod namespace" \
      "$pod_gateway" \
      podman run --rm --pod "$TEST_POD" -e TARGET_HOST="$pod_gateway" -e TARGET_PORT="$HOST_LISTENER_PORT" -i "$PROBE_IMAGE" sh -c "$TC19_TCP_TARGET_PROBE"
    then
      attempted_count=$((attempted_count + 1))
    else
      probe_status=$?
      if [ "$probe_status" -eq 2 ]; then
        unavailable_count=$((unavailable_count + 1))
      else
        cld6001_record_result "bounded_host_loopback_bypass" "FAIL"
        return 1
      fi
    fi
  fi

  if [ "$attempted_count" -eq 0 ]; then
    record_tc19_block "tc19_bypass_probe_unavailable" "Bounded host-bypass probes were unavailable because Podman could not expose any supported gateway or host-alias probe surface."
    log_tc19 "BLOCK: Bounded host-bypass probes were unavailable because Podman could not expose any supported gateway or host-alias probe surface."
    return "${BLOCK_EXIT_CODE:-3}"
  fi

  log_tc19 "PASS: ${attempted_count} bounded host-loopback bypass probe(s) remained blocked; unavailable probe count: ${unavailable_count}"
  cld6001_record_result "bounded_host_loopback_bypass" "PASS"
  return 0
}

echo "--- TC19: Network-Isolation Validation ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: ${TC19_RUNTIME_ID}"
echo ""

run_tc19_validation validate_default_network_reachability
run_tc19_validation capture_network_namespace_state
run_tc19_validation validate_host_network_exposure
run_tc19_validation validate_same_pod_shared_network
run_tc19_validation validate_external_container_pod_separation
run_tc19_validation validate_bounded_host_bypass_probes

log_tc19 "PASS count: ${PASS_COUNT}"
log_tc19 "FAIL count: ${FAIL_COUNT}"

echo ""
echo "--- TC19: Network-Isolation Validation ---"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi

if [ -n "$TC19_BLOCKED_REASON_CODE" ]; then
  write_result_reason "block" "$TC19_BLOCKED_REASON_CODE" "$TC19_BLOCKED_REASON_TEXT" "testcase-artifact"
  exit "${BLOCK_EXIT_CODE:-3}"
fi
