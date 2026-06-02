#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/shared/adapter-result-helpers.sh"
source "$REPO_ROOT/src/shared/adapter-artifact-helpers.sh"
source "$REPO_ROOT/src/execute/escape-tests/network-probe-common.sh"
TC19_REVERSIBLE_VARIANT_PROBE="$(resolve_source_repo_path "resources/exploits/cve2026_31431_reversible/copy_fail_exp_reversible.py")"

PROBE_IMAGE="${RUNNER_TARGET_IMAGE:-}"
if [ -z "$PROBE_IMAGE" ]; then
  PROBE_IMAGE="$(resolve_helper_image alpine-shell)"
fi

TC19_RUNTIME_ID="${RUNNER_RUNTIME_ID:-docker-rootful}"
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

write_tc19_unknown_reason_if_absent() {
  if ! result_reason_exists; then
    write_result_reason "fail" "unknown" "Unknown" "testcase-artifact"
  fi
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

docker_container_ip() {
  local container_name="$1"
  docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name"
}

docker_container_gateway() {
  local container_name="$1"
  docker inspect --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' "$container_name"
}

date "+%Y-%m-%d %H:%M:%S" > "$RESULTS_DIR/tc19-network-isolation.log" 2>&1
LOG_FILE="${RESULTS_DIR}/tc19-network-isolation.log"
touch "$RESULTS_DIR/test-results.txt"

RUN_ID="$(cld6001_unique_timestamp_id "%s" "-")"
TARGET_CONTAINER="tc19-target-${RUN_ID}"
ISOLATED_TARGET_CONTAINER="tc19-iso-target-${RUN_ID}"
ISOLATION_NETWORK="tc19-isolation-${RUN_ID}"
TC19_LISTENING_PORTS_PROBE="$(listening_socket_probe_script)"
TC19_TCP_TARGET_PROBE="$(tcp_target_probe_script)"

cleanup_tc19_docker_resources() {
  cleanup_host_tcp_helper

  if docker container inspect "$ISOLATED_TARGET_CONTAINER" >/dev/null 2>&1; then
    docker rm -f "$ISOLATED_TARGET_CONTAINER" >/dev/null 2>&1
  fi

  if docker container inspect "$TARGET_CONTAINER" >/dev/null 2>&1; then
    docker rm -f "$TARGET_CONTAINER" >/dev/null 2>&1
  fi

  if docker network inspect "$ISOLATION_NETWORK" >/dev/null 2>&1; then
    docker network rm "$ISOLATION_NETWORK" >/dev/null 2>&1
  fi
}

cleanup_on_exit() {
  local exit_status=$?

  if ! cleanup_tc19_docker_resources; then
    echo "TC19 Docker cleanup failed" >&2
    if [ $exit_status -eq 0 ]; then
      exit_status=1
    fi
  fi

  if ! cld6001_mirror_artifacts_now "TC19_ARTIFACTS_DIR"; then
    echo "TC19 Docker artifact mirroring failed" >&2
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

classify_docker_alias_probe_unavailable() {
  case "$1" in
    *'invalid IP address in add-host'*|*"host-gateway"*|*"unknown flag: --add-host"*)
      return 0
      ;;
  esac

  return 1
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

  if classify_docker_alias_probe_unavailable "$probe_output"; then
    log_tc19 "INFO: ${label} could not be exercised with the available runtime features/tooling"
    return 2
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
  log_tc19 "Starting default-network target container..."
  docker run --rm -d --name "$TARGET_CONTAINER" "$PROBE_IMAGE" sh -c 'while true; do printf "default\n" | nc -l -p 8000; done' >/dev/null

  if ! target_ip="$(wait_for_nonempty_command_output docker_container_ip "$TARGET_CONTAINER")"; then
    log_tc19 "FAIL: Could not resolve Docker default-network target IP"
    cld6001_record_result "default_network_reachability" "FAIL"
    return 1
  fi

  if ! wait_for_command_success docker run --rm -e TARGET_IP="$target_ip" -i "$PROBE_IMAGE" sh -c 'nc -w 3 -z "$TARGET_IP" 8000'; then
    log_tc19 "FAIL: Default-network target listener did not become reachable on ${target_ip}:8000"
    cld6001_record_result "default_network_reachability" "FAIL"
    return 1
  fi

  log_tc19 "Resolved Docker default-network target IP: $target_ip"
  if docker run --rm -e TARGET_IP="$target_ip" -i "$PROBE_IMAGE" sh -c 'nc -w 3 -z "$TARGET_IP" 8000' 2>&1 | tee -a "$LOG_FILE"; then
    log_tc19 "PASS: Shared default-network peers can reach the target by IP"
    cld6001_record_result "default_network_reachability" "PASS"
    return 0
  fi

  log_tc19 "FAIL: Shared default-network peers could not reach the target by IP"
  cld6001_record_result "default_network_reachability" "FAIL"
  return 1
}

capture_network_namespace_state() {
  local network_state_output=""
  local probe_status=0
  local reason_text=""

  log_tc19 "--- TC19.2:: Network namespace state capture ---"
  read -r -d '' TC19_DOCKER_NETWORK_STATE_SCRIPT <<EOF || true
echo "--- Network namespace state ---"
echo "Network interfaces:"
ip link show
echo ""
echo "Listening ports:"
${TC19_LISTENING_PORTS_PROBE}
echo ""
echo "Route table probe:"
if [ -s /proc/net/route ]; then
  cat /proc/net/route
else
  echo "/proc/net/route missing or empty"
  exit 42
fi
echo ""
echo "Namespaces:"
cat /proc/self/ns/net 2>/dev/null || echo "Cannot read namespace info"
EOF

  set +e
  network_state_output="$(docker run --rm -i "$PROBE_IMAGE" sh -c "$TC19_DOCKER_NETWORK_STATE_SCRIPT" 2>&1)"
  probe_status=$?
  set -e
  printf '%s\n' "$network_state_output" | tee -a "$LOG_FILE"

  if [ "$probe_status" -eq 0 ]; then
    log_tc19 "PASS: Network namespace state capture completed"
    cld6001_record_result "network_namespace_state_capture" "PASS"
    return 0
  fi

  case "$network_state_output" in
    *"/proc/net/route missing or empty"*)
      reason_text="Network namespace probe could not confirm a populated /proc/net/route inside the container."
      write_result_reason "fail" "network_probe_failed" "$reason_text" "testcase-artifact"
      log_tc19 "FAIL: ${reason_text}"
      ;;
    *)
      log_tc19 "FAIL: Network namespace state capture failed"
      ;;
  esac
  cld6001_record_result "network_namespace_state_capture" "FAIL"
  return 1
}

