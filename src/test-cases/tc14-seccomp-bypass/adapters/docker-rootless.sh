#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/test-cases/tc14-seccomp-bypass/probe-helpers.sh"

TC14_RUNTIME_ID="${RUNNER_RUNTIME_ID:-docker-rootless}"
PROBE_IMAGE="$(resolve_helper_image python-probe)"
HOST_PTRACE_TARGET_PID=""
HOST_PTRACE_ATTACH_PROBE="$(tc14_host_ptrace_attach_probe)"
PEER_PTRACE_SYSCALL_PROBE="$(tc14_peer_ptrace_syscall_probe)"
SENDFILE_PROBE="$(tc14_sendfile_probe)"

cleanup_host_ptrace_helper() {
  if [ -n "${HOST_PTRACE_TARGET_PID:-}" ]; then
    kill "${HOST_PTRACE_TARGET_PID}" 2>/dev/null || true
    wait "${HOST_PTRACE_TARGET_PID}" 2>/dev/null || true
  fi
}

start_host_ptrace_helper() {
  (sleep 3600) &
  HOST_PTRACE_TARGET_PID=$!
}

run_rootless_probe() {
  local output_file="$1"
  local success_status="$2"
  local refusal_status="$3"
  shift 3

  local output=""
  local refusal_output=""
  local status=0

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [ -n "$output" ]; then
    printf '%s\n' "$output" | tee "$output_file"
  else
    : > "$output_file"
  fi

  if [ "$status" -eq 0 ]; then
    TC14_LAST_STATUS="$success_status"
    return 0
  fi

  refusal_output="${refusal_status/BLOCK -/BLOCK:}"
  printf '%s\n' "$refusal_output" | tee -a "$output_file"
  TC14_LAST_STATUS="$refusal_status"
  return 0
}

emit_probe_summary() {
  cat <<EOF
--- Seccomp Probe Summary ---
Test 1 status: $1
Test 2 status: $2
Test 3 status: $3
Scope note: direct runtime evidence only - blocked or unavailable probes stay explicit
EOF
}

trap cleanup_host_ptrace_helper EXIT

echo "--- TC14: Seccomp Bypass Probe ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: ${TC14_RUNTIME_ID}"
echo ""

echo "--- Test 1: Cross-process memory read probe ---"
start_host_ptrace_helper
run_rootless_probe \
  "${TEST_RESULTS_DIR}/tc14-test1.txt" \
  "EXECUTED - host ptrace probe recorded under relaxed seccomp" \
  "BLOCK - runtime refused host ptrace probe preconditions (--pid=host and SYS_PTRACE)" \
  docker run --rm -i --pid=host --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
    -e HOST_PTRACE_TARGET_PID="$HOST_PTRACE_TARGET_PID" \
    -e CONTAINER_PROBE_TMP_DIR="$CONTAINER_PROBE_TMP_DIR" \
    "$PROBE_IMAGE" python3 -c "$HOST_PTRACE_ATTACH_PROBE"
test1_status="$TC14_LAST_STATUS"

echo "--- Test 2: Indirect system calls ---"
run_rootless_probe \
  "${TEST_RESULTS_DIR}/tc14-test2.txt" \
  "EXECUTED - peer ptrace syscall probe recorded under relaxed seccomp" \
  "BLOCK - runtime refused peer ptrace probe preconditions (CAP_SYS_PTRACE)" \
  docker run --rm -i --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
    -e CONTAINER_PROBE_TMP_DIR="$CONTAINER_PROBE_TMP_DIR" \
    "$PROBE_IMAGE" python3 -c "$PEER_PTRACE_SYSCALL_PROBE"
test2_status="$TC14_LAST_STATUS"

echo "--- Test 3: Kernel exploit via syscalls ---"
run_rootless_probe \
  "${TEST_RESULTS_DIR}/tc14-test3.txt" \
  "EXECUTED - relaxed seccomp syscall probe recorded" \
  "BLOCK - runtime refused relaxed seccomp syscall probe" \
  docker run --rm -i --security-opt seccomp=unconfined \
    -e CONTAINER_PROBE_TMP_DIR="$CONTAINER_PROBE_TMP_DIR" \
    "$PROBE_IMAGE" python3 -c "$SENDFILE_PROBE"
test3_status="$TC14_LAST_STATUS"

echo ""
probe_summary="$(emit_probe_summary "$test1_status" "$test2_status" "$test3_status")"
printf '%s\n' "$probe_summary"
cat "${TEST_RESULTS_DIR}/tc14-test1.txt" "${TEST_RESULTS_DIR}/tc14-test2.txt" "${TEST_RESULTS_DIR}/tc14-test3.txt" > "${TEST_RESULTS_DIR}/tc14-results.txt"
{
  echo ""
  printf '%s\n' "$probe_summary"
} >> "${TEST_RESULTS_DIR}/tc14-results.txt"
echo "Seccomp bypass probing completed"
echo "Results saved to ${TEST_RESULTS_DIR}/tc14-results.txt"
