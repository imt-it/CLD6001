#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd -P)"
source "$REPO_ROOT/src/execute/test-runner-common.sh"
source "$REPO_ROOT/src/test-cases/tc14-seccomp-bypass/probe-helpers.sh"

PROBE_IMAGE="$(resolve_helper_image python-probe)"
HOST_PTRACE_TARGET_PID=""
HOST_PTRACE_ATTACH_PROBE="$(tc14_host_ptrace_attach_probe)"
PEER_PTRACE_SYSCALL_PROBE="$(tc14_peer_ptrace_syscall_probe)"
SENDFILE_PROBE="$(tc14_sendfile_probe)"

echo "--- TC14: Seccomp Bypass Probe ---"
echo "Date: $(date -Iseconds)"
echo "Runtime: docker-rootful"
echo ""

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

trap cleanup_host_ptrace_helper EXIT

echo "--- Test 1: Cross-process memory read probe ---"
start_host_ptrace_helper
{
  echo "Seccomp profile: Unconfined"
  echo "Capabilities: SYS_PTRACE"
  echo "PID namespace: host"
  echo "Attempting host-process memory read against helper PID ${HOST_PTRACE_TARGET_PID}..."
  docker run --rm -i --pid=host --cap-add=SYS_PTRACE --security-opt seccomp=unconfined -e HOST_PTRACE_TARGET_PID="$HOST_PTRACE_TARGET_PID" -e CONTAINER_PROBE_TMP_DIR="$CONTAINER_PROBE_TMP_DIR" "$PROBE_IMAGE" python3 -c "$HOST_PTRACE_ATTACH_PROBE"
} 2>&1 | tee "${TEST_RESULTS_DIR}/tc14-test1.txt"

echo "--- Test 2: Indirect system calls ---"
{
  echo "Seccomp profile: Unconfined"
  echo "Capabilities: SYS_PTRACE"
  echo "Testing indirect system calls against a non-traced peer process..."
  docker run --rm -i --cap-add=SYS_PTRACE --security-opt seccomp=unconfined -e CONTAINER_PROBE_TMP_DIR="$CONTAINER_PROBE_TMP_DIR" "$PROBE_IMAGE" python3 -c "$PEER_PTRACE_SYSCALL_PROBE"
} 2>&1 | tee "${TEST_RESULTS_DIR}/tc14-test2.txt"

echo "--- Test 3: Kernel exploit via syscalls ---"
{
  echo "Seccomp profile: Unconfined"
  echo "Testing kernel exploits via syscalls..."
  docker run --rm -i --security-opt seccomp=unconfined -e CONTAINER_PROBE_TMP_DIR="$CONTAINER_PROBE_TMP_DIR" "$PROBE_IMAGE" python3 -c "$SENDFILE_PROBE"
} 2>&1 | tee "${TEST_RESULTS_DIR}/tc14-test3.txt"

echo ""
cat "${TEST_RESULTS_DIR}/tc14-test1.txt" "${TEST_RESULTS_DIR}/tc14-test2.txt" "${TEST_RESULTS_DIR}/tc14-test3.txt" > "${TEST_RESULTS_DIR}/tc14-results.txt"
echo "Seccomp bypass probing completed"
echo "Results saved to ${TEST_RESULTS_DIR}/tc14-results.txt"