validate_host_network_exposure() {
  HOST_LISTENER_PORT="$((18080 + (RANDOM % 1000)))"
  log_tc19 "--- TC19.3:: Host network mode validation ---"

  if ! start_host_tcp_helper "$HOST_LISTENER_PORT"; then
    log_tc19 "FAIL: Could not start host-side TCP helper on 127.0.0.1:${HOST_LISTENER_PORT}"
    cld6001_record_result "host_network_exposure" "FAIL"
    return 1
  fi

  log_tc19 "Validating Docker host-network exposure against 127.0.0.1:${HOST_LISTENER_PORT}"
  if docker run --rm --network=host -e HOST_LISTENER_PORT="$HOST_LISTENER_PORT" -i "$PROBE_IMAGE" sh -c 'nc -w 3 -z 127.0.0.1 "$HOST_LISTENER_PORT"' 2>&1 | tee -a "$LOG_FILE"; then
    log_tc19 "PASS: Host-network mode exposes the controlled host listener"
    cld6001_record_result "host_network_exposure" "PASS"
    return 0
  fi

  log_tc19 "FAIL: Host-network mode did not expose the controlled host listener"
  cld6001_record_result "host_network_exposure" "FAIL"
  return 1
}

validate_isolated_bridge_separation() {
  local isolated_target_ip=""

  log_tc19 "--- TC19.4:: Isolated bridge separation ---"
  docker network create --driver bridge "$ISOLATION_NETWORK" >/dev/null
  docker run --rm -d --name "$ISOLATED_TARGET_CONTAINER" --network "$ISOLATION_NETWORK" "$PROBE_IMAGE" sh -c 'while true; do printf "isolated\n" | nc -l -p 9000; done' >/dev/null

  if ! isolated_target_ip="$(wait_for_nonempty_command_output docker_container_ip "$ISOLATED_TARGET_CONTAINER")"; then
    log_tc19 "FAIL: Could not resolve isolated-bridge target IP"
    cld6001_record_result "isolated_bridge_separation" "FAIL"
    return 1
  fi

  if ! wait_for_command_success docker run --rm --network "$ISOLATION_NETWORK" -e TARGET_IP="$isolated_target_ip" -i "$PROBE_IMAGE" sh -c 'nc -w 3 -z "$TARGET_IP" 9000'; then
    log_tc19 "FAIL: Isolated-bridge target listener did not become reachable within the isolated bridge network"
    cld6001_record_result "isolated_bridge_separation" "FAIL"
    return 1
  fi

  log_tc19 "Resolved isolated-bridge target IP: $isolated_target_ip"
  if docker run --rm -e TARGET_IP="$isolated_target_ip" -i "$PROBE_IMAGE" sh -c 'nc -w 3 -z "$TARGET_IP" 9000' 2>&1 | tee -a "$LOG_FILE"; then
    log_tc19 "FAIL: Default-network container unexpectedly reached the isolated bridge target"
    cld6001_record_result "isolated_bridge_separation" "FAIL"
    return 1
  fi

  log_tc19 "PASS: Default-network container could not reach the isolated bridge target"
  cld6001_record_result "isolated_bridge_separation" "PASS"
  return 0
}

validate_bounded_host_bypass_probes() {
  local default_gateway=""
  local isolated_gateway=""
  local attempted_count=0
  local unavailable_count=0
  local probe_status=0

  log_tc19 "--- TC19.5:: Bounded host-loopback bypass probes ---"

  if [ -z "${HOST_LISTENER_PORT:-}" ]; then
    record_tc19_block "tc19_bypass_probe_unavailable" "Bounded host-bypass probes were unavailable because the controlled host listener was not established."
    log_tc19 "BLOCK: Bounded host-bypass probes were unavailable because the controlled host listener was not established."
    return "${BLOCK_EXIT_CODE:-3}"
  fi

  if ! default_gateway="$(wait_for_nonempty_command_output docker_container_gateway "$TARGET_CONTAINER")"; then
    unavailable_count=$((unavailable_count + 1))
    log_tc19 "INFO: Could not resolve Docker default-network gateway metadata for bounded bypass probes"
  else
    if run_bounded_bypass_probe \
      "default bridge gateway probe" \
      "default bridge" \
      "$default_gateway" \
      docker run --rm -e TARGET_HOST="$default_gateway" -e TARGET_PORT="$HOST_LISTENER_PORT" -i "$PROBE_IMAGE" sh -c "$TC19_TCP_TARGET_PROBE"
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
    "default bridge" \
    "host.docker.internal" \
    docker run --rm --add-host "host.docker.internal:host-gateway" -e TARGET_HOST="host.docker.internal" -e TARGET_PORT="$HOST_LISTENER_PORT" -i "$PROBE_IMAGE" sh -c "$TC19_TCP_TARGET_PROBE"
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

  if ! isolated_gateway="$(wait_for_nonempty_command_output docker_container_gateway "$ISOLATED_TARGET_CONTAINER")"; then
    unavailable_count=$((unavailable_count + 1))
    log_tc19 "INFO: Could not resolve isolated-bridge gateway metadata for bounded bypass probes"
  else
    if run_bounded_bypass_probe \
      "isolated bridge gateway probe" \
      "isolated bridge" \
      "$isolated_gateway" \
      docker run --rm --network "$ISOLATION_NETWORK" -e TARGET_HOST="$isolated_gateway" -e TARGET_PORT="$HOST_LISTENER_PORT" -i "$PROBE_IMAGE" sh -c "$TC19_TCP_TARGET_PROBE"
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
    record_tc19_block "tc19_bypass_probe_unavailable" "Bounded host-bypass probes were unavailable because Docker could not expose any supported gateway or host-alias probe surface."
    log_tc19 "BLOCK: Bounded host-bypass probes were unavailable because Docker could not expose any supported gateway or host-alias probe surface."
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
run_tc19_validation validate_isolated_bridge_separation
run_tc19_validation validate_bounded_host_bypass_probes

log_tc19 "PASS count: ${PASS_COUNT}"
log_tc19 "FAIL count: ${FAIL_COUNT}"

echo ""
echo "--- TC19: Network-Isolation Validation ---"

if [ "$FAIL_COUNT" -gt 0 ]; then
  write_tc19_unknown_reason_if_absent
  exit 1
fi

if [ -n "$TC19_BLOCKED_REASON_CODE" ]; then
  write_result_reason "block" "$TC19_BLOCKED_REASON_CODE" "$TC19_BLOCKED_REASON_TEXT" "testcase-artifact"
  exit "${BLOCK_EXIT_CODE:-3}"
fi
